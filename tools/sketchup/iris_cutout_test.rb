# encoding: UTF-8
#
# IRIS — 알파 컷아웃이 화면에 나오나 (통제 시험)
#
# 왜
#   텍스처의 알파 채널로 구멍을 내는 길(11번 (a))을 붙였습니다. 프로브가
#   재는 것도, 리더가 읽는 것도 시험으로 확인했습니다. 남은 것은 **화면**
#   입니다 — 엔진이 실제로 구멍을 뚫는가.
#
#   그런데 세종 모델에서 구멍 있는 텍스처를 가진 재질(`Perforated Panel2`,
#   617x490, 픽셀의 32.5%가 알파 128 미만)은 **어느 면에도 안 칠해져**
#   있습니다. 볼 수가 없습니다.
#
#   그래서 **지금 보고 있는 면**에 잠깐 칠합니다. 화면 한가운데로 광선을
#   쏴서 맞는 면을 고르므로, 카메라를 옮기지 않아도 반드시 보입니다.
#
#   되돌릴 수 있습니다 — 원래 재질을 기억해 두고 revert 로 되돌립니다
#   (되돌리기 한 번으로도 됩니다).
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_cutout_test.rb'   # 칠합니다
#   IRIS::CutoutTest.revert                             # 되돌립니다
#
# 칠한 뒤에는 IRIS::Link.sync(force: true) 로 보내야 화면이 바뀝니다.

require 'fileutils'

module IRIS
  module CutoutTest
    class << self
      # 구멍이 있는 텍스처를 가진 재질. 없으면 고르지 않습니다.
      TARGET = 'Perforated Panel2'

      def run(name: TARGET)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        mat = model.materials.find { |m| m.display_name.to_s == name }
        return puts("[IRIS] 재질 '#{name}' 이 없습니다.") unless mat

        face, path = pick_face(model)
        return puts('[IRIS] 화면 한가운데에 면이 없습니다. 시점을 옮겨 보십시오.') unless face

        model.start_operation('IRIS: 컷아웃 시험', true)
        @undo = { face: face,
                  front: (face.material rescue nil),
                  back:  (face.back_material rescue nil) }
        # 앞뒷면 모두 칠합니다 — 어느 쪽을 보고 있는지 모릅니다.
        face.material      = mat
        face.back_material = mat
        model.commit_operation

        area = (face.area * 0.00064516 rescue 0.0)
        puts "[IRIS] '#{name}' 을 화면 한가운데 면에 칠했습니다."
        puts format('       면 넓이 %.2f m2 · 경로 깊이 %d', area, (path || []).length)
        puts '       IRIS::Link.sync(force: true) 로 보내고 화면을 보십시오.'
        puts '       IRIS::CutoutTest.revert 로 되돌립니다.'
        @undo
      rescue StandardError => e
        puts "[IRIS] 실패: #{e.class}: #{e.message}"
        nil
      end

      def revert
        model = Sketchup.active_model
        return puts('[IRIS] 되돌릴 것이 없습니다.') unless model && @undo
        f = @undo[:face]
        return puts('[IRIS] 면이 사라졌습니다.') unless f && f.valid?
        model.start_operation('IRIS: 컷아웃 시험 되돌리기', true)
        f.material      = @undo[:front]
        f.back_material = @undo[:back]
        model.commit_operation
        puts '[IRIS] 되돌렸습니다. IRIS::Link.sync(force: true) 로 다시 보내십시오.'
        @undo = nil
      end

      # 화면 한가운데로 광선을 쏴서 맞는 면.
      #
      # `Model#raytest` 는 [점, 경로] 를 줍니다. 경로의 끝이 면입니다.
      # 컴포넌트 안이면 그 정의를 쓰는 인스턴스 전부가 같이 바뀝니다 —
      # 임시 시험이고 revert 로 돌리므로 그대로 씁니다.
      def pick_face(model)
        view = model.active_view
        cam  = view.camera
        hit  = model.raytest([cam.eye, cam.direction])
        return [nil, nil] unless hit
        path = hit[1]
        face = (path || []).reverse.find { |e| e.is_a?(Sketchup::Face) }
        [face, path]
      rescue StandardError
        [nil, nil]
      end
    end
  end
end

IRIS::CutoutTest.run
