// IRIS — 높이맵을 탄젠트 공간 노멀맵으로
//
// 왜
//   Enscape 는 재질에 `BumpAmount` 와 `BumpTexture` 를 남깁니다. 그런데
//   그 경로는 실측 8개 중 8개가 열리지 않았습니다 — 남의 컴퓨터의 네트워크
//   공유, 다른 사용자의 바탕화면, 임시 폴더(11번 (d)).
//
//   대신 **8개 중 8개가 디퓨즈와 같은 파일**이었고 그 그림은 .skp 안에
//   있어 우리가 이미 PNG 로 내보냅니다. 그래서 그 PNG 를 높이맵으로 읽어
//   노멀맵을 만듭니다.
//
//   엔진이 원하는 것은 노멀맵입니다. 높이맵을 그대로 주면 표면이
//   이상해집니다. BumpMapType 이 BUMP/DISPLACEMENT 인 것이 8개 중 8개라
//   변환은 선택이 아닙니다.
//
// 어디에 두나
//   원본 옆에 `<이름>.nrm.png` 로 굽고 **파일로 캐시**합니다. 델타 동기화가
//   잦고 렌더러를 다시 띄우는 일도 잦으므로, 메모리 캐시만으로는 같은 일을
//   반복합니다. 원본보다 새것이면 그냥 씁니다.
//
// 세기
//   여기서는 **고정 배율로 굽습니다.** 세기는 엔진의 `normalTextureScale`
//   로 곱하는 것이 맞습니다 — 그래야 같은 텍스처에 대해 노멀맵이 하나면
//   되고, 세기를 바꿔도 다시 구울 필요가 없습니다.

#pragma once

#include <filesystem>
#include <string>

namespace iris::bridge
{
    // 높이맵 PNG -> 노멀맵 PNG.
    //
    // `invert` 는 Enscape 의 `IsInverted` 입니다(밝은 곳이 낮은 경우).
    //
    // 반환: 만들어졌거나 이미 있던 노멀맵 경로. 실패하면 빈 경로이고,
    //       `error` 에 이유가 들어갑니다(호출자가 로그로 남깁니다).
    std::filesystem::path MakeNormalMap(const std::filesystem::path& sourceImage,
                                        bool                         invert,
                                        std::string*                 error = nullptr);
}
