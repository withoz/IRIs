// IRIS — .irisb 리더 시험
//
// 실제 프로젝트 모델(골프존 실내, 36 MB)로 돌립니다. 합성 데이터만으로 시험하면
// 놓치는 것이 있습니다 — RTXPT 세그폴트도 "재질 없는 프리미티브"가 원인이었고
// 합성 데이터에는 전부 재질이 있어서 잡히지 않았습니다.
//
// 기대값은 리더가 아니라 **Python 으로 따로 세어** 얻었습니다.
// 리더가 스스로를 검증하게 두면 시험이 아닙니다.
//
// 사용법:  test_irisb_reader.exe <파일.irisb>

#include "iris/protocol/IrisbReader.h"
#include "iris/bridge/IrisBridge.h"   // HelloAck 조립 (순수 함수)

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace iris::protocol;

namespace
{
    int g_failed = 0;
    int g_passed = 0;

    void Check(bool cond, const std::string& what)
    {
        if (cond)
        {
            ++g_passed;
            std::printf("  [ok]   %s\n", what.c_str());
        }
        else
        {
            ++g_failed;
            std::printf("  [FAIL] %s\n", what.c_str());
        }
    }

    template <typename T>
    void CheckEq(T actual, T expected, const std::string& what)
    {
        const bool ok = (actual == expected);
        if (!ok)
            ++g_failed;
        else
            ++g_passed;
        std::printf("  [%s] %-38s %lld  (기대 %lld)\n", ok ? "ok  " : "FAIL",
                    what.c_str(), (long long)actual, (long long)expected);
    }

    // ⚠ 모델 판본에 기대값을 박지 않습니다.
    //
    // 처음에는 골프존 모델의 수치를 상수로 박아 두었습니다. 그런데 라이브
    // 링크를 붙이고 나니 그 파일이 **사용자가 편집할 때마다 갱신**됩니다.
    // 그러면 시험이 리더가 아니라 모델의 판본을 검사하게 되어 멀쩡한 코드에
    // 헛경보를 냅니다 — 실제로 8건이 그렇게 실패했습니다.
    //
    // 대신 **Ruby 프로브가 센 값과 C++ 리더가 다시 센 값**을 대조합니다.
    // 서로 다른 구현이 같은 답을 내는지 보는 것이므로 교차 검증이 됩니다.
    // 절대 수치는 정보로만 찍습니다.

    void TestErrorPaths(const std::vector<uint8_t>& good)
    {
        std::printf("\n오류 경로\n");
        Scene s;

        // ⚠ 파일 크기를 가정하지 않습니다.
        //
        // 처음에는 good.begin() + 4096 / + 65536 으로 잘랐습니다. 36 MB 모델만
        // 쓰던 동안에는 문제가 없었지만, 6 KB 짜리 합성 씬을 넣자 **끝을 넘어가
        // 시험이 세그폴트로 죽었습니다.** 리더가 아니라 시험의 버그였습니다.
        const size_t head = good.size() < 4096 ? good.size() : size_t(4096);
        const size_t cut  = good.size() < 65537 ? good.size() - 1 : size_t(65536);

        if (good.size() < 64)
        {
            Check(false, "오류 경로 시험에 쓰기엔 파일이 너무 작습니다");
            return;
        }

        {   // 너무 짧음
            ReadResult r = ReadIrisbMemory(good.data(), 16, s);
            Check(!r.ok, "16바이트 입력을 거부한다: " + r.error);
        }
        {   // MAGIC 훼손
            std::vector<uint8_t> bad(good.begin(), good.begin() + head);
            bad[3] = 'X';
            ReadResult r = ReadIrisbMemory(bad.data(), bad.size(), s);
            Check(!r.ok && r.error.find("MAGIC") != std::string::npos,
                  "잘못된 MAGIC 을 거부한다: " + r.error);
        }
        {   // 형식 버전 999
            std::vector<uint8_t> bad(good.begin(), good.begin() + head);
            const uint32_t v = 999;
            std::memcpy(bad.data() + 8, &v, 4);
            ReadResult r = ReadIrisbMemory(bad.data(), bad.size(), s);
            Check(!r.ok && r.error.find("버전") != std::string::npos,
                  "모르는 형식 버전을 거부한다: " + r.error);
        }
        {   // 선언 크기가 파일보다 큼 (잘린 파일)
            std::vector<uint8_t> bad(good.begin(), good.begin() + cut);
            ReadResult r = ReadIrisbMemory(bad.data(), bad.size(), s);
            Check(!r.ok, "잘린 파일을 거부한다: " + r.error);
        }
        {   // 블롭 오프셋을 범위 밖으로 밀어 놓은 매니페스트는 파일을 다시 써야 하므로
            // 여기서는 헤더의 blobBytes 를 0 으로 줄여 같은 효과를 만든다.
            std::vector<uint8_t> bad(good);
            const uint64_t zero = 0;
            std::memcpy(bad.data() + 24, &zero, 8);
            bad.resize(32 + *reinterpret_cast<const uint64_t*>(good.data() + 16));
            ReadResult r = ReadIrisbMemory(bad.data(), bad.size(), s);
            Check(!r.ok && r.error.find("범위") != std::string::npos,
                  "블롭 범위를 벗어난 참조를 거부한다: " + r.error);
        }
    }
}

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::printf("사용법: %s <파일.irisb>\n", argv[0]);
        return 2;
    }
    const std::filesystem::path path = argv[1];

    // 버퍼링을 끕니다. 시험이 죽으면 버퍼에 남은 출력이 통째로 날아가
    // "어디서 죽었는지" 조차 알 수 없습니다 — 실제로 그랬습니다.
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    std::printf("IRIS .irisb 리더 시험\n파일: %s\n\n", path.string().c_str());

    Scene scene;
    const auto t0 = std::chrono::steady_clock::now();
    ReadResult res = ReadIrisbFile(path, scene);
    const auto ms  = std::chrono::duration<double, std::milli>(
                         std::chrono::steady_clock::now() - t0).count();

    if (!res.ok)
    {
        std::printf("읽기 실패: %s\n", res.error.c_str());
        return 1;
    }
    std::printf("읽기 %.1f ms\n", ms);
    for (const auto& w : res.warnings)
        std::printf("  경고: %s\n", w.c_str());

    std::printf("\n머리말\n");
    std::printf("  format=%s version=%s unit=%s up=%s hand=%s\n",
                scene.format.c_str(), scene.version.c_str(), scene.unit.c_str(),
                scene.upAxis.c_str(), scene.handedness.c_str());
    std::printf("  source: %s\n", scene.sourceApp.c_str());

    // --- 리더가 실제로 만든 것을 다시 센다 ---
    size_t   buckets = 0, noMat = 0, childNodes = 0, withUv = 0, withNormals = 0;
    uint64_t tris = 0, verts = 0;

    auto tally = [&](const Definition& d) {
        for (const auto& b : d.meshes)
        {
            ++buckets;
            if (b.materialId.empty()) ++noMat;
            if (!b.uvs.Empty())       ++withUv;
            if (!b.normals.Empty())   ++withNormals;
            tris  += b.TriangleCount();
            verts += b.VertexCount();
        }
        childNodes += d.children.size();
    };
    for (const auto& [id, d] : scene.definitions)
        tally(d);
    tally(scene.root);

    std::printf("\n구조 (정보)\n");
    std::printf("  정의 %zu · 머티리얼 %zu · 뷰 %zu · 버킷 %zu(재질없음 %zu)\n",
                scene.definitions.size(), scene.materials.size(), scene.views.size(),
                buckets, noMat);
    std::printf("  인스턴스 노드 %zu · 삼각형 %llu · 정점 %llu · 블롭 %zu bytes\n",
                childNodes, (unsigned long long)tris, (unsigned long long)verts,
                scene.blob.size());

    // --- 진짜 시험: Ruby 프로브의 집계 대 C++ 리더의 재집계 ---
    std::printf("\n교차 검증 (Ruby 프로브 집계 대 C++ 재집계)\n");
    CheckEq<long long>(tris,  (long long)scene.stats.triangles,   "삼각형 = stats.triangles");
    CheckEq<long long>(verts, (long long)scene.stats.vertices,    "정점 = stats.vertices");
    CheckEq<long long>(childNodes, (long long)scene.stats.instances, "인스턴스 = stats.instances");
    CheckEq<long long>((long long)scene.definitions.size(),
                       (long long)scene.stats.definitions, "정의 = stats.definitions");

    std::printf("\n불변 조건\n");
    Check(!scene.definitions.empty(), "정의가 하나 이상 있다");
    Check(buckets > 0,                "메시 버킷이 하나 이상 있다");
    Check(!scene.blob.empty(),        "블롭이 비어 있지 않다");
    Check(scene.format == "iris.sketchup.scene", "format 이 iris.sketchup.scene 이다");
    Check(scene.unit == "meter",      "단위가 meter 다");
    Check(scene.upAxis == "z",        "up_axis 가 z 다");

    std::printf("\n속성\n");
    std::printf("  법선 있는 버킷 %zu / %zu, UV 있는 버킷 %zu / %zu\n",
                withNormals, buckets, withUv, buckets);
    Check(withNormals == buckets, "모든 버킷에 법선이 있다");

    // --- 데이터가 실제로 읽히는지 ---
    std::printf("\n블롭 접근\n");
    {
        const Definition* d = nullptr;
        for (const auto& [id, def] : scene.definitions)
            if (!def.meshes.empty()) { d = &def; break; }

        Check(d != nullptr, "메시가 있는 정의를 찾았다");
        if (d)
        {
            const MeshBucket& b   = d->meshes.front();
            const float*      pos = scene.Floats(b.positions);
            const uint32_t*   idx = scene.Uints(b.indices);
            Check(pos != nullptr && idx != nullptr, "위치·인덱스 포인터를 얻었다");

            bool finite = true;
            for (uint32_t i = 0; i < b.positions.count; ++i)
                if (!(pos[i] > -1e9f && pos[i] < 1e9f)) { finite = false; break; }
            Check(finite, "위치 값이 유한하고 상식적인 범위다");

            uint32_t maxIdx = 0;
            for (uint32_t i = 0; i < b.indices.count; ++i)
                maxIdx = idx[i] > maxIdx ? idx[i] : maxIdx;
            Check(maxIdx < b.VertexCount(),
                  "최대 인덱스 " + std::to_string(maxIdx) + " < 정점 수 " + std::to_string(b.VertexCount()));
        }
    }

    // --- 조명과 PBR (Enscape) ---
    //
    // 여섯 단계(SketchUp -> 프로브 -> .irisb -> 리더 -> 씬 구축 -> 렌더러)를
    // 지나가는 동안 어느 한 곳이 필드를 흘리면 **오류 없이 조용히** 조명이
    // 사라집니다. 실제로 strip_def 가 떨어뜨릴 뻔했습니다. 여기서 못을 박습니다.
    {
        size_t lights = 0, spots = 0, points = 0, areas = 0, withGeometry = 0;
        double lumens = 0.0;
        bool   badCone = false, badIntensity = false;

        for (const auto& [key, d] : scene.definitions)
        {
            if (!d.light.Valid())
                continue;
            ++lights;
            lumens += d.light.lumens;

            switch (d.light.kind)
            {
            case LightSpec::Kind::Spot:   ++spots;  break;
            case LightSpec::Kind::Point:  ++points; break;
            default:                      ++areas;  break;
            }

            // 광원 프록시에 지오메트리가 남아 있으면 조명 앞에 물체가 뜹니다.
            if (!d.meshes.empty())
                ++withGeometry;

            // 원뿔각은 **반각**입니다. 90도를 넘으면 RTXPT 의 cos 비교가 무너집니다.
            if (d.light.kind == LightSpec::Kind::Spot &&
                !(d.light.outerDeg > 0.0f && d.light.outerDeg < 90.0f &&
                  d.light.innerDeg >= 0.0f && d.light.innerDeg <= d.light.outerDeg))
                badCone = true;

            // NaN·음수는 리더가 걸러야 합니다. 통과하면 광원 선택 가중치가 무너집니다.
            const float v = (d.light.kind == LightSpec::Kind::Spot ||
                             d.light.kind == LightSpec::Kind::Point)
                          ? d.light.intensity : d.light.radiance;
            if (!(v > 0.0f) || !std::isfinite(v))
                badIntensity = true;
        }

        std::printf("\n조명 %zu종 (스포트 %zu · 점 %zu · 면 %zu) · 총 광속 %.0f lm\n",
                    lights, spots, points, areas, lumens);
        if (lights > 0)
        {
            Check(!badCone,      "스포트 원뿔각이 반각 범위(0~90도) 안이다");
            Check(!badIntensity, "모든 광원의 세기가 유한한 양수다");
            CheckEq(withGeometry, size_t(0),
                    "광원 프록시에 남은 지오메트리");
        }

        size_t pbr = 0, emissive = 0;
        bool   badPbr = false;
        for (const auto& m : scene.materials)
        {
            if (!m.pbr.present)
                continue;
            ++pbr;
            if (m.pbr.hasEmissive)
                ++emissive;
            // 리더가 0~1 로 조여야 합니다.
            if (m.pbr.roughness < 0.0f || m.pbr.roughness > 1.0f ||
                m.pbr.metalness < 0.0f || m.pbr.metalness > 1.0f)
                badPbr = true;
        }
        std::printf("PBR 재질 %zu / %zu (발광 %zu)\n", pbr, scene.materials.size(), emissive);
        if (pbr > 0)
            Check(!badPbr, "거칠기·금속성이 0~1 로 조여져 있다");
    }

    // --- 텍스처 ---
    size_t textured = 0, alphaCh = 0, cutout = 0, unmeasured = 0;
    for (const auto& m : scene.materials)
    {
        if (!m.hasTexture) continue;
        ++textured;
        if (m.texture.alphaChannel) ++alphaCh;
        if (m.texture.NeedsAlphaTest()) ++cutout;
        if (m.texture.alphaChannel && m.texture.alphaHoles < 0.0f) ++unmeasured;
    }
    std::printf("\n텍스처 있는 머티리얼 %zu / %zu · 알파 채널 %zu · 컷아웃 %zu (못 잰 것 %zu)\n",
                textured, scene.materials.size(), alphaCh, cutout, unmeasured);

    // --- 합성 배선 씬에 심어 둔 텍스처 알파 (있을 때만) ---
    //
    // 위의 판정 표는 순수 논리만 봅니다. 여기서는 **JSON 을 실제로 읽었는지**
    // 를 봅니다 — 항목 이름이 어긋나면 조용히 기본값으로 떨어지고, 그러면
    // 컷아웃이 전부 사라집니다.
    for (const auto& m : scene.materials)
    {
        if (m.id == "mat_leaf")
        {
            Check(m.texture.alphaChannel,            "mat_leaf: 알파 채널을 읽었다");
            Check(m.texture.alphaMin == 0,           "mat_leaf: 최솟값 0 을 읽었다");
            Check(m.texture.alphaHoles > 0.38f,      "mat_leaf: 구멍 38.6% 를 읽었다");
            Check(m.texture.NeedsAlphaTest(),        "mat_leaf: 컷아웃으로 판정");
        }
        else if (m.id == "mat_tile")
        {
            Check(m.texture.alphaChannel,            "mat_tile: 알파 채널을 읽었다");
            Check(m.texture.alphaHoles == 0.0f,      "mat_tile: 구멍 0 을 읽었다");
            Check(!m.texture.NeedsAlphaTest(),       "mat_tile: 컷아웃 아님");
        }
        else if (m.id == "mat_bigtex")
        {
            Check(m.texture.alphaChannel,            "mat_bigtex: 알파 채널을 읽었다");
            Check(m.texture.alphaHoles < 0.0f,       "mat_bigtex: 구멍은 미지정으로 남았다");
            Check(m.texture.NeedsAlphaTest(),        "mat_bigtex: 못 쟀으므로 컷아웃으로 판정");
        }
    }

    // --- 유리: 단면/덩어리와 굴절률 (합성 배선 씬에 있을 때만) ---
    //
    // 둘 다 Donut 의 Material 에 칸이 없어 오랫동안 버려지던 값입니다.
    // 항목 이름이 어긋나면 조용히 기본값으로 떨어지고, 그러면 모든 유리가
    // 다시 덩어리 1.5 가 됩니다 — 화면으로는 늦게 드러납니다.
    for (const auto& m : scene.materials)
    {
        if (m.id == "mat_glass_thin")
        {
            Check(m.pbr.present,           "mat_glass_thin: Enscape 설정을 읽었다");
            Check(!m.pbr.solidGlass,       "mat_glass_thin: 덩어리가 아니라고 읽었다");
            Check(m.pbr.ior == 0.0f,       "mat_glass_thin: 굴절률은 미지정(0)으로 남았다");
        }
        else if (m.id == "mat_glass_solid")
        {
            Check(m.pbr.solidGlass,                        "mat_glass_solid: 덩어리로 읽었다");
            Check(std::fabs(m.pbr.ior - 1.52f) < 1e-4f,    "mat_glass_solid: 굴절률 1.52 를 읽었다");
        }
        else if (m.id == "mat_water")
        {
            Check(m.pbr.solidGlass,                        "mat_water: 덩어리로 읽었다");
            Check(std::fabs(m.pbr.ior - 1.33f) < 1e-4f,    "mat_water: 굴절률 1.33 을 읽었다");
        }
    }

    // --- 범프: 쓸 그림이 있을 때만 냅니다 (합성 배선 씬에 있을 때만) ---
    //
    // Enscape 가 적어 둔 BumpTexture 경로는 실측 8개 중 8개가 열리지
    // 않았습니다. 세기만 보고 범프를 내면 **그림 없는 범프**가 생깁니다.
    for (const auto& m : scene.materials)
    {
        if (m.id == "mat_grass")
        {
            Check(m.pbr.bump > 0.6f,        "mat_grass: 범프 세기를 읽었다");
            Check(m.pbr.bumpFromDiffuse,    "mat_grass: 디퓨즈를 높이맵으로 쓰라고 읽었다");
            Check(m.pbr.HasBump(),          "mat_grass: 범프를 낼 수 있다");
            Check(m.pbr.bumpType == "DISPLACEMENT", "mat_grass: 종류를 읽었다");
        }
        else if (m.id == "mat_bump_orphan")
        {
            Check(m.pbr.bump > 2.9f,        "mat_bump_orphan: 범프 세기는 있다");
            Check(!m.pbr.bumpFromDiffuse,   "mat_bump_orphan: 쓸 그림이 없다고 읽었다");
            Check(!m.pbr.HasBump(),         "mat_bump_orphan: **범프를 내면 안 된다**");
        }
    }

    // --- 알파 테스트 판정 (순수 논리라 파일이 필요 없습니다) ---
    //
    // 여기서 틀리면 나뭇잎·타공판의 구멍이 막히거나(끄는 쪽으로 틀림),
    // 멀쩡한 텍스처에 애니히트 셰이더가 붙습니다(켜는 쪽으로 틀림).
    // 둘 다 화면으로는 늦게 드러나므로 표로 못박아 둡니다.
    {
        std::printf("\n알파 테스트 판정\n");
        struct Case { bool ch; int mn; float holes; bool want; const char* what; };
        const Case cases[] = {
            { false,  -1, -1.0f,   false, "채널 없음 -> 끔" },
            { false, 255,  0.0f,   false, "채널 없음은 다른 값과 무관" },
            { true,   -1, -1.0f,   true,  "채널 있고 못 쟀으면 -> 켬 (안전한 쪽)" },
            { true,  255,  0.0f,   false, "채널 있으나 구멍 없음 -> 끔" },
            { true,    0,  0.386f, true,  "구멍 38.6% -> 켬 (세종 mat_285 실측)" },
            { true,    0,  0.0005f,false, "구멍이 표본의 0.05% -> 끔 (잡티)" },
            { true,  128,  0.002f, true,  "구멍 0.2% -> 켬" },
        };
        for (const auto& c : cases)
        {
            Texture t;
            t.alphaChannel = c.ch;
            t.alphaMin     = c.mn;
            t.alphaHoles   = c.holes;
            Check(t.NeedsAlphaTest() == c.want, c.what);
        }
    }

    // --- 오류 경로 ---
    {
        std::vector<uint8_t> raw;
        FILE* f = nullptr;
        if (fopen_s(&f, path.string().c_str(), "rb") == 0 && f)
        {
            std::fseek(f, 0, SEEK_END);
            raw.resize((size_t)std::ftell(f));
            std::fseek(f, 0, SEEK_SET);
            const size_t got = std::fread(raw.data(), 1, raw.size(), f);
            std::fclose(f);
            raw.resize(got);
            TestErrorPaths(raw);
        }
    }

    // --- HelloAck 의 칸 ---
    //
    // **빠뜨리면 조용히 망가지는 자리입니다.** 세션 번호를 빠뜨려 델타가
    // 영영 안 켜진 적이 있고, 호스트는 매번 전체를 보내면서도 아무 오류를
    // 보지 못했습니다. 칸 이름 하나하나를 못 박습니다.
    {
        const std::string ack =
            iris::bridge::BuildHelloAck(1, 12345, true, 1920, 1080, 7, true, 2);

        const char* must[] = {
            "\"protocol\":1", "\"accepted\":true", "\"renderer\":\"IRIS\"",
            "\"session\":12345", "\"need_full\":true",
            "\"display_w\":1920", "\"display_h\":1080",
            // 아래 셋이 "보냈는데 화면이 안 바뀐다"를 호스트가 알아채는 근거입니다.
            "\"applied\":7", "\"pending\":true", "\"dropped\":2",
        };
        for (const char* key : must)
            Check(ack.find(key) != std::string::npos,
                  std::string("HelloAck 에 ") + key);

        const std::string off =
            iris::bridge::BuildHelloAck(1, 1, false, 0, 0, 0, false, 0);
        Check(off.find("\"need_full\":false") != std::string::npos, "need_full 거짓도 실린다");
        Check(off.find("\"pending\":false") != std::string::npos, "pending 거짓도 실린다");
        Check(off.find("\"applied\":0") != std::string::npos, "applied 0 도 실린다");
    }

    std::printf("\n────────────────────────────\n통과 %d / 실패 %d\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
