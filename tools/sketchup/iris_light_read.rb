# encoding: UTF-8
#
# IRIS — 선택한 Enscape 조명의 원문을 읽습니다 (누적)
#
# 왜 필요한가
#   포르쉐 성수 모델의 사각 광원 39종 중 **38종이 Luminosity 가 정확히
#   같습니다** (300000.00000000012). 같은 값이 반복되면 작성자가 정한 값이
#   아니라 **기본값**입니다. 그러면 이 모델만 봐서는 단위를 알 수 없습니다 —
#   자료에 변화가 없으니까요.
#
#   변화를 **우리가 만들어서** 봅니다. Enscape UI 에서 밝기를 아는 값으로
#   바꾸고 저장된 수를 읽으면, UI 단위와 저장 단위의 대응이 바로 나옵니다.
#   두 점이면 배율과 오프셋이 정해집니다.
#
# 하는 법
#   1) SketchUp 에서 Enscape 사각 광원을 **하나 선택**합니다
#      (없으면 Enscape 로 새로 하나 놓습니다 — 기본값을 그대로 둡니다)
#   2) load 'E:/IRIS/tools/sketchup/iris_light_read.rb'          <- 기본값 기록
#   3) Enscape 조명 설정에서 밝기를 **1000** 으로 바꿉니다
#   4) 같은 줄을 다시 실행                                       <- 바뀐 값 기록
#   5) 밝기를 **2000** 으로 바꾸고 다시 실행                     <- 확인용 셋째 점
#
#   읽는 법
#     UI 1000 -> 저장 1000        단위는 lm. 기본값이 정말 300,000 lm 이다
#     UI 1000 -> 저장 다른 수     그 비가 곧 변환 배율이다
#     안 바뀐다                   UI 값이 다른 곳에 저장된다 (인스턴스 등)
#
# **누적해서 씁니다** — out/sketchup/light_read.txt 에 계속 덧붙습니다.
# 그래야 바꾸기 전과 후가 한 파일에 남습니다.

require 'fileutils'

module IRIS
  module LightRead
    DICT = 'Enscape.Light'

    class << self
      def run(out_dir: nil, note: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        lines = []
        say = ->(l) { lines << l.to_s; puts l }

        sel = model.selection.to_a
        say.call ''
        say.call '=' * 72
        say.call "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}   선택 #{sel.size}개#{note ? "   메모: #{note}" : ''}"
        say.call '=' * 72

        if sel.empty?
          say.call '아무것도 선택되지 않았습니다.'
          say.call 'Enscape 조명을 하나 클릭한 뒤 다시 실행하십시오.'
          return write(lines, out_dir)
        end

        found = 0
        sel.each do |e|
          d = definition_of(e)
          unless d
            say.call "  #{e.class} — 컴포넌트가 아닙니다 (건너뜁니다)"
            next
          end
          dict = (d.attribute_dictionary(DICT) rescue nil)
          unless dict
            say.call "  '#{d.name}' — Enscape.Light 사전이 없습니다"
            next
          end
          found += 1
          say.call "  정의: #{d.name}   인스턴스 #{(d.instances.length rescue 0)}개"
          say.call "  변환 배율: #{fmt_scale(e)}"
          dict.each_pair do |k, v|
            s = v.to_s.gsub(%r{<IesData>.*?</IesData>}m, '<IesData>...생략...</IesData>')
            say.call "  [#{k}]"
            s.each_line { |ln| say.call "    #{ln.rstrip}" }
          end
          # 인스턴스에도 사전이 붙는지 봅니다 — UI 값이 거기 갈 수도 있습니다.
          ids = (e.attribute_dictionaries rescue nil)
          if ids && ids.to_a.any?
            say.call "  (인스턴스 사전: #{ids.map(&:name).join(', ')})"
          end
        end
        say.call '  Enscape 조명을 찾지 못했습니다.' if found.zero?
        write(lines, out_dir)
      rescue StandardError => e
        puts "실패: #{e.class} — #{e.message}"
        nil
      end

      def definition_of(e)
        return e.definition if e.is_a?(Sketchup::ComponentInstance)
        return e.definition if e.is_a?(Sketchup::Group)
        return e if e.is_a?(Sketchup::ComponentDefinition)
        nil
      rescue StandardError
        nil
      end

      def fmt_scale(e)
        a = (e.transformation.to_a rescue nil)
        return '(없음)' unless a
        format('(%.3f, %.3f, %.3f)',
               Math.sqrt(a[0]**2 + a[1]**2 + a[2]**2),
               Math.sqrt(a[4]**2 + a[5]**2 + a[6]**2),
               Math.sqrt(a[8]**2 + a[9]**2 + a[10]**2))
      rescue StandardError
        '(없음)'
      end

      # 덧붙여 씁니다. 바꾸기 전과 후가 한 파일에 있어야 비교가 됩니다.
      def write(lines, out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'light_read.txt')
        File.open(path, 'a:UTF-8') { |f| lines.each { |l| f.puts l } }
        puts "덧붙임: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

IRIS::LightRead.run
