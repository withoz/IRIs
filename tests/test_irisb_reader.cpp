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

#include <chrono>
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

    // 골프존 실내 모델의 기대값. Python 으로 따로 센 값입니다.
    struct Expected
    {
        size_t   definitions = 706;
        size_t   materials   = 99;
        size_t   views       = 4;
        size_t   buckets     = 555;
        size_t   bucketsNoMaterial = 55;
        size_t   childNodes  = 1155;
        uint64_t triangles   = 400062;
        uint64_t vertices    = 956942;
        size_t   blobBytes   = 35422888;
    };

    void TestErrorPaths(const std::vector<uint8_t>& good)
    {
        std::printf("\n오류 경로\n");
        Scene s;

        {   // 너무 짧음
            ReadResult r = ReadIrisbMemory(good.data(), 16, s);
            Check(!r.ok, "16바이트 입력을 거부한다: " + r.error);
        }
        {   // MAGIC 훼손
            std::vector<uint8_t> bad(good.begin(), good.begin() + 4096);
            bad[3] = 'X';
            ReadResult r = ReadIrisbMemory(bad.data(), bad.size(), s);
            Check(!r.ok && r.error.find("MAGIC") != std::string::npos,
                  "잘못된 MAGIC 을 거부한다: " + r.error);
        }
        {   // 형식 버전 999
            std::vector<uint8_t> bad(good.begin(), good.begin() + 4096);
            const uint32_t v = 999;
            std::memcpy(bad.data() + 8, &v, 4);
            ReadResult r = ReadIrisbMemory(bad.data(), bad.size(), s);
            Check(!r.ok && r.error.find("버전") != std::string::npos,
                  "모르는 형식 버전을 거부한다: " + r.error);
        }
        {   // 선언 크기가 파일보다 큼 (잘린 파일)
            std::vector<uint8_t> bad(good.begin(), good.begin() + 65536);
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

    const Expected e;
    std::printf("\n구조\n");
    CheckEq<long long>(scene.definitions.size(), (long long)e.definitions, "정의");
    CheckEq<long long>(scene.materials.size(),   (long long)e.materials,   "머티리얼");
    CheckEq<long long>(scene.views.size(),       (long long)e.views,       "뷰");
    CheckEq<long long>(buckets,                  (long long)e.buckets,     "메시 버킷");
    CheckEq<long long>(noMat,          (long long)e.bucketsNoMaterial,     "  재질 없는 버킷");
    CheckEq<long long>(childNodes,               (long long)e.childNodes,  "인스턴스 노드");
    CheckEq<long long>(tris,                     (long long)e.triangles,   "삼각형");
    CheckEq<long long>(verts,                    (long long)e.vertices,    "정점");
    CheckEq<long long>(scene.blob.size(),        (long long)e.blobBytes,   "블롭 바이트");

    std::printf("\n매니페스트 stats 와의 일치\n");
    CheckEq<long long>(tris,  (long long)scene.stats.triangles,   "삼각형 = stats.triangles");
    CheckEq<long long>(verts, (long long)scene.stats.vertices,    "정점 = stats.vertices");
    CheckEq<long long>(childNodes, (long long)scene.stats.instances, "인스턴스 = stats.instances");

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

    // --- 텍스처 ---
    size_t textured = 0;
    for (const auto& m : scene.materials)
        if (m.hasTexture) ++textured;
    std::printf("\n텍스처 있는 머티리얼 %zu / %zu\n", textured, scene.materials.size());

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

    std::printf("\n────────────────────────────\n통과 %d / 실패 %d\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
