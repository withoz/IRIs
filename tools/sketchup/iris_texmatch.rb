# encoding: UTF-8
#
# IRIS — 내보낸 텍스처가 **정말 그 재질의 것인가**
#
# 왜
#   사용자가 화면을 보고 짚었습니다: "스케치업과 IRIS 재질이 다릅니다."
#   바닥(`stone05`)을 캐 보니:
#
#     SketchUp  stone05   1442 x 597 · 평균색 [53,53,50] (어두움)
#     내보낸 것 mat_218.png 1800 x 1800 · 평균 [142,140,131] (밝음)
#
#   **다른 그림입니다.**
#
#   원인 후보는 내보내기의 캐시입니다(iris_probe.rb export_texture):
#
#     if File.exist?(path)
#       @stats['textures_reused'] += 1
#       return rel            # 다시 쓰지 않습니다
#     end
#
#   무효화는 재질 관찰자가 잡은 변경뿐입니다. 그런데 파일 이름이
#   `mat_<entityID>.png` 이고 **entityID 는 모델을 다시 열 때마다 다시
#   매겨집니다.** 폴더는 모델 **제목**으로만 갈립니다. 그래서 지난 세션의
#   다른 재질 그림이 같은 이름으로 남아 있으면 그대로 나갑니다.
#
# 무엇을 재나
#   텍스처가 있는 재질마다 **SketchUp 이 말하는 크기**와 **내보낸 PNG 의
#   크기**를 견줍니다. PNG 헤더만 읽으면 되므로 빠릅니다(IHDR: 16~23바이트).
#
#   크기가 다르면 **확실히 다른 그림**입니다. 같다고 같은 그림이라는
#   보장은 없지만(같은 크기의 다른 사진), 크기만으로도 규모가 드러납니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_texmatch.rb'
#
# 읽기 전용입니다. out/sketchup/texmatch.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module TexMatch
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"

        dir = texture_dir(model)
        say "텍스처 폴더: #{dir}"
        unless dir && File.directory?(dir)
          say '폴더가 없습니다 — 한 번도 내보내지 않았거나 경로가 다릅니다.'
          return finish(out_dir)
        end
        say ''

        unless defined?(IRIS::Probe)
          f = File.join(File.dirname(__FILE__), 'iris_probe.rb')
          load f if File.exist?(f)
        end

        rows = []
        model.materials.each do |m|
          t = (m.texture rescue nil)
          next unless t
          # 이름은 이제 **그림**이 정합니다(iris_probe.rb texture_key).
          key  = (IRIS::Probe.texture_key(m, t) rescue "mat_#{m.entityID}")
          file = File.join(dir, "#{key}.png")
          want = [t.image_width.to_i, t.image_height.to_i]
          got  = File.exist?(file) ? png_size(file) : nil
          rows << { name: m.display_name.to_s, id: m.entityID, want: want, got: got,
                    src: File.basename(t.filename.to_s) }
        end

        missing = rows.count { |r| r[:got].nil? }
        same    = rows.count { |r| r[:got] && r[:got] == r[:want] }
        diff    = rows.select { |r| r[:got] && r[:got] != r[:want] }

        say '=' * 96
        say "텍스처 있는 재질 #{rows.size}개"
        say '=' * 96
        say format('    크기 일치       %4d개', same)
        say format('    **크기 불일치**  %4d개   <- 확실히 다른 그림입니다', diff.size)
        say format('    내보낸 파일 없음 %4d개', missing)
        say ''

        unless diff.empty?
          say '=' * 96
          say '어긋난 것 — SketchUp 이 말하는 크기 vs 내보낸 PNG'
          say '=' * 96
          diff.sort_by { |r| r[:name] }.each do |r|
            say format('    %-26s  원본 %5dx%-5d  내보낸 것 %5dx%-5d   (%s)',
                       clip(r[:name], 26),
                       r[:want][0], r[:want][1], r[:got][0], r[:got][1], clip(r[:src], 24))
          end
        end

        say ''
        say '  크기가 같아도 다른 그림일 수 있습니다 — 이 검사는 **하한**입니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(8).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      # 프로브와 같은 규칙으로 폴더를 찾습니다.
      def texture_dir(model)
        base = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        title = model.title.to_s
        title = 'untitled' if title.empty?
        File.join(base, 'textures', title.gsub(/[\\\/:*?"<>|]/, '_').tr(' ', '_'))
      end

      # PNG 헤더에서 크기만. IHDR 의 폭/높이는 16~23바이트입니다.
      def png_size(path)
        File.open(path, 'rb') do |f|
          head = f.read(24)
          return nil unless head && head.bytesize == 24
          return nil unless head[0, 8].bytes == [137, 80, 78, 71, 13, 10, 26, 10]
          head[16, 8].unpack('N2')
        end
      rescue StandardError
        nil
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
        path = File.join(dir, 'texmatch.txt')
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

IRIS::TexMatch.run
