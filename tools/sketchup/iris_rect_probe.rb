# encoding: UTF-8
#
# IRIS — 사각 광원의 Luminosity 가 무슨 단위인가
#
# 무엇이 이상한가
#   포르쉐 성수 모델의 사각 광원 285개가 합계 **8,520만 lm** 입니다.
#   하나당 평균 299,000 lm — 경기장 투광기 급입니다. 285개가 그럴 리 없습니다.
#
#   골프존 모델에서는 Rect 가 2,832 였고 그건 lm 으로 타당했습니다. 같은
#   필드가 모델에 따라 다른 값을 낸다면 **우리가 단위를 잘못 읽고 있거나,
#   보이지 않는 배율이 있습니다.**
#
# 어떻게 가리는가
#   추측 대신 **상관**을 봅니다.
#
#     Luminosity 가 넓이에 비례한다  -> 총광속(lm). 지금 읽는 방식이 맞다
#     넓이와 무관하다                -> 단위 면적당 양(lm/m2 · cd/m2)
#     인스턴스 배율에 따라 다르다    -> 정의의 W·L 만 보면 안 된다
#
#   셋은 고치는 곳이 완전히 다릅니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_rect_probe.rb'
#
# 읽기 전용입니다. out/sketchup/rect_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module RectProbe
    INCH_TO_M = 0.0254

    # 견줄 실물. 600x600 사무실 LED 패널 3,600 lm.
    #   램버시안 한쪽 방출: L = 파이 / (pi * A)
    PANEL_LM   = 3600.0
    PANEL_AREA = 0.36

    class << self
      def run(out_dir: nil, max_xml: 3)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say format('견줄 값: 사무실 LED 패널 %.0f lm / %.2f m2 = %.0f cd/m2',
                   PANEL_LM, PANEL_AREA, PANEL_LM / (Math::PI * PANEL_AREA))
        say ''

        rows = collect(model)
        if rows.empty?
          say 'Enscape 조명이 없습니다.'
          return finish(out_dir)
        end

        table(rows)
        rect_analysis(rows.select { |r| r[:kind] == 'rectangular' })
        scales(model, rows)
        raw(rows, max_xml)
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def collect(model)
        rows = []
        model.definitions.each do |d|
          dict = (d.attribute_dictionary('Enscape.Light') rescue nil)
          next unless dict
          xml = dict['LightData'].to_s
          next if xml.empty?
          n = (d.instances.length rescue 0)
          # 배치되지 않은 정의는 화면에 없습니다. 합계를 흐립니다.
          next if n.zero?
          w = num(xml, 'Width')
          l = num(xml, 'Length')
          rows << {
            name:  d.name.to_s,
            defn:  d,
            kind:  xml[/xsi:type="Sketchup([A-Za-z]+)Light"/, 1].to_s.downcase,
            lm:    num(xml, 'Luminosity') || 0.0,
            w_in:  w,
            l_in:  l,
            w:     w ? w * INCH_TO_M : nil,
            l:     l ? l * INCH_TO_M : nil,
            inst:  n,
            xml:   xml.gsub(%r{<IesData>.*?</IesData>}m, '<IesData>...</IesData>'),
          }
        end
        rows
      end

      def table(rows)
        say '=' * 96
        say '[1] 배치된 Enscape 조명 정의 (합계 기여 순)'
        say '=' * 96
        say format('%-30s %-12s %12s %5s %14s %10s %10s',
                   '이름', '종류', 'Luminosity', '개수', '합계 lm', 'W(m)', 'L(m)')
        tot = Hash.new(0.0)
        cnt = Hash.new(0)
        rows.sort_by { |r| -(r[:lm] * r[:inst]) }.each do |r|
          tot[r[:kind]] += r[:lm] * r[:inst]
          cnt[r[:kind]] += r[:inst]
          say format('%-30s %-12s %12.1f %5d %14s %10s %10s',
                     r[:name][0, 30], r[:kind], r[:lm], r[:inst],
                     comma(r[:lm] * r[:inst]),
                     r[:w] ? format('%.3f', r[:w]) : '-',
                     r[:l] ? format('%.3f', r[:l]) : '-')
        end
        say ''
        say '종류별 합계'
        tot.sort_by { |_, v| -v }.each do |k, v|
          say format('    %-14s %5d개 · %16s lm', k, cnt[k], comma(v))
        end
        say ''
      end

      # 여기가 판정입니다.
      def rect_analysis(rect)
        say '=' * 96
        say '[2] 판정 — Luminosity 는 넓이에 비례하는가'
        say '=' * 96
        if rect.empty?
          say '    사각 광원이 없습니다.'
          say ''
          return
        end

        say format('%-30s %10s %10s %12s %12s %12s',
                   '이름', '넓이(m2)', '개수', 'Luminosity', 'lm/m2', 'cd/m2')
        pts = []
        rect.sort_by { |r| -(r[:lm] * r[:inst]) }.each do |r|
          a = (r[:w] && r[:l]) ? r[:w] * r[:l] : 0.0
          per = a > 1e-9 ? r[:lm] / a : nil
          cd  = a > 1e-9 ? r[:lm] / (Math::PI * a) : nil
          pts << [a, r[:lm]] if a > 1e-9
          say format('%-30s %10s %10d %12.1f %12s %12s',
                     r[:name][0, 30], a > 1e-9 ? format('%.4f', a) : '-', r[:inst], r[:lm],
                     per ? comma(per) : '-', cd ? comma(cd) : '-')
        end
        say ''

        if pts.size < 3
          say '    표본이 적어 상관을 말할 수 없습니다.'
          say ''
          return
        end

        # **퇴화 검사를 먼저 합니다.**
        #
        # 실측에서 39종 중 38종이 Luminosity 가 정확히 같았습니다. 그런
        # 자료에 회귀를 돌리면 남은 한 점이 기울기를 정하고, 이 모델에서는
        # 그 값이 +1.096 이 나왔습니다 — "넓이에 비례한다 = 지금 방식이
        # 맞다"로 읽힐 뻔했습니다. 통계는 옳게 계산됐고 결론만 틀립니다.
        # 원표를 보고서야 알았습니다.
        vals = pts.map { |_, v| v }.map { |v| v.round(6) }
        uniq = vals.uniq
        if uniq.size <= 2 && vals.size >= 5
          top = uniq.max_by { |u| vals.count(u) }
          say format('    ** Luminosity 가 사실상 한 값입니다 — %d개 중 %d개가 %s **',
                     vals.size, vals.count(top), comma(top))
          say '    같은 값이 반복되면 이것은 작성자가 정한 값이 아니라'
          say '    **기본값**입니다. 넓이와의 상관은 의미가 없습니다 —'
          say '    아래 기울기를 근거로 쓰지 마십시오.'
          say ''
        end

        # 로그-로그 기울기. 비례하면 1, 무관하면 0 근처입니다.
        lx = pts.map { |a, _| Math.log(a) }
        ly = pts.map { |_, v| Math.log([v, 1e-9].max) }
        mx = lx.sum / lx.size
        my = ly.sum / ly.size
        sxy = lx.each_with_index.sum { |x, i| (x - mx) * (ly[i] - my) }
        sxx = lx.sum { |x| (x - mx)**2 }
        syy = ly.sum { |y| (y - my)**2 }
        slope = sxx > 1e-12 ? sxy / sxx : 0.0
        r2    = (sxx * syy) > 1e-12 ? (sxy * sxy) / (sxx * syy) : 0.0

        pm = pts.map { |a, v| v / a }
        cv = spread(pm)
        say format('    log(Luminosity) 대 log(넓이) 기울기 = %+.3f   R2 = %.3f  (표본 %d)',
                   slope, r2, pts.size)
        say format('    lm/m2 의 흩어짐(변동계수) = %.2f   범위 %s ~ %s',
                   cv, comma(pm.min), comma(pm.max))
        say ''
        say '    읽는 법'
        say '      기울기 ~ +1 이고 R2 가 높다   -> Luminosity 는 **총광속(lm)**. 지금 방식이 맞다'
        say '      기울기 ~  0 이다              -> **단위 면적당 양**. 넓이를 곱해야 한다'
        say '      둘 다 아니다                  -> 단위가 아니라 값 자체가 제각각 (작성자가 넣은 수)'
        say ''
        say format('    참고: 사무실 패널은 %s cd/m2 입니다.', comma(PANEL_LM / (Math::PI * PANEL_AREA)))
        say ''
      end

      # 인스턴스가 배율을 갖고 있으면 정의의 W·L 만 보는 것이 틀립니다.
      def scales(model, rows)
        say '=' * 96
        say '[3] 인스턴스 배율 — 정의의 W·L 을 믿어도 되는가'
        say '=' * 96
        rect = rows.select { |r| r[:kind] == 'rectangular' }
        if rect.empty?
          say '    사각 광원이 없습니다.'
          say ''
          return
        end
        odd = 0
        rect.sort_by { |r| -r[:inst] }.first(12).each do |r|
          ss = (r[:defn].instances rescue []).first(4).map { |i| scale_of(i) }
          bad = ss.any? { |s| s.any? { |v| (v - 1.0).abs > 0.01 } }
          odd += 1 if bad
          say format('    %-30s %s%s', r[:name][0, 30],
                     ss.map { |s| format('(%.2f,%.2f,%.2f)', *s) }.join(' '),
                     bad ? '   <- 배율 있음' : '')
        end
        say ''
        say(odd.zero? ? '    배율이 전부 1 입니다 — 정의의 W·L 을 그대로 써도 됩니다.' :
                        "    **#{odd}종에 배율이 있습니다 — 실제 발광 넓이가 W·L 과 다릅니다.**")
        say ''
      end

      def raw(rows, max_xml)
        say '=' * 96
        say '[4] 원문 (IesData 는 생략)'
        say '=' * 96
        rect = rows.select { |r| r[:kind] == 'rectangular' }.sort_by { |r| -r[:lm] }
        pick = rect.first(max_xml) + rect.last(max_xml)
        pick.uniq { |r| r[:name] }.each do |r|
          say ''
          say "--- #{r[:name]}  (인스턴스 #{r[:inst]}) ---"
          say r[:xml]
        end
        say ''
      end

      def scale_of(inst)
        a = (inst.transformation.to_a rescue nil)
        return [1.0, 1.0, 1.0] unless a
        [Math.sqrt(a[0]**2 + a[1]**2 + a[2]**2),
         Math.sqrt(a[4]**2 + a[5]**2 + a[6]**2),
         Math.sqrt(a[8]**2 + a[9]**2 + a[10]**2)]
      rescue StandardError
        [1.0, 1.0, 1.0]
      end

      def spread(v)
        return 0.0 if v.size < 2
        m = v.sum / v.size
        return 0.0 if m.abs < 1e-12
        Math.sqrt(v.sum { |x| (x - m)**2 } / v.size) / m.abs
      end

      def num(xml, tag)
        return nil unless xml[%r{<#{tag}>([^<]*)</#{tag}>}]
        v = Regexp.last_match(1).to_s.strip
        v.empty? ? nil : Float(v)
      rescue StandardError
        nil
      end

      def comma(v)
        v.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
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
        path = File.join(dir, 'rect_probe.txt')
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

IRIS::RectProbe.run
