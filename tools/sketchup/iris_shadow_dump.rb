# encoding: UTF-8
#
# IRIS — 그림자 설정 원문 덤프
#
# 왜 필요한가
#   프로브가 `shadow_info['DisplayShadows']` 를 읽는데, 사용자가 그림자를
#   켰는데도 계속 false 로 나옵니다. 키 이름이 다르거나 값의 형이 다를 수
#   있습니다 — 예를 들어 정수 0/1 이면 Ruby 에서 0 은 **참**이므로 판정이
#   뒤집힙니다.
#
#   추측하지 않고 있는 그대로 봅니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_shadow_dump.rb'
#
# 읽기 전용입니다. out/sketchup/shadow_dump.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module ShadowDump
    def self.run(out_dir: nil)
      model = Sketchup.active_model
      return puts('[IRIS] 활성 모델이 없습니다.') unless model
      si = model.shadow_info
      log = []
      say = ->(l) { log << l.to_s; puts l }

      say.call "모델: #{model.title}"
      say.call ''
      say.call '=' * 60
      say.call 'shadow_info 전체 (키 = 값  [형])'
      say.call '=' * 60
      begin
        si.each_pair do |k, v|
          say.call format('  %-24s = %-28s [%s]', k.to_s, v.inspect[0, 28], v.class)
        end
      rescue StandardError => e
        say.call "each_pair 실패: #{e.message}"
        # 알려진 키를 하나씩
        %w[DisplayShadows UseSunForAllShading SunRise SunSet ShadowTime
           ShadowTime_time_t Light Dark City Country Latitude Longitude
           TZOffset DayOfYear SunDirection DisplayOnAllFaces DisplayOnGroundPlane
           EdgesCastShadows].each do |k|
          v = (si[k] rescue '(읽기 실패)')
          say.call format('  %-24s = %-28s [%s]', k, v.inspect[0, 28], v.class)
        end
      end

      say.call ''
      d = (si['SunDirection'] rescue nil)
      if d
        z = d.z.to_f
        elev = Math.asin([[z, -1.0].max, 1.0].min) * 180.0 / Math::PI
        say.call format('태양 고도: %.1f도  %s', elev,
                        elev > 0 ? '(지평선 위 — 햇빛이 있습니다)' : '**(지평선 아래 — 밤입니다. 햇빛이 없습니다)**')
      end

      dir = out_dir ||
            File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
      FileUtils.mkdir_p(dir)
      path = File.join(dir, 'shadow_dump.txt')
      File.open(path, 'w:UTF-8') { |f| f.write(log.join("\n")) }
      puts "저장: #{path}"
      { saved: path }
    rescue StandardError => e
      puts "실패: #{e.class} — #{e.message}"
      nil
    end
  end
end

IRIS::ShadowDump.run
