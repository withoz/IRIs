# encoding: UTF-8
#
# IRIS — 델타 granularity 검증
#
# 목적
#   정의 캐시의 옵저버가 **정확히 편집된 정의만** 무효화하는지 확인한다.
#   하나 고쳤는데 수십 개가 무효화되면 캐시 이득이 무너지고, 반대로 고쳤는데
#   무효화가 안 되면 화면이 낡은 상태로 남는다. 둘 다 치명적이다.
#
#   편집 종류별로 다르게 동작해야 한다.
#     - 인스턴스 이동    -> 무효화 **없음**이 정답. 지오메트리는 그대로이고
#                          변환행렬만 바뀌며, 그건 매 동기화마다 다시 읽는다
#     - 정의 내부 편집   -> 그 정의 **하나만** 무효화되어야 한다
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_probe.rb'
#   IRIS::Probe.run                      # 캐시를 채운다
#   load 'E:/IRIS/tools/sketchup/iris_delta_test.rb'
#   IRIS::DeltaTest.run
#
# 안전성
#   모든 편집은 `model.start_operation` / `commit_operation` 으로 감싸고
#   **즉시 `Sketchup.undo` 로 되돌립니다.** 스크립트가 끝나면 모델은 원래대로입니다.
#   결과는 out/sketchup/delta_test.txt 에도 남깁니다.

require 'fileutils'

module IRIS
  module DeltaTest
    class << self

      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        unless defined?(IRIS::Probe) && IRIS::Probe.respond_to?(:dirty_report)
          return puts('[IRIS] 먼저 iris_probe.rb 를 로드하고 IRIS::Probe.run 을 실행하십시오.')
        end

        @log = []
        say ''
        say "모델: #{model.title}"
        say '(모든 편집은 즉시 되돌립니다)'
        say ''

        baseline = IRIS::Probe.dirty_report
        unless baseline
          return say('캐시가 없습니다. IRIS::Probe.run 을 먼저 실행하십시오.')
        end
        if baseline[:dirty] > 0
          say "! 시작 시점에 이미 #{baseline[:dirty]}개가 무효 상태입니다."
          say '  IRIS::Probe.run 을 다시 돌려 캐시를 재구축한 뒤 시도하십시오.'
          return write_log(out_dir)
        end
        say "기준선: 무효 0 / 전체 #{baseline[:total]}"
        say ''

        test_move_instance(model)
        test_edit_definition(model)

        say ''
        say '읽는 법'
        say '  [1] 인스턴스 이동은 무효화 0 이 정답입니다.'
        say '      변환행렬만 바뀌었고 그건 매 동기화마다 다시 읽습니다.'
        say '  [2] 정의 내부 편집은 그 정의 1개만 무효화되어야 합니다.'
        say '      숫자가 크면 옵저버가 과도하게 전파되는 것이고, 0이면 감지 실패입니다.'

        write_log(out_dir)
      end

      # ---------------------------------------------------------------- 시험

      def test_move_instance(model)
        inst = model.entities.grep(Sketchup::ComponentInstance).first ||
               model.entities.grep(Sketchup::Group).first
        unless inst
          say '[1] 최상위 인스턴스를 찾지 못해 건너뜁니다.'
          return
        end

        say "[1] 인스턴스 이동  (#{describe(inst)})"
        before = dirty_count
        model.start_operation('IRIS delta test: move', true)
        inst.transform!(Geom::Transformation.translation([1.0, 0, 0]))
        model.commit_operation
        after = dirty_count
        Sketchup.undo

        say format('    무효화: %d -> %d  (증가 %d)', before, after, after - before)
        say(after - before == 0 ? '    ✅ 기대대로 — 지오메트리 재추출 불필요' :
                                  "    ⚠ 예상 밖 — #{after - before}개가 무효화됨")
        say ''
      end

      def test_edit_definition(model)
        target = model.definitions.find do |d|
          !d.group? && d.entities.grep(Sketchup::Face).size.between?(1, 200) && d.count_instances > 0
        end
        target ||= model.definitions.find { |d| !d.entities.grep(Sketchup::Face).empty? }
        unless target
          say '[2] 면이 있는 정의를 찾지 못해 건너뜁니다.'
          return
        end

        faces = target.entities.grep(Sketchup::Face)
        say "[2] 정의 내부 편집  (#{target.name}, 면 #{faces.size}개, 인스턴스 #{target.count_instances}개)"
        before = dirty_count
        model.start_operation('IRIS delta test: edit', true)
        # 눈에 띄지 않을 만큼만 움직인다 (0.001 인치). 어차피 되돌린다.
        target.entities.transform_entities(
          Geom::Transformation.translation([0, 0, 0.001]), [faces.first]
        )
        model.commit_operation
        after = dirty_count
        Sketchup.undo

        delta = after - before
        say format('    무효화: %d -> %d  (증가 %d)', before, after, delta)
        if delta == 1
          say '    ✅ 정확히 1개 — 옵저버 granularity 정상'
        elsif delta.zero?
          say '    ⚠ 감지 실패 — 화면이 낡은 상태로 남는다는 뜻'
        else
          say "    ⚠ #{delta}개가 무효화됨 — 과도 전파. 캐시 이득이 줄어든다"
        end

        rpt = IRIS::Probe.dirty_report
        say format('    재추출 예상: %s 삼각형 / %.1f ms', rpt[:tris], rpt[:est_ms]) if rpt
        say ''
      end

      # ---------------------------------------------------------------- 보조

      def dirty_count
        IRIS::Probe.instance_variable_get(:@def_cache)&.dirty_entries&.size || 0
      end

      def describe(e)
        n = (e.name rescue '')
        n = e.is_a?(Sketchup::Group) ? '그룹' : (e.definition.name rescue '컴포넌트') if n.to_s.empty?
        n
      end

      def say(line)
        @log ||= []
        @log << line
        puts line
      end

      def write_log(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'delta_test.txt')
        File.open(path, 'w:UTF-8') { |f| f.write(@log.join("\n")) }
        puts ''
        puts "결과 저장: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "결과 저장 실패: #{e.message}"
        nil
      end
    end
  end
end

puts '[IRIS] 델타 검증 로드 완료. IRIS::DeltaTest.run 을 실행하세요.'
puts '       (편집은 모두 즉시 되돌립니다)'
