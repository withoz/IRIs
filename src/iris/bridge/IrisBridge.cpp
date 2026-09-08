#include "IrisBridge.h"

#include <json/json.h>

#include <memory>

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

            ack = "{\"protocol\":" + std::to_string(protocol::kProtocolVersion) +
                  ",\"accepted\":true,\"renderer\":\"IRIS\"}";
            return true;
        };

        cb.onSceneBlob = [this, say](std::vector<uint8_t>&& blob, uint32_t flags, std::string& err) {
            if (flags & protocol::FrameFlag_Partial)
            {
                // 부분 갱신은 5단계입니다. 지금 조용히 전체로 취급하면 화면이
                // 틀리게 나오므로 명시적으로 거절합니다.
                err = "부분 씬(Partial)은 아직 지원하지 않습니다";
                return false;
            }

            size_t bytes = 0;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                // 렌더가 따라가지 못해 아직 안 가져간 씬이 있으면 **버리고 최신으로
                // 갈아탑니다.** 큐에 쌓으면 편집이 빠를 때 지연만 늘어납니다.
                if (!m_pending.empty())
                    ++m_dropped;
                m_pending = std::move(blob);
                bytes     = m_pending.size();
            }
            say("씬 수신 " + std::to_string(bytes) + " bytes");
            return true;
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
