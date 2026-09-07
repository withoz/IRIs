#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IRIS — SketchUp 프로브 JSON → glTF(.glb) 변환기

이것이 SketchUp 트랙과 렌더링 트랙이 처음 만나는 지점이다.
[`tools/sketchup/iris_probe.rb`](../sketchup/iris_probe.rb)가 뽑은 씬을 RTXPT(Donut)가
읽을 수 있는 glTF 2.0으로 바꾼다.

사용법
  python iris_json_to_gltf.py <probe.iris.json> <out.glb> [--scene-json <out.scene.json>]

  --scene-json 을 주면 RTXPT용 .scene.json 도 함께 만든다. 둘 다 RTXPT의 Assets 폴더
  아래에 두고 RTXPT를 재시작하면 씬 목록에 나타난다.

설계
  정의(definition) → glTF **mesh**   : 메시 데이터는 참조로 공유된다 = BLAS 재사용
  인스턴스          → glTF **node**   : 노드는 복제되지만 메시는 공유 = TLAS 인스턴스
  머티리얼 버킷      → mesh **primitive** : 프리미티브 하나당 머티리얼 하나

  프로브 실측 기준 정의 425개 / 인스턴스 1,699개였으므로, 이 매핑이 지오메트리 메모리를
  4배 절약한다.

좌표계
  SketchUp: Z-up, 오른손. glTF: Y-up, 오른손.
  정점을 건드리지 않고 **루트 노드에 X축 -90° 회전**을 걸어 변환한다. 원본 좌표가
  그대로 남아 있어야 나중에 SketchUp으로 되돌리는 경로(라이브 링크 역방향)가 쉬워진다.

텍스처
  프로브가 `ImageRep#save_as` 로 .skp 내부 텍스처를 PNG로 뽑아 두면(materials[].texture.export)
  그 파일을 읽어 **.glb 안에 임베드**한다. 외부 파일 배치가 필요 없다.
  UV는 SketchUp(좌하단 원점) → glTF(좌상단 원점) 변환을 위해 V를 뒤집는다.
  샘플러는 REPEAT — SketchUp 텍스처는 타일링이 기본이라 UV가 1을 크게 넘는다.

알려진 한계
  - **재질 상속 미해결.** 면에 재질이 없으면 SketchUp은 상위 인스턴스 재질을 쓴다.
    glTF는 메시를 공유하므로 인스턴스별 재질 오버라이드를 표현할 수 없다. 제대로 하려면
    메시를 재질별로 복제해야 하고 그러면 인스턴싱 이득이 사라진다
  - 레이어(태그)·persistent_id 는 glTF에 실을 자리가 없어 버려진다. 증분 동기화를
    구현할 때는 glTF가 아니라 자체 프로토콜을 써야 한다는 뜻이다
"""

import argparse
import base64
import io
import json
import os
import struct
import sys

GLTF_FLOAT = 5126
GLTF_UINT32 = 5125
ARRAY_BUFFER = 34962
ELEMENT_ARRAY_BUFFER = 34963

# 노드 폭증 방지. 정의가 서로를 깊게 중첩하면 인스턴스화한 노드 수가 폭발할 수 있다.
MAX_NODES = 500000


class GltfBuilder(object):
    def __init__(self):
        self.buffer = bytearray()
        self.bufferViews = []
        self.accessors = []
        self.meshes = []
        self.nodes = []
        self.materials = []
        self.images = []
        self.textures = []
        self.samplers = []

    # ---------------------------------------------------------------- 버퍼

    def _align4(self):
        while len(self.buffer) % 4:
            self.buffer.append(0)

    def _add_view(self, data, target):
        self._align4()
        offset = len(self.buffer)
        self.buffer.extend(data)
        self.bufferViews.append({
            "buffer": 0, "byteOffset": offset, "byteLength": len(data), "target": target,
        })
        return len(self.bufferViews) - 1

    def add_floats(self, values, comp_count, with_minmax=False):
        """values: flat float list. comp_count: 3(VEC3) 또는 2(VEC2)."""
        data = struct.pack("<%df" % len(values), *values)
        view = self._add_view(data, ARRAY_BUFFER)
        acc = {
            "bufferView": view,
            "componentType": GLTF_FLOAT,
            "count": len(values) // comp_count,
            "type": {2: "VEC2", 3: "VEC3"}[comp_count],
        }
        if with_minmax:
            # glTF 사양상 POSITION 접근자는 min/max 필수
            mins = [float("inf")] * comp_count
            maxs = [float("-inf")] * comp_count
            for i in range(0, len(values), comp_count):
                for c in range(comp_count):
                    v = values[i + c]
                    if v < mins[c]:
                        mins[c] = v
                    if v > maxs[c]:
                        maxs[c] = v
            acc["min"] = mins
            acc["max"] = maxs
        self.accessors.append(acc)
        return len(self.accessors) - 1

    def add_indices(self, values):
        data = struct.pack("<%dI" % len(values), *values)
        view = self._add_view(data, ELEMENT_ARRAY_BUFFER)
        self.accessors.append({
            "bufferView": view,
            "componentType": GLTF_UINT32,
            "count": len(values),
            "type": "SCALAR",
        })
        return len(self.accessors) - 1

    def add_image(self, data, mime):
        """이미지 바이트를 버퍼에 임베드하고 glTF image 인덱스를 반환.

        .glb 하나로 끝나도록 외부 참조 대신 임베드한다. RTXPT Assets 폴더에
        텍스처 파일을 따로 배치할 필요가 없어진다.
        """
        self._align4()
        offset = len(self.buffer)
        self.buffer.extend(data)
        # 이미지 bufferView 에는 target 을 주지 않는다 (glTF 사양)
        self.bufferViews.append({
            "buffer": 0, "byteOffset": offset, "byteLength": len(data),
        })
        self.images.append({"bufferView": len(self.bufferViews) - 1, "mimeType": mime})
        return len(self.images) - 1


# SketchUp 기본 면 색 근사. 재질을 지정하지 않은 면에 쓴다.
DEFAULT_MATERIAL_KEY = "__iris_default__"


REPEAT = 10497
LINEAR = 9729
LINEAR_MIPMAP_LINEAR = 9987


def load_texture(builder, tex, base_dir, cache):
    """프로브가 뽑아둔 PNG를 glTF texture 인덱스로. 실패하면 None."""
    rel = (tex or {}).get("export")
    if not rel:
        return None
    if rel in cache:
        return cache[rel]

    path = os.path.join(base_dir, rel.replace("/", os.sep))
    if not os.path.isfile(path):
        cache[rel] = None
        return None
    with open(path, "rb") as f:
        data = f.read()

    if not builder.samplers:
        # SketchUp 텍스처는 타일링이 기본. UV가 1을 훨씬 넘으므로 REPEAT 필수.
        builder.samplers.append({
            "magFilter": LINEAR, "minFilter": LINEAR_MIPMAP_LINEAR,
            "wrapS": REPEAT, "wrapT": REPEAT,
        })
    img = builder.add_image(data, "image/png")
    builder.textures.append({"sampler": 0, "source": img})
    cache[rel] = len(builder.textures) - 1
    return cache[rel]


def convert_materials(builder, src_materials, base_dir=None):
    """프로브 머티리얼 → glTF 머티리얼. id → glTF 인덱스 맵을 반환.

    ⚠ 머티리얼이 **없는** 프리미티브를 위한 기본 머티리얼을 반드시 하나 넣는다.
    Donut의 glTF 임포터는 material 없는 프리미티브에서 죽는다(실측: 세그폴트).
    실제 SketchUp 모델은 면의 40%가 재질 미지정이라 이 경로를 반드시 탄다.
    """
    index_of = {}
    builder.materials.append({
        "name": "IRIS_Default",
        "pbrMetallicRoughness": {
            "baseColorFactor": [0.78, 0.78, 0.76, 1.0],
            "metallicFactor": 0.0,
            "roughnessFactor": 0.8,
        },
        "doubleSided": True,
    })
    index_of[DEFAULT_MATERIAL_KEY] = 0
    cache = {}
    for m in src_materials:
        color = m.get("color") or [1.0, 1.0, 1.0]
        alpha = m.get("alpha")
        alpha = 1.0 if alpha is None else float(alpha)
        gm = {
            "name": m.get("name") or m.get("id", ""),
            "pbrMetallicRoughness": {
                "baseColorFactor": [float(color[0]), float(color[1]), float(color[2]), alpha],
                "metallicFactor": 0.0,
                "roughnessFactor": 0.7,
            },
            "doubleSided": True,   # SketchUp 면은 양면이 기본
        }

        tex_idx = load_texture(builder, m.get("texture"), base_dir, cache) if base_dir else None
        if tex_idx is not None:
            gm["pbrMetallicRoughness"]["baseColorTexture"] = {"index": tex_idx, "texCoord": 0}
            # image_rep(true) 로 뽑을 때 머티리얼 색이 이미 이미지에 반영되어 있다.
            # 여기서 색을 또 곱하면 이중 적용된다.
            gm["pbrMetallicRoughness"]["baseColorFactor"] = [1.0, 1.0, 1.0, alpha]

        if alpha < 0.999:
            gm["alphaMode"] = "BLEND"
        builder.materials.append(gm)
        index_of[m["id"]] = len(builder.materials) - 1
    return index_of


def build_mesh(builder, meshes, mat_index, name):
    """프로브 메시 버킷 목록 → glTF mesh. 비어 있으면 None."""
    primitives = []
    for mb in meshes:
        pos = mb.get("positions") or []
        idx = mb.get("indices") or []
        if not pos or not idx:
            continue
        attrs = {"POSITION": builder.add_floats(pos, 3, with_minmax=True)}
        nrm = mb.get("normals") or []
        if len(nrm) == len(pos):
            attrs["NORMAL"] = builder.add_floats(nrm, 3)
        uvs = mb.get("uvs") or []
        if uvs and len(uvs) // 2 == len(pos) // 3:
            # SketchUp UV 원점은 좌하단, glTF는 좌상단. V를 뒤집는다.
            # 타일링(1 초과 값)이 있어도 1-v 는 그대로 성립한다.
            flipped = list(uvs)
            for i in range(1, len(flipped), 2):
                flipped[i] = 1.0 - flipped[i]
            attrs["TEXCOORD_0"] = builder.add_floats(flipped, 2)

        prim = {"attributes": attrs, "indices": builder.add_indices(idx), "mode": 4}
        mid = mb.get("material")
        # material 은 **항상** 붙인다. 없으면 기본 머티리얼로. (위 convert_materials 주석 참조)
        prim["material"] = mat_index.get(mid, mat_index[DEFAULT_MATERIAL_KEY])
        primitives.append(prim)

    if not primitives:
        return None
    builder.meshes.append({"name": name, "primitives": primitives})
    return len(builder.meshes) - 1


def normalize_matrix(m):
    """SketchUp 4x4(열 우선). 마지막 원소가 1이 아니면 전체를 그것으로 나눈다.

    SketchUp 변환행렬은 16번째 원소에 균일 스케일 제수를 담을 수 있다. 점 변환이
    (M*p)/w 이므로 앞 15개를 w로 나누면 동등하면서 w=1인 행렬이 된다.
    프로브가 이미 평행이동을 미터로 바꿔 두었는데, 균일 나눗셈이라 순서는 무관하다.
    """
    m = [float(x) for x in m]
    if len(m) != 16:
        return None
    w = m[15]
    if abs(w) < 1e-12:
        return None
    if abs(w - 1.0) > 1e-9:
        m = [v / w for v in m[:15]] + [1.0]
    return m


class NodeEmitter(object):
    def __init__(self, builder, doc, mat_index):
        self.b = builder
        self.doc = doc
        self.mat_index = mat_index
        self.def_mesh = {}       # definition id → glTF mesh index (또는 None)
        self.overflow = False
        self.skipped_tf = 0

    def mesh_for_definition(self, def_id):
        if def_id in self.def_mesh:
            return self.def_mesh[def_id]
        d = self.doc["definitions"].get(def_id)
        if d is None:
            self.def_mesh[def_id] = None
            return None
        # 자리 예약 = 순환 참조 가드 (프로브도 같은 방식으로 막는다)
        self.def_mesh[def_id] = None
        self.def_mesh[def_id] = build_mesh(
            self.b, d.get("meshes") or [], self.mat_index, d.get("name") or def_id)
        return self.def_mesh[def_id]

    def emit_children(self, children, depth=0):
        """인스턴스 목록 → glTF 노드 인덱스 목록."""
        out = []
        if depth > 32:
            return out
        for inst in children:
            if len(self.b.nodes) >= MAX_NODES:
                self.overflow = True
                break
            if inst.get("hidden"):
                continue
            def_id = inst.get("definition")
            d = self.doc["definitions"].get(def_id)
            if d is None:
                continue

            node = {"name": inst.get("name") or def_id}
            m = normalize_matrix(inst.get("transform") or [])
            if m is None:
                self.skipped_tf += 1
            elif m != [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]:
                node["matrix"] = m

            mesh_idx = self.mesh_for_definition(def_id)
            if mesh_idx is not None:
                node["mesh"] = mesh_idx

            kids = self.emit_children(d.get("children") or [], depth + 1)
            if kids:
                node["children"] = kids

            if "mesh" not in node and "children" not in node:
                continue    # 빈 노드는 버린다

            self.b.nodes.append(node)
            out.append(len(self.b.nodes) - 1)
        return out


def convert(doc, base_dir=None):
    b = GltfBuilder()
    mat_index = convert_materials(b, doc.get("materials") or [], base_dir)

    emitter = NodeEmitter(b, doc, mat_index)

    root = doc.get("root") or {}
    top = emitter.emit_children(root.get("children") or [])

    # 최상위에 흩어져 있는 면들 (그룹/컴포넌트에 속하지 않은 지오메트리)
    loose = build_mesh(b, root.get("meshes") or [], mat_index, "loose_geometry")
    if loose is not None:
        b.nodes.append({"name": "loose_geometry", "mesh": loose})
        top.append(len(b.nodes) - 1)

    # Z-up → Y-up: X축 -90°. 정점을 건드리지 않고 루트 노드에서 회전시킨다.
    q = -(0.5 ** 0.5)
    b.nodes.append({"name": "IRIS_ZUP_TO_YUP", "rotation": [q, 0.0, 0.0, -q], "children": top})
    scene_root = len(b.nodes) - 1

    src = doc.get("source") or {}
    gltf = {
        "asset": {
            "version": "2.0",
            "generator": "IRIS iris_json_to_gltf.py (from %s)" % (src.get("app") or "SketchUp"),
        },
        "scene": 0,
        "scenes": [{"nodes": [scene_root]}],
        "nodes": b.nodes,
        "meshes": b.meshes,
        "accessors": b.accessors,
        "bufferViews": b.bufferViews,
        "buffers": [{"byteLength": len(b.buffer)}],
    }
    if b.materials:
        gltf["materials"] = b.materials
    if b.images:
        gltf["images"] = b.images
        gltf["textures"] = b.textures
        gltf["samplers"] = b.samplers
    return gltf, bytes(b.buffer), emitter


def _mat_apply(m, p):
    """열 우선 4x4에 점을 적용."""
    x, y, z = p
    return (m[0] * x + m[4] * y + m[8] * z + m[12],
            m[1] * x + m[5] * y + m[9] * z + m[13],
            m[2] * x + m[6] * y + m[10] * z + m[14])


def _mat_mul(a, b):
    """열 우선 4x4 곱 a*b."""
    out = [0.0] * 16
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4))
    return out


IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]


def scene_bounds(doc, percentile=None):
    """씬 바운딩 박스를 **glTF(Y-up) 공간**으로 계산.

    SketchUp Z-up (x,y,z) → glTF Y-up (x, z, -y).

    percentile 을 주면(예: 2.0) 양 끝 그만큼을 잘라낸 박스를 돌려준다.
    건축 대지 모델은 도로·주변 필지 같은 컨텍스트가 수 km 뻗어 있는 경우가 많아
    절대 min/max 로 프레이밍하면 정작 건물이 점이 된다(실측: 대지 1,909 m).
    """
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    defs = doc.get("definitions") or {}
    samples = [[], [], []] if percentile else None

    def acc(p):
        # Z-up → Y-up
        q = (p[0], p[2], -p[1])
        for i in range(3):
            if q[i] < lo[i]:
                lo[i] = q[i]
            if q[i] > hi[i]:
                hi[i] = q[i]
            if samples is not None:
                samples[i].append(q[i])

    def visit(node, xf, depth):
        if depth > 32:
            return
        for mb in node.get("meshes") or []:
            pos = mb.get("positions") or []
            # 정점이 많으면 표본만 봐도 박스는 충분히 잡힌다
            step = 3 * max(1, (len(pos) // 3) // 4000)
            for i in range(0, len(pos) - 2, step):
                acc(_mat_apply(xf, (pos[i], pos[i + 1], pos[i + 2])))
        for inst in node.get("children") or []:
            if inst.get("hidden"):
                continue
            d = defs.get(inst.get("definition"))
            if d is None:
                continue
            m = normalize_matrix(inst.get("transform") or []) or IDENTITY
            visit(d, _mat_mul(xf, m), depth + 1)

    visit(doc.get("root") or {}, IDENTITY, 0)

    if lo[0] > hi[0]:      # 지오메트리 없음
        return [-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]

    if samples is not None and samples[0]:
        plo, phi = [0.0] * 3, [0.0] * 3
        for i in range(3):
            s = sorted(samples[i])
            k = max(0, min(len(s) - 1, int(len(s) * percentile / 100.0)))
            plo[i], phi[i] = s[k], s[len(s) - 1 - k]
        # 축이 통째로 눌리면(평평한 대지 등) 그 축은 원래 값을 쓴다
        for i in range(3):
            if phi[i] - plo[i] < 1e-6:
                plo[i], phi[i] = lo[i], hi[i]
        return plo, phi
    return lo, hi


def _quat_from_axes(xc, yc, zc):
    """열이 xc,yc,zc 인 회전행렬 → 쿼터니언 [x,y,z,w]."""
    m00, m01, m02 = xc[0], yc[0], zc[0]
    m10, m11, m12 = xc[1], yc[1], zc[1]
    m20, m21, m22 = xc[2], yc[2], zc[2]
    tr = m00 + m11 + m22
    if tr > 0:
        s = (tr + 1.0) ** 0.5 * 2
        return [(m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25 * s]
    if m00 > m11 and m00 > m22:
        s = (1.0 + m00 - m11 - m22) ** 0.5 * 2
        return [0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s]
    if m11 > m22:
        s = (1.0 + m11 - m00 - m22) ** 0.5 * 2
        return [(m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m02 - m20) / s]
    s = (1.0 + m22 - m00 - m11) ** 0.5 * 2
    return [(m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m10 - m01) / s]


def zup_to_yup(p):
    """SketchUp Z-up → glTF Y-up."""
    return [p[0], p[2], -p[1]]


def look_at_rotation(eye, target, up):
    """eye→target 을 보는 카메라의 쿼터니언. 실패하면 None."""
    import math
    fwd = [target[i] - eye[i] for i in range(3)]
    n = math.sqrt(sum(v * v for v in fwd))
    if n < 1e-9:
        return None
    zc = [-fwd[i] / n for i in range(3)]          # 카메라 +Z 는 시선 반대

    xc = [up[1] * zc[2] - up[2] * zc[1],
          up[2] * zc[0] - up[0] * zc[2],
          up[0] * zc[1] - up[1] * zc[0]]
    n = math.sqrt(sum(v * v for v in xc))
    if n < 1e-9:
        # up 이 시선과 평행하면 다른 축으로 다시 시도
        alt = [0.0, 0.0, 1.0] if abs(zc[1]) > 0.9 else [0.0, 1.0, 0.0]
        xc = [alt[1] * zc[2] - alt[2] * zc[1],
              alt[2] * zc[0] - alt[0] * zc[2],
              alt[0] * zc[1] - alt[1] * zc[0]]
        n = math.sqrt(sum(v * v for v in xc))
        if n < 1e-9:
            return None
    xc = [v / n for v in xc]
    yc = [zc[1] * xc[2] - zc[2] * xc[1],
          zc[2] * xc[0] - zc[0] * xc[2],
          zc[0] * xc[1] - zc[1] * xc[0]]
    return _quat_from_axes(xc, yc, zc)


def view_to_camera_node(v, index):
    """프로브가 뽑은 SketchUp 장면 카메라 → RTXPT PerspectiveCamera 노드."""
    import math
    if not v.get("perspective", True):
        return None            # 평행투영은 RTXPT가 다루지 않는다
    eye = zup_to_yup(v.get("eye") or [0, 0, 0])
    tgt = zup_to_yup(v.get("target") or [0, 0, 1])
    up = zup_to_yup(v.get("up") or [0, 0, 1])
    q = look_at_rotation(eye, tgt, up)
    if q is None:
        return None

    fov_deg = v.get("fov_deg") or 60.0
    dist = math.sqrt(sum((tgt[i] - eye[i]) ** 2 for i in range(3)))
    return {
        "name": "SU_%02d_%s" % (index, (v.get("name") or "view").replace(" ", "_")),
        "type": "PerspectiveCamera",
        "translation": [round(x, 5) for x in eye],
        "rotation": [round(x, 7) for x in q],
        "verticalFov": round(math.radians(float(fov_deg)), 6),
        "zNear": max(1e-3, min(0.05, dist * 1e-3)),
        "exposureValue": -1.0,
        "enableAutoExposure": True,
        "exposureCompensation": 1.2,
        "exposureValueMin": -4.0,
        "exposureValueMax": 6.0,
    }


def camera_pos_dir_up(v):
    """RTXPT `--cameraPosDirUp` 인자 문자열 (9개 콤마 구분)."""
    import math
    eye = zup_to_yup(v.get("eye") or [0, 0, 0])
    tgt = zup_to_yup(v.get("target") or [0, 0, 1])
    up = zup_to_yup(v.get("up") or [0, 0, 1])
    d = [tgt[i] - eye[i] for i in range(3)]
    n = math.sqrt(sum(x * x for x in d)) or 1.0
    d = [x / n for x in d]
    return ",".join("%.5f" % x for x in (eye + d + up))


def camera_node(bmin, bmax, fov=1.04):
    """바운딩 박스를 화면에 담는 3/4 시점 카메라 노드 (glTF Y-up 공간)."""
    import math

    center = [(bmin[i] + bmax[i]) * 0.5 for i in range(3)]
    radius = max(1e-3, 0.5 * math.sqrt(sum((bmax[i] - bmin[i]) ** 2 for i in range(3))))
    dist = radius / math.sin(fov * 0.5) * 1.15

    d = [1.0, 0.45, 1.0]                       # 오른쪽 위 앞에서 내려다보는 방향
    n = math.sqrt(sum(v * v for v in d))
    d = [v / n for v in d]
    eye = [center[i] + d[i] * dist for i in range(3)]

    zc = d                                      # 카메라 +Z 는 시선 반대
    up = [0.0, 1.0, 0.0]
    xc = [up[1] * zc[2] - up[2] * zc[1], up[2] * zc[0] - up[0] * zc[2], up[0] * zc[1] - up[1] * zc[0]]
    n = math.sqrt(sum(v * v for v in xc)) or 1.0
    xc = [v / n for v in xc]
    yc = [zc[1] * xc[2] - zc[2] * xc[1], zc[2] * xc[0] - zc[0] * xc[2], zc[0] * xc[1] - zc[1] * xc[0]]

    return {
        "name": "IRIS_Auto", "type": "PerspectiveCamera",
        "translation": [round(v, 5) for v in eye],
        "rotation": [round(v, 7) for v in _quat_from_axes(xc, yc, zc)],
        "verticalFov": fov,
        "zNear": max(1e-4, radius * 1e-4),
        # 노출은 기존 RTXPT 씬(bistro)과 같은 자동노출 설정을 따른다.
        # 이게 없으면 건축 모델이 전반적으로 어둡게 나온다.
        "exposureValue": -1.0,
        "enableAutoExposure": True,
        "exposureCompensation": 1.2,
        "exposureValueMin": -4.0,
        "exposureValueMax": 6.0,
    }


def write_glb(path, gltf, blob):
    js = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    bin_pad = blob + b"\0" * ((4 - len(blob) % 4) % 4)

    total = 12 + 8 + len(js) + (8 + len(bin_pad) if bin_pad else 0)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A))
        f.write(js)
        if bin_pad:
            f.write(struct.pack("<II", len(bin_pad), 0x004E4942))
            f.write(bin_pad)


def main():
    ap = argparse.ArgumentParser(description="SketchUp 프로브 JSON을 glTF(.glb)로 변환")
    ap.add_argument("input", help="프로브가 만든 .iris.json")
    ap.add_argument("output", nargs="?", help="출력 .glb (--list-views 시 생략 가능)")
    ap.add_argument("--scene-json", help="RTXPT용 .scene.json 도 생성")
    ap.add_argument("--list-views", action="store_true",
                    help="저장된 SketchUp 장면 카메라를 RTXPT 인자 형식으로 출력하고 종료")
    ap.add_argument("--frame-percentile", type=float, default=2.0,
                    help="카메라 프레이밍용 바운딩 박스에서 잘라낼 양 끝 비율(%%). "
                         "0이면 전체 범위. 기본 2.0 (멀리 있는 컨텍스트 지오메트리 무시)")
    ap.add_argument("--envmap",
                    default="EnvironmentMaps/kloofendal_48d_partly_cloudy_puresky_4k_cube_bc6u.dds",
                    help="환경광 큐브맵 (RTXPT Assets 기준 상대경로)")
    args = ap.parse_args()

    with io.open(args.input, encoding="utf-8") as f:
        doc = json.load(f)

    if not args.list_views and not args.output:
        print("출력 경로가 필요합니다 (또는 --list-views)")
        return 1

    if args.list_views:
        views = doc.get("views") or []
        print("저장된 시점 %d개 (RTXPT --cameraPosDirUp 인자)" % len(views))
        for i, v in enumerate(views):
            eye = v.get("eye") or [0, 0, 0]
            tgt = v.get("target") or [0, 0, 0]
            # SketchUp Z-up 기준 높이. 실내 시점은 대개 바닥+1.5m 근처다.
            print("  [%2d] %-28s 높이 %7.2f m  fov %s  %s"
                  % (i, (v.get("name") or "")[:28], eye[2], v.get("fov_deg"),
                     "직교" if not v.get("perspective", True) else ""))
            print("       --cameraPosDirUp %s" % camera_pos_dir_up(v))
        return 0

    if doc.get("format") != "iris.sketchup.scene":
        print("경고: format 이 'iris.sketchup.scene' 이 아닙니다: %r" % doc.get("format"))

    # 텍스처 상대경로는 프로브 JSON 위치 기준이다.
    base_dir = os.path.dirname(os.path.abspath(args.input))
    gltf, blob, em = convert(doc, base_dir)
    write_glb(args.output, gltf, blob)

    n_prims = sum(len(m["primitives"]) for m in gltf["meshes"])
    print("생성: %s  (%.2f MB)" % (args.output, os.path.getsize(args.output) / 1048576.0))
    print("  메시(정의) %d · 프리미티브 %d · 노드 %d · 머티리얼 %d · 텍스처 %d"
          % (len(gltf["meshes"]), n_prims, len(gltf["nodes"]),
             len(gltf.get("materials") or []), len(gltf.get("textures") or [])))
    stats = doc.get("stats") or {}
    if stats:
        print("  원본 통계: 면 %s · 삼각형 %s · 정의 %s · 인스턴스 %s"
              % (stats.get("faces"), stats.get("triangles"),
                 stats.get("definitions"), stats.get("instances")))
    if em.overflow:
        print("  ⚠ 노드 수가 %d 를 넘어 잘렸습니다" % MAX_NODES)
    if em.skipped_tf:
        print("  ⚠ 변환행렬이 부적합한 인스턴스 %d 개는 항등으로 처리했습니다" % em.skipped_tf)

    if args.scene_json:
        model_rel = os.path.basename(args.output)
        pct = args.frame_percentile if args.frame_percentile > 0 else None
        bmin, bmax = scene_bounds(doc, pct)
        fmin, fmax = scene_bounds(doc, None)
        scene = {
            "models": [model_rel],
            "graph": [
                {"name": "IRIS_SketchUp", "model": 0},
                {"name": "Sky", "type": "EnvironmentLight",
                 "radianceScale": [1, 1, 1], "textureIndex": [0], "rotation": [0],
                 "path": args.envmap},
                camera_node(bmin, bmax),
                {"name": "SampleSettings", "type": "SampleSettings",
                 "realtimeMode": True, "enableAnimations": False},
            ],
        }
        # SketchUp 장면(Page)에 저장된 시점을 카메라로 추가한다.
        # 설계자가 잡아둔 시점이라 임의 카메라보다 낫다.
        su_cams = []
        for i, v in enumerate(doc.get("views") or []):
            node = view_to_camera_node(v, i)
            if node:
                su_cams.append(node)
        scene["graph"].extend(su_cams)
        with io.open(args.scene_json, "w", encoding="utf-8") as f:
            json.dump(scene, f, indent=2, ensure_ascii=False)
        size = [bmax[i] - bmin[i] for i in range(3)]
        full = [fmax[i] - fmin[i] for i in range(3)]
        print("생성: %s" % args.scene_json)
        print("  전체 범위(Y-up, m): %.1f x %.1f x %.1f" % (full[0], full[1], full[2]))
        print("  프레이밍 범위(%.0f%% 절단): %.1f x %.1f x %.1f"
              % (args.frame_percentile, size[0], size[1], size[2]))
        print("  환경광: %s" % args.envmap)
        print("  SketchUp 장면 카메라: %d개 추가" % len(su_cams))
    return 0


if __name__ == "__main__":
    sys.exit(main())
