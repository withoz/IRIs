// IRIS — 프로토콜 와이어 형식
//
// 명명 파이프 하나 위에 얹는 프레임 형식입니다.
// 설계 배경은 docs/05-씬-델타-프로토콜.md 3·10.1절.
//
// **채널을 둘로 나누지 않았습니다.** 05번 3절은 제어와 벌크를 나눌 것을 고려했지만,
// 실측에서 파이프가 SketchUp Ruby 기준 중간값 758 MB/s 였고 36 MB 씬이 47 ms
// 였습니다. 순서가 보장되는 스트림 하나로 충분하고, 두 채널의 순서를 맞추는
// 복잡함을 살 이유가 없습니다.

#pragma once

#include <cstdint>

namespace iris::protocol
{
    // 모든 프레임의 머리 16바이트. 리틀엔디언.
    //
    //   [0..4)   u32  type
    //   [4..8)   u32  flags
    //   [8..16)  u64  payloadLen
    //   [16..)        payload
    //
    // 페이로드 길이를 u64 로 둔 이유: 씬 블롭이 36 MB 이고 앞으로 더 커집니다.
    struct FrameHeader
    {
        uint32_t type       = 0;
        uint32_t flags      = 0;
        uint64_t payloadLen = 0;
    };

    inline constexpr size_t kFrameHeaderSize = 16;

    enum class MsgType : uint32_t
    {
        None      = 0,

        // --- 호스트 -> 렌더러 ---
        Hello     = 1,   // JSON  { protocol, app, model, unit, up_axis }
        SyncBegin = 3,   // JSON  { seq }
        SceneBlob = 4,   // .irisb 바이트 그대로
        SyncEnd   = 5,   // JSON  { seq }

        // --- 렌더러 -> 호스트 ---
        HelloAck  = 2,   // JSON  { protocol, accepted, renderer, reason }
        SyncAck   = 6,   // JSON  { seq, ok, ms, error }

        // --- 양방향 ---
        Bye       = 7,   // 페이로드 없음

        // 카메라만 갱신합니다. JSON { eye, target, up, fov_deg, fov_is_height, aspect }
        //
        // 시점을 돌릴 때마다 36 MB 씬을 다시 보낼 수는 없습니다. 05번 3절이
        // 말한 "작고 잦은 제어" 가 이것입니다 — 수백 바이트짜리 프레임이고
        // 씬을 다시 세우지 않으므로 렌더러가 즉시 따라옵니다.
        Camera    = 8,
    };

    // SceneBlob 의 flags.
    enum FrameFlags : uint32_t
    {
        // 씬 전체가 아니라 바뀐 정의만 담고 있다는 표시. 받는 쪽은 기존 씬에
        // 병합합니다. 5단계(델타)에서 씁니다 — 2c 에서는 항상 0 입니다.
        FrameFlag_Partial = 1u << 0,
    };

    // 프로토콜 버전. Hello/HelloAck 에서 교환하고 낮은 쪽에 맞춥니다.
    // 필드 추가는 하위 호환, 삭제·의미 변경은 이 값을 올립니다.
    inline constexpr uint32_t kProtocolVersion = 1;

    // 한 프레임이 가질 수 있는 최대 페이로드. 신뢰하지 않는 입력이 터무니없는
    // 길이를 선언해 메모리를 고갈시키는 것을 막습니다.
    // 골프존 실내 모델이 36 MB 이므로 512 MB 면 충분히 여유롭습니다.
    inline constexpr uint64_t kMaxPayloadBytes = 512ull * 1024 * 1024;

    inline void EncodeHeader(const FrameHeader& h, uint8_t out[kFrameHeaderSize])
    {
        auto put32 = [](uint8_t* p, uint32_t v) {
            p[0] = uint8_t(v); p[1] = uint8_t(v >> 8); p[2] = uint8_t(v >> 16); p[3] = uint8_t(v >> 24);
        };
        auto put64 = [](uint8_t* p, uint64_t v) {
            for (int i = 0; i < 8; ++i) p[i] = uint8_t(v >> (8 * i));
        };
        put32(out + 0, h.type);
        put32(out + 4, h.flags);
        put64(out + 8, h.payloadLen);
    }

    inline FrameHeader DecodeHeader(const uint8_t in[kFrameHeaderSize])
    {
        auto get32 = [](const uint8_t* p) -> uint32_t {
            return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
        };
        auto get64 = [](const uint8_t* p) -> uint64_t {
            uint64_t v = 0;
            for (int i = 0; i < 8; ++i) v |= uint64_t(p[i]) << (8 * i);
            return v;
        };
        FrameHeader h;
        h.type       = get32(in + 0);
        h.flags      = get32(in + 4);
        h.payloadLen = get64(in + 8);
        return h;
    }

    inline const char* MsgTypeName(uint32_t t)
    {
        switch (static_cast<MsgType>(t))
        {
        case MsgType::Hello:     return "Hello";
        case MsgType::HelloAck:  return "HelloAck";
        case MsgType::SyncBegin: return "SyncBegin";
        case MsgType::SceneBlob: return "SceneBlob";
        case MsgType::SyncEnd:   return "SyncEnd";
        case MsgType::SyncAck:   return "SyncAck";
        case MsgType::Bye:       return "Bye";
        case MsgType::Camera:    return "Camera";
        default:                 return "(unknown)";
        }
    }
}
