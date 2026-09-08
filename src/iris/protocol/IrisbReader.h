// IRIS — .irisb 씬 파일 리더
//
// .irisb 는 SketchUp 프로브가 내보내는 자체 형식입니다. GLB 와 같은 구조로
// 32바이트 헤더 + JSON 매니페스트 + 분리된 이진 블롭입니다.
// 형식 명세는 docs/05-씬-델타-프로토콜.md 8절을 보십시오.
//
// 이 헤더는 **엔진에 의존하지 않습니다.** Donut/nvrhi 타입이 나오지 않으므로
// 단독으로 빌드·시험할 수 있고, 씬 구축(SceneBuilder)과 책임이 갈립니다.
//
// 입력은 신뢰하지 않습니다. 파이프 너머에서 오는 데이터이므로 모든 오프셋과
// 인덱스를 범위 검사합니다 — 검사를 빠뜨리면 BLAS 빌드에서 GPU 가 죽습니다.

#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <unordered_map>
#include <vector>

namespace iris::protocol
{
    // 매니페스트에 { "off": <바이트 오프셋>, "count": <스칼라 개수> } 로 적히는 참조.
    // count 는 정점 수가 아니라 **스칼라 개수**입니다 — 위치 24개 = 정점 8개.
    struct BufferRef
    {
        uint64_t byteOffset = 0;
        uint32_t count      = 0;
        bool     present    = false;

        [[nodiscard]] bool Empty() const { return !present || count == 0; }
    };

    // 하나의 머티리얼로 묶인 삼각형 덩어리. 정의 하나가 여러 개를 가집니다.
    struct MeshBucket
    {
        std::string materialId;   // 비어 있으면 머티리얼 없음 (상속 대상)
        BufferRef   positions;    // f32, 정점당 3
        BufferRef   normals;      // f32, 정점당 3
        BufferRef   uvs;          // f32, 정점당 2
        BufferRef   indices;      // u32

        [[nodiscard]] uint32_t VertexCount() const { return positions.count / 3; }
        [[nodiscard]] uint32_t IndexCount() const { return indices.count; }
        [[nodiscard]] uint32_t TriangleCount() const { return indices.count / 3; }
    };

    // 인스턴스. 정의를 참조하고 배치 정보를 가집니다.
    struct Node
    {
        std::string          definitionId;
        int64_t              entityId     = 0;
        int64_t              persistentId = 0;   // 델타 추적의 열쇠
        std::string          name;
        std::array<float, 16> transform{};       // 열 우선. 읽을 때 [15]==1 로 정규화됨
        std::string          materialId;         // 인스턴스 단위 재질 덮어쓰기. 비면 없음
        std::string          layer;
        bool                 hidden = false;
    };

    // Enscape 가 SketchUp 속성 사전에 남긴 광원 설정.
    //
    // SketchUp 자체는 조명을 주지 않습니다. 하지만 Enscape 로 작업된 모델에는
    // 설계자가 정해 둔 세기·크기·IES 배광이 그대로 들어 있습니다. 프로브가
    // 그것을 읽어 여기로 넘깁니다 — 추측한 값보다 언제나 낫습니다.
    //
    // 위치와 방향은 여기 없습니다. 광원은 **프록시 컴포넌트의 인스턴스**이고,
    // 배치는 그 인스턴스의 변환에서 나옵니다. 씬 그래프가 합성하므로 노드에
    // 붙이기만 하면 됩니다.
    struct LightSpec
    {
        enum class Kind { None, Point, Spot, Rect, Linear };

        Kind                 kind      = Kind::None;
        std::array<float, 3> color{ 1.0f, 1.0f, 1.0f };  // 선형
        float                lumens    = 0.0f;   // 원본 광속. 참고·진단용
        float                intensity = 0.0f;   // cd — 주방향 광도 (point/spot)
        float                radius    = 0.0f;   // m — 광원 반지름
        float                innerDeg  = 0.0f;   // 반각. 축에서 잰 각도
        float                outerDeg  = 0.0f;   // 반각
        float                width     = 0.0f;   // m — rect/linear
        float                length    = 0.0f;   // m — rect/linear
        float                radiance  = 0.0f;   // cd/m^2 — rect/linear 면광원
        std::string          iesFile;            // 진단용 파일명

        [[nodiscard]] bool Valid() const { return kind != Kind::None; }
    };

    struct Definition
    {
        std::string             id;
        std::string             name;
        std::vector<MeshBucket> meshes;
        std::vector<Node>       children;
        int64_t                 persistentId  = 0;
        bool                    isGroup       = false;
        uint32_t                instanceCount = 0;

        // 비어 있지 않으면 이 정의는 광원 프록시입니다. meshes 도 비어 있습니다.
        LightSpec               light;

        // **델타**: 참이면 호스트가 지오메트리를 싣지 않았습니다. 렌더러가
        // 이미 갖고 있다는 뜻이며, 이전 동기화에서 만든 메시를 그대로 씁니다.
        //
        // meshes 가 비어 있는 것만으로는 판단할 수 없습니다 — 지오메트리가
        // 정말 없는 정의(순수 컨테이너)가 이 모델에 39% 있습니다. 그래서
        // 명시적인 표시가 필요합니다.
        bool                    geometryUnchanged = false;
    };

    struct Texture
    {
        std::string file;        // SketchUp 이 보고한 원본 경로 (없을 수 있음)
        std::string exportPath;  // 프로브가 내보낸 PNG. 씬 파일 기준 상대경로
        double      widthM  = 0.0;
        double      heightM = 0.0;
    };

    // Enscape 가 남긴 PBR 파라미터.
    //
    // SketchUp 은 색과 알파만 줍니다. 그래서 지금까지 모든 재질이
    // roughness 0.5 / metalness 0 고정이었고, "재질이 섬세하지 않다"는
    // 보고가 그것입니다. Enscape 모델에는 설계자가 정한 값이 들어 있습니다.
    struct MaterialPbr
    {
        bool  present   = false;
        std::string etype;              // GENERIC / SELF_ILLUMINATED / ...
        float roughness = 0.5f;
        float metalness = 0.0f;
        float specular  = 0.5f;         // glTF 의 반사율 스케일과 같은 뜻
        float opacity   = 1.0f;
        float ior       = 0.0f;         // 0 이면 미지정
        float bump      = 0.0f;
        float normalIntensity = 0.0f;
        std::string bumpType;           // UNDEFINED / BUMP / DISPLACEMENT / NORMAL
        bool  solidGlass = false;

        // 발광. cd/m^2 로 해석합니다 — 천장 패널의 3000~7000 이 실제 LED
        // 패널 휘도와 맞습니다. 골프존 모델의 천장 조명 29개가 이쪽입니다.
        bool                 hasEmissive = false;
        std::array<float, 3> emissive{ 1.0f, 1.0f, 1.0f };
        float                emissiveCd  = 0.0f;
    };

    struct Material
    {
        std::string          id;
        std::string          name;
        std::array<float, 3> color{ 1.0f, 1.0f, 1.0f };
        float                alpha      = 1.0f;
        int                  type       = 0;
        bool                 hasTexture = false;
        Texture              texture;
        MaterialPbr          pbr;
    };

    struct View
    {
        std::string          name;
        std::array<float, 3> eye{};
        std::array<float, 3> target{};
        std::array<float, 3> up{};
        float                fovDeg      = 60.0f;

        // ⚠ SketchUp 의 fov 는 수직일 수도 수평일 수도 있습니다.
        // false 면 **수평 화각**이며, 수직으로 바꾸려면 종횡비가 필요합니다.
        // 이 구분을 빠뜨리면 보이는 범위가 호스트와 달라집니다.
        bool                 fovIsHeight = true;
        float                viewportAspect = 0.0f;   // 호스트 뷰포트의 가로/세로

        bool                 perspective = true;
        float                aspect      = 0.0f;
        float                height      = 0.0f;   // 평행 투영일 때만 의미 있음
        bool                 hasHeight   = false;
    };

    // SketchUp 의 그림자 설정에서 온 태양.
    //
    // ⚠ toward 는 **모델에서 태양을 향하는** 방향입니다. 빛이 나아가는
    //   방향은 그 반대입니다. 부호를 잘못 쓰면 그림자가 정반대로 집니다.
    struct SunSpec
    {
        bool                 present  = false;
        std::array<float, 3> toward{ 0.0f, 0.0f, 1.0f };   // Z-up 모델 좌표
        bool                 shadows  = true;
        float                light    = 0.0f;   // SketchUp 의 0~100 슬라이더
        float                dark     = 0.0f;
        std::string          time;
        std::string          city;
    };

    struct Stats
    {
        int64_t faces = 0, triangles = 0, vertices = 0;
        int64_t instances = 0, definitions = 0;
        int64_t faceErrors = 0, groupsSkipped = 0;
    };

    struct Scene
    {
        // --- 매니페스트 머리말 ---
        std::string format;       // "iris.sketchup.scene"
        std::string version;      // "0.1.0"
        std::string unit;         // "meter"
        std::string upAxis;       // "z"  — 엔진은 Y-up 이므로 씬 구축 시 회전이 필요합니다
        std::string handedness;   // "right"
        std::string generated;
        std::string sourceApp;
        std::string sourceTitle;
        std::string sourceFile;

        // --- 본문 ---
        std::vector<Material>                        materials;
        std::vector<View>                            views;
        SunSpec                                      sun;
        std::unordered_map<std::string, Definition>  definitions;
        Definition                                   root;      // 최상위 메시 + 인스턴스
        Stats                                        stats;

        // --- 이진 블롭 ---
        std::vector<uint8_t> blob;

        // 블롭 접근자. 참조가 비어 있으면 nullptr 을 돌려줍니다.
        // 범위 검사는 읽는 시점에 이미 끝나 있으므로 여기서는 다시 하지 않습니다.
        [[nodiscard]] const float*    Floats(const BufferRef& r) const;
        [[nodiscard]] const uint32_t* Uints(const BufferRef& r) const;

        [[nodiscard]] const Material* FindMaterial(const std::string& id) const;
        [[nodiscard]] const Definition* FindDefinition(const std::string& id) const;
    };

    struct ReadOptions
    {
        // 인덱스가 정점 수를 넘지 않는지 전수 검사합니다. 400k 삼각형에 약 1 ms 이고,
        // 빠뜨리면 잘못된 인덱스가 그대로 BLAS 빌드로 들어가 GPU 가 죽습니다.
        bool validateIndices = true;

        // 위반을 만나면 실패로 끝낼지, 해당 버킷만 버리고 계속할지.
        // 라이브 링크 중에는 화면이 통째로 사라지는 것보다 나은 경우가 있습니다.
        bool strict = true;
    };

    struct ReadResult
    {
        bool        ok = false;
        std::string error;              // ok 가 false 일 때만 의미 있음
        std::vector<std::string> warnings;   // strict=false 로 버린 것들
    };

    // 파일에서 읽습니다.
    ReadResult ReadIrisbFile(const std::filesystem::path& path, Scene& out,
                             const ReadOptions& options = {});

    // 이미 메모리에 있는 바이트에서 읽습니다. 파이프 수신 경로가 이쪽을 씁니다.
    ReadResult ReadIrisbMemory(const uint8_t* data, size_t size, Scene& out,
                               const ReadOptions& options = {});

    // 헤더 상수 — 시험과 송신부가 공유합니다.
    inline constexpr char     kMagic[8]      = { 'I', 'R', 'I', 'S', 'S', 'C', 'N', '1' };
    inline constexpr uint32_t kFormatVersion = 1;
    inline constexpr size_t   kHeaderSize    = 32;
}
