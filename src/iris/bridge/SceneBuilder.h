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
        uint64_t triangles   = 0;
        uint64_t vertices    = 0;
        size_t   cameras     = 0;
        bool     hasEnvLight = false;
        size_t   maxDepth    = 0;
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

        // baseDir 은 텍스처 상대경로의 기준입니다 (.irisb 가 있던 디렉터리).
        std::shared_ptr<donut::engine::SceneGraph> Build(const protocol::Scene& src, BuildStats& stats);

    private:
        std::function<void(const std::string&)> m_trace;
        std::string                             m_environmentMap;
        TextureLoader                           m_textureLoader;
        void Trace(const std::string& msg) const { if (m_trace) m_trace(msg); }

        std::shared_ptr<donut::engine::SceneTypeFactory> m_typeFactory;
        std::shared_ptr<donut::engine::TextureCache>     m_textureCache;
        std::filesystem::path                            m_baseDir;

        std::unordered_map<std::string, std::shared_ptr<donut::engine::Material>> m_materials;
        std::shared_ptr<donut::engine::Material>                                  m_defaultMaterial;
        std::unordered_map<std::string, std::shared_ptr<donut::engine::MeshInfo>> m_meshes;

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
