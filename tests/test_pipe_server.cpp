// IRIS — 명명 파이프 수신부 시험
//
// 클라이언트는 **일반 파일 열기**로 붙습니다. SketchUp 의 Ruby 가
// File.open("\\.\pipe\iris", "rb+") 로 하는 것과 같은 경로(CreateFile)이며,
// 그래야 이 시험이 실제 조건을 반영합니다.
//
// 실제 36 MB .irisb 를 보내고, 받은 바이트가 IrisbReader 로 파싱되는지까지
// 확인합니다. 합성 데이터만으로는 놓치는 것이 있습니다.
//
// 사용법:  test_pipe_server.exe <파일.irisb>

#include "iris/protocol/IrisbReader.h"
#include "iris/protocol/PipeServer.h"
#include "iris/protocol/Wire.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

using namespace iris::protocol;

namespace
{
    int g_passed = 0;
    int g_failed = 0;

    void Check(bool cond, const std::string& what)
    {
        (cond ? g_passed : g_failed)++;
        std::printf("  [%s] %s\n", cond ? "ok  " : "FAIL", what.c_str());
    }

    // ------------------------------------------------------------ 클라이언트
    //
    // Ruby 와 같은 방식으로 파이프를 엽니다 — 특별한 API 를 쓰지 않습니다.
    class Client
    {
    public:
        bool Open(const std::string& path, int retries = 25)
        {
            for (int i = 0; i < retries; ++i)
            {
                m_h = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                                  0, nullptr, OPEN_EXISTING, 0, nullptr);
                if (m_h != INVALID_HANDLE_VALUE)
                    return true;
                std::this_thread::sleep_for(std::chrono::milliseconds(40));
            }
            return false;
        }

        void Close()
        {
            if (m_h != INVALID_HANDLE_VALUE) { CloseHandle(m_h); m_h = INVALID_HANDLE_VALUE; }
        }

        ~Client() { Close(); }

        bool Send(MsgType type, uint32_t flags, const void* payload, size_t len)
        {
            uint8_t head[kFrameHeaderSize];
            EncodeHeader({ static_cast<uint32_t>(type), flags, static_cast<uint64_t>(len) }, head);
            return WriteAll(head, sizeof(head)) && (len == 0 || WriteAll(payload, len));
        }

        bool Send(MsgType type, const std::string& json)
        {
            return Send(type, 0, json.data(), json.size());
        }

        // 헤더에만 큰 길이를 선언하고 실제로는 안 보냅니다 — 한도 검사를 보기 위함.
        bool SendBogusHeader(MsgType type, uint64_t declaredLen)
        {
            uint8_t head[kFrameHeaderSize];
            EncodeHeader({ static_cast<uint32_t>(type), 0, declaredLen }, head);
            return WriteAll(head, sizeof(head));
        }

        bool Recv(FrameHeader& h, std::vector<uint8_t>& payload)
        {
            uint8_t head[kFrameHeaderSize];
            if (!ReadAll(head, sizeof(head)))
                return false;
            h = DecodeHeader(head);
            payload.resize(static_cast<size_t>(h.payloadLen));
            return h.payloadLen == 0 || ReadAll(payload.data(), payload.size());
        }

    private:
        bool WriteAll(const void* src, size_t n)
        {
            const uint8_t* p = static_cast<const uint8_t*>(src);
            size_t done = 0;
            while (done < n)
            {
                DWORD put = 0;
                const DWORD want = static_cast<DWORD>(std::min<size_t>(n - done, 1u << 20));
                if (!WriteFile(m_h, p + done, want, &put, nullptr) || put == 0)
                    return false;
                done += put;
            }
            return true;
        }

        bool ReadAll(void* dst, size_t n)
        {
            uint8_t* p = static_cast<uint8_t*>(dst);
            size_t done = 0;
            while (done < n)
            {
                DWORD got = 0;
                if (!ReadFile(m_h, p + done, static_cast<DWORD>(n - done), &got, nullptr) || got == 0)
                    return false;
                done += got;
            }
            return true;
        }

        HANDLE m_h = INVALID_HANDLE_VALUE;
    };

    std::vector<uint8_t> ReadFileBytes(const char* path)
    {
        std::vector<uint8_t> data;
        FILE* f = nullptr;
        if (fopen_s(&f, path, "rb") != 0 || !f)
            return data;
        std::fseek(f, 0, SEEK_END);
        data.resize(static_cast<size_t>(std::ftell(f)));
        std::fseek(f, 0, SEEK_SET);
        const size_t got = std::fread(data.data(), 1, data.size(), f);
        std::fclose(f);
        data.resize(got);
        return data;
    }
}

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::printf("사용법: %s <파일.irisb>\n", argv[0]);
        return 2;
    }

    const std::vector<uint8_t> scene = ReadFileBytes(argv[1]);
    if (scene.empty())
    {
        std::printf("씬 파일을 읽지 못했습니다: %s\n", argv[1]);
        return 2;
    }
    std::printf("IRIS 파이프 수신부 시험\n씬: %s (%zu bytes)\n\n", argv[1], scene.size());

    // 같은 머신에서 다른 시험과 부딪히지 않도록 이름에 PID 를 붙입니다.
    const std::string name = "iris-test-" + std::to_string(GetCurrentProcessId());
    const std::string path = PipeServer::PipePath(name);

    // ---- 수신 쪽 상태 ----
    std::mutex               mu;
    std::vector<uint8_t>     received;
    std::string              helloSeen;
    std::atomic<int>         syncEnds{ 0 };
    std::atomic<uint32_t>    blobFlags{ 0 };

    PipeServerCallbacks cb;
    cb.onHello = [&](const std::string& json, std::string& ack) {
        std::lock_guard<std::mutex> lock(mu);
        helloSeen = json;
        ack = "{\"protocol\":1,\"accepted\":true,\"renderer\":\"IRIS-test\"}";
        return true;
    };
    cb.onSceneBlob = [&](std::vector<uint8_t>&& blob, uint32_t flags, std::string& err) {
        Scene parsed;
        const ReadResult r = ReadIrisbMemory(blob.data(), blob.size(), parsed);
        if (!r.ok) { err = r.error; return false; }
        std::lock_guard<std::mutex> lock(mu);
        received  = std::move(blob);
        blobFlags = flags;
        return true;
    };
    cb.onSyncEnd = [&](uint64_t) { ++syncEnds; };

    PipeServer server;
    PipeServerConfig cfg;
    cfg.name = name;

    std::printf("서버 시작: %s\n", path.c_str());
    Check(server.Start(cfg, cb), "서버가 떴다");
    if (!server.IsRunning())
    {
        std::printf("시작 실패: %s\n", server.LastError().c_str());
        return 1;
    }

    // ---------------------------------------------------------- 정상 왕복
    std::printf("\n정상 왕복\n");
    {
        Client c;
        Check(c.Open(path), "일반 파일 열기로 붙었다 (Ruby 와 같은 경로)");

        const std::string hello =
            R"({"protocol":1,"app":"SketchUp 26.2.243","model":"golf","unit":"meter","up_axis":"z"})";
        Check(c.Send(MsgType::Hello, hello), "Hello 전송");

        FrameHeader h;
        std::vector<uint8_t> ack;
        Check(c.Recv(h, ack), "HelloAck 수신");
        Check(h.type == (uint32_t)MsgType::HelloAck, "응답 종류가 HelloAck");
        {
            const std::string s(ack.begin(), ack.end());
            Check(s.find("\"accepted\":true") != std::string::npos, "HelloAck 에 accepted:true — " + s);
        }

        Check(c.Send(MsgType::SyncBegin, R"({"seq":1})"), "SyncBegin 전송");

        const auto t0 = std::chrono::steady_clock::now();
        Check(c.Send(MsgType::SceneBlob, 0, scene.data(), scene.size()), "SceneBlob 전송");
        Check(c.Send(MsgType::SyncEnd, R"({"seq":1})"), "SyncEnd 전송");

        Check(c.Recv(h, ack), "SyncAck 수신");
        const double ms = std::chrono::duration<double, std::milli>(
                              std::chrono::steady_clock::now() - t0).count();
        Check(h.type == (uint32_t)MsgType::SyncAck, "응답 종류가 SyncAck");

        std::printf("  씬 %zu bytes 왕복 %.1f ms = %.0f MB/s\n",
                    scene.size(), ms, scene.size() / 1048576.0 / (ms / 1000.0));

        {
            std::lock_guard<std::mutex> lock(mu);
            Check(received.size() == scene.size(), "받은 크기가 같다");
            Check(received.size() == scene.size() &&
                      std::memcmp(received.data(), scene.data(), scene.size()) == 0,
                  "받은 바이트가 완전히 같다");
            Check(helloSeen.find("SketchUp") != std::string::npos, "Hello 내용이 전달됐다");
        }
        Check(syncEnds.load() == 1, "SyncEnd 콜백이 정확히 1회");

        c.Send(MsgType::Bye, 0, nullptr, 0);
        c.Close();
    }

    // ---------------------------------------------------------- 오류 경로
    std::printf("\n오류 경로\n");
    {
        // Hello 없이 SceneBlob
        Client c;
        if (c.Open(path))
        {
            const uint8_t dummy[4] = { 1, 2, 3, 4 };
            c.Send(MsgType::SceneBlob, 0, dummy, sizeof(dummy));
            c.Close();
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            Check(server.LastError().find("Hello 없이") != std::string::npos,
                  "Hello 없는 SceneBlob 을 거부한다: " + server.LastError());
        }
        else
        {
            Check(false, "재연결 실패");
        }
    }
    {
        // 터무니없는 길이 선언
        Client c;
        if (c.Open(path))
        {
            c.SendBogusHeader(MsgType::SceneBlob, kMaxPayloadBytes + 1);
            c.Close();
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            Check(server.LastError().find("너무 큽니다") != std::string::npos,
                  "한도를 넘는 페이로드 선언을 거부한다: " + server.LastError());
        }
        else
        {
            Check(false, "재연결 실패");
        }
    }
    {
        // 깨진 .irisb
        Client c;
        if (c.Open(path))
        {
            c.Send(MsgType::Hello, R"({"protocol":1})");
            FrameHeader h; std::vector<uint8_t> ack;
            c.Recv(h, ack);
            std::vector<uint8_t> junk(64, 0xAB);
            c.Send(MsgType::SceneBlob, 0, junk.data(), junk.size());
            c.Close();
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            Check(server.LastError().find("씬 처리 실패") != std::string::npos,
                  "파싱 실패한 씬을 보고한다: " + server.LastError());
        }
        else
        {
            Check(false, "재연결 실패");
        }
    }

    // ---------------------------------------------------------- 재연결
    std::printf("\n재연결\n");
    {
        Client c;
        Check(c.Open(path), "오류 후에도 다시 붙는다");
        c.Send(MsgType::Hello, R"({"protocol":1})");
        FrameHeader h; std::vector<uint8_t> ack;
        Check(c.Recv(h, ack) && h.type == (uint32_t)MsgType::HelloAck, "다시 HelloAck 를 받는다");
        c.Close();
    }

    const PipeServerStats st = server.GetStats();
    std::printf("\n통계: 연결 %llu · 프레임 %llu · 바이트 %llu · 씬 %llu · 오류 %llu\n",
                (unsigned long long)st.connections, (unsigned long long)st.framesIn,
                (unsigned long long)st.bytesIn, (unsigned long long)st.scenesIn,
                (unsigned long long)st.errors);
    Check(st.scenesIn == 1, "성공한 씬은 1건으로 센다");

    server.Stop();
    Check(!server.IsRunning(), "서버가 깨끗하게 멈춘다");

    std::printf("\n────────────────────────────\n통과 %d / 실패 %d\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
