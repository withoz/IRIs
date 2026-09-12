# encoding: UTF-8
#
# IRIS — 텍스처 알파를 **어느 재질이** 갖고 있나
#
# 왜
#   나뭇잎·난간·타공판의 구멍은 재질 알파(Material#alpha)가 아니라 텍스처의
#   알파 채널에 있습니다. 재질 알파는 1.0 이라 그것만 보면 "불투명"으로
#   읽히고, 수신부가 구멍을 막은 채 그립니다(11번 (a)).
#
#   프로브가 그 채널을 재서 매니페스트에 싣도록 고쳤습니다. 이 도구는
#   **프로브와 같은 함수를 불러** 무엇이 컷아웃으로 나가는지 보여 줍니다.
#   화면으로 확인하기 전에, 무엇을 봐야 하는지 알기 위한 것입니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_reload.rb'     # 프로브를 먼저 최신으로
#   load 'E:/IRIS/tools/sketchup/iris_texalpha.rb'
#
# 읽기 전용입니다. out/sketchup/texalpha.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module TexAlpha
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Probe) && IRIS::Probe.respond_to?(:texture_alpha_stats, true)
          return puts('[IRIS] 프로브가 낡았습니다. iris_reload.rb 를 먼저 올리십시오.')
        end

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        # 재질이 실제로 몇 면에 쓰이는지도 셉니다 — 이름만으로는 화면에서
        # 어디를 봐야 할지 모릅니다.
        use = Hash.new(0)
        owner = Hash.new { |h, k| h[k] = Hash.new(0) }
        t0 = Time.now
        walk(model.entities, 0, '(루트)', use, owner)
        say format('트리 순회 %.1f ms', (Time.now - t0) * 1000.0)
        say ''

        rows = []
        model.materials.each do |m|
          tex = (m.texture rescue nil)
          next unless tex
          st = IRIS::Probe.send(:texture_alpha_stats, tex)
          rows << [m, tex, st]
        end

        say '=' * 96
        say '텍스처 있는 재질 — 알파 채널과 구멍'
        say '=' * 96
        say format('    %-26s %6s %11s %6s %8s %8s %8s',
                   '이름', '알파', '픽셀', '채널', '최솟값', '구멍%', '면')
        cut = 0
        rows.sort_by { |m, _, _| -use[m.entityID] }.each do |m, tex, st|
          ch   = st && st['channel']
          mn   = st && st['min']
          hole = st && st['holes']
          on   = ch && (hole.nil? || hole > 0.001)
          cut += 1 if on
          say format('    %-26s %6.3f %5dx%-5d %6s %8s %8s %8d  %s',
                     clip(m.display_name.to_s, 26), (m.alpha rescue 1.0),
                     (tex.image_width rescue 0), (tex.image_height rescue 0),
                     ch.nil? ? '?' : (ch ? 'O' : 'X'),
                     mn.nil? ? '-' : mn.to_s,
                     hole.nil? ? '-' : format('%.2f', hole * 100.0),
                     use[m.entityID],
                     on ? '<< 컷아웃' : '')
        end
        say ''
        say "    컷아웃으로 나갈 재질: #{cut}개 / 텍스처 재질 #{rows.size}개"
        say ''

        say '=' * 96
        say '컷아웃 재질은 어디에 있나 (화면에서 확인할 곳)'
        say '=' * 96
        rows.each do |m, _, st|
          next unless st && st['channel'] && (st['holes'].nil? || st['holes'] > 0.001)
          where = owner[m.entityID].sort_by { |_, v| -v }.first(5)
                                   .map { |k, v| "#{k}(#{v})" }.join(' · ')
          say format('    %-26s %s', clip(m.display_name.to_s, 26), clip(where, 62))
        end
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      MAX_DEPTH = 12

      def walk(entities, depth, owner_name, use, owner)
        return if depth > MAX_DEPTH
        entities.each do |e|
          case e
          when Sketchup::Face
            [e.material, e.back_material].compact.uniq.each do |m|
              use[m.entityID] += 1
              owner[m.entityID][owner_name] += 1
            end
          when Sketchup::ComponentInstance, Sketchup::Group
            d = (e.definition rescue nil)
            next unless d
            nm = if e.is_a?(Sketchup::ComponentInstance)
                   d.name.to_s
                 else
                   e.name.to_s.empty? ? owner_name : e.name.to_s
                 end
            walk(d.entities, depth + 1, nm, use, owner)
          end
        end
      end

      def clip(t, n) = t.to_s[0, n]

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def finish(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'texalpha.txt')
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

IRIS::TexAlpha.run
