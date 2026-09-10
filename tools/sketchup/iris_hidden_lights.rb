# encoding: UTF-8
#
# IRIS — 숨겨진 Enscape 조명
#
# 무엇이 문제인가
#   렌더러는 hidden 노드를 통째로 건너뜁니다(SceneBuilder.cpp:409). 조명
#   프록시가 숨겨져 있으면 **그 광원이 아예 안 만들어집니다.**
#
#   포르쉐 성수 모델에서 `Enscape.RectangularLight#4` 가 배치 43개 전부
#   숨김으로 나왔습니다. 작성자가 껐다면 맞는 동작이고, Enscape 가 자동으로
#   숨긴 것이라면 우리가 광원을 잃고 있는 것입니다.
#
#   둘을 화면으로 가리기 전에 **얼마나 손해인지**부터 잽니다. 전체 광속의
#   0.03% 라면 답을 낼 필요가 없습니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_hidden_lights.rb'
#
# 읽기 전용입니다. out/sketchup/hidden_lights.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module HiddenLights
    class << self
      def run(out_dir: nil, max_list: 20)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Enscape)
          return puts('[IRIS] iris_reload.rb 를 먼저 실행하십시오.')
        end

        @log  = []
        @rows = []
        @spec = {}   # defn.entityID => 조명 파라미터 (한 번만 파싱)

        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        walk(model.entities, 0, '')

        if @rows.empty?
          say 'Enscape 조명 배치를 찾지 못했습니다.'
          return finish(out_dir)
        end

        total  = @rows.size
        hidden = @rows.count { |r| r[:hidden] }
        lm_all = @rows.sum { |r| r[:lm] }
        lm_hid = @rows.select { |r| r[:hidden] }.sum { |r| r[:lm] }

        say '=' * 70
        say '[1] 얼마나 손해인가'
        say '=' * 70
        say format('    조명 배치   %6d개 중 숨김 %d개 (%.1f%%)',
                   total, hidden, 100.0 * hidden / total)
        say format('    광속        %s lm 중 숨김 %s lm (%.3f%%)',
                   comma(lm_all), comma(lm_hid),
                   lm_all > 0 ? 100.0 * lm_hid / lm_all : 0.0)
        say ''
        say '    읽는 법'
        say '      1% 미만이면 화면에 안 보입니다 — 답을 낼 필요가 없습니다.'
        say '      크면 Enscape 가 자동으로 숨긴 것인지 가려야 합니다.'
        say ''

        say '=' * 70
        say '[2] 숨겨진 것들 (정의별)'
        say '=' * 70
        by_def = Hash.new { |h, k| h[k] = { n: 0, lm: 0.0, kind: nil, path: nil } }
        @rows.select { |r| r[:hidden] }.each do |r|
          e = by_def[r[:name]]
          e[:n]    += 1
          e[:lm]   += r[:lm]
          e[:kind] ||= r[:kind]
          e[:path] ||= r[:path]
        end
        if by_def.empty?
          say '    없습니다.'
        else
          say format('    %-32s %6s %6s %14s', '정의', '종류', '개수', '광속 lm')
          by_def.sort_by { |_, v| -v[:lm] }.first(max_list).each do |nm, v|
            say format('    %-32s %6s %6d %14s', nm[0, 32], v[:kind].to_s, v[:n], comma(v[:lm]))
            say format('        경로 %s', v[:path].to_s[0, 90])
          end
        end
        say ''

        say '=' * 70
        say '[3] 견줌 — 보이는 것들 (정의별 상위)'
        say '=' * 70
        vis = Hash.new { |h, k| h[k] = { n: 0, lm: 0.0, kind: nil } }
        @rows.reject { |r| r[:hidden] }.each do |r|
          e = vis[r[:name]]
          e[:n]  += 1
          e[:lm] += r[:lm]
          e[:kind] ||= r[:kind]
        end
        say format('    %-32s %6s %6s %14s', '정의', '종류', '개수', '광속 lm')
        vis.sort_by { |_, v| -v[:lm] }.first(8).each do |nm, v|
          say format('    %-32s %6s %6d %14s', nm[0, 32], v[:kind].to_s, v[:n], comma(v[:lm]))
        end
        say ''
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      # 숨은 가지 **안쪽까지** 셉니다. 렌더러는 건너뛰지만, 우리는 무엇을
      # 잃고 있는지 알아야 하니까요.
      def walk(entities, depth, path)
        return if depth > 14
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          d = (e.definition rescue nil)
          next unless d
          nm  = e.name.to_s.empty? ? d.name.to_s : e.name.to_s
          sub = "#{path}/#{nm}"
          hid = (e.hidden? rescue false)

          spec = light_of(d)
          if spec
            @rows << { name: d.name.to_s, kind: spec['kind'], lm: spec['lumens'].to_f,
                       hidden: hid, path: sub }
          end
          # 조명 정의 안으로는 안 내려갑니다 — 프록시 지오메트리뿐입니다.
          walk(d.entities, depth + 1, sub) unless spec
        end
      end

      # 정의당 한 번만 파싱합니다. 안 그러면 인스턴스 수만큼 XML 을 다시 읽습니다.
      def light_of(defn)
        key = defn.entityID
        return @spec[key] if @spec.key?(key)
        @spec[key] = (IRIS::Enscape.light(defn) rescue nil)
      end

      def comma(v)
        v.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
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
        path = File.join(dir, 'hidden_lights.txt')
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

IRIS::HiddenLights.run
