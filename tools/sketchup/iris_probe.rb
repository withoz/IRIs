# encoding: UTF-8
#
# IRIS — SketchUp 지오메트리 덤프 · 라이브 링크 실현성 프로브
# Phase 0-2 과제 4 / 대상: SketchUp 2026 (2017+ 호환)
#
# 사용법 — SketchUp Ruby 콘솔 (창 > Ruby 콘솔):
#   load 'E:/IRIS/tools/sketchup/iris_probe.rb'
#   IRIS::Probe.run                 # 측정 + JSON 덤프
#   IRIS::Probe.run(dump: false)    # 측정만
#   IRIS::Probe.watch               # 변경 감지 옵저버 부착 (증분 동기화 테스트)
#   IRIS::Probe.flush               # 감지된 델타 출력
#   IRIS::Probe.unwatch
#
# 이 스크립트가 답하려는 질문:
#   1. 렌더러가 필요한 데이터(정점·법선·UV·머티리얼·변환)를 전부 뽑을 수 있는가
#   2. 인스턴싱 구조를 그대로 살릴 수 있는가 (= BLAS 재사용률)
#   3. persistent_id로 증분 델타 추적이 가능한가
#   4. 전체 추출에 몇 ms 걸리는가 (= 최초 로딩 비용의 하한)
#
# 좌표계: SketchUp 원본 유지 — Z-up, 우수 좌표계. 단위만 인치→미터 변환.
#         Y-up 변환은 렌더러 측 임포터의 책임으로 남긴다.

require 'json'
require 'fileutils'

module IRIS
  module Probe

    VERSION   = '0.1.0'
    INCH_TO_M = 0.0254

    # Face#mesh 비트마스크 (1: UVQ front, 2: UVQ back, 4: normals)
    # 버전별 상수 차이 가능성이 있어 값을 신뢰하지 않고 결과를 런타임에 검증한다.
    MESH_FLAGS = 1 | 2 | 4

    # 진행 표시 주기(면 단위). Ruby가 메인 스레드를 잡고 있어
    # 상태바 갱신만이 유일하게 살아 있는 피드백 경로다.
    PROGRESS_EVERY = 2000

    # 삼각형 예산 초과 시 탈출용
    class BudgetExceeded < StandardError; end

    class << self

      # ---------------------------------------------------------------- 실행

      # limit: 삼각형 예산. 초과하면 즉시 중단하고 거기까지의 통계만 낸다.
      #        대형 모델에서 "끝나긴 하는가"를 먼저 확인할 때 쓴다.
      def run(dump: true, out_dir: nil, pretty: false, limit: nil, textures: true)
        model = Sketchup.active_model
        unless model
          puts '[IRIS] 활성 모델이 없습니다.'
          return nil
        end

        reset!
        @limit = limit
        t0 = Time.now

        # 텍스처는 지오메트리 수집 중에 뽑히므로 디렉터리를 먼저 만들어 둔다.
        if textures
          begin
            # ⚠ 모델별로 나눈다. 텍스처 파일명이 mat_<entityID> 인데 entityID 는
            # 모델마다 다시 매겨지므로, 한 폴더에 섞으면 다른 모델의 텍스처를
            # 재사용하는 사고가 난다.
            @texture_rel = "textures/#{sanitize(model.title)}"
            @texture_dir = File.join(out_dir || default_out_dir, 'textures', sanitize(model.title))
            FileUtils.mkdir_p(@texture_dir)
          rescue StandardError => e
            puts "텍스처 폴더 생성 실패, 텍스처 없이 진행합니다: #{e.message}"
            @texture_dir = nil
          end
        end

        @caps = probe_capabilities(model)

        scene = nil
        begin
          scene = build_scene(model)
        rescue BudgetExceeded
          @truncated = true
        ensure
          Sketchup.status_text = ''
        end
        @elapsed = Time.now - t0

        path = nil
        if dump && scene
          dir = out_dir || default_out_dir
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{sanitize(model.title)}.iris.json")
          t1 = Time.now
          # 정점 배열이 그대로 텍스트가 되므로 기본은 compact.
          # 눈으로 확인할 때만 pretty: true.
          json = pretty ? JSON.pretty_generate(scene) : JSON.generate(scene)
          File.open(path, 'w:UTF-8') { |f| f.write(json) }
          @write_elapsed = Time.now - t1
        end

        report(model, path)

        # 씬 전체를 반환하면 Ruby 콘솔이 그 해시를 통째로 에코하다가 몇 분간 얼어붙는다.
        # (정점 15만 개가 전부 텍스트가 된다.) 요약만 돌려주고 씬은 last_scene으로 꺼낸다.
        @scene = scene
        {
          'stats'     => @stats,
          'elapsed_s' => @elapsed.round(3),
          'truncated' => @truncated,
          'dump'      => path,
          'report'    => File.join(default_out_dir, 'report.txt'),
        }
      end

      # run이 만든 씬 해시. 콘솔에 그대로 찍지 말 것.
      def last_scene
        @scene
      end

      # ------------------------------------------------------- 규모 사전 조사

      # 지오메트리 버퍼를 전혀 만들지 않고 규모만 센다.
      # Face#mesh 호출도 생략하고 정점 수로 삼각형을 추정하므로 훨씬 빠르다.
      # run이 얼마나 걸릴지 가늠할 때 먼저 이걸 돌린다.
      def scan
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        @scan = { faces: 0, tris_est: 0, instances: 0, defs: {}, edges: 0, depth: 0 }
        t0 = Time.now
        begin
          scan_entities(model.entities, 0)
        ensure
          Sketchup.status_text = ''
        end
        dt = Time.now - t0

        puts ''
        puts '--- IRIS 규모 사전 조사 ---'
        puts " 면            : #{@scan[:faces]}"
        puts " 삼각형(추정)  : #{@scan[:tris_est]}"
        puts " 인스턴스      : #{@scan[:instances]}"
        puts " 고유 정의     : #{@scan[:defs].size}"
        puts " 최대 중첩깊이 : #{@scan[:depth]}"
        puts format(' 조사 시간     : %.2f 초', dt)
        puts ''
        puts ' run()은 면마다 mesh()를 부르므로 이보다 훨씬 오래 걸립니다.'
        puts ' 삼각형이 100만을 넘으면 limit를 걸고 시작하십시오:'
        puts '   IRIS::Probe.run(dump: false, limit: 200_000)'
        puts ''
        # defs는 정의 ID 해시라 그대로 반환하면 콘솔이 길게 에코한다. 개수만 준다.
        { faces: @scan[:faces], tris_est: @scan[:tris_est],
          instances: @scan[:instances], defs: @scan[:defs].size, depth: @scan[:depth] }
      end

      def scan_entities(entities, depth)
        @scan[:depth] = depth if depth > @scan[:depth]
        entities.each do |e|
          case e
          when Sketchup::Face
            @scan[:faces] += 1
            # 볼록면 가정한 추정치. 구멍 있는 면은 과소평가된다.
            @scan[:tris_est] += [(e.vertices.length - 2), 1].max
            if (@scan[:faces] % PROGRESS_EVERY).zero?
              Sketchup.status_text = "IRIS 사전조사… 면 #{@scan[:faces]}"
            end
          when Sketchup::ComponentInstance, Sketchup::Group
            @scan[:instances] += 1
            defn = e.is_a?(Sketchup::Group) ? group_definition(e) : e.definition
            next unless defn
            key = defn.entityID
            next if @scan[:defs].key?(key)   # 정의당 1회만 하강
            @scan[:defs][key] = true
            scan_entities(defn.entities, depth + 1)
          end
        end
      end

      # ------------------------------------------------ 증분 동기화 테스트

      def watch
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model
        unwatch

        @delta = []
        @entity_watcher = EntityWatcher.new(@delta)
        @tx_watcher     = TxWatcher.new(@delta)

        model.entities.add_observer(@entity_watcher)
        model.add_observer(@tx_watcher)

        puts '[IRIS] 옵저버 부착됨. 모델을 편집한 뒤 IRIS::Probe.flush 를 호출하세요.'
        puts '       (최상위 entities 한정 — 그룹/컴포넌트 내부 편집은 별도 부착 필요)'
        true
      end

      def unwatch
        model = Sketchup.active_model
        return false unless model
        model.entities.remove_observer(@entity_watcher) if @entity_watcher
        model.remove_observer(@tx_watcher) if @tx_watcher
        @entity_watcher = nil
        @tx_watcher = nil
        true
      rescue StandardError => e
        puts "[IRIS] 옵저버 해제 실패: #{e.message}"
        false
      end

      def flush
        d = @delta || []
        puts ''
        puts "=== 감지된 델타 #{d.size}건 ==="
        d.each do |r|
          puts format('  %-10s entityID=%-10s persistent_id=%s',
                      r[:op], r[:entity_id].to_s, r[:pid].nil? ? '(조회 불가)' : r[:pid].to_s)
        end
        orphan = d.count { |r| r[:op] == 'removed' && r[:pid].nil? }
        if orphan > 0
          puts ''
          puts "  ! 삭제 #{orphan}건은 persistent_id를 얻지 못했습니다."
          puts '    onElementRemoved 콜백은 entityID(Integer)만 전달합니다.'
          puts '    => 렌더러 측에서 entityID -> persistent_id 매핑을 자체 유지해야 합니다.'
        end
        @delta = []
        d
      end

      # ---------------------------------------------------------- 씬 수집

      def build_scene(model)
        root_children = []
        root_meshes   = collect_entities(model.entities, root_children)

        @definitions.each_value do |d|
          d['instance_count'] = @instance_count[d['id']] || 0
        end

        {
          'format'       => 'iris.sketchup.scene',
          'version'      => VERSION,
          'unit'         => 'meter',
          'up_axis'      => 'z',
          'handedness'   => 'right',
          'source'       => {
            'app'   => "SketchUp #{Sketchup.version}",
            'title' => model.title,
            'file'  => model.path,
          },
          'generated'    => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
          'capabilities' => @caps,
          'materials'    => @materials.values,
          'views'        => (@scene_views_list = collect_views(model)),
          'definitions'  => @definitions,
          'root'         => { 'meshes' => root_meshes, 'children' => root_children },
          'stats'        => @stats,
        }
      end

      # entities를 훑어 면은 메시로 누적하고, 인스턴스는 children에 추가한다.
      def collect_entities(entities, children)
        buckets = {}
        entities.each do |e|
          case e
          when Sketchup::Face
            accumulate_face(e, buckets)
          when Sketchup::ComponentInstance
            children << instance_entry(e, e.definition)
          when Sketchup::Group
            defn = group_definition(e)
            if defn
              children << instance_entry(e, defn)
            else
              @stats['groups_skipped'] += 1
            end
          end
        end
        finalize_buckets(buckets)
      end

      def instance_entry(inst, defn)
        @stats['instances'] += 1
        key = ensure_definition(defn)
        @instance_count[key] = (@instance_count[key] || 0) + 1
        {
          'definition'    => key,
          'entity_id'     => inst.entityID,
          'persistent_id' => safe_pid(inst),
          'name'          => (inst.name rescue ''),
          'transform'     => transform_to_a(inst.transformation),
          'material'      => (inst.material ? register_material(inst.material) : nil),
          'layer'         => (inst.layer ? inst.layer.name : nil),
          'hidden'        => (inst.hidden? rescue false),
        }
      end

      # 정의는 한 번만 추출한다. 이것이 인스턴싱 이득의 실체.
      def ensure_definition(defn)
        key = "def_#{defn.entityID}"
        return key if @definitions.key?(key)

        # 자리 예약 = 순환 참조 가드
        @definitions[key] = {
          'id' => key, 'name' => defn.name, 'meshes' => [], 'children' => [],
        }
        children = []
        meshes   = collect_entities(defn.entities, children)

        @definitions[key]['meshes']        = meshes
        @definitions[key]['children']      = children
        @definitions[key]['persistent_id'] = safe_pid(defn)
        @definitions[key]['is_group']      = (defn.group? rescue false)
        @stats['definitions'] += 1
        key
      end

      def group_definition(group)
        group.respond_to?(:definition) ? group.definition : nil
      rescue StandardError
        nil
      end

      # ------------------------------------------------------------ 지오메트리

      # 머티리얼별로 버킷을 나눈다 = 드로우콜/BLAS 지오메트리 분리 단위.
      def accumulate_face(face, buckets)
        mat  = face.material || face.back_material
        mkey = mat ? register_material(mat) : '__default__'
        buf  = (buckets[mkey] ||= { 'p' => [], 'n' => [], 'uv' => [], 'i' => [] })

        begin
          mesh = face.mesh(MESH_FLAGS)
        rescue StandardError
          @stats['face_errors'] += 1
          return
        end
        return if mesh.nil?

        base = buf['p'].length / 3
        (1..mesh.count_points).each do |i|
          pt = mesh.point_at(i)
          # Length는 Float 하위 클래스라 JSON 직렬화가 되긴 하지만
          # 단위 의미가 붙은 채 흘러가지 않도록 여기서 순수 Float로 끊는다.
          buf['p'].push((pt.x * INCH_TO_M).to_f,
                        (pt.y * INCH_TO_M).to_f,
                        (pt.z * INCH_TO_M).to_f)

          n = (mesh.normal_at(i) rescue nil)
          if n
            @seen[:normals] = true
            buf['n'].push(n.x.to_f, n.y.to_f, n.z.to_f)
          else
            buf['n'].push(0.0, 0.0, 1.0)
          end

          uv = (mesh.uv_at(i, true) rescue nil)
          if uv
            @seen[:uvs] = true
            q = (uv.z.nil? || uv.z.abs < 1e-12) ? 1.0 : uv.z
            buf['uv'].push((uv.x / q).to_f, (uv.y / q).to_f)
          else
            buf['uv'].push(0.0, 0.0)
          end
        end

        mesh.polygons.each do |poly|
          next unless poly.length == 3
          # 인덱스는 1-based이며 부호는 에지 가시성을 뜻한다 -> abs 필수
          buf['i'].push(base + poly[0].abs - 1, base + poly[1].abs - 1, base + poly[2].abs - 1)
          @stats['triangles'] += 1
        end
        @stats['faces'] += 1

        if (@stats['faces'] % PROGRESS_EVERY).zero?
          Sketchup.status_text =
            "IRIS 추출 중… 면 #{@stats['faces']} / 삼각형 #{@stats['triangles']}"
        end
        raise BudgetExceeded if @limit && @stats['triangles'] > @limit
      end

      def finalize_buckets(buckets)
        buckets.map do |mkey, b|
          @stats['vertices'] += b['p'].length / 3
          {
            'material'  => (mkey == '__default__' ? nil : mkey),
            'positions' => b['p'],
            'normals'   => b['n'],
            'uvs'       => b['uv'],
            'indices'   => b['i'],
          }
        end
      end

      def register_material(mat)
        key = "mat_#{mat.entityID}"
        return key if @materials.key?(key)

        c   = (mat.color rescue nil)
        tex = (mat.texture rescue nil)
        @materials[key] = {
          'id'      => key,
          'name'    => (mat.name rescue ''),
          'color'   => c ? [c.red / 255.0, c.green / 255.0, c.blue / 255.0] : [1.0, 1.0, 1.0],
          'alpha'   => (mat.alpha rescue 1.0),
          'type'    => (mat.materialType rescue nil),  # 0 solid / 1 textured / 2 colorized
          'texture' => tex ? {
            'file'     => (tex.filename rescue nil),
            # 실제로 꺼낸 이미지의 상대경로. .skp 안에 임베드된 것을 파일로 뽑아낸 것이라
            # 'file'(원본 파일명)과 달리 **실제로 존재하는 경로**다.
            'export'   => export_texture(tex, key),
            'width_m'  => ((tex.width * INCH_TO_M) rescue nil),
            'height_m' => ((tex.height * INCH_TO_M) rescue nil),
            'pixels'   => [(tex.image_width rescue nil), (tex.image_height rescue nil)],
          } : nil,
        }
        key
      end

      # ------------------------------------------------------------ 저장된 시점
      #
      # SketchUp의 '장면(Page)'에는 설계자가 잡아둔 카메라가 들어 있다. 실무 모델에는
      # 보통 수십 개가 있고(이 모델은 20개 이상), 그것이 곧 "보여줄 시점"이다.
      # 임의로 카메라를 놓는 것보다 이 시점을 그대로 쓰는 것이 맞다.
      #
      # Enscape 계열 제품이 호스트의 뷰를 동기화하는 것도 같은 이유다.
      def collect_views(model)
        out = []

        # 현재 뷰포트 카메라도 하나의 시점으로 포함한다.
        begin
          out << view_entry('(현재 뷰)', model.active_view.camera)
        rescue StandardError
          nil
        end

        begin
          model.pages.each do |page|
            cam = (page.camera rescue nil)
            next unless cam
            out << view_entry((page.name rescue ''), cam)
          end
        rescue StandardError => e
          @views_error = e.message
        end
        out.compact
      end

      def view_entry(name, cam)
        {
          'name'        => name,
          'eye'         => point_m(cam.eye),
          'target'      => point_m(cam.target),
          'up'          => [cam.up.x.to_f, cam.up.y.to_f, cam.up.z.to_f],
          # SketchUp fov 는 화면이 세로로 길면 수평 화각을 준다. 렌더러 쪽에서
          # 종횡비를 알 수 없으므로 그대로 넘기고 해석은 소비자에게 맡긴다.
          'fov_deg'     => (cam.fov rescue nil),
          'perspective' => (cam.perspective? rescue true),
          'aspect'      => (cam.aspect_ratio rescue 0.0),
          'height'      => (cam.perspective? ? nil : (cam.height * INCH_TO_M rescue nil)),
        }
      rescue StandardError
        nil
      end

      def point_m(p)
        [(p.x * INCH_TO_M).to_f, (p.y * INCH_TO_M).to_f, (p.z * INCH_TO_M).to_f]
      end

      # SketchUp 텍스처는 .skp 내부에 임베드되어 있어 `texture.filename` 경로에는
      # 파일이 없다. ImageRep(2018+)으로 꺼내 PNG로 저장한다.
      #
      # image_rep(true) 는 머티리얼 색으로 착색된(colorized) 결과를 준다. SketchUp은
      # 같은 이미지에 색을 입혀 여러 재질을 만들 수 있으므로, 재질별로 따로 뽑아야
      # 화면에서 본 것과 같아진다.
      def export_texture(tex, key)
        return nil unless @texture_dir

        file = "#{key}.png"
        path = File.join(@texture_dir, file)
        rel  = "#{@texture_rel}/#{file}"
        if File.exist?(path)
          # 이전 실행에서 이미 뽑아둔 것. 다시 쓰되 통계에는 따로 센다 —
          # 이걸 구분하지 않으면 "추출 0개"로 보고돼 실패한 것처럼 보인다.
          @stats['textures_reused'] += 1
          return rel
        end

        begin
          rep = tex.image_rep(true)
          # 저장 메서드 이름이 버전에 따라 다르다. SketchUp 2026 은 save_file.
          # 이름을 추측하지 않고 있는 것을 찾아 쓴다.
          if rep.respond_to?(:save_file)
            rep.save_file(path)
          elsif rep.respond_to?(:save_as)
            rep.save_as(path)
          else
            avail = (rep.methods - Object.instance_methods).sort.join(', ')
            raise "ImageRep에 저장 메서드가 없습니다. 사용 가능: #{avail}"
          end
          @stats['textures_exported'] += 1
          rel
        rescue StandardError => e
          @stats['texture_errors'] += 1
          @texture_error_msg ||= e.message
          nil
        end
      end

      def transform_to_a(tr)
        a = tr.to_a.map(&:to_f)
        a[12] *= INCH_TO_M
        a[13] *= INCH_TO_M
        a[14] *= INCH_TO_M
        a
      end

      # ------------------------------------------------------------ 능력 조사

      def probe_capabilities(model)
        face = first_face(model.entities, 0)
        caps = {
          'sketchup_version'  => Sketchup.version,
          'ruby_version'      => RUBY_VERSION,
          'persistent_id'     => false,
          'mesh_normals'      => false,
          'mesh_uvs'          => false,
          'entities_observer' => !!defined?(Sketchup::EntitiesObserver),
          'model_observer'    => !!defined?(Sketchup::ModelObserver),
          'sample_face'       => !face.nil?,
        }
        caps['persistent_id'] = !(face && safe_pid(face)).nil?

        if face
          begin
            m = face.mesh(MESH_FLAGS)
            caps['mesh_normals'] = !(m.normal_at(1) rescue nil).nil?
            caps['mesh_uvs']     = !(m.uv_at(1, true) rescue nil).nil?
          rescue StandardError => e
            caps['mesh_error'] = e.message
          end
        end
        caps
      end

      def first_face(entities, depth)
        return nil if depth > 4
        entities.each do |e|
          return e if e.is_a?(Sketchup::Face)
        end
        entities.each do |e|
          sub = if e.is_a?(Sketchup::Group)
                  d = group_definition(e)
                  d && d.entities
                elsif e.is_a?(Sketchup::ComponentInstance)
                  e.definition.entities
                end
          next unless sub
          f = first_face(sub, depth + 1)
          return f if f
        end
        nil
      end

      # ---------------------------------------------------------------- 리포트

      def report(model, path)
        tri   = @stats['triangles']
        ms    = @elapsed * 1000.0
        rate  = @elapsed > 0 ? (tri / @elapsed) : 0
        insts = @stats['instances']
        defs  = @stats['definitions']
        reuse = defs > 0 ? (insts.to_f / defs) : 0

        w = []
        w << ''
        w << '=============================================================='
        w << " IRIS SketchUp 프로브 v#{VERSION}"
        w << '=============================================================='
        w << " 모델      : #{model.title.to_s.empty? ? '(제목 없음)' : model.title}"
        w << " 파일      : #{model.path.to_s.empty? ? '(저장 안 됨)' : model.path}"
        w << " SketchUp  : #{Sketchup.version}  /  Ruby #{RUBY_VERSION}"
        if @truncated
          w << ''
          w << " !! 삼각형 예산(#{@limit}) 초과로 중단됨 — 아래 수치는 부분 집계입니다."
          w << '    처리량과 능력 판정은 유효하지만 총량·재사용률은 신뢰할 수 없습니다.'
        end
        w << ''
        w << ' [1] 지오메트리 추출'
        w << "     면            : #{@stats['faces']}"
        w << "     삼각형        : #{tri}"
        w << "     정점          : #{@stats['vertices']}"
        w << "     법선 추출     : #{@seen[:normals] ? 'O' : 'X'}"
        w << "     UV 추출       : #{@seen[:uvs] ? 'O' : 'X'}"
        w << "     추출 실패 면  : #{@stats['face_errors']}"
        w << ''
        w << ' [2] 인스턴싱 (= BLAS 재사용)'
        w << "     정의 수       : #{defs}"
        w << "     인스턴스 수   : #{insts}"
        w << format('     재사용률      : %.2f 인스턴스/정의', reuse)
        w << "     스킵된 그룹   : #{@stats['groups_skipped']}"
        w << ''
        w << ' [3] 머티리얼'
        w << "     고유 머티리얼 : #{@materials.size}"
        w << "     텍스처 보유   : #{@materials.values.count { |m| m['texture'] }}"
        w << "     텍스처 추출   : #{@stats['textures_exported']} 신규 / #{@stats['textures_reused']} 재사용 (실패 #{@stats['texture_errors']})"
        w << "     추출 실패 사유: #{@texture_error_msg}" if @texture_error_msg
        w << ''
        w << "     저장된 시점   : #{(@scene_views_list || []).size}"
        w << "     시점 수집 오류: #{@views_error}" if @views_error
        w << ''
        w << ' [4] 증분 동기화 가능성'
        w << "     persistent_id    : #{@caps['persistent_id'] ? 'O — GUID 델타 추적 가능' : 'X — 추적 불가'}"
        w << "     EntitiesObserver : #{@caps['entities_observer'] ? 'O' : 'X'}"
        w << "     ModelObserver    : #{@caps['model_observer'] ? 'O' : 'X'}"
        w << ''
        w << ' [5] 성능'
        w << format('     추출 시간     : %.1f ms', ms)
        w << format('     처리량        : %.0f 삼각형/초', rate)
        w << format('     1000만 삼각형 환산 : %.1f 초', 10_000_000.0 / rate) if rate > 0
        w << format('     JSON 기록     : %.1f ms', @write_elapsed * 1000.0) if @write_elapsed
        if path && File.exist?(path)
          w << format('     덤프 파일     : %s (%.1f MB)', path, File.size(path) / 1048576.0)
        end
        w << ''
        w << ' 판정'
        verdict.each { |line| w << "     #{line}" }
        w << '=============================================================='

        text = w.join("\n")
        puts text

        # Ruby 콘솔은 긴 출력에 약하다. 파일로도 남겨 두면 밖에서 읽을 수 있다.
        begin
          dir = default_out_dir
          FileUtils.mkdir_p(dir)
          rp = File.join(dir, 'report.txt')
          File.open(rp, 'w:UTF-8') { |f| f.write(text) }
          puts "리포트 저장: #{rp}"
        rescue StandardError => e
          puts "리포트 저장 실패: #{e.message}"
        end
        nil
      end

      def verdict
        v = []
        v << (@caps['persistent_id'] ?
              'persistent_id 사용 가능 -> 증분 동기화 설계 성립' :
              'persistent_id 없음 -> 전체 재변환만 가능. 라이브 링크 재검토 필요')
        v << (@seen[:normals] && @seen[:uvs] ?
              '정점·법선·UV 모두 확보 -> 렌더러 입력으로 충분' :
              '법선/UV 일부 누락 -> Face#mesh 플래그 재확인 필요')
        v << (@stats['definitions'] > 0 ?
              '컴포넌트 정의 구조 유지 -> BLAS 재사용 가능' :
              '정의 없음(단일 메시 모델) -> 인스턴싱 이득 측정 불가, 다른 모델로 재측정')
        v << '삭제 델타는 entityID만 통보됨 -> 자체 ID 매핑 테이블 필수 (watch/flush로 확인)'
        v
      end

      # ---------------------------------------------------------------- 유틸

      def reset!
        @stats = {
          'faces' => 0, 'triangles' => 0, 'vertices' => 0, 'instances' => 0,
          'definitions' => 0, 'face_errors' => 0, 'groups_skipped' => 0,
          'textures_exported' => 0, 'textures_reused' => 0, 'texture_errors' => 0,
        }
        @definitions    = {}
        @materials      = {}
        @instance_count = {}
        @seen           = { normals: false, uvs: false }
        @caps           = {}
        @write_elapsed  = nil
        @truncated      = false
        @limit          = nil
        @scene          = nil
        @texture_dir    = nil
        @texture_rel    = nil
        @texture_error_msg = nil
      end

      def safe_pid(e)
        return nil unless e.respond_to?(:persistent_id)
        e.persistent_id
      rescue StandardError
        nil
      end

      def default_out_dir
        File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
      end

      def sanitize(name)
        s = name.to_s.strip
        s = 'untitled' if s.empty?
        s.gsub(/[^\w\-.가-힣]+/, '_')
      end
    end

    # -------------------------------------------------------------- 옵저버

    class EntityWatcher < Sketchup::EntitiesObserver
      def initialize(sink)
        @sink = sink
      end

      def onElementAdded(_entities, entity)
        push('added', entity)
      end

      def onElementModified(_entities, entity)
        push('modified', entity)
      end

      # 주의: 삭제 콜백은 entity_id(Integer)만 준다.
      # 엔티티 객체가 이미 무효라 persistent_id를 조회할 수 없다.
      def onElementRemoved(_entities, entity_id)
        @sink << { op: 'removed', entity_id: entity_id, pid: nil }
      end

      private

      def push(op, entity)
        @sink << {
          op: op,
          entity_id: (entity.entityID rescue nil),
          pid: IRIS::Probe.safe_pid(entity),
        }
      end
    end

    class TxWatcher < Sketchup::ModelObserver
      def initialize(sink)
        @sink = sink
      end

      # 트랜잭션 경계 = 델타를 배치로 묶어 전송할 지점
      def onTransactionCommit(_model)
        @sink << { op: 'tx_commit', entity_id: nil, pid: nil }
      end

      def onTransactionUndo(_model)
        @sink << { op: 'tx_undo', entity_id: nil, pid: nil }
      end
    end
  end
end

puts "[IRIS] 프로브 로드 완료 (v#{IRIS::Probe::VERSION}). IRIS::Probe.run 을 실행하세요."
