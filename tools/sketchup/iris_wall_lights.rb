# encoding: UTF-8
#
# IRIS — Enscape 의 **벽면 조명**을 찾습니다
#
# 왜
#   골프존 모델 화면에는 천장 코브를 따라 빛 띠가 있고 벽에도 조명이
#   있어 보입니다. 그런데 그것이 무엇으로 만들어졌는지 우리는 모릅니다.
#   셋 중 하나입니다.
#
#     1. Enscape 광원 객체      — 우리가 광원으로 변환합니다
#     2. 자체발광 재질          — 우리가 발광 지오메트리로 냅니다
#     3. Enscape 자산(조명 기구) — **껍데기만 옵니다.** 진짜 모델도 빛도
#                                 Enscape 라이브러리 안에 있어서 우리에게는
#                                 아무것도 오지 않습니다(11번 11.7)
#
#   3번이면 우리 화면에서 그 조명은 **그냥 없습니다.** 오류도 안 납니다.
#   그래서 세어 봐야 합니다.
#
# 무엇을 보는가
#   * Enscape 광원 정의를 종류별로 셉니다 (Sphere/Spot/Rect/Line/Disk/IES)
#   * 각 인스턴스의 **자세**를 봅니다 — 광원 정면이 수평에 가까우면
#     벽에 붙은 것으로 봅니다(벽등·월워셔). 아래를 보면 천장등입니다.
#   * 자체발광 재질이 쓰인 면의 **법선**도 같은 기준으로 가릅니다.
#   * Enscape 자산 중 이름에 조명 낱말이 든 것을 따로 셉니다 —
#     이것이 "화면에 없는 조명" 후보입니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_wall_lights.rb'
#
# 읽기 전용입니다. out/sketchup/wall_lights.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module WallLights
    class << self
      MAX_DEPTH = 12

      # 광원 정면(로컬 +Z)이 수평에서 이 각도 안이면 '벽면'으로 봅니다.
      WALL_CONE_DEG = 40.0

      LIGHT_WORDS = /light|lamp|sconce|pendant|luminaire|fixture|led|spot|
                     조명|등기구|벽등|펜던트|다운라이트/xi

      # **지금 화면에 무엇이 있는가.**
      #
      # `view.screen_coords` 는 3D 점을 화면 좌표로 옮겨 줍니다. 뷰포트
      # 사각형 안이고 **카메라 앞쪽**이면 보이는 자리입니다.
      #
      # ⚠ 가려짐(occlusion)은 보지 않습니다. 벽 뒤에 있어도 '화면 안'으로
      #   셉니다 — 그것까지 하려면 광선을 쏴야 하고, 여기서는 과합니다.
      def on_screen(view, pt)
        eye  = view.camera.eye
        dirv = view.camera.direction
        v = pt - eye
        return nil if v.dot(dirv) <= 0.0          # 뒤쪽
        sc = view.screen_coords(pt)
        return nil if sc.x < 0 || sc.y < 0
        return nil if sc.x > view.vpwidth || sc.y > view.vpheight
        [sc.x.to_i, sc.y.to_i]
      end

      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Enscape)
          f = File.join(File.dirname(__FILE__), 'iris_enscape.rb')
          load f if File.exist?(f)
        end

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        @lights   = []   # Enscape 광원 인스턴스
        @assets   = Hash.new(0)   # Enscape 자산 이름 -> 인스턴스 수
        @emissive = []   # 자체발광 재질이 붙은 면
        @emat     = {}   # 재질 id -> pbr

        model.materials.each do |m|
          pbr = (IRIS::Enscape.material(m) rescue nil)
          next unless pbr
          @emat[m.entityID] = pbr if pbr['emissive_cd'].to_f > 0.0
        end

        t0 = Time.now
        walk(model.entities, Geom::Transformation.new, 0)
        say format('트리 순회 %.1f ms', (Time.now - t0) * 1000.0)
        say ''

        report_view
        report_lights
        report_emissive
        report_assets

        say ''
        say '  읽는 법'
        say '    [3] 이 두꺼우면 그 조명은 **우리 화면에 아예 없습니다.**'
        say '        Enscape 자산은 껍데기만 오고 빛은 라이브러리 안에 있습니다.'
        say '    [1]·[2] 에 있으면 우리가 이미 내고 있습니다 — 화면에서'
        say '        안 보이면 세기나 방향 쪽 문제입니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      # ------------------------------------------------------------ 보고

      # [0] 지금 화면에 잡히는 조명만. 사용자가 보고 있는 것이 기준입니다.
      def report_view
        view = Sketchup.active_model.active_view
        cam  = view.camera
        say '=' * 92
        say '[0] **지금 화면에 있는 조명**'
        say '=' * 92
        say format('    뷰포트 %dx%d · 눈 (%.2f %.2f %.2f) m · 화각 %.1f도',
                   view.vpwidth, view.vpheight,
                   cam.eye.x.to_f * 0.0254, cam.eye.y.to_f * 0.0254, cam.eye.z.to_f * 0.0254,
                   cam.fov.to_f)
        say ''

        vl = @lights.select { |l| l[:screen] }
        ve = @emissive.select { |e| e[:screen] }

        if vl.empty? && ve.empty?
          say '    화면 안에 광원도 발광면도 없습니다.'
          say '    (가려짐은 보지 않습니다 — 벽 뒤에 있어도 화면 안으로 셉니다)'
          return
        end

        unless vl.empty?
          say "    Enscape 광원 #{vl.size}개:"
          vl.sort_by { |l| -l[:lm] }.each do |l|
            say format('      %-10s %-20s %8.0f lm  높이 %5.2f m  화면 (%4d,%4d)%s',
                       l[:kind], clip(l[:name], 20), l[:lm], l[:z],
                       l[:screen][0], l[:screen][1], l[:wall] ? '  [벽면]' : '')
          end
        end

        unless ve.empty?
          say '' unless vl.empty?
          by_mat = Hash.new { |h, k| h[k] = [] }
          ve.each { |e| by_mat[e[:mat]] << e }
          say "    자체발광 재질 #{by_mat.size}종 (#{ve.size}면):"
          by_mat.sort_by { |_, v| -v.sum { |e| e[:area] } }.each do |name, list|
            wall = list.count { |e| e[:wall] }
            xs = list.map { |e| e[:screen][0] }
            ys = list.map { |e| e[:screen][1] }
            say format('      %-24s %5d면  %7.3f m²  %6.0f cd/m²  벽면 %d  화면 x %d~%d y %d~%d',
                       clip(name, 24), list.size, list.sum { |e| e[:area] },
                       list.first[:cd], wall, xs.min, xs.max, ys.min, ys.max)
          end
        end
        say ''
      end

      def report_lights
        say '=' * 92
        say "[1] Enscape 광원 객체 — #{@lights.size}개"
        say '=' * 92
        if @lights.empty?
          say '    없습니다.'
          return
        end
        by_kind = Hash.new { |h, k| h[k] = [] }
        @lights.each { |l| by_kind[l[:kind]] << l }
        by_kind.sort_by { |k, v| -v.size }.each do |kind, list|
          wall = list.count { |l| l[:wall] }
          say format('    %-12s %4d개   그중 벽면 자세 %d개', kind, list.size, wall)
        end
        say ''
        walls = @lights.select { |l| l[:wall] }
        if walls.empty?
          say '    **벽면 자세인 광원이 없습니다.**'
        else
          say "    벽면으로 본 것 (정면이 수평 #{WALL_CONE_DEG.to_i}도 안):"
          walls.sort_by { |l| -l[:lm] }.first(20).each do |l|
            say format('      %-22s %8.0f lm  높이 %6.2f m  정면 %s',
                       clip(l[:name], 22), l[:lm], l[:z], vec(l[:dir]))
          end
        end
      end

      def report_emissive
        say ''
        say '=' * 92
        say "[2] 자체발광 재질이 붙은 면 — #{@emissive.size}곳"
        say '=' * 92
        if @emissive.empty?
          say '    없습니다.'
          return
        end
        by_mat = Hash.new { |h, k| h[k] = [] }
        @emissive.each { |e| by_mat[e[:mat]] << e }
        by_mat.sort_by { |k, v| -v.size }.each do |name, list|
          wall = list.count { |e| e[:wall] }
          area = list.sum { |e| e[:area] }
          say format('    %-26s %5d면  %7.2f m²  그중 벽면 %d면  %6.0f cd/m²',
                     clip(name, 26), list.size, area, wall, list.first[:cd])
        end
      end

      def report_assets
        say ''
        say '=' * 92
        say '[3] Enscape 자산 중 조명으로 보이는 것 — **우리에게는 빛이 오지 않습니다**'
        say '=' * 92
        remote = @assets.select { |k, _| k.end_with?('[REMOTE]') }
        say format('    Enscape 자산 전체 %d종 · 그중 REMOTE %d종', @assets.size, remote.size)
        say ''
        hit = @assets.select { |name, _| name =~ LIGHT_WORDS }
        if hit.empty?
          say '    이름에 조명 낱말이 든 자산은 없습니다.'
        else
          say '    이름에 조명 낱말이 든 자산:'
          hit.sort_by { |_, n| -n }.each do |name, n|
            say format('      %-52s 인스턴스 %d개', clip(name, 52), n)
          end
        end
        return if remote.empty?
        say ''
        say '    REMOTE 자산 전체 (껍데기만 옵니다):'
        remote.sort_by { |_, n| -n }.first(20).each do |name, n|
          say format('      %-52s 인스턴스 %d개', clip(name, 52), n)
        end
      end

      # ------------------------------------------------------------ 순회

      def walk(entities, tr, depth)
        return if depth > MAX_DEPTH
        entities.each do |e|
          case e
          when Sketchup::Face
            scan_face(e, tr)
          when Sketchup::ComponentInstance, Sketchup::Group
            d = (e.definition rescue nil)
            next unless d
            here = tr * e.transformation

            if (asset = (IRIS::Enscape.asset(d) rescue nil))
              # **REMOTE 가 핵심입니다.** Source 가 REMOTE 면 지오메트리도
              # 빛도 Enscape 라이브러리 안에 있고, .skp 에는 껍데기만
              # 있습니다 — 우리에게는 아무것도 오지 않습니다(11번 11.7).
              key = format('%s  [%s]', d.name.to_s, asset['source'].to_s)
              @assets[key] += 1
            end

            if (li = (IRIS::Enscape.light(d) rescue nil))
              record_light(e, d, li, here)
              next   # 광원 프록시 안은 볼 것이 없습니다
            end

            walk(d.entities, here, depth + 1)
          end
        end
      end

      # 광원 정면은 프록시의 로컬 +Z 입니다 (10번 10.1 — 실측).
      def record_light(inst, defn, li, tr)
        dir = tr.zaxis
        dir = [dir.x, dir.y, dir.z]
        len = Math.sqrt(dir[0]**2 + dir[1]**2 + dir[2]**2)
        dir = dir.map { |v| v / len } if len > 1e-9
        # 수평에서 얼마나 벗어났나. |z| 가 작을수록 수평 = 벽면.
        tilt_deg = Math.asin([[dir[2].abs, 1.0].min, 0.0].max) * 180.0 / Math::PI
        @lights << {
          screen: on_screen(Sketchup.active_model.active_view, tr.origin),
          kind: (li['kind'] || 'UNKNOWN').to_s,
          name: (defn.name.to_s.empty? ? inst.entityID.to_s : defn.name.to_s),
          lm:   li['lumens'].to_f,
          z:    tr.origin.z.to_f * 0.0254,
          dir:  dir,
          wall: tilt_deg <= WALL_CONE_DEG,
        }
      end

      def scan_face(face, tr)
        [face.material, face.back_material].compact.each do |m|
          pbr = @emat[m.entityID]
          next unless pbr
          n = face.normal.transform(tr)
          len = n.length.to_f
          next if len < 1e-9
          nz = (n.z / len).abs
          tilt_deg = Math.asin([[nz, 1.0].min, 0.0].max) * 180.0 / Math::PI
          @emissive << {
            screen: on_screen(Sketchup.active_model.active_view, face.bounds.center.transform(tr)),
            mat:  m.display_name.to_s,
            area: face.area(tr) * 0.00064516,   # in² -> m²
            cd:   pbr['emissive_cd'].to_f,
            wall: tilt_deg <= WALL_CONE_DEG,
          }
        end
      end

      # ------------------------------------------------------------ 공통

      def vec(d) = format('(%.2f %.2f %.2f)', d[0], d[1], d[2])
      def clip(t, n) = t.to_s[0, n]

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def finish(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'wall_lights.txt')
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

IRIS::WallLights.run
