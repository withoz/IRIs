// IRIS — .irisb 씬을 Donut SceneGraph 로 세운다.
//
// 여기가 IRIS 코드가 엔진과 처음 만나는 지점입니다. 리더(iris_protocol)는
// 엔진을 모르고, 이 계층만 Donut 을 압니다.
//
// 지금까지의 경로:
//     .irisb -> iris_json_to_gltf.py -> .glb(85 MB) -> Donut glTF 로더
// 이 계층이 하는 일:
//     .irisb -> IrisbReader -> SceneGraph
// 파이썬 변환과 디스크 왕복이 사라집니다.

#pragma once

#include <donut/engine/SceneGraph.h>
#include <donut/engine/SceneTypes.h>

#include <filesystem>
#include <functional>
#include <map>
#include <set>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace donut::engine
{
    class TextureCache;
    struct LoadedTexture;
}

namespace iris::protocol
{
    struct Scene;
    struct Definition;
    struct Node;
    struct LightSpec;
}

namespace iris::bridge
{
    struct BuildStats
    {
        size_t   meshes      = 0;   // 지오메트리를 가진 정의 = MeshInfo 개수
        size_t   geometries  = 0;   // 메시 버킷 = MeshGeometry 개수
        size_t   instances   = 0;   // MeshInstance 개수
        size_t   materials   = 0;
        size_t   textures    = 0;
        size_t   glassMaterials = 0;   // 반투명 + 텍스처 없음 -> 유리로 해석
        size_t   pointLights    = 0;
        size_t   spotLights     = 0;   // 면광원 근사도 여기에 포함됩니다
        bool     hasSun         = false;
        float    sunIrradiance  = 0.0f;   // lux
        float    sunElevationDeg = 0.0f;  // 0 이하면 밤입니다
        // 태양을 향하는 단위 벡터. **엔진 월드(Y-up)** 입니다.
        //
        // 하늘은 여기서 다시 자기 좌표로 바꿉니다 — EnvMapBaker.hlsl 이
        // cubeDir 에 적용하는 것과 같은 변환(Y·Z 맞바꾸기)을 씁니다.
        // 그 변환을 여기서 미리 하면 두 곳에 같은 규칙이 흩어집니다.
        float    sunDirYUp[3]   = { 0.0f, 1.0f, 0.0f };
        size_t   mirroredNodes  = 0;   // 행렬식이 음수인 노드 = 거울 배치
        size_t   meshesReused   = 0;   // 델타: 다시 만들지 않고 재사용한 정의
        size_t   meshesMissing  = 0;   // 델타: 재사용해야 하는데 캐시에 없던 것 (전체 재동기화 필요)
        size_t   emissiveMaterials = 0;   // Enscape 자체발광
        size_t   emissiveTextures  = 0;   // 그중 그림째로 빛나는 것 (11번 (e))
        size_t   areaLights        = 0;   // 발광 지오메트리로 낸 면광원
        size_t   iesProfiles       = 0;   // 텍스처로 구운 IES 배광 (고유 개수)
        size_t   iesLights         = 0;   // 그 배광을 쓰는 광원 수
        size_t   specularOverrides = 0;   // Specular 가 0.5 가 아닌 재질
        size_t   invisibleMaterials = 0;  // 알파 0 — 호스트에서 안 보임
        size_t   authorGlass        = 0;  // Enscape 가 유리라고 한 것
        size_t   authorTranslucent  = 0;  // Enscape 가 **유리가 아니라고** 한 반투명 (알파 블렌드)
        size_t   authorOpacity      = 0;  // Enscape 불투명도가 SketchUp 알파를 덮은 것
        size_t   cutoutMaterials    = 0;  // 텍스처 알파로 구멍을 내는 재질 (알파 테스트)
        size_t   cutoutUnmeasured   = 0;  // 그중 프로브가 픽셀을 못 재서 켠 것
        size_t   thinGlass          = 0;  // 단면으로 본 유리 (ThinSurface)
        size_t   solidGlass         = 0;  // 두께 있는 덩어리로 본 유리 (Enscape 지정)
        size_t   authorIor          = 0;  // Enscape 굴절률을 쓴 재질
        size_t   bumpMaterials      = 0;  // 높이맵에서 구운 노멀맵을 쓴 재질
        size_t   bumpSkipped        = 0;  // 범프 세기는 있는데 쓸 그림이 없던 것

        // **Enscape 값이 없는 재질을 어떻게 추측했나** (11번 (g)).
        // 어떤 규칙이 몇 개를 잡았는지 남깁니다 — 규칙이 조용히 오작동하면
        // 화면만 보고는 알 수 없기 때문입니다.
        std::map<std::string, size_t> surfaceRules;            // 규칙 이름 -> 재질 수
        size_t                        surfaceDefaulted = 0;    // 규칙 없이 기본값으로 간 것
        double   lightLumens    = 0.0;    // 광원 총 광속. 노출 감각용
        uint64_t triangles   = 0;
        uint64_t vertices    = 0;
        size_t   cameras     = 0;
        bool     hasEnvLight = false;
        size_t   maxDepth    = 0;
        size_t   inheritingBuckets = 0;   // 재질이 없어 상속 대상인 버킷
        size_t   overriddenSubInstances = 0;   // 인스턴스 재질이 실제로 적용된 (인스턴스×지오메트리)
        double   buildMs     = 0.0;

        std::vector<std::string> warnings;
    };

    // Donut SceneGraph 를 만듭니다. GPU 자원은 건드리지 않습니다 —
    // 버퍼 생성과 업로드는 Scene::RefreshBuffers 가 합니다.
    class SceneBuilder
    {
    public:
        SceneBuilder(std::shared_ptr<donut::engine::SceneTypeFactory> typeFactory,
                     std::shared_ptr<donut::engine::TextureCache>     textureCache,
                     std::filesystem::path                            baseDir);

        // 단계별 진행 보고. 렌더러 안에서 죽으면 stdout 이 남지 않으므로
        // 어디까지 갔는지 알 방법이 필요합니다. 설정하지 않으면 아무 일도 없습니다.
        void SetTrace(std::function<void(const std::string&)> trace) { m_trace = std::move(trace); }

        // **SketchUp 모델에는 광원이 하나도 없습니다.** 태양과 앰비언트만 있고
        // 그것도 씬 데이터로 나오지 않습니다. 광원 없이 패스트레이싱하면 화면이
        // 완전히 검게 나옵니다 — 실제로 그렇게 나왔습니다.
        //
        // 그래서 기본 환경광(하늘)을 넣습니다. 건축 렌더러가 모델을 열었을 때
        // 무언가 보이는 것이 옳은 기본값이기도 합니다. 경로가 비면 넣지 않습니다.
        // 본격적인 조명 시스템은 Phase 1 4단계입니다.
        void SetEnvironmentMap(std::string path) { m_environmentMap = std::move(path); }

        // 텍스처를 어떻게 얻을지 바깥에서 정할 수 있게 합니다.
        //
        // 기본은 엔진의 TextureCache 를 직접 부르는 것인데, 그 캐시는 **씬을
        // 로드할 때마다 비워집니다.** 라이브 갱신에서는 같은 텍스처를 매번 다시
        // 디코드하게 되므로(실측 구축 656 ms 중 638 ms), 호출자가 프로세스
        // 수명 캐시를 끼워 넣을 수 있어야 합니다.
        // ⚠ `sRGB` 를 반드시 넘기십시오. 색 텍스처는 sRGB 이고 **노멀맵은
        //   선형**입니다. 섞으면 범프가 엉뚱한 방향으로 눕습니다.
        using TextureLoader =
            std::function<std::shared_ptr<donut::engine::LoadedTexture>(
                const std::filesystem::path&, bool /*sRGB*/)>;
        void SetTextureLoader(TextureLoader loader) { m_textureLoader = std::move(loader); }

        // **재질 상속** — SketchUp 에서 면에 재질이 없으면 상위 인스턴스의 재질을
        // 씁니다. 같은 정의가 인스턴스마다 다른 색으로 보일 수 있습니다.
        //
        // glTF 는 이것을 못 합니다. 메시가 인스턴스 간 공유되므로 재질을 메시에
        // 박아야 하고, 인스턴스별로 다르게 하려면 메시를 복제해야 해서 인스턴싱
        // 이득이 사라집니다([05번 5절](../../docs/05-씬-델타-프로토콜.md)).
        //
        // 레이트레이서는 할 수 있습니다. RTXPT 는 재질 인덱스를
        // **서브인스턴스(인스턴스×지오메트리) 단위**로 들고 있습니다
        // (SubInstanceData::GlobalGeometryIndex_PTMaterialDataIndex).
        // 지오메트리는 한 벌만 두고 인스턴스마다 다른 재질을 낼 수 있습니다.
        //
        // 이 계층은 RTXPT 타입을 몰라야 하므로 **적용은 호출자에게 넘깁니다.**
        // 넘기는 벡터는 지오메트리 개수와 같은 길이이고, 덮어쓸 자리만 채워집니다.
        using InstanceMaterialApplier =
            std::function<void(donut::engine::MeshInstance&,
                               std::vector<std::shared_ptr<donut::engine::Material>>&&)>;
        void SetInstanceMaterialApplier(InstanceMaterialApplier fn) { m_applyInstanceMaterials = std::move(fn); }

        // **Donut 머티리얼에 칸이 없는 값들.**
        //
        // 호스트는 알고 있는데 `donut::engine::Material` 에 담을 곳이 없어
        // 버려지던 것들입니다. RTXPT 의 `PTMaterial` 에는 자리가 있습니다:
        //
        //   ThinSurface  단면인가 두께가 있는 덩어리인가. 셰이더에서 이 깃발은
        //                굴절률을 1 로 바꿔치기하고(BxDF.hlsli) 중첩 유전체
        //                스택을 건너뜁니다. 건축 유리는 거의 **한 장의 면**
        //                이라 두께 있는 매질로 다루면 굴절·흡수가 어긋납니다.
        //   IoR          Enscape 의 IndexOfRefraction. `ImportFromDonut` 에서
        //                주석 처리되어 있어(Donut 에 필드가 없습니다) 지금까지
        //                전부 1.5 였습니다.
        //
        // 이 계층은 RTXPT 타입을 몰라야 하므로 **적용은 호출자에게 넘깁니다** —
        // 인스턴스 재질과 같은 방식입니다. 결합이 IrisScene.cpp 한 곳에만
        // 남습니다(11번 11.6).
        struct MaterialHints
        {
            bool  thinSurface = true;    // 단면으로 볼 것인가
            float ior         = 0.0f;    // 0 이면 미지정 — 엔진 기본값(1.5)을 둡니다

            // **탄젠트를 안 보냅니다.** `.irisb` 에는 위치·법선·UV·인덱스만
            // 들어 있습니다. 노멀맵을 쓰려면 엔진이 UV 미분에서 탄젠트를
            // 만들어야 합니다(PTMaterial::IgnoreMeshTangentSpace).
            // 정점에 탄젠트를 싣는 것보다 싸고 전송량도 안 늘어납니다.
            bool  ignoreMeshTangentSpace = false;
        };
        using MaterialHintApplier =
            std::function<void(donut::engine::Material&, const MaterialHints&)>;
        void SetMaterialHintApplier(MaterialHintApplier fn) { m_applyMaterialHints = std::move(fn); }

        // **측광 단위 -> 렌더러 라디언스 단위.**
        //
        // Enscape 값은 물리 단위입니다(cd, cd/m^2). 렌더러는 그렇지 않습니다 —
        // 환경맵의 하늘이 대략 1.0 인 스케일로 돌아갑니다. 실제 흐린 하늘은
        // 약 5000 cd/m^2 이므로 그 비율로 옮깁니다.
        //
        // 이 값이 맞는지는 **상대 비율**이 더 중요합니다. 절대 밝기는 노출이
        // 흡수하고, 조명끼리·발광 재질끼리의 균형은 이 한 값으로 보존됩니다.
        // 확인: 천장 패널 5076 cd/m^2 -> 1.02 (하늘과 비슷한 밝기. 맞습니다)
        //
        // 미결정 B(PBR·측광 범위)에서 정식화합니다.
        // **맑은 날 정오의 직달 일사 조도(lux).**
        //
        // SketchUp 은 태양 방향만 주고 세기는 주지 않습니다. 물리 표준값을
        // 기본으로 쓰고, 측광 변환(SetPhotometricScale)을 함께 통과시켜
        // 인공 조명과 같은 척도 위에 놓습니다.
        //
        // 확인: 100,000 lux -> 흰 확산면의 휘도 0.8*100000/pi = 25,465 cd/m^2
        //       -> 렌더러 단위 5.1. 하늘(약 1.0)의 5배. 맑은 날의 대비입니다.
        void SetSunIrradiance(float lux) { m_sunIrradiance = lux; }

        // 참이면 태양을 **방향광으로 만들지 않습니다.** 하늘(절차적 하늘)이
        // 태양을 그리고, 우리는 방향만 넘깁니다. 둘 다 만들면 그림자가 둘입니다.
        void SetSkyOwnsSun(bool v) { m_skyOwnsSun = v; }

        void SetPhotometricScale(float cdPerUnit)
        {
            m_photometricScale = (cdPerUnit > 1e-6f) ? (1.0f / cdPerUnit) : 1.0f;
        }

        // **델타** — 이전 동기화에서 만든 메시를 넘겨받습니다.
        //
        // 호스트는 바뀐 정의의 지오메트리만 보냅니다. 나머지는 `geom: "same"`
        // 으로 표시되어 오고, 그때는 여기 있는 것을 그대로 씁니다.
        //
        // 텍스처 캐시와 같은 이유로 **바깥에서** 소유합니다 — 이 빌더는 동기화
        // 한 번마다 새로 만들어지므로 스스로는 아무것도 기억하지 못합니다.
        //
        // 상속 마스크(m_inherits)도 함께 넘어갑니다. 인스턴스 재질을 어느
        // 지오메트리 자리에 꽂을지가 거기 들어 있고, 메시를 다시 만들지 않으면
        // 그 정보도 다시 만들어지지 않기 때문입니다.
        struct MeshCache
        {
            std::unordered_map<std::string, std::shared_ptr<donut::engine::MeshInfo>> meshes;
            std::unordered_map<std::string, std::vector<bool>>                        inherits;
        };
        void SetMeshCache(std::shared_ptr<MeshCache> cache) { m_meshCache = std::move(cache); }

        // **IES 배광을 텍스처로 굽는 일은 엔진이 합니다.**
        //
        // SceneBuilder 는 장치를 모릅니다(텍스처도 SetTextureLoader 로 받습니다).
        // 같은 방식으로, 격자를 넘기면 bindless 색인을 돌려주는 함수를 받습니다.
        // 색인이 -1 이면 원뿔 근사로 돌아갑니다.
        //
        // 굽기와 **광원에 달기**를 한 번에 맡깁니다. 색인을 받아 SpotLightEx 에
        // 넣으려면 브리지가 엔진 타입을 알아야 하는데, 그러면 순환 의존입니다
        // (IrisScene 이 엔진 안에 있는 이유와 같습니다).
        //
        // key 는 같은 배광을 두 번 굽지 않으려는 것입니다 — 골프존 모델은
        // 정의 4종이 같은 Bega 8331 하나를 씁니다. 캐시도 엔진이 듭니다.
        //
        // 참이면 배광이 달렸다는 뜻이고, 그때는 원뿔을 넓혀 배광이 잘리지
        // 않게 합니다.
        using IesApplier = std::function<bool(donut::engine::SpotLight& light,
                                              const std::string& key,
                                              const float* data,
                                              uint32_t width, uint32_t height)>;
        void SetIesApplier(IesApplier f) { m_iesApplier = std::move(f); }

        // **면광원을 발광 지오메트리로 낼 것인가. 기본은 아니오입니다.**
        //
        // 호스트는 둘을 이미 갈라 놓았습니다. 그 구분을 지키는 것이 이
        // 설정의 전부입니다.
        //
        //   재질(자체발광)   눈에 보이는 빛나는 표면. 저작자가 모델링한
        //                    것입니다 — 코브 조명 띠, 시뮬레이터 스크린,
        //                    간판. **우리가 그립니다.**
        //   조명(Enscape)    빛만 내는 장치. 기구가 아니라 도구입니다.
        //                    **Enscape 는 이것을 절대 그리지 않습니다.**
        //
        // 켜면 사각·선형 광원이 발광 사각형이 됩니다. 물리적으로는 더
        // 맞습니다 — 모양도, 길쭉함도, 코사인 감쇠도. 근사(88도 원뿔 +
        // 등가 면적 구면)가 틀리는 것이 그 셋입니다:
        //
        //   모양      반사에 원형으로 비칩니다. 사각이어야 합니다.
        //   길쭉함    선형 광원(0.02 x 2 m)이 반지름 0.11 m 공이 됩니다.
        //   코사인    구는 원뿔 안에서 고르게 내보냅니다. 패널은 기울면
        //             겉보기 면적이 줄어 어두워져야 합니다.
        //
        // 그런데 **그리는 순간 뒤를 가립니다.**
        //
        // 2026-09-12, 골프존 모델에서 걸렸습니다. 사용자가 화면을 보고
        // 짚었습니다 — "조명을 벽으로 표현하고 있어요". 선택해 보니:
        //
        //   Enscape.RectangularLight  3.0 x 2.45 m (7.35 m²) · 2,831.6 lm
        //
        // 이런 것이 **4개**. 골프 시뮬레이터 스크린 바로 앞에 놓여 있어,
        // 발광 사각형으로 바꾸는 순간 스크린을 통째로 덮었습니다. Enscape
        // 화면에는 골프 코스 영상이 나오고 우리 화면에는 회색 판이었습니다
        // (out/rtxpt/IRIS_vs_Enscape_3.png).
        //
        // 7.35 m² 짜리 조명 기구는 건축에 없습니다. 저것은 기구가 아니라
        // **스크린을 빛나게 하려고 놓은 장치**이고, 스크린 지오메트리는
        // 이미 있습니다. 그리면 안 되는 것이었습니다.
        //
        // ⚠ `PTMaterial::SkipRender` 로 "빛은 내되 안 그리기"를 해 보려
        //   했는데 **안 됩니다.** 헤더 주석이 "hidden emissives 에도 쓸 수
        //   있다"고 적어 두었지만, 실제로는 LightsBaker 도 같은 깃발로
        //   발광을 건너뜁니다(LightsBaker.cpp:875). 지오메트리와 빛이
        //   **같이** 사라집니다.
        //
        // 예전 근거는 우리 두 선택지끼리 견준 것이었습니다(09번 8-f,
        // 포르쉐 성수 1F: OFF 동그란 빛 웅덩이 / ON 사각 패널, 성능 동일).
        // 기구를 모델링하지 않은 모델에서는 그 판단이 맞습니다. 그래서
        // 설정은 남겨 둡니다 — 다만 **기본은 Enscape 와 같게** 둡니다.
        //
        // 끄려면 IRIS_AREA_LIGHTS=0, 켜려면 설정 또는 IRIS_AREA_LIGHTS=1.
        void SetAreaLightGeometry(bool on) { m_areaLightGeometry = on; }

        // **유리의 거칠기.**
        //
        // SketchUp 은 거칠기를 주지 않습니다. Enscape 값이 있으면 그걸 쓰고,
        // 없을 때 무엇으로 둘지가 남습니다. 지금까지 0.05(연마 판유리)로
        // 박혀 있었는데 **근거가 없습니다** — 재고 정한 값이 아닙니다.
        //
        // 숨은 상수로 두는 대신 밖으로 뺍니다. 프로젝트마다 커튼월이 맑은
        // 유리일 수도, 반투명 스크린일 수도 있습니다.
        void SetGlassRoughness(float r) { m_glassRoughness = (r < 0.0f) ? 0.0f : (r > 1.0f ? 1.0f : r); }

        // 텍스처 알파 채널로 구멍을 낼 것인가(알파 테스트) — 11번 (a).
        // 실제로 구멍이 있는 텍스처만 대상입니다(Texture::NeedsAlphaTest).
        void SetAlphaCutout(bool on) { m_alphaCutout = on; }

        // **Enscape 값이 없을 때** 유리를 단면으로 볼 것인가 — 11번 (b).
        // Enscape 가 IsSolidGlass 를 말했으면 그 값이 이깁니다.
        void SetGlassThinDefault(bool thin) { m_glassThinDefault = thin; }

        // **Enscape 값이 없을 때 쓸 거칠기** — 11번 (g).
        //
        // 0.9 는 같은 모델의 Enscape 재질 27벌에서 잰 값입니다(SurfaceGuess.h).
        // 지금까지 쓰던 0.5 는 근거가 없었고 실측 분포의 가장 반짝이는 끝입니다.
        // **씬을 다시 받아야** 적용됩니다.
        void SetRoughnessDefault(float r) { m_roughnessDefault = (r < 0.0f) ? 0.0f : (r > 1.0f ? 1.0f : r); }

        // 이름 표를 쓸 것인가 — 11번 (g). 끄면 전부 기본값으로 갑니다.
        void SetSurfaceNameRules(bool on) { m_surfaceNameRules = on; }

        // 범프 세기 배율. Enscape 의 BumpAmount(0.1~3.0)를 엔진의
        // normalTextureScale 로 옮길 때 곱합니다 — 대응은 **가정**이라
        // 밖으로 뺐습니다(11번 (d)).
        void SetBumpStrength(float k) { m_bumpStrength = (k < 0.0f) ? 0.0f : k; }
        [[nodiscard]] bool AreaLightGeometry() const { return m_areaLightGeometry; }

        // baseDir 은 텍스처 상대경로의 기준입니다 (.irisb 가 있던 디렉터리).
        std::shared_ptr<donut::engine::SceneGraph> Build(const protocol::Scene& src, BuildStats& stats);

    private:
        std::function<void(const std::string&)> m_trace;
        std::string                             m_environmentMap;
        float                                   m_photometricScale = 1.0f / 5000.0f;
        float                                   m_sunIrradiance    = 100000.0f;
        bool                                    m_skyOwnsSun       = false;
        TextureLoader                           m_textureLoader;
        InstanceMaterialApplier                 m_applyInstanceMaterials;
        MaterialHintApplier                     m_applyMaterialHints;
        void Trace(const std::string& msg) const { if (m_trace) m_trace(msg); }

        std::shared_ptr<donut::engine::SceneTypeFactory> m_typeFactory;
        std::shared_ptr<donut::engine::TextureCache>     m_textureCache;
        std::filesystem::path                            m_baseDir;

        std::unordered_map<std::string, std::shared_ptr<donut::engine::Material>> m_materials;
        std::shared_ptr<donut::engine::Material>                                  m_defaultMaterial;
        std::unordered_map<std::string, std::shared_ptr<donut::engine::MeshInfo>> m_meshes;

        // 정의별로 "이 버킷은 재질을 상속한다"를 기록합니다. 지오메트리 순서와
        // 같은 길이이며, 인스턴스 재질을 어디에 꽂을지 정하는 데 씁니다.
        std::unordered_map<std::string, std::vector<bool>> m_inherits;

        std::shared_ptr<MeshCache> m_meshCache;

        bool BuildAreaLightGeometry(const std::shared_ptr<donut::engine::SceneGraph>& graph,
                                    const std::shared_ptr<donut::engine::SceneGraphNode>& node,
                                    const protocol::LightSpec& spec,
                                    BuildStats& stats);
        std::shared_ptr<donut::engine::MeshInfo> AreaQuadMesh(const protocol::LightSpec& spec,
                                                              BuildStats& stats);

        bool  m_areaLightGeometry = false;   // Enscape 는 광원 프록시를 안 그립니다
        float m_glassRoughness    = 0.05f;
        bool  m_alphaCutout       = false;
        bool  m_glassThinDefault  = true;
        float m_bumpStrength      = 1.0f;
        float m_roughnessDefault  = 0.9f;   // 11번 (g) — 실측 기본값
        bool  m_surfaceNameRules  = true;
        // 노멀맵을 쓰는 재질이 하나라도 있으면 참. 그때만 탄젠트를 만듭니다
        // (정점당 4바이트). BuildMaterials 가 켜고 BuildMeshes 가 봅니다.
        bool  m_anyNormalMap      = false;
        // 저장된 재질 덮어쓰기를 모델별로 가르는 키. BuildMaterials 가 채웁니다.
        std::string m_modelKey;
        IesApplier m_iesApplier;
        std::set<std::string> m_iesKeys;   // 고유 배광 개수 세기
        // 라디언스·색이 같으면 같은 메시를 씁니다. 단위 사각형 하나를
        // 인스턴스마다 (w, l, 1) 로 늘려 쓰므로 BLAS 도 재사용됩니다.
        std::unordered_map<std::string, std::shared_ptr<donut::engine::MeshInfo>> m_areaQuads;

        void BuildMaterials(const protocol::Scene& src, BuildStats& stats);

        // 지오메트리가 있는 정의마다 MeshInfo 를 하나 만듭니다. 인스턴스가 여럿이어도
        // MeshInfo 는 하나이고, 그것이 BLAS 재사용의 근거입니다.
        std::shared_ptr<donut::engine::MeshInfo> BuildMesh(const protocol::Scene& src,
                                                           const protocol::Definition& def,
                                                           BuildStats& stats);

        void BuildNodes(const protocol::Scene& src,
                        const std::shared_ptr<donut::engine::SceneGraph>& graph,
                        const std::shared_ptr<donut::engine::SceneGraphNode>& parent,
                        const std::vector<protocol::Node>& children,
                        int depth, BuildStats& stats);

        // 인스턴스에 지정된 재질을, 정의 안의 "재질 없는" 버킷 자리에 꽂습니다.
        void ApplyInheritedMaterial(donut::engine::MeshInstance& instance,
                                    const std::string& defId,
                                    const std::string& instanceMaterialId,
                                    BuildStats& stats);

        // Enscape 광원을 씬 그래프 잎으로 만듭니다.
        void BuildLight(const std::shared_ptr<donut::engine::SceneGraph>& graph,
                        const std::shared_ptr<donut::engine::SceneGraphNode>& node,
                        const protocol::LightSpec& spec,
                        BuildStats& stats);

        // SketchUp 그림자 설정의 태양을 방향광으로 만듭니다.
        void BuildSun(const protocol::Scene& src,
                      const std::shared_ptr<donut::engine::SceneGraph>& graph,
                      const std::shared_ptr<donut::engine::SceneGraphNode>& parent,
                      BuildStats& stats);

        // 기본 환경광. 자세한 이유는 SetEnvironmentMap 주석 참조.
        void BuildEnvironmentLight(const std::shared_ptr<donut::engine::SceneGraph>& graph,
                                   const std::shared_ptr<donut::engine::SceneGraphNode>& parent,
                                   BuildStats& stats);

        // SketchUp 의 장면(뷰)을 카메라 노드로 만듭니다. 이것이 없으면 렌더러가
        // 모델과 무관한 기본 시점을 잡아 화면에 아무것도 안 보일 수 있습니다.
        void BuildViews(const protocol::Scene& src,
                        const std::shared_ptr<donut::engine::SceneGraph>& graph,
                        const std::shared_ptr<donut::engine::SceneGraphNode>& parent,
                        BuildStats& stats);
    };
}
