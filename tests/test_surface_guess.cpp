// 거칠기 이름 표 시험 (11번 (g))
//
// 왜 따로 시험하나
//   이 표는 **조용히 틀립니다.** 규칙이 하나 어긋나도 렌더러는 멀쩡히 돌고,
//   화면에서는 "저 벽이 좀 반짝이네" 정도로만 보입니다. 09번 8-i 의
//   "큰 면만 유리" 규칙이 그랬습니다.
//
//   그래서 위험한 쪽을 명시적으로 못 박습니다 — **걸려야 할 것**보다
//   **걸리면 안 되는 것**이 더 중요합니다.
//
// 실행:  test_surface_guess         (인자 없음)

#include "../src/iris/bridge/SurfaceGuess.cpp"

#include <cmath>
#include <cstdio>
#include <string>

namespace
{
    int g_fail = 0;
    int g_ok   = 0;

    void Check(bool cond, const std::string& what)
    {
        if (cond)
        {
            ++g_ok;
        }
        else
        {
            ++g_fail;
            std::printf("  FAIL  %s\n", what.c_str());
        }
    }

    using iris::bridge::GuessSurface;

    // 이름이 기대한 규칙에 걸리고 값이 맞는가.
    void Hit(const char* name, const char* rule, float roughness, float metalness)
    {
        const auto g = GuessSurface(name, 0.9f, true);
        const bool ruleOk =
            (g.rule != nullptr) && (std::string(g.rule) == rule);
        Check(ruleOk, std::string(name) + " -> 규칙 '" + rule + "' (실제 '" +
                          (g.rule ? g.rule : "(없음)") + "')");
        Check(std::fabs(g.roughness - roughness) < 1e-4f,
              std::string(name) + " -> 거칠기 " + std::to_string(roughness) +
                  " (실제 " + std::to_string(g.roughness) + ")");
        Check(std::fabs(g.metalness - metalness) < 1e-4f,
              std::string(name) + " -> 금속성 " + std::to_string(metalness) +
                  " (실제 " + std::to_string(g.metalness) + ")");
    }

    // 아무 규칙도 걸리지 않고 기본값으로 가는가.
    void Miss(const char* name)
    {
        const auto g = GuessSurface(name, 0.9f, true);
        Check(g.rule == nullptr,
              std::string(name) + " -> 규칙 없음 (실제 '" +
                  (g.rule ? g.rule : "(없음)") + "')");
        Check(std::fabs(g.roughness - 0.9f) < 1e-4f,
              std::string(name) + " -> 기본값 0.9 (실제 " +
                  std::to_string(g.roughness) + ")");
        Check(g.metalness == 0.0f, std::string(name) + " -> 금속성 0");
    }
}

int main()
{
    std::printf("거칠기 이름 표\n");

    // ---------------------------------------------------------------- 걸려야 함
    //
    // 이 모델에 실제로 있는 이름입니다(out/sketchup/rough_probe.txt [4]절).
    Hit("_leather, fawn brown", "가죽", 0.55f, 0.0f);   // 24,261면 — 표의 최대 수혜
    Hit("_wood laminate1",      "목재", 0.65f, 0.0f);
    Hit("Natural birch",        "목재", 0.65f, 0.0f);
    Hit("GLASS-2",              "유리", 0.10f, 0.0f);
    Hit("Metal_Corrogated_Shiny", "유광", 0.25f, 0.0f);

    // 한글은 낱말 경계가 없어 부분 문자열로 찾습니다.
    Hit("스테인리스 판넬", "스테인리스", 0.25f, 1.0f);
    Hit("크롬도금",       "크롬",       0.10f, 1.0f);
    Hit("대리석바닥",     "연마 석재",  0.45f, 0.0f);
    Hit("무늬목 마감",    "목재",       0.65f, 0.0f);

    // ------------------------------------------------------------ 걸리면 안 됨
    //
    // **여기가 이 시험의 요점입니다.**

    // 1. 흰 도장을 금속으로 만들면 흰 거울이 됩니다. `metal`·`steel`·
    //    `aluminum` 은 건축에서 도장 판넬을 가리킬 때가 더 많아 뺐습니다.
    Miss("Metal_Seamed");
    Miss("Steel Frame");
    Miss("Aluminum Composite Panel");

    // 2. 짧은 영어 낱말은 다른 낱말 안에 들어앉습니다. 부분 문자열로 찾으면
    //    전부 오탐입니다.
    Miss("PDM_Cotton_woven_01");   // 'wove(n)' 안에 든 것이 아님 — 목재 아님
    Miss("textile blue");          // 'tile' 이 'textile' 안에 있습니다
    Miss("golden retriever");      // 'gold' 는 표에 없지만 경계 확인용
    Miss("Woodland Path");         // 'woodland' 는 'wood' 가 아닙니다

    // 3. 나무껍질은 마감재가 아닙니다. 그래서 'maple' 을 표에서 뺐습니다.
    Miss("Vegetation_Bark_Maple");
    Miss("Vegetation_Bark_PaloVerde");

    // 4. 뜻 없는 이름 — 이 모델 면 수의 67%가 이 여섯입니다.
    Miss("pro_02");
    Miss("t_01");
    Miss("Color M08");
    Miss("Material~29");
    Miss("재질141");
    Miss("<auto>3");

    // ------------------------------------------------------------ 무광 표시
    //
    // 손대지 말라는 표시가 있으면 표보다 먼저입니다. 규칙 이름은 남겨서
    // 로그에 "왜 기본값인지"가 드러나게 합니다.
    {
        const auto g = GuessSurface("무광 우드", 0.9f, true);
        Check(g.rule != nullptr && std::string(g.rule) == "무광",
              "'무광 우드' -> 무광 규칙이 목재보다 먼저");
        Check(std::fabs(g.roughness - 0.9f) < 1e-4f, "'무광 우드' -> 기본값 유지");
    }
    {
        const auto g = GuessSurface("Matte Chrome", 0.9f, true);
        Check(g.rule != nullptr && std::string(g.rule) == "무광",
              "'Matte Chrome' -> 무광이 크롬보다 먼저");
        Check(g.metalness == 0.0f, "'Matte Chrome' -> 금속성 건드리지 않음");
    }

    // ---------------------------------------------------------------- 표 끄기
    //
    // A/B 하려면 표를 통째로 끌 수 있어야 합니다.
    {
        const auto g = GuessSurface("_leather, fawn brown", 0.9f, false);
        Check(g.rule == nullptr, "표를 끄면 규칙이 걸리지 않습니다");
        Check(std::fabs(g.roughness - 0.9f) < 1e-4f, "표를 끄면 기본값");
    }

    // ------------------------------------------------------------ 기본값 전달
    //
    // 기본값은 설정에서 옵니다. 옛 값(0.5)으로도 돌 수 있어야 A/B 가 됩니다.
    {
        const auto g = GuessSurface("pro_02", 0.5f, true);
        Check(std::fabs(g.roughness - 0.5f) < 1e-4f, "기본값 0.5 가 그대로 전달됩니다");
    }
    {
        const auto g = GuessSurface("pro_02", 2.0f, true);
        Check(std::fabs(g.roughness - 1.0f) < 1e-4f, "기본값은 [0,1] 로 조입니다");
    }
    {
        const auto g = GuessSurface("", 0.9f, true);
        Check(g.rule == nullptr, "빈 이름은 기본값");
    }

    std::printf("\n확인 %d개 통과", g_ok);
    if (g_fail)
    {
        std::printf(", **%d개 실패**\n", g_fail);
        return 1;
    }
    std::printf(", 실패 없음\n");
    return 0;
}
