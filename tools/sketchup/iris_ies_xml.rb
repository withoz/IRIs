# encoding: UTF-8
#
# IRIS — Enscape IES 조명의 XML 을 통째로 봅니다 (배광 데이터만 빼고)
#
# 왜
#   배광의 0도 방위가 프록시의 어느 축인지 몰라서, 지금은 **로컬 +X 라고
#   가정**하고 있습니다. 가정을 지우려면 먼저 **Enscape 가 무엇을
#   적어 두는지** 다 봐야 합니다. 회전 필드가 있으면 그게 답입니다 —
#   가정이 아니라 저작자가 남긴 값이 됩니다.
#
#   <IesData> 는 수십 KB 짜리 base64 라 길이만 적고 건너뜁니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_ies_xml.rb'
#
# 읽기 전용입니다. out/sketchup/ies_xml.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module IesXml
    class << self
      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        n = 0
        model.definitions.each do |d|
          dict = (d.attribute_dictionary('Enscape.Light') rescue nil)
          next unless dict
          xml = dict['LightData'].to_s
          next if xml.empty?
          n += 1
          say '=' * 74
          say format('%s   인스턴스 %d', d.name.to_s, (d.instances.length rescue 0))
          say '=' * 74

          # 사전에 LightData 말고 또 무엇이 있는가.
          keys = (dict.keys rescue [])
          say format('  Enscape.Light 키: %s', keys.inspect)
          keys.each do |k|
            next if k == 'LightData'
            v = dict[k]
            say format('    %s = %s', k, v.inspect[0, 200])
          end

          # 정의에 붙은 다른 사전들도 봅니다 — 회전이 거기 있을 수 있습니다.
          others = (d.attribute_dictionaries rescue nil)
          if others
            others.each do |ad|
              next if ad.name == 'Enscape.Light'
              say format('  [%s] %s', ad.name, (ad.keys rescue []).inspect[0, 300])
            end
          end

          say '  --- LightData (IesData 는 길이만) ---'
          shown = xml.gsub(%r{<IesData>(.*?)</IesData>}m) do
            "<IesData>…#{Regexp.last_match(1).to_s.length} chars…</IesData>"
          end
          shown.split("\n").each { |l| say "    #{l.rstrip}" }

          # 인스턴스에 붙은 사전도 봅니다. 회전을 인스턴스마다 줄 수 있다면
          # 거기 있어야 합니다.
          inst = (d.instances.first rescue nil)
          if inst
            ids = (inst.attribute_dictionaries rescue nil)
            say '  --- 첫 인스턴스의 사전 ---'
            if ids.nil?
              say '    없음'
            else
              ids.each do |ad|
                say format('    [%s] %s', ad.name, (ad.keys rescue []).inspect[0, 300])
                (ad.keys rescue []).each do |k|
                  say format('       %s = %s', k, ad[k].inspect[0, 200])
                end
              end
            end
          end
          say ''
        end

        say "IES/조명 정의 #{n}종을 찍었습니다." if n.positive?
        say '조명 정의를 찾지 못했습니다.' if n.zero?
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
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
        path = File.join(dir, 'ies_xml.txt')
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

IRIS::IesXml.run
