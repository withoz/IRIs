# encoding: UTF-8
#
# IRIS — ImageRep 에서 알파를 어떻게 읽나 (진단)
#
# 왜
#   `rep.resize(64,64)` 로 줄여 표본을 보려 했는데 거의 모든 텍스처에서
#   값이 안 나왔습니다. 어디서 막히는지 추측하지 않고 **정답이 있는 텍스처
#   하나로** 맞춰 봅니다.
#
#   정답: `Perforated Panel2` (617x490). 프로브가 내보낸 PNG 를 따로
#   디코딩해 보니 **픽셀의 38.6%가 완전 투명**이었습니다(11번 (a)).
#   어떤 읽기 방법이 38.6% 를 돌려주는지가 답입니다.
#
#   바이트 순서를 짐작하지 않습니다 — BGRA·RGBA 는 알파가 끝이지만
#   ARGB 는 앞입니다. 둘 다 재서 맞는 쪽을 고릅니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_texalpha_diag.rb'
#
# 읽기 전용입니다. out/sketchup/texalpha_diag.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module TexAlphaDiag
    class << self
      TARGET_W = 617
      TARGET_H = 490

      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        mat = model.materials.find do |m|
          t = (m.texture rescue nil)
          t && (t.image_width rescue 0) == TARGET_W && (t.image_height rescue 0) == TARGET_H
        end
        unless mat
          say "정답 텍스처(#{TARGET_W}x#{TARGET_H})를 못 찾았습니다."
          return finish(out_dir)
        end
        say "대상: #{mat.display_name} (#{TARGET_W}x#{TARGET_H}) — 정답 투명 38.6%"
        say ''

        rep = mat.texture.image_rep(true)
        say '=' * 76
        say '[1] ImageRep 이 무엇을 주나'
        say '=' * 76
        say "    클래스        : #{rep.class}"
        say "    크기          : #{rep.width} x #{rep.height}"
        say "    bits_per_pixel: #{(rep.bits_per_pixel rescue '?')}"
        say "    row_padding   : #{(rep.row_padding rescue '?')}"
        say "    size          : #{(rep.size rescue '?')}"
        meths = (rep.methods - Object.instance_methods).sort
        say "    메서드        : #{meths.join(', ')}"
        say ''

        say '=' * 76
        say '[2] resize 가 무엇을 돌려주나'
        say '=' * 76
        if rep.respond_to?(:resize)
          begin
            r = rep.resize(64, 64)
            say "    돌려준 것 : #{r.class}"
            if r.is_a?(Sketchup::ImageRep)
              say "    크기      : #{r.width} x #{r.height}  bpp #{(r.bits_per_pixel rescue '?')}"
            end
            say "    원본은    : #{rep.width} x #{rep.height} (제자리에서 바뀌었나 확인)"
          rescue StandardError => e
            say "    !! #{e.class}: #{e.message}"
          end
        else
          say '    resize 없음'
        end
        say ''

        say '=' * 76
        say '[3] colors 가 되나 (작은 것으로만)'
        say '=' * 76
        begin
          small = rep.respond_to?(:resize) ? rep.resize(64, 64) : nil
          if small.is_a?(Sketchup::ImageRep)
            t0 = Time.now
            cols = small.colors
            say format('    colors %d개, %.1f ms', cols.length, (Time.now - t0) * 1000.0)
            trans = cols.count { |c| (c.alpha rescue 255).to_i < 128 }
            say format('    알파<128 : %d / %d = %.1f%%  (정답 38.6%%)',
                       trans, cols.length, 100.0 * trans / cols.length)
          else
            say '    resize 가 ImageRep 을 안 줘서 건너뜁니다'
          end
        rescue StandardError => e
          say "    !! #{e.class}: #{e.message}"
        end
        say ''

        say '=' * 76
        say '[4] data 를 직접 — 바이트 순서를 재서 고릅니다'
        say '=' * 76
        begin
          t0 = Time.now
          data = rep.data
          say format('    data %s, %d 바이트, %.1f ms',
                     data.class, data.bytesize, (Time.now - t0) * 1000.0)
          bpp = (rep.bits_per_pixel rescue 32).to_i
          say "    픽셀당 바이트 : #{bpp / 8}"
          if bpp == 32
            npix = rep.width * rep.height
            say "    예상 바이트   : #{npix * 4} (패딩 없을 때)"
            [0, 3].each do |off|
              t1 = Time.now
              step = [npix / 4096, 1].max
              n = 0
              trans = 0
              mn = 255
              i = 0
              while i < npix
                b = data.getbyte(i * 4 + off)
                break if b.nil?
                n += 1
                trans += 1 if b < 128
                mn = b if b < mn
                i += step
              end
              say format('    바이트 %d 번째: 표본 %d · 알파<128 %.1f%% · 최솟값 %d · %.1f ms',
                         off, n, n.zero? ? 0.0 : 100.0 * trans / n, mn,
                         (Time.now - t1) * 1000.0)
            end
            say '    -> 38.6% 에 가까운 쪽이 알파 위치입니다.'
          else
            say '    32bpp 가 아니라 알파가 없습니다.'
          end
        rescue StandardError => e
          say "    !! #{e.class}: #{e.message}"
          (e.backtrace || []).first(3).each { |l| say "       #{l}" }
        end
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
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
        path = File.join(dir, 'texalpha_diag.txt')
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

IRIS::TexAlphaDiag.run
