# encoding: UTF-8
#
# IRIS — 그림자가 화면 어느 쪽으로 뻗어야 하는가
#
# 왜 필요한가
#   "SketchUp 은 3시, IRIS 는 1시" 처럼 두 화면을 눈으로 비교하면, 카메라가
#   조금만 달라도 시계 방향이 달라집니다. 그러면 **좌표계 문제인지 카메라
#   문제인지** 가릴 수 없습니다.
#
#   현재 카메라와 태양으로 **기대되는 시계 방향을 계산**합니다. 그 값과
#   두 화면을 각각 비교하면 어느 쪽이 어긋났는지 바로 나옵니다.
#
#     계산값 == SketchUp != IRIS   -> IRIS 의 태양 방위가 틀렸다
#     계산값 == IRIS != SketchUp   -> 카메라가 다르다 (또는 제 계산이 틀렸다)
#     둘 다 다르다                 -> 카메라가 서로 다르다
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_shadow_clock.rb'
#
# 읽기 전용입니다. out/sketchup/shadow_clock.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module ShadowClock
    def self.run(out_dir: nil)
      model = Sketchup.active_model
      return puts('[IRIS] 활성 모델이 없습니다.') unless model
      si  = model.shadow_info
      cam = model.active_view.camera
      log = []
      say = ->(l) { log << l.to_s; puts l }

      d = si['SunDirection']
      return say.call('SunDirection 이 없습니다.') unless d
      s = norm([d.x.to_f, d.y.to_f, d.z.to_f])
      elev = Math.asin([[s[2], -1.0].max, 1.0].min) * 180.0 / Math::PI
      az   = (Math.atan2(s[0], s[1]) * 180.0 / Math::PI) % 360.0

      say.call "모델: #{model.title}"
      say.call format('태양: 고도 %+.1f도 · 방위 %.1f도 (북=0, 동=90)', elev, az)
      say.call format('      벡터 (%.3f, %.3f, %.3f)  [태양을 향함, Z-up]', *s)
      say.call ''

      # 바닥에 드리우는 그림자의 수평 방향 = 태양 반대쪽
      g = norm([-s[0], -s[1], 0.0])
      say.call format('그림자 수평 방향: (%.3f, %.3f, 0)  방위 %.1f도',
                      g[0], g[1], (Math.atan2(g[0], g[1]) * 180.0 / Math::PI) % 360.0)
      say.call ''

      eye = cam.eye.to_a.map(&:to_f)
      tgt = cam.target.to_a.map(&:to_f)
      f   = norm([tgt[0] - eye[0], tgt[1] - eye[1], tgt[2] - eye[2]])
      wup = [0.0, 0.0, 1.0]
      r   = norm(cross(f, wup))
      u   = cross(r, f)

      sx = dot(g, r)
      sy = dot(g, u)
      # 12시가 위, 시계 방향
      ang   = (Math.atan2(sx, sy) * 180.0 / Math::PI) % 360.0
      hours = ang / 30.0
      hh    = hours.round % 12
      hh    = 12 if hh.zero?

      say.call format('카메라 eye    (%.1f, %.1f, %.1f)', *eye)
      say.call format('       target (%.1f, %.1f, %.1f)', *tgt)
      say.call format('       forward(%.3f, %.3f, %.3f)', *f)
      say.call ''
      say.call '=' * 52
      say.call format('  기대되는 그림자 방향: **%d시** (정확히는 %.1f시, %.1f도)', hh, hours, ang)
      say.call '=' * 52
      say.call ''
      say.call '읽는 법'
      say.call '  이 값을 SketchUp 화면·IRIS 화면과 각각 비교하십시오.'
      say.call '  두 화면의 카메라가 같다면 셋이 모두 같아야 합니다.'
      say.call '  IRIS 만 다르면 태양 방위가 틀린 것이고,'
      say.call '  SketchUp 만 다르면 제 계산이 틀린 것입니다.'

      dir = out_dir ||
            File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
      FileUtils.mkdir_p(dir)
      path = File.join(dir, 'shadow_clock.txt')
      File.open(path, 'w:UTF-8') { |f2| f2.write(log.join("\n")) }
      puts "저장: #{path}"
      { saved: path, hours: hours }
    rescue StandardError => e
      puts "실패: #{e.class} — #{e.message}"
      nil
    end

    def self.norm(v)
      n = Math.sqrt(v.inject(0.0) { |a, c| a + c * c })
      n < 1e-12 ? [0.0, 0.0, 0.0] : v.map { |c| c / n }
    end

    def self.cross(a, b)
      [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    end

    def self.dot(a, b) = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
  end
end

IRIS::ShadowClock.run
