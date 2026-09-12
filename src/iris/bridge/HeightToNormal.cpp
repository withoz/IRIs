#include "HeightToNormal.h"

// stb 는 Donut 이 이미 구현을 컴파일해 두었습니다
// (External/Donut/src/engine/stb_impl.c). 여기서는 **선언만** 가져옵니다 —
// 구현 매크로를 또 정의하면 링크에서 심볼이 겹칩니다.
#include <stb_image.h>
#include <stb_image_write.h>

#include <cmath>
#include <system_error>
#include <vector>

namespace iris::bridge
{
    namespace
    {
        // 높이 기울기를 노멀로 바꿀 때 쓰는 고정 배율.
        //
        // 등급: **가정**. 8비트 높이맵의 중앙차분은 보통 아주 작아서
        // 그대로 쓰면 거의 평평합니다. 4.0 은 눈에 보이면서 과하지 않은
        // 쪽으로 고른 값이고, 화면으로 맞춰 본 적은 없습니다.
        //
        // 세기 조절은 여기가 아니라 엔진의 normalTextureScale 이 합니다 —
        // 그래야 세기를 바꿔도 다시 굽지 않습니다.
        constexpr float kSlopeScale = 4.0f;

        // 가장자리는 되풀이로 봅니다. 텍스처는 이어 붙이는 것이 보통이라
        // 경계에서 자르면 솔기가 생깁니다.
        inline int Wrap(int v, int n)
        {
            if (n <= 0) return 0;
            v %= n;
            return (v < 0) ? v + n : v;
        }
    }

    std::filesystem::path MakeNormalMap(const std::filesystem::path& sourceImage,
                                        bool                         invert,
                                        std::string*                 error)
    {
        auto fail = [&](const std::string& why) -> std::filesystem::path {
            if (error) *error = why;
            return {};
        };

        std::error_code ec;
        if (!std::filesystem::exists(sourceImage, ec) || ec)
            return fail("원본이 없습니다: " + sourceImage.string());

        std::filesystem::path out = sourceImage;
        out.replace_extension();
        out += invert ? ".inv.nrm.png" : ".nrm.png";

        // **캐시.** 원본보다 새것이면 그대로 씁니다. 델타 동기화마다 다시
        // 굽지 않기 위한 것이고, 렌더러를 다시 띄워도 남습니다.
        if (std::filesystem::exists(out, ec) && !ec)
        {
            const auto tSrc = std::filesystem::last_write_time(sourceImage, ec);
            if (!ec)
            {
                const auto tOut = std::filesystem::last_write_time(out, ec);
                if (!ec && tOut >= tSrc)
                    return out;
            }
        }

        // 명암 한 채널로 읽습니다. 색이 입혀진 디퓨즈라도 밝기가 곧 높이라고
        // 봅니다 — Enscape 가 디퓨즈를 범프로 쓰는 것과 같은 해석입니다.
        int w = 0, h = 0, channels = 0;
        stbi_uc* height = stbi_load(sourceImage.string().c_str(), &w, &h, &channels, 1);
        if (height == nullptr)
            return fail(std::string("읽지 못했습니다: ") + (stbi_failure_reason() ? stbi_failure_reason() : "?"));
        if (w <= 1 || h <= 1)
        {
            stbi_image_free(height);
            return fail("너무 작습니다");
        }

        std::vector<unsigned char> normal(static_cast<size_t>(w) * h * 3);

        for (int y = 0; y < h; ++y)
        {
            for (int x = 0; x < w; ++x)
            {
                auto at = [&](int xx, int yy) -> float {
                    const float v = height[static_cast<size_t>(Wrap(yy, h)) * w + Wrap(xx, w)] / 255.0f;
                    return invert ? (1.0f - v) : v;
                };

                // 중앙차분. 소벨까지 갈 필요가 없습니다 — 3x3 가중은 부드럽게
                // 만들 뿐이고, 여기 입력은 이미 사진이라 잡음이 섞여 있습니다.
                const float dx = (at(x + 1, y) - at(x - 1, y)) * 0.5f * kSlopeScale;
                const float dy = (at(x, y + 1) - at(x, y - 1)) * 0.5f * kSlopeScale;

                // 탄젠트 공간: +Z 가 표면 바깥. 기울기가 클수록 눕습니다.
                float nx = -dx, ny = -dy, nz = 1.0f;
                const float len = std::sqrt(nx * nx + ny * ny + nz * nz);
                nx /= len; ny /= len; nz /= len;

                const size_t o = (static_cast<size_t>(y) * w + x) * 3;
                normal[o + 0] = static_cast<unsigned char>((nx * 0.5f + 0.5f) * 255.0f + 0.5f);
                normal[o + 1] = static_cast<unsigned char>((ny * 0.5f + 0.5f) * 255.0f + 0.5f);
                normal[o + 2] = static_cast<unsigned char>((nz * 0.5f + 0.5f) * 255.0f + 0.5f);
            }
        }
        stbi_image_free(height);

        if (stbi_write_png(out.string().c_str(), w, h, 3, normal.data(), w * 3) == 0)
            return fail("쓰지 못했습니다: " + out.string());

        return out;
    }
}
