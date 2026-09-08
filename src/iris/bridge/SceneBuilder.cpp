#include "SceneBuilder.h"

#include "iris/protocol/IrisbReader.h"

#include <donut/core/math/math.h>
#include <json/json.h>
#include <donut/engine/TextureCache.h>

#include <chrono>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <windows.h>
#endif

using namespace donut::math;
namespace de = donut::engine;

namespace iris::bridge
{
    namespace
    {
        // 인스턴스 중첩 한계. SketchUp 이 이만큼 깊어질 일은 없지만, 프로토콜
        // 입력은 신뢰하지 않습니다 — 정의가 서로를 참조하면 무한히 내려갑니다.
        constexpr int kMaxDepth = 64;

        // .irisb 의 변환행렬은 glTF 와 같은 배치입니다 — 열 우선, X축이 [0..3),
        // Y축이 [4..7), Z축이 [8..11), 원점이 [12..15).
        // **glTF 임포터와 완전히 같은 방식으로 넣습니다**
        // (External/Donut/src/engine/GltfImporter.cpp:1745). 규약을 새로 해석하지
        // 않는 것이 목적입니다 — 틀리면 씬 전체가 전치됩니다.
        void ApplyTransform(const std::shared_ptr<de::SceneGraphNode>& node, const float* m)
        {
            const affine3 aff = affine3(float3(m + 0), float3(m + 4), float3(m + 8), float3(m + 12));

            double3 translation;
            double3 scaling;
            dquat   rotation;
            decomposeAffine(daffine3(aff), &translation, &rotation, &scaling);

            node->SetTransform(&translation, &rotation, &scaling);
        }

        // SketchUp 은 Z-up, 엔진은 Y-up 입니다. 정점을 건드리지 않고 루트 아래에
        // 회전 노드 하나를 둡니다 — 파이썬 변환기가 하던 것과 같은 처리입니다.
        //
        // X축 -90°. 열 우선 4x4 로 적으면 (x,y,z) -> (x, z, -y) 입니다.
        // 쿼터니언을 직접 만들지 않고 행렬로 적어 위 ApplyTransform 에 넘기는 이유는
        // 규약 추측을 없애기 위해서입니다.
        constexpr float kZUpToYUp[16] = {
            1.0f, 0.0f,  0.0f, 0.0f,
            0.0f, 0.0f, -1.0f, 0.0f,
            0.0f, 1.0f,  0.0f, 0.0f,
            0.0f, 0.0f,  0.0f, 1.0f,
        };

        // .irisb 의 문자열은 UTF-8 입니다. 그런데 MSVC 에서
        // std::filesystem::path(std::string) 은 **현재 ANSI 코드페이지**로 해석합니다.
        // 한국어 환경(CP949)에서 UTF-8 바이트를 넘기면 경로가 깨지거나 예외가 납니다.
        // 예외가 나면 std::terminate -> abort(0xC0000409) 로 죽고, 이유가 남지 않습니다.
        //
        // 실제로 여기서 한 번 죽었습니다. 텍스처 경로에 한글 폴더명이 들어 있습니다.
        std::filesystem::path Utf8Path(const std::string& s)
        {
            return std::filesystem::path(
                std::u8string(reinterpret_cast<const char8_t*>(s.c_str()), s.size()));
        }

        // .irisb 의 이름은 UTF-8 입니다. 그런데 Donut/RTXPT 는 std::string 이름을
        // **시스템 ANSI 코드페이지**로 다룹니다 — 그 이름으로 파일 경로를 만들고
        // (MaterialsBaker::GetMaterialStoragePath, SceneGraphNode::GetPath)
        // 나중에 path::string() 으로 되돌립니다.
        //
        // UTF-8 바이트를 그대로 넣으면 CP949 로 잘못 해석돼 되돌릴 수 없는 문자가
        // 생기고, path::string() 이 던지는 예외가 잡히지 않아
        // std::terminate -> abort(0xC0000409) 로 죽습니다. 이유도 남지 않습니다.
        // 실제로 여기서 한참 헤맸습니다.
        //
        // 그래서 이름은 **네이티브 좁은 인코딩**으로 바꿔서 넘깁니다. 한국어
        // 환경(CP949)에서는 한글이 그대로 보존되고, 표현 못 하는 문자만 '_' 가 됩니다.
        std::string ToNativeNarrow(const std::string& utf8)
        {
#ifdef _WIN32
            if (utf8.empty())
                return utf8;

            const int wlen = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), nullptr, 0);
            if (wlen <= 0)
                return utf8;
            std::wstring wide(static_cast<size_t>(wlen), L'\0');
            MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), wide.data(), wlen);

            const char kDefault = '_';
            const int nlen = WideCharToMultiByte(CP_ACP, 0, wide.c_str(), wlen,
                                                 nullptr, 0, &kDefault, nullptr);
            if (nlen <= 0)
                return utf8;
            std::string narrow(static_cast<size_t>(nlen), '\0');
            WideCharToMultiByte(CP_ACP, 0, wide.c_str(), wlen, narrow.data(), nlen, &kDefault, nullptr);
            return narrow;
#else
            return utf8;
#endif
        }

        box3 BoundsOf(const float* pos, uint32_t vertexCount)
        {
            box3 b = box3::empty();
            for (uint32_t i = 0; i < vertexCount; ++i)
                b |= float3(pos + i * 3);
            return b;
        }
    }   // namespace

    SceneBuilder::SceneBuilder(std::shared_ptr<de::SceneTypeFactory> typeFactory,
                               std::shared_ptr<de::TextureCache>     textureCache,
                               std::filesystem::path                 baseDir)
        : m_typeFactory(std::move(typeFactory))
        , m_textureCache(std::move(textureCache))
        , m_baseDir(std::move(baseDir))
    {
    }

    // ---------------------------------------------------------------- 머티리얼

    void SceneBuilder::BuildMaterials(const protocol::Scene& src, BuildStats& stats)
    {
        // 재질 없는 버킷이 실제로 존재합니다 — 골프존 모델에서 555개 중 55개.
        // Donut 은 머티리얼이 없는 프리미티브에서 죽습니다. 기본 머티리얼을
        // 반드시 하나 두고 그쪽으로 보냅니다.
        m_defaultMaterial = m_typeFactory->CreateMaterial();
        m_defaultMaterial->name              = "IRIS_default";
        m_defaultMaterial->baseOrDiffuseColor = float3(0.72f, 0.72f, 0.72f);
        m_defaultMaterial->roughness          = 0.5f;
        m_defaultMaterial->metalness          = 0.0f;
        m_defaultMaterial->domain             = de::MaterialDomain::Opaque;

        for (const auto& sm : src.materials)
        {
            auto m = m_typeFactory->CreateMaterial();
            m->name               = ToNativeNarrow(sm.name.empty() ? sm.id : sm.name);
            m->baseOrDiffuseColor = float3(sm.color[0], sm.color[1], sm.color[2]);
            m->opacity            = sm.alpha;

            // SketchUp 은 PBR 파라미터를 주지 않습니다. 임시 기본값이며
            // 미결정 B(PBR 파라미터 범위)가 정해지면 여기가 바뀝니다.
            m->roughness = 0.5f;
            m->metalness = 0.0f;
            m->domain    = (sm.alpha < 0.999f) ? de::MaterialDomain::AlphaBlended
                                               : de::MaterialDomain::Opaque;

            if (sm.hasTexture && !sm.texture.exportPath.empty() && (m_textureCache || m_textureLoader))
            {
                const std::filesystem::path p = m_baseDir / Utf8Path(sm.texture.exportPath);
                std::error_code ec;
                if (std::filesystem::exists(p, ec))
                {
                    // 색상 텍스처이므로 sRGB 입니다.
                    m->baseOrDiffuseTexture =
                        m_textureLoader ? m_textureLoader(p)
                                        : m_textureCache->LoadTextureFromFileDeferred(p, true);
                    ++stats.textures;
                }
                else
                {
                    stats.warnings.push_back("텍스처를 찾지 못했습니다: " + sm.texture.exportPath);
                }
            }

            m_materials.emplace(sm.id, std::move(m));
        }
        stats.materials = m_materials.size() + 1;   // +1 = 기본 머티리얼
    }

    // ---------------------------------------------------------------- 메시

    std::shared_ptr<de::MeshInfo> SceneBuilder::BuildMesh(const protocol::Scene& src,
                                                          const protocol::Definition& def,
                                                          BuildStats& stats)
    {
        auto mesh     = m_typeFactory->CreateMesh();
        mesh->name    = ToNativeNarrow(def.name.empty() ? def.id : def.name);
        mesh->type    = de::MeshType::Triangles;
        mesh->buffers = std::make_shared<de::BufferGroup>();
        mesh->objectSpaceBounds = box3::empty();

        auto& buffers = *mesh->buffers;

        // 버킷 순서와 같은 길이. 나중에 인스턴스 재질을 어디에 꽂을지 정합니다.
        std::vector<bool> inheritFlags;
        inheritFlags.reserve(def.meshes.size());

        // 먼저 총량을 세어 한 번에 확보합니다. 버킷마다 늘리면 재할당이 반복됩니다.
        size_t totalVerts = 0, totalIdx = 0;
        for (const auto& b : def.meshes)
        {
            totalVerts += b.VertexCount();
            totalIdx   += b.IndexCount();
        }
        buffers.positionData.reserve(totalVerts);
        buffers.normalData.reserve(totalVerts);
        buffers.texcoord1Data.reserve(totalVerts);
        buffers.indexData.reserve(totalIdx);

        for (const auto& b : def.meshes)
        {
            const uint32_t vcount = b.VertexCount();
            const uint32_t icount = b.IndexCount();
            const float*   pos    = src.Floats(b.positions);
            const float*   nrm    = src.Floats(b.normals);
            const float*   uv     = src.Floats(b.uvs);
            const uint32_t* idx   = src.Uints(b.indices);

            auto geom = m_typeFactory->CreateMeshGeometry();
            geom->type               = de::MeshGeometryPrimitiveType::Triangles;
            geom->indexOffsetInMesh  = mesh->totalIndices;
            geom->vertexOffsetInMesh = mesh->totalVertices;
            geom->numIndices         = icount;
            geom->numVertices        = vcount;
            geom->objectSpaceBounds  = BoundsOf(pos, vcount);

            // 재질이 없는 버킷은 **상속 대상**입니다. 기본 머티리얼을 넣어 두되
            // (Donut 은 머티리얼 없는 프리미티브에서 죽습니다) 어느 자리가
            // 상속인지 기록해 두었다가 인스턴스 재질로 덮어씁니다.
            auto it = m_materials.find(b.materialId);
            const bool inherits = (it == m_materials.end());
            geom->material = inherits ? m_defaultMaterial : it->second;
            inheritFlags.push_back(inherits);
            if (inherits)
                ++stats.inheritingBuckets;

            // 인덱스는 버킷 안에서 국소적입니다. glTF 임포터도 그대로 넣고
            // vertexOffsetInMesh 로 보정합니다 — 같은 규약을 씁니다.
            buffers.indexData.insert(buffers.indexData.end(), idx, idx + icount);

            for (uint32_t v = 0; v < vcount; ++v)
                buffers.positionData.push_back(float3(pos + v * 3));

            if (nrm)
            {
                // BufferGroup::normalData 는 uint32 패킹입니다 — float3 이 아닙니다.
                for (uint32_t v = 0; v < vcount; ++v)
                    buffers.normalData.push_back(vectorToSnorm8(float3(nrm + v * 3)));
            }
            else
            {
                // 법선이 없으면 위로 채웁니다. 실측상 이런 버킷은 없었습니다.
                const uint32_t up = vectorToSnorm8(float3(0.0f, 0.0f, 1.0f));
                buffers.normalData.insert(buffers.normalData.end(), vcount, up);
            }

            if (uv)
            {
                for (uint32_t v = 0; v < vcount; ++v)
                    buffers.texcoord1Data.push_back(float2(uv + v * 2));
            }
            else
            {
                buffers.texcoord1Data.insert(buffers.texcoord1Data.end(), vcount, float2(0.0f, 0.0f));
            }

            mesh->objectSpaceBounds |= geom->objectSpaceBounds;
            mesh->totalIndices  += icount;
            mesh->totalVertices += vcount;
            mesh->geometries.push_back(std::move(geom));

            stats.triangles += b.TriangleCount();
            stats.vertices  += vcount;
            ++stats.geometries;
        }

        m_inherits[def.id] = std::move(inheritFlags);

        ++stats.meshes;
        return mesh;
    }

    // ---------------------------------------------------------------- 노드

    void SceneBuilder::BuildNodes(const protocol::Scene& src,
                                  const std::shared_ptr<de::SceneGraph>& graph,
                                  const std::shared_ptr<de::SceneGraphNode>& parent,
                                  const std::vector<protocol::Node>& children,
                                  int depth, BuildStats& stats)
    {
        if (depth > kMaxDepth)
        {
            stats.warnings.push_back("중첩이 " + std::to_string(kMaxDepth) +
                                     " 단계를 넘어 더 내려가지 않습니다");
            return;
        }
        stats.maxDepth = std::max(stats.maxDepth, static_cast<size_t>(depth));

        for (const auto& n : children)
        {
            if (n.hidden)
                continue;

            const protocol::Definition* def = src.FindDefinition(n.definitionId);
            if (!def)
            {
                stats.warnings.push_back("정의를 찾지 못했습니다: " + n.definitionId);
                continue;
            }

            auto node = std::make_shared<de::SceneGraphNode>();
            node->SetName(ToNativeNarrow(n.name.empty() ? n.definitionId : n.name));
            ApplyTransform(node, n.transform.data());
            graph->Attach(parent, node);

            if (!def->meshes.empty())
            {
                auto it = m_meshes.find(def->id);
                if (it == m_meshes.end())
                    it = m_meshes.emplace(def->id, BuildMesh(src, *def, stats)).first;

                auto instance = m_typeFactory->CreateMeshInstance(it->second);
                graph->AttachLeafNode(node, instance);
                ++stats.instances;

                ApplyInheritedMaterial(*instance, def->id, n.materialId, stats);
            }

            if (!def->children.empty())
                BuildNodes(src, graph, node, def->children, depth + 1, stats);
        }
    }

    void SceneBuilder::ApplyInheritedMaterial(de::MeshInstance& instance,
                                              const std::string& defId,
                                              const std::string& instanceMaterialId,
                                              BuildStats& stats)
    {
        if (instanceMaterialId.empty() || !m_applyInstanceMaterials)
            return;

        auto flagIt = m_inherits.find(defId);
        if (flagIt == m_inherits.end())
            return;

        auto matIt = m_materials.find(instanceMaterialId);
        if (matIt == m_materials.end())
            return;

        const std::vector<bool>& flags = flagIt->second;
        std::vector<std::shared_ptr<de::Material>> overrides;
        size_t applied = 0;

        for (size_t i = 0; i < flags.size(); ++i)
        {
            if (!flags[i])
                continue;
            if (overrides.empty())
                overrides.resize(flags.size());
            overrides[i] = matIt->second;
            ++applied;
        }

        if (applied == 0)
            return;   // 이 정의에는 상속할 자리가 없습니다

        stats.overriddenSubInstances += applied;
        m_applyInstanceMaterials(instance, std::move(overrides));
    }

    // ---------------------------------------------------------------- 환경광

    void SceneBuilder::BuildEnvironmentLight(const std::shared_ptr<de::SceneGraph>& graph,
                                             const std::shared_ptr<de::SceneGraphNode>& parent,
                                             BuildStats& stats)
    {
        if (m_environmentMap.empty())
        {
            stats.warnings.push_back("환경맵이 지정되지 않았습니다 — 광원이 없어 화면이 검게 나옵니다");
            return;
        }

        // EnvironmentLight 는 RTXPT 타입입니다. 이 계층은 RTXPT 를 몰라야 하므로
        // 팩토리에 이름으로 요청하고 JSON 으로 값을 넘깁니다. 팩토리가 그 타입을
        // 모르면(예: 순수 Donut) 조용히 넘어갑니다.
        auto leaf = m_typeFactory->CreateLeaf("EnvironmentLight");
        if (!leaf)
        {
            stats.warnings.push_back("팩토리가 EnvironmentLight 를 만들지 못했습니다");
            return;
        }

        Json::Value j;
        for (int i = 0; i < 3; ++i)
            j["radianceScale"][i] = 1.0;
        j["textureIndex"] = 0;
        j["rotation"]     = 0.0;
        j["path"]         = m_environmentMap;
        leaf->Load(j);

        auto node = std::make_shared<de::SceneGraphNode>();
        node->SetName("IRIS_Sky");
        graph->Attach(parent, node);
        graph->AttachLeafNode(node, leaf);
        stats.hasEnvLight = true;
    }

    // ---------------------------------------------------------------- 뷰

    void SceneBuilder::BuildViews(const protocol::Scene& src,
                                  const std::shared_ptr<de::SceneGraph>& graph,
                                  const std::shared_ptr<de::SceneGraphNode>& parent,
                                  BuildStats& stats)
    {
        // 순서에 뜻이 있습니다. 렌더러는 **마지막 카메라**를 초기 시점으로 씁니다
        // (RTXPT Sample.cpp: cameras.back()). SketchUp 의 첫 항목이 '현재 뷰',
        // 즉 사용자가 방금 보고 있던 화면이므로 그것을 맨 뒤에 한 번 더 답니다.
        //
        // 이걸 안 하면 저장된 장면 중 마지막 것이 초기 시점이 되는데, 그게 벽을
        // 마주보는 어두운 지점이면 화면이 새까맣게 나옵니다. 실제로 그랬습니다.
        std::vector<const protocol::View*> ordered;
        ordered.reserve(src.views.size() + 1);
        for (const auto& v : src.views)
            ordered.push_back(&v);
        if (!src.views.empty())
            ordered.push_back(&src.views.front());

        for (size_t vi = 0; vi < ordered.size(); ++vi)
        {
            const protocol::View& v = *ordered[vi];
            const bool isDefault = (vi + 1 == ordered.size());
            if (!v.perspective)
            {
                // 평행 투영 뷰는 아직 다루지 않습니다. 패스트레이서에서 의미가
                // 제한적이고 건축 시점은 거의 원근입니다.
                stats.warnings.push_back("평행 투영 뷰는 건너뜁니다: " + v.name);
                continue;
            }

            const float3 eye    (v.eye[0],    v.eye[1],    v.eye[2]);
            const float3 target (v.target[0], v.target[1], v.target[2]);
            const float3 upHint (v.up[0],     v.up[1],     v.up[2]);

            const float3 fwd = target - eye;
            if (length(fwd) < 1e-6f)
            {
                stats.warnings.push_back("눈과 목표가 같은 뷰는 건너뜁니다: " + v.name);
                continue;
            }

            // glTF·Donut 카메라 규약: 로컬 -Z 를 바라보고 +Y 가 위입니다.
            // 이 노드는 Z-up -> Y-up 회전 노드 **아래**에 붙으므로, 여기서는
            // SketchUp 의 Z-up 공간에서 축을 세우면 됩니다. 부모가 함께 돌립니다.
            const float3 z = normalize(-fwd);
            float3 x = cross(upHint, z);
            if (length(x) < 1e-6f)
                x = cross(float3(0.0f, 1.0f, 0.0f), z);   // 시선이 up 과 나란한 경우
            x = normalize(x);
            const float3 y = cross(z, x);

            // affine3(row0,row1,row2,translation) 에서 row 는 기저벡터의 상(像)입니다
            // (affine::transformVector 참조). 인스턴스 경로와 같은 규약입니다.
            const affine3 aff(x, y, z, eye);

            double3 translation, scaling;
            dquat   rotation;
            decomposeAffine(daffine3(aff), &translation, &rotation, &scaling);

            auto cam = std::make_shared<de::PerspectiveCamera>();
            cam->verticalFov = dm::radians(v.fovDeg);
            cam->zNear       = 0.01f;
            if (v.aspect > 0.0f)
                cam->aspectRatio = v.aspect;

            auto node = std::make_shared<de::SceneGraphNode>();
            node->SetName(isDefault ? "IRIS_Default"
                                    : ToNativeNarrow(v.name.empty()
                                          ? ("view_" + std::to_string(stats.cameras)) : v.name));
            node->SetTransform(&translation, &rotation, &scaling);
            graph->Attach(parent, node);
            graph->AttachLeafNode(node, cam);
            ++stats.cameras;
        }
    }

    // ---------------------------------------------------------------- 진입점

    std::shared_ptr<de::SceneGraph> SceneBuilder::Build(const protocol::Scene& src, BuildStats& stats)
    {
        const auto t0 = std::chrono::steady_clock::now();
        auto since = [&t0]() {
            return std::to_string((int)std::chrono::duration<double, std::milli>(
                       std::chrono::steady_clock::now() - t0).count()) + " ms";
        };

        m_materials.clear();
        m_meshes.clear();
        m_inherits.clear();

        auto graph = std::make_shared<de::SceneGraph>();

        Trace("그래프 생성");
        auto root = std::make_shared<de::SceneGraphNode>();
        root->SetName("SceneRoot");
        graph->SetRootNode(root);

        Trace("머티리얼 시작");
        BuildMaterials(src, stats);
        Trace("머티리얼 완료 " + std::to_string(stats.materials) +
              " (텍스처 " + std::to_string(stats.textures) + ") @" + since());

        // Z-up -> Y-up 회전 노드. 그 아래에 씬 전체가 들어갑니다.
        auto axis = std::make_shared<de::SceneGraphNode>();
        axis->SetName("IRIS_ZUP_TO_YUP");
        if (src.upAxis == "z")
            ApplyTransform(axis, kZUpToYUp);
        else if (src.upAxis != "y")
            stats.warnings.push_back("모르는 up_axis '" + src.upAxis + "' — 회전 없이 둡니다");
        graph->Attach(root, axis);

        // 최상위 메시(정의에 속하지 않고 모델 루트에 바로 있는 것)도 다룹니다.
        if (!src.root.meshes.empty())
        {
            auto mesh = BuildMesh(src, src.root, stats);
            auto node = std::make_shared<de::SceneGraphNode>();
            node->SetName("IRIS_root_geometry");
            graph->Attach(axis, node);
            graph->AttachLeafNode(node, m_typeFactory->CreateMeshInstance(mesh));
            ++stats.instances;
        }

        Trace("노드 시작 (최상위 " + std::to_string(src.root.children.size()) + ")");
        BuildNodes(src, graph, axis, src.root.children, 0, stats);
        Trace("노드 완료 — 메시 " + std::to_string(stats.meshes) +
              " 인스턴스 " + std::to_string(stats.instances) +
              " 최대중첩 " + std::to_string(stats.maxDepth) + " @" + since());

        Trace("뷰 시작 (" + std::to_string(src.views.size()) + ")");
        BuildViews(src, graph, axis, stats);
        Trace("뷰 완료 " + std::to_string(stats.cameras) + " @" + since());

        // 환경광은 루트에 답니다 — Z-up 회전 아래에 두면 하늘이 같이 돌아갑니다.
        Trace("환경광 시작");
        BuildEnvironmentLight(graph, root, stats);
        Trace(stats.hasEnvLight ? "환경광 완료" : "환경광 없음");

        stats.buildMs = std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - t0).count();
        return graph;
    }
}
