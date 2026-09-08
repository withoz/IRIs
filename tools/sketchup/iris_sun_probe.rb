# encoding: UTF-8
#
# IRIS — 태양 방향의 부호를 가르는 시험
#
# 무엇을 가르는가
#   `shadow_info['SunDirection']` 이 **태양을 향하는** 방향인지, **빛이
#   나아가는** 방향인지는 문서가 분명하지 않습니다. 틀리면 모든 그림자가
#   정반대로 집니다.
#
#   천문 계산은 시간대·위치 설정이 이상하면 흔들립니다. 대신 흔들리지 않는
#   사실 하나만 씁니다 — **북반구에서 정오의 태양은 남쪽에 있습니다.**
#
#     y < 0, z > 0  ->  태양을 향하는 방향
#     y > 0, z < 0  ->  빛이 나아가는 방향
#
#   (SketchUp 축: +X 동, +Y 북, +Z 위)
#
# 모델은 그대로 둡니다 — start_operation / abort_operation 으로 되돌립니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_sun_probe.rb'

require 'fileutils'

module IRIS
  module SunProbe
    def self.run(out_dir: nil)
      model = Sketchup.active_model
      return puts('[IRIS] 활성 모델이 없습니다.') unless model
      si = model.shadow_info
      log = []
      say = ->(l) { log << l.to_s; puts l }

      say.call "모델: #{model.title}"
      say.call "위치: #{si['City']} (위도 #{si['Latitude']}, 경도 #{si['Longitude']})"
      say.call "현재: #{si['ShadowTime']}  방향 #{fmt(si['SunDirection'])}"
      say.call ''

      # 하루를 훑어 봅니다. 정오 부근에서 y 부호가 답을 줍니다.
      results = []
      model.start_operation('IRIS sun probe', true)
      begin
        [6, 9, 12, 15, 18].each do |h|
          si['ShadowTime'] = Time.new(2022, 6, 20, h, 0, 0)
          v = si['SunDirection'].to_a.map(&:to_f)
          results << [h, v]
        end
      ensure
        model.abort_operation   # 모델을 원래대로 되돌립니다
      end

      say.call '=' * 58
      say.call '  시각    SunDirection (x=동, y=북, z=위)      고도'
      say.call '=' * 58
      results.each do |h, v|
        elev = Math.asin([[v[2], -1.0].max, 1.0].min) * 180.0 / Math::PI
        say.call format('  %02d:00   (%+.3f, %+.3f, %+.3f)   %+6.1f도', h, v[0], v[1], v[2], elev)
      end
      say.call ''

      noon = results.find { |h, _| h == 12 }
      if noon
        y = noon[1][1]
        z = noon[1][2]
        say.call format('정오 판정: y = %+.3f, z = %+.3f', y, z)
        if y < 0 && z > 0
          say.call '  -> **태양을 향하는 방향**입니다 (정오에 남쪽·위).'
          say.call '     지금 IRIS 의 부호가 맞습니다.'
        elsif y > 0 && z < 0
          say.call '  -> **빛이 나아가는 방향**입니다 (정오에 북쪽·아래).'
          say.call '     IRIS 가 부호를 뒤집어야 합니다.'
        else
          say.call '  -> 판정 불가. 위치가 남반구이거나 시간대 설정이 특이합니다.'
          say.call '     하루 표를 보고 손으로 읽으십시오.'
        end
      end

      dir = out_dir ||
            File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
      FileUtils.mkdir_p(dir)
      path = File.join(dir, 'sun_probe.txt')
      File.open(path, 'w:UTF-8') { |f| f.write(log.join("\n")) }
      puts "저장: #{path}"
      { saved: path }
    rescue StandardError => e
      puts "실패: #{e.class} — #{e.message}"
      nil
    end

    def self.fmt(v)
      return '(없음)' unless v
      a = v.to_a.map(&:to_f)
      format('(%+.3f, %+.3f, %+.3f)', a[0], a[1], a[2])
    end
  end
end

IRIS::SunProbe.run
