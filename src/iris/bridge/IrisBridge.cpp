#include "IrisBridge.h"

#include <donut/engine/TextureCache.h>

#include <cstdio>
#include <cstring>
#include <json/json.h>

#include <memory>

namespace de = donut::engine;

namespace
{
    // 64비트씩 훑는 FNV-1a 변형. 36 MB 에 수 ms 로, 전송(47 ms)이나
    // 씬 구축(20 ms)에 비하면 무시할 수 있습니다.
    // 암호학적 용도가 아니라 "같은 바이트인가"만 봅니다.
    uint64_t HashBytes(const uint8_t* data, size_t size)
    {
        constexpr uint64_t kOffset = 1469598103934665603ull;
        constexpr uint64_t kPrime  = 1099511628211ull;

        uint64_t h = kOffset ^ static_cast<uint64_t>(size);

        const size_t words = size / sizeof(uint64_t);
        const uint8_t* p = data;
        for (size_t i = 0; i < words; ++i)
        {
            uint64_t w;
            std::memcpy(&w, p, sizeof(w));
            p += sizeof(w);
            h = (h ^ w) * kPrime;
        }
        for (const uint8_t* end = data + size; p != end; ++p)
            h = (h ^ *p) * kPrime;
        return h;
    }
}

namespace iris::bridge
{
    IrisBridge& IrisBridge::Get()
    {
        static IrisBridge instance;
        return instance;
    }

    IrisBridge::~IrisBridge()
    {
        Stop();
    }

    void IrisBridge::SetLog(std::function<void(const std::string&)> log)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_log = std::move(log);
    }

    bool IrisBridge::Start(const std::string& pipeName)
    {
        if (m_server.IsRunning())
            return true;

        auto say = [this](const std::string& s) {
            std::function<void(const std::string&)> fn;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                fn = m_log;
            }
            if (fn)
                fn(s);
        };

        protocol::PipeServerCallbacks cb;

        cb.onLog = say;

        cb.onHello = [this, say](const std::string& helloJson, std::string& ack) {
            say("Hello: " + helloJson);

            Json::Value  doc;
            Json::CharReaderBuilder builder;
            std::string  parseError;
            std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
            const bool parsed = reader->parse(helloJson.data(),
                                              helloJson.data() + helloJson.size(),
                                              &doc, &parseError);
            if (!parsed || !doc.isObject())
            {
                ack = "{\"protocol\":" + std::to_string(protocol::kProtocolVersion) +
                      ",\"accepted\":false,\"reason\":\"Hello JSON 파싱 실패\"}";
                say("Hello 파싱 실패: " + parseError);
                return false;
            }

            const uint32_t theirs = doc["protocol"].isNumeric()
                                        ? static_cast<uint32_t>(doc["protocol"].asUInt()) : 0;
            if (theirs != protocol::kProtocolVersion)
            {
                ack = "{\"protocol\":" + std::to_string(protocol::kProtocolVersion) +
                      ",\"accepted\":false,\"reason\":\"프로토콜 버전 불일치\"}";
                say("프로토콜 버전 불일치: 호스트 " + std::to_string(theirs) +
                    " vs 렌더러 " + std::to_string(protocol::kProtocolVersion));
                return false;
            }

            if (doc["texture_base"].isString())
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                m_textureBase = doc["texture_base"].asString();
            }

            // ⚠ 세션 번호를 빠뜨리지 마십시오.
            //
            // 여기서 ack 를 통째로 덮어씁니다. PipeServer 가 만들어 둔 기본
            // 응답은 사라집니다 — 실제로 그렇게 해서 델타가 켜지지 않았고,
            // 호스트는 매번 전체를 보내면서도 아무 오류를 보지 못했습니다.
            const bool needFull = TakeFullResyncRequest();
            if (needFull)
                say("지난 씬에 재사용할 메시가 없었습니다 — 전체 재전송을 요청합니다");

            ack = "{\"protocol\":" + std::to_string(protocol::kProtocolVersion) +
                  ",\"accepted\":true,\"renderer\":\"IRIS\",\"session\":" +
                  std::to_string(protocol::ProcessSessionId()) +
                  ",\"need_full\":" + (needFull ? "true" : "false") + "}";
            return true;
        };

        cb.onSceneBlob = [this, say](std::vector<uint8_t>&& blob, uint32_t flags, std::string& err) {
            if (flags & protocol::FrameFlag_Partial)
            {
                // 델타(5단계)는 **프레임 플래그가 아니라 페이로드**로 표현합니다.
                // 매니페스트는 항상 완전하고, 바뀌지 않은 정의만 `geom: "same"`
                // 으로 표시되어 정점이 빠집니다. 그래서 이 플래그는 여전히
                // 쓰이지 않으며, 켜져서 오면 우리가 모르는 형식입니다.
                err = "부분 프레임(Partial)은 쓰지 않습니다 — 델타는 페이로드로 표현합니다";
                return false;
            }

            const uint64_t hash = HashBytes(blob.data(), blob.size());

            size_t   bytes = 0;
            uint64_t dup   = 0;
            {
                std::lock_guard<std::mutex> lock(m_mutex);

                // 내용이 같으면 무시합니다. 받아들이면 BLAS 를 다시 짓고 누적을
                // 초기화해 화면이 수렴하지 못합니다.
                if (m_hasLastHash && hash == m_lastHash)
                {
                    dup = ++m_duplicates;
                }
                else
                {
                    // 렌더가 따라가지 못해 아직 안 가져간 씬이 있으면 **버리고
                    // 최신으로 갈아탑니다.** 큐에 쌓으면 편집이 빠를 때 지연만
                    // 늘어납니다.
                    if (!m_pending.empty())
                        ++m_dropped;
                    m_pending     = std::move(blob);
                    m_lastHash    = hash;
                    m_hasLastHash = true;
                    bytes         = m_pending.size();
                }
            }

            if (dup)
            {
                // 매번 찍으면 로그가 넘칩니다. 처음과 이후 100회마다만 알립니다.
                if (dup == 1 || dup % 100 == 0)
                    say("같은 씬이 다시 왔습니다 — 무시합니다 (누적 " + std::to_string(dup) + "회)");
            }
            else
            {
                say("씬 수신 " + std::to_string(bytes) + " bytes");
            }
            return true;
        };

        cb.onCamera = [this, say](const std::string& json) {
            Json::Value  doc;
            Json::CharReaderBuilder builder;
            std::string  err;
            std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
            if (!reader->parse(json.data(), json.data() + json.size(), &doc, &err) || !doc.isObject())
            {
                say("카메라 JSON 파싱 실패: " + err);
                return;
            }

            auto vec3 = [&doc](const char* key, float* out) {
                const Json::Value& a = doc[key];
                if (!a.isArray() || a.size() != 3)
                    return false;
                for (int i = 0; i < 3; ++i)
                    out[i] = static_cast<float>(a[i].asDouble());
                return true;
            };

            CameraState c;
            if (!vec3("eye", c.eye) || !vec3("target", c.target))
            {
                say("카메라 메시지에 eye/target 이 없습니다");
                return;
            }
            vec3("up", c.up);
            if (doc["fov_deg"].isNumeric())       c.fovDeg      = static_cast<float>(doc["fov_deg"].asDouble());
            if (doc["fov_is_height"].isBool())    c.fovIsHeight = doc["fov_is_height"].asBool();
            if (doc["aspect"].isNumeric())        c.aspect      = static_cast<float>(doc["aspect"].asDouble());

            uint64_t n = 0;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                m_camera    = c;
                m_hasCamera = true;
                n = ++m_cameraCount;
            }
            // 매초 오므로 처음 몇 번과 이후 가끔만 알립니다.
            if (n <= 3 || n % 30 == 0)
            {
                char buf[192];
                std::snprintf(buf, sizeof(buf),
                              "카메라 수신 #%llu  눈(%.2f, %.2f, %.2f) fov %.1f%s",
                              (unsigned long long)n,
                              c.eye[0], c.eye[1], c.eye[2], c.fovDeg,
                              c.fovIsHeight ? " (수직)" : " (수평)");
                say(buf);
            }
        };

        protocol::PipeServerConfig cfg;
        cfg.name = pipeName;

        if (!m_server.Start(cfg, std::move(cb)))
        {
            say("파이프 서버 시작 실패: " + m_server.LastError());
            return false;
        }
        return true;
    }

    void IrisBridge::Stop()
    {
        m_server.Stop();
        std::lock_guard<std::mutex> lock(m_mutex);
        m_pending.clear();
    }

    bool IrisBridge::IsRunning() const
    {
        return m_server.IsRunning();
    }

    bool IrisBridge::HasPendingScene() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return !m_pending.empty();
    }

    std::vector<uint8_t> IrisBridge::TakePendingScene()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        // 이동 후 상태는 표준이 "유효하나 미지정"이라고만 합니다. HasPendingScene 이
        // 비었는지로 판단하므로 명시적으로 비웁니다.
        std::vector<uint8_t> out = std::move(m_pending);
        m_pending.clear();
        return out;
    }

    bool IrisBridge::HasPendingCamera() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_hasCamera;
    }

    IrisBridge::CameraState IrisBridge::TakePendingCamera()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_hasCamera = false;
        return m_camera;
    }

    protocol::PipeServerStats IrisBridge::Stats() const
    {
        return m_server.GetStats();
    }

    std::string IrisBridge::LastError() const
    {
        return m_server.LastError();
    }

    std::string IrisBridge::TextureBase() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_textureBase;
    }

    std::shared_ptr<de::LoadedTexture> IrisBridge::FindTexture(const std::string& key) const
    {
        std::lock_guard<std::mutex> lock(m_texMutex);
        auto it = m_textures.find(key);
        return it == m_textures.end() ? nullptr : it->second;
    }

    void IrisBridge::CacheTexture(const std::string& key, std::shared_ptr<de::LoadedTexture> tex)
    {
        if (!tex)
            return;
        std::lock_guard<std::mutex> lock(m_texMutex);
        m_textures[key] = std::move(tex);
    }

    size_t IrisBridge::TextureCacheSize() const
    {
        std::lock_guard<std::mutex> lock(m_texMutex);
        return m_textures.size();
    }

    void IrisBridge::ClearTextureCache()
    {
        std::lock_guard<std::mutex> lock(m_texMutex);
        m_textures.clear();
    }

    uint64_t IrisBridge::DuplicatesIgnored() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_duplicates;
    }

    uint64_t IrisBridge::ScenesApplied() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return m_applied;
    }

    void IrisBridge::NotifyApplied()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        ++m_applied;
    }
}

namespace iris::bridge
{
    void IrisBridge::RequestFullResync()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_needFullResync = true;
    }

    bool IrisBridge::TakeFullResyncRequest()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        const bool v = m_needFullResync;
        m_needFullResync = false;
        return v;
    }
}
