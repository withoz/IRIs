# encoding: UTF-8
#
# IRIS — IES 0도 방위가 프록시의 어느 축인가
#
# 무엇을 모르는가
#   배광을 2차원 텍스처로 넣으면서 기구의 **roll** 을 같이 보냅니다
#   (LightsBaker.cpp: tangent = 노드의 로컬 +X). 그래야 비대칭 배광이
#   인스턴스마다 제멋대로 돌지 않습니다.
#
#   그런데 **로컬 +X 가 IES 의 0도 방위 평면이라는 것은 가정**입니다.
#   틀렸다면 전체가 같은 각도만큼 돌아간 것이라 상수로 보정됩니다 —
#   인스턴스마다 다른 이전 상태보다는 낫지만, 그래도 틀린 겁니다.
#
# 무엇으로 가리는가
#   IES LM-63 의 헤더 10개 중 8·9·10번이 **광원 개구부의 폭·길이·높이**
#   입니다. 그리고 규격상
#
#     폭   = 90도-270도 축 방향의 크기
#     길이 =  0도-180도 축 방향의 크기
#
#   입니다. 즉 **헤더가 0도 평면이 기구의 어느 변을 따라가는지 알려줍니다.**
#   프록시 지오메트리의 로컬 가로세로와 견주면 대응이 나옵니다.
#
#   폭과 길이가 같으면(정사각·원형) 이 방법으로는 못 가립니다. 그때는
#   배광 자체의 퍼짐(0도 평면 대 90도 평면)을 같이 봅니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_ies_axis.rb'
#
# 읽기 전용입니다. out/sketchup/ies_axis.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module IesAxis
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        defs = []
        model.definitions.each do |d|
          dict = (d.attribute_dictionary('Enscape.Light') rescue nil)
          next unless dict
          xml = dict['LightData'].to_s
          next unless xml.include?('SketchupIesLight')
          defs << [d, xml]
        end

        if defs.empty?
          say 'IES 조명 정의를 찾지 못했습니다.'
          return finish(out_dir)
        end

        say "IES 조명 정의 #{defs.size}종"
        say ''
        defs.each { |d, xml| report(d, xml) }

        say '=' * 74
        say '읽는 법'
        say '=' * 74
        say '  [A] IES 헤더의 폭/길이 — 규격이 정한 기구의 방향'
        say '        길이 = 0도-180도 축 · 폭 = 90도-270도 축'
        say '  [B] 프록시 로컬 바운딩박스 — 우리가 +X 라고 부르는 축'
        say '  [C] 배광이 0도 평면과 90도 평면에서 얼마나 다른가'
        say ''
        say '  A 의 긴 변과 B 의 긴 변이 같은 축이면 가정이 맞습니다.'
        say '  A 가 정사각이면 이 방법으로는 못 가립니다 — C 와 설치 맥락을 봅니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def report(defn, xml)
        say '-' * 74
        say format('%s   인스턴스 %d', defn.name.to_s[0, 44], (defn.instances.length rescue 0))
        say format('    파일 %s',
                   xml[%r{<OriginalIesFile>([^<]*)</OriginalIesFile>}, 1]
                     .to_s.tr('\\', '/').split('/').last.to_s[0, 50])

        ies = parse(xml[%r{<IesData>(.*?)</IesData>}m, 1])
        unless ies
          say '    !! IES 를 읽지 못했습니다.'
          say ''
          return
        end

        # ---------------------------------------------------------- [A] 헤더
        u    = ies[:units] == 1 ? 'ft' : 'm'
        w    = ies[:width]
        l    = ies[:length]
        h    = ies[:height]
        say ''
        say '    [A] IES 헤더 — 규격이 정한 기구 치수'
        say format('        측광 유형 %s · 단위 %s', ies[:ptype_name], u)
        say format('        폭(90-270축) %.4f %s', w, u)
        say format('        길이(0-180축) %.4f %s', l, u)
        say format('        높이 %.4f %s', h, u)
        aw = w.abs
        al = l.abs
        a_verdict =
          if aw < 1e-6 && al < 1e-6
            '점광원으로 선언 — 치수 없음 (이 방법으로는 못 가립니다)'
          elsif (aw - al).abs <= 1e-6 * [aw, al].max + 1e-9
            '정사각/원형 — 못 가립니다'
          elsif al > aw
            format('**0-180축이 더 깁니다** (%.3f : 1)', al / [aw, 1e-9].max)
          else
            format('**90-270축이 더 깁니다** (%.3f : 1)', aw / [al, 1e-9].max)
          end
        say format('        -> %s', a_verdict)

        # -------------------------------------------- [B] 프록시 로컬 바운딩박스
        bb = (defn.bounds rescue nil)
        say ''
        say '    [B] 프록시 로컬 바운딩박스 (인치)'
        if bb.nil? || bb.empty?
          say '        비어 있습니다 — 프록시에 지오메트리가 없습니다.'
          say '        (Enscape 조명은 아이콘만 있는 경우가 있습니다)'
        else
          ex = (bb.max.x - bb.min.x).to_f
          ey = (bb.max.y - bb.min.y).to_f
          ez = (bb.max.z - bb.min.z).to_f
          say format('        X %.3f · Y %.3f · Z %.3f', ex, ey, ez)
          say format('        면 %d개 · 모서리 %d개',
                     (defn.entities.grep(Sketchup::Face).size rescue 0),
                     (defn.entities.grep(Sketchup::Edge).size rescue 0))
          b_verdict =
            if [ex, ey].max < 1e-6
              '평평/없음 — 못 가립니다'
            elsif (ex - ey).abs <= 0.02 * [ex, ey].max
              '정사각 — 못 가립니다'
            elsif ex > ey
              format('**X 가 더 깁니다** (%.3f : 1)', ex / [ey, 1e-9].max)
            else
              format('**Y 가 더 깁니다** (%.3f : 1)', ey / [ex, 1e-9].max)
            end
          say format('        -> %s', b_verdict)
        end

        # -------------------------------------------------------- [C] 배광 자체
        say ''
        say '    [C] 배광 — 0도 평면 대 90도 평면'
        say format('        세로각 %d개 (%.0f~%.0f) · 가로각 %d개 (%.0f~%.0f)',
                   ies[:nv], ies[:vert].first, ies[:vert].last,
                   ies[:nh], ies[:horz].first, ies[:horz].last)
        say format('        대칭: %s', symmetry_name(ies[:horz]))
        p0  = plane_profile(ies, 0.0)
        p90 = plane_profile(ies, 90.0)
        if p0 && p90
          say format('        0도 평면  : 최대 %.0f cd · 반치각 %.1f도', p0[:peak], p0[:half])
          say format('        90도 평면 : 최대 %.0f cd · 반치각 %.1f도', p90[:peak], p90[:half])
          c_verdict =
            if (p0[:half] - p90[:half]).abs < 1.0
              '두 평면이 거의 같습니다 — 돌려도 티가 안 납니다'
            elsif p0[:half] > p90[:half]
              format('**0-180축으로 더 넓게 퍼집니다** (%.1f도 대 %.1f도)', p0[:half], p90[:half])
            else
              format('**90-270축으로 더 넓게 퍼집니다** (%.1f도 대 %.1f도)', p90[:half], p0[:half])
            end
          say format('        -> %s', c_verdict)
        end

        # --------------------------------------------- [D] 인스턴스의 로컬 +X
        say ''
        say '    [D] 인스턴스 — 로컬 +X 가 월드에서 어디를 보나'
        insts = (defn.instances rescue [])
        shown = 0
        dirs  = []
        insts.each do |i|
          tr = (i.transformation rescue nil)
          next unless tr
          xa = tr.xaxis
          za = tr.zaxis
          dirs << xa
          next if shown >= 5
          shown += 1
          say format('        #%d  +X (%.3f %.3f %.3f)  ·  축 -Z (%.3f %.3f %.3f)',
                     shown, xa.x, xa.y, xa.z, -za.x, -za.y, -za.z)
        end
        say format('        ... 외 %d개', insts.length - shown) if insts.length > shown
        if dirs.size > 1
          # 로컬 +X 들이 서로 같은 방향인가? 다 같으면 상수 보정이 쉽습니다.
          spread = dirs.combination(2).map { |a, b| (a % b).abs }.min
          say format('        +X 방향 일치도: 최소 |cos| %.3f  (1 이면 전부 같은 선상)',
                     spread)
        end
        say ''
      end

      def symmetry_name(horz)
        return '축대칭 (가로각 1개)' if horz.size <= 1
        span = horz.last - horz.first
        return "사분 대칭 (0~90) — 두 축 모두 좌우 대칭" if (span - 90.0).abs < 1.0
        return "좌우 대칭 (0~180)" if (span - 180.0).abs < 1.0
        return "대칭 없음 (0~360)" if (span - 360.0).abs < 1.0
        format('가로각 %.0f~%.0f', horz.first, horz.last)
      end

      # 주어진 방위 평면의 세로 분포. 대칭이면 접어서 읽습니다.
      def plane_profile(ies, hdeg)
        nv = ies[:nv]
        prof = Array.new(nv) { |i| ies_at(ies, i, hdeg) }
        peak = prof.max
        return nil if peak.nil? || peak <= 0.0
        { peak: peak, half: (fall_angle(ies[:vert], prof, peak * 0.5) || ies[:vert].last) }
      end

      # 세로각 색인 vi, 방위 hdeg 의 광도. 가로각 표를 대칭으로 접어 읽습니다.
      def ies_at(ies, vi, hdeg)
        horz = ies[:horz]
        return ies[:cand][vi].to_f * ies[:scale] if horz.size <= 1
        h = fold_h(horz, hdeg)
        i, t = axis_pos(horz, h)
        j = [i + 1, horz.size - 1].min
        a = ies[:cand][i * ies[:nv] + vi].to_f
        b = ies[:cand][j * ies[:nv] + vi].to_f
        (a + (b - a) * t) * ies[:scale]
      end

      def fold_h(horz, deg)
        span = horz.last - horz.first
        d = deg % 360.0
        if (span - 90.0).abs < 1.0
          d = 360.0 - d if d > 180.0
          d = 180.0 - d if d > 90.0
        elsif (span - 180.0).abs < 1.0
          d = 360.0 - d if d > 180.0
        end
        d
      end

      def axis_pos(axis, x)
        return [0, 0.0] if axis.size < 2
        return [0, 0.0] if x <= axis.first
        return [axis.size - 1, 0.0] if x >= axis.last
        i = 0
        i += 1 while i < axis.size - 2 && axis[i + 1] < x
        d = axis[i + 1] - axis[i]
        [i, d.abs < 1e-9 ? 0.0 : (x - axis[i]) / d]
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

      PTYPE = { 1 => 'C', 2 => 'B', 3 => 'A' }.freeze

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
        nv = nums[3].to_i
        nh = nums[4].to_i
        return nil if nv < 2 || nh < 1 || nv > 4096 || nh > 4096
        base = 13
        return nil if nums.size < base + nv + nh + nv * nh
        { ptype: nums[5].to_i, ptype_name: PTYPE[nums[5].to_i] || nums[5].to_i.to_s,
          units: nums[6].to_i, width: nums[7], length: nums[8], height: nums[9],
          nv: nv, nh: nh,
          vert: nums[base, nv], horz: nums[base + nv, nh],
          cand: nums[(base + nv + nh), nv * nh],
          scale: nums[2].zero? ? 1.0 : nums[2],
          head: text[0, idx].split("\n").reject { |l| l.strip.empty? } }
      rescue StandardError
        nil
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
        path = File.join(dir, 'ies_axis.txt')
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

IRIS::IesAxis.run
