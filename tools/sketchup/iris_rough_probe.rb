# encoding: UTF-8
#
# IRIS — 거칠기를 추측할 **신호가 실제로 있나** (11번 (g) 준비)
#
# 왜
#   Enscape 값이 없는 재질은 전부 `roughness 0.5 · metalness 0` 고정입니다.
#   아스팔트도 스테인리스도 잔디도 같은 광택이라 화면이 플라스틱처럼
#   보입니다. 재질의 80~90% 가 여기 해당합니다.
#
#   추측 규칙을 넣기 전에 **무엇을 근거로 삼을 수 있는지** 먼저 셉니다.
#   오늘 "큰 면만 유리로 본다"는 규칙을 넣을 뻔했습니다 — 데이터가 깨끗하게
#   갈렸지만 램프 렌즈를 깨뜨렸을 규칙이었습니다(09번 8-i).
#
#   후보 신호 셋을 각각 세어 봅니다:
#
#     1. SketchUp 기본 재질 이름   `[Asphalt New]` 처럼 대괄호에 영문.
#                                  라이브러리에서 온 것이라 뜻이 분명합니다.
#     2. 텍스처 유무               텍스처가 있으면 실제 표면(목재·석재·직물),
#                                  색만 있으면 도장일 때가 많습니다.
#     3. 이름에 뜻이 있는가         `chrome`·`wood flooring` 처럼 영어 단어.
#                                  `재질16`·`L16 색` 은 아무 신호가 없습니다.
#
#   **신호가 없는 재질이 몇 %인지**가 이 작업의 상한입니다. 거기에는
#   어떤 규칙을 넣어도 0.5 고정과 다를 바 없습니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_rough_probe.rb'
#
# 읽기 전용입니다. out/sketchup/rough_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module RoughProbe
    class << self
      MAX_DEPTH = 12

      def run(out_dir: nil, top: 24)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Enscape)
          f = File.join(File.dirname(__FILE__), 'iris_enscape.rb')
          load f if File.exist?(f)
        end

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        use = Hash.new(0)
        t0 = Time.now
        walk(model.entities, 0, use)
        say format('트리 순회 %.1f ms', (Time.now - t0) * 1000.0)
        say ''

        rows = []
        ens = []
        enscape = 0
        model.materials.each do |m|
          has_ens = defined?(IRIS::Enscape) &&
                    !IRIS::Enscape.send(:dict_value, m, 'Enscape.Material', 'MaterialData').nil?
          if has_ens
            enscape += 1
            ens << { name: m.display_name.to_s, faces: use[m.entityID],
                     tex: !(m.texture rescue nil).nil?,
                     pbr: (IRIS::Enscape.material(m) rescue nil) }
            next   # 저작자 값이 있으면 추측할 일이 없습니다
          end

          name = m.display_name.to_s
          c = (m.color rescue nil)
          rows << {
            name: name,
            faces: use[m.entityID],
            tex:  !(m.texture rescue nil).nil?,
            lib:  library_name?(name),
            word: meaningful?(name),
            rgb:  c ? [c.red, c.green, c.blue] : nil,
          }
        end

        total = rows.size
        say '=' * 96
        say "[1] 신호가 있나 — Enscape 값이 없는 재질 #{total}개 " \
            "(전체 #{model.materials.size}, Enscape 있음 #{enscape})"
        say '=' * 96
        lib  = rows.count { |r| r[:lib] }
        word = rows.count { |r| !r[:lib] && r[:word] }
        tex  = rows.count { |r| !r[:lib] && !r[:word] && r[:tex] }
        none = total - lib - word - tex
        pct  = ->(n) { total.zero? ? 0.0 : 100.0 * n / total }
        say format('    SketchUp 기본 재질 이름  %5d개 (%4.1f%%)  <- 뜻이 분명합니다', lib, pct.call(lib))
        say format('    영어 낱말이 든 이름      %5d개 (%4.1f%%)  <- 약한 신호', word, pct.call(word))
        say format('    이름은 없고 텍스처만     %5d개 (%4.1f%%)  <- 아주 약한 신호', tex, pct.call(tex))
        say format('    **신호 없음**            %5d개 (%4.1f%%)  <- 규칙을 넣어도 소용없습니다',
                   none, pct.call(none))
        say ''

        # 면 수로 가중하면 화면에서 차지하는 몫에 가깝습니다.
        fsum = ->(sel) { rows.select(&sel).sum { |r| r[:faces] } }
        tf = rows.sum { |r| r[:faces] }
        say '    면 수로 가중하면 (화면에서 차지하는 몫에 가깝습니다):'
        fp = ->(n) { tf.zero? ? 0.0 : 100.0 * n / tf }
        say format('      기본 이름 %5.1f%% · 낱말 %5.1f%% · 텍스처만 %5.1f%% · 신호 없음 %5.1f%%',
                   fp.call(fsum.call(->(r) { r[:lib] })),
                   fp.call(fsum.call(->(r) { !r[:lib] && r[:word] })),
                   fp.call(fsum.call(->(r) { !r[:lib] && !r[:word] && r[:tex] })),
                   fp.call(fsum.call(->(r) { !r[:lib] && !r[:word] && !r[:tex] })))
        say ''

        say '=' * 96
        say '[2] SketchUp 기본 재질 이름 — 실제로 무엇이 있나'
        say '=' * 96
        rows.select { |r| r[:lib] }.sort_by { |r| -r[:faces] }.first(top).each do |r|
          say format('    %-34s %7d면  %s', clip(r[:name], 34), r[:faces],
                     r[:tex] ? '텍스처' : '색만')
        end
        say ''

        say '=' * 96
        say '[3] 신호가 없는데 면이 많은 것 — 여기가 손해 보는 자리'
        say '=' * 96
        rows.select { |r| !r[:lib] && !r[:word] }.sort_by { |r| -r[:faces] }.first(top).each do |r|
          say format('    %-34s %7d면  %s  RGB%s', clip(r[:name], 34), r[:faces],
                     r[:tex] ? '텍스처' : '색만 ', r[:rgb].inspect)
        end
        say ''
        say '=' * 96
        say '[4] 영어 낱말이 든 이름 — 낱말이 정말 뜻을 담고 있나'
        say '=' * 96
        rows.select { |r| !r[:lib] && r[:word] }.sort_by { |r| -r[:faces] }.each do |r|
          say format('    %-34s %7d면  %s  %s', clip(r[:name], 34), r[:faces],
                     r[:tex] ? '텍스처' : '색만 ', r[:name].scan(/[A-Za-z]{3,}/).join(','))
        end
        say ''
        say '=' * 96
        say '[5] Enscape 값이 있는 재질 — 저작자는 실제로 어떤 값을 쓰나'
        say '=' * 96
        ens.sort_by { |r| -r[:faces] }.each do |r|
          p = r[:pbr]
          if p.nil?
            say format('    %-30s %7d면  (해석 실패)', clip(r[:name], 30), r[:faces])
            next
          end
          say format('    %-30s %7d면  %-10s R=%-6s M=%-6s S=%-6s O=%-6s',
                     clip(r[:name], 30), r[:faces], p['etype'].to_s,
                     fmt(p['roughness']), fmt(p['metalness']),
                     fmt(p['specular']), fmt(p['opacity']))
        end
        say ''
        vals = ens.map { |r| r[:pbr] && r[:pbr]['roughness'] }.compact
        if vals.any?
          hist = Hash.new(0)
          vals.each { |v| hist[(v * 100).round / 100.0] += 1 }
          say '    거칠기 값의 도수 — 같은 값이 뭉치면 그게 Enscape 기본값입니다:'
          hist.sort_by { |v, n| [-n, v] }.first(12).each do |v, n|
            say format('      %.2f  %s %d개', v, '#' * n, n)
          end
          say format('    중앙값 %.2f · 평균 %.2f · 최소 %.2f · 최대 %.2f',
                     median(vals), vals.sum / vals.size.to_f, vals.min, vals.max)
        end
        say ''
        say '  읽는 법'
        say '    [1] 의 "신호 없음" 비율이 이 작업의 **상한**입니다.'
        say '    [2] 가 두꺼우면 이름 규칙만으로도 값이 있습니다.'
        say '    [3] 이 두꺼우면 이름으로는 못 잡습니다 — 다른 신호를 찾거나'
        say '        사용자 편집에 기대야 합니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      # SketchUp 기본 라이브러리 이름: 대괄호 안에 영문. `[Asphalt New]`,
      # `[Granite Light Gray]2`, `[Color_A07]` 처럼 뒤에 번호가 붙기도 합니다.
      #
      # `[Color_...]`·`[Translucent ...]` 는 색·유리 계열이라 거칠기 신호가
      # 약하지만, 일단 '기본 이름'으로 세고 종류는 [2] 에서 눈으로 봅니다.
      def library_name?(name)
        !!(name =~ /\A\[[A-Za-z][A-Za-z0-9 _\-]*\]/)
      end

      # 영어 낱말이 둘 이상 들어 있으면 뜻이 있다고 봅니다.
      # `chrome`, `wood flooring`, `_sofa fabric` 같은 것들입니다.
      def meaningful?(name)
        words = name.scan(/[A-Za-z]{3,}/)
        return false if words.empty?
        # `Matte__FFCCC`, `_auto_9`, `mat_123` 처럼 기계가 만든 이름은 뺍니다.
        return false if name =~ /\A(Matte__|_auto|mat_|Color_|재질)/i
        true
      end

      def walk(entities, depth, use)
        return if depth > MAX_DEPTH
        entities.each do |e|
          case e
          when Sketchup::Face
            [e.material, e.back_material].compact.uniq.each { |m| use[m.entityID] += 1 }
          when Sketchup::ComponentInstance, Sketchup::Group
            d = (e.definition rescue nil)
            walk(d.entities, depth + 1, use) if d
          end
        end
      end

      def clip(t, n) = t.to_s[0, n]

      def fmt(v) = v.nil? ? '-' : format('%.3f', v)

      def median(a)
        s = a.sort
        n = s.size
        n.odd? ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
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
        path = File.join(dir, 'rough_probe.txt')
        File.open(path, 'w:UTF-8') { |f| @log.each { |l| f.puts l } }
        puts "저장: #{path}"
        nil
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

IRIS::RoughProbe.run
