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
#   깊이 중첩된 프록시를 클릭으로 찾는 것은 번거롭습니다. **선택이 필요
#   없게** 해 두었습니다 — Enscape 로 새 광원을 놓으면 그것이 가장 최근
#   정의가 되므로 이름 없이 집어낼 수 있습니다.
#
#   1) Enscape 툴바에서 **사각 광원을 새로 하나** 놓습니다 (기본값 그대로)
#   2) load 'E:/IRIS/tools/sketchup/iris_light_read.rb'          <- 기본값 기록
#   3) Enscape 조명 설정에서 밝기를 **1000** 으로 바꿉니다
#   4) IRIS::LightRead.latest                                    <- 바뀐 값 기록
#   5) 밝기를 **2000** 으로 바꾸고  IRIS::LightRead.latest        <- 셋째 점
#
#   다른 방법
#     IRIS::LightRead.run              선택한 것을 읽습니다
#     IRIS::LightRead.latest           가장 최근에 생긴 Enscape 조명
#     IRIS::LightRead.dump('이름')     이름으로 (부분 일치)
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
      # 가장 최근에 생긴 Enscape 조명 정의.
      #
      # entityID 는 증가하므로 마지막에 놓은 것이 가장 큽니다. 새로 놓은
      # 광원을 이름 없이, 선택 없이 집어냅니다.
      def latest(out_dir: nil, note: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        # **셋을 냅니다.** 밝기를 바꾸면 Enscape 가 정의를 새로 만들 수
        # 있습니다 — LightData 가 정의에 붙어 있으니 값이 다르면 정의가
        # 갈라져야 합니다. 하나만 보면 어느 쪽을 보는지 알 수 없습니다.
        ds = model.definitions.select { |x| x.attribute_dictionary(DICT) rescue nil }
                  .sort_by { |x| -x.entityID }.first(3)
        return puts('[IRIS] Enscape 조명 정의가 없습니다.') if ds.empty?
        emit(ds, out_dir, note || '가장 최근 정의 3개 (id 큰 순)')
      end

      # 이름으로. 부분 일치이고 여러 개면 전부 뜹니다.
      def dump(name, out_dir: nil, note: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        re = Regexp.new(Regexp.escape(name.to_s), Regexp::IGNORECASE)
        ds = model.definitions.select do |x|
          (x.attribute_dictionary(DICT) rescue nil) && re.match?(x.name.to_s)
        end
        return puts("[IRIS] '#{name}' 에 맞는 Enscape 조명이 없습니다.") if ds.empty?
        emit(ds.first(5), out_dir, note || "이름 '#{name}'")
      end

      def emit(defs, out_dir, note)
        lines = []
        say = ->(l) { lines << l.to_s; puts l }
        say.call ''
        say.call '=' * 72
        say.call "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}   #{note}"
        say.call '=' * 72
        defs.each { |d| report_def(d, nil, say) }
        write(lines, out_dir)
      end

      def report_def(d, inst, say)
        dict = (d.attribute_dictionary(DICT) rescue nil)
        unless dict
          say.call "  '#{d.name}' — Enscape.Light 사전이 없습니다"
          return
        end
        say.call "  정의: #{d.name}   인스턴스 #{(d.instances.length rescue 0)}개   id #{d.entityID}"
        say.call "  변환 배율: #{fmt_scale(inst)}" if inst
        dict.each_pair do |k, v|
          s = v.to_s.gsub(%r{<IesData>.*?</IesData>}m, '<IesData>...생략...</IesData>')
          say.call "  [#{k}]"
          s.each_line { |ln| say.call "    #{ln.rstrip}" }
        end
        return unless inst
        ids = (inst.attribute_dictionaries rescue nil)
        say.call "  (인스턴스 사전: #{ids.map(&:name).join(', ')})" if ids && ids.to_a.any?
      end

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
          say.call '아무것도 선택되지 않았습니다 — 가장 최근 정의로 대신합니다.'
          write(lines, out_dir)
          return latest(out_dir: out_dir, note: note)
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
          report_def(d, e, say)
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
