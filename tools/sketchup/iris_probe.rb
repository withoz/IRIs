# encoding: UTF-8
#
# IRIS — SketchUp 지오메트리 덤프 · 라이브 링크 실현성 프로브
# Phase 0-2 과제 4 / 대상: SketchUp 2026 (2017+ 호환)
#
# 사용법 — SketchUp Ruby 콘솔 (창 > Ruby 콘솔):
#   load 'E:/IRIS/tools/sketchup/iris_probe.rb'
#   IRIS::Probe.run                 # 측정 + 바이너리 덤프 (.irisb)
#   IRIS::Probe.run(format: :json)  # JSON 덤프 (호환/디버깅용, 느림)
#   IRIS::Probe.run(dump: false)    # 측정만
#   IRIS::Probe.watch               # 변경 감지 옵저버 부착 (증분 동기화 테스트)
#   IRIS::Probe.flush               # 감지된 델타 출력
#   IRIS::Probe.unwatch
#
#   IRIS::Probe.cache_status        # 정의 캐시 상태
#   IRIS::Probe.dirty_report        # 편집 후: 무효화된 정의와 재추출 예상 비용
#   IRIS::Probe.cache_clear         # 캐시 비우고 옵저버 해제
#   IRIS::Probe.run(cache: false)   # 캐시 없이 (비교용)
#
# ⚠ 모델을 바꿔 열기 전에 cache_clear 를 호출하십시오. 캐시 키가 entityID 인데
#   모델마다 다시 매겨지므로, 그대로 두면 엉뚱한 정의를 재사용합니다.
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

# Enscape 가 속성 사전에 남긴 조명·재질 설정을 읽습니다.
# 설계자가 이미 정해 둔 값이므로 추측하지 않습니다.
#
# require_relative 가 아니라 load 인 이유: SketchUp 콘솔에서 프로브를 다시
# 로드해 가며 값을 조정하는데, require 는 한 번만 읽으므로 수정이 반영되지
# 않습니다. 같이 갱신되어야 합니다.
load File.expand_path('iris_enscape.rb', File.dirname(__FILE__))

module IRIS
  module Probe

    VERSION   = '0.1.0'
    INCH_TO_M = 0.0254

    # 정의 캐시 레코드의 판. **머티리얼 레코드의 모양이 바뀌면 올리십시오.**
    # 올리지 않으면 같은 SketchUp 세션의 옛 캐시가 되살아나 새 필드가 빠집니다.
    #   2 — Enscape PBR(pbr) 필드 추가
    #   3 — 자식 엔티티 목록(kids)·엔티티 개수(esize) 추가
    #   4 — 메시를 배열이 아니라 **미리 인코딩한 이진**으로 보관
    #   5 — 지오메트리 판(gen) 추가 — 델타의 근거
    #   6 — 뒷면 재질 면의 UV·법선·감김 교정 (메시 내용이 바뀝니다)
    #   7 — v 뒤집기 (SketchUp 은 아래가 v=0, 렌더러는 위가 v=0)
    #
    # ⚠ 번호를 올리는 것을 잊어도 되도록, fetch 가 **필드 목록**도 함께
    #   봅니다(DefCache::CACHE_FIELDS). 실제로 한 번 잊었고 델타가 조용히
    #   꺼졌습니다.
    CACHE_SCHEMA = 7

    # Face#mesh 비트마스크 (1: UVQ front, 2: UVQ back, 4: normals)
    # 버전별 상수 차이 가능성이 있어 값을 신뢰하지 않고 결과를 런타임에 검증한다.
    MESH_FLAGS = 1 | 2 | 4

    # 진행 표시 주기(면 단위). Ruby가 메인 스레드를 잡고 있어
    # 상태바 갱신만이 유일하게 살아 있는 피드백 경로다.
    PROGRESS_EVERY = 2000

    # 삼각형 예산 초과 시 탈출용
    class BudgetExceeded < StandardError; end

    # ------------------------------------------------------------ 정의 캐시
    #
    # 추출 비용의 91%가 PolygonMesh에서 데이터를 꺼내는 데 들어간다
    # (벤치마크 실측 — docs/05-씬-델타-프로토콜.md 7절). 그리고 그 비용은
    # Ruby 루프를 다듬어서는 줄지 않는다.
    #
    # 그래서 빠르게 하는 대신 **적게** 한다. 정의마다 옵저버를 붙여 두고,
    # 내용이 바뀌지 않은 정의는 이전 추출 결과를 그대로 쓴다.
    # 실측 재사용률이 1.64~4.00이고 일반적인 편집은 정의 몇 개만 건드리므로,
    # 두 번째 동기화부터는 대부분이 캐시 적중이 된다.
    #
    # ⚠ 세션 한정이다. entityID 를 키로 쓰는데 모델을 다시 열면 다시 매겨진다.

    class DefWatcher < Sketchup::EntitiesObserver
      def initialize(cache, key)
        @cache = cache
        @key = key
      end

      def onElementAdded(_entities, _entity)     = @cache.mark_dirty(@key)
      def onElementModified(_entities, _entity)  = @cache.mark_dirty(@key)
      def onElementRemoved(_entities, _id)       = @cache.mark_dirty(@key)
      def onEraseEntities(_entities)             = @cache.mark_dirty(@key)
    end

    # 머티리얼 속성 변경은 정의의 EntitiesObserver 로 잡히지 않는다.
    # 이게 없으면 색을 바꿔도 캐시가 옛 값을 계속 내놓는다.
    class MatWatcher < Sketchup::MaterialsObserver
      def initialize(cache)
        @cache = cache
      end

      # **어느 재질이 바뀌었는지**를 버리지 않습니다.
      #
      # 이름을 흘리고 "재질이 바뀌었다"로만 넘기면 다음 추출이 텍스처를 전부
      # 다시 뽑습니다 — 색 하나 바꾸는 데 13.9초였습니다(231장 재추출).
      # 옵저버가 알려준 것을 그대로 들고 갑니다.
      def onMaterialChange(_materials, material) = @cache.invalidate_material(material)
      def onMaterialRemove(_materials, material) = @cache.invalidate_material(material)
      def onMaterialRemoveAll(_materials)        = @cache.invalidate_all_materials
    end

    class DefCache
      def initialize
        @entries   = {}   # entityID => {meshes:, mats:, verts:, tris:, faces:, dirty:}
        @observers = {}   # entityID => [definition, observer]
        @mat_obs   = nil
        @mat_model = nil
        @suspended = false
        @suppressed = { elements: 0, materials: 0 }
        @materials_stale = false
        @stale_all  = false   # 어느 것인지 모른다 -> 전부 다시 읽는다
        @stale_mats = {}      # id => true
      end

      # 추출 중에는 무효화를 받지 않습니다.
      #
      # 우리가 읽는 동작 자체가 옵저버를 깨울 수 있습니다 — face.mesh() 의
      # 삼각분할 결과가 엔티티에 캐시되거나, 텍스처를 만지면 머티리얼 옵저버가
      # 뜹니다. 그러면 추출이 끝나자마자 전체가 다시 dirty 가 되어 **자동
      # 동기화가 편집이 없는데도 매초 돕니다.** 렌더러는 매번 누적을 초기화하므로
      # 화면이 영원히 수렴하지 않습니다. 실제로 그렇게 됐습니다.
      #
      # SketchUp 은 단일 스레드이므로 추출 중에 사용자 편집이 끼어들 수 없습니다.
      # 따라서 이 구간의 무효화는 전부 우리가 만든 것입니다.
      def suspend
        prev = @suspended
        @suspended = true
        yield
      ensure
        @suspended = prev
      end

      def suppressed_counts
        @suppressed
      end

      def reset_suppressed
        @suppressed = { elements: 0, materials: 0 }
      end

      # ⚠ 스키마 판이 다르면 버립니다.
      #
      # 캐시는 SketchUp 세션 내내 살아 있고, **머티리얼 레코드도 통째로** 들고
      # 있습니다. 프로브 코드가 바뀌어 레코드에 필드가 늘어나면(예: Enscape PBR)
      # 옛 레코드가 그대로 되살아나 새 필드가 통째로 빠집니다. 조용히 틀립니다 —
      # 오류도 없고 개수도 맞으므로 알아채기 어렵습니다.
      #
      # 콘솔에서 프로브를 다시 로드하는 것이 이 도구의 정상적인 사용법이므로,
      # 스스로 무효화되어야 합니다.
      # 읽는 쪽이 쓰는 필드가 **전부 있는지** 봅니다.
      #
      # 판 번호만으로는 부족했습니다. 판을 4로 올린 뒤 gen 필드를 추가하면서
      # 판을 다시 올리지 않았고, 그래서 검사는 통과하는데 gen 이 없어
      # **델타가 조용히 꺼졌습니다.** 오류도 없고 화면도 맞아서, 계측하지
      # 않았다면 '구현 완료'라고 말했을 것입니다.
      #
      # 필드 목록 검사는 그 실수를 기계가 잡아 줍니다 — 읽을 필드를 늘리면
      # 여기에도 적어야 하고, 적으면 옛 캐시가 자동으로 버려집니다.
      CACHE_FIELDS = %i[gen kids esize meshes mats verts tris faces seen].freeze

      # 모델이 바뀌면 캐시를 통째로 버립니다.
      #
      # 캐시 키가 entityID 인데 **모델마다 다시 매겨집니다.** 다른 파일을 열면
      # 같은 번호가 전혀 다른 정의를 가리킵니다. 그대로 두면 엉뚱한 지오메트리가
      # 되살아나고, 오류는 나지 않습니다.
      #
      # 지금까지는 주석으로 "모델을 바꾸기 전에 cache_clear 하십시오"라고만
      # 적어 두었습니다. 사람이 기억해야 하는 안전장치는 안전장치가 아닙니다.
      def check_model(model)
        key = model_key(model)
        return if key == @model_key
        unless @model_key.nil?
          puts "[IRIS] 모델이 바뀌었습니다 — 정의 캐시를 비웁니다"
        end
        @entries = {}
        detach_all rescue nil
        # 다른 모델의 재질 id 를 들고 가면 엉뚱한 것을 지목합니다.
        clear_materials_stale
        forget_materials
        @model_key = key
      end

      def model_key(model)
        path = (model.path.to_s rescue '')
        path.empty? ? "guid:#{(model.guid rescue model.object_id)}" : "path:#{path}"
      end

      def fetch(defn)
        e = @entries[defn.entityID]
        return nil if e.nil? || e[:dirty]
        return nil if e[:schema] != CACHE_SCHEMA
        return nil unless CACHE_FIELDS.all? { |k| e.key?(k) }
        e
      end

      # 자식 인스턴스를 **다시 쓸 수 있는가**.
      #
      # 캐시가 적중해도 지금까지는 정의 안의 모든 엔티티를 훑었습니다 —
      # 자식을 찾으려고 면 27만 개를 매번 지나갔고, 그것이 추출 시간의
      # 대부분이었습니다(194 ms).
      #
      # 자식 **엔티티 객체**만 들고 있으면 면을 건드리지 않고도 배치를 다시
      # 읽을 수 있습니다. 값(변환·이름·숨김·재질)은 그때그때 새로 읽으므로
      # 옵저버가 놓치는 편집(숨김·이름 변경 — 실측으로 확인됨)도 반영됩니다.
      #
      # 되쓸 수 없는 경우는 둘입니다.
      #   - 엔티티 개수가 달라짐  = 자식이 추가·삭제됨
      #   - 죽은 엔티티가 섞임    = 삭제 후 개수가 우연히 같아진 경우
      # 어느 쪽이든 전체 순회로 되돌아갑니다.
      def reusable_children(defn, hit)
        kids = hit[:kids]
        return nil unless kids
        return nil unless hit[:esize] == (defn.entities.size rescue -1)
        return nil unless kids.all? { |e| e.valid? rescue false }
        kids
      end

      # 지오메트리 판.
      #
      # 델타는 "렌더러가 이 정의의 지오메트리를 이미 갖고 있는가"를 알아야
      # 합니다. 다시 추출할 때마다 판을 올리면, 호스트는 판만 비교하면 됩니다.
      # 내용을 다시 해싱할 필요가 없습니다 — 추출은 곧 변경이기 때문입니다.
      def next_gen
        @gen = @gen.to_i + 1
      end

      def store(defn, meshes, mats, verts, tris, faces, seen, kids = nil)
        @entries[defn.entityID] = {
          schema: CACHE_SCHEMA, gen: next_gen,
          kids: kids, esize: (defn.entities.size rescue nil),
          meshes: meshes, mats: mats, verts: verts, tris: tris, faces: faces,
          # 능력 플래그(법선·UV 추출 성공 여부)도 함께 보관한다.
          # 이게 없으면 캐시 적중 시 accumulate_face 가 안 돌아서
          # "법선/UV 누락"으로 잘못 판정한다.
          seen: seen, dirty: false,
        }
        attach(defn)
      end

      def mark_dirty(key)
        if @suspended
          @suppressed[:elements] += 1
          return
        end
        e = @entries[key]
        e[:dirty] = true if e
      end

      # 머티리얼이 바뀌면 어느 정의가 그걸 쓰는지 모르므로 전부 무효화한다.
      # 머티리얼 편집은 드물어서 이 정도로 충분하다.
      # 재질이 바뀌었다 — **지오메트리는 그대로입니다.**
      #
      # 예전에는 여기서 캐시 전체를 무효화했습니다. 재질 하나를 건드리면
      # 정의 2,249개가 전부 다시 뽑혀 **131만 삼각형에 33초**가 걸렸고
      # 111 MB 를 다시 보냈습니다. 지오메트리는 하나도 안 바뀌었는데요.
      #
      # 재질의 **속성**이 바뀐 것과 면에 **다른 재질을 칠한** 것은 다릅니다.
      # 후자는 엔티티 변경이라 EntitiesObserver 가 그 정의만 정확히 잡습니다.
      # 여기서 할 일은 **머티리얼 레코드를 다시 읽는 것**뿐입니다.
      #
      # 재질 조정은 라이브 링크에서 가장 흔한 작업입니다. 그때마다 전체
      # 재추출이 도는 것은 제품으로 성립하지 않습니다.
      def invalidate_material(mat)
        if @suspended
          @suppressed[:materials] += 1
          return
        end
        @materials_stale = true
        return if @stale_all
        id = ("mat_#{mat.entityID}" rescue nil)
        # ||= 로 지연 생성합니다. 콘솔에서 프로브를 다시 로드하면 **이미 있던
        # DefCache 인스턴스**가 그대로 살아 있어 initialize 가 다시 돌지
        # 않습니다. 새로 넣은 ivar 는 nil 인 채로 남습니다.
        id ? ((@stale_mats ||= {})[id] = true) : (@stale_all = true)
      end

      # 어느 것인지 모를 때. 전부 다시 읽습니다.
      def invalidate_all_materials
        if @suspended
          @suppressed[:materials] += 1
          return
        end
        @materials_stale = true
        @stale_all = true
      end

      # 예전 이름 — 부르는 곳이 남아 있을 수 있어 남겨 둡니다.
      def invalidate_materials = invalidate_all_materials

      # nil 이면 '전부'. 빈 해시면 '없음'.
      def stale_material_ids = @stale_all ? nil : (@stale_mats || {})

      def materials_stale? = @materials_stale ? true : false

      def clear_materials_stale
        @materials_stale = false
        @stale_all  = false
        @stale_mats = {}
      end

      # 다시 읽은 재질 레코드는 **캐시 항목 밖에** 들고 있습니다.
      #
      # 캐시 항목의 mats 는 그 정의를 추출하던 시점의 레코드입니다. 재질을
      # 다시 읽고 표시를 지우고 나면, 다음 실행이 그 낡은 레코드를 되살립니다 —
      # **색이 조용히 되돌아갑니다.** 오류도 없고 시간도 빠르므로 알아채기
      # 어렵습니다. 벤치는 단계마다 색을 또 바꿔서 이걸 못 잡았습니다.
      def remember_material(mid, rec)
        (@mat_records ||= {})[mid] = [CACHE_SCHEMA, rec]
      end

      # 판이 다르면 버립니다 — 레코드에 필드가 늘면(예: Enscape PBR) 옛것이
      # 조용히 되살아납니다. @entries 와 같은 이유입니다.
      def material_record(mid)
        e = (@mat_records || {})[mid]
        e && e[0] == CACHE_SCHEMA ? e[1] : nil
      end

      def forget_materials = (@mat_records = {})

      def attach(defn)
        return if @observers.key?(defn.entityID)
        obs = DefWatcher.new(self, defn.entityID)
        defn.entities.add_observer(obs)
        @observers[defn.entityID] = [defn, obs]
      rescue StandardError
        nil
      end

      def attach_materials(model)
        return if @mat_obs
        @mat_obs   = MatWatcher.new(self)
        @mat_model = model
        model.materials.add_observer(@mat_obs)
      rescue StandardError
        @mat_obs = nil
      end

      def detach_all
        @observers.each_value do |(defn, obs)|
          begin
            defn.entities.remove_observer(obs)
          rescue StandardError
            nil
          end
        end
        @observers.clear
        begin
          @mat_model.materials.remove_observer(@mat_obs) if @mat_obs && @mat_model
        rescue StandardError
          nil
        end
        @mat_obs = nil
        @entries.clear
      end

      # 전부 깨끗하다고 표시한다.
      #
      # 추출을 끝내고 만든 바이트가 지난번과 같다고 확인했을 때 부릅니다.
      # 그 시점의 무효화 표시는 **증명된 거짓**입니다 — 다시 뽑아 봤는데
      # 내용이 같았으니까요. 지우지 않으면 다음 틱에도 또 뽑게 되고,
      # 편집이 없는데도 매초 전체 추출이 돕니다.
      #
      # SketchUp 은 단일 스레드이므로 추출과 이 호출 사이에 사용자 편집이
      # 끼어들 수 없습니다.
      def clear_dirty
        @entries.each_value { |e| e[:dirty] = false }
      end

      # 무효화된 항목만. 델타 비용 측정에 쓴다.
      def dirty_entries
        @entries.select { |_, e| e[:dirty] }
      end

      def status
        {
          entries: @entries.size,
          dirty: @entries.count { |_, e| e[:dirty] },
          observers: @observers.size,
          materials_observer: !@mat_obs.nil?,
        }
      end
    end

    class << self

      # ---------------------------------------------------------------- 실행

      # limit: 삼각형 예산. 초과하면 즉시 중단하고 거기까지의 통계만 낸다.
      #        대형 모델에서 "끝나긴 하는가"를 먼저 확인할 때 쓴다.
      def run(dump: true, out_dir: nil, pretty: false, limit: nil, textures: true, cache: true,
              format: :binary)
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

        # 정의 캐시. 세션 동안 유지되며 옵저버가 변경을 감시한다.
        if cache
          # class << self 안이므로 @def_cache 는 IRIS::Probe 자신의 인스턴스 변수다.
          # 클래스 변수(@@)를 쓰면 싱글턴 클래스에 붙어 의도와 달라진다.
          @def_cache ||= DefCache.new
          @cache = @def_cache
          # 다른 파일을 열었으면 여기서 캐시가 스스로 비워집니다.
          @cache.check_model(model)
          @cache.attach_materials(model)

          # 재질이 바뀌었으면 캐시된 머티리얼 레코드를 살아 있는 것으로
          # 갈아 끼웁니다. 지오메트리는 건드리지 않습니다.
          @refresh_materials = @cache.materials_stale?
          if @refresh_materials
            # 옵저버가 알려준 **그 재질만** 다시 읽습니다. nil 이면 전부입니다.
            @stale_mat_ids = @cache.stale_material_ids
            @mat_index = model.materials.each_with_object({}) do |m, h|
              h["mat_#{m.entityID}"] = m
            end
          end
        else
          @cache = nil
          # 캐시가 없으면 어차피 전부 새로 뽑습니다.
          @refresh_materials = false
          @stale_mat_ids = nil
        end

        @caps = probe_capabilities(model)

        scene = nil
        begin
          # 추출 중 옵저버 무효화를 막습니다. 자세한 이유는 DefCache#suspend 주석.
          @cache&.reset_suppressed
          if @cache
            @cache.suspend { scene = build_scene(model) }
          else
            scene = build_scene(model)
          end
        rescue BudgetExceeded
          @truncated = true
        ensure
          Sketchup.status_text = ''
        end
        @suppressed = @cache&.suppressed_counts
        @elapsed = Time.now - t0

        path = nil
        if dump && scene
          dir = out_dir || default_out_dir
          FileUtils.mkdir_p(dir)
          base = sanitize(model.title)
          t1 = Time.now
          if format == :binary
            path = File.join(dir, "#{base}.irisb")
            @write_sizes = write_binary(path, scene)
          else
            path = File.join(dir, "#{base}.iris.json")
            # 메시는 이제 **미리 인코딩한 이진**으로 들고 있습니다. JSON 은
            # 이진 문자열을 담지 못하므로 이 경로에서만 배열로 풀어 줍니다.
            plain = scene_with_arrays(scene)
            # 정점 배열이 그대로 텍스트가 되므로 기본은 compact.
            # 눈으로 확인할 때만 pretty: true.
            json = pretty ? JSON.pretty_generate(plain) : JSON.generate(plain)
            File.open(path, 'w:UTF-8') { |f| f.write(json) }
            @write_sizes = nil
          end
          @write_format = format
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

      # -------------------------------------------------------- 바이너리 직렬화
      #
      # 캐싱을 넣은 뒤 병목이 추출(3.4%)에서 직렬화(96.6%)로 옮겨갔다.
      # JSON 140.6 MB / 7.6초가 유일한 병목이다.
      #
      # 구조는 GLB와 같다 — 헤더 + JSON 매니페스트 + 바이너리 블롭.
      # 구조·메타데이터(정의 트리, 머티리얼, 인스턴스, 시점)는 작아서 JSON으로 두고,
      # 지오메트리 배열만 블롭으로 뺀다. 디버깅 가능성을 잃지 않으면서 크기와
      # 시간을 줄이는 절충이다.
      #
      # 정점 속성을 인터리브하지 않고 분리 블롭으로 두는 이유: 프로브가 이미
      # 분리된 배열을 갖고 있어 재배열 비용이 0이고, glTF도 속성별 접근자를 쓴다.

      MAGIC   = 'IRISSCN1'   # 8 bytes
      FMT_VER = 1

      # scene 해시를 [manifest_hash, binary_string] 으로 나눈다.
      # scene 자체는 건드리지 않는다 (last_scene 이 계속 유효해야 한다).
      # 블롭을 **만들지 않고** 계획만 세웁니다.
      #
      # 조각(미리 인코딩된 정점 바이트)은 참조만 모으고 오프셋은 크기로
      # 계산합니다. 복사가 없으므로 550개 정의에 사실상 공짜입니다.
      # 실제로 이어붙이는 것은 보낼 것이 정해진 뒤 한 번뿐입니다.
      class BlobPlan
        attr_reader :segments, :bytesize
        def initialize
          @segments = []
          @bytesize = 0
        end

        def push(str, count)
          return nil if str.nil? || count.nil? || count.zero?
          off = @bytesize
          @segments << str
          @bytesize += str.bytesize
          { 'off' => off, 'count' => count }
        end

        # Array#join 은 C 구현이고 전체 크기를 먼저 계산해 **한 번만**
        # 할당합니다. << 를 반복하면 재할당이 여러 번 일어납니다.
        def join
          @segments.empty? ? +''.b : @segments.join.b
        end
      end

      # skip_geom: { 정의id => 판 }. 판이 같으면 **지오메트리를 싣지 않습니다.**
      # 렌더러가 이미 갖고 있다는 뜻입니다.
      def split_binary(scene, skip_geom = nil)
        blob = BlobPlan.new
        man  = {}

        scene.each do |k, v|
          man[k] = if k == 'definitions'
                     v.each_with_object({}) { |(dk, d), h| h[dk] = strip_def(d, blob, skip_geom) }
                   elsif k == 'root'
                     # 루트는 캐시하지 않으므로 판이 없습니다. 항상 싣습니다.
                     { 'meshes' => v['meshes'].map { |mb| strip_mesh(mb, blob) },
                       'children' => v['children'] }
                   else
                     v
                   end
        end
        man['binary'] = { 'layout' => 'separate', 'bytes' => blob.bytesize }
        [man, blob]
      end

      def strip_def(d, blob, skip_geom = nil)
        out = d.dup
        gen = d['gen']
        # ⚠ 지오메트리가 **있는** 정의에만 표시합니다.
        #
        # 순수 컨테이너(이 모델의 39%)에도 붙였더니 렌더러가 캐시에서 메시를
        # 찾다가 없어서 476번 경고했습니다. 없는 것이 정상인데 없다고 알린
        # 것입니다 — 진짜 누락이 그 안에 묻힙니다.
        has_geometry = !(d['meshes'] || []).empty?
        if has_geometry && skip_geom && gen && gen > 0 && skip_geom[d['id']] == gen
          # 이 정의의 지오메트리는 렌더러가 이미 갖고 있습니다.
          # 배치·이름·조명은 그대로 싣습니다 — 그건 매번 바뀔 수 있습니다.
          out['meshes'] = []
          out['geom']   = 'same'
          @geom_skipped = @geom_skipped.to_i + 1
        else
          out['meshes'] = (d['meshes'] || []).map { |mb| strip_mesh(mb, blob) }
          @geom_sent = @geom_sent.to_i + 1 unless out['meshes'].empty?
        end
        out
      end

      def geom_counts
        { sent: @geom_sent.to_i, skipped: @geom_skipped.to_i }
      end

      # 배열을 블롭으로 옮기고 {off, count} 참조만 남긴다.
      def strip_mesh(mb, blob)
        bin = mb['bin']
        cnt = mb['count']
        {
          'material'  => mb['material'],
          'positions' => push_bin(blob, bin['p'],  cnt['p']),
          'normals'   => push_bin(blob, bin['n'],  cnt['n']),
          'uvs'       => push_bin(blob, bin['uv'], cnt['uv']),
          'indices'   => push_bin(blob, bin['i'],  cnt['i']),
        }
      end

      # 이미 인코딩된 조각을 계획에 등록하고 {off, count} 만 남긴다.
      # 여기서 복사는 일어나지 않습니다 — 참조만 모읍니다.
      def push_bin(blob, str, count)
        blob.push(str, count)
      end

      # 씬 전체를 JSON 이 담을 수 있는 모양으로. 느린 경로 전용입니다.
      def scene_with_arrays(scene)
        out = scene.dup
        out['definitions'] = scene['definitions'].each_with_object({}) do |(k, d), h|
          h[k] = d.merge('meshes' => (d['meshes'] || []).map { |mb| mesh_as_arrays(mb) })
        end
        out['root'] = scene['root'].merge(
          'meshes' => (scene['root']['meshes'] || []).map { |mb| mesh_as_arrays(mb) }
        )
        out
      end

      # JSON 덤프(호환·디버깅용)는 배열을 기대합니다. 이제 메시는 이진으로
      # 들고 있으므로 그때만 풀어 줍니다. 느린 경로이므로 비용은 문제되지 않습니다.
      def mesh_as_arrays(mb)
        bin = mb['bin']
        cnt = mb['count']
        return mb unless bin && cnt
        {
          'material'  => mb['material'],
          'positions' => bin['p'].unpack('e*'),
          'normals'   => bin['n'].unpack('e*'),
          'uvs'       => bin['uv'].unpack('e*'),
          'indices'   => bin['i'].unpack('V*'),
        }
      end

      # ('e' = little-endian f32, 'V' = little-endian u32 로 인코딩하는 일은
      #  이제 finalize_buckets 에서 **추출할 때 한 번만** 합니다. 여기 있던
      #  push_f32/push_u32 는 그래서 사라졌습니다 — 남겨 두면 동작하는 것처럼
      #  보이지만 BlobPlan 에는 << 가 없어 그 자리에서 죽습니다.)

      # .irisb 바이트를 **메모리에** 만든다. 라이브 링크(iris_link.rb)가 이것을
      # 그대로 파이프로 보냅니다 — 파일을 거치지 않습니다.
      #
      # 반환: [바이트 문자열(BINARY), { json:, bin: }]
      # 직렬화가 왕복의 85~90%가 됐습니다(추출을 19.7 ms 로 줄인 뒤).
      # 델타가 없앨 수 있는 부분과 남는 부분이 다르므로 나눠 잽니다.
      #   블롭  — 정점·인덱스. 바뀐 정의만 보내면 사라집니다
      #   JSON  — 배치 트리는 매번 필요합니다. 델타로도 남습니다
      #   조립  — 헤더 + 이어붙이기
      # 보낼 것을 계획합니다. 이어붙이지는 않습니다.
      #
      # 반환: { head:, json:, segments:, bytes:, sizes:, sent_gen: }
      #   sent_gen — 이번에 지오메트리를 실은 정의의 판. 호스트가 기억해 두면
      #              다음 번에 건너뛸 수 있습니다.
      def plan_binary(scene, skip_geom: nil)
        t0 = Time.now
        @geom_sent = 0
        @geom_skipped = 0
        man, blob = split_binary(scene, skip_geom)
        t1 = Time.now
        json = JSON.generate(man).b
        json << (' '.b * ((8 - (json.bytesize % 8)) % 8))
        t2 = Time.now

        head = +''.b
        head << MAGIC
        head << [FMT_VER, 0].pack('VV')
        head << [json.bytesize, blob.bytesize].pack('Q<Q<')

        # 지오메트리를 가진 정의만 기억합니다 — 나머지는 보낼 것이 없습니다.
        sent = {}
        (scene['definitions'] || {}).each do |id, d|
          g = d['gen']
          next unless g && g > 0
          next if (d['meshes'] || []).empty?
          sent[id] = g
        end

        @pack_phase = { blob_ms: (t1 - t0) * 1000.0, json_ms: (t2 - t1) * 1000.0, join_ms: 0.0 }
        { head: head, json: json, plan: blob,
          bytes: head.bytesize + json.bytesize + blob.bytesize,
          sizes: { json: json.bytesize, bin: blob.bytesize },
          sent_gen: sent }
      end

      def pack_binary(scene, skip_geom: nil)
        pl = plan_binary(scene, skip_geom: skip_geom)
        t0 = Time.now
        out = +''.b
        out << pl[:head] << pl[:json] << pl[:plan].join
        @pack_phase[:join_ms] = (Time.now - t0) * 1000.0
        [out, pl[:sizes]]
      end

      def pack_phase
        @pack_phase || {}
      end

      def write_binary(path, scene)
        bytes, sizes = pack_binary(scene)
        File.open(path, 'wb') { |f| f.write(bytes) }
        sizes
      end

      # ------------------------------------------------------------ 캐시 제어

      def cache_status
        st = @def_cache ? @def_cache.status : { entries: 0, dirty: 0, observers: 0, materials_observer: false }
        puts "정의 캐시: 항목 #{st[:entries]} / 무효 #{st[:dirty]} / 옵저버 #{st[:observers]}"              " / 머티리얼 감시 #{st[:materials_observer] ? 'O' : 'X'}"
        st
      end

      # 마지막 동기화 이후 무효화된 정의를 보고한다.
      # 편집 -> dirty_report 순서로 호출하면 "이 편집이 얼마를 다시 추출하게 하는가"가 나온다.
      def dirty_report(rate: 31_637.0)
        unless @def_cache
          puts '캐시가 없습니다. 먼저 IRIS::Probe.run 을 실행하십시오.'
          return nil
        end
        d = @def_cache.dirty_entries
        st = @def_cache.status

        tris = d.values.sum { |e| e[:tris] }
        puts ''
        puts "무효화된 정의: #{d.size} / #{st[:entries]}"
        puts "재추출할 삼각형: #{tris} (전체 대비 계산은 리포트 참조)"
        puts format('예상 재추출 시간: %.1f ms  (기준 %d tri/s)', 1000.0 * tris / rate, rate)
        unless d.empty?
          puts ''
          puts '  상위 무효 정의 (삼각형 기준):'
          d.sort_by { |_, e| -e[:tris] }.first(10).each do |k, e|
            puts format('    entityID %-12s 삼각형 %6d  면 %6d', k.to_s, e[:tris], e[:faces])
          end
        end
        { dirty: d.size, total: st[:entries], tris: tris,
          est_ms: (1000.0 * tris / rate).round(1) }
      end

      # 옵저버를 떼고 캐시를 비운다. 모델을 바꿔 열기 전에 반드시 호출할 것 —
      # entityID 가 다시 매겨지므로 그대로 두면 엉뚱한 정의를 재사용한다.
      def cache_clear
        @def_cache&.detach_all
        @def_cache = nil
        @cache = nil
        puts '정의 캐시를 비우고 옵저버를 해제했습니다.'
        true
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

        # 재질을 살아 있는 것으로 다시 읽었으면 표시를 지웁니다.
        @cache.clear_materials_stale if @refresh_materials && @cache

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
          # ⚠ 타임스탬프를 여기에 넣지 마십시오.
          #
          # 넣으면 **편집이 없어도 매 추출마다 바이트가 달라집니다.** 그러면
          # "내용이 같으면 보내지 않는다"가 성립하지 않아 자동 동기화가 멈추지
          # 않고, 렌더러는 매번 누적을 초기화해 화면이 영원히 수렴하지 않습니다.
          # 실제로 그렇게 됐습니다 — 렌더러 로그에 재로딩 478회가 찍혔습니다.
          #
          # 씬 페이로드는 **내용만** 담습니다. 생성 시각 같은 것은 연결 단위
          # 메시지(Hello)에 실립니다.
          'capabilities' => @caps,
          'materials'    => @materials.values,
          'views'        => (@scene_views_list = collect_views(model)),
          'sun'          => (@sun = collect_sun(model)),
          'definitions'  => @definitions,
          'root'         => { 'meshes' => root_meshes, 'children' => root_children },
          'stats'        => scene_stats,
        }
      end

      # 씬 페이로드에 실을 통계.
      #
      # **씬을 설명하는 값만 담습니다.** 이번 실행이 어땠는지(캐시가 몇 개
      # 맞았는지, 텍스처를 새로 뽑았는지)는 빼야 합니다.
      #
      # 그것들이 들어가면 편집이 없어도 실행마다 바이트가 달라집니다. 그러면
      # "내용이 같으면 보내지 않는다"가 성립하지 않아 자동 동기화가 멈추지 않고,
      # 렌더러는 매번 누적을 초기화해 화면이 영원히 수렴하지 않습니다.
      # 실제로 그렇게 됐습니다 — generated 를 뺀 뒤에도 여기서 계속 달라졌습니다.
      #
      # 실행 통계는 @stats 에 그대로 남아 report 에 나옵니다.
      SCENE_STAT_KEYS = %w[
        faces triangles vertices instances definitions face_errors groups_skipped
      ].freeze

      def scene_stats
        SCENE_STAT_KEYS.each_with_object({}) { |k, h| h[k] = @stats[k] }
      end

      # entities를 훑어 면은 메시로 누적하고, 인스턴스는 children에 추가한다.
      # skip_faces: 캐시 적중 시 면 추출만 건너뛴다. 자식 인스턴스는 여전히 훑어야
      # 하는데, 벤치마크에서 면 순회 자체는 사실상 공짜였으므로(49M tri/s) 비용이 없다.
      # counts: 넘기면 **이 레벨만의** 면/삼각형/정점 수를 채운다.
      #   @stats 델타로 재면 자식 정의의 추출분까지 섞여 들어간다
      #   (collect_entities 가 자식 인스턴스를 만나면 그 정의도 추출하므로).
      #   캐시에 그 값을 넣으면 적중 시 자손이 조상 수만큼 중복 계산된다 — 실측 5.4배.
      def collect_entities(entities, children, skip_faces: false, counts: nil, kids: nil)
        buckets = {}
        entities.each do |e|
          case e
          when Sketchup::Face
            accumulate_face(e, buckets, counts) unless skip_faces
          when Sketchup::ComponentInstance
            children << instance_entry(e, e.definition)
            kids << e if kids
          when Sketchup::Group
            defn = group_definition(e)
            if defn
              children << instance_entry(e, defn)
              kids << e if kids
            else
              @stats['groups_skipped'] += 1
            end
          end
        end
        skip_faces ? nil : finalize_buckets(buckets, counts)
      end

      # 캐시된 자식 엔티티에서 배치 레코드를 다시 만든다.
      # 면을 건드리지 않는 것이 요점이다.
      def children_from_cache(kids, children)
        kids.each do |e|
          defn = e.is_a?(Sketchup::Group) ? group_definition(e) : (e.definition rescue nil)
          if defn
            children << instance_entry(e, defn)
          else
            @stats['groups_skipped'] += 1
          end
        end
      end

      def instance_entry(inst, defn)
        @stats['instances'] += 1
        # 렌더러는 hidden 노드를 통째로 건너뜁니다(SceneBuilder.cpp:409) —
        # 그 아래 가지까지 전부. 보냈는데 화면에 없는 것이 여기서 생기므로
        # 세어서 리포트에 적습니다. 조용히 사라지면 원인을 엉뚱한 데서 찾습니다.
        hidden = (inst.hidden? rescue false)
        @stats['instances_hidden'] += 1 if hidden
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
          'hidden'        => hidden,
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

        # Enscape 조명이면 지오메트리를 뽑지 않는다.
        #
        # 이 정의들은 **광원 자리를 표시하는 프록시**입니다. Enscape 도 렌더에
        # 그리지 않습니다. 그리면 조명 앞에 작은 물체가 떠서 빛을 가립니다.
        # 대신 인스턴스마다 광원 노드를 만듭니다 — 위치와 방향은 그 인스턴스의
        # 변환에서 나오므로 씬 그래프가 알아서 합성합니다.
        # Enscape 원격 자산 — 실물이 .skp 안에 없습니다. 자세한 이유는
        # IRIS::Enscape.asset 주석. 그릴 수 없으니 세어서 알립니다.
        begin
          @definitions[key]['enscape_remote'] = true if IRIS::Enscape.remote_asset?(defn)
        rescue StandardError
          nil
        end

        spec = light_spec(defn)
        if spec
          @definitions[key]['light']         = spec
          @definitions[key]['persistent_id'] = safe_pid(defn)
          @definitions[key]['is_group']      = false
          @stats['definitions'] += 1
          @stats['lights_defs']  = (@stats['lights_defs'] || 0) + 1
          return key
        end

        children = []

        hit = @cache && @cache.fetch(defn)
        if hit
          # 자식 엔티티를 들고 있고 아직 유효하면 **면을 아예 훑지 않는다.**
          # 값은 새로 읽으므로 숨김·이름 변경도 반영된다.
          reuse = @cache.reusable_children(defn, hit)
          if reuse
            children_from_cache(reuse, children)
            @stats['kids_reused'] = (@stats['kids_reused'] || 0) + 1
          else
            collect_entities(defn.entities, children, skip_faces: true)
            @stats['kids_rescanned'] = (@stats['kids_rescanned'] || 0) + 1
          end
          meshes = hit[:meshes]
          gen    = hit[:gen]
          # 캐시된 메시가 참조하는 머티리얼 레코드를 이번 실행의 목록에 되살린다.
          #
          # 재질이 바뀌었으면 캐시된 레코드는 낡았습니다. 살아 있는 재질에서
          # 다시 읽습니다 — **지오메트리는 다시 뽑지 않습니다.**
          hit[:mats].each do |mid, rec|
            next if @materials.key?(mid)
            live = stale_material?(mid) ? @mat_index[mid] : nil
            # 캐시 항목의 rec 은 추출 시점의 것입니다. 그 뒤에 다시 읽은 것이
            # 있으면 그쪽이 최신입니다.
            live ? register_material(live) : (@materials[mid] = @cache&.material_record(mid) || rec)
          end
          @stats['vertices']  += hit[:verts]
          @stats['triangles'] += hit[:tris]
          @stats['faces']     += hit[:faces]
          if hit[:seen]
            @seen[:normals] ||= hit[:seen][:normals]
            @seen[:uvs]     ||= hit[:seen][:uvs]
          end
          @stats['defs_cached'] += 1
        else
          local = { faces: 0, tris: 0, verts: 0 }
          kids   = []
          meshes = collect_entities(defn.entities, children, counts: local, kids: kids)
          if @cache
            mats = {}
            meshes.each do |mb|
              mid = mb['material']
              mats[mid] = @materials[mid] if mid && @materials[mid]
            end
            @cache.store(defn, meshes, mats,
                         local[:verts], local[:tris], local[:faces],
                         { normals: @seen[:normals], uvs: @seen[:uvs] }, kids)
            gen = @cache.fetch(defn)&.fetch(:gen, nil)
          end
          # 캐시가 없으면 판을 매길 수 없습니다 — 매번 새 값이어야 하므로
          # 델타가 성립하지 않고, 그때는 항상 전체를 보냅니다.
          gen ||= (@nocache_gen = @nocache_gen.to_i + 1) * -1
          @stats['defs_extracted'] += 1
        end

        @definitions[key]['meshes']        = meshes
        @definitions[key]['children']      = children
        @definitions[key]['gen']           = gen
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
      # ⚠ 재질을 뒷면에서 가져왔으면 **UV 도 뒷면 것**이어야 합니다.
      #
      # SketchUp 의 면은 앞뒤가 각각 재질과 UV 를 따로 가집니다. 반대편에서
      # 페인트를 칠하면 재질이 뒷면에 붙는데(아주 흔합니다), 그때 앞면 UV 로
      # 그리면 **텍스처가 좌우로 뒤집힙니다.** 실제로 로고 글자가 거울상으로
      # 나왔습니다.
      #
      # 보이는 쪽이 뒷면이므로 법선과 감김 방향도 함께 뒤집습니다. 그러지
      # 않으면 빛을 뒤에서 받는 것으로 계산됩니다.
      def accumulate_face(face, buckets, counts = nil)
        front = (face.material rescue nil)
        back  = (face.back_material rescue nil)
        use_back = front.nil? && !back.nil?
        mat  = front || back
        @stats['back_faces'] = (@stats['back_faces'] || 0) + 1 if use_back
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
            sign = use_back ? -1.0 : 1.0
            buf['n'].push(n.x.to_f * sign, n.y.to_f * sign, n.z.to_f * sign)
          else
            buf['n'].push(0.0, 0.0, use_back ? -1.0 : 1.0)
          end

          # ⚠ **v 를 뒤집습니다.**
          #
          # SketchUp 의 텍스처 좌표는 v 가 **위로** 증가하고 이미지의 아래쪽
          # 행이 v=0 입니다. 렌더러(glTF·D3D 관례)는 이미지의 **첫 행**이
          # v=0 입니다. 그대로 넘기면 텍스처가 세로로 어긋납니다.
          #
          # 실측: 로고가 한 면에 **두 번** 나왔습니다. 오프라인으로 우리가 보낸
          # UV·텍스처·변환·카메라만 가지고 깊이 버퍼를 넣어 그렸더니 렌더 화면이
          # 그대로 재현됐고, v 를 뒤집으면 **한 번, 제자리**가 됐습니다.
          # 서로 다른 두 텍스처에서 같은 결론이 나왔습니다.
          uv = (mesh.uv_at(i, !use_back) rescue nil)
          if uv
            @seen[:uvs] = true
            q = (uv.z.nil? || uv.z.abs < 1e-12) ? 1.0 : uv.z
            buf['uv'].push((uv.x / q).to_f, (1.0 - uv.y / q).to_f)
          else
            buf['uv'].push(0.0, 0.0)
          end
        end

        mesh.polygons.each do |poly|
          next unless poly.length == 3
          # 인덱스는 1-based이며 부호는 에지 가시성을 뜻한다 -> abs 필수
          a = base + poly[0].abs - 1
          b = base + poly[1].abs - 1
          c = base + poly[2].abs - 1
          # 뒷면을 보여 주는 면은 감김도 뒤집어 기하 법선을 셰이딩 법선과 맞춥니다.
          use_back ? buf['i'].push(a, c, b) : buf['i'].push(a, b, c)
          @stats['triangles'] += 1
          counts[:tris] += 1 if counts
        end
        @stats['faces'] += 1
        counts[:faces] += 1 if counts

        if (@stats['faces'] % PROGRESS_EVERY).zero?
          Sketchup.status_text =
            "IRIS 추출 중… 면 #{@stats['faces']} / 삼각형 #{@stats['triangles']}"
        end
        raise BudgetExceeded if @limit && @stats['triangles'] > @limit
      end

      # 정점 데이터를 **여기서 한 번만** 이진으로 인코딩합니다.
      #
      # 예전에는 Ruby 배열로 들고 있다가 동기화할 때마다 pack 했습니다. 그런데
      # 그 배열은 캐시에 그대로 있는 **변하지 않는 데이터**입니다 — 매번 다시
      # 인코딩할 이유가 없습니다. 실측으로 블롭 만들기가 367 ms 였고, 그것이
      # 직렬화 446 ms 의 82% 였습니다.
      #
      # 미리 인코딩해 두면 동기화는 **이어붙이기만** 하면 됩니다. 그리고 이
      # 조각들이 곧 델타가 보낼 단위이기도 합니다.
      #
      # 메모리도 줄어듭니다 — f32 는 4바이트인데 Ruby 배열의 Float 는 8바이트입니다.
      def finalize_buckets(buckets, counts = nil)
        buckets.map do |mkey, b|
          n = b['p'].length / 3
          @stats['vertices'] += n
          counts[:verts] += n if counts
          {
            'material' => (mkey == '__default__' ? nil : mkey),
            'bin'      => {
              'p'  => b['p'].pack('e*'),  'n' => b['n'].pack('e*'),
              'uv' => b['uv'].pack('e*'), 'i' => b['i'].pack('V*'),
            },
            'count'    => {
              'p'  => b['p'].length,  'n' => b['n'].length,
              'uv' => b['uv'].length, 'i' => b['i'].length,
            },
          }
        end
      end

      # Enscape 조명 정의인가. 사전이 없거나 파싱이 안 되면 nil.
      def light_spec(defn)
        IRIS::Enscape.light(defn)
      rescue StandardError => e
        @enscape_errors = (@enscape_errors || 0) + 1
        @enscape_last_error ||= e.message
        nil
      end

      # 이 재질을 다시 읽어야 하는가.
      #
      # @stale_mat_ids 가 nil 이면 '어느 것인지 모른다' 이므로 전부입니다
      # (onMaterialRemoveAll, 또는 entityID 를 못 읽은 경우).
      def stale_material?(mid)
        return false unless @refresh_materials
        @stale_mat_ids.nil? || @stale_mat_ids.key?(mid)
      end

      def register_material(mat)
        key = "mat_#{mat.entityID}"
        return key if @materials.key?(key)

        # 지목된 재질을 실제로 다시 읽은 횟수. 여기서 세야 루트에 칠해진
        # 재질까지 셉니다.
        @stats['materials_refreshed'] += 1 if stale_material?(key)

        c   = (mat.color rescue nil)
        tex = (mat.texture rescue nil)
        @materials[key] = {
          'id'      => key,
          'name'    => (mat.name rescue ''),
          # **선형 색으로 보냅니다.** SketchUp 의 Color 는 화면 표시용 sRGB 이고,
          # 렌더러(와 05번 명세)는 선형을 기대합니다. 변환하지 않으면 모든 색이
          # 밝게 뜹니다 — sRGB 0.5 는 선형 0.21 입니다.
          'color'   => c ? [srgb_to_linear(c.red / 255.0),
                            srgb_to_linear(c.green / 255.0),
                            srgb_to_linear(c.blue / 255.0)] : [1.0, 1.0, 1.0],
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

        # Enscape 가 남긴 PBR 파라미터. 있으면 그대로 씁니다 — 추측한
        # roughness 0.5 / metalness 0 고정보다 언제나 낫습니다.
        begin
          pbr = IRIS::Enscape.material(mat)
          @materials[key]['pbr'] = pbr if pbr
        rescue StandardError => e
          @enscape_errors = (@enscape_errors || 0) + 1
          @enscape_last_error ||= e.message
        end

        # 이 실행에서 살아 있는 재질로부터 만든 레코드입니다. 캐시 항목이
        # 들고 있는 옛 레코드보다 항상 새것이므로 남겨 둡니다.
        @cache&.remember_material(key, @materials[key])

        key
      end

      def comma_i(v)
        v.to_i.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
      end

      # sRGB -> 선형. 표준 변환식입니다.
      def srgb_to_linear(c)
        c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4
      end

      # ------------------------------------------------------------ 저장된 시점
      #
      # SketchUp의 '장면(Page)'에는 설계자가 잡아둔 카메라가 들어 있다. 실무 모델에는
      # 보통 수십 개가 있고(이 모델은 20개 이상), 그것이 곧 "보여줄 시점"이다.
      # 임의로 카메라를 놓는 것보다 이 시점을 그대로 쓰는 것이 맞다.
      #
      # Enscape 계열 제품이 호스트의 뷰를 동기화하는 것도 같은 이유다.
      # ------------------------------------------------------------------ 태양
      #
      # SketchUp 은 인공 광원은 주지 않지만 **태양은 줍니다.** 그림자 설정에
      # 날짜·시각·위치가 들어 있고 그것으로 태양 방향이 정해집니다. 건축
      # 렌더러에서 이것은 선택 사항이 아닙니다 — 실외는 물론이고 실내도
      # 창으로 들어오는 빛이 그림의 대부분입니다.
      #
      # ⚠ SunDirection 은 **모델에서 태양을 향하는** 방향입니다. 빛이 나아가는
      #   방향은 그 반대입니다. 부호를 잘못 쓰면 그림자가 정반대로 집니다.
      def collect_sun(model)
        si = (model.shadow_info rescue nil)
        return nil unless si

        d = (si['SunDirection'] rescue nil)
        return nil unless d
        v = [d.x.to_f, d.y.to_f, d.z.to_f]
        len = Math.sqrt(v.inject(0.0) { |a, c| a + c * c })
        return nil if len < 1e-9
        v = v.map { |c| c / len }

        {
          # 태양을 향하는 단위 벡터 (모델 좌표계, Z-up)
          'toward'        => v,
          'shadows'       => (si['DisplayShadows'] rescue true) ? true : false,
          'use_sun_only'  => (si['UseSunForAllShading'] rescue false) ? true : false,
          # 0~100. Enscape 처럼 세기를 직접 주지는 않으므로 참고값입니다.
          'light'         => (si['Light'] rescue nil),
          'dark'          => (si['Dark'] rescue nil),
          'time'          => (si['ShadowTime'].to_s rescue nil),
          'city'          => (si['City'].to_s rescue nil),
          'latitude'      => (si['Latitude'] rescue nil),
          'longitude'     => (si['Longitude'] rescue nil),
          'tz_offset'     => (si['TZOffset'] rescue nil),
        }
      rescue StandardError => e
        @sun_error = e.message
        nil
      end

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
          # ⚠ SketchUp 의 fov 는 **수직일 수도 수평일 수도** 있습니다.
          # fov_is_height? 가 false 면 수평 화각입니다. 이 값을 함께 보내지 않으면
          # 렌더러가 수직으로 단정해 **보이는 범위가 달라집니다.**
          'fov_deg'       => (cam.fov rescue nil),
          'fov_is_height' => (cam.fov_is_height? rescue true),
          # 수평 화각을 수직으로 바꾸려면 종횡비가 필요합니다. cam.aspect_ratio 는
          # "창에 맞춤"이면 0 을 주므로 실제 뷰포트 비율을 함께 넘깁니다.
          'viewport_aspect' => (begin
            v = Sketchup.active_model.active_view
            v.vpheight.to_f > 0 ? (v.vpwidth.to_f / v.vpheight.to_f) : 0.0
          rescue StandardError
            0.0
          end),
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
        # 재질이 바뀌었으면 이미지 자체가 바뀌었을 수 있습니다. 파일이 있다고
        # 그냥 쓰면 낡은 그림이 남습니다.
        if stale_material?(key) && File.exist?(path)
          File.delete(path) rescue nil
        end
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
        # 뒷면에만 칠해진 면. 앞면 UV 로 그리면 텍스처가 거울상이 됩니다.
        w << "     뒷면 재질 면  : #{@stats['back_faces']}" if @stats['back_faces'].to_i > 0
        w << ''
        w << ' [1-b] 정의 캐시'
        w << "     신규 추출     : #{@stats['defs_extracted']}"
        w << "     캐시 적중     : #{@stats['defs_cached']}"
        if (@stats['defs_extracted'] + @stats['defs_cached']) > 0
          hit = 100.0 * @stats['defs_cached'] / (@stats['defs_extracted'] + @stats['defs_cached'])
          w << format('     적중률        : %.1f%%', hit)
        end
        if @refresh_materials
          # 재질만 바뀐 경우입니다. 지오메트리를 다시 뽑지 않은 것이 요점입니다.
          scope = @stale_mat_ids ? "#{@stale_mat_ids.size}종 지목" : '전체 (어느 것인지 모름)'
          w << "     재질 갱신     : #{@stats['materials_refreshed']}개 다시 읽음 / #{scope}"
          w << '                     (지오메트리는 재추출하지 않음)'
        end
        if (@stats['kids_reused'].to_i + @stats['kids_rescanned'].to_i) > 0
          # 자식을 되쓴 정의는 **면을 아예 훑지 않았습니다.** 이 모델에서
          # 면 순회가 추출 시간의 대부분이었습니다.
          w << "     자식 재사용   : #{@stats['kids_reused']} / 재순회 #{@stats['kids_rescanned']}"
        end
        w << ''
        w << ' [2] 인스턴싱 (= BLAS 재사용)'
        w << "     정의 수       : #{defs}"
        w << "     인스턴스 수   : #{insts}"
        w << format('     재사용률      : %.2f 인스턴스/정의', reuse)
        w << "     스킵된 그룹   : #{@stats['groups_skipped']}"
        if @stats['instances_hidden'].to_i > 0
          # 보내지만 렌더러가 안 그립니다. 숨은 가지 아래도 전부입니다.
          w << "     숨김 인스턴스 : #{@stats['instances_hidden']} (렌더러가 건너뜁니다)"
        end
        rem = @definitions.each_value.select { |d| d['enscape_remote'] }
        unless rem.empty?
          n = rem.sum { |d| d['instance_count'].to_i }
          w << "     Enscape 원격 자산 : #{rem.size}종 / #{n}개 — **그릴 수 없습니다**"
          w << '                     (실물이 Enscape 라이브러리에 있고 파일에는 껍데기만)'
          rem.first(5).each { |d| w << "                       #{d['name']}" }
        end
        w << ''
        w << ' [3] 머티리얼'
        w << "     고유 머티리얼 : #{@materials.size}"
        w << "     텍스처 보유   : #{@materials.values.count { |m| m['texture'] }}"
        with_tex  = @materials.values.count { |m| m['texture'] }
        with_file = @materials.values.count { |m| m['texture'] && m['texture']['export'] }
        w << "     이미지 확보   : #{with_file} / #{with_tex}"
        w << "     이번 실행     : #{@stats['textures_exported']} 신규 추출 / "              "#{@stats['textures_reused']} 기존 파일 재사용 / #{@stats['texture_errors']} 실패"
        w << '     (캐시 적중한 정의의 머티리얼은 재추출하지 않으므로 위 두 줄이 다릅니다)'              if @stats['defs_cached'] > 0
        w << "     추출 실패 사유: #{@texture_error_msg}" if @texture_error_msg
        w << ''
        w << "     저장된 시점   : #{(@scene_views_list || []).size}"
        if @sun
          z = @sun['toward'][2]
          elev = Math.asin([[z, -1.0].max, 1.0].min) * 180.0 / Math::PI
          w << format('     태양          : 고도 %+.1f도 · 그림자 %s · %s',
                      elev, @sun['shadows'] ? 'O' : 'X', @sun['time'].to_s[0, 24])
          w << format('                     위치 %s (위도 %.2f 경도 %.2f)',
                      @sun['city'].to_s, @sun['latitude'].to_f, @sun['longitude'].to_f)
          w << '                     ⚠ 지평선 아래입니다 — 햇빛이 없습니다' if elev <= 0
          w << '                     ⚠ 호스트에서 그림자가 꺼져 있습니다' unless @sun['shadows']
        else
          w << "     태양          : 없음#{@sun_error ? " (#{@sun_error})" : ''}"
        end
        w << "     시점 수집 오류: #{@views_error}" if @views_error
        w << ''
        w << ' [3-b] Enscape 설정 (조명·PBR)'
        lit  = @definitions.values.select { |d| d['light'] }
        linst = lit.sum { |d| @instance_count[d['id']] || 0 }
        pbrs = @materials.values.count { |m| m['pbr'] }
        if lit.empty? && pbrs.zero?
          w << '     (없음 — Enscape 로 작업된 모델이 아닙니다)'
        else
          w << "     조명 정의     : #{lit.size}종 / 인스턴스 #{linst}개 (프록시 지오메트리는 제외됨)"
          lit.group_by { |d| d['light']['kind'] }.sort_by { |k, _| k.to_s }.each do |kind, ds|
            n = ds.sum { |d| @instance_count[d['id']] || 0 }
            lm = ds.sum { |d| (d['light']['lumens'] || 0) * (@instance_count[d['id']] || 0) }
            w << format('       %-8s %2d종 · %3d개 · 총 %s lm', kind, ds.size, n, comma_i(lm))
          end
          w << "     PBR 재질      : #{pbrs} / #{@materials.size}"
          emi = @materials.values.select { |m| m['pbr'] && m['pbr']['emissive_cd'] }
          w << "     발광 재질     : #{emi.size}개" unless emi.empty?
        end
        w << "     Enscape 읽기 오류: #{@enscape_errors} (#{@enscape_last_error})" if @enscape_errors.to_i > 0
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
        if @write_elapsed
          label = @write_format == :binary ? '바이너리 기록' : 'JSON 기록   '
          w << format('     %s : %.1f ms', label, @write_elapsed * 1000.0)
          if @write_sizes
            w << format('       매니페스트  : %.2f MB', @write_sizes[:json] / 1048576.0)
            w << format('       지오메트리  : %.2f MB', @write_sizes[:bin] / 1048576.0)
          end
        end
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
          'defs_extracted' => 0, 'defs_cached' => 0, 'lights_defs' => 0,
          'kids_reused' => 0, 'kids_rescanned' => 0, 'back_faces' => 0,
          'materials_refreshed' => 0, 'instances_hidden' => 0,
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
        @write_sizes    = nil
        @write_format   = nil
        # @cache 는 여기서 지우지 않는다 — 세션 동안 유지되는 것이 목적이다
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
