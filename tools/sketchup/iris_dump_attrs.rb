# encoding: UTF-8
#
# IRIS — 속성 원문 덤프
#
# 조사 도구(iris_lights_probe / iris_materials_probe)는 값을 100자에서 자릅니다.
# Enscape 가 남긴 것은 XML 이라 **전체를 봐야** 어떤 필드가 있는지 압니다.
#
#   Enscape.Light    / LightData     — 조명 세기·색·각도·IES
#   Enscape.Material / MaterialData  — 거칠기·금속성·범프
#
# 이 값들을 그대로 읽으면 사용자가 이미 지정해 둔 설정이 IRIS 에서 재현됩니다.
# 추측할 필요가 없어집니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_dump_attrs.rb'
#   IRIS::DumpAttrs.run
#
# 읽기 전용입니다. out/sketchup/attrs_dump.txt 에 저장합니다.

require 'fileutils'

module IRIS
  module DumpAttrs
    class << self

      # per_kind: 종류별로 몇 개까지 원문을 뜰지
      def run(out_dir: nil, per_kind: 2)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say ''

        # --- 조명 ---
        say '=' * 70
        say '조명  (Enscape.Light / LightData)'
        say '=' * 70
        seen = Hash.new(0)
        model.definitions.each do |d|
          dict = (d.attribute_dictionary('Enscape.Light') rescue nil)
          next unless dict
          kind = d.name.to_s.sub(/#\d+$/, '')      # SpotLight#1, #2 -> SpotLight
          next if seen[kind] >= per_kind
          seen[kind] += 1

          say ''
          say "--- #{d.name}  (인스턴스 #{d.count_instances}) ---"
          dict.each_pair { |k, v| say "[#{k}]"; say v.to_s }
        end
        say '' if seen.empty?
        say '(Enscape.Light 사전이 없습니다)' if seen.empty?

        # --- 재질 ---
        say ''
        say '=' * 70
        say '재질  (Enscape.Material / MaterialData)'
        say '=' * 70
        n = 0
        model.materials.each do |m|
          dict = (m.attribute_dictionary('Enscape.Material') rescue nil)
          next unless dict
          n += 1
          break if n > per_kind * 3

          say ''
          say "--- '#{m.name}'  type=#{(m.materialType rescue '?')} alpha=#{format('%.3f', (m.alpha rescue 1.0))} 텍스처=#{!(m.texture rescue nil).nil?} ---"
          dict.each_pair { |k, v| say "[#{k}]"; say v.to_s }
        end
        say ''
        say '(Enscape.Material 사전이 없습니다)' if n.zero?

        # --- 요약 ---
        say ''
        say '=' * 70
        lights = model.definitions.count { |d| (d.attribute_dictionary('Enscape.Light') rescue nil) }
        linst  = model.definitions.select { |d| (d.attribute_dictionary('Enscape.Light') rescue nil) }
                                  .sum(&:count_instances)
        mats   = model.materials.count { |m| (m.attribute_dictionary('Enscape.Material') rescue nil) }
        say "조명 정의 #{lights}종 · 인스턴스 #{linst}개"
        say "Enscape 재질 #{mats} / #{model.materials.size}"

        write_log(out_dir)
      end

      def say(line)
        @log ||= []
        @log << line.to_s
      end

      def write_log(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'attrs_dump.txt')
        File.open(path, 'w:UTF-8') { |f| f.write(@log.join("\n")) }
        puts "[IRIS] 저장: #{path}  (#{@log.size}줄)"
        puts '       콘솔에는 찍지 않습니다 — XML 이 길어서 콘솔이 멈춥니다.'
        { saved: path, lines: @log.size }
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

puts '[IRIS] 속성 덤프 로드 완료. IRIS::DumpAttrs.run 을 실행하세요.'
puts '       읽기 전용이고, 결과는 파일로만 저장합니다.'
