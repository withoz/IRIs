# encoding: UTF-8
#
# IRIS — 반투명 재질이 무엇이고 우리가 무엇으로 바꾸는가
#
# 왜
#   화면에서 어떤 면이 **뿌옇게** 나올 때, 원인은 대개 셋 중 하나입니다.
#
#     1. 알파가 1 미만인데 텍스처가 없다  -> 우리가 **유리(Transmissive)** 로
#        바꿉니다 (SceneBuilder.cpp). 건축 모델에서 알파만 걸린 단색 재질은
#        거의 항상 유리라서 그렇게 둔 것인데, 타공판·메시 스크린도 같은
#        모양을 하고 있으면 같이 휩쓸립니다.
#
#     2. 알파가 1 미만인데 텍스처가 있다  -> AlphaBlended 로 둡니다. 잎사귀
#        컷아웃이면 맞지만, 타공 구멍을 텍스처로 표현한 패널이면 구멍이
#        뚫리지 않고 **균일한 막**으로 보입니다.
#
#     3. 애초에 모델에서 반투명하다       -> 우리 잘못이 아닙니다.
#
#   셋을 가르려면 재질의 알파와 텍스처 유무를 같이 봐야 합니다. 그것만
#   찍습니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_alpha_probe.rb'
#
#   면을 하나 선택하고 부르면 그 면의 재질을 맨 위에 따로 적습니다.
#
# 읽기 전용입니다. out/sketchup/alpha_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module AlphaProbe
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        # 선택한 것이 있으면 그것부터.
        sel = model.selection.to_a
        unless sel.empty?
          say '=' * 74
          say '[0] 선택한 것'
          say '=' * 74
          sel.first(6).each { |e| describe_entity(e) }
          say ''
        end

        mats = model.materials.to_a
        say '=' * 74
        say "[1] 반투명 재질 (알파 < 1) — 전체 #{mats.size}개 중"
        say '=' * 74
        say format('    %-34s %6s %6s %8s %s', '이름', '알파', '텍스처', '우리 처리', '쓰는 곳')
        rows = mats.select { |m| (m.alpha rescue 1.0) < 0.999 }
        if rows.empty?
          say '    없습니다.'
        else
          rows.sort_by { |m| m.alpha rescue 1.0 }.each do |m|
            a   = (m.alpha rescue 1.0)
            tex = !(m.texture rescue nil).nil?
            say format('    %-34s %6.3f %6s %8s %s',
                       m.display_name.to_s[0, 34], a, tex ? 'O' : 'X',
                       tex ? 'AlphaBl' : '**유리**', usage_hint(model, m))
          end
        end
        say ''

        say '=' * 74
        say '[2] 이름에 타공/메시/스크린이 든 재질'
        say '=' * 74
        pat = /perforat|타공|mesh|메시|screen|스크린|louver|루버|grill/i
        hits = mats.select { |m| m.display_name.to_s =~ pat }
        if hits.empty?
          say '    없습니다.'
        else
          hits.each do |m|
            a   = (m.alpha rescue 1.0)
            tex = (m.texture rescue nil)
            say format('    %-34s 알파 %.3f · 텍스처 %s',
                       m.display_name.to_s[0, 34], a,
                       tex ? "#{tex.width.round}x#{tex.height.round} #{File.basename(tex.filename.to_s)}" : '없음')
            say format('        -> %s', a < 0.999 ? (tex ? 'AlphaBlended (구멍이 아니라 균일한 막)' : '**유리로 바뀝니다**') : '불투명 — 문제 없음')
          end
        end
        say ''

        say '=' * 74
        say '읽는 법'
        say '=' * 74
        say '  **유리** 로 표시된 것이 화면에서 뿌옇게 나오는 후보입니다.'
        say '  진짜 유리면 맞는 동작이고, 타공판·스크린이면 우리가 잘못 읽은 것입니다.'
        say '  알파 0.9 이상인데 유리로 바뀐 것이 있으면 특히 의심하십시오 —'
        say '  거의 불투명한데 투과로 그려집니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(8).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def describe_entity(e)
        say format('    %s', e.class.to_s.split('::').last)
        m = (e.material rescue nil)
        if m
          a = (m.alpha rescue 1.0)
          t = (m.texture rescue nil)
          say format('      재질 %s · 알파 %.3f · 텍스처 %s',
                     m.display_name, a, t ? File.basename(t.filename.to_s) : '없음')
          say format('      -> %s', a < 0.999 ? (t ? 'AlphaBlended' : '**유리(Transmissive)로 바뀝니다**') : '불투명')
        else
          say '      재질 없음 (상위에서 상속)'
        end
      end

      # 이 재질이 몇 군데 쓰이는지 — 전부 세면 느리니 상한을 둡니다.
      def usage_hint(model, mat)
        n = 0
        model.definitions.each do |d|
          next if d.image?
          d.entities.grep(Sketchup::Face).each do |f|
            n += 1 if f.material == mat || f.back_material == mat
            return "#{n}+곳" if n > 200
          end
        end
        model.entities.grep(Sketchup::Face).each do |f|
          n += 1 if f.material == mat || f.back_material == mat
        end
        "#{n}곳"
      rescue StandardError
        '?'
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
        path = File.join(dir, 'alpha_probe.txt')
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

IRIS::AlphaProbe.run
