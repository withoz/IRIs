# encoding: UTF-8
#
# IRIS — 반투명 재질에 대해 Enscape 는 뭐라고 적어 뒀나
#
# 왜
#   우리는 "알파 < 1 이고 텍스처 없음 -> 유리" 라는 **휴리스틱**으로 유리를
#   정합니다(SceneBuilder.cpp). 그런데 Enscape 로 작업된 모델에는 저작자가
#   직접 고른 값이 들어 있습니다 — `TypeV5`, `Opacity`, `IsSolidGlass`.
#
#   추측보다 저작자의 값이 낫습니다. 다만 **바꾸기 전에 무엇이 들어 있는지**
#   봐야 합니다. 없으면 지금 휴리스틱이 여전히 유일한 근거입니다.
#
#   특히 알파 0 짜리가 궁금합니다. SketchUp 에서는 안 보이는데, Enscape 가
#   Opacity 1 이라고 적어 뒀다면 **화면에서 보이는 것이 맞습니다.**
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_glass_probe.rb'
#
# 읽기 전용입니다. out/sketchup/glass_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module GlassProbe
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Enscape)
          return puts('[IRIS] iris_reload.rb 를 먼저 실행하십시오.')
        end

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        mats = model.materials.to_a
        trans = mats.select { |m| (m.alpha rescue 1.0) < 0.999 }

        say '=' * 78
        say "[1] 반투명 재질 — SketchUp 알파 대 Enscape 값"
        say '=' * 78
        say format('    %-28s %6s %6s %8s %6s %6s %s',
                   '이름', 'SU알파', 'Ens투명', 'TypeV5', '거칠기', '금속', 'Solid')
        if trans.empty?
          say '    없습니다.'
        else
          trans.sort_by { |m| m.alpha rescue 1.0 }.each { |m| row(m) }
        end
        say ''

        say '=' * 78
        say '[2] Enscape 설정이 있는 재질 전체 (반투명이 아니어도)'
        say '=' * 78
        withe = mats.select { |m| enscape(m) }
        say format('    %d개 / 전체 %d개', withe.size, mats.size)
        types = Hash.new(0)
        withe.each { |m| types[enscape(m)['etype'].to_s] += 1 }
        types.sort_by { |_, v| -v }.each { |t, n| say format('      %-24s %d', t, n) }
        say ''

        say '=' * 78
        say '[3] 판정에 쓸 수 있는가'
        say '=' * 78
        n_tr_with = trans.count { |m| enscape(m) }
        say format('    반투명 %d개 중 Enscape 값이 있는 것 %d개', trans.size, n_tr_with)
        if n_tr_with.zero?
          say '    -> **없습니다.** 이 모델에서는 알파 휴리스틱이 유일한 근거입니다.'
          say '       Enscape 값으로 보강해도 이 모델은 달라지지 않습니다.'
        elsif n_tr_with < trans.size
          say '    -> 일부만 있습니다. 있으면 그것을, 없으면 휴리스틱을 써야 합니다.'
        else
          say '    -> 전부 있습니다. 휴리스틱을 밀어낼 수 있습니다.'
        end
        say ''
        say '    알파 0 짜리가 Enscape 에서 불투명(Opacity 1)이면,'
        say '    SketchUp 화면이 아니라 **Enscape 화면이 정답**입니다 —'
        say '    이 모델은 Enscape 로 렌더하려고 만든 것이니까요.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(8).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def row(m)
        e = enscape(m)
        a = (m.alpha rescue 1.0)
        if e.nil?
          say format('    %-28s %6.3f %6s %8s %6s %6s %s',
                     m.display_name.to_s[0, 28], a, '-', '(없음)', '-', '-', '-')
          return
        end
        say format('    %-28s %6.3f %6s %8s %6s %6s %s',
                   m.display_name.to_s[0, 28], a,
                   e['opacity'] ? format('%.3f', e['opacity']) : '-',
                   e['etype'].to_s[0, 8],
                   e['roughness'] ? format('%.2f', e['roughness']) : '-',
                   e['metalness'] ? format('%.2f', e['metalness']) : '-',
                   e['solid_glass'] ? 'O' : '-')
      end

      def enscape(m)
        @cache ||= {}
        k = m.entityID
        return @cache[k] if @cache.key?(k)
        @cache[k] = (IRIS::Enscape.material(m) rescue nil)
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
        path = File.join(dir, 'glass_probe.txt')
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

IRIS::GlassProbe.run
