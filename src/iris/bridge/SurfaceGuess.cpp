#include "SurfaceGuess.h"

#include <algorithm>
#include <cctype>
#include <vector>

namespace iris::bridge
{
    namespace
    {
        // ---------------------------------------------------------------- 낱말

        // 이름을 낱말로 가릅니다. `Metal_Corrogated_Shiny` -> metal, corrogated,
        // shiny. `_wood laminate1` -> wood, laminate. `stone05` -> stone.
        //
        // **왜 부분 문자열이 아니라 낱말인가.** `gold` 를 부분 문자열로 찾으면
        // `golden oak` 가 금이 되고, `tile` 은 `textile` 안에 들어 있습니다.
        // 짧은 영어 낱말은 이런 사고가 흔해서 경계를 지킵니다.
        //
        // 끝의 숫자는 뗍니다 — SketchUp 이 이름 충돌을 숫자로 피하기 때문입니다
        // (`laminate1`, `stone05`, `[Color M07]2`).
        std::vector<std::string> Words(std::string_view name)
        {
            std::vector<std::string> out;
            std::string              cur;
            auto flush = [&] {
                while (!cur.empty() && cur.back() >= '0' && cur.back() <= '9')
                    cur.pop_back();
                if (cur.size() >= 3)
                    out.push_back(cur);
                cur.clear();
            };
            for (const char ch : name)
            {
                const unsigned char u = static_cast<unsigned char>(ch);
                if (u < 0x80 && (std::isalnum(u) != 0))
                    cur.push_back(static_cast<char>(std::tolower(u)));
                else
                    flush();
            }
            flush();
            return out;
        }

        bool HasWord(const std::vector<std::string>& words, const char* w)
        {
            return std::find(words.begin(), words.end(), w) != words.end();
        }

        // 한글은 낱말 경계가 없습니다 — `스테인리스판넬` 처럼 붙여 씁니다.
        // 대신 한글 낱말은 길어서 부분 문자열이 안전합니다.
        bool HasPart(std::string_view name, const char* s)
        {
            return name.find(s) != std::string_view::npos;
        }

        // ------------------------------------------------------------------ 표

        struct Rule
        {
            const char* rule;        // 로그에 남길 이름
            float       roughness;
            float       metalness;
            const char* words[8];    // 영어 낱말 (경계 일치). 끝은 nullptr.
            const char* parts[6];    // 한글 등 (부분 일치). 끝은 nullptr.
        };

        // **순서가 곧 우선순위입니다.** 먼저 걸리는 것이 이깁니다.
        //
        // 값은 전부 **가정**입니다 — 건축 마감의 통상값이고 실측이 아닙니다.
        // 그래서 하나하나 정밀할 필요는 없고, "0.9 가 분명히 아니다"만
        // 맞으면 됩니다. 마음에 안 들면 재질 편집기에서 고치고 저장하면
        // 그 값이 이깁니다(11.6).
        constexpr Rule kRules[] = {
            // 손대지 말라는 표시가 있으면 아무것도 하지 않습니다. 표보다 먼저입니다.
            { "무광", -1.0f, 0.0f,
              { "matte", "matt", nullptr },
              { "무광", nullptr } },

            { "거울", 0.05f, 1.0f,
              { "mirror", nullptr },
              { "거울", nullptr } },

            { "물", 0.05f, 0.0f,
              { "water", nullptr },
              { "수면", nullptr } },

            { "크롬", 0.10f, 1.0f,
              { "chrome", nullptr },
              { "크롬", nullptr } },

            // 반투명 유리는 유리 경로가 따로 처리합니다(SceneBuilder). 여기 오는
            // 것은 이름만 유리인 **불투명** 재질입니다. 그래도 반짝이는 편이 맞습니다.
            { "유리", 0.10f, 0.0f,
              { "glass", nullptr },
              { "유리", nullptr } },

            { "스테인리스", 0.25f, 1.0f,
              { "stainless", nullptr },
              { "스테인리스", "스텐", nullptr } },

            // 유광/광택은 금속성을 건드리지 않습니다 — 유광 도장이 대부분입니다.
            { "유광", 0.25f, 0.0f,
              { "polished", "gloss", "glossy", "shiny", nullptr },
              { "유광", "광택", nullptr } },

            { "황동·구리·청동", 0.30f, 1.0f,
              { "brass", "copper", "bronze", nullptr },
              { "황동", "구리", "청동", nullptr } },

            { "타일·도기", 0.35f, 0.0f,
              { "tile", "ceramic", "porcelain", nullptr },
              { "타일", "세라믹", "도기", nullptr } },

            { "플라스틱·아크릴", 0.35f, 0.0f,
              { "plastic", "acrylic", nullptr },
              { "아크릴", "플라스틱", nullptr } },

            { "연마 석재", 0.45f, 0.0f,
              { "marble", "granite", nullptr },
              { "대리석", "화강석", "화강암", nullptr } },

            { "가죽", 0.55f, 0.0f,
              { "leather", nullptr },
              { "가죽", nullptr } },

            // `maple` 은 뺐습니다 — 이 모델의 `Vegetation_Bark_Maple` 은 나무껍질
            // 이고 마감재가 아닙니다. 낱말 하나로 둘을 못 가릅니다.
            { "목재", 0.65f, 0.0f,
              { "wood", "timber", "oak", "walnut", "birch", "veneer", "laminate", "plywood" },
              { "목재", "우드", "원목", "무늬목", nullptr } },
        };
    }

    SurfaceGuess GuessSurface(std::string_view name, float defaultRoughness, bool useNameRules)
    {
        SurfaceGuess g;
        g.roughness = (defaultRoughness < 0.0f) ? 0.0f
                                                : (defaultRoughness > 1.0f ? 1.0f : defaultRoughness);
        g.metalness = 0.0f;
        g.rule      = nullptr;

        if (!useNameRules || name.empty())
            return g;

        const std::vector<std::string> words = Words(name);

        for (const Rule& r : kRules)
        {
            bool hit = false;
            for (const char* w : r.words)
            {
                if (w == nullptr)
                    break;
                if (HasWord(words, w))
                {
                    hit = true;
                    break;
                }
            }
            if (!hit)
            {
                for (const char* p : r.parts)
                {
                    if (p == nullptr)
                        break;
                    if (HasPart(name, p))
                    {
                        hit = true;
                        break;
                    }
                }
            }
            if (!hit)
                continue;

            // 거칠기가 음수인 규칙은 **손대지 말라**는 뜻입니다(무광).
            // 규칙 이름은 남겨서 로그에 왜 기본값인지 드러냅니다.
            if (r.roughness >= 0.0f)
            {
                g.roughness = r.roughness;
                g.metalness = r.metalness;
            }
            g.rule = r.rule;
            return g;
        }

        return g;
    }
}
