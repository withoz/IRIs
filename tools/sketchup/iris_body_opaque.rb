# encoding: UTF-8
#
# IRIS — 반투명 재질을 꼭 집어 보고, 골라서 불투명으로
#
# 왜
#   세종 모델의 반투명 재질은 커튼월 하나를 빼면 전부 반입한 자동차
#   (RENAULT KIGER) 두 대 안에 있습니다. 그중 램프 렌즈·차창은 진짜
#   유리이므로 그대로 두어야 하고, **차체**만 불투명이어야 합니다.
#
#   이름으로는 못 고릅니다(`L16 색`은 마감 코드처럼 생겼습니다). 무엇에
#   붙었는지 보고 고릅니다.
#
# 앞선 도구(iris_finish_probe.rb)의 넓이는 믿지 마십시오
#   거기서는 넓이를 `face.area * (tr.xaxis.length * tr.yaxis.length)` 로
#   근사했습니다. SketchUp 의 Transformation 은 **균일 배율을 15번째
#   원소에 숨겨** 두므로 xaxis.length 가 1 로 나옵니다. 반입 컴포넌트는
#   거의 항상 그 배율을 씁니다 — 즉 그 숫자는 배율을 통째로 놓쳤습니다.
#   여기서는 SketchUp 이 주는 `face.area(tr)` 를 씁니다. 둘 다 찍어서
#   얼마나 어긋났는지 보입니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_body_opaque.rb'
#   IRIS::BodyOpaque.report                 # 읽기 전용. 무엇에 붙었나
#   IRIS::BodyOpaque.look 3                 # 3번 재질 쪽으로 카메라 (되돌릴 수 있음)
#   IRIS::BodyOpaque.restore                # 카메라 복구
#   IRIS::BodyOpaque.apply_from_file        # 알파 1.0 (되돌리기 한 번)
#   IRIS::BodyOpaque.revert                 # 방금 바꾼 것을 값으로 되돌립니다

require 'fileutils'

module IRIS
  module BodyOpaque
    class << self
      MAX_DEPTH = 12

      # ---------------------------------------------------------------- 조사

      def report(out_dir: nil, max_mats: 14)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        gather(model)
        @rows = @stat.values.select { |s| s[:faces] > 0 }.sort_by { |s| -s[:area] }

        say '=' * 92
        say '[1] 넓이 — 정확한 값과, 앞선 도구가 쓰던 근사'
        say '=' * 92
        say format('    %2s %-24s %6s %7s %10s %10s %7s',
                   '#', '이름', '알파', '면', '넓이 m2', '(옛 근사)', '배율')
        rows.first(max_mats).each_with_index do |s, i|
          ratio = s[:area_old] > 1e-9 ? (s[:area] / s[:area_old]) : 0.0
          say format('    %2d %-24s %6.3f %7d %10.2f %10.2f %6.1fx',
                     i + 1, clip(s[:name], 24), s[:alpha], s[:faces], s[:area], s[:area_old], ratio)
        end
        say ''

        say '=' * 92
        say '[2] 면이 어디를 보나 (월드 기준) — 차체라면 위·아래를 보는 면이 있어야 합니다'
        say '=' * 92
        say format('    %-24s %7s %7s %7s   %s', '이름', '위', '아래', '옆', '판정 재료')
        rows.first(max_mats).each do |s|
          f = [s[:faces], 1].max
          say format('    %-24s %6.0f%% %6.0f%% %6.0f%%   %s',
                     clip(s[:name], 24),
                     100.0 * s[:up] / f, 100.0 * s[:down] / f, 100.0 * s[:side] / f,
                     s[:up] + s[:down] > f * 0.05 ? '입체(차체·부품)' : '납작(창·판)')
        end
        say ''

        say '=' * 92
        say '[3] 무엇에 붙었나 (가장 가까운 컴포넌트, 전부)'
        say '=' * 92
        rows.first(max_mats).each do |s|
          owners = s[:owners].sort_by { |_, v| -v }
          say format('    %-24s %s', clip(s[:name], 24),
                     clip(owners.map { |k, v| "#{k}(#{v})" }.join(' · '), 62))
        end
        say ''

        say '=' * 92
        say '[4] 크기와 색'
        say '=' * 92
        rows.first(max_mats).each do |s|
          b = s[:bb]
          next unless b
          say format('    %-24s %5.2f x %5.2f x %5.2f m   RGB(%3d,%3d,%3d) %s',
                     clip(s[:name], 24),
                     (b.max.x - b.min.x).to_m, (b.max.y - b.min.y).to_m, (b.max.z - b.min.z).to_m,
                     s[:rgb][0], s[:rgb][1], s[:rgb][2],
                     s[:textured] ? '텍스처 있음' : '색만')
        end
        say ''
        say '=' * 92
        say '[5] 알파는 1.0 인데 IRIS 가 유리로 볼 수 있는 재질 (Enscape 설정)'
        say '=' * 92
        unless defined?(IRIS::Enscape)
          f = File.join(File.dirname(__FILE__), 'iris_enscape.rb')
          load f if File.exist?(f)
        end
        if defined?(IRIS::Enscape)
          with_data = 0
          risky = []
          model.materials.each do |m|
            e = (IRIS::Enscape.material(m) rescue nil)
            next unless e
            with_data += 1
            op = e['opacity']
            next unless e['solid_glass'] || (op && op < 0.999)
            risky << [m.display_name.to_s, (m.alpha rescue 1.0), op, e['solid_glass'], e['etype']]
          end
          say "    재질 #{model.materials.size}개 중 Enscape 설정이 있는 것 #{with_data}개"
          if risky.empty?
            say '    알파 1.0 인데 Enscape 때문에 유리가 되는 재질: **없음**'
          else
            risky.each do |n, a, op, sg, t|
              say format('    %-24s 알파 %.3f · Enscape 불투명도 %s · 고체유리 %s · %s',
                         clip(n, 24), a, op ? format('%.3f', op) : '-', sg ? '예' : '아니오', t)
            end
          end
        else
          say '    iris_enscape.rb 를 못 올렸습니다 — 건너뜁니다.'
        end
        say ''
        say '  읽는 법 — 위/아래를 보는 면이 거의 없으면 **판**입니다(차창·유리).'
        say '            위·아래가 고루 섞이면 **입체**입니다(차체·범퍼·램프).'
        finish(out_dir, 'body_opaque_report.txt')
      rescue StandardError => e
        fail_out(e, out_dir, 'body_opaque_report.txt')
      end

      # ------------------------------------------------------- 카메라로 보기

      # **번호로 부릅니다.** 재질 이름이 한글이라 콘솔에 타이핑하면 깨집니다
      # (붙여넣기가 한글에서 실패한 적이 있습니다). 보고서 [1]번 표의
      # 순번을 그대로 씁니다.
      def look(n)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        report if rows.empty?
        s = rows[n - 1]
        return puts("[IRIS] #{n}번이 없습니다.") unless s && s[:bb]
        name = s[:name]

        # View#zoom 은 BoundingBox 를 안 받습니다(숫자·엔티티만) — 한 번
        # TypeError 로 배웠습니다. 카메라를 직접 놓습니다.
        view = model.active_view
        @saved_camera ||= view.camera
        c = s[:bb].center
        d = [s[:bb].diagonal.to_f, 12.0].max          # 인치. 너무 작으면 코앞이 됩니다
        eye = Geom::Point3d.new(c.x + d * 0.8, c.y - d * 0.8, c.z + d * 0.5)
        view.camera = Sketchup::Camera.new(eye, c, Z_AXIS)
        puts "[IRIS] '#{name}' 쪽으로 옮겼습니다. IRIS::BodyOpaque.restore 로 되돌립니다."
        nil
      end

      def restore
        model = Sketchup.active_model
        return unless model && @saved_camera
        model.active_view.camera = @saved_camera
        @saved_camera = nil
        puts '[IRIS] 카메라를 되돌렸습니다.'
        nil
      end

      # ------------------------------------------------------------- 표시해보기
      #
      # 이름·숫자로는 끝내 확신이 안 섭니다. **잠깐 자홍색 불투명으로**
      # 칠해서 어디가 그 재질인지 눈으로 봅니다. unpeek 로 값까지 되돌립니다
      # (되돌리기 한 번으로도 됩니다).
      def peek(*ns)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        report if rows.empty?
        index = model.materials.each_with_object({}) { |m, h| h[m.entityID] = m }
        picks = ns.map { |n| rows[n - 1] }.compact
        return puts('[IRIS] 그런 번호가 없습니다.') if picks.empty?

        model.start_operation('IRIS: 재질 표시', true)
        @peek = picks.map do |s|
          m = index[s[:id]]
          next unless m
          rec = { id: s[:id], name: s[:name], alpha: m.alpha, color: m.color }
          m.alpha = 1.0
          m.color = Sketchup::Color.new(255, 0, 255)
          rec
        end.compact
        model.commit_operation
        puts "[IRIS] #{@peek.map { |r| r[:name] }.join(', ')} 를 자홍색으로 칠했습니다. unpeek 로 되돌립니다."
        nil
      end

      def unpeek
        model = Sketchup.active_model
        return puts('[IRIS] 표시한 것이 없습니다.') unless model && @peek && !@peek.empty?
        index = model.materials.each_with_object({}) { |m, h| h[m.entityID] = m }
        model.start_operation('IRIS: 재질 표시 되돌리기', true)
        @peek.each do |r|
          m = index[r[:id]]
          next unless m
          m.color = r[:color]
          m.alpha = r[:alpha]
        end
        model.commit_operation
        puts "[IRIS] #{@peek.size}개를 되돌렸습니다."
        @peek = nil
      end

      # ---------------------------------------------------------------- 적용

      # 대상 목록은 **파일에서** 읽습니다 — 한 줄에 재질 이름 하나, UTF-8.
      # 콘솔에 한글을 타이핑하지 않기 위해서입니다.
      def targets_file
        File.expand_path(File.join(File.dirname(__FILE__), '..', '..',
                                   'out', 'sketchup', 'body_opaque_targets.txt'))
      end

      def apply_from_file
        path = targets_file
        return puts("[IRIS] 대상 파일이 없습니다: #{path}") unless File.exist?(path)
        # BOM 은 인코딩 이름으로 벗깁니다. UTF-8 소스 안에 바이트 리터럴로
        # 쓴 정규식은 인코딩이 어긋나 터집니다.
        names = File.read(path, encoding: 'bom|UTF-8').split("\n")
                    .map(&:strip)
                    .reject { |l| l.empty? || l.start_with?('#') }
        puts "[IRIS] 대상 #{names.size}개를 파일에서 읽었습니다."
        apply(names)
      end

      # 알파 1.0 으로. **되돌리기 한 번**으로 묶습니다.
      def apply(names)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        names = [names] unless names.is_a?(Array)

        found = names.map { |n| [n, model.materials.to_a.find { |m| m.display_name.to_s == n }] }
        missing = found.select { |_, m| m.nil? }.map(&:first)
        puts "[IRIS] 못 찾은 재질: #{missing.join(', ')}" unless missing.empty?
        targets = found.map(&:last).compact
        return puts('[IRIS] 바꿀 것이 없습니다.') if targets.empty?

        model.start_operation('IRIS: 차체 불투명', true)
        @undo = targets.map do |m|
          rec = { name: m.display_name.to_s, id: m.entityID, alpha: (m.alpha rescue 1.0) }
          m.alpha = 1.0
          rec
        end
        model.commit_operation

        @undo.each { |r| puts format('[IRIS] %-24s 알파 %.3f -> 1.000', r[:name], r[:alpha]) }
        puts '[IRIS] 되돌리기: Ctrl+Z 한 번, 또는 IRIS::BodyOpaque.revert'
        puts '[IRIS] 파일에는 저장하지 않았습니다 — 저장은 사용자가 정합니다.'
        @undo
      end

      def revert
        model = Sketchup.active_model
        return puts('[IRIS] 되돌릴 기록이 없습니다.') unless model && @undo && !@undo.empty?
        index = model.materials.each_with_object({}) { |m, h| h[m.entityID] = m }
        model.start_operation('IRIS: 차체 불투명 되돌리기', true)
        @undo.each do |r|
          m = index[r[:id]]
          m.alpha = r[:alpha] if m
        end
        model.commit_operation
        puts "[IRIS] #{@undo.size}개를 원래 값으로 되돌렸습니다."
        @undo = nil
      end

      # ---------------------------------------------------------------- 속살

      def rows = (@rows || [])

      def gather(model)
        targets = model.materials.to_a.select { |m| (m.alpha rescue 1.0) < 0.999 }
        @stat = {}
        targets.each do |m|
          c = (m.color rescue nil)
          @stat[m.entityID] = {
            id: m.entityID,
            name: m.display_name.to_s, alpha: (m.alpha rescue 1.0),
            faces: 0, area: 0.0, area_old: 0.0,
            up: 0, down: 0, side: 0, owners: Hash.new(0), bb: nil,
            rgb: c ? [c.red, c.green, c.blue] : [0, 0, 0],
            textured: !(m.texture rescue nil).nil?
          }
        end
        t0 = Time.now
        walk(model.entities, Geom::Transformation.new, 0, '(루트)')
        say format('트리 순회 %.1f ms · 반투명 재질 %d개', (Time.now - t0) * 1000.0, targets.size)
        say ''
        @stat
      end

      def walk(entities, tr, depth, owner)
        return if depth > MAX_DEPTH
        entities.each do |e|
          case e
          when Sketchup::Face
            note(e, tr, owner)
          when Sketchup::ComponentInstance, Sketchup::Group
            d = (e.definition rescue nil)
            next unless d
            nm = if e.is_a?(Sketchup::ComponentInstance)
                   d.name.to_s
                 else
                   e.name.to_s.empty? ? owner : e.name.to_s
                 end
            walk(d.entities, tr * e.transformation, depth + 1, nm)
          end
        end
      end

      def note(face, tr, owner)
        [face.material, face.back_material].compact.uniq.each do |m|
          s = @stat[m.entityID]
          next unless s
          # SketchUp 이 직접 변환된 넓이를 줍니다. 숨은 배율까지 봅니다.
          a  = (face.area(tr) rescue face.area) * 0.00064516   # 제곱인치 -> m2
          sc = (tr.xaxis.length * tr.yaxis.length) rescue 1.0
          s[:faces]    += 1
          s[:area]     += a
          s[:area_old] += face.area * sc * 0.00064516
          n = (face.normal.transform(tr) rescue face.normal)
          n = n.normalize if n.length > 0
          if n.z > 0.5 then s[:up] += 1
          elsif n.z < -0.5 then s[:down] += 1
          else s[:side] += 1
          end
          s[:owners][owner] += 1
          s[:bb] ||= Geom::BoundingBox.new
          face.outer_loop.vertices.each { |v| s[:bb].add(v.position.transform(tr)) }
        end
      rescue StandardError
        nil
      end

      def clip(t, n) = t.to_s[0, n]

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def fail_out(e, out_dir, name)
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir, name)
      end

      def finish(out_dir, name)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, name)
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

IRIS::BodyOpaque.report
