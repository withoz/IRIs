# encoding: UTF-8
#
# IRIS — IES 배광 vs 원뿔 근사, 얼마나 다른가
#
# 왜 재는가
#   IES 프로파일을 제대로 넣으려면 배관이 깁니다 — 호스트가 배광 격자를
#   보내고, 렌더러가 텍스처로 구워 bindless 에 등록하고, 셰이더의
#   `evaluateIesProfile`(지금 `#if 0`)을 켜야 합니다.
#
#   그 전에 **얼마나 좋아지는지**를 압니다. 지금은 배광에서 빔각(50%)과
#   필드각(10%)을 뽑아 원뿔로 근사하고, 축상 광도는 IES 적분으로 정확히
#   맞춰 둡니다. 남은 오차는 **그 사이 모양**뿐입니다. 그게 작으면 배관을
#   깔 이유가 없습니다.
#
# 무엇과 견주는가
#   RTXPT 의 실제 감쇠식입니다(LightShaping.hlsli):
#
#     softness      = saturate(1 - inner/outer)        (LightsBaker.cpp)
#     cosConeAngle  = cos(outer)
#     falloff       = smoothstep(cosConeAngle, cosConeAngle + softness, cos(theta))
#
#   ⚠ softness 는 **각이 아니라 코사인에 더하는 수**입니다. 각도로 생각하면
#     빗나갑니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_ies_check.rb'
#
# 읽기 전용입니다. out/sketchup/ies_check.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module IesCheck
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        rows = []
        model.definitions.each do |d|
          dict = (d.attribute_dictionary('Enscape.Light') rescue nil)
          next unless dict
          xml = dict['LightData'].to_s
          next unless xml.include?('SketchupIesLight')
          n = (d.instances.length rescue 0)
          data = parse(xml[%r{<IesData>(.*?)</IesData>}m, 1])
          next unless data
          rows << [d.name.to_s, n, xml[%r{<OriginalIesFile>([^<]*)</OriginalIesFile>}, 1].to_s, data]
        end

        if rows.empty?
          say 'IES 조명을 찾지 못했습니다.'
          return finish(out_dir)
        end

        say "IES 조명 정의 #{rows.size}종"
        say ''

        rows.each { |nm, n, file, d| report(nm, n, file, d) }

        say '=' * 74
        say '읽는 법'
        say '=' * 74
        say '  최대오차가 0.05 아래면 눈으로 구별하기 어렵습니다 — 배관을 깔 값이 없습니다.'
        say '  0.15 를 넘으면 벽면 그라데이션이 눈에 띄게 다릅니다.'
        say '  가로 비대칭이 크면 1차원 근사로는 아예 담을 수 없습니다 (2D 텍스처 필요).'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(8).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def report(name, insts, file, d)
        vert = d[:vert]
        prof = d[:prof]
        peak = d[:peak]
        inner = fall_angle(vert, prof, peak * 0.5) || 20.0
        outer = fall_angle(vert, prof, peak * 0.1) || 35.0

        say '-' * 74
        say format('%s   인스턴스 %d', name[0, 40], insts)
        say format('    파일 %s', file.to_s.tr('\\', '/').split('/').last.to_s[0, 44])
        say format('    세로각 %d개 (%.0f~%.0f도) · 가로각 %d개 · 최대 %.0f cd',
                   vert.size, vert.first, vert.last, d[:nh], peak)
        say format('    유도한 원뿔: 안쪽 %.1f도 · 바깥 %.1f도', inner, outer)
        say ''

        # RTXPT 가 실제로 쓰는 식.
        softness = 1.0 - (inner / outer)
        softness = 0.0 if softness < 0.0
        softness = 1.0 if softness > 1.0
        cos_outer = Math.cos(outer * Math::PI / 180.0)

        say format('    %6s %10s %10s %9s', '각도', '실제', '원뿔근사', '차이')
        worst = 0.0
        sum2  = 0.0
        cnt   = 0
        vert.each_with_index do |a, i|
          real = prof[i] / peak
          c    = Math.cos(a * Math::PI / 180.0)
          approx = smoothstep(cos_outer, cos_outer + softness, c)
          diff = (real - approx).abs
          worst = diff if diff > worst
          sum2 += diff * diff
          cnt  += 1
          mark = diff > 0.15 ? '  <<' : (diff > 0.05 ? '  <' : '')
          say format('    %5.1f도 %10.3f %10.3f %9.3f%s', a, real, approx, diff, mark)
        end
        rms = cnt > 0 ? Math.sqrt(sum2 / cnt) : 0.0
        say ''
        say format('    **최대오차 %.3f · RMS %.3f**', worst, rms)
        say format('    가로 비대칭 %.3f  (0 이면 축대칭 — 1차원으로 충분)', d[:asym])
        say ''
      end

      # --- IES 파싱 (도구 안에서 자급합니다) ---
      def parse(b64)
        return nil if b64.nil? || b64.strip.empty?
        text = b64.unpack1('m')
        return nil if text.nil? || text.empty?
        text = text.force_encoding('BINARY').gsub(/\r\n?/, "\n")
        idx = text.index(/^[ \t]*TILT[ \t]*=/i)
        return nil unless idx
        lines = text[idx..].split("\n")
        return nil unless lines.shift.to_s =~ /NONE/i
        nums = lines.join(' ').split(/[\s,]+/).reject(&:empty?).map(&:to_f)
        return nil if nums.size < 13
        mult = nums[2]
        nv   = nums[3].to_i
        nh   = nums[4].to_i
        return nil if nv < 2 || nh < 1 || nv > 4096 || nh > 4096
        base = 13
        return nil if nums.size < base + nv + nh + nv * nh
        vert = nums[base, nv]
        cand = nums[(base + nv + nh), nv * nh]
        scale = mult.zero? ? 1.0 : mult

        prof = Array.new(nv) do |i|
          (0...nh).map { |h| cand[h * nv + i].to_f }.max * scale
        end
        peak = prof.max
        return nil if peak <= 0.0

        # 가로 비대칭: 세로각마다 (최대-최소)/최대 의 최댓값.
        asym = 0.0
        if nh > 1
          (0...nv).each do |i|
            vals = (0...nh).map { |h| cand[h * nv + i].to_f }
            mx = vals.max
            next if mx <= 1e-9
            a = (mx - vals.min) / mx
            asym = a if a > asym
          end
        end

        { vert: vert, prof: prof, peak: peak, nh: nh, asym: asym }
      rescue StandardError
        nil
      end

      def fall_angle(vert, prof, target)
        return nil if vert.empty?
        (1...vert.size).each do |i|
          a0 = prof[i - 1]
          a1 = prof[i]
          next unless a0 >= target && a1 < target
          t = (a0 - target) / [(a0 - a1), 1e-9].max
          return vert[i - 1] + (vert[i] - vert[i - 1]) * t
        end
        nil
      end

      def smoothstep(e0, e1, x)
        return 0.0 if e1 <= e0
        t = (x - e0) / (e1 - e0)
        t = 0.0 if t < 0.0
        t = 1.0 if t > 1.0
        t * t * (3.0 - 2.0 * t)
      end

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def finish(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'ies_check.txt')
        File.open(path, 'w:UTF-8') { |f| @log.each { |l| f.puts l } }
        puts "저장: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

IRIS::IesCheck.run
