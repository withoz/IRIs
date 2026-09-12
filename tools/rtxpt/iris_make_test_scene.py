# IRIS — 배선 시험용 합성 씬 생성기
#
# 왜 필요한가
#   조명·PBR 은 SketchUp -> 프로브 -> .irisb -> 리더 -> 씬 구축 -> 렌더러 로
#   여섯 단계를 지나갑니다. 어느 한 곳이 필드를 흘려도 **오류 없이 조용히**
#   조명이 사라집니다 (실제로 strip_def 가 필드를 떨어뜨릴 뻔했습니다).
#
#   SketchUp 을 열지 않고 그 경로 전체를 확인할 수 있어야 합니다. 값이
#   알려져 있으므로 렌더러 로그와 대조하면 배선이 맞는지 바로 압니다.
#
# 사용법:
#   python tools/rtxpt/iris_make_test_scene.py out/test/wiring.irisb
#   python tools/rtxpt/iris_send.py out/test/wiring.irisb
#   -> 추적 로그의 "조명 —" 줄이 아래 EXPECTED 와 같아야 합니다.

import json
import math
import os
import struct
import sys

MAGIC = b"IRISSCN1"
FMT_VER = 1

# 기대값 — 렌더러 로그의 "조명 —" 줄과 대조합니다.
#
# 나쁜 값 셋(bogus·negative·badcone)은 리더가 처리해야 합니다:
#   bogus    종류 불명   -> 버림
#   negative 세기 음수   -> 버림
#   badcone  원뿔 150도  -> 안전한 반각으로 조여서 **살림**
EXPECTED = {
    "point_lights": 2,      # PointLight 2개 (negative 는 버려짐)
    "spot_lights": 4,       # 스포트 2 + 사각 1 + badcone 1
    "emissive_materials": 1,
    "lumens": 1000.0 * 2 + 20000.0 * 2 + 3000.0 * 1 + 500.0,
}


def f32(values):
    return struct.pack("<%df" % len(values), *values)


def u32(values):
    return struct.pack("<%dI" % len(values), *values)


class Blob:
    def __init__(self):
        self.buf = bytearray()

    def floats(self, values):
        off = len(self.buf)
        self.buf += f32(values)
        return {"off": off, "count": len(values)}

    def uints(self, values):
        off = len(self.buf)
        self.buf += u32(values)
        return {"off": off, "count": len(values)}


def quad(blob, material, size=6.0, z=0.0):
    """XY 평면의 사각형 하나. 조명이 떨어질 바닥이 있어야 눈으로도 봅니다."""
    h = size * 0.5
    pos = [-h, -h, z,  h, -h, z,  h, h, z,  -h, h, z]
    nrm = [0.0, 0.0, 1.0] * 4
    uvs = [0.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0]
    return {
        "material": material,
        "positions": blob.floats(pos),
        "normals": blob.floats(nrm),
        "uvs": blob.floats(uvs),
        "indices": blob.uints([0, 1, 2, 0, 2, 3]),
    }


def translation(x, y, z):
    """열 우선 4x4. 프로브가 보내는 것과 같은 배치(이동은 [12..14])."""
    return [1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            x,   y,   z,   1.0]


def node(defn, name, x, y, z, material=None):
    return {
        "definition": defn,
        "entity_id": abs(hash(name)) % 100000,
        "persistent_id": abs(hash(name)) % 100000,
        "name": name,
        "transform": translation(x, y, z),
        "material": material,
        "layer": "Layer0",
        "hidden": False,
    }


def build():
    blob = Blob()

    materials = [
        {
            "id": "mat_floor",
            "name": "floor",
            "color": [0.5, 0.5, 0.5],
            "alpha": 1.0,
            "type": 0,
            "texture": None,
            # 실제 Enscape 값(_sofa fabric)을 그대로 씁니다.
            "pbr": {
                "etype": "GENERIC",
                "roughness": 0.83,
                "metalness": 0.109,
                "specular": 0.19,
                "opacity": 1.0,
                "ior": 0.0,
                "bump": 3.0,
                "normal_intensity": 0.0,
                "bump_type": "BUMP",
            },
        },
        {
            "id": "mat_panel",
            "name": "ceiling panel",
            "color": [1.0, 1.0, 1.0],
            "alpha": 1.0,
            "type": 0,
            "texture": None,
            # 실제 Enscape 값(SELF_ILLUMINATED)
            "pbr": {
                "etype": "SELF_ILLUMINATED",
                "roughness": 0.9,
                "metalness": 0.0,
                "specular": 0.5,
                "opacity": 1.0,
                "emissive": [1.0, 1.0, 1.0],
                "emissive_cd": 5076.72637359386,
            },
        },
        # --- 텍스처 알파 세 가지 ---------------------------------------
        #
        # 컷아웃(나뭇잎·타공판)의 구멍은 재질 알파가 아니라 **텍스처의 알파
        # 채널**에 있습니다. 셋 다 재질 알파는 1.0 입니다 — 그것만 보면
        # 전부 불투명으로 읽히는 것이 요점입니다(11번 (a)).
        #
        # 실제 모델로만 시험하면 이 값들은 사용자가 편집할 때마다 흔들리고,
        # 어느 날 조용히 0이 되어도 모릅니다.
        {
            "id": "mat_leaf",
            "name": "leaf cutout",
            "color": [1.0, 1.0, 1.0],
            "alpha": 1.0,
            "type": 1,
            # 세종 모델 mat_285(617x490, 38.6% 투명)를 본뜬 값
            "texture": {
                "file": "leaf.png", "export": "textures/mat_leaf.png",
                "width_m": 1.0, "height_m": 1.0, "pixels": [617, 490],
                "alpha": {"channel": True, "min": 0, "holes": 0.386},
            },
        },
        {
            "id": "mat_tile",
            "name": "tile (알파 채널은 있으나 구멍 없음)",
            "color": [1.0, 1.0, 1.0],
            "alpha": 1.0,
            "type": 1,
            "texture": {
                "file": "tile.png", "export": "textures/mat_tile.png",
                "width_m": 0.6, "height_m": 0.6, "pixels": [500, 500],
                "alpha": {"channel": True, "min": 255, "holes": 0.0},
            },
        },
        {
            "id": "mat_bigtex",
            "name": "big texture (프로브가 픽셀을 못 잼)",
            "color": [1.0, 1.0, 1.0],
            "alpha": 1.0,
            "type": 1,
            # 'min'·'holes' 가 없습니다 — 큰 이미지라 프로브가 안 훑은 경우.
            # 미지정이면 **켜는 쪽**이 안전합니다(IrisbReader.h Texture 주석).
            "texture": {
                "file": "big.png", "export": "textures/mat_bigtex.png",
                "width_m": 4.0, "height_m": 4.0, "pixels": [4096, 4096],
                "alpha": {"channel": True},
            },
        },
    ]

    definitions = {
        "def_floor": {
            "id": "def_floor", "name": "floor",
            "meshes": [quad(blob, "mat_floor", 12.0, 0.0)],
            "children": [], "persistent_id": 1, "is_group": False,
            "instance_count": 1,
        },
        "def_panel": {
            "id": "def_panel", "name": "ceiling panel",
            "meshes": [quad(blob, "mat_panel", 2.0, 0.0)],
            "children": [], "persistent_id": 2, "is_group": False,
            "instance_count": 1,
        },
        # --- 광원 프록시: 지오메트리 없음 ---
        "def_spot": {
            "id": "def_spot", "name": "Enscape.SpotLight#1",
            "meshes": [], "children": [], "persistent_id": 3, "is_group": False,
            "instance_count": 2,
            "light": {
                "kind": "spot",
                "color": [1.0, 1.0, 1.0],
                "lumens": 20000.0,
                # 실제 Bega 8331WIDE 에서 유도한 값
                "inner": 29.83,
                "outer": 54.25,
                "radius": 0.025,
                "intensity": 20000.0 * 5968.7 / 5088.1,
                "ies_file": "Bega.8331WIDE.IES",
            },
        },
        "def_point": {
            "id": "def_point", "name": "Enscape.PointLight",
            "meshes": [], "children": [], "persistent_id": 4, "is_group": False,
            "instance_count": 2,
            "light": {
                "kind": "point",
                "color": [1.0, 0.9, 0.8],
                "lumens": 1000.0,
                "radius": 0.0,
                "intensity": 1000.0 / (4.0 * math.pi),
            },
        },
        "def_rect": {
            "id": "def_rect", "name": "Enscape.RectangularLight",
            "meshes": [], "children": [], "persistent_id": 5, "is_group": False,
            "instance_count": 1,
            "light": {
                "kind": "rect",
                "color": [1.0, 1.0, 1.0],
                "lumens": 3000.0,
                "width": 1.2,
                "length": 0.6,
                "radiance": 3000.0 / (math.pi * 1.2 * 0.6),
            },
        },
        # --- 방어 경로 ---
        #
        # JSON 은 NaN 을 담지 못하므로(jsoncpp 가 파일 전체를 거부합니다)
        # 실제로 도달 가능한 나쁜 값으로 시험합니다.

        # 알 수 없는 종류 — 조용히 무시되어야 합니다.
        "def_bogus": {
            "id": "def_bogus", "name": "Enscape.WeirdLight",
            "meshes": [], "children": [], "persistent_id": 6, "is_group": False,
            "instance_count": 1,
            "light": {"kind": "hyperbolic", "lumens": 1e9, "intensity": 1e9},
        },
        # 세기가 음수 — 광원으로 만들면 광원 선택 가중치가 무너집니다.
        "def_negative": {
            "id": "def_negative", "name": "Enscape.PointLight(negative)",
            "meshes": [], "children": [], "persistent_id": 7, "is_group": False,
            "instance_count": 1,
            "light": {"kind": "point", "lumens": -5.0, "intensity": -1234.0},
        },
        # 원뿔각이 반각 범위를 벗어남 — 리더가 안전한 값으로 조여야 합니다.
        # (전각을 반각 자리에 넣는 실수가 이렇게 나타납니다)
        "def_badcone": {
            "id": "def_badcone", "name": "Enscape.SpotLight(badcone)",
            "meshes": [], "children": [], "persistent_id": 8, "is_group": False,
            "instance_count": 1,
            "light": {
                "kind": "spot", "lumens": 500.0, "intensity": 400.0,
                "radius": 0.02, "inner": 170.0, "outer": 150.0,
            },
        },
    }

    children = [
        node("def_floor", "floor", 0.0, 0.0, 0.0),
        node("def_panel", "panel", 0.0, 0.0, 3.0),
        node("def_spot", "spot A", -2.0, 0.0, 3.0),
        node("def_spot", "spot B", 2.0, 0.0, 3.0),
        node("def_point", "point A", 0.0, -2.0, 2.0),
        node("def_point", "point B", 0.0, 2.0, 2.0),
        node("def_rect", "rect A", 3.0, 3.0, 2.5),
        node("def_bogus", "bogus", 5.0, 5.0, 2.0),
        node("def_negative", "negative", 5.0, -5.0, 2.0),
        node("def_badcone", "badcone", -5.0, 5.0, 2.0),
    ]

    scene = {
        "format": "iris.sketchup.scene",
        "version": "0.1.0",
        "unit": "meter",
        "up_axis": "z",
        "handedness": "right",
        "source": {"app": "iris_make_test_scene.py", "title": "wiring", "file": ""},
        "capabilities": {},
        "materials": materials,
        "views": [{
            "name": "IRIS_Default",
            "eye": [8.0, -8.0, 5.0],
            "target": [0.0, 0.0, 1.0],
            "up": [0.0, 0.0, 1.0],
            "fov": 60.0,
            "fov_is_height": True,
            "viewport_aspect": 16.0 / 9.0,
            "perspective": True,
        }],
        "definitions": definitions,
        "root": {"meshes": [], "children": children},
        "stats": {
            "faces": 2, "triangles": 4, "vertices": 8,
            "instances": len(children), "definitions": len(definitions),
            "face_errors": 0, "groups_skipped": 0,
        },
        "binary": {"layout": "separate", "bytes": len(blob.buf)},
    }
    return scene, bytes(blob.buf)


def pack(scene, blob):
    raw = json.dumps(scene, ensure_ascii=False).encode("utf-8")
    raw += b" " * ((8 - len(raw) % 8) % 8)
    head = MAGIC + struct.pack("<II", FMT_VER, 0) + struct.pack("<QQ", len(raw), len(blob))
    return head + raw + blob


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "out/test/wiring.irisb"
    scene, blob = build()
    data = pack(scene, blob)
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "wb") as f:
        f.write(data)
    print("wrote %s  (%d bytes)" % (out, len(data)))
    print("expect: point=%d spot=%d lumens=%.0f emissive=%d" % (
        EXPECTED["point_lights"], EXPECTED["spot_lights"],
        EXPECTED["lumens"], EXPECTED["emissive_materials"]))
    print("  (def_bogus must be ignored: unknown kind + NaN intensity)")


if __name__ == "__main__":
    main()
