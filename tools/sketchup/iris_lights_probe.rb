# encoding: UTF-8
#
# IRIS — 조명 프록시 조사
#
# 왜 만드는가
#   문서에 "SketchUp 에는 광원 엔티티가 없다"고 적어 왔고 그건 사실입니다.
#   그런데 실제 프로젝트 모델을 열어 보니 **Enscape.SpotLight 컴포넌트가
#   29개** 들어 있었습니다. 사용자가 이미 조명을 배치해 둔 것입니다.
#
#   즉 조명 정보가 모델 안에 **컴포넌트 이름과 속성 사전**으로 존재합니다.
#   IRIS 가 그것을 읽으면 기존 Enscape 사용자의 모델이 그대로 켜집니다.
#
#   설계에 앞서 **무엇을 읽을 수 있는지** 부터 확인합니다. 세기·색·각도가
#   속성에 들어 있는지, 아니면 이름과 변환행렬뿐인지에 따라 설계가 달라집니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_lights_probe.rb'
#   IRIS::LightsProbe.run                 # 조명으로 보이는 것만
#   IRIS::LightsProbe.run(all: true)      # 속성 사전이 있는 모든 정의
#
# 읽기 전용입니다. 결과는 out/sketchup/lights_probe.txt 에도 남습니다.

require 'fileutils'

module IRIS
  module LightsProbe
    INCH_TO_M = 0.0254

    # 조명 프록시로 볼 이름들. Enscape 외 다른 도구도 넣어 둡니다.
    LIGHT_PATTERNS = [
      /enscape/i, /\blight\b/i, /luminaire/i, /ies\b/i,
      /spot\s*light/i, /point\s*light/i, /area\s*light/i,
      /조명/, /광원/,
    ].freeze

    class << self

      def run(out_dir: nil, all: false, max_dump: 6)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say ''
        say "모델: #{model.title}"
        say ''

        # --- 1. 정의 이름으로 후보 찾기 ---
        cands = model.definitions.select { |d| light_name?(d.name.to_s) }
        say "[1] 이름이 조명으로 보이는 정의: #{cands.size}"
        cands.sort_by { |d| -d.count_instances }.first(20).each do |d|
          say format('    %-38s 인스턴스 %d · 엔티티 %d',
                     d.name.to_s[0, 38], d.count_instances, d.entities.size)
        end
        say ''

        # --- 2. 속성 사전 조사 ---
        say '[2] 속성 사전 — 여기에 세기·색·각도가 있는지가 관건입니다'
        dumped = 0
        seen_dicts = Hash.new(0)

        targets = all ? model.definitions.to_a : cands
        targets.each do |d|
          # 정의 자체의 속성
          note_dicts(d, "정의 '#{d.name}'", seen_dicts,
                     dumped < max_dump ? :dump : :count)
          dumped += 1 if has_dicts?(d) && dumped < max_dump

          # 인스턴스의 속성 (Enscape 는 인스턴스에 값을 넣는 경우가 많습니다)
          inst = d.instances.first
          next unless inst
          note_dicts(inst, "  인스턴스 '#{inst.name.to_s.empty? ? d.name : inst.name}'",
                     seen_dicts, dumped <= max_dump ? :dump : :count)
        end

        if seen_dicts.empty?
          say '    (속성 사전이 하나도 없습니다)'
        else
          say ''
          say '    사전 이름별 등장 횟수:'
          seen_dicts.sort_by { |_, v| -v }.first(20).each do |k, v|
            say format('      %-40s %d', k[0, 40], v)
          end
        end
        say ''

        # --- 3. 배치 정보 ---
        say '[3] 조명 후보 인스턴스의 배치 (미터)'
        shown = 0
        cands.each do |d|
          d.instances.each do |inst|
            break if shown >= 10
            t = inst.transformation
            o = t.origin
            zaxis = t.zaxis   # 스포트라이트라면 이 방향이 조사 방향일 가능성이 큽니다
            say format('    %-26s 위치(%.2f, %.2f, %.2f)  Z축(%.2f, %.2f, %.2f)',
                       d.name.to_s[0, 26],
                       o.x * INCH_TO_M, o.y * INCH_TO_M, o.z * INCH_TO_M,
                       zaxis.x, zaxis.y, zaxis.z)
            shown += 1
          end
          break if shown >= 10
        end
        say '' if shown.zero?
        say '    (없음)' if shown.zero?

        say ''
        say '읽는 법'
        say '  속성 사전에 세기·색·각도가 있으면 그대로 읽어 광원을 만들 수 있습니다.'
        say '  이름과 변환행렬뿐이라면 위치·방향만 얻고 나머지는 IRIS 가 기본값을'
        say '  주고 사용자가 조정하는 구조가 됩니다.'

        write_log(out_dir)
      end

      # ---------------------------------------------------------------- 내부

      def light_name?(name)
        LIGHT_PATTERNS.any? { |re| re.match?(name) }
      end

      def has_dicts?(entity)
        dd = (entity.attribute_dictionaries rescue nil)
        dd && dd.count > 0
      rescue StandardError
        false
      end

      def note_dicts(entity, label, seen, mode)
        dd = (entity.attribute_dictionaries rescue nil)
        return unless dd

        dd.each do |dict|
          seen[dict.name.to_s] += 1
          next unless mode == :dump

          say "    #{label} · 사전 '#{dict.name}'"
          begin
            dict.each_pair do |k, v|
              say format('        %-28s = %s', k.to_s[0, 28], short(v))
            end
          rescue StandardError => e
            say "        (읽기 실패: #{e.message})"
          end
        end
      rescue StandardError
        nil
      end

      def short(v)
        s = v.inspect
        s.length > 90 ? "#{s[0, 90]}…" : s
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
        path = File.join(dir, 'lights_probe.txt')
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

puts '[IRIS] 조명 프록시 조사 로드 완료. IRIS::LightsProbe.run 을 실행하세요.'
puts '       읽기 전용입니다 — 모델을 바꾸지 않습니다.'
