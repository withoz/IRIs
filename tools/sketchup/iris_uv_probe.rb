# encoding: UTF-8
#
# IRIS — 텍스처 UV / 거울 배치 조사
#
# 왜 필요한가
#   렌더에서 로고 글자가 좌우로 뒤집히고 같은 면에 두 번 나옵니다.
#   원인 후보가 둘인데 서로 완전히 다른 곳입니다.
#
#     (1) UV        — 우리가 읽는 UV 가 SketchUp 이 쓰는 것과 다르다
#     (2) 거울 배치 — 컴포넌트가 뒤집혀 놓였고(행렬식 음수) 우리 변환이
#                     그 부호를 잃는다
#
#   추측으로 한쪽을 고치면 다른 쪽이 남습니다. 실제 값을 봅니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_uv_probe.rb'
#   IRIS::UvProbe.run                    # 텍스처 있는 재질 전부 요약
#   IRIS::UvProbe.run(match: 'up')       # 이름·파일명에 'up' 이 든 것만
#
# 읽기 전용입니다. out/sketchup/uv_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module UvProbe
    class << self
      # id: 'mat_114' 처럼 프로브가 붙인 재질 id 로 바로 찍을 수 있습니다.
      def run(out_dir: nil, match: nil, id: nil, max_mats: 8, max_faces: 3)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say ''

        # --- 1. 거울 배치 ---
        say '=' * 70
        say '[1] 거울 배치 (행렬식이 음수인 인스턴스)'
        say '=' * 70
        neg = []
        walk_instances(model.entities, Geom::Transformation.new, neg, 0)
        say "    전체 인스턴스 #{@seen_instances}개 중 **거울 #{neg.size}개**"
        if neg.empty?
          say '    -> 거울 배치는 없습니다. 뒤집힘의 원인이 아닙니다.'
        else
          say '    -> 거울 배치가 있습니다. 변환의 부호 처리를 봐야 합니다.'
          neg.first(8).each { |r| say format('       det %+.4f  %s', r[:det], r[:name]) }
        end
        say ''

        # --- 2. 텍스처 재질의 UV ---
        say '=' * 70
        say '[2] q(원근 나눗셈 항)의 부호'
        say '=' * 70
        say '    uv_at 은 UVQ 를 줍니다. 프로브는 u=x/q, v=y/q 로 나눕니다.'
        say '    **q 가 음수면 u 와 v 가 함께 뒤집힙니다.**'
        qn = qtot = 0
        qmin = 1e30
        qmax = -1e30
        scan_q(model.entities, 0) do |q|
          qtot += 1
          qn += 1 if q < 0
          qmin = q if q < qmin
          qmax = q if q > qmax
        end
        say format('    정점 %d개 중 q<0 이 %d개  (범위 %.4f ~ %.4f)', qtot, qn, qmin, qmax)
        say(qn.zero? ? '    -> q 는 원인이 아닙니다.' : '    -> **q 가 음수인 정점이 있습니다. 여기가 원인입니다.**')
        say ''

        say '=' * 70
        say '[3] 텍스처 UV'
        say '=' * 70
        mats = model.materials.select { |m| (m.texture rescue nil) }
        if id
          want = id.to_s.sub(/\Amat_/, '').to_i
          mats = mats.select { |m| m.entityID == want }
        end
        if match
          re = Regexp.new(Regexp.escape(match), Regexp::IGNORECASE)
          mats = mats.select do |m|
            re.match?(m.name.to_s) || re.match?((m.texture.filename.to_s rescue ''))
          end
        end
        say "    텍스처 재질 #{mats.size}개#{match ? " ('#{match}' 필터)" : ''}"
        say ''

        mats.first(max_mats).each do |m|
          t = m.texture
          say "--- '#{m.name}' ---"
          say format('    파일   : %s', (t.filename rescue '?').to_s.split(%r{[/\\]}).last)
          say format('    크기   : %.4f x %.4f m  (픽셀 %s x %s)',
                     (t.width * 0.0254 rescue 0), (t.height * 0.0254 rescue 0),
                     (t.image_width rescue '?'), (t.image_height rescue '?'))
          faces = faces_using(model, m, max_faces)
          if faces.empty?
            say '    이 재질을 쓰는 면을 찾지 못했습니다'
            say ''
            next
          end
          faces.each_with_index do |info, idx|
            f = info[:face]
            side = info[:side]
            mesh = (f.mesh(1 | 2 | 4) rescue nil)
            next unless mesh
            fu = uv_range(mesh, true)
            bu = uv_range(mesh, false)
            say format('    면[%d] 재질쪽=%s  점 %d개  넓이 %.3f m2',
                       idx, side, mesh.count_points, (f.area * 0.00064516 rescue 0))
            (1..[mesh.count_points, 4].min).each do |i|
              raw = (mesh.uv_at(i, true) rescue nil)
              next unless raw
              say format('          raw[%d] x=%.4f y=%.4f q=%.4f  ->  u=%.4f v=%.4f',
                         i, raw.x.to_f, raw.y.to_f, raw.z.to_f,
                         raw.x.to_f / (raw.z.to_f.abs < 1e-12 ? 1.0 : raw.z.to_f),
                         raw.y.to_f / (raw.z.to_f.abs < 1e-12 ? 1.0 : raw.z.to_f))
            end
            say format('          앞면 UV  u %.3f~%.3f  v %.3f~%.3f', *fu)
            say format('          뒷면 UV  u %.3f~%.3f  v %.3f~%.3f', *bu)
            say format('          경로 %s', info[:path])
          end
          say ''
        end

        say '읽는 법'
        say '  UV 범위가 0~1 이면 텍스처가 한 번, 0~2 면 두 번 반복됩니다.'
        say '  앞면 UV 와 뒷면 UV 의 u 범위가 서로 뒤집혀 있으면(한쪽이 감소)'
        say '  어느 쪽을 쓰는지가 좌우 방향을 정합니다.'
        write_log(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(8).each { |l| say "   #{l}" }
        write_log(out_dir)
        raise
      end

      # 인스턴스를 훑으며 누적 변환의 행렬식 부호를 본다.
      def walk_instances(entities, acc, out, depth, path = '')
        @seen_instances = 0 if depth.zero?
        return if depth > 20
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          defn = e.respond_to?(:definition) ? e.definition : nil
          next unless defn
          @seen_instances += 1
          tr = acc * e.transformation
          d  = det(tr)
          nm = e.name.to_s.empty? ? defn.name.to_s : e.name.to_s
          out << { det: d, name: "#{path}/#{nm}" } if d < 0
          walk_instances(defn.entities, tr, out, depth + 1, "#{path}/#{nm}")
        end
      end

      def det(tr)
        a = tr.to_a.map(&:to_f)
        m = [[a[0], a[1], a[2]], [a[4], a[5], a[6]], [a[8], a[9], a[10]]]
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
          m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
          m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
      end

      # 이 재질을 쓰는 면을 몇 개 찾는다. 앞/뒤 어느 쪽에 붙었는지도 본다.
      def faces_using(model, mat, limit)
        found = []
        scan_faces(model.entities, mat, found, limit, '', 0)
        found
      end

      def scan_faces(entities, mat, found, limit, path, depth)
        return if found.size >= limit || depth > 20
        entities.each do |e|
          return if found.size >= limit
          if e.is_a?(Sketchup::Face)
            fm = (e.material rescue nil)
            bm = (e.back_material rescue nil)
            if fm == mat
              found << { face: e, side: '앞', path: path }
            elsif bm == mat
              found << { face: e, side: '뒤', path: path }
            end
          elsif e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
            defn = e.respond_to?(:definition) ? e.definition : nil
            next unless defn
            nm = e.name.to_s.empty? ? defn.name.to_s : e.name.to_s
            scan_faces(defn.entities, mat, found, limit, "#{path}/#{nm}", depth + 1)
          end
        end
      end

      # 모델 전체에서 q 의 분포를 봅니다.
      def scan_q(entities, depth, &blk)
        return if depth > 12
        entities.each do |e|
          if e.is_a?(Sketchup::Face)
            m = (e.mesh(1 | 2 | 4) rescue nil)
            next unless m
            (1..m.count_points).each do |i|
              uv = (m.uv_at(i, true) rescue nil)
              blk.call(uv.z.to_f) if uv
            end
          elsif e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
            d = e.respond_to?(:definition) ? e.definition : nil
            scan_q(d.entities, depth + 1, &blk) if d
          end
        end
      end

      def uv_range(mesh, front)
        us = []
        vs = []
        (1..mesh.count_points).each do |i|
          uv = (mesh.uv_at(i, front) rescue nil)
          next unless uv
          q = (uv.z.nil? || uv.z.abs < 1e-12) ? 1.0 : uv.z
          us << (uv.x / q).to_f
          vs << (uv.y / q).to_f
        end
        return [0.0, 0.0, 0.0, 0.0] if us.empty?
        [us.min, us.max, vs.min, vs.max]
      end

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def write_log(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'uv_probe.txt')
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

puts '[IRIS] UV 조사 로드 완료. IRIS::UvProbe.run 을 실행하세요.'
