# encoding: UTF-8
#
# IRIS — Enscape 범프가 **얼마나 있고 어떤 꼴인가** (11번 (d) 준비)
#
# 왜
#   Enscape 는 재질에 `BumpTexture` + `BumpAmount` + `BumpMapType` 를
#   남겨 두는데 우리는 전혀 안 읽습니다. 잔디·아스팔트·벽돌·콘크리트가
#   전부 매끈한 판으로 나옵니다.
#
#   붙이기 전에 **얼마나 듣는 일인지** 먼저 잽니다. 세 가지가 갈립니다:
#
#     BumpMapType = NORMAL         이미 노멀맵 — 변환 없이 바로 씁니다
#                 = BUMP/DISPLACEMENT  높이맵 — 노멀맵으로 바꿔야 합니다
#     BumpTexture 파일이 디퓨즈와 같은가  같으면 새로 내보낼 것이 없습니다
#     그 파일이 **지금 존재하는가**       Enscape 는 임시 폴더 경로를 적기도 합니다
#
#   마지막 항목이 특히 중요합니다. 경로만 있고 파일이 없으면 그 재질은
#   아무리 배선을 놓아도 범프가 안 나옵니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_bump_probe.rb'
#
# 읽기 전용입니다. out/sketchup/bump_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module BumpProbe
    class << self
      MAX_DEPTH = 12

      def run(out_dir: nil)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unless defined?(IRIS::Enscape)
          f = File.join(File.dirname(__FILE__), 'iris_enscape.rb')
          load f if File.exist?(f)
        end
        return puts('[IRIS] iris_enscape.rb 를 못 올렸습니다.') unless defined?(IRIS::Enscape)

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say ''

        # 면 수는 화면에서 차지하는 몫의 대리 지표입니다. 범프가 1면짜리
        # 재질에만 있으면 붙여도 안 보입니다.
        use = Hash.new(0)
        t0 = Time.now
        walk(model.entities, 0, use)
        say format('트리 순회 %.1f ms', (Time.now - t0) * 1000.0)
        say ''

        rows = []
        with_enscape = 0
        model.materials.each do |m|
          xml = IRIS::Enscape.send(:dict_value, m, 'Enscape.Material', 'MaterialData')
          next unless xml
          with_enscape += 1
          bt = texture_block(xml, 'BumpTexture')
          dt = texture_block(xml, 'DiffuseTexture')
          next unless bt || (IRIS::Enscape.send(:num, xml, 'BumpAmount').to_f > 0.0)
          rows << {
            name:   m.display_name.to_s,
            faces:  use[m.entityID],
            amount: IRIS::Enscape.send(:num, xml, 'BumpAmount').to_f,
            nmi:    IRIS::Enscape.send(:num, xml, 'NormalMapIntensity').to_f,
            type:   IRIS::Enscape.send(:str, xml, 'BumpMapType').to_s,
            bpath:  bt && bt[:path],
            dpath:  dt && dt[:path],
            inv:    bt && bt[:inverted],
            same:   (bt && dt && bt[:path] == dt[:path]),
            exists: bt && bt[:path] && File.exist?(bt[:path]),
            # **결정적인 칸.** Enscape 가 적어 둔 경로는 남의 컴퓨터·임시
            # 폴더라 거의 안 열립니다. 그런데 범프가 디퓨즈와 같은 파일이면
            # 그 그림은 .skp 안에 있고 우리가 이미 내보내고 있습니다.
            sutex:  !(m.texture rescue nil).nil?,
          }
        end

        say '=' * 100
        say "[1] 범프가 있는 재질 — Enscape 설정이 있는 재질 #{with_enscape}개 중 #{rows.size}개"
        say '=' * 100
        if rows.empty?
          say '    없습니다.'
        else
          say format('    %-24s %7s %7s %-13s %5s %5s %5s %5s',
                     '이름', '면', '범프', '종류', '디퓨즈같음', '파일있음', 'SU텍스처', '반전')
          rows.sort_by { |r| -r[:faces] }.each do |r|
            say format('    %-24s %7d %7.3f %-13s %5s %5s %5s %5s',
                       clip(r[:name], 24), r[:faces], r[:amount],
                       clip(r[:type], 13),
                       r[:same].nil? ? '-' : (r[:same] ? 'O' : 'X'),
                       r[:exists].nil? ? '-' : (r[:exists] ? 'O' : 'X'),
                       r[:sutex] ? 'O' : '**X**',
                       r[:inv].nil? ? '-' : (r[:inv] ? 'O' : 'X'))
          end
        end
        say ''

        say '=' * 100
        say '[2] 종류별 — 무엇을 만들어야 하나'
        say '=' * 100
        kinds = Hash.new(0)
        rows.each { |r| kinds[r[:type].empty? ? '(없음)' : r[:type]] += 1 }
        kinds.sort_by { |_, v| -v }.each { |k, v| say format('    %-16s %d개', k, v) }
        say ''
        say '    NORMAL            변환 없이 바로 노멀맵으로 씁니다'
        say '    BUMP/DISPLACEMENT 높이맵 -> 노멀맵 변환이 필요합니다'
        say ''

        say '=' * 100
        say '[3] 파일 경로 (앞 6개)'
        say '=' * 100
        rows.sort_by { |r| -r[:faces] }.first(6).each do |r|
          say format('    %-20s %s', clip(r[:name], 20), clip(r[:bpath].to_s, 72))
        end
        say ''
        say '  읽는 법'
        say '    파일있음 X  — Enscape 가 적어 둔 경로에 그림이 없습니다(남의 컴퓨터·임시 폴더).'
        say '    디퓨즈같음 O + SU텍스처 O  — **그 그림은 .skp 안에 있습니다.** 우리가'
        say '                                 이미 내보내는 PNG 를 높이맵으로 쓰면 됩니다.'
        say '    SU텍스처 **X**            — 쓸 그림이 아예 없습니다. 이 재질은 범프를 못 냅니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      # <BumpTexture><Filepath>..</Filepath><IsInverted>..</IsInverted>..</BumpTexture>
      def texture_block(xml, tag)
        block = xml[%r{<#{tag}>(.*?)</#{tag}>}m]
        return nil unless block
        inner = Regexp.last_match(1)
        path = inner[%r{<Filepath>([^<]*)</Filepath>}] ? Regexp.last_match(1).to_s : nil
        return nil if path.nil? || path.empty?
        { path: path,
          inverted: inner[%r{<IsInverted>([^<]*)</IsInverted>}] &&
                    Regexp.last_match(1).to_s.strip == 'true' }
      rescue StandardError
        nil
      end

      def walk(entities, depth, use)
        return if depth > MAX_DEPTH
        entities.each do |e|
          case e
          when Sketchup::Face
            [e.material, e.back_material].compact.uniq.each { |m| use[m.entityID] += 1 }
          when Sketchup::ComponentInstance, Sketchup::Group
            d = (e.definition rescue nil)
            walk(d.entities, depth + 1, use) if d
          end
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
        path = File.join(dir, 'bump_probe.txt')
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

IRIS::BumpProbe.run
