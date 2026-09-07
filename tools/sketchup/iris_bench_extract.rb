# encoding: UTF-8
#
# IRIS — SketchUp 지오메트리 추출 방식별 속도 벤치마크
#
# 목적
#   프로토콜 설계([docs/05-씬-델타-프로토콜.md])의 성능 목표를 정하려면 "Ruby로
#   어디까지 되는가"를 알아야 한다. 현재 프로브는 정점마다 API를 3번 호출하고
#   rescue 블록까지 세우는데(실측 29,363 tri/s), 이게 Ruby의 한계인지 구현의
#   문제인지 구분되지 않은 상태다.
#
#   여기서 추출 방식을 바꿔가며 재서, C API 이관이 정말 필요한지와 몇 배가
#   필요한지를 근거 있게 판단한다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_bench_extract.rb'
#   IRIS::BenchExtract.run                 # 면 3만 개 표본
#   IRIS::BenchExtract.run(limit: 100_000) # 표본 크기 지정
#   IRIS::BenchExtract.run(limit: nil)     # 전체
#
# 읽는 법
#   A가 현재 프로브 방식이다. B~E 가 얼마나 빨라지는지가 최적화 여지이고,
#   F(면 순회만)가 이론적 상한이다. F에 가까울수록 Ruby로는 더 못 짜낸다는 뜻.
#
# 주의: 읽기 전용이다. 모델을 변경하지 않는다.

require 'fileutils'

module IRIS
  module BenchExtract

    INCH_TO_M  = 0.0254
    MESH_FLAGS = 1 | 2 | 4     # UVQ front | UVQ back | normals

    class << self

      def run(limit: 30_000, out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        # 콘솔은 읽기가 번거롭다. 프로브와 마찬가지로 파일로도 남긴다.
        @log = []
        say ''
        say "모델: #{model.title}"
        say "SketchUp #{Sketchup.version} / Ruby #{RUBY_VERSION}"
        say ''
        say '면 수집 중…'
        t0 = Time.now
        faces = collect_faces(model, limit)
        say format('  면 %d개 수집 (%.2f초)', faces.size, Time.now - t0)

        tris = faces.sum { |f| [(f.vertices.length - 2), 1].max }
        say format('  삼각형 약 %d개', tris)
        say ''

        results = []
        results << bench('A 현재 프로브 (point_at/normal_at/uv_at + rescue)', faces, tris) { |f| extract_a(f) }
        results << bench('B rescue 제거', faces, tris)                                    { |f| extract_b(f) }
        results << bench('C + points 벌크 접근',  faces, tris)                            { |f| extract_c(f) }
        results << bench('D + 면 법선 사용 (정점 법선 포기)', faces, tris)                 { |f| extract_d(f) }
        results << bench('E 위치+인덱스만 (법선·UV 없음)', faces, tris)                    { |f| extract_e(f) }
        results << bench('F mesh() 호출만 (추출 없음)', faces, tris)                       { |f| extract_f(f) }
        results << bench('G 면 순회만 (mesh() 없음) — 상한', faces, tris)                  { |f| nil }

        say ''
        say '=' * 74
        say format('%-46s %10s %14s', '방식', '초', '삼각형/초')
        say '-' * 74
        base = results.first[:rate]
        results.each do |r|
          mark = r[:rate] > 0 && base > 0 ? format(' (%.1f배)', r[:rate] / base) : ''
          say format('%-46s %10.3f %14s%s', r[:name], r[:sec],
                     r[:rate].round.to_s.reverse.scan(/\d{1,3}/).join(',').reverse, mark)
        end
        say '=' * 74
        say ''
        say 'A→D 사이가 Ruby 안에서 얻을 수 있는 개선폭입니다.'
        say 'G(면 순회만)에 근접할수록 Ruby로는 더 못 짜낸다는 뜻이고,'
        say '그 경우 C API 이관 외에 방법이 없습니다.'

        path = write_log(out_dir)
        puts ''
        puts "결과 저장: #{path}" if path
        { saved: path }
      end

      def say(line)
        @log ||= []
        @log << line
        puts line
      end

      def write_log(out_dir)
        dir = out_dir || File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'bench_extract.txt')
        File.open(path, 'w:UTF-8') { |f| f.write(@log.join("\n")) }
        path
      rescue StandardError => e
        puts "결과 저장 실패: #{e.message}"
        nil
      end

      # ------------------------------------------------------------ 수집

      def collect_faces(model, limit)
        faces = []
        seen  = {}
        walk = lambda do |entities, depth|
          return if depth > 24
          return if limit && faces.size >= limit
          entities.each do |e|
            break if limit && faces.size >= limit
            case e
            when Sketchup::Face
              faces << e
            when Sketchup::ComponentInstance, Sketchup::Group
              d = e.is_a?(Sketchup::Group) ? (e.definition rescue nil) : e.definition
              next unless d
              next if seen[d.entityID]     # 정의당 1회 (프로브와 같은 규칙)
              seen[d.entityID] = true
              walk.call(d.entities, depth + 1)
            end
          end
        end
        walk.call(model.entities, 0)
        faces
      end

      def bench(name, faces, tris)
        GC.start
        t = Time.now
        faces.each { |f| yield f }
        sec = Time.now - t
        { name: name, sec: sec, rate: sec > 0 ? tris / sec : 0.0 }
      end

      # ------------------------------------------------------------ 방식들

      # A: 현재 프로브와 동일
      def extract_a(face)
        mesh = face.mesh(MESH_FLAGS) rescue return
        pos = []; nrm = []; uv = []
        (1..mesh.count_points).each do |i|
          p = mesh.point_at(i)
          pos.push(p.x * INCH_TO_M, p.y * INCH_TO_M, p.z * INCH_TO_M)
          n = (mesh.normal_at(i) rescue nil)
          n ? nrm.push(n.x, n.y, n.z) : nrm.push(0.0, 0.0, 1.0)
          t = (mesh.uv_at(i, true) rescue nil)
          if t
            q = t.z.abs < 1e-12 ? 1.0 : t.z
            uv.push(t.x / q, t.y / q)
          else
            uv.push(0.0, 0.0)
          end
        end
        mesh.polygons.each { |poly| poly }
        [pos, nrm, uv]
      end

      # B: 핫 루프에서 rescue 제거 (예외 프레임 설치 비용 제거)
      def extract_b(face)
        mesh = face.mesh(MESH_FLAGS) rescue return
        pos = []; nrm = []; uv = []
        (1..mesh.count_points).each do |i|
          p = mesh.point_at(i)
          pos.push(p.x * INCH_TO_M, p.y * INCH_TO_M, p.z * INCH_TO_M)
          n = mesh.normal_at(i)
          nrm.push(n.x, n.y, n.z)
          t = mesh.uv_at(i, true)
          q = t.z.abs < 1e-12 ? 1.0 : t.z
          uv.push(t.x / q, t.y / q)
        end
        mesh.polygons.each { |poly| poly }
        [pos, nrm, uv]
      end

      # C: points 벌크 접근 — 정점 하나당 호출 1회를 줄인다
      def extract_c(face)
        mesh = face.mesh(MESH_FLAGS) rescue return
        pos = []; nrm = []; uv = []
        mesh.points.each do |p|
          pos.push(p.x * INCH_TO_M, p.y * INCH_TO_M, p.z * INCH_TO_M)
        end
        (1..mesh.count_points).each do |i|
          n = mesh.normal_at(i)
          nrm.push(n.x, n.y, n.z)
          t = mesh.uv_at(i, true)
          q = t.z.abs < 1e-12 ? 1.0 : t.z
          uv.push(t.x / q, t.y / q)
        end
        mesh.polygons.each { |poly| poly }
        [pos, nrm, uv]
      end

      # D: 면 법선을 모든 정점에 공유 — 정점당 호출 1회 제거.
      #    곡면은 각지게 보이지만 건축 모델은 대부분 평면이다.
      def extract_d(face)
        mesh = face.mesh(MESH_FLAGS) rescue return
        fn = face.normal
        nx = fn.x; ny = fn.y; nz = fn.z
        pos = []; nrm = []; uv = []
        mesh.points.each do |p|
          pos.push(p.x * INCH_TO_M, p.y * INCH_TO_M, p.z * INCH_TO_M)
          nrm.push(nx, ny, nz)
        end
        (1..mesh.count_points).each do |i|
          t = mesh.uv_at(i, true)
          q = t.z.abs < 1e-12 ? 1.0 : t.z
          uv.push(t.x / q, t.y / q)
        end
        mesh.polygons.each { |poly| poly }
        [pos, nrm, uv]
      end

      # E: 위치와 인덱스만 — UV·법선 비용 제거
      def extract_e(face)
        mesh = face.mesh(0) rescue return
        pos = []
        mesh.points.each { |p| pos.push(p.x * INCH_TO_M, p.y * INCH_TO_M, p.z * INCH_TO_M) }
        mesh.polygons.each { |poly| poly }
        pos
      end

      # F: 삼각분할만 하고 아무것도 꺼내지 않음 — mesh() 자체의 비용
      def extract_f(face)
        face.mesh(MESH_FLAGS) rescue nil
        nil
      end
    end
  end
end

puts '[IRIS] 추출 벤치마크 로드 완료. IRIS::BenchExtract.run 을 실행하세요.'
