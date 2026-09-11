# encoding: UTF-8
#
# IRIS — 월워셔가 씻는 벽을 화면에 잡습니다
#
# 왜
#   IES 0도 방위가 맞는지 **그림으로** 견주려는 참입니다. Enscape 와 IRIS
#   로 같은 뷰를 렌더해 벽의 무늬를 봅니다.
#
#   그러려면 두 렌더러가 **정확히 같은 카메라**를 봐야 합니다. 손으로 맞출
#   수 없으니 계산해서 넣습니다. 벽은 월워셔 배치선이 알려 줍니다:
#
#     배치선  = 벽의 방향
#     기운 쪽 = 벽이 있는 쪽
#
#   카메라는 배치선 가운데에서 벽 반대쪽으로 물러나, 벽을 정면으로 봅니다.
#
# 무엇을 보게 되는가
#   맞으면  — 벽에 **가로로 긴 띠**가 이어집니다 (넓은 축 29.8도가 벽을 따라감)
#   틀리면  — **세로로 긴 가리비**가 1.95 m 간격으로 끊깁니다 (좁은 축 18도)
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_ies_view.rb'
#   IRIS::IesView.aim                      # 기본: SpotLight#1
#   IRIS::IesView.aim(name: '...', back: 300, up: 0.4)
#
# 카메라만 바꿉니다. 지오메트리는 건드리지 않습니다.

require 'fileutils'

module IRIS
  module IesView
    class << self
      # back — 벽에서 물러나는 거리(인치). nil 이면 배치 길이로 정합니다.
      # up   — 눈높이를 벽 높이의 몇 배로 둘지.
      def aim(name: 'Enscape.SpotLight#1', back: nil, up: 0.45, out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        @rows = []
        walk(model.entities, Geom::Transformation.new, 0)
        rows = @rows.select { |r| r[:def] == name }
        if rows.size < 2
          say "#{name} 배치를 2개 이상 찾지 못했습니다 (찾은 것 #{rows.size}개)."
          say "있는 것: #{@rows.map { |r| r[:def] }.uniq.inspect}"
          return finish(out_dir)
        end

        say format('%s 배치 %d개', name, rows.size)

        pts = rows.map { |r| r[:pos] }
        cx  = pts.sum { |p| p.x.to_f } / pts.size
        cy  = pts.sum { |p| p.y.to_f } / pts.size
        cz  = pts.sum { |p| p.z.to_f } / pts.size

        dir = line_dir(pts)
        return finish(out_dir) if dir.nil?
        span = pts.map { |p| (p.x - cx) * dir.x + (p.y - cy) * dir.y }.minmax
        length = (span[1] - span[0]).abs
        say format('    배치선 (%.3f %.3f 0)  길이 %.0f 인치 (%.1f m)',
                   dir.x, dir.y, length, length * 0.0254)

        # 벽이 있는 쪽 = 방출 축의 수평 성분.
        aim = rows.first[:aim]
        toward = Geom::Vector3d.new(aim.x, aim.y, 0)
        if toward.length < 1e-6
          say '    기울지 않은 다운라이트입니다 — 벽 방향을 못 읽습니다.'
          say '    기운 배치(#1)로 다시 부르십시오.'
          return finish(out_dir)
        end
        toward.normalize!
        say format('    벽은 (%.3f %.3f 0) 쪽', toward.x, toward.y)

        # 카메라: 배치선 가운데에서 벽 **반대쪽**으로 물러나 벽을 봅니다.
        d = (back || [length * 0.75, 200.0].max).to_f
        eye = Geom::Point3d.new(cx - toward.x * d, cy - toward.y * d, cz * up)
        tgt = Geom::Point3d.new(cx + toward.x * d * 0.6,
                                cy + toward.y * d * 0.6, cz * up * 0.75)
        model.active_view.camera = Sketchup::Camera.new(eye, tgt, [0, 0, 1])
        say ''
        say format('    카메라 눈 (%.0f %.0f %.0f)  대상 (%.0f %.0f %.0f)',
                   eye.x, eye.y, eye.z, tgt.x, tgt.y, tgt.z)
        say format('    물러난 거리 %.0f 인치 (%.1f m) · 눈높이 %.0f 인치',
                   d, d * 0.0254, eye.z)
        say ''
        say '    무엇을 볼 것인가'
        say '      맞으면 — 벽에 **가로로 긴 띠**가 이어집니다 (넓은 축이 벽을 따라감)'
        say '      틀리면 — **세로로 긴 가리비**가 끊겨 보입니다 (좁은 축이 벽을 따라감)'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def line_dir(pts)
        n = pts.size.to_f
        cx = pts.sum { |p| p.x.to_f } / n
        cy = pts.sum { |p| p.y.to_f } / n
        sxx = syy = sxy = 0.0
        pts.each do |p|
          dx = p.x.to_f - cx
          dy = p.y.to_f - cy
          sxx += dx * dx
          syy += dy * dy
          sxy += dx * dy
        end
        tr = sxx + syy
        return nil if tr < 1e-9
        det = sxx * syy - sxy * sxy
        disc = Math.sqrt([tr * tr / 4.0 - det, 0.0].max)
        l1 = tr / 2.0 + disc
        v = if sxy.abs > 1e-9
              Geom::Vector3d.new(l1 - syy, sxy, 0)
            else
              sxx >= syy ? Geom::Vector3d.new(1, 0, 0) : Geom::Vector3d.new(0, 1, 0)
            end
        return nil if v.length < 1e-9
        v.normalize!
        v
      end

      def walk(entities, tr, depth)
        return if depth > 14
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          d = (e.definition rescue nil)
          next unless d
          t = tr * e.transformation
          if ies?(d)
            @rows << { def: d.name.to_s, pos: t.origin, aim: t.zaxis.normalize }
            next
          end
          walk(d.entities, t, depth + 1)
        end
      end

      def ies?(defn)
        dict = (defn.attribute_dictionary('Enscape.Light') rescue nil)
        return false unless dict
        dict['LightData'].to_s.include?('SketchupIesLight')
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
        path = File.join(dir, 'ies_view.txt')
        File.open(path, 'w:UTF-8') { |f| @log.each { |l| f.puts l } }
        puts "저장: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

puts '[IRIS] IesView 로드 완료 — IRIS::IesView.aim 으로 카메라를 맞춥니다.'
