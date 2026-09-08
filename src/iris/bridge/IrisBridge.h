// IRIS — 라이브 링크 수명 관리
//
// 파이프 서버를 **프로세스 수명 동안** 들고 있습니다. 씬(IrisScene)은 로드할
// 때마다 새로 만들어지므로 거기에 서버를 두면 씬이 바뀔 때마다 연결이 끊깁니다.
//
// 스레드 경계가 여기입니다.
//   수신 스레드 : 파이프에서 .irisb 바이트를 받아 여기에 쌓는다
//   렌더 스레드 : HasPendingScene() 으로 확인하고 TakePendingScene() 으로 가져간다
//
// 받은 바이트를 그대로 넘기고 **파싱과 씬 구축은 렌더 스레드에서** 합니다.
// nvrhi 자원 생성이 렌더 스레드 전용이기 때문입니다. 파싱만 수신 스레드로
// 옮기는 것은 나중에 볼 최적화이고, 실측상 파싱은 전체의 일부입니다
// (docs/07-프로토콜-수신부-설계.md 5.2).

#pragma once

#include "iris/protocol/PipeServer.h"
#include "iris/protocol/Wire.h"

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace donut::engine
{
    struct LoadedTexture;
}

namespace iris::bridge
{
    // 렌더러가 라이브 씬을 가리킬 때 쓰는 이름. 실제 파일이 아닙니다 —
    // 엔진의 씬 전환 경로를 그대로 재사용하기 위한 가상 이름입니다.
    inline constexpr const char* kLiveSceneName = "IRIS live";

    class IrisBridge
    {
    public:
        static IrisBridge& Get();

        bool Start(const std::string& pipeName = "iris");
        void Stop();
        [[nodiscard]] bool IsRunning() const;

        // --- 렌더 스레드 ---
        [[nodiscard]] bool                 HasPendingScene() const;
        [[nodiscard]] std::vector<uint8_t> TakePendingScene();

        // 호스트 뷰포트 카메라. 시점을 돌릴 때마다 36 MB 씬을 다시 보낼 수는
        // 없으므로 작은 전용 메시지로 받습니다(Wire.h MsgType::Camera).
        // 좌표는 호스트 공간(Z-up, 미터)이며 변환은 소비자가 합니다.
        struct CameraState
        {
            float eye[3]{};
            float target[3]{};
            float up[3]{ 0.0f, 0.0f, 1.0f };
            float fovDeg      = 60.0f;
            bool  fovIsHeight = true;
            float aspect      = 0.0f;   // 호스트 뷰포트 가로/세로
        };

        [[nodiscard]] bool        HasPendingCamera() const;
        [[nodiscard]] CameraState TakePendingCamera();

        // 텍스처 파일이 놓인 디렉터리. 호스트가 Hello 의 texture_base 로 알려줍니다.
        //
        // 라이브 링크에서는 씬이 파일로 존재하지 않으므로 "씬 파일 옆"이라는
        // 기준을 쓸 수 없습니다. 텍스처는 같은 머신의 파일로 두고 경로만
        // 주고받습니다 — 05번 문서가 열어 둔 항목이며, 같은 머신이라 이쪽이
        // 단순합니다. 원격 구성이 생기면 바이트 전송을 다시 봅니다.
        [[nodiscard]] std::string TextureBase() const;

        // **델타 안전망.**
        //
        // 호스트가 "이 정의는 안 바뀌었다"고 했는데 우리가 갖고 있지 않으면
        // 그 물체는 화면에서 사라집니다. 오류는 나지 않으므로 아무도 모릅니다.
        //
        // 씬 적용은 렌더 스레드에서 나중에 일어나므로 그 자리에서 SyncAck 에
        // 실을 수 없습니다. 대신 표시를 남겨 **다음 Hello 응답**에 실어 보내고,
        // 호스트가 전체를 다시 보냅니다.
        void RequestFullResync();
        [[nodiscard]] bool TakeFullResyncRequest();

        // **하늘이 태양을 소유합니다.**
        //
        // 환경맵(HDRI)에는 태양이 구워져 있습니다. 거기에 우리 방향광을 더하면
        // **그림자가 둘**이 됩니다 — 실외 모델에서 바로 드러났습니다.
        //
        // RTXPT 에는 절차적 하늘이 있고(SampleProceduralSky, Q2RTX 대기 산란
        // 모델) 그 상수에 SunDir 이 있습니다. 다만 시각 스칼라로만 계산하고
        // 실제 태양 벡터를 받지 않습니다. 여기에 호스트의 방향을 넣어 두면
        // 하늘이 그것을 씁니다.
        //
        // 방향은 **엔진 월드(Y-up)에서 태양을 향하는** 단위 벡터입니다.
        // 하늘은 자기 좌표로 다시 바꿔서 씁니다.
        void SetSunDirection(const float dirYUp[3], bool present);
        [[nodiscard]] bool GetSunDirection(float outDirYUp[3]) const;

        // --- 텍스처 캐시 (프로세스 수명) ---
        //
        // **엔진의 TextureCache 는 씬을 로드할 때마다 비워집니다**
        // (ApplicationBase::BeginLoadingScene 이 Reset() 을 부릅니다).
        // 다른 씬으로 바꿀 때는 맞지만, 라이브 갱신에서는 곧바로 다시 읽을
        // 텍스처를 버리는 셈입니다. 실측에서 동기화 한 번마다 40장을 다시
        // 디코드했고 그것이 구축 시간 656 ms 중 638 ms 였습니다.
        //
        // Reset() 은 맵만 비우므로 **우리가 shared_ptr 을 들고 있으면 텍스처는
        // 살아남습니다.** GPU 자원도 그대로입니다.
        [[nodiscard]] std::shared_ptr<donut::engine::LoadedTexture>
                          FindTexture(const std::string& key) const;
        void              CacheTexture(const std::string& key,
                                       std::shared_ptr<donut::engine::LoadedTexture> tex);
        [[nodiscard]] size_t TextureCacheSize() const;
        void                 ClearTextureCache();

        // --- 진단 ---
        [[nodiscard]] protocol::PipeServerStats Stats() const;
        [[nodiscard]] std::string               LastError() const;
        [[nodiscard]] uint64_t                  ScenesApplied() const;
        [[nodiscard]] uint64_t                  DuplicatesIgnored() const;

        void SetLog(std::function<void(const std::string&)> log);

        // 씬을 실제로 화면에 반영했을 때 렌더 쪽에서 알려 줍니다. 통계용입니다.
        void NotifyApplied();

    private:
        IrisBridge() = default;
        ~IrisBridge();
        IrisBridge(const IrisBridge&)            = delete;
        IrisBridge& operator=(const IrisBridge&) = delete;

        mutable std::mutex                      m_mutex;
        bool                                    m_needFullResync = false;
        bool                                    m_sunPresent     = false;
        float                                   m_sunDir[3]      = { 0.0f, 1.0f, 0.0f };
        std::vector<uint8_t>                    m_pending;
        std::string                             m_textureBase;
        std::function<void(const std::string&)> m_log;
        protocol::PipeServer                    m_server;
        uint64_t                                m_applied = 0;
        uint64_t                                m_dropped = 0;

        // 같은 씬이 다시 오면 무시하기 위한 지문.
        //
        // 호스트가 내용이 같은 씬을 반복해 보내면 렌더러가 매번 BLAS 를 다시
        // 짓고 누적을 초기화합니다 — **화면이 영원히 수렴하지 않습니다.**
        // 실제로 그렇게 됐고, 로그에 478회 재로딩이 찍혔습니다.
        //
        // 호스트 쪽에서도 막지만(iris_link.rb), 프로토콜은 어떤 호스트가 붙어도
        // 견뎌야 합니다. 여기서 한 번 더 막습니다.
        uint64_t                                m_lastHash = 0;
        bool                                    m_hasLastHash = false;
        uint64_t                                m_duplicates = 0;

        CameraState                             m_camera;
        bool                                    m_hasCamera = false;
        uint64_t                                m_cameraCount = 0;

        mutable std::mutex                      m_texMutex;
        std::unordered_map<std::string, std::shared_ptr<donut::engine::LoadedTexture>> m_textures;
    };
}
