# encoding: UTF-8
#
# IRIS — Enscape 속성 읽기
#
# 왜 이것이 옳은가
#   SketchUp 자체는 PBR 파라미터도 조명도 주지 않습니다. 그래서 지금까지
#   모든 재질이 roughness 0.5 / metalness 0 고정이었고 조명은 하늘뿐이었습니다.
#
#   그런데 이 모델은 Enscape 로 작업된 것이고, Enscape 는 설정을 SketchUp 의
#   **속성 사전**에 XML 로 남겨 둡니다. 설계자가 이미 정해 둔 값이 모델 안에
#   그대로 있습니다. 추측할 필요가 없습니다 — 읽으면 됩니다.
#
#   Enscape.Light    / LightData     조명 세기·크기·IES 배광
#   Enscape.Material / MaterialData  거칠기·금속성·발광·범프
#
# 읽기 전용입니다. 모델을 바꾸지 않습니다.
#
# 실측한 스키마는 docs/09-조명-설계.md 에 있습니다.

module IRIS
  module Enscape
    INCH_TO_M     = 0.0254
    LIGHT_DICT    = 'Enscape.Light'
    MATERIAL_DICT = 'Enscape.Material'
    ASSET_DICT    = 'Enscape.Asset'

    # RTXPT 는 spot.radius == 0 을 가정하지 않습니다 (LightsBaker.cpp 의
    # assert(false) — "not tested with radius == 0"). 0 이면 이 값을 씁니다.
    # 25 mm 는 다운라이트 광원으로 타당하고 그림자 경계도 자연스러워집니다.
    DEFAULT_SPOT_RADIUS_M = 0.025

    # 선형 조명의 가정 두께(m). 면광원으로 낼 때 필요합니다.
    LINEAR_WIDTH_M = 0.02

    class << self
      # Luminosity 의 단위.
      #
      # 정직하게: Enscape 문서가 아니라 값에서 역추론했습니다.
      #   PointLight 989 · LinearLight 1000(정확) · Rect 2832 · IES 83860
      # 1000 이 정확히 떨어지는 것과 989 lm(백열 60W 급)이 물리적으로 맞는 것을
      # 근거로 **루멘(lm)** 으로 봅니다. 틀렸다면 이 배율 하나로 교정됩니다.
      attr_accessor :lumen_scale
    end
    @lumen_scale = 1.0

    class << self
      # ---------------------------------------------------------------- 자산

      # Enscape 자산이면 {source:, id:}, 아니면 nil.
      #
      # **Source 가 'REMOTE' 면 실물 지오메트리가 .skp 안에 없습니다.**
      # 모델에는 자리표시만 들어 있고(62~118 삼각형짜리 껍데기), Enscape 는
      # 렌더할 때 자기 라이브러리의 실물로 바꿔 끼웁니다. 그래서 SketchUp
      # 인스턴스는 hidden 으로 놓여 있습니다 — 거친 껍데기를 화면에 보이지
      # 않으려는 것입니다.
      #
      # 우리는 그 라이브러리가 없으므로 **그릴 수 없습니다.** 조용히 빠지면
      # "식물이 안 나온다"가 되고 원인을 파일 안에서 찾게 됩니다. 세어서
      # 리포트에 적습니다.
      #
      # Source 가 비어 있으면 지오메트리가 파일에 들어 있습니다 — 평범하게
      # 그려집니다. 실측: 배치된 자산 11종 중 REMOTE 2종(식물)만 숨김.
      def asset(defn)
        d = (defn.attribute_dictionary(ASSET_DICT) rescue nil)
        return nil unless d
        { 'source' => (d['Source'].to_s rescue ''), 'id' => (d['Id'].to_s rescue '') }
      rescue StandardError
        nil
      end

      def remote_asset?(defn)
        a = asset(defn)
        a ? a['source'].to_s.upcase == 'REMOTE' : false
      end

      # ---------------------------------------------------------------- 조명

      # 컴포넌트 정의가 Enscape 조명이면 파라미터를, 아니면 nil.
      def light(defn)
        xml = dict_value(defn, LIGHT_DICT, 'LightData')
        return nil unless xml

        kind = xml[/xsi:type="Sketchup([A-Za-z]+)Light"/, 1].to_s.downcase
        lm   = (num(xml, 'Luminosity') || 0.0) * lumen_scale
        return nil if lm <= 0.0

        base = { 'lumens' => lm, 'color' => light_color(xml) }

        case kind
        when 'ies'
          cone  = ies_cone(xml[%r{<IesData>(.*?)</IesData>}m, 1])
          inner = cone ? cone[:inner] : 20.0
          outer = cone ? cone[:outer] : 35.0
          # 배광을 아는데 원뿔로 근사할 이유가 없습니다. IES 를 적분해 얻은
          # 실제 광속으로 정규화하면 **축상 광도가 그대로 보존**됩니다.
          # (골프존 모델의 Bega 8331 에서 균일 원뿔 근사는 2.37배 어두웠습니다.)
          axial = if cone && cone[:flux] > 1e-6
                    lm * cone[:peak] / cone[:flux]
                  else
                    spot_candela(lm, inner, outer)
                  end
          base.merge(
            'kind'        => 'spot',
            'inner'       => inner,
            'outer'       => outer,
            'radius'      => DEFAULT_SPOT_RADIUS_M,
            'intensity'   => axial,
            'ies_file'    => ies_basename(xml),
            'ies_peak_cd' => cone && cone[:peak],
            'ies_flux_lm' => cone && cone[:flux],
            'ies_lamp_lm' => cone && cone[:declared_lm]
          )
        when 'spot'
          # 원뿔각이 명시된 스포트라이트(IES 아님). 반각으로 저장합니다.
          outer = (num(xml, 'ConeAngle') || num(xml, 'OuterConeAngle') || 70.0) * 0.5
          inner = (num(xml, 'InnerConeAngle') || (outer * 1.6)) * 0.5
          base.merge('kind' => 'spot', 'inner' => inner, 'outer' => outer,
                     'radius' => DEFAULT_SPOT_RADIUS_M,
                     'intensity' => spot_candela(lm, inner, outer))
        when 'point'
          r = (num(xml, 'LightSourceRadius') || 0.0) * INCH_TO_M
          base.merge('kind' => 'point', 'radius' => r,
                     'intensity' => lm / (4.0 * Math::PI))
        when 'rectangular'
          w = (num(xml, 'Width')  || 0.0) * INCH_TO_M
          l = (num(xml, 'Length') || 0.0) * INCH_TO_M
          base.merge('kind' => 'rect', 'width' => w, 'length' => l,
                     'radiance' => area_radiance(lm, w * l))
        when 'linear'
          l = (num(xml, 'Length') || 0.0) * INCH_TO_M
          base.merge('kind' => 'linear', 'length' => l, 'width' => LINEAR_WIDTH_M,
                     'radiance' => area_radiance(lm, l * LINEAR_WIDTH_M))
        else
          base.merge('kind' => 'point', 'radius' => 0.0,
                     'intensity' => lm / (4.0 * Math::PI))
        end
      rescue StandardError
        nil
      end

      # 루멘 -> 칸델라.
      #
      # RTXPT 의 getShapingFluxFactor 와 같은 근사를 씁니다. 그래야 광원 선택
      # 가중치(광속)와 실제 밝기가 어긋나지 않습니다.
      #   Omega = 4pi * (1 - cos(outer)) * lerp(1, 0.5, softness) * 0.5
      def spot_candela(lm, inner_deg, outer_deg)
        outer = clampf(outer_deg, 0.5, 89.5)
        inner = clampf(inner_deg, 0.0, outer)
        softness = clampf(1.0 - (inner / outer), 0.0, 1.0)
        omega = 2.0 * Math::PI * (1.0 - Math.cos(outer * Math::PI / 180.0)) *
                (1.0 - 0.5 * softness)
        omega < 1e-6 ? lm : lm / omega
      end

      # 루멘 -> 램버시안 면광원의 라디언스(cd/m^2). Phi = L * pi * A.
      def area_radiance(lm, area_m2)
        area_m2 > 1e-9 ? lm / (Math::PI * area_m2) : 0.0
      end

      # ------------------------------------------------------------------ IES
      #
      # IES 프로파일은 RTXPT 에 아직 연결돼 있지 않습니다 — LightsBaker.cpp 에
      # 주석 처리된 예시만 있고 셰이더의 evaluateIesProfile 은 비어 있습니다.
      # 그래서 텍스처로 넘기는 대신 **배광에서 원뿔각을 유도**합니다.
      # 절반(50%)에서 내부 원뿔, 1/10(10%)에서 외부 원뿔 — 조명업계의
      # 빔각·필드각 정의 그대로입니다.
      #
      # 광속은 배광을 **구면 적분**해 구합니다. 파일이 선언한 램프 광속이
      # 아니라 실제 방출 광속입니다 — 이 모델의 Bega 8331 은 8500 lm 램프에
      # 적분 광속 5088 lm(효율 59.9%)로, 매입 다운라이트의 전형값입니다.
      #
      # 반환: { inner:, outer:, peak:, flux:, declared_lm: }  각도는 반각(도).
      def ies_cone(b64)
        return nil if b64.nil? || b64.strip.empty?
        text = b64.unpack1('m')
        return nil if text.nil? || text.empty?
        text = text.force_encoding('BINARY').gsub(/\r\n?/, "\n")

        idx = text.index(/^[ \t]*TILT[ \t]*=/i)
        return nil unless idx

        lines = text[idx..].split("\n")
        tilt  = lines.shift.to_s
        # TILT=INCLUDE 면 뒤에 기울기 표가 붙어 오프셋이 달라집니다. 건너뜁니다.
        return nil unless tilt =~ /NONE/i

        nums = lines.join(' ').split(/[\s,]+/).reject(&:empty?).map(&:to_f)
        return nil if nums.size < 13

        declared_lm = nums[1]
        mult        = nums[2]
        nv          = nums[3].to_i
        nh          = nums[4].to_i
        return nil if nv < 2 || nh < 1 || nv > 4096 || nh > 4096

        base = 13 # 앞의 10개 + 안정기계수/예비/입력전력 3개
        return nil if nums.size < base + nv + nh + nv * nh

        vert  = nums[base, nv]
        horz  = nums[base + nv, nh]
        cand  = nums[(base + nv + nh), nv * nh]
        scale = mult.zero? ? 1.0 : mult

        # 세로각마다 가로 전체의 최댓값 — 축대칭이 아니어도 빔 폭이 나옵니다.
        prof = Array.new(nv) do |i|
          (0...nh).map { |h| cand[h * nv + i].to_f }.max * scale
        end
        peak = prof.max
        return nil if peak <= 0.0

        { inner: fall_angle(vert, prof, peak * 0.5) || 20.0,
          outer: fall_angle(vert, prof, peak * 0.1) || 35.0,
          peak: peak, flux: ies_flux(vert, horz, cand, scale, nv, nh),
          declared_lm: declared_lm }
      rescue StandardError
        nil
      end

      # 배광의 구면 적분.  Phi = SS I(theta,phi) sin(theta) dtheta dphi
      #
      # IES 는 대칭이면 일부만 적습니다: 수평각이 0 하나면 축대칭,
      # 0~90 이면 사분 대칭, 0~180 이면 좌우 대칭입니다. 그만큼 곱해야
      # 전체 광속이 됩니다 — 빼먹으면 4배 어두워집니다.
      def ies_flux(vert, horz, cand, scale, nv, nh)
        wv = trapezoid_weights(vert).map { |w| w * Math::PI / 180.0 }
        if nh <= 1
          wh     = [2.0 * Math::PI]
          mirror = 1.0
        else
          span   = horz[-1] - horz[0]
          wh     = trapezoid_weights(horz).map { |w| w * Math::PI / 180.0 }
          mirror = span > 1e-6 ? (360.0 / span) : 1.0
        end

        total = 0.0
        (0...nh).each do |h|
          (0...nv).each do |v|
            total += cand[h * nv + v].to_f * scale *
                     Math.sin(vert[v] * Math::PI / 180.0) * wv[v] * wh[h]
          end
        end
        total * mirror
      rescue StandardError
        0.0
      end

      def trapezoid_weights(a)
        w = Array.new(a.size, 0.0)
        (0...(a.size - 1)).each do |k|
          d = a[k + 1] - a[k]
          w[k] += d / 2.0
          w[k + 1] += d / 2.0
        end
        w
      end

      # 세기가 처음으로 threshold 아래로 떨어지는 각도를 선형 보간으로.
      def fall_angle(vert, prof, threshold)
        (1...prof.size).each do |i|
          next unless prof[i] < threshold && prof[i - 1] >= threshold
          span = prof[i - 1] - prof[i]
          t    = span.abs < 1e-9 ? 0.0 : (prof[i - 1] - threshold) / span
          return vert[i - 1] + (vert[i] - vert[i - 1]) * t
        end
        nil
      end

      def ies_basename(xml)
        p = xml[%r{<OriginalIesFile>(.*?)</OriginalIesFile>}m, 1].to_s
        p.split(%r{[/\\]}).last.to_s
      end

      # ---------------------------------------------------------------- 재질

      # 재질에 Enscape 설정이 있으면 PBR 파라미터를, 없으면 nil.
      def material(mat)
        xml = dict_value(mat, MATERIAL_DICT, 'MaterialData')
        return nil unless xml

        out = { 'etype' => (str(xml, 'TypeV5') || str(xml, 'Type') || 'GENERIC') }

        put(out, 'roughness',        num(xml, 'Roughness'))
        put(out, 'metalness',        num(xml, 'Metallic'))
        put(out, 'specular',         num(xml, 'Specular'))
        put(out, 'opacity',          num(xml, 'Opacity'))
        put(out, 'ior',              num(xml, 'IndexOfRefraction'))
        put(out, 'bump',             num(xml, 'BumpAmount'))
        put(out, 'normal_intensity', num(xml, 'NormalMapIntensity'))
        put(out, 'bump_type',        str(xml, 'BumpMapType'))
        out['solid_glass'] = true if str(xml, 'IsSolidGlass') == 'true'

        # 발광. EmissiveStrength 는 cd/m^2 로 봅니다 — 천장 패널의 3000~7000 이
        # 실제 LED 패널 휘도(3000~8000 nit)와 맞습니다.
        es = num(xml, 'EmissiveStrength')
        if es && es > 0.0
          out['emissive']    = hex_linear(str(xml, 'EmissiveColor')) || [1.0, 1.0, 1.0]
          out['emissive_cd'] = es
        end

        tint = hex_linear(str(xml, 'TintColor'))
        out['tint'] = tint if tint && tint != [1.0, 1.0, 1.0]

        out
      rescue StandardError
        nil
      end

      # ---------------------------------------------------------------- 공통

      def dict_value(owner, dict_name, key)
        d = owner.attribute_dictionary(dict_name)
        return nil unless d
        s = d[key].to_s
        s.empty? ? nil : s
      rescue StandardError
        nil
      end

      def num(xml, tag)
        return nil unless xml[%r{<#{tag}>([^<]*)</#{tag}>}]
        v = Regexp.last_match(1).to_s.strip
        v.empty? ? nil : Float(v)
      rescue StandardError
        nil
      end

      def str(xml, tag)
        xml[%r{<#{tag}>([^<]*)</#{tag}>}] ? Regexp.last_match(1).to_s.strip : nil
      end

      def put(h, k, v)
        h[k] = v unless v.nil?
      end

      # Enscape 는 조명 색이 기본값(흰색)이면 아예 적지 않습니다.
      def light_color(xml)
        hex_linear(str(xml, 'Color') || str(xml, 'LightColor')) || [1.0, 1.0, 1.0]
      end

      # "#RRGGBB" -> 선형 [r,g,b]. 렌더러는 선형을 기대합니다.
      def hex_linear(s)
        return nil unless s.is_a?(String)
        m = s.strip[/\A#?([0-9A-Fa-f]{6})\z/, 1]
        return nil unless m
        [0, 2, 4].map { |i| srgb_to_linear(m[i, 2].to_i(16) / 255.0) }
      end

      def srgb_to_linear(c)
        c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
      end

      def clampf(v, lo, hi)
        return lo if v < lo
        return hi if v > hi
        v
      end
    end
  end
end
