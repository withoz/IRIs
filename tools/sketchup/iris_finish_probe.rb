# encoding: UTF-8
#
# IRIS — 반투명 재질이 **무엇에** 칠해져 있나
#
# 왜
#   우리는 "알파 < 1 이고 텍스처 없음 -> 유리"로 정합니다. 세종 모델에는
#   `C01 색`·`L16 색`·`Color_A01` 처럼 **마감 코드 이름**을 단 반투명
#   재질이 섞여 있고, 그것도 유리로 휩쓸립니다.
#
#   이름만으로는 못 가립니다. 유리일 수도 있고(코드가 유리 사양일 수도
#   있습니다), 반투명 스크린일 수도 있고, 도면용 표시일 수도 있습니다.
#
#   **무엇에 칠해져 있는지**를 보면 갈립니다:
#     - 큰 수직면 몇 장    -> 커튼월·스크린
#     - 작은 조각 여럿      -> 몰딩·프레임·디테일
#     - 수평면 위주        -> 바닥·천장 (유리일 리 없습니다)
#     - 한 컴포넌트 안에만  -> 그 컴포넌트가 무엇인지가 답
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_finish_probe.rb'
#
# 읽기 전용입니다. out/sketchup/finish_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module FinishProbe
    class << self
      MAX_DEPTH = 12

      def run(out_dir: nil, max_mats: 14)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        targets = model.materials.to_a.select { |m| (m.alpha rescue 1.0) < 0.999 }
        if targets.empty?
          say '반투명 재질이 없습니다.'
          return finish(out_dir)
        end

        # 재질 -> 통계. 트리를 **한 번만** 훑습니다.
        @stat = {}
        targets.each { |m| @stat[m.entityID] = blank(m) }
        @targets = targets.each_with_object({}) { |m, h| h[m.entityID] = m }

        t0 = Time.now
        walk(model.entities, Geom::Transformation.new, 0, '(루트)')
        say format('트리 순회 %.1f ms', (Time.now - t0) * 1000.0)
        say ''

        rows = @stat.values.select { |s| s[:faces] > 0 }
                    .sort_by { |s| -s[:area] }
        say '=' * 78
        say '[1] 넓이 순 — 화면에서 차지하는 몫'
        say '=' * 78
        say format('    %-26s %6s %7s %9s %6s %6s', '이름', '알파', '면', '넓이 m2', '수직%', '큰면%')
        rows.first(max_mats).each do |s|
          say format('    %-26s %6.3f %7d %9.1f %5.0f%% %5.0f%%',
                     s[:name][0, 26], s[:alpha], s[:faces], s[:area],
                     100.0 * s[:vertical] / [s[:faces], 1].max,
                     100.0 * s[:big] / [s[:faces], 1].max)
        end
        say ''
        say '    수직% — 법선이 수평에 가까운 면(벽·커튼월). 낮으면 바닥·천장입니다.'
        say '    큰면% — 1 m2 이상인 면. 낮으면 몰딩·프레임 같은 조각입니다.'
        say ''

        say '=' * 78
        say '[2] 어디에 들어 있나 (상위 컴포넌트)'
        say '=' * 78
        rows.first(max_mats).each do |s|
          say format('    %-26s %s', s[:name][0, 26],
                     s[:owners].sort_by { |_, v| -v }.first(4)
                               .map { |k, v| "#{k}(#{v})" }.join(' · ')[0, 84])
        end
        say ''

        say '=' * 78
        say '[3] 어디쯤에 있나 (월드 바운딩박스, m)'
        say '=' * 78
        rows.first(max_mats).each do |s|
          b = s[:bb]
          next if b.nil?
          say format('    %-26s X %.0f~%.0f · Y %.0f~%.0f · Z %.1f~%.1f',
                     s[:name][0, 26],
                     b[0] * 0.0254, b[3] * 0.0254, b[1] * 0.0254, b[4] * 0.0254,
                     b[2] * 0.0254, b[5] * 0.0254)
        end
        say ''

        say '=' * 78
        say '읽는 법'
        say '=' * 78
        say '  수직% 높고 큰면% 높고 Z 범위가 층고를 덮으면 -> 커튼월·스크린. 유리 취급이 말이 됩니다.'
        say '  수직% 낮으면 바닥·천장입니다 — **유리일 리 없습니다.**'
        say '  큰면% 낮고 조각이 많으면 몰딩·프레임입니다 — 역시 유리가 아닙니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def blank(m)
        { name: m.display_name.to_s, alpha: (m.alpha rescue 1.0),
          faces: 0, area: 0.0, vertical: 0, big: 0, owners: Hash.new(0), bb: nil }
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
            # **가장 가까운 컴포넌트**를 소유자로 적습니다.
            #
            # 처음에는 최상위 이름을 적었는데, 모델 전체가 그룹 하나 안에
            # 들어 있어서 전부 `그룹#271` 로 나왔습니다 — 아무것도 알려주지
            # 않았습니다. 컴포넌트는 보통 의미 있는 이름을 답니다
            # (자동차·가구 같은 반입 자산이 그렇습니다).
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
          # 넓이는 변환의 배율을 반영해야 합니다. 균일 배율로 근사합니다.
          sc = (tr.xaxis.length * tr.yaxis.length) rescue 1.0
          a  = (face.area * sc) * 0.00064516   # 제곱인치 -> m2
          s[:faces] += 1
          s[:area]  += a
          s[:big]   += 1 if a >= 1.0
          n = (face.normal.transform(tr) rescue face.normal)
          s[:vertical] += 1 if n.z.abs < 0.5
          s[:owners][owner] += 1
          p = (face.bounds.center.transform(tr) rescue nil)
          next unless p
          if s[:bb].nil?
            s[:bb] = [p.x, p.y, p.z, p.x, p.y, p.z]
          else
            b = s[:bb]
            b[0] = p.x if p.x < b[0]; b[1] = p.y if p.y < b[1]; b[2] = p.z if p.z < b[2]
            b[3] = p.x if p.x > b[3]; b[4] = p.y if p.y > b[4]; b[5] = p.z if p.z > b[5]
          end
        end
      rescue StandardError
        nil
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
        path = File.join(dir, 'finish_probe.txt')
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

IRIS::FinishProbe.run
