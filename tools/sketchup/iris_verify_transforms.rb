# encoding: UTF-8
#
# IRIS — 변환 검증
#
# "가구 위치가 실제 모델과 다르다"는 보고를 숫자로 바꾸기 위한 도구입니다.
#
# 무엇을 대조하는가
#   진실  : SketchUp 자신의 Geom::Transformation 으로 누적한 월드 변환
#   우리 것: 프로브가 직렬화한 f32 행렬(미터 단위)을 같은 순서로 누적한 것
#
# 두 값이 어긋나면 **프로브의 직렬화**가 문제이고, 일치하면 문제는 그 다음
# 단계(렌더러)에 있습니다. 어느 쪽인지부터 가르는 것이 목적입니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_probe.rb'
#   load 'E:/IRIS/tools/sketchup/iris_verify_transforms.rb'
#   IRIS::VerifyTransforms.run
#
# 결과는 out/sketchup/verify_transforms.txt 에도 남습니다.

require 'fileutils'

module IRIS
  module VerifyTransforms
    INCH_TO_M = 0.0254
    MAX_DEPTH = 24

    class << self

      def run(out_dir: nil, limit: nil, tolerance_mm: 1.0)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Probe)
          return puts('[IRIS] iris_probe.rb 를 먼저 로드하십시오.')
        end

        @log = []
        @rows = []
        @count = 0
        @limit = limit

        say ''
        say "모델: #{model.title}"
        say '진실 = SketchUp 누적 변환 / 우리 것 = 프로브 직렬화 행렬 누적'
        say ''

        walk(model.entities, Geom::Transformation.new, identity4, 0, [])

        if @rows.empty?
          say '인스턴스를 찾지 못했습니다.'
          return write_log(out_dir)
        end

        errs = @rows.map { |r| r[:err_mm] }.sort
        worst = @rows.max_by(8) { |r| r[:err_mm] }

        say format('인스턴스 %d개 검사', @rows.size)
        say format('  위치 오차(mm)  중간값 %.4f · 95%%값 %.4f · 최대 %.4f',
                   errs[errs.size / 2], errs[(errs.size * 0.95).to_i], errs.last)
        say format('  %.1fmm 초과: %d개', tolerance_mm,
                   errs.count { |e| e > tolerance_mm })
        say ''

        if errs.last > tolerance_mm
          say '가장 큰 오차 (경로 / 오차mm / 깊이):'
          worst.each do |r|
            next if r[:err_mm] <= tolerance_mm
            say format('  %8.2f mm  깊이%d  %s', r[:err_mm], r[:depth], r[:path])
          end
          say ''
          say '→ 프로브가 직렬화한 행렬이 SketchUp 의 실제 변환과 다릅니다.'
          say '  단위 변환이나 균일 제수(15번 원소) 처리를 봐야 합니다.'
        else
          say '→ 직렬화는 정확합니다. 어긋남이 있다면 그 다음 단계(렌더러)입니다.'
        end

        # 참고 정보: 균일 제수와 비균일 스케일 분포
        w_not_one = @rows.count { |r| (r[:w] - 1.0).abs > 1e-9 }
        say ''
        say format('참고: 균일 제수(원소15) != 1 인 인스턴스 %d개', w_not_one)
        say format('      비균일 스케일 인스턴스 %d개', @rows.count { |r| r[:nonuniform] })
        say format('      최대 중첩 깊이 %d', @rows.map { |r| r[:depth] }.max)

        write_log(out_dir)
      end

      # ---------------------------------------------------------------- 내부

      def walk(entities, su_tr, our_tr, depth, path)
        return if depth > MAX_DEPTH
        return if @limit && @rows.size >= @limit

        entities.each do |e|
          break if @limit && @rows.size >= @limit
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)

          defn = e.is_a?(Sketchup::Group) ? (e.definition rescue nil) : e.definition
          next unless defn

          # --- 진실: SketchUp 자신의 변환 합성 ---
          su_child = su_tr * e.transformation

          # --- 우리 것: 프로브가 내보내는 행렬을 그대로 합성 ---
          our_child = mat_mul(our_tr, probe_matrix(e.transformation))

          # 원점을 각각 옮겨 비교합니다. 원점만 봐도 평행이동 오차가 잡히고,
          # 회전·스케일 오차는 자식 단계에서 위치 오차로 드러납니다.
          p_su  = su_child.origin
          truth = [p_su.x * INCH_TO_M, p_su.y * INCH_TO_M, p_su.z * INCH_TO_M]
          ours  = [our_child[12], our_child[13], our_child[14]]
          err_m = Math.sqrt((0..2).sum { |i| (truth[i] - ours[i])**2 })

          name = (e.name.to_s.empty? ? defn.name.to_s : e.name.to_s)
          here = path + [name[0, 24]]

          a = e.transformation.to_a
          w = a[15].to_f
          sx = Math.sqrt(a[0]**2 + a[1]**2 + a[2]**2)
          sy = Math.sqrt(a[4]**2 + a[5]**2 + a[6]**2)
          sz = Math.sqrt(a[8]**2 + a[9]**2 + a[10]**2)
          nonuniform = (sx - sy).abs > 1e-6 || (sy - sz).abs > 1e-6

          @rows << {
            err_mm: err_m * 1000.0, depth: depth, path: here.join(' / '),
            w: w, nonuniform: nonuniform,
          }

          walk(defn.entities, su_child, our_child, depth + 1, here)
        end
      end

      # 프로브가 실제로 내보내는 것과 **같은 방식**으로 행렬을 만듭니다.
      # (transform_to_a + 소비자 측 균일 제수 정규화)
      def probe_matrix(tr)
        a = IRIS::Probe.send(:transform_to_a, tr)
        w = a[15]
        return a if (w - 1.0).abs <= 1e-9
        return a if w.abs < 1e-12
        (0..14).each { |i| a[i] /= w }
        a[15] = 1.0
        a
      end

      def identity4
        [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
      end

      # 열 우선 4x4 곱. c = a 다음 b (즉 부모 a, 자식 b 를 합성한 월드 변환).
      # SketchUp 의 su_tr * e.transformation 과 같은 순서가 되도록 맞춥니다.
      def mat_mul(a, b)
        out = Array.new(16, 0.0)
        4.times do |col|
          4.times do |row|
            s = 0.0
            4.times { |k| s += a[k * 4 + row] * b[col * 4 + k] }
            out[col * 4 + row] = s
          end
        end
        out
      end

      def say(line)
        @log ||= []
        @log << line
        puts line
      end

      def write_log(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'verify_transforms.txt')
        File.open(path, 'w:UTF-8') { |f| f.write(@log.join("\n")) }
        puts ''
        puts "결과 저장: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "결과 저장 실패: #{e.message}"
        nil
      end
    end
  end
end

puts '[IRIS] 변환 검증 로드 완료. IRIS::VerifyTransforms.run 을 실행하세요.'
puts '       읽기 전용입니다 — 모델을 바꾸지 않습니다.'
