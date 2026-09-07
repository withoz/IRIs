#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IRIS — RTXPT 다광원 테스트 씬 생성기

목적
  자료집 4.1은 RTXDI(ReSTIR)를 "수천~수십만 광원 실시간 처리의 핵심"이라 하고,
  "건축 실내 조명에 결정적"이라고 적었다. 그런데 RTXPT 기본 제공 씬은 해석적 광원이
  최대 71개(bistro)뿐이라 그 조건을 재볼 수 없다. 실제 건축 실내는 다운라이트가
  수백 개다.

  이 스크립트는 kitchen 씬에 천장 다운라이트를 격자로 깔아 그 조건을 만든다.
  ReSTIR ON/OFF 비교의 교차점을 찾는 것이 목적이다.

사용법
  python gen_light_scene.py <RTXPT_Assets_경로> [광원수 ...]

  예) python gen_light_scene.py E:/iris-ext/RTXPT/Assets 64 256 1024

  생성물: <Assets>/kitchen-lights-<N>.scene.json
  RTXPT를 재시작하면 씬 목록에 나타난다.

주의
  - Donut 씬 그래프의 PointLight 필드: color, intensity, radius, range (+ translation)
  - 좌표계는 Y-up (glTF 표준). kitchen 천장은 y ≈ 2.4 m
  - 총 광량을 광원 수에 반비례시켜 밝기를 일정하게 유지한다. 그래야 노출 차이가 아니라
    광원 개수만의 성능 영향을 본다
"""

import json
import io
import os
import sys

# kitchen 씬의 대략적 실내 범위 (모델 배치 좌표에서 역산)
ROOM_X = (-3.0, 3.0)
ROOM_Z = (-3.0, 3.0)
CEILING_Y = 2.4

# 광원 하나당 기준 광량. 총합을 일정하게 유지하려 광원 수로 나눈다.
TOTAL_INTENSITY = 120.0
LIGHT_RADIUS = 0.05      # 면광원 반경 (m). 0이면 점광원 = 하드 섀도우
LIGHT_RANGE = 8.0        # 감쇠 거리 (m)


def grid_dims(n):
    """n개를 최대한 정사각에 가깝게 나누는 (열, 행)."""
    cols = int(n ** 0.5)
    while cols > 1 and n % cols:
        cols -= 1
    return cols, n // cols


def make_lights(count):
    cols, rows = grid_dims(count)
    intensity = TOTAL_INTENSITY / count
    out = []
    for r in range(rows):
        for c in range(cols):
            # 격자를 방 안쪽에 고르게. 가장자리에 붙지 않도록 (i+0.5)/n 방식
            fx = (c + 0.5) / cols
            fz = (r + 0.5) / rows
            x = ROOM_X[0] + (ROOM_X[1] - ROOM_X[0]) * fx
            z = ROOM_Z[0] + (ROOM_Z[1] - ROOM_Z[0]) * fz
            out.append({
                "name": "IrisTestLight_%03d" % len(out),
                "type": "PointLight",
                "translation": [round(x, 4), CEILING_Y, round(z, 4)],
                "color": [1.0, 0.95, 0.88],     # 전구색 3000K 근사
                "intensity": round(intensity, 6),
                "radius": LIGHT_RADIUS,
                "range": LIGHT_RANGE,
            })
    return out


def build(assets_dir, count):
    base_path = os.path.join(assets_dir, "kitchen.scene.json")
    with io.open(base_path, encoding="utf-8") as f:
        scene = json.load(f)

    scene["graph"] = list(scene["graph"]) + make_lights(count)

    out_path = os.path.join(assets_dir, "kitchen-lights-%d.scene.json" % count)
    with io.open(out_path, "w", encoding="utf-8") as f:
        json.dump(scene, f, indent=2, ensure_ascii=False)

    cols, rows = grid_dims(count)
    print("생성: %s  (%d개 = %d x %d 격자, 광원당 intensity %.4f)"
          % (os.path.basename(out_path), count, cols, rows, TOTAL_INTENSITY / count))
    return out_path


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    assets_dir = sys.argv[1]
    if not os.path.isfile(os.path.join(assets_dir, "kitchen.scene.json")):
        print("kitchen.scene.json 을 찾을 수 없습니다: %s" % assets_dir)
        return 1

    counts = [int(a) for a in sys.argv[2:]] or [64, 256, 1024]
    for n in counts:
        build(assets_dir, n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
