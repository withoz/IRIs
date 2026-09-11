# encoding: UTF-8
#
# IRIS — IES 0도 방위, 통제된 시험
#
# 왜 통제가 필요한가
#   실제 모델(골프존)에서 0도와 90도를 각각 렌더해 견줬더니 **구별되지
#   않았습니다.** 배광이 1.65:1 로 완만하고, 광원 43개의 웅덩이가 겹치고,
#   빔이 닿는 바닥이 짙은 인조잔디라 무늬가 안 읽힙니다.
#
#   장면을 단순하게 만들면 못 볼 수가 없습니다 — **조명 하나, 흰 바닥,
#   빛 샐 곳 없는 방.**
#
# 무엇을 보게 되는가
#   조명을 로컬 +X 가 **월드 +X** 를 보도록 놓고, 똑바로 아래를 비춥니다.
#   카메라는 천장에서 바닥을 내려다보고 화면 위가 월드 +Y 입니다.
#
#   우리 기준(로컬 +X = IES 가로각 0도)이 맞으면
#     0도 평면(= 월드 X)이 **좁은 축**(반치각 18.0도)
#     90도 평면(= 월드 Y)이 **넓은 축**(29.8도)
#     -> 웅덩이가 화면에서 **세로로 길쭉**합니다.
#
#   90도 틀렸다면 정반대 — **가로로 길쭉**합니다.
#
#   1.65 : 1 이라 눈으로 바로 갈립니다.
#
# 쓰는 법 — SketchUp Ruby 콘솔
#   1) 골프존 모델에서 조명 컴포넌트를 파일로 빼냅니다 (한 번만):
#        d=Sketchup.active_model.definitions.to_a.find{|x| x.name=='Enscape.SpotLight#1'}
#        d.save_as('E:/IRIS/out/ies_light.skp')
#   2) 새 빈 모델을 만든 뒤:
#        load 'E:/IRIS/tools/sketchup/iris_ies_labtest.rb'
#        IRIS::IesLabTest.build
#
#   사용자 모델은 건드리지 않습니다 — 새 모델 안에서만 만듭니다.

require 'fileutils'

module IRIS
  module IesLabTest
    ROOM   = 300.0   # 방 한 변 (인치) — 7.6 m
    HEIGHT = 250.0   # 천장 높이 — 6.35 m
    LAMP_Z = 180.0   # 조명 높이 — 4.6 m
    LIGHT  = 'E:/IRIS/out/ies_light.skp'

    class << self
      def build(path: LIGHT)
        model = Sketchup.active_model
        return puts('[IRIS] 활성 모델이 없습니다.') unless model

        if model.entities.length > 0
          puts '[IRIS] 이 모델은 비어 있지 않습니다. 새 빈 모델에서 부르십시오.'
          puts "        (엔티티 #{model.entities.length}개)"
          return nil
        end

        @log = []
        say "시각: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"

        defn = model.definitions.load(path)
        unless defn
          say "조명 컴포넌트를 읽지 못했습니다: #{path}"
          return finish
        end
        say "조명 컴포넌트: #{defn.name}"

        model.start_operation('IRIS IES 통제 시험', true)
        begin
          ents = model.entities
          h = ROOM / 2.0

          floor = make_material(model, 'IRIS_Floor', [235, 235, 235])
          dark  = make_material(model, 'IRIS_Dark',  [18, 18, 18])
          mark  = make_material(model, 'IRIS_MarkX', [220, 40, 40])

          # 바닥 — 흰색. 여기에 웅덩이가 그려집니다.
          f = ents.add_face([-h, -h, 0], [h, -h, 0], [h, h, 0], [-h, h, 0])
          f.material = floor
          f.back_material = floor

          # 벽 넷 + 천장 — 빛이 새지 않게 닫습니다. 어둡게 해서 바운스를
          # 줄입니다. 하늘이 들어오면 웅덩이 대비가 죽습니다.
          walls = [
            [[-h, -h, 0], [h, -h, 0], [h, -h, HEIGHT], [-h, -h, HEIGHT]],
            [[-h,  h, 0], [h,  h, 0], [h,  h, HEIGHT], [-h,  h, HEIGHT]],
            [[-h, -h, 0], [-h, h, 0], [-h, h, HEIGHT], [-h, -h, HEIGHT]],
            [[ h, -h, 0], [ h, h, 0], [ h, h, HEIGHT], [ h, -h, HEIGHT]]
          ]
          walls.each do |pts|
            w = ents.add_face(pts)
            w.material = dark
            w.back_material = dark
          end
          c = ents.add_face([-h, -h, HEIGHT], [h, -h, HEIGHT], [h, h, HEIGHT], [-h, h, HEIGHT])
          c.material = dark
          c.back_material = dark

          # **+X 표시.** 화면에서 어느 쪽이 월드 +X 인지 눈으로 확인합니다.
          # 웅덩이 밖(바닥 가장자리)에 둡니다.
          m = ents.add_face([h - 60, -h + 6, 0.05], [h - 6, -h + 6, 0.05],
                            [h - 6, -h + 18, 0.05], [h - 60, -h + 18, 0.05])
          m.material = mark
          m.back_material = mark

          # 조명 — 로컬 +X 를 월드 +X 로, 정면(로컬 +Z)을 아래로.
          #
          #   x=(1,0,0)  y=(0,-1,0)  z=(0,0,-1)     x cross y = z  (오른손)
          #
          # 프록시의 정면이 로컬 +Z 인 것은 실측입니다(SceneBuilder.cpp 주석).
          tr = Geom::Transformation.axes(Geom::Point3d.new(0, 0, LAMP_Z),
                                         Geom::Vector3d.new(1, 0, 0),
                                         Geom::Vector3d.new(0, -1, 0),
                                         Geom::Vector3d.new(0, 0, -1))
          inst = ents.add_instance(defn, tr)
          inst.name = 'IES_TEST'

          model.commit_operation
        rescue StandardError => e
          model.abort_operation
          say "!! 만들다 실패: #{e.class}: #{e.message}"
          return finish
        end

        # 태양은 끕니다 — 있으면 웅덩이가 묻힙니다.
        si = model.shadow_info
        si['DisplayShadows'] = false
        si['UseSunForAllShading'] = false

        aim
        report(inst)
        finish
      rescue StandardError => e
        say "!! 실패: #{e.class}: #{e.message}"
        (e.backtrace || []).first(8).each { |l| say "   #{l}" }
        finish
      end

      # 천장에서 바닥을 똑바로 내려다봅니다. 화면 위 = 월드 +Y.
      def aim
        v = Sketchup.active_model.active_view
        v.camera = Sketchup::Camera.new(
          Geom::Point3d.new(0, 0, HEIGHT - 6),
          Geom::Point3d.new(0, 0, 0),
          Geom::Vector3d.new(0, 1, 0)
        )
        v.camera.fov = 70
        (IRIS::Link.camera(force: true) rescue nil)
      end

      def report(inst)
        t = inst.transformation
        say ''
        say '=' * 70
        say '놓은 대로'
        say '=' * 70
        say format('  조명 위치 (0, 0, %.0f) 인치 · 바닥까지 %.1f m', LAMP_Z, LAMP_Z * 0.0254)
        say format('  로컬 +X -> 월드 (%.3f %.3f %.3f)', t.xaxis.x, t.xaxis.y, t.xaxis.z)
        say format('  로컬 +Y -> 월드 (%.3f %.3f %.3f)', t.yaxis.x, t.yaxis.y, t.yaxis.z)
        say format('  로컬 +Z -> 월드 (%.3f %.3f %.3f)  (정면)', t.zaxis.x, t.zaxis.y, t.zaxis.z)
        say ''
        say '  카메라: 천장에서 수직 아래. **화면 위 = 월드 +Y, 오른쪽 = +X**'
        say '  빨간 막대가 바닥 오른쪽 아래에 보입니다 — 그쪽이 +X 입니다.'
        say ''
        say '=' * 70
        say '읽는 법'
        say '=' * 70
        say '  세로로 길쭉  -> 넓은 축(29.8도)이 월드 Y   -> **가정이 맞습니다**'
        say '  가로로 길쭉  -> 넓은 축이 월드 X          -> **90도 틀렸습니다**'
        say ''
        say '  배광 자체가 1.65 : 1 (29.8도 대 18.0도) 이라 눈으로 갈립니다.'
      end

      def make_material(model, name, rgb)
        m = model.materials[name] || model.materials.add(name)
        m.color = Sketchup::Color.new(*rgb)
        m.alpha = 1.0
        m
      end

      def say(line)
        @log ||= []
        @log << line.to_s
        puts line
      end

      def finish
        dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'ies_labtest.txt')
        File.open(path, 'w:UTF-8') { |f| (@log || []).each { |l| f.puts l } }
        puts "저장: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "저장 실패: #{e.message}"
        nil
      end
    end
  end
end

puts '[IRIS] IesLabTest 로드 완료 — 빈 모델에서 IRIS::IesLabTest.build'
