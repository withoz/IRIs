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
        // 엔진 좌표(Y-up)에서 태양을 향하는 단위 벡터. 하늘에 넘깁니다.
        float    sunDirYUp[3]   = { 0.0f, 1.0f, 0.0f };
        size_t   mirroredNodes  = 0;   // 행렬식이 음수인 노드 = 거울 배치
        size_t   meshesReused   = 0;   // 델타: 다시 만들지 않고 재사용한 정의
        size_t   meshesMissing  = 0;   // 델타: 재사용해야 하는데 캐시에 없던 것 (전체 재동기화 필요)
        size_t   emissiveMaterials = 0;   // Enscape 자체발광
        size_t   specularOverrides = 0;   // Specular 가 0.5 가 아닌 재질
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
        using TextureLoader =
            std::function<std::shared_ptr<donut::engine::LoadedTexture>(const std::filesystem::path&)>;
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
