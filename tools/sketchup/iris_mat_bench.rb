# encoding: UTF-8
#
# IRIS — 재질 변경 한 번의 값
#
# 무엇을 재는가
#   재질의 색을 바꾸면 추출이 얼마나 걸리는가. 고치기 전에는 정의 2,249개가
#   전부 무효화되어 131만 삼각형을 다시 뽑았고 **33초**가 걸렸습니다.
#   지오메트리는 하나도 안 바뀌었는데요.
#
#   빠른 것만으로는 부족합니다. **바뀐 색이 실제로 매니페스트에 반영되는지**를
#   같이 봅니다. 안 그러면 "아무것도 안 해서 빠른" 것과 구별되지 않습니다.
#
# 재는 방법
#   1) 캐시를 데운다            — 전체 추출
#   2) 변경 없이 한 번 더       — 바닥값 (캐시가 다 맞을 때의 비용)
#   3) 재질 하나의 색을 바꾼다  — 옵저버가 깨어난다
#   4) 다시 추출                — **이것이 측정값**
#   5) 색을 되돌린다
#
# 모델은 원래대로 되돌립니다(색을 기록해 두었다가 되돌립니다).
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_mat_bench.rb'
#
# 결과는 out/sketchup/mat_bench.txt 에 남습니다.

require 'fileutils'

module IRIS
  module MatBench
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Probe)
          return puts('[IRIS] iris_reload.rb 를 먼저 실행하십시오.')
        end

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        say '[1] 캐시 데우기 (전체 추출)'
        ms0, s0 = timed_run
        return finish(out_dir, '추출에 실패했습니다.') unless s0
        say format('    %9.1f ms · 신규 %d · 캐시 %d · 삼각형 %s',
                   ms0, s0[:new], s0[:hit], comma(s0[:tris]))
        say tex_line(s0)
        say ''

        say '[2] 변경 없이 한 번 더 (바닥값)'
        ms1, s1 = timed_run
        say format('    %9.1f ms · 신규 %d · 캐시 %d', ms1, s1[:new], s1[:hit])
        say tex_line(s1)
        say ''

        target = pick_material(model, s1)
        return finish(out_dir, '색을 바꿀 만한 재질을 찾지 못했습니다.') unless target
        key    = "mat_#{target.entityID}"
        before = color_of(s1, key)
        orig   = target.color

        say "[3] 재질 '#{target.name}' (#{key}) 의 색을 바꿉니다"
        say format('    바꾸기 전 매니페스트 색(선형) %s', fmt3(before))
        newc = Sketchup::Color.new((orig.red + 97) % 256,
                                   (orig.green + 41) % 256,
                                   (orig.blue + 173) % 256)
        model.start_operation('IRIS mat bench', true)
        target.color = newc
        model.commit_operation
        say format('    sRGB (%d,%d,%d) -> (%d,%d,%d)',
                   orig.red, orig.green, orig.blue, newc.red, newc.green, newc.blue)

        fired = stale?
        say format('    옵저버가 깨웠는가: materials_stale? = %s', fired.inspect)
        unless fired
          say '    ** Ruby 로 색을 바꿨을 때는 옵저버가 안 깨웠습니다.'
          say '       SketchUp 은 재질 편집기(UI)에서 바꿀 때만 부르는 것으로 보입니다.'
          say '       화면에서 바꾸는 실제 사용은 깨웁니다 — 그건 따로 확인하십시오.'
          say '       여기서는 손으로 그 재질만 표시해 두고 계속합니다.'
          c = cache
          if c && c.respond_to?(:invalidate_material)
            c.invalidate_material(target)
          elsif c
            c.invalidate_materials
          end
        end
        say ''

        say '[4] 재질만 바뀐 뒤 추출   ** 측정값 **'
        ms2, s2 = timed_run
        after = color_of(s2, key)
        say format('    %9.1f ms · 신규 %d · 캐시 %d · 재질갱신 %d',
                   ms2, s2[:new], s2[:hit], s2[:refreshed])
        say tex_line(s2)
        say format('    바꾼 뒤 매니페스트 색(선형) %s', fmt3(after))
        say ''

        model.start_operation('IRIS mat bench restore', true)
        target.color = orig
        model.commit_operation
        say '[5] 색을 원래대로 되돌렸습니다.'
        ms3, s3 = timed_run
        say format('    되돌린 뒤 추출 %.1f ms · 신규 %d · 재질갱신 %d',
                   ms3, s3[:new], s3[:refreshed])
        say tex_line(s3)
        say format('    되돌린 뒤 색 %s', fmt3(color_of(s3, key)))
        say ''

        changed = before && after && !same3(before, after)
        say '=' * 60
        say '판정'
        say '=' * 60
        say format('  속도    : 전체 %.0f ms -> 재질 변경 %.0f ms  (바닥값 %.0f ms)',
                   ms0, ms2, ms1)
        say format('  지오메트리 재추출 : %d개  %s',
                   s2[:new], s2[:new].zero? ? '<- 0 이어야 합니다. 통과.' : '<- 0 이 아닙니다. 실패.')
        say format('  색 반영 : %s',
                   changed ? '바뀐 색이 매니페스트에 들어왔습니다. 통과.' :
                             '** 색이 그대로입니다. 재질을 다시 안 읽었습니다. 실패. **')
        say format('  텍스처  : %d장 다시 뽑음 (1장 이하여야 합니다)', s2[:tex_new])
        say format('  옵저버  : %s', fired ? 'Ruby 변경에도 깨어남' : 'Ruby 변경으로는 안 깨어남 (UI 는 별도 확인)')
        say ''
        if s2[:new].zero? && changed
          say '  두 조건이 같이 성립해야 의미가 있습니다 —'
          say '  "빠르지만 반영이 안 되는 것"은 고친 게 아닙니다.'
        end
        say ''
        say '다음: 렌더러를 띄우고 IRIS::Link.sync(force: true) 로'
        say '      실제 전송량(geom_sent 0)을 확인하십시오.'

        finish(out_dir, nil)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir, nil)
      end

      def timed_run
        t = Time.now
        IRIS::Probe.run(dump: false, cache: true)
        [(Time.now - t) * 1000.0, snapshot]
      end

      def snapshot
        sc = IRIS::Probe.last_scene
        return nil unless sc
        st = IRIS::Probe.instance_variable_get(:@stats) || {}
        { new:       st['defs_extracted'].to_i,
          hit:       st['defs_cached'].to_i,
          tris:      st['triangles'].to_i,
          refreshed: st['materials_refreshed'].to_i,
          tex_new:   st['textures_exported'].to_i,
          tex_reuse: st['textures_reused'].to_i,
          mats:      sc['materials'] || [] }
      end

      # 텍스처 재추출이 이번 수정의 진짜 비용이었습니다 — 231장을 다시 뽑느라
      # 13.9초였습니다. 매 단계에서 몇 장을 뽑았는지 같이 봅니다.
      def tex_line(s)
        format('              텍스처 %d장 새로 뽑음 / %d장 재사용',
               s[:tex_new].to_i, s[:tex_reuse].to_i)
      end

      def cache = IRIS::Probe.instance_variable_get(:@def_cache)

      def stale?
        c = cache
        c && c.respond_to?(:materials_stale?) ? c.materials_stale? : nil
      end

      # 텍스처 없는 재질을 고릅니다 — 색이 곧 눈에 보이는 값이라 판정이 분명합니다.
      def pick_material(model, snap)
        ids = {}
        (snap[:mats] || []).each { |m| ids[m['id']] = true }
        cands = model.materials.select { |m| ids.key?("mat_#{m.entityID}") }
        return nil if cands.empty?
        cands.find { |m| (m.texture rescue nil).nil? } || cands.first
      end

      def color_of(snap, key)
        return nil unless snap
        rec = (snap[:mats] || []).find { |m| m['id'] == key }
        rec && rec['color']
      end

      def same3(a, b)
        3.times.all? { |i| (a[i].to_f - b[i].to_f).abs < 1e-6 }
      end

      def fmt3(a)
        return '(없음)' unless a
        format('(%.4f, %.4f, %.4f)', a[0].to_f, a[1].to_f, a[2].to_f)
      end

      def comma(v)
        v.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
      end

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def finish(out_dir, msg)
        say msg if msg
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'mat_bench.txt')
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

IRIS::MatBench.run
