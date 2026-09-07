#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IRIS — RTXPT 파이프라인 품질 비교

목적
  프레임 시간(ms)만으로는 패스트레이서를 비교할 수 없다. 옳은 기준은 "같은 품질에
  도달하는 비용"이다. 이 스크립트는 RTXPT의 Reference 모드(4096 spp) 이미지를 정답으로
  놓고, 각 실시간 파이프라인 출력의 오차를 잰다.

사용법
  python compare_images.py <reference.png> <candidate.png> [<candidate2.png> ...]

  예) python compare_images.py out/rtxpt/ref.png out/rtxpt/a_dlssrr.png out/rtxpt/b_restir.png

지표
  RMSE   낮을수록 좋음. 0~255 스케일
  PSNR   높을수록 좋음. dB
  MAE    평균 절대 오차
  평균휘도 세 이미지가 크게 다르면 노출이 안 맞은 것이므로 비교가 무의미하다.
         RTXPT 캡처 시 --overrideAutoexposureOff 를 반드시 줄 것

주의
  - 입력은 톤매핑된 sRGB 8bit PNG다. 선형 공간 오차가 아니라 표시 공간 오차를 재는 것이며,
    사람 눈에 보이는 차이에 가깝다는 뜻이다
  - 알파 채널은 무시하고 RGB만 비교한다
"""

import os
import sys

import numpy as np
from PIL import Image


def load_rgb(path):
    img = Image.open(path).convert("RGB")
    return np.asarray(img).astype(np.float64)


def luminance(a):
    # Rec.709
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def compare(ref, cand):
    diff = cand - ref
    mse = float(np.mean(diff ** 2))
    rmse = mse ** 0.5
    mae = float(np.mean(np.abs(diff)))
    psnr = float("inf") if mse == 0 else 10.0 * np.log10((255.0 ** 2) / mse)
    # 채널별 RMSE
    per_ch = [float(np.mean(diff[..., c] ** 2) ** 0.5) for c in range(3)]
    return rmse, psnr, mae, per_ch


def save_diff(ref, cand, out_path, gain=8.0):
    """오차 위치를 눈으로 보기 위한 증폭 차분 이미지."""
    d = np.abs(cand - ref).mean(axis=2) * gain
    d = np.clip(d, 0, 255).astype(np.uint8)
    Image.fromarray(d, mode="L").save(out_path)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    ref_path = sys.argv[1]
    ref = load_rgb(ref_path)

    print("레퍼런스: %s  %dx%d" % (os.path.basename(ref_path), ref.shape[1], ref.shape[0]))
    print("  평균휘도 %.2f" % float(np.mean(luminance(ref))))
    print("")
    print("%-20s %8s %9s %8s   %-22s %8s" %
          ("후보", "RMSE", "PSNR(dB)", "MAE", "채널별 RMSE (R/G/B)", "평균휘도"))
    print("-" * 88)

    for cand_path in sys.argv[2:]:
        cand = load_rgb(cand_path)
        if cand.shape != ref.shape:
            print("%-20s 해상도 불일치 %s vs %s" %
                  (os.path.basename(cand_path), cand.shape, ref.shape))
            continue

        rmse, psnr, mae, per_ch = compare(ref, cand)
        lum = float(np.mean(luminance(cand)))
        print("%-20s %8.3f %9.2f %8.3f   %6.2f /%6.2f /%6.2f %8.2f" %
              (os.path.basename(cand_path), rmse, psnr, mae,
               per_ch[0], per_ch[1], per_ch[2], lum))

        diff_path = os.path.splitext(cand_path)[0] + "_diff.png"
        save_diff(ref, cand, diff_path)

    print("")
    print("차분 이미지(×8 증폭)를 <후보>_diff.png 로 저장했습니다.")
    print("평균휘도가 레퍼런스와 크게 다르면 노출이 안 맞은 것이므로 위 수치는 신뢰할 수 없습니다.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
