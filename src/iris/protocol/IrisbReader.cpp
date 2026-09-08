#include "IrisbReader.h"

#include <json/json.h>

#include <cmath>
#include <cstring>
#include <fstream>
#include <memory>

namespace iris::protocol
{
    namespace
    {
        // ---------------------------------------------------------------- 헤더

        struct Header
        {
            uint32_t version    = 0;
            uint32_t reserved   = 0;
            uint64_t jsonBytes  = 0;
            uint64_t blobBytes  = 0;
        };

        bool ReadHeader(const uint8_t* data, size_t size, Header& out, std::string& error)
        {
            if (size < kHeaderSize)
            {
                error = "파일이 너무 짧습니다 (" + std::to_string(size) + " bytes, 최소 32 필요)";
                return false;
            }
            if (std::memcmp(data, kMagic, sizeof(kMagic)) != 0)
            {
                error = "MAGIC 이 'IRISSCN1' 이 아닙니다 — .irisb 파일이 아닙니다";
                return false;
            }
            std::memcpy(&out.version,   data + 8,  4);
            std::memcpy(&out.reserved,  data + 12, 4);
            std::memcpy(&out.jsonBytes, data + 16, 8);
            std::memcpy(&out.blobBytes, data + 24, 8);

            if (out.version != kFormatVersion)
            {
                error = "형식 버전 " + std::to_string(out.version) + " 을 읽을 수 없습니다 (지원: " +
                        std::to_string(kFormatVersion) + ")";
                return false;
            }

            // 곱셈 없이 더하기만으로 넘침을 피해 검사합니다.
            if (out.jsonBytes > size - kHeaderSize ||
                out.blobBytes > size - kHeaderSize - out.jsonBytes)
            {
                error = "선언된 크기가 파일을 넘습니다 (json " + std::to_string(out.jsonBytes) +
                        " + blob " + std::to_string(out.blobBytes) + " > " +
                        std::to_string(size - kHeaderSize) + ")";
                return false;
            }
            return true;
        }

        // ---------------------------------------------------------------- 보조

        std::string GetString(const Json::Value& v, const char* key, const char* fallback = "")
        {
            const Json::Value& m = v[key];
            return m.isString() ? m.asString() : std::string(fallback);
        }

        // material 은 null 이거나 문자열입니다. null 이면 빈 문자열로 둡니다.
        std::string GetOptionalId(const Json::Value& v, const char* key)
        {
            const Json::Value& m = v[key];
            return m.isString() ? m.asString() : std::string();
        }

        double GetDouble(const Json::Value& v, const char* key, double fallback = 0.0)
        {
            const Json::Value& m = v[key];
            return m.isNumeric() ? m.asDouble() : fallback;
        }

        int64_t GetInt64(const Json::Value& v, const char* key, int64_t fallback = 0)
        {
            const Json::Value& m = v[key];
            return m.isNumeric() ? m.asInt64() : fallback;
        }

        bool GetBool(const Json::Value& v, const char* key, bool fallback = false)
        {
            const Json::Value& m = v[key];
            return m.isBool() ? m.asBool() : fallback;
        }

        template <size_t N>
        bool ReadVec(const Json::Value& v, std::array<float, N>& out)
        {
            if (!v.isArray() || v.size() != N)
                return false;
            for (Json::ArrayIndex i = 0; i < N; ++i)
            {
                if (!v[i].isNumeric())
                    return false;
                out[i] = static_cast<float>(v[i].asDouble());
            }
            return true;
        }

        // { "off": n, "count": n } 을 읽고 블롭 범위 안인지 확인합니다.
        // elementSize 는 스칼라 하나의 크기(4). null 이면 present=false 로 둡니다.
        bool ReadBufferRef(const Json::Value& v, uint64_t blobSize, size_t elementSize,
                           BufferRef& out, const char* what, std::string& error)
        {
            if (v.isNull())
            {
                out = {};
                return true;
            }
            if (!v.isObject() || !v["off"].isNumeric() || !v["count"].isNumeric())
            {
                error = std::string(what) + ": {off,count} 형태가 아닙니다";
                return false;
            }
            const int64_t off   = v["off"].asInt64();
            const int64_t count = v["count"].asInt64();
            if (off < 0 || count < 0)
            {
                error = std::string(what) + ": 음수 오프셋/개수";
                return false;
            }

            // 오프셋 정렬. 프로브는 항상 4바이트 배수로 쌓지만, 깨진 파일이 들어오면
            // reinterpret_cast 가 미정의 동작이 됩니다. 값싼 검사이므로 합니다.
            if (off % static_cast<int64_t>(elementSize) != 0)
            {
                error = std::string(what) + ": 오프셋 " + std::to_string(off) + " 가 " +
                        std::to_string(elementSize) + "바이트 정렬이 아닙니다";
                return false;
            }

            const uint64_t bytes = static_cast<uint64_t>(count) * elementSize;
            if (static_cast<uint64_t>(off) > blobSize || bytes > blobSize - static_cast<uint64_t>(off))
            {
                error = std::string(what) + ": 블롭 범위를 벗어납니다 (off " + std::to_string(off) +
                        " + " + std::to_string(bytes) + " > " + std::to_string(blobSize) + ")";
                return false;
            }

            out.byteOffset = static_cast<uint64_t>(off);
            out.count      = static_cast<uint32_t>(count);
            out.present    = true;
            return true;
        }

        // SketchUp 4x4 (열 우선). 16번째 원소가 균일 스케일 제수일 수 있습니다.
        // 점 변환이 (M*p)/w 이므로 앞 15개를 w 로 나누면 동등하면서 w=1 인 행렬이 됩니다.
        bool NormalizeTransform(const Json::Value& v, std::array<float, 16>& out)
        {
            if (!v.isArray() || v.size() != 16)
                return false;

            double m[16];
            for (Json::ArrayIndex i = 0; i < 16; ++i)
            {
                if (!v[i].isNumeric())
                    return false;
                m[i] = v[i].asDouble();
            }

            const double w = m[15];
            if (std::abs(w) < 1e-12)
                return false;
            if (std::abs(w - 1.0) > 1e-9)
            {
                for (int i = 0; i < 15; ++i)
                    m[i] /= w;
                m[15] = 1.0;
            }
            for (int i = 0; i < 16; ++i)
                out[i] = static_cast<float>(m[i]);
            return true;
        }

        // ---------------------------------------------------------------- 파싱

        struct Parser
        {
            uint64_t                  blobSize = 0;
            const uint8_t*            blob     = nullptr;
            const ReadOptions*        opt      = nullptr;
            std::vector<std::string>* warnings = nullptr;
            std::string               error;

            void Warn(std::string msg) { warnings->push_back(std::move(msg)); }

            // 반환값: 이 버킷을 씬에 넣을지. strict 면 위반 시 error 를 채우고 false.
            bool ReadMeshBucket(const Json::Value& v, const std::string& owner, MeshBucket& out)
            {
                out.materialId = GetOptionalId(v, "material");

                const std::string tag = owner + " 메시";
                if (!ReadBufferRef(v["positions"], blobSize, 4, out.positions, (tag + ".positions").c_str(), error) ||
                    !ReadBufferRef(v["normals"],   blobSize, 4, out.normals,   (tag + ".normals").c_str(),   error) ||
                    !ReadBufferRef(v["uvs"],       blobSize, 4, out.uvs,       (tag + ".uvs").c_str(),       error) ||
                    !ReadBufferRef(v["indices"],   blobSize, 4, out.indices,   (tag + ".indices").c_str(),   error))
                    return false;

                return ValidateBucket(out, tag);
            }

            bool Reject(const std::string& msg)
            {
                if (opt->strict)
                {
                    error = msg;
                    return false;
                }
                Warn(msg + " — 이 버킷을 버립니다");
                return false;   // strict 여부와 무관하게 버킷은 넣지 않는다
            }

            bool ValidateBucket(const MeshBucket& b, const std::string& tag)
            {
                if (b.positions.Empty() || b.indices.Empty())
                    return Reject(tag + ": 위치 또는 인덱스가 없습니다");

                if (b.positions.count % 3 != 0)
                    return Reject(tag + ": 위치 개수 " + std::to_string(b.positions.count) + " 가 3의 배수가 아닙니다");

                if (b.indices.count % 3 != 0)
                    return Reject(tag + ": 인덱스 개수 " + std::to_string(b.indices.count) + " 가 3의 배수가 아닙니다");

                const uint32_t verts = b.VertexCount();

                if (!b.normals.Empty() && b.normals.count != b.positions.count)
                    return Reject(tag + ": 법선 개수(" + std::to_string(b.normals.count) +
                                  ") 가 위치 개수(" + std::to_string(b.positions.count) + ") 와 다릅니다");

                if (!b.uvs.Empty() && b.uvs.count != verts * 2)
                    return Reject(tag + ": UV 개수(" + std::to_string(b.uvs.count) +
                                  ") 가 정점 수(" + std::to_string(verts) + ")*2 와 다릅니다");

                if (opt->validateIndices)
                {
                    const uint32_t* idx = reinterpret_cast<const uint32_t*>(blob + b.indices.byteOffset);
                    for (uint32_t i = 0; i < b.indices.count; ++i)
                    {
                        if (idx[i] >= verts)
                            return Reject(tag + ": 인덱스 " + std::to_string(idx[i]) +
                                          " 가 정점 수 " + std::to_string(verts) + " 를 넘습니다");
                    }
                }
                return true;
            }

            bool ReadNode(const Json::Value& v, const std::string& owner, Node& out)
            {
                out.definitionId = GetString(v, "definition");
                if (out.definitionId.empty())
                {
                    error = owner + ": 인스턴스에 definition 이 없습니다";
                    return false;
                }
                out.entityId     = GetInt64(v, "entity_id");
                out.persistentId = GetInt64(v, "persistent_id");
                out.name         = GetString(v, "name");
                out.materialId   = GetOptionalId(v, "material");
                out.layer        = GetString(v, "layer");
                out.hidden       = GetBool(v, "hidden");

                if (!NormalizeTransform(v["transform"], out.transform))
                {
                    // 변환행렬이 깨진 인스턴스 하나 때문에 씬 전체를 버리지는 않습니다.
                    Warn(owner + ": 인스턴스 " + out.definitionId + " 의 변환행렬이 유효하지 않습니다 — 건너뜁니다");
                    return false;
                }
                return true;
            }

            bool ReadDefinitionBody(const Json::Value& v, const std::string& owner, Definition& out)
            {
                const Json::Value& meshes = v["meshes"];
                if (meshes.isArray())
                {
                    out.meshes.reserve(meshes.size());
                    for (const auto& m : meshes)
                    {
                        MeshBucket b;
                        if (ReadMeshBucket(m, owner, b))
                            out.meshes.push_back(std::move(b));
                        else if (!error.empty())
                            return false;
                    }
                }

                const Json::Value& children = v["children"];
                if (children.isArray())
                {
                    out.children.reserve(children.size());
                    for (const auto& c : children)
                    {
                        Node n;
                        if (ReadNode(c, owner, n))
                            out.children.push_back(std::move(n));
                        else if (!error.empty())
                            return false;
                    }
                }
                return true;
            }
        };
    }   // namespace

    // -------------------------------------------------------------------- 접근자

    const float* Scene::Floats(const BufferRef& r) const
    {
        if (r.Empty())
            return nullptr;
        return reinterpret_cast<const float*>(blob.data() + r.byteOffset);
    }

    const uint32_t* Scene::Uints(const BufferRef& r) const
    {
        if (r.Empty())
            return nullptr;
        return reinterpret_cast<const uint32_t*>(blob.data() + r.byteOffset);
    }

    const Material* Scene::FindMaterial(const std::string& id) const
    {
        if (id.empty())
            return nullptr;
        for (const auto& m : materials)
            if (m.id == id)
                return &m;
        return nullptr;
    }

    const Definition* Scene::FindDefinition(const std::string& id) const
    {
        auto it = definitions.find(id);
        return it == definitions.end() ? nullptr : &it->second;
    }

    // -------------------------------------------------------------------- 읽기

    ReadResult ReadIrisbMemory(const uint8_t* data, size_t size, Scene& out, const ReadOptions& options)
    {
        ReadResult res;
        out = Scene{};

        Header hdr;
        if (!ReadHeader(data, size, hdr, res.error))
            return res;

        const char* jsonBegin = reinterpret_cast<const char*>(data + kHeaderSize);
        const char* jsonEnd   = jsonBegin + hdr.jsonBytes;

        Json::Value  doc;
        Json::CharReaderBuilder builder;
        std::string  jsonError;
        {
            std::unique_ptr<Json::CharReader> reader(builder.newCharReader());
            if (!reader->parse(jsonBegin, jsonEnd, &doc, &jsonError))
            {
                res.error = "매니페스트 JSON 파싱 실패: " + jsonError;
                return res;
            }
        }
        if (!doc.isObject())
        {
            res.error = "매니페스트가 객체가 아닙니다";
            return res;
        }

        // 블롭을 먼저 복사합니다. 파싱 중 범위 검사에 필요합니다.
        const uint8_t* blobBegin = data + kHeaderSize + hdr.jsonBytes;
        out.blob.assign(blobBegin, blobBegin + hdr.blobBytes);

        // --- 머리말 ---
        out.format      = GetString(doc, "format");
        out.version     = GetString(doc, "version");
        out.unit        = GetString(doc, "unit");
        out.upAxis      = GetString(doc, "up_axis");
        out.handedness  = GetString(doc, "handedness");
        out.generated   = GetString(doc, "generated");
        if (doc["source"].isObject())
        {
            out.sourceApp   = GetString(doc["source"], "app");
            out.sourceTitle = GetString(doc["source"], "title");
            out.sourceFile  = GetString(doc["source"], "file");
        }

        if (out.format != "iris.sketchup.scene")
            res.warnings.push_back("format 이 'iris.sketchup.scene' 이 아닙니다: '" + out.format + "'");

        // --- 머티리얼 ---
        for (const auto& mv : doc["materials"])
        {
            Material m;
            m.id    = GetString(mv, "id");
            m.name  = GetString(mv, "name");
            m.alpha = static_cast<float>(GetDouble(mv, "alpha", 1.0));
            m.type  = static_cast<int>(GetInt64(mv, "type"));
            ReadVec(mv["color"], m.color);

            const Json::Value& t = mv["texture"];
            if (t.isObject())
            {
                m.hasTexture         = true;
                m.texture.file       = GetString(t, "file");
                m.texture.exportPath = GetString(t, "export");
                m.texture.widthM     = GetDouble(t, "width_m");
                m.texture.heightM    = GetDouble(t, "height_m");
            }
            out.materials.push_back(std::move(m));
        }

        // --- 뷰 ---
        for (const auto& vv : doc["views"])
        {
            View v;
            v.name        = GetString(vv, "name");
            v.fovDeg         = static_cast<float>(GetDouble(vv, "fov_deg", 60.0));
            v.fovIsHeight    = GetBool(vv, "fov_is_height", true);
            v.viewportAspect = static_cast<float>(GetDouble(vv, "viewport_aspect"));
            v.perspective    = GetBool(vv, "perspective", true);
            v.aspect      = static_cast<float>(GetDouble(vv, "aspect"));
            ReadVec(vv["eye"], v.eye);
            ReadVec(vv["target"], v.target);
            ReadVec(vv["up"], v.up);
            if (vv["height"].isNumeric())
            {
                v.height    = static_cast<float>(vv["height"].asDouble());
                v.hasHeight = true;
            }
            out.views.push_back(std::move(v));
        }

        // --- 정의와 루트 ---
        Parser parser;
        parser.blobSize = hdr.blobBytes;
        parser.blob     = out.blob.data();
        parser.opt      = &options;
        parser.warnings = &res.warnings;

        const Json::Value& defs = doc["definitions"];
        if (defs.isObject())
        {
            out.definitions.reserve(defs.size());
            for (const auto& key : defs.getMemberNames())
            {
                const Json::Value& dv = defs[key];
                Definition d;
                d.id            = GetString(dv, "id", key.c_str());
                d.name          = GetString(dv, "name");
                d.persistentId  = GetInt64(dv, "persistent_id");
                d.isGroup       = GetBool(dv, "is_group");
                d.instanceCount = static_cast<uint32_t>(GetInt64(dv, "instance_count"));

                if (!parser.ReadDefinitionBody(dv, "정의 " + key, d))
                {
                    res.error = parser.error;
                    return res;
                }
                out.definitions.emplace(key, std::move(d));
            }
        }

        out.root.id = "__root__";
        if (!parser.ReadDefinitionBody(doc["root"], "루트", out.root))
        {
            res.error = parser.error;
            return res;
        }

        // --- 통계 ---
        const Json::Value& st = doc["stats"];
        if (st.isObject())
        {
            out.stats.faces         = GetInt64(st, "faces");
            out.stats.triangles     = GetInt64(st, "triangles");
            out.stats.vertices      = GetInt64(st, "vertices");
            out.stats.instances     = GetInt64(st, "instances");
            out.stats.definitions   = GetInt64(st, "definitions");
            out.stats.faceErrors    = GetInt64(st, "face_errors");
            out.stats.groupsSkipped = GetInt64(st, "groups_skipped");
        }

        res.ok = true;
        return res;
    }

    ReadResult ReadIrisbFile(const std::filesystem::path& path, Scene& out, const ReadOptions& options)
    {
        ReadResult res;

        std::error_code ec;
        const auto fileSize = std::filesystem::file_size(path, ec);
        if (ec)
        {
            res.error = "파일 크기를 읽을 수 없습니다: " + path.string() + " (" + ec.message() + ")";
            return res;
        }

        std::ifstream f(path, std::ios::binary);
        if (!f)
        {
            res.error = "파일을 열 수 없습니다: " + path.string();
            return res;
        }

        std::vector<uint8_t> bytes(static_cast<size_t>(fileSize));
        f.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        if (static_cast<size_t>(f.gcount()) != bytes.size())
        {
            res.error = "파일을 끝까지 읽지 못했습니다: " + path.string();
            return res;
        }

        return ReadIrisbMemory(bytes.data(), bytes.size(), out, options);
    }
}
