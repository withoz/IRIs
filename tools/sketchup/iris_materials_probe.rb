# encoding: UTF-8
#
# IRIS — 재질 속성 조사
#
# 왜 만드는가
#   "재질이 섬세하지 않다"는 보고. 맞습니다 — 지금은 모든 재질이
#   roughness 0.5 / metalness 0 고정입니다. SketchUp 자체는 PBR 파라미터를
#   주지 않기 때문입니다.
#
#   그런데 이 모델은 **Enscape 로 작업된 것**입니다(SpotLight 프록시 29개).
#   Enscape·V-Ray·Twinmotion 같은 도구는 재질 설정을 SketchUp 의
#   **속성 사전(AttributeDictionary)** 에 저장합니다.
#
#   **사용자가 이미 지정해 둔 값이 모델 안에 있을 수 있습니다.**
#   그렇다면 추측할 필요 없이 그대로 읽으면 됩니다 — 조명 프록시와 같은 발상입니다.
#
#   추측으로 휴리스틱을 만들기 전에 **무엇이 있는지부터** 봅니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_materials_probe.rb'
#   IRIS::MaterialsProbe.run              # 속성이 있는 재질 위주
#   IRIS::MaterialsProbe.run(all: true)   # 전부
#
# 읽기 전용입니다. 결과는 out/sketchup/materials_probe.txt 에도 남습니다.

require 'fileutils'

module IRIS
  module MaterialsProbe
    class << self

      def run(out_dir: nil, all: false, max_dump: 12)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        mats = model.materials.to_a
        say ''
        say "모델: #{model.title}"
        say "재질 #{mats.size}개"
        say ''

        # --- 1. 속성 사전 분포 ---
        dict_counts = Hash.new(0)
        key_counts  = Hash.new(0)
        with_dicts  = []

        mats.each do |m|
          dd = (m.attribute_dictionaries rescue nil)
          next unless dd && dd.count > 0
          with_dicts << m
          dd.each do |d|
            dict_counts[d.name.to_s] += 1
            begin
              d.each_key { |k| key_counts["#{d.name}/#{k}"] += 1 }
            rescue StandardError
              nil
            end
          end
        end

        say "[1] 속성 사전이 있는 재질: #{with_dicts.size} / #{mats.size}"
        if dict_counts.empty?
          say '    (없음 — 이 모델의 재질에는 외부 도구가 남긴 값이 없습니다)'
          say '    그렇다면 거칠기·금속성은 이름 규칙이나 IRIS 자체 UI 로 정해야 합니다.'
        else
          say '    사전 이름별:'
          dict_counts.sort_by { |_, v| -v }.each { |k, v| say format('      %-44s %d', k[0, 44], v) }
          say ''
          say '    키별 (상위 40):'
          key_counts.sort_by { |_, v| -v }.first(40).each { |k, v| say format('      %-52s %d', k[0, 52], v) }
        end
        say ''

        # --- 2. 실제 값 덤프 ---
        say '[2] 값 예시 — 여기에 거칠기·금속성·범프가 있으면 그대로 읽습니다'
        (all ? mats : with_dicts).first(max_dump).each do |m|
          say ''
          say "    재질 '#{m.name}'  (type=#{(m.materialType rescue '?')}, alpha=#{format('%.3f', (m.alpha rescue 1.0))}, 텍스처=#{!(m.texture rescue nil).nil?})"
          dd = (m.attribute_dictionaries rescue nil)
          if dd.nil? || dd.count.zero?
            say '        (속성 없음)'
            next
          end
          dd.each do |d|
            say "        사전 '#{d.name}'"
            begin
              d.each_pair { |k, v| say format('            %-30s = %s', k.to_s[0, 30], short(v)) }
            rescue StandardError => e
              say "            (읽기 실패: #{e.message})"
            end
          end
        end
        say ''

        # --- 3. 이름 규칙이 쓸 만한지 ---
        say '[3] 이름 규칙 후보 (속성이 없을 때의 차선책)'
        pats = {
          '금속' => /metal|steel|alum|brass|copper|chrome|스테인|금속|알루미/i,
          '거울' => /mirror|거울/i,
          '유리' => /glass|유리/i,
          '나무' => /wood|timber|oak|walnut|목재|나무/i,
          '천'   => /fabric|cloth|textile|carpet|rug|천|패브릭|카펫/i,
          '무광' => /matte|matt|무광/i,
        }
        pats.each do |label, re|
          hit = mats.select { |m| re.match?(m.name.to_s) }
          next if hit.empty?
          say format('    %-4s %2d개  예: %s', label, hit.size,
                     hit.first(4).map { |m| m.name.to_s[0, 18] }.join(', '))
        end
        say ''
        say '읽는 법'
        say '  [1]에 사전이 있으면 그 값을 그대로 읽는 것이 정답입니다.'
        say '  없으면 [3]의 이름 규칙이 차선이고, 그마저 빈약하면'
        say '  IRIS 자체 재질 UI 가 필요합니다.'

        write_log(out_dir)
      end

      def short(v)
        s = v.inspect
        s.length > 100 ? "#{s[0, 100]}…" : s
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
        path = File.join(dir, 'materials_probe.txt')
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

puts '[IRIS] 재질 속성 조사 로드 완료. IRIS::MaterialsProbe.run 을 실행하세요.'
puts '       읽기 전용입니다 — 모델을 바꾸지 않습니다.'
