# encoding: UTF-8
#
# IRIS — 조명 프록시 축 실측
#
# 왜 필요한가
#   Enscape 조명은 컴포넌트 인스턴스이고, 위치와 방향은 그 인스턴스의
#   변환에서 나옵니다. 그런데 "정면"이 로컬 어느 축인지는 문서에 없습니다.
#   Donut/glTF 는 로컬 -Z 를 정면으로 봅니다(SceneTypes.cpp: -row2).
#
#   추측하면 조명이 엉뚱한 곳을 비춥니다. 그래서 실측합니다:
#   천장 다운라이트는 **아래(월드 -Z)** 를 향해야 합니다. 각 로컬 축이
#   월드에서 어디를 가리키는지 세어 보면 어느 축이 정면인지 드러납니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_lights_axis.rb'
#   IRIS::LightsAxis.run
#
# 읽기 전용입니다.

require 'fileutils'

module IRIS
  module LightsAxis
    AXES = {
      '+X' => [1, 0, 0], '-X' => [-1, 0, 0],
      '+Y' => [0, 1, 0], '-Y' => [0, -1, 0],
      '+Z' => [0, 0, 1], '-Z' => [0, 0, -1],
    }.freeze

    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say ''

        defs = model.definitions.select { |d| light_dict(d) }
        if defs.empty?
          say '(Enscape.Light 정의가 없습니다)'
          return write_log(out_dir)
        end

        defs.each do |d|
          rows = []
          walk(model.entities, Geom::Transformation.new, d, rows)
          next if rows.empty?

          say '=' * 66
          say "#{d.name}  — 인스턴스 #{rows.size}개  (타입: #{xsi_type(d)})"
          say '=' * 66

          # 각 로컬 축이 월드에서 평균적으로 어디를 향하는가
          AXES.each do |label, v|
            dirs = rows.map { |r| world_dir(r[:tr], v) }
            avg  = mean(dirs)
            down = dirs.count { |dd| dd[2] < -0.85 }
            up   = dirs.count { |dd| dd[2] > 0.85 }
            say format('  로컬 %-2s -> 월드 평균 (%6.3f %6.3f %6.3f)   아래향 %2d  위향 %2d',
                       label, avg[0], avg[1], avg[2], down, up)
          end

          zs = rows.map { |r| r[:pos][2] }
          say format('  높이(mm): 최소 %.0f  중앙 %.0f  최대 %.0f',
                     mm(zs.min), mm(zs.sort[zs.size / 2]), mm(zs.max))
          say format('  스케일  : %s', rows.first[:scale].map { |s| format('%.4f', s) }.join(' '))
          say ''
          rows.first(3).each_with_index do |r, i|
            say format('  [%d] 위치(mm) %8.0f %8.0f %8.0f   경로 %s',
                       i, mm(r[:pos][0]), mm(r[:pos][1]), mm(r[:pos][2]), r[:path])
          end
          say ''
        end

        say '읽는 법'
        say '  천장 다운라이트라면 "아래향"이 인스턴스 수와 같은 축이 정면입니다.'
        say '  Donut 은 로컬 -Z 를 정면으로 씁니다 — 그 줄이 아래를 향하면 변환이 없어도 맞습니다.'
        write_log(out_dir)
      end

      def light_dict(d)
        d.attribute_dictionary('Enscape.Light')
      rescue StandardError
        nil
      end

      def xsi_type(d)
        dict = light_dict(d)
        return '?' unless dict
        xml = dict['LightData'].to_s
        m = xml[/xsi:type="([A-Za-z]+)"/, 1]
        m || '?'
      end

      # 모델 전체를 훑어 이 정의의 인스턴스를 모두 찾고 누적 변환을 구한다.
      def walk(entities, acc, target, out, path = '', depth = 0)
        return if depth > 24
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          defn = e.respond_to?(:definition) ? e.definition : nil
          next unless defn
          tr = acc * e.transformation
          if defn == target
            out << { tr: tr, pos: tr.origin.to_a, scale: scale_of(tr),
                     path: "#{path}/#{e.name.to_s.empty? ? defn.name : e.name}" }
          else
            walk(defn.entities, tr, target, out,
                 "#{path}/#{e.name.to_s.empty? ? defn.name : e.name}", depth + 1)
          end
        end
      end

      # 로컬 벡터가 월드에서 향하는 단위 방향
      def world_dir(tr, v)
        d = tr * Geom::Vector3d.new(v[0], v[1], v[2]) - tr * Geom::Point3d.new(0, 0, 0)
        d = Geom::Vector3d.new(d.to_a) if d.is_a?(Geom::Point3d)
        len = Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        return [0.0, 0.0, 0.0] if len < 1e-12
        [d.x / len, d.y / len, d.z / len]
      end

      def scale_of(tr)
        a = tr.to_a
        [Math.sqrt(a[0]**2 + a[1]**2 + a[2]**2),
         Math.sqrt(a[4]**2 + a[5]**2 + a[6]**2),
         Math.sqrt(a[8]**2 + a[9]**2 + a[10]**2)]
      end

      def mean(list)
        n = list.size.to_f
        return [0.0, 0.0, 0.0] if n.zero?
        [list.sum { |v| v[0] } / n, list.sum { |v| v[1] } / n, list.sum { |v| v[2] } / n]
      end

      def mm(inches) = inches * 25.4

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def write_log(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'lights_axis.txt')
        File.open(path, 'w:UTF-8') { |f| f.write(@log.join("\n")) }
        puts "저장: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

puts '[IRIS] 조명 축 실측 로드 완료. IRIS::LightsAxis.run 을 실행하세요.'
