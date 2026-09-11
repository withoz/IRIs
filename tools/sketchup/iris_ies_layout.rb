# encoding: UTF-8
#
# IRIS — IES 0도 방위를 **배치로** 가립니다
#
# 무엇이 남았나
#   Enscape 는 IES 조명에 회전을 저장하지 않습니다(ies_xml.txt 로 확인).
#   방위 기준은 오로지 프록시 변환에서 나옵니다. 우리는 **로컬 +X 를 0도
#   방위 평면**이라고 가정했습니다.
#
#   이 모델의 배광은 **사분 대칭**(가로각 0~90)입니다. 그러면 180도 회전은
#   자기 자신이라 티가 안 납니다. 남은 가능성은 **0도냐 90도냐 둘뿐**입니다.
#   즉 틀렸다면 넓은 축과 좁은 축이 뒤바뀝니다 (29.8도 대 18.0도).
#
# 어떻게 가리나
#   조명이 **무엇을 비추는지**를 봅니다. 벽을 씻는 기구(월워셔)는
#
#     - 벽 쪽으로 기울고
#     - 넓은 축이 **벽과 나란해야** 합니다 (벽면을 고르게 덮으려고)
#
#   이 모델의 #1 여덟 개는 15도 기울어 있습니다. 기운 방향이 벽을 가리키고,
#   배치가 이루는 선이 벽의 방향입니다. 그 둘이 직교하면 가정을 검증할 수
#   있습니다.
#
#   판정:
#     넓은 축(로컬 +Y) 이 배치선과 나란하면  -> 가정이 맞습니다
#     좁은 축(로컬 +X) 이 배치선과 나란하면  -> 90도 틀렸습니다
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_ies_layout.rb'
#
# 읽기 전용입니다. out/sketchup/ies_layout.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module IesLayout
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log  = []
        @rows = []
        @ies  = {}

        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        walk(model.entities, Geom::Transformation.new, 0)

        if @rows.empty?
          say 'IES 조명 배치를 찾지 못했습니다.'
          return finish(out_dir)
        end

        say '=' * 74
        say '[0] 원본 IES 의 머리말 — 제조사가 방향을 적어 뒀는가'
        say '=' * 74
        @ies.each do |name, txt|
          say format('  %s', name)
          txt.each { |l| say format('    %s', l[0, 110]) }
          say ''
        end

        by_def = @rows.group_by { |r| r[:def] }
        by_def.each { |name, rows| report(name, rows) }

        say '=' * 74
        say '판정 규칙'
        say '=' * 74
        say '  월워셔는 벽 쪽으로 기울고, **넓은 축이 벽과 나란**해야 합니다.'
        say '  배치선 = 벽의 방향. 기운 방향 = 벽이 있는 쪽(배치선과 직교).'
        say ''
        say '  넓은 축(로컬 +Y)이 배치선과 나란함  -> 가정(로컬 +X = 0도) 맞음'
        say '  좁은 축(로컬 +X)이 배치선과 나란함  -> 90도 틀림'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def report(name, rows)
        say '-' * 74
        say format('%s   배치 %d개', name, rows.size)

        pts = rows.map { |r| r[:pos] }
        line = principal_axis(pts)
        if line.nil?
          say '    한 점에 모여 있습니다 — 배치선을 구할 수 없습니다.'
          say ''
          return
        end
        dir, spread, second = line
        say format('    배치선  (%.3f %.3f %.3f)  퍼짐 %.1f 인치 (직교 방향 %.1f)',
                   dir.x, dir.y, dir.z, spread, second)
        if second > spread * 0.35
          say '    -> 선이 아니라 판/무리입니다. 벽 방향을 못 읽습니다.'
          say ''
          return
        end

        r0 = rows.first
        say format('    방출 축  (%.3f %.3f %.3f)   (로컬 +Z)',
                   r0[:aim].x, r0[:aim].y, r0[:aim].z)
        # 기운 방향 = 방출 축의 수평 성분.
        tilt = Geom::Vector3d.new(r0[:aim].x, r0[:aim].y, 0)
        if tilt.length > 1e-6
          tilt.normalize!
          say format('    기운 쪽  (%.3f %.3f %.3f)  — 벽은 이쪽에 있습니다',
                     tilt.x, tilt.y, tilt.z)
          say format('    기운 쪽 · 배치선 |cos| %.3f  (0 이면 직교 — 월워셔다움)',
                     (tilt % dir).abs)
        else
          say '    기울지 않았습니다 (수직 다운라이트) — 벽 방향 단서 없음'
        end

        xa = r0[:xaxis]
        ya = r0[:yaxis]
        say format('    좁은 축 로컬 +X (%.3f %.3f %.3f) · 배치선과 |cos| %.3f',
                   xa.x, xa.y, xa.z, (xa % dir).abs)
        say format('    넓은 축 로컬 +Y (%.3f %.3f %.3f) · 배치선과 |cos| %.3f',
                   ya.x, ya.y, ya.z, (ya % dir).abs)

        cx = (xa % dir).abs
        cy = (ya % dir).abs
        verdict =
          if (cx - cy).abs < 0.2
            '판정 불가 — 두 축이 배치선과 비슷하게 놓였습니다'
          elsif cy > cx
            '**넓은 축이 배치선과 나란합니다 -> 가정이 맞습니다**'
          else
            '**좁은 축이 배치선과 나란합니다 -> 90도 틀렸습니다**'
          end
        say format('    => %s', verdict)
        say ''
      end

      # 점들의 주축. [방향, 그 방향 퍼짐, 직교 퍼짐]
      def principal_axis(pts)
        return nil if pts.size < 2
        n  = pts.size.to_f
        cx = pts.sum { |p| p.x.to_f } / n
        cy = pts.sum { |p| p.y.to_f } / n
        # 수평면에서만 봅니다 — 조명은 대개 같은 높이에 달립니다.
        sxx = syy = sxy = 0.0
        pts.each do |p|
          dx = p.x.to_f - cx
          dy = p.y.to_f - cy
          sxx += dx * dx
          syy += dy * dy
          sxy += dx * dy
        end
        tr  = sxx + syy
        return nil if tr < 1e-9
        det = sxx * syy - sxy * sxy
        disc = Math.sqrt([tr * tr / 4.0 - det, 0.0].max)
        l1 = tr / 2.0 + disc
        l2 = tr / 2.0 - disc
        v = if sxy.abs > 1e-9
              Geom::Vector3d.new(l1 - syy, sxy, 0)
            else
              sxx >= syy ? Geom::Vector3d.new(1, 0, 0) : Geom::Vector3d.new(0, 1, 0)
            end
        return nil if v.length < 1e-9
        v.normalize!
        [v, Math.sqrt([l1 / n, 0.0].max) * 2.0, Math.sqrt([l2 / n, 0.0].max) * 2.0]
      end

      def walk(entities, tr, depth)
        return if depth > 14
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          d = (e.definition rescue nil)
          next unless d
          t = tr * e.transformation
          if ies?(d)
            @rows << { def: d.name.to_s, pos: t.origin,
                       aim: t.zaxis.normalize,      # 프록시 정면은 로컬 +Z (실측)
                       xaxis: t.xaxis.normalize,
                       yaxis: t.yaxis.normalize }
            next
          end
          walk(d.entities, t, depth + 1)
        end
      end

      def ies?(defn)
        dict = (defn.attribute_dictionary('Enscape.Light') rescue nil)
        return false unless dict
        xml = dict['LightData'].to_s
        return false unless xml.include?('SketchupIesLight')
        unless @ies.key?(defn.name.to_s)
          @ies[defn.name.to_s] = head_lines(xml[%r{<IesData>(.*?)</IesData>}m, 1])
        end
        true
      end

      # TILT 앞의 키워드 줄들 — 제조사가 방향을 적어 뒀을 수 있습니다.
      def head_lines(b64)
        return ['(읽지 못함)'] if b64.nil?
        text = b64.unpack1('m').to_s.force_encoding('BINARY').gsub(/\r\n?/, "\n")
        i = text.index(/^[ \t]*TILT[ \t]*=/i)
        return ['(TILT 없음)'] if i.nil?
        lines = text[0, i].split("\n").map(&:rstrip).reject(&:empty?)
        # TILT 바로 뒤 두 줄(헤더 숫자)도 같이 보여 줍니다.
        lines + ['--- TILT 이후 ---'] + text[i..].split("\n")[0, 3].map(&:rstrip)
      rescue StandardError
        ['(파싱 실패)']
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
        path = File.join(dir, 'ies_layout.txt')
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

IRIS::IesLayout.run
