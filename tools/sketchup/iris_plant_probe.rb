# encoding: UTF-8
#
# IRIS — 식물이 왜 안 나오는가
#
# 후보가 서로 아주 다른 곳에 있습니다. 하나를 고치면 다른 하나가 남습니다.
#
#   (1) 지오메트리가 .skp 안에 없다 — Enscape 자산 프록시. 실물은 Enscape
#       라이브러리에 있고 모델에는 자리표시만 있습니다. 우리가 뽑을 것이
#       애초에 없습니다.
#   (2) 카메라를 향해 도는 2D 카드 — always_face_camera. 우리는 변환을 그대로
#       구우므로 옆에서 보면 **종잇장이 되어 사라집니다.**
#   (3) 태그가 꺼져 있거나 hidden — 렌더러가 hidden 노드를 건너뜁니다.
#   (4) 알파 텍스처 — 잎 모양이 알파로 뚫린 PNG. 알파를 잃으면 사각형이
#       되고, 재질이 투명하면 통째로 비칩니다.
#
# 이름으로 찾는 것은 이미 한 번 실패했습니다("익명 Group#N"). 그래서 이름은
# 여러 신호 중 하나로만 씁니다. 가장 정보가 많은 것은 **속성 사전 이름 인구
# 조사**입니다 — Enscape 가 무엇을 남겼는지 추측 없이 보여 줍니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_plant_probe.rb'
#
# 읽기 전용입니다. out/sketchup/plant_probe.txt 에 남깁니다.

require 'fileutils'

module IRIS
  module PlantProbe
    WORDS = /나무|수목|식물|화분|조경|잔디|덤불|관목|화단|plant|tree|grass|
             shrub|bush|foliage|veget|flower|ivy|palm|potted|leaf|leaves|
             hedge|bamboo|fern|cactus/ix

    class << self
      def run(out_dir: nil, max_list: 25)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @log = []
        say "모델: #{model.title}"
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        say "정의 #{model.definitions.length}종 · 재질 #{model.materials.length}종 · 태그 #{model.layers.length}개"
        say ''

        census(model)
        face_me(model, max_list)
        tags(model, max_list)
        by_name(model, max_list)
        by_texture(model, max_list)
        assets(model, max_list)
        manifest_check(model)

        say ''
        say '=' * 66
        say '읽는 법'
        say '=' * 66
        say '  [1] 에 Enscape 자산 계열 사전이 보이면 (1)번 — 지오메트리가'
        say '      파일에 없습니다. 이름으로 찾는 것은 의미가 없습니다.'
        say '  [2] 의 개수가 크면 (2)번 — 옆에서 보면 사라집니다.'
        say '  [3] 에 꺼진 태그가 있고 거기 식물이 있으면 (3)번.'
        say '  [6] 이 "매니페스트에 없음"이면 추출 단계에서 빠진 것이고,'
        say '      "있음"이면 우리가 보냈는데 렌더러가 안 그린 것입니다 —'
        say '      그 둘은 고치는 곳이 완전히 다릅니다.'
        finish(out_dir)
      rescue StandardError => e
        say ''
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(10).each { |l| say "   #{l}" }
        finish(out_dir)
      end

      # --- [1] 속성 사전 인구조사 -------------------------------------------
      #
      # 무엇이 있는지 묻지 않고 **있는 것을 셉니다.** Enscape 가 자산을 어떻게
      # 표시하는지 우리는 모릅니다. 이름을 추측하면 또 헛돕니다.
      def census(model)
        say '=' * 66
        say '[1] 속성 사전 이름 (있는 그대로)'
        say '=' * 66
        counts  = Hash.new(0)
        samples = {}
        add = lambda do |ent, where|
          ds = (ent.attribute_dictionaries rescue nil)
          next unless ds
          ds.each do |d|
            k = "#{where}: #{d.name}"
            counts[k] += 1
            samples[k] ||= [(ent.respond_to?(:name) ? ent.name.to_s : ''),
                            (d.keys rescue []).first(6)]
          end
        end

        add.call(model, '모델')
        model.definitions.each do |d|
          add.call(d, '정의')
          (d.instances rescue []).first(3).each { |i| add.call(i, '인스턴스') }
        end
        model.materials.each { |m| add.call(m, '재질') }

        if counts.empty?
          say '    속성 사전이 하나도 없습니다.'
        else
          counts.sort_by { |k, v| [-v, k] }.each do |k, v|
            nm, keys = samples[k]
            say format('    %-46s %5d개', k, v)
            say format('        예: %s  키 %s', nm.to_s[0, 28], keys.inspect[0, 70])
          end
        end
        say ''
      end

      # --- [2] 카메라를 향해 도는 컴포넌트 ----------------------------------
      def face_me(model, max_list)
        say '=' * 66
        say '[2] 카메라를 향해 도는 컴포넌트 (2D 식물의 표식)'
        say '=' * 66
        hits = model.definitions.select do |d|
          b = (d.behavior rescue nil)
          b ? (b.always_face_camera? rescue false) : false
        end
        if hits.empty?
          say '    없습니다. (2)번은 원인이 아닙니다.'
        else
          n = hits.sum { |d| (d.instances.length rescue 0) }
          say "    **#{hits.size}종 / 인스턴스 #{n}개**"
          say '    우리는 변환을 그대로 구우므로 옆에서 보면 종잇장이 됩니다.'
          hits.first(max_list).each do |d|
            say format('      %-40s 인스턴스 %d · 면 %d',
                       d.name.to_s[0, 40], (d.instances.length rescue 0),
                       (d.entities.grep(Sketchup::Face).size rescue 0))
          end
        end
        say ''
      end

      # --- [3] 태그 가시성 ---------------------------------------------------
      def tags(model, max_list)
        say '=' * 66
        say '[3] 꺼진 태그'
        say '=' * 66
        off = model.layers.reject { |l| (l.visible? rescue true) }
        if off.empty?
          say '    전부 켜져 있습니다.'
        else
          say "    **#{off.size}개가 꺼져 있습니다**"
          off.first(max_list).each { |l| say "      #{l.name}" }
          say '    (우리는 태그 가시성을 아직 안 읽습니다 — 켜진 것으로 취급합니다.'
          say '     즉 꺼진 태그는 IRIS 에서 **더 보이지 덜 보이지 않습니다.**)'
        end
        say ''
      end

      # --- [4] 이름 ----------------------------------------------------------
      def by_name(model, max_list)
        say '=' * 66
        say '[4] 이름에 식물 낱말이 든 것'
        say '=' * 66
        defs = model.definitions.select { |d| WORDS.match?(d.name.to_s) }
        lays = model.layers.select { |l| WORDS.match?(l.name.to_s) }
        say "    정의 #{defs.size}종 · 태그 #{lays.size}개"
        defs.first(max_list).each do |d|
          # 맨 위 면만 세면 중첩 그룹이 전부 '면 0'으로 보입니다. 재귀로 셉니다.
          say format('      정의 %-36s 인스턴스 %d · 삼각형 %d',
                     d.name.to_s[0, 36], (d.instances.length rescue 0),
                     model_triangles(d))
        end
        lays.first(max_list).each { |l| say "      태그 #{l.name}  보임=#{(l.visible? rescue '?')}" }
        say ''
      end

      # --- [5] 텍스처 파일명 -------------------------------------------------
      def by_texture(model, max_list)
        say '=' * 66
        say '[5] 텍스처 파일명에 식물 낱말이 든 재질'
        say '=' * 66
        hits = model.materials.select do |m|
          t = (m.texture rescue nil)
          f = (t ? t.filename.to_s : '')
          WORDS.match?(f) || WORDS.match?(m.name.to_s)
        end
        say "    #{hits.size}종"
        hits.first(max_list).each do |m|
          t = (m.texture rescue nil)
          say format('      %-28s alpha %.2f · %s',
                     m.name.to_s[0, 28], (m.alpha rescue 1.0).to_f,
                     t ? basename(t.filename)[0, 34] : '(텍스처 없음)')
        end
        say ''
      end

      # --- [6] 우리가 보낸 것에 들어 있는가 ---------------------------------
      #
      # **여기가 갈림길입니다.** 매니페스트에 없으면 추출에서 빠진 것이고,
      # 있으면 보냈는데 렌더러가 안 그린 것입니다. 고칠 곳이 다릅니다.
      #
      # 면 수를 정의의 **맨 위에서만** 세면 안 됩니다. 식물은 거의 항상
      # 중첩 그룹이라 위에는 면이 0개입니다 — 첫 판에서 그렇게 읽고
      # "면 0"을 늘어놓았습니다. 재귀로 셉니다.
      def manifest_check(model)
        say '=' * 66
        say '[6] 후보의 실체 — 재귀 삼각형 · 매니페스트 포함 여부'
        say '=' * 66
        sc = (defined?(IRIS::Probe) ? IRIS::Probe.last_scene : nil)
        defs = sc ? (sc['definitions'] || {}) : {}
        defs = defs.each_with_object({}) { |d, h| h[d['id']] = d } if defs.is_a?(Array)
        say(sc ? "    매니페스트 정의 #{defs.size}종" :
                 '    프로브를 아직 안 돌렸습니다 — IRIS::Probe.run 뒤에 다시.')

        cands = model.definitions.select do |d|
          next false if (d.instances.length rescue 0).zero?
          WORDS.match?(d.name.to_s) || asset_info(d)
        end
        if cands.empty?
          say '    쓰이고 있는 식물 후보가 없습니다.'
          say ''
          return
        end

        say format('    %-34s %5s %8s %9s %6s', '이름', '인스턴스', '모델삼각형', '매니페스트', '자산')
        cands.sort_by { |d| -(d.instances.length rescue 0) }.first(40).each do |d|
          tri  = model_triangles(d)
          rec  = defs["def_#{d.entityID}"]
          mtri = rec ? manifest_triangles(rec, defs, 0) : nil
          say format('    %-34s %5d %8d %9s %6s',
                     d.name.to_s[0, 34], (d.instances.length rescue 0), tri,
                     rec.nil? ? '**없음**' : mtri.to_s,
                     asset_info(d) ? 'O' : '-')
        end
        say ''
        say '    모델삼각형 = .skp 안에 실제로 있는 것 (재귀)'
        say '    매니페스트 = 우리가 보낸 것 (자식 정의까지 재귀)'
        say '    둘이 같으면 우리는 있는 것을 다 보냈습니다.'
        say ''
      end

      # --- [7] Enscape 자산 --------------------------------------------------
      #
      # Enscape 자산은 **.skp 에 저해상도 대역만** 들어 있고 실물은 Enscape
      # 라이브러리에 있습니다. Enscape 는 렌더할 때 바꿔 끼웁니다. 우리는
      # 그 라이브러리가 없으므로 대역을 그대로 그립니다 — 없어지는 게 아니라
      # **거칠게** 나와야 정상입니다. 정말 안 보인다면 다른 이유가 있습니다.
      def assets(model, max_list)
        say '=' * 66
        say '[7] Enscape 자산 (Enscape.Asset)'
        say '=' * 66
        hits = model.definitions.select { |d| asset_info(d) }
        if hits.empty?
          say '    없습니다.'
          say ''
          return
        end
        used = hits.select { |d| (d.instances.length rescue 0) > 0 }
        say "    #{hits.size}종 (그중 배치된 것 #{used.size}종)"
        say ''
        used.sort_by { |d| -(d.instances.length rescue 0) }.first(max_list).each do |d|
          info = asset_info(d)
          say format('    %-36s 인스턴스 %2d · 삼각형 %5d',
                     d.name.to_s[0, 36], (d.instances.length rescue 0), model_triangles(d))
          say format('        Source=%s  Id=%s', info[0].to_s[0, 24], info[1].to_s[0, 40])
          inst = (d.instances rescue []).first(3)
          inst.each do |i|
            say format('        인스턴스: 태그 %-16s 숨김=%s 보임=%s',
                       (i.layer ? i.layer.name.to_s[0, 16] : '?'),
                       (i.hidden? rescue '?').to_s, (i.visible? rescue '?').to_s)
          end
        end
        say ''
      end

      def asset_info(defn)
        ds = (defn.attribute_dictionaries rescue nil)
        return nil unless ds
        d = (ds['Enscape.Asset'] rescue nil)
        return nil unless d
        [(d['Source'] rescue nil), (d['Id'] rescue nil)]
      rescue StandardError
        nil
      end

      # .skp 안에 실제로 있는 삼각형. 중첩을 따라 내려갑니다.
      def model_triangles(defn, depth = 0)
        return 0 if depth > 12
        n = 0
        (defn.entities rescue []).each do |e|
          case e
          when Sketchup::Face
            m = (e.mesh(0) rescue nil)
            n += m ? m.count_polygons : 1
          when Sketchup::ComponentInstance
            n += model_triangles(e.definition, depth + 1)
          when Sketchup::Group
            dd = (e.definition rescue nil)
            n += model_triangles(dd, depth + 1) if dd
          end
        end
        n
      rescue StandardError
        n
      end

      # 우리가 보낸 것의 삼각형. 자식 정의까지 따라갑니다.
      def manifest_triangles(rec, defs, depth)
        return 0 if depth > 12 || rec.nil?
        n = (rec['meshes'] || []).sum do |m|
          c = m.is_a?(Hash) ? m['count'] : nil
          c && c['i'] ? c['i'] / 3 : 0
        end
        (rec['children'] || []).each do |ch|
          n += manifest_triangles(defs[ch['definition']], defs, depth + 1)
        end
        n
      end

      def basename(path)
        path.to_s.tr('\\', '/').split('/').last.to_s
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
        path = File.join(dir, 'plant_probe.txt')
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

IRIS::PlantProbe.run
