# encoding: UTF-8
#
# IRIS — **SketchUp 에서 안 보이는데 우리는 그리는 것**을 찾습니다
#
# 왜
#   사용자가 잡았습니다: "스케치업에서 엔스케이프 조명이 가려져 있는데
#   IRIS 는 조명을 벽으로 표현하고 있어요."
#
#   우리 추출기는 `inst.hidden?` 만 봅니다(iris_probe.rb:1192). 그런데
#   SketchUp 에서 무언가를 안 보이게 하는 길은 **넷**입니다.
#
#     1. 개체 숨기기      inst.hidden?            ← 우리가 보는 유일한 것
#     2. 태그(레이어) 끄기 inst.layer.visible?     ← **안 봅니다**
#     3. 부모가 숨겨짐     조상 중 하나라도 숨김
#     4. 정의가 숨겨짐     defn.hidden?
#
#   2번이 특히 흔합니다 — Enscape 광원·기구를 전용 태그에 모아 두고 그
#   태그를 끄는 것이 표준 작업 방식입니다. 그러면 SketchUp 에도 Enscape
#   에도 안 보이는데 **우리 화면에만 나타납니다.**
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_hidden_probe.rb'
#
# 읽기 전용입니다. out/sketchup/hidden_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module HiddenProbe
    class << self
      MAX_DEPTH = 12

      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Enscape)
          f = File.join(File.dirname(__FILE__), 'iris_enscape.rb')
          load f if File.exist?(f)
        end

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        say '=' * 92
        say '[1] 태그(레이어) 가시성'
        say '=' * 92
        off = model.layers.reject(&:visible?)
        say format('    태그 %d개 · 그중 꺼짐 %d개', model.layers.size, off.size)
        off.each { |l| say format('      꺼짐: %s', l.name) }
        say ''

        @rows = []
        t0 = Time.now
        walk(model.entities, 0, false, nil)
        say format('트리 순회 %.1f ms · 인스턴스 %d개', (Time.now - t0) * 1000.0, @rows.size)
        say ''

        say '=' * 92
        say '[2] 어떻게 숨겨져 있나 — **우리가 보내는지**와 함께'
        say '=' * 92
        by_self   = @rows.count { |r| r[:self_hidden] }
        by_layer  = @rows.count { |r| !r[:self_hidden] && r[:layer_off] }
        by_parent = @rows.count { |r| !r[:self_hidden] && !r[:layer_off] && r[:parent_hidden] }
        by_defn   = @rows.count { |r| !r[:self_hidden] && !r[:layer_off] && !r[:parent_hidden] && r[:defn_hidden] }
        vis       = @rows.size - by_self - by_layer - by_parent - by_defn
        say format('    보임                       %6d', vis)
        say format('    개체 숨김  (우리도 건너뜀) %6d   <- inst.hidden?', by_self)
        say format('    **태그 꺼짐 (우리는 그림)**%6d   <- inst.layer.visible?', by_layer)
        say format('    **부모 숨김 (우리는 그림)**%6d', by_parent)
        say format('    **정의 숨김 (우리는 그림)**%6d', by_defn)
        say ''

        leak = @rows.select { |r| !r[:self_hidden] && (r[:layer_off] || r[:parent_hidden] || r[:defn_hidden]) }
        if leak.empty?
          say '    새는 것이 없습니다.'
        else
          say '=' * 92
          say "[3] **새는 것** — SketchUp 에 안 보이는데 우리는 보냅니다 (#{leak.size}개)"
          say '=' * 92
          by_def = Hash.new { |h, k| h[k] = [] }
          leak.each { |r| by_def[r[:defn]] << r }
          by_def.sort_by { |_, v| -v.size }.first(30).each do |name, list|
            r = list.first
            why = []
            why << '태그꺼짐'   if r[:layer_off]
            why << '부모숨김'   if r[:parent_hidden]
            why << '정의숨김'   if r[:defn_hidden]
            say format('    %-40s %5d개  %s  태그=%s%s',
                       clip(name, 40), list.size, why.join('+'),
                       clip(r[:layer].to_s, 18),
                       r[:enscape] ? "  [Enscape #{r[:enscape]}]" : '')
          end
        end

        say ''
        say '  읽는 법'
        say '    [2] 의 굵은 세 줄이 0 이 아니면 **우리 화면에만 있는 물체**입니다.'
        say '    오류가 안 나므로 화면을 나란히 놓기 전에는 모릅니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      def walk(entities, depth, parent_hidden, parent_layer_off)
        return if depth > MAX_DEPTH
        entities.each do |e|
          next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          d = (e.definition rescue nil)
          next unless d

          self_hidden = (e.hidden? rescue false)
          layer       = (e.layer rescue nil)
          layer_off   = layer ? !layer.visible? : false
          defn_hidden = (d.respond_to?(:hidden?) ? (d.hidden? rescue false) : false)

          ens = nil
          ens = 'light' if (IRIS::Enscape.light(d) rescue nil)
          ens = 'asset' if ens.nil? && (IRIS::Enscape.asset(d) rescue nil)

          @rows << {
            defn:          (d.name.to_s.empty? ? "def_#{d.entityID}" : d.name.to_s),
            layer:         layer ? layer.name : nil,
            self_hidden:   self_hidden,
            layer_off:     layer_off || parent_layer_off,
            parent_hidden: parent_hidden,
            defn_hidden:   defn_hidden,
            enscape:       ens,
          }

          walk(d.entities, depth + 1,
               parent_hidden || self_hidden,
               layer_off || parent_layer_off)
        end
      end

      def clip(t, n) = t.to_s[0, n]

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def finish(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'hidden_probe.txt')
        File.open(path, 'w:UTF-8') { |f| @log.each { |l| f.puts l } }
        puts "저장: #{path}"
        nil
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

IRIS::HiddenProbe.run
