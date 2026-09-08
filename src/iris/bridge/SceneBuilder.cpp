#include "SceneBuilder.h"

#include "iris/protocol/IrisbReader.h"

#include <donut/core/math/math.h>
#include <json/json.h>
#include <donut/engine/TextureCache.h>

#include <algorithm>
#include <chrono>
#include <cmath>

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
        //
        // 변환행렬을 Donut 의 TRS 로 **정확히** 분해합니다.
        //
        // **`decomposeAffine` 을 쓰면 안 됩니다.** 그 함수는 스케일과 회전을
        // 행렬의 **열**에서 뽑는데, `SceneGraphNode::UpdateLocalTransform` 은
        // `scaling * rotation` (행벡터) 로 재합성합니다. 그 형태의 저장 행렬은
        //
        //     row_i = s_i * R.row_i
        //
        // 이므로 **행**에서 뽑아야 왕복이 성립합니다. 열에서 뽑으면 회전이
        // 전치되어 나옵니다.
        //
        // 수치로 확인한 결과 (원소 최대 오차):
        //   회전만 / 균일 스케일        0        — 우연히 맞습니다
        //   거울(반전) + 회전           1.414    — **복원값이 전치. 방향이 뒤집힙니다**
        //   비균일 스케일 + 회전        0.71~2.59
        //
        // 실제 모델에서 비균일 스케일이 인스턴스의 17% 이고, 가구를 좌우 반전해
        // 배치하는 것은 SketchUp 의 일상적인 사용법입니다. 그래서 가구 방향이
        // 반대로 나왔습니다.
        //
        // 아래 방식은 임의 S·R 행렬 2000개에서 최대 오차 4.12e-13 입니다.
        // 쿼터니언 부호 규약은 `decomposeAffine` 것과 같습니다 — 그 부분은 맞습니다.
        //
        // ⚠ 이것은 Donut 자체의 문제이므로 **glTF 경로에도 같은 오류가 있습니다.**
        //   우리는 우리 경로만 고칩니다.
        void ApplyTransform(const std::shared_ptr<de::SceneGraphNode>& node, const float* m)
        {
            // 저장 레이아웃: row_i = 기저벡터 e_i 의 상(像).
            // .irisb 는 glTF 와 같은 배치이므로 m+0/+4/+8 이 각각 X·Y·Z 축입니다.
            double3 row[3] = {
                double3(m[0], m[1], m[2]),
                double3(m[4], m[5], m[6]),
                double3(m[8], m[9], m[10]),
            };

            double s[3];
            for (int i = 0; i < 3; ++i)
            {
                s[i] = length(row[i]);
                if (s[i] > 1e-12)
                    row[i] = row[i] / s[i];
            }

            // 반사(행렬식 음수)면 한 축에 음수 스케일로 접어 넣어 R 을 정회전으로
            // 만듭니다. 이렇게 해야 쿼터니언이 성립합니다.
            if (dot(cross(row[0], row[1]), row[2]) < 0.0)
            {
                s[0]   = -s[0];
                row[0] = -row[0];
            }
            const double3 scaling(s[0], s[1], s[2]);

            // 순수 회전에서 쿼터니언을 뽑습니다 (decomposeAffine 과 같은 규약).
            dquat rotation;
            rotation.w = std::sqrt(std::max(0.0, 1.0 + row[0].x + row[1].y + row[2].z)) * 0.5;
            rotation.x = std::sqrt(std::max(0.0, 1.0 + row[0].x - row[1].y - row[2].z)) * 0.5;
            rotation.y = std::sqrt(std::max(0.0, 1.0 - row[0].x + row[1].y - row[2].z)) * 0.5;
            rotation.z = std::sqrt(std::max(0.0, 1.0 - row[0].x - row[1].y + row[2].z)) * 0.5;
            rotation.x = std::copysign(rotation.x, row[1].z - row[2].y);
            rotation.y = std::copysign(rotation.y, row[2].x - row[0].z);
            rotation.z = std::copysign(rotation.z, row[0].y - row[1].x);

            double3 translation(m[12], m[13], m[14]);
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
            m->name    = ToNativeNarrow(sm.name.empty() ? sm.id : sm.name);
            m->opacity = sm.alpha;

            const bool hasTexture = sm.hasTexture && !sm.texture.exportPath.empty();

            // **텍스처가 있으면 기본색은 흰색입니다.**
            //
            // 프로브가 내보내는 PNG 는 `image_rep(true)` 로 뽑은 것이라 **이미
            // 재질 색이 입혀져 있습니다**. 여기서 색을 또 곱하면 두 번 착색됩니다.
            // 게다가 SketchUp 의 Material#color 는 텍스처 재질일 때 텍스처의
            // **평균색**을 돌려주므로, 곱하면 전체가 그 색으로 어두워집니다.
            m->baseOrDiffuseColor = hasTexture
                ? float3(1.0f, 1.0f, 1.0f)
                : float3(sm.color[0], sm.color[1], sm.color[2]);

            // SketchUp 은 PBR 파라미터를 주지 않습니다. 아래는 건축 재질에 대한
            // 잠정 휴리스틱이며, Enscape 값이 있으면 바로 아래에서 덮어씁니다.
            m->metalness = 0.0f;
            m->roughness = 0.5f;

            // Enscape 가 남긴 값이 있으면 그것이 정답입니다 — 설계자가 직접
            // 정한 값이고, 우리가 추측한 고정값보다 언제나 낫습니다.
            const bool ePbr = sm.pbr.present;
            if (ePbr)
            {
                m->roughness = sm.pbr.roughness;
                m->metalness = sm.pbr.metalness;

                // Enscape 의 Specular 는 glTF 의 반사율 스케일과 같은 뜻입니다.
                // Donut 의 금속-거칠기 모델에는 대응 필드가 없어 기본값(0.5)에서
                // 벗어날 때만 기록해 둡니다. 실제 반영은 미결정 B 에서 정합니다.
                if (std::abs(sm.pbr.specular - 0.5f) > 0.01f)
                    ++stats.specularOverrides;

                if (sm.pbr.hasEmissive)
                {
                    // **천장 조명 29개가 여기입니다.** Enscape 조명 객체가 아니라
                    // 자체발광 재질로 만들어져 있었습니다. 이것을 반영하지 않으면
                    // 실내가 어둡습니다.
                    m->emissiveColor     = float3(sm.pbr.emissive[0], sm.pbr.emissive[1],
                                                  sm.pbr.emissive[2]);
                    m->emissiveIntensity = sm.pbr.emissiveCd * m_photometricScale;
                    ++stats.emissiveMaterials;
                }
            }

            if (sm.alpha < 0.999f && !hasTexture)
            {
                // **반투명한데 텍스처가 없으면 유리로 봅니다.**
                //
                // 건축 모델에서 알파가 걸린 단색 재질은 거의 항상 유리입니다
                // (이 모델에도 'Translucent Glass', 'black glass' 가 있습니다).
                // AlphaBlended 로 두면 굴절도 반사도 없는 '유령'처럼 보입니다.
                // 패스트레이서가 유리를 제대로 그릴 수 있는데 그러지 않을 이유가
                // 없습니다.
                //
                // 텍스처가 있는 반투명은 잎사귀 컷아웃일 수 있어 그대로 둡니다.
                m->domain             = de::MaterialDomain::Transmissive;
                m->transmissionFactor = 1.0f - sm.alpha;
                // 유리도 Enscape 값이 있으면 그쪽을 씁니다. 없을 때만 0.05.
                m->roughness          = ePbr ? sm.pbr.roughness : 0.05f;
                m->opacity            = 1.0f;   // 투과로 표현하므로 불투명도는 되돌립니다
                ++stats.glassMaterials;
            }
            else
            {
                m->domain = (sm.alpha < 0.999f) ? de::MaterialDomain::AlphaBlended
                                                : de::MaterialDomain::Opaque;
            }

            if (hasTexture && (m_textureCache || m_textureLoader))
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

            // **거울 배치가 살아 있는가.**
            //
            // 이 모델은 인스턴스의 30%(1875개 중 557개)가 뒤집혀 놓여 있습니다.
            // 정의 안의 지오메트리가 이미 거울이고 배치가 그것을 되돌리는
            // 구조라, 부호를 잃으면 **모양은 그대로인데 텍스처 글자가
            // 뒤집힙니다.** 실제로 로고가 그렇게 나왔습니다.
            //
            // 호스트가 센 값과 여기서 센 값이 맞는지 봅니다.
            {
                const double3 r0(n.transform[0], n.transform[1], n.transform[2]);
                const double3 r1(n.transform[4], n.transform[5], n.transform[6]);
                const double3 r2(n.transform[8], n.transform[9], n.transform[10]);
                if (dot(cross(r0, r1), r2) < 0.0)
                    ++stats.mirroredNodes;
            }

            // 광원 프록시는 지오메트리 대신 광원 잎을 답니다. 위치와 방향은
            // 이 노드의 변환에서 나오므로 씬 그래프가 알아서 합성합니다.
            if (def->light.Valid())
                BuildLight(graph, node, def->light, stats);

            std::shared_ptr<de::MeshInfo> mesh;

            if (!def->meshes.empty())
            {
                auto it = m_meshes.find(def->id);
                if (it == m_meshes.end())
                {
                    it = m_meshes.emplace(def->id, BuildMesh(src, *def, stats)).first;
                    if (m_meshCache)
                    {
                        m_meshCache->meshes[def->id]   = it->second;
                        auto ih = m_inherits.find(def->id);
                        if (ih != m_inherits.end())
                            m_meshCache->inherits[def->id] = ih->second;
                    }
                }
                mesh = it->second;
            }
            else if (def->geometryUnchanged && m_meshCache)
            {
                // 호스트가 "이건 안 바뀌었다"고 했습니다. 이전 동기화에서 만든
                // 것을 그대로 씁니다 — 정점 업로드도 BLAS 재구축도 없습니다.
                auto it = m_meshes.find(def->id);
                if (it != m_meshes.end())
                {
                    mesh = it->second;
                }
                else
                {
                    auto ch = m_meshCache->meshes.find(def->id);
                    if (ch != m_meshCache->meshes.end())
                    {
                        mesh = ch->second;
                        m_meshes.emplace(def->id, mesh);
                        auto ih = m_meshCache->inherits.find(def->id);
                        if (ih != m_meshCache->inherits.end())
                            m_inherits[def->id] = ih->second;
                        ++stats.meshesReused;
                    }
                    else
                    {
                        // 호스트가 우리가 갖고 있다고 믿었는데 없습니다.
                        // 조용히 빠뜨리면 그 물체가 화면에서 사라집니다 —
                        // 반드시 드러나야 합니다.
                        ++stats.meshesMissing;
                        if (stats.meshesMissing <= 5)
                            stats.warnings.push_back(
                                "델타: 재사용해야 할 메시가 없습니다 — " + def->id);
                    }
                }
            }

            if (mesh)
            {
                auto instance = m_typeFactory->CreateMeshInstance(mesh);
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

    // ---------------------------------------------------------------- 광원

    void SceneBuilder::BuildLight(const std::shared_ptr<de::SceneGraph>& graph,
                                  const std::shared_ptr<de::SceneGraphNode>& node,
                                  const protocol::LightSpec& spec,
                                  BuildStats& stats)
    {
        using Kind = protocol::LightSpec::Kind;

        // 면광원(rect/linear)은 아직 발광 지오메트리로 내지 않습니다. 넓은
        // 원뿔 + 등가 면적의 구면 광원으로 근사합니다 — 반각 88도이면 실효
        // 입체각이 거의 정확히 pi 라서 램버시안 패널의 축상 광도와 맞습니다.
        // 지오메트리로 내는 것은 뒤로 미룹니다. 두 종류 합쳐 52개 중 5개입니다.
        const bool  area   = (spec.kind == Kind::Rect || spec.kind == Kind::Linear);
        const bool  isSpot = (spec.kind == Kind::Spot) || area;

        auto leaf = m_typeFactory->CreateLeaf(isSpot ? "SpotLight" : "PointLight");
        if (!leaf)
        {
            stats.warnings.push_back("팩토리가 광원을 만들지 못했습니다");
            return;
        }

        const float3 color(spec.color[0], spec.color[1], spec.color[2]);

        // **Enscape 프록시의 정면은 로컬 +Z 입니다.**
        //
        // Donut 은 로컬 -Z 를 정면으로 봅니다 (SceneTypes.cpp 의
        // `Light::GetDirection() { return -normalize(row2); }` — glTF 규약).
        // 정반대입니다.
        //
        // 실측(tools/sketchup/iris_lights_axis.rb, out/sketchup/lights_axis.txt):
        //   SpotLight#1~#4 의 43개 인스턴스 **전부** 로컬 +Z 가 월드 아래를
        //   향합니다. 15도 기울어진 월워셔(#1)까지 같은 규약입니다.
        //
        // 그대로 두면 다운라이트 43개가 전부 천장을 비춥니다. 그래서 광원 잎을
        // 인스턴스 노드에 직접 달지 않고, **X축 180도 회전한 자식 노드**에
        // 답니다. 자식의 -Z 가 부모의 +Z 가 됩니다.
        //
        // 인스턴스 노드의 변환은 건드리지 않습니다 — 그것은 호스트가 보낸
        // 값이고, 델타 추적이 그 위에서 돌아갑니다.
        auto host = node;
        if (isSpot)
        {
            host = std::make_shared<de::SceneGraphNode>();
            host->SetName("IRIS_LightAxis");
            const dquat flipX(0.0, 1.0, 0.0, 0.0);   // w, x, y, z — X축 180도
            const double3 zero(0.0, 0.0, 0.0);
            const double3 one(1.0, 1.0, 1.0);
            host->SetTransform(&zero, &flipX, &one);
            graph->Attach(node, host);
        }

        if (isSpot)
        {
            auto light = std::dynamic_pointer_cast<de::SpotLight>(leaf);
            if (!light)
            {
                stats.warnings.push_back("SpotLight 캐스팅에 실패했습니다");
                return;
            }

            float radius    = spec.radius;
            float outer     = spec.outerDeg;
            float inner     = spec.innerDeg;
            float intensity = spec.intensity;

            if (area)
            {
                const float w = spec.width  > 0.0f ? spec.width  : spec.length;
                const float a = std::max(w * spec.length, 1e-6f);
                radius    = std::sqrt(a / dm::PI_f);
                outer     = 88.0f;
                inner     = 0.0f;
                intensity = spec.radiance * a;   // L * A = 축상 광도
            }

            // ⚠ RTXPT 는 radius == 0 인 스포트라이트를 가정하지 않습니다
            // (LightsBaker.cpp 의 assert(false) — "not tested with radius == 0").
            // 0 이면 kPoint 경로로 빠지면서 원뿔 성형도 적용되지 않습니다.
            light->radius     = std::max(radius, 0.005f);
            light->intensity  = intensity * m_photometricScale;
            light->color      = color;
            light->range      = 0.0f;
            light->outerAngle = outer;   // 축에서 잰 반각(도) — RTXPT 는 cos(outerAngle) 로 씁니다
            light->innerAngle = std::min(inner, outer);
            ++stats.spotLights;
        }
        else
        {
            auto light = std::dynamic_pointer_cast<de::PointLight>(leaf);
            if (!light)
            {
                stats.warnings.push_back("PointLight 캐스팅에 실패했습니다");
                return;
            }
            light->radius    = spec.radius;   // 0 이어도 됩니다. kPoint 경로가 처리합니다
            light->intensity = spec.intensity * m_photometricScale;
            light->color     = color;
            light->range     = 0.0f;
            ++stats.pointLights;
        }

        graph->AttachLeafNode(host, leaf);
        stats.lightLumens += spec.lumens;
    }

    // ---------------------------------------------------------------- 태양

    void SceneBuilder::BuildSun(const protocol::Scene& src,
                                const std::shared_ptr<de::SceneGraph>& graph,
                                const std::shared_ptr<de::SceneGraphNode>& parent,
                                BuildStats& stats)
    {
        if (!src.sun.present)
            return;
        // 고도. toward.z 는 Z-up 모델 좌표이므로 그대로 sin(고도) 입니다.
        //
        // 부호 확인(2026-09-08): SketchUp 이 준 -0.363(고도 -21.3도)을 위경도와
        // 시각으로 따로 계산한 태양 고도(-20.0도)와 대조했습니다. 일치합니다 —
        // **SunDirection 은 태양을 향하는 방향**이 맞습니다.
        const float elevationDeg =
            std::asin(std::clamp(src.sun.toward[2], -1.0f, 1.0f)) * 180.0f / dm::PI_f;
        stats.sunElevationDeg = elevationDeg;

        if (elevationDeg <= 0.0f)
        {
            // 지평선 아래입니다. 그대로 넣으면 **땅 밑에서 빛이 올라옵니다.**
            // 조용히 넣지 않는 것보다, 왜 태양이 없는지 말해 주는 편이 낫습니다.
            stats.warnings.push_back(
                "태양이 지평선 아래입니다 (고도 " + std::to_string((int)elevationDeg) +
                "도) — 호스트의 그림자 시각이 밤입니다");
            return;
        }

        if (!src.sun.shadows)
        {
            // 호스트에서 그림자를 꺼 두었으면 태양도 넣지 않습니다. 설계자가
            // 일부러 끈 것을 렌더러가 되살리면 화면이 호스트와 달라집니다.
            stats.warnings.push_back("호스트에서 그림자가 꺼져 있어 태양을 넣지 않습니다");
            return;
        }

        // 방향을 먼저 구해 둡니다 — 하늘이 태양을 소유하더라도 방향은 넘겨야
        // 하기 때문입니다.
        {
            const double3 tz(src.sun.toward[0], src.sun.toward[1], src.sun.toward[2]);
            const double3 ty = normalize(double3(tz.x, tz.z, -tz.y));
            stats.sunDirYUp[0] = (float)ty.x;
            stats.sunDirYUp[1] = (float)ty.y;
            stats.sunDirYUp[2] = (float)ty.z;
            stats.hasSun = true;
        }

        if (m_skyOwnsSun)
        {
            // 하늘이 태양을 그립니다. 방향광을 또 만들면 **그림자가 둘**이
            // 됩니다 — 실외 모델에서 실제로 그렇게 나왔습니다.
            stats.sunIrradiance = 0.0f;
            return;
        }

        auto leaf = m_typeFactory->CreateLeaf("DirectionalLight");
        auto light = std::dynamic_pointer_cast<de::DirectionalLight>(leaf);
        if (!light)
        {
            stats.warnings.push_back("팩토리가 DirectionalLight 를 만들지 못했습니다");
            return;
        }

        // ⚠ toward 는 **태양을 향하는** 방향입니다(Z-up 모델 좌표).
        //   빛이 나아가는 방향은 그 반대이고, Donut 은 노드의 로컬 -Z 를
        //   그 방향으로 봅니다. 그러므로 노드의 **+Z 를 태양 쪽**에 둡니다.
        //   부호를 틀리면 그림자가 정반대로 집니다.
        double3 towardZUp(src.sun.toward[0], src.sun.toward[1], src.sun.toward[2]);

        // 모델은 Z-up, 엔진은 Y-up. kZUpToYUp 과 같은 회전입니다.
        double3 toward(towardZUp.x, towardZUp.z, -towardZUp.y);
        if (length(toward) < 1e-9)
            return;
        toward = normalize(toward);

        // +Z 가 태양을 향하는 정규직교 기저.
        double3 up(0.0, 1.0, 0.0);
        if (std::abs(dot(toward, up)) > 0.999)
            up = double3(1.0, 0.0, 0.0);
        double3 xa = normalize(cross(up, toward));
        double3 ya = cross(toward, xa);

        auto node = std::make_shared<de::SceneGraphNode>();
        node->SetName("IRIS_Sun");
        {
            // 행 i = 로컬 e_i 의 상. row2 = +Z = 태양 쪽.
            dquat q;
            const double m00 = xa.x, m01 = xa.y, m02 = xa.z;
            const double m10 = ya.x, m11 = ya.y, m12 = ya.z;
            const double m20 = toward.x, m21 = toward.y, m22 = toward.z;
            q.w = std::sqrt(std::max(0.0, 1.0 + m00 + m11 + m22)) * 0.5;
            q.x = std::copysign(std::sqrt(std::max(0.0, 1.0 + m00 - m11 - m22)) * 0.5, m12 - m21);
            q.y = std::copysign(std::sqrt(std::max(0.0, 1.0 - m00 + m11 - m22)) * 0.5, m20 - m02);
            q.z = std::copysign(std::sqrt(std::max(0.0, 1.0 - m00 - m11 + m22)) * 0.5, m01 - m10);
            const double3 zero(0.0, 0.0, 0.0);
            const double3 one(1.0, 1.0, 1.0);
            node->SetTransform(&zero, &q, &one);
        }
        graph->Attach(parent, node);

        light->irradiance  = m_sunIrradiance * m_photometricScale;
        light->angularSize = 0.53f;   // 태양의 실제 각지름(도)
        light->color       = float3(1.0f, 1.0f, 1.0f);
        graph->AttachLeafNode(node, light);

        stats.sunIrradiance = m_sunIrradiance;
    }

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

            // 화각 규약을 맞춥니다.
            //
            // SketchUp 의 fov 는 fov_is_height? 가 false 면 **수평** 화각입니다.
            // 그대로 수직으로 쓰면 보이는 범위가 호스트와 달라집니다 —
            // 실제로 "스케치업 화면과 렌더링 범위가 다르다"는 보고가 있었습니다.
            float verticalFovDeg = v.fovDeg;
            if (!v.fovIsHeight)
            {
                const float aspect = (v.aspect > 0.0f) ? v.aspect
                                   : (v.viewportAspect > 0.0f) ? v.viewportAspect
                                   : 16.0f / 9.0f;   // 정보가 없으면 흔한 값으로
                const float halfH = dm::radians(v.fovDeg) * 0.5f;
                verticalFovDeg = dm::degrees(2.0f * std::atan(std::tan(halfH) / aspect));
                stats.warnings.push_back(
                    "뷰 '" + v.name + "': 수평 화각 " + std::to_string(v.fovDeg) +
                    "도를 종횡비 " + std::to_string(aspect) + " 로 수직 " +
                    std::to_string(verticalFovDeg) + "도로 변환");
            }

            auto cam = std::make_shared<de::PerspectiveCamera>();
            cam->verticalFov = dm::radians(verticalFovDeg);
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
        BuildSun(src, graph, root, stats);
        BuildEnvironmentLight(graph, root, stats);
        Trace(stats.hasEnvLight ? "환경광 완료" : "환경광 없음");

        stats.buildMs = std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - t0).count();
        return graph;
    }
}
