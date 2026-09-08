// IRIS — 명명 파이프 수신 서버
//
// 호스트 확장(SketchUp 안의 Ruby)이 보내는 프레임을 받습니다.
// 전송 방식 결정 근거와 실측은 docs/05-씬-델타-프로토콜.md 10.1절.
//
// 왜 명명 파이프인가
//   - Ruby 가 gem 없이 File.open("\\.\pipe\iris") 로 붙습니다
//   - TCP 루프백과 달리 방화벽 창이 뜨지 않습니다
//   - Windows 접근 제어가 내장이고 양방향입니다
//
// 스레드 규칙
//   수신은 **별도 스레드**에서 돕니다. 36 MB 를 읽는 동안 렌더 스레드를 세우면
//   프레임이 끊깁니다. 콜백은 그 수신 스레드에서 불리며, nvrhi 객체를 만들거나
//   커맨드 리스트를 건드려서는 안 됩니다 — 그건 렌더 스레드 전용입니다.

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace iris::protocol
{
    // 이 렌더러 프로세스의 세션 번호. **프로세스마다 한 번** 정해집니다.
    //
    // 델타의 전제는 "렌더러가 이전에 보낸 지오메트리를 아직 들고 있다" 입니다.
    // 렌더러를 다시 띄우면 그 전제가 깨지는데, 호스트는 그것을 알 방법이
    // 없습니다 — 파이프는 그대로 열리고 이름도 같습니다. 그러면 호스트는
    // 바뀐 것만 보내고 렌더러는 나머지를 영영 못 받습니다.
    // **오류 없이 물체가 사라집니다.**
    //
    // HelloAck 에 실어 보내고, 다르면 호스트가 전체를 다시 보냅니다.
    uint64_t ProcessSessionId();

    struct PipeServerConfig
    {
        // 실제 경로는 \\.\pipe\<name> 이 됩니다.
        std::string name = "iris";

        // 인스턴스 수. **1로 두지 마십시오.** 낡은 인스턴스가 이름을 잡고 있으면
        // 새 서버 생성도 클라이언트 연결도 전부 EACCES(액세스 거부)가 되고,
        // "없음"이 아니라 "거부"라서 원인을 짚기 어렵습니다. 실제로 헤맸습니다.
        uint32_t maxInstances = 4;

        // 한 번에 읽는 크기. 파이프 버퍼와 맞춰 둡니다.
        uint32_t bufferBytes = 1u << 20;
    };

    struct PipeServerCallbacks
    {
        // 전부 **수신 스레드**에서 불립니다.

        // Hello 를 받았을 때. false 를 돌려주면 연결을 거절합니다.
        // ackJson 에 담은 내용이 HelloAck 로 나갑니다.
        std::function<bool(const std::string& helloJson, std::string& ackJson)> onHello;

        // 씬 블롭(.irisb)을 받았을 때. blob 은 이동해서 가져가십시오.
        // false 를 돌려주면 error 가 SyncAck 에 실립니다.
        std::function<bool(std::vector<uint8_t>&& blob, uint32_t flags, std::string& error)> onSceneBlob;

        // 동기화 한 건이 끝났을 때(SyncEnd). 처리 시간을 돌려주면 SyncAck 에 실립니다.
        std::function<void(uint64_t seq)> onSyncEnd;

        // 카메라만 바뀌었을 때. 씬은 건드리지 않습니다.
        std::function<void(const std::string& cameraJson)> onCamera;

        // 진단. 없으면 조용합니다.
        std::function<void(const std::string&)> onLog;
    };

    struct PipeServerStats
    {
        uint64_t connections = 0;
        uint64_t framesIn    = 0;
        uint64_t bytesIn     = 0;
        uint64_t scenesIn    = 0;
        uint64_t camerasIn   = 0;
        uint64_t errors      = 0;
    };

    class PipeServer
    {
    public:
        PipeServer();
        ~PipeServer();

        PipeServer(const PipeServer&)            = delete;
        PipeServer& operator=(const PipeServer&) = delete;

        // 수신 스레드를 띄웁니다. 이미 돌고 있으면 false.
        bool Start(const PipeServerConfig& config, PipeServerCallbacks callbacks);

        // 스레드를 세우고 정리합니다. 대기 중인 연결도 깨웁니다.
        void Stop();

        [[nodiscard]] bool IsRunning() const;
        [[nodiscard]] PipeServerStats GetStats() const;

        // 마지막 오류. 시작 실패 원인을 보려면 이것을 읽으십시오.
        [[nodiscard]] std::string LastError() const;

        // \\.\pipe\<name> 을 만들어 돌려줍니다. 클라이언트가 열 경로입니다.
        [[nodiscard]] static std::string PipePath(const std::string& name);

    private:
        struct Impl;
        std::unique_ptr<Impl> m_impl;
    };
}
