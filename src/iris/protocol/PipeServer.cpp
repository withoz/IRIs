#include "PipeServer.h"

#include "Wire.h"

#include <mutex>
#include <thread>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#endif

namespace iris::protocol
{
    namespace
    {
        std::string LastWinError(const char* what)
        {
#ifdef _WIN32
            const DWORD code = GetLastError();
            char* msg = nullptr;
            const DWORD n = FormatMessageA(
                FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPSTR)&msg, 0, nullptr);
            std::string text = (n && msg) ? std::string(msg, n) : std::string("(메시지 없음)");
            if (msg) LocalFree(msg);
            while (!text.empty() && (text.back() == '\n' || text.back() == '\r'))
                text.pop_back();
            return std::string(what) + " 실패 (" + std::to_string(code) + "): " + text;
#else
            return std::string(what) + " 실패 (Windows 전용)";
#endif
        }
    }

    // ------------------------------------------------------------------ Impl

    struct PipeServer::Impl
    {
        PipeServerConfig    config;
        PipeServerCallbacks cb;

        std::thread         thread;
        std::atomic<bool>   running{ false };
        std::atomic<bool>   stopping{ false };

        mutable std::mutex  mutex;
        PipeServerStats     stats;
        std::string         lastError;

#ifdef _WIN32
        // Stop() 이 WaitForConnection 을 깨우기 위해 씁니다.
        HANDLE              stopEvent  = nullptr;
        // 지금 대기/통신 중인 파이프. Stop 에서 취소하기 위해 들고 있습니다.
        std::atomic<void*>  activePipe{ nullptr };
#endif

        void Log(const std::string& s)
        {
            if (cb.onLog)
                cb.onLog(s);
        }

        void SetError(std::string s)
        {
            {
                std::lock_guard<std::mutex> lock(mutex);
                lastError = s;
                ++stats.errors;
            }
            Log("오류: " + s);
        }

        void Run();
#ifdef _WIN32
        bool ServeOne(HANDLE pipe);
        bool ReadExact(HANDLE pipe, uint8_t* dst, size_t bytes, OVERLAPPED& ov);
        bool WriteAll(HANDLE pipe, const uint8_t* src, size_t bytes, OVERLAPPED& ov);
        bool SendFrame(HANDLE pipe, MsgType type, uint32_t flags,
                       const void* payload, size_t len, OVERLAPPED& ov);
#endif
    };

    // ------------------------------------------------------------------ 공개

    PipeServer::PipeServer()  : m_impl(std::make_unique<Impl>()) {}
    PipeServer::~PipeServer() { Stop(); }

    std::string PipeServer::PipePath(const std::string& name)
    {
        // 역슬래시를 소스에 직접 쓰지 않습니다. 편집 도구를 거치며 개수가
        // 어긋나기 쉬워 실제로 한 번 깨졌습니다(Ruby 쪽 iris_pipe_test.rb 참조).
        const char b = static_cast<char>(92);   // '\'
        std::string p;
        p += b; p += b; p += '.'; p += b;
        p += "pipe";
        p += b;
        p += name;
        return p;
    }

    bool PipeServer::IsRunning() const { return m_impl->running.load(); }

    PipeServerStats PipeServer::GetStats() const
    {
        std::lock_guard<std::mutex> lock(m_impl->mutex);
        return m_impl->stats;
    }

    std::string PipeServer::LastError() const
    {
        std::lock_guard<std::mutex> lock(m_impl->mutex);
        return m_impl->lastError;
    }

    bool PipeServer::Start(const PipeServerConfig& config, PipeServerCallbacks callbacks)
    {
#ifndef _WIN32
        (void)config; (void)callbacks;
        m_impl->SetError("명명 파이프는 Windows 전용입니다");
        return false;
#else
        if (m_impl->running.load())
            return false;

        m_impl->config   = config;
        m_impl->cb       = std::move(callbacks);
        m_impl->stopping = false;

        m_impl->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!m_impl->stopEvent)
        {
            m_impl->SetError(LastWinError("CreateEvent"));
            return false;
        }

        m_impl->running = true;
        m_impl->thread  = std::thread([impl = m_impl.get()] { impl->Run(); });
        return true;
#endif
    }

    void PipeServer::Stop()
    {
#ifdef _WIN32
        if (!m_impl->running.load() && !m_impl->thread.joinable())
            return;

        m_impl->stopping = true;
        if (m_impl->stopEvent)
            SetEvent(m_impl->stopEvent);

        // 대기 중인 WaitForConnection 을 취소합니다.
        if (HANDLE pipe = static_cast<HANDLE>(m_impl->activePipe.load()))
            CancelIoEx(pipe, nullptr);

        if (m_impl->thread.joinable())
            m_impl->thread.join();

        if (m_impl->stopEvent)
        {
            CloseHandle(m_impl->stopEvent);
            m_impl->stopEvent = nullptr;
        }
        m_impl->running = false;
#endif
    }

#ifdef _WIN32

    // ------------------------------------------------------------------ 수신 루프

    void PipeServer::Impl::Run()
    {
        const std::wstring path = [this] {
            const std::string narrow = PipeServer::PipePath(config.name);
            return std::wstring(narrow.begin(), narrow.end());   // 파이프 이름은 ASCII 로 제한합니다
        }();

        Log("수신 대기: " + PipeServer::PipePath(config.name));

        while (!stopping.load())
        {
            HANDLE pipe = CreateNamedPipeW(
                path.c_str(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                config.maxInstances,
                config.bufferBytes,   // 출력 버퍼
                config.bufferBytes,   // 입력 버퍼
                0,                    // 기본 타임아웃
                nullptr);             // 기본 보안 (만든 사용자에게 전권)

            if (pipe == INVALID_HANDLE_VALUE)
            {
                SetError(LastWinError("CreateNamedPipe"));
                break;
            }

            activePipe = pipe;

            OVERLAPPED ov{};
            ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);

            bool connected = ConnectNamedPipe(pipe, &ov) != 0;
            if (!connected)
            {
                const DWORD err = GetLastError();
                if (err == ERROR_PIPE_CONNECTED)
                {
                    connected = true;
                }
                else if (err == ERROR_IO_PENDING)
                {
                    HANDLE waits[2] = { ov.hEvent, stopEvent };
                    const DWORD w = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
                    if (w == WAIT_OBJECT_0)
                    {
                        DWORD got = 0;
                        connected = GetOverlappedResult(pipe, &ov, &got, FALSE) != 0;
                    }
                    // w == WAIT_OBJECT_0 + 1 이면 Stop 요청 — connected 는 false
                }
                else if (!stopping.load())
                {
                    SetError(LastWinError("ConnectNamedPipe"));
                }
            }

            if (connected && !stopping.load())
            {
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    ++stats.connections;
                }
                Log("연결됨");
                ServeOne(pipe);
                Log("연결 종료");
            }

            DisconnectNamedPipe(pipe);
            activePipe = nullptr;
            CloseHandle(ov.hEvent);
            CloseHandle(pipe);
        }

        running = false;
        Log("수신 종료");
    }

    // ------------------------------------------------------------------ 입출력

    bool PipeServer::Impl::ReadExact(HANDLE pipe, uint8_t* dst, size_t bytes, OVERLAPPED& ov)
    {
        size_t done = 0;
        while (done < bytes)
        {
            if (stopping.load())
                return false;

            const DWORD want = static_cast<DWORD>(
                (bytes - done) > 0xFFFFFFFFull ? 0xFFFFFFFFull : (bytes - done));
            DWORD got = 0;
            ResetEvent(ov.hEvent);

            if (!ReadFile(pipe, dst + done, want, &got, &ov))
            {
                const DWORD err = GetLastError();
                if (err != ERROR_IO_PENDING)
                    return false;   // 상대가 끊음 — 정상 종료 경로이므로 오류로 세지 않습니다

                HANDLE waits[2] = { ov.hEvent, stopEvent };
                if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) != WAIT_OBJECT_0)
                    return false;
                if (!GetOverlappedResult(pipe, &ov, &got, FALSE))
                    return false;
            }
            if (got == 0)
                return false;
            done += got;
        }
        return true;
    }

    bool PipeServer::Impl::WriteAll(HANDLE pipe, const uint8_t* src, size_t bytes, OVERLAPPED& ov)
    {
        size_t done = 0;
        while (done < bytes)
        {
            const DWORD want = static_cast<DWORD>(
                (bytes - done) > 0xFFFFFFFFull ? 0xFFFFFFFFull : (bytes - done));
            DWORD put = 0;
            ResetEvent(ov.hEvent);

            if (!WriteFile(pipe, src + done, want, &put, &ov))
            {
                if (GetLastError() != ERROR_IO_PENDING)
                    return false;
                HANDLE waits[2] = { ov.hEvent, stopEvent };
                if (WaitForMultipleObjects(2, waits, FALSE, INFINITE) != WAIT_OBJECT_0)
                    return false;
                if (!GetOverlappedResult(pipe, &ov, &put, FALSE))
                    return false;
            }
            if (put == 0)
                return false;
            done += put;
        }
        return true;
    }

    bool PipeServer::Impl::SendFrame(HANDLE pipe, MsgType type, uint32_t flags,
                                     const void* payload, size_t len, OVERLAPPED& ov)
    {
        uint8_t head[kFrameHeaderSize];
        EncodeHeader({ static_cast<uint32_t>(type), flags, static_cast<uint64_t>(len) }, head);
        if (!WriteAll(pipe, head, sizeof(head), ov))
            return false;
        if (len && !WriteAll(pipe, static_cast<const uint8_t*>(payload), len, ov))
            return false;
        return true;
    }

    // ------------------------------------------------------------------ 프레임 처리

    bool PipeServer::Impl::ServeOne(HANDLE pipe)
    {
        OVERLAPPED ov{};
        ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        struct Closer { HANDLE h; ~Closer() { if (h) CloseHandle(h); } } closer{ ov.hEvent };

        bool     sawHello = false;
        uint64_t seq      = 0;

        for (;;)
        {
            uint8_t head[kFrameHeaderSize];
            if (!ReadExact(pipe, head, sizeof(head), ov))
                return true;   // 상대가 끊음

            const FrameHeader h = DecodeHeader(head);

            if (h.payloadLen > kMaxPayloadBytes)
            {
                SetError("페이로드가 너무 큽니다: " + std::to_string(h.payloadLen) +
                         " (한도 " + std::to_string(kMaxPayloadBytes) + ")");
                return false;
            }

            std::vector<uint8_t> payload(static_cast<size_t>(h.payloadLen));
            if (h.payloadLen && !ReadExact(pipe, payload.data(), payload.size(), ov))
            {
                SetError(std::string(MsgTypeName(h.type)) + " 페이로드 수신 중 연결이 끊겼습니다");
                return false;
            }

            {
                std::lock_guard<std::mutex> lock(mutex);
                ++stats.framesIn;
                stats.bytesIn += kFrameHeaderSize + h.payloadLen;
            }

            switch (static_cast<MsgType>(h.type))
            {
            case MsgType::Hello:
            {
                const std::string helloJson(reinterpret_cast<const char*>(payload.data()), payload.size());
                std::string ack = "{\"protocol\":" + std::to_string(kProtocolVersion) +
                                  ",\"accepted\":true,\"renderer\":\"IRIS\"}";
                bool accept = true;
                if (cb.onHello)
                    accept = cb.onHello(helloJson, ack);

                if (!SendFrame(pipe, MsgType::HelloAck, 0, ack.data(), ack.size(), ov))
                    return false;
                if (!accept)
                {
                    Log("Hello 거절 — 연결을 닫습니다");
                    return true;
                }
                sawHello = true;
                Log("Hello OK");
                break;
            }

            case MsgType::SyncBegin:
                if (!sawHello)
                {
                    SetError("Hello 없이 SyncBegin 이 왔습니다");
                    return false;
                }
                ++seq;
                break;

            case MsgType::SceneBlob:
            {
                if (!sawHello)
                {
                    SetError("Hello 없이 SceneBlob 이 왔습니다");
                    return false;
                }
                std::string err;
                const bool ok = cb.onSceneBlob
                                    ? cb.onSceneBlob(std::move(payload), h.flags, err)
                                    : (err = "수신 처리기가 없습니다", false);
                if (ok)
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    ++stats.scenesIn;
                }
                else
                {
                    SetError("씬 처리 실패: " + err);
                }
                break;
            }

            case MsgType::SyncEnd:
            {
                if (cb.onSyncEnd)
                    cb.onSyncEnd(seq);
                const std::string ack = "{\"seq\":" + std::to_string(seq) + ",\"ok\":true}";
                if (!SendFrame(pipe, MsgType::SyncAck, 0, ack.data(), ack.size(), ov))
                    return false;
                break;
            }

            case MsgType::Bye:
                Log("Bye");
                return true;

            default:
                // 모르는 타입은 건너뜁니다. 필드 추가가 하위 호환이 되도록
                // 하는 것과 같은 이유입니다(05번 9절).
                Log(std::string("모르는 프레임 종류 ") + std::to_string(h.type) + " — 건너뜁니다");
                break;
            }
        }
    }

#else   // !_WIN32

    void PipeServer::Impl::Run() { running = false; }

#endif
}
