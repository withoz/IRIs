# encoding: UTF-8
#
# IRIS — SketchUp 라이브 링크 송신부
#
# SketchUp 모델을 실행 중인 IRIS 렌더러로 보냅니다. 파일을 거치지 않고
# 명명 파이프로 곧바로 넘깁니다.
#
#   Hello      -> HelloAck    프로토콜 버전 교환, 텍스처 기준 경로 통지
#   SyncBegin
#   SceneBlob                 .irisb 바이트 그대로
#   SyncEnd    -> SyncAck
#
# 파이프는 **일반 파일 열기**로 엽니다 — gem 이 필요 없습니다.
# 형식 명세는 docs/07-프로토콜-수신부-설계.md 7.1절.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_probe.rb'
#   load 'E:/IRIS/tools/sketchup/iris_link.rb'
#
#   IRIS::Link.sync          # 한 번 보낸다 (추출 + 직렬화 + 전송)
#   IRIS::Link.auto          # 편집을 감시하다가 바뀌면 자동으로 보낸다
#   IRIS::Link.auto_stop
#   IRIS::Link.status
#
# 렌더러(Rtxpt.exe)가 먼저 떠 있어야 합니다.

require 'json'

module IRIS
  module Link
    PROTOCOL_VERSION = 1

    MSG_HELLO      = 1
    MSG_HELLO_ACK  = 2
    MSG_SYNC_BEGIN = 3
    MSG_SCENE_BLOB = 4
    MSG_SYNC_END   = 5
    MSG_SYNC_ACK   = 6
    MSG_BYE        = 7
    MSG_CAMERA     = 8

    MSG_NAMES = {
      MSG_HELLO => 'Hello', MSG_HELLO_ACK => 'HelloAck',
      MSG_SYNC_BEGIN => 'SyncBegin', MSG_SCENE_BLOB => 'SceneBlob',
      MSG_SYNC_END => 'SyncEnd', MSG_SYNC_ACK => 'SyncAck', MSG_BYE => 'Bye',
      MSG_CAMERA => 'Camera'
    }.freeze

    class << self

      # ---------------------------------------------------------------- 주 진입점

      # 한 번 보냅니다. 추출·직렬화·전송을 전부 합니다.
      #
      # 캐시가 살아 있으면 바뀐 정의만 다시 추출하고, 렌더러가 이미 가진
      # 지오메트리는 보내지 않습니다(docs/05-씬-델타-프로토콜.md 6절).
      #
      #   force — 바뀐 게 없어도 보냅니다. **델타는 그대로 적용됩니다**
      #   full  — 렌더러가 이미 가진 지오메트리까지 전부 다시 보냅니다
      #
      # 둘을 하나로 묶어 뒀다가 델타가 켜졌는지 확인할 수 없었습니다 —
      # "다시 보낸다"와 "전부 보낸다"는 다른 뜻입니다.
      #
      # 예외는 out/sketchup/sync_error.txt 에 남깁니다. SketchUp 콘솔의 예외는
      # 화면 밖의 사람에게 전달되지 않기 때문입니다.
      def sync(pipe: 'iris', textures: true, force: false, full: false)
        sync_inner(pipe: pipe, textures: textures, force: force, full: full)
      rescue StandardError, ScriptError => e
        log_failure(e)
        raise
      end

      # 어떤 파일을 보고 있는가. 저장 전이면 경로가 없으므로 guid 로.
      def model_key(model)
        path = (model.path.to_s rescue '')
        path.empty? ? "guid:#{(model.guid rescue model.object_id)}" : "path:#{path}"
      end

      def log_failure(e)
        dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        require 'fileutils'
        FileUtils.mkdir_p(dir)
        File.open(File.join(dir, 'sync_error.txt'), 'w:UTF-8') do |f|
          f.puts Time.now.strftime('%Y-%m-%d %H:%M:%S')
          f.puts "#{e.class}: #{e.message}"
          (e.backtrace || []).first(20).each { |l| f.puts "  #{l}" }
        end
        say "실패를 out/sketchup/sync_error.txt 에 남겼습니다: #{e.class} — #{e.message}"
      rescue StandardError
        nil
      end

      def sync_inner(pipe: 'iris', textures: true, force: false, full: false)
        model = Sketchup.active_model
        return say('활성 모델이 없습니다.') unless model
        return say('iris_probe.rb 를 먼저 로드하십시오.') unless defined?(IRIS::Probe)

        # **모델이 바뀌면 델타를 처음부터 다시 시작합니다.**
        #
        # @sent_gen 은 정의 id(entityID 기반)로 "렌더러가 이미 가졌다"를
        # 기억합니다. 그런데 entityID 는 **모델마다 다시 매겨집니다.** 다른
        # 파일을 열면 같은 번호가 전혀 다른 정의를 가리키고, 그러면 보내야 할
        # 지오메트리를 '이미 있다'고 건너뜁니다 — 물체가 사라지고 오류는
        # 나지 않습니다.
        key = model_key(model)
        if @model_key && key != @model_key
          say '모델이 바뀌었습니다 — 전체를 다시 보냅니다.'
          @sent_gen = {}
          @last_sig = nil
          full = true
        end
        @model_key = key

        log_line("===== sync force=#{force} full=#{full} =====")
        t_extract0 = Time.now
        IRIS::Probe.run(dump: false, textures: textures, cache: true)
        scene = IRIS::Probe.last_scene
        return say('씬 추출에 실패했습니다.') unless scene
        extract_ms = (Time.now - t_extract0) * 1000.0

        # **직렬화는 연결 뒤로 미룹니다.**
        #
        # 무엇을 보낼지는 렌더러가 무엇을 갖고 있느냐에 달렸고, 그건 Hello 를
        # 주고받아야 압니다. 미리 직렬화하면 델타를 정할 수 없습니다.
        pack_ms = 0.0

        # **결과로 판단합니다.** 캐시가 "바뀌었다"고 해도 만들어진 바이트가
        # 지난번과 같으면 보내지 않습니다.
        #
        # 옵저버는 우리가 읽는 동작에도 반응할 수 있고, 그러면 편집이 없는데도
        # 매초 동기화가 돌아 렌더러가 누적을 계속 초기화합니다 — 화면이 영원히
        # 수렴하지 않습니다. 무효화가 왜 생겼는지와 무관하게, 내용이 같으면
        # 보내지 않는 것이 옳습니다.
        #
        # 비교는 매니페스트 JSON 하나입니다. 지오메트리는 정의마다 **판(gen)**
        # 이 붙어 있고 다시 추출될 때만 올라가므로, 매니페스트만 같으면 씬 전체가
        # 같습니다. 36 MB 를 들고 있으면서 비교할 필요가 없어졌습니다.
        sig = IRIS::Probe.plan_binary(scene)[:json]
        if !force && @last_sig && @last_sig == sig
          @skipped = @skipped.to_i + 1

          # 무효화 표시는 **증명된 거짓**입니다 — 다시 뽑아 봤는데 내용이
          # 같았습니다. 지우지 않으면 다음 틱에도 또 뽑게 되어, 편집이 없는데도
          # 매초 전체 추출이 돕니다.
          cache0 = IRIS::Probe.instance_variable_get(:@def_cache)
          cache0&.clear_dirty
          cache0&.clear_materials_stale if cache0.respond_to?(:clear_materials_stale)

          # 매번 찍으면 콘솔이 계속 도는 것처럼 보입니다. 처음 몇 번과
          # 이후 가끔만 알립니다.
          if @skipped <= 3 || (@skipped % 30).zero?
            say format('변경 없음 — 보내지 않습니다 (추출 %.0f ms · 연속 %d회)',
                       extract_ms, @skipped)
          end
          return true
        end

        # 크기가 같은데 내용이 다르면 어디가 다른지 알려줍니다.
        # 편집이 없는데 매번 달라지면 씬에 비결정적 필드가 들어 있다는 뜻이고,
        # 그러면 "변경 없음" 판정이 영영 성립하지 않습니다 — 실제로 겪었습니다.
        if @last_sig && @last_sig.bytesize == sig.bytesize && @last_sig != sig
          off = first_diff(@last_sig, sig)
          say format('  매니페스트 크기는 같은데 내용이 다릅니다 (오프셋 %d): %s',
                     off, sig.byteslice([off - 30, 0].max, 80).inspect) if off
        end
        @skipped = 0

        t_send0 = Time.now
        ok, bytes, sizes, pack_ms = transmit(pipe, scene, full: full)
        send_ms = (Time.now - t_send0) * 1000.0 - pack_ms
        @last_sig = sig if ok
        unless bytes
          say '전송하지 못했습니다 — 렌더러(Rtxpt.exe)가 떠 있는지 보십시오.'
          log_timing(extract_ms, 0.0, send_ms, 0, scene['stats'] || {}, ok: false)
          return false
        end

        st = scene['stats'] || {}
        say ''
        say format('추출 %7.1f ms   삼각형 %s · 인스턴스 %s',
                   extract_ms, comma(st['triangles'].to_i), comma(st['instances'].to_i))
        say format('직렬화 %6.1f ms   %s bytes (JSON %s + 블롭 %s)',
                   pack_ms, comma(bytes.bytesize), comma(sizes[:json]), comma(sizes[:bin]))
        pp = IRIS::Probe.respond_to?(:pack_phase) ? IRIS::Probe.pack_phase : {}
        unless pp.empty?
          say format('  └ 블롭 %.1f · JSON %.1f · 조립 %.1f ms',
                     pp[:blob_ms].to_f, pp[:json_ms].to_f, pp[:join_ms].to_f)
        end
        if @diag
          say format('  └ 세션 %s (이전 %s) · 보유 판 %d개 · full=%s',
                     @diag[:session].inspect, @diag[:prev].inspect,
                     @diag[:sent_gen], @diag[:full])
        end
        gc = IRIS::Probe.respond_to?(:geom_counts) ? IRIS::Probe.geom_counts : nil
        if gc && gc[:skipped] > 0
          say format('  └ 지오메트리 %d개 실음 / %d개 생략 (렌더러가 이미 보유)',
                     gc[:sent], gc[:skipped])
        end
        say format('전송 %8.1f ms   %.0f MB/s', send_ms,
                   bytes.bytesize / 1048576.0 / [send_ms / 1000.0, 1e-9].max)
        if @phase
          say format('  └ 열기 %.1f · Hello %.1f · 쓰기 %.1f · Ack 대기 %.1f · Bye %.1f ms',
                     @phase[:open].to_f, @phase[:hello].to_f, @phase[:write].to_f,
                     @phase[:ack].to_f, @phase[:bye].to_f)
        end
        say format('합계 %8.1f ms', extract_ms + pack_ms + send_ms)

        # 추출 중 우리 스스로 만든 무효화. 0이 아니면 그만큼 옵저버가
        # 우리 읽기 동작에 반응했다는 뜻입니다 — 억제하지 않으면 자동 동기화가
        # 편집 없이도 매초 돕니다.
        sup = IRIS::Probe.instance_variable_get(:@suppressed)
        if sup && (sup[:elements].to_i + sup[:materials].to_i) > 0
          say format('  (추출 중 자체 무효화 억제: 엔티티 %d · 머티리얼 %d)',
                     sup[:elements].to_i, sup[:materials].to_i)
        end
        say(ok ? '렌더러 화면이 바뀌어야 합니다.' : '전송 실패 — 위 메시지를 보십시오.')
        log_timing(extract_ms, pack_ms, send_ms, bytes.bytesize, st)
        ok
      end

      # 왕복 시간을 파일에도 남깁니다.
      #
      # 콘솔에만 찍으면 나중에 "무엇이 얼마나 빨라졌는가"를 말할 수 없습니다.
      # 델타(5단계)는 정확히 그 질문에 답해야 하는 작업이므로, 고치기 전의
      # 숫자가 남아 있어야 합니다.
      def log_timing(extract_ms, pack_ms, send_ms, bytes, st, ok: true)
        dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        require 'fileutils'
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'sync_timing.csv')
        cols = %w[time ok extract_ms pack_ms blob_ms json_ms join_ms send_ms
                  open_ms hello_ms write_ms ack_ms bye_ms total_ms bytes
                  geom_sent geom_skipped session prev_session held_gen
                  triangles instances defs_extracted defs_cached].join(',')

        # **열이 바뀌었는데 옛 파일에 이어 붙이면 모든 값이 한 칸씩 밀립니다.**
        #
        # 콘솔에서 도구를 다시 로드하는 것이 이 도구의 정상적인 사용법이고,
        # 그때 열이 늘어날 수 있습니다. 조용히 틀린 표가 남고, 나중에 그 표를
        # 믿고 판단합니다. 머리글이 다르면 옛 파일을 옆으로 치웁니다.
        if File.exist?(path)
          first = (File.open(path, 'r:UTF-8', &:gets).to_s.chomp rescue nil)
          if first != cols
            stamp = Time.now.strftime('%m%d_%H%M%S')
            begin
              File.rename(path, File.join(dir, "sync_timing_#{stamp}.csv"))
            rescue StandardError
              File.delete(path) rescue nil
            end
          end
        end

        head = !File.exist?(path)
        File.open(path, 'a:UTF-8') do |f|
          f.puts(cols) if head
          ph = @phase || {}
          pp = IRIS::Probe.respond_to?(:pack_phase) ? IRIS::Probe.pack_phase : {}
          f.puts([Time.now.strftime('%H:%M:%S'), (ok ? 'ok' : 'FAIL'),
                  format('%.1f', extract_ms), format('%.1f', pack_ms),
                  format('%.1f', pp[:blob_ms].to_f), format('%.1f', pp[:json_ms].to_f),
                  format('%.1f', pp[:join_ms].to_f),
                  format('%.1f', send_ms),
                  format('%.1f', ph[:open].to_f),  format('%.1f', ph[:hello].to_f),
                  format('%.1f', ph[:write].to_f), format('%.1f', ph[:ack].to_f),
                  format('%.1f', ph[:bye].to_f),
                  format('%.1f', extract_ms + pack_ms + send_ms), bytes,
                  (IRIS::Probe.respond_to?(:geom_counts) ? IRIS::Probe.geom_counts[:sent] : 0),
                  (IRIS::Probe.respond_to?(:geom_counts) ? IRIS::Probe.geom_counts[:skipped] : 0),
                  (@diag || {})[:session].inspect, (@diag || {})[:prev].inspect,
                  (@diag || {})[:sent_gen],
                  st['triangles'].to_i, st['instances'].to_i,
                  IRIS::Probe.instance_variable_get(:@stats)&.fetch('defs_extracted', 0).to_i,
                  IRIS::Probe.instance_variable_get(:@stats)&.fetch('defs_cached', 0).to_i].join(','))
        end
      rescue StandardError
        nil
      end

      # ---------------------------------------------------------------- 전송 실측

      # 전송이 왜 느린지 재는 도구.
      #
      # 실측: 36 MB 에 1066 ms = **34 MB/s**. 같은 파이프에 Python 참조 구현은
      # 2029 MB/s 를 냅니다. 60배 차이이므로 파이프가 아니라 Ruby 쪽 쓰기
      # 방식의 문제입니다. 어느 방식이 빠른지는 **재서** 정합니다.
      #
      # 모르는 프레임 종류는 서버가 읽고 버립니다(05번 9절). 그래서 씬을
      # 다시 만들게 하지 않고 순수 전송 속도만 잴 수 있습니다.
      #
      # 사용법:  IRIS::Link.bench_transport
      BENCH_TYPE = 9999

      def bench_transport(pipe: 'iris', mb: 32)
        payload = ('x' * (1024 * 1024)).b * mb
        io = open_pipe(pipe_path(pipe))
        return say('파이프를 열지 못했습니다.') unless io

        @bench_log = []
        results = []
        begin
          send_frame(io, MSG_HELLO, JSON.generate(hello_payload).b)
          type, = recv_frame(io)
          return say('Hello 응답이 없습니다.') unless type == MSG_HELLO_ACK

          say ''
          say format('전송 실측 — %d MB', mb)
          say '-' * 52

          results << bench_one(io, payload, 'IO#write 통째로') do |x|
            io.write(x)
          end
          results << bench_one(io, payload, 'syswrite 통째로') do |x|
            write_all(io, x, x.bytesize)
          end
          [64 * 1024, 1024 * 1024, 8 * 1024 * 1024].each do |chunk|
            label = chunk >= 1024 * 1024 ? "syswrite #{chunk / 1024 / 1024} MB 씩" : 'syswrite 64 KB 씩'
            results << bench_one(io, payload, label) { |x| write_all(io, x, chunk) }
          end

          send_frame(io, MSG_BYE, ''.b)
        rescue StandardError => e
          say "실패: #{e.class} — #{e.message}"
        ensure
          io.close rescue nil
        end

        say '-' * 52
        best = results.compact.max_by { |r| r[:mbps] }
        say format('가장 빠른 방식: %s  (%.0f MB/s)', best[:label], best[:mbps]) if best
        write_bench_log
        results
      end

      # 측정 결과는 **파일로도** 남깁니다.
      #
      # 콘솔에만 찍으면 나중에 대조할 수 없고, 화면 밖의 사람에게 전달되지도
      # 않습니다. 재는 도구를 만들면서 결과를 남기지 않는 것은 재지 않은 것과
      # 크게 다르지 않습니다.
      def write_bench_log
        dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        require 'fileutils'
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'transport_bench.txt')
        File.open(path, 'w:UTF-8') { |f| f.write((@bench_log || []).join("\n")) }
        puts "[IRIS 링크] 저장: #{path}"
      rescue StandardError => e
        puts "[IRIS 링크] 저장 실패: #{e.message}"
      end

      def bench_one(io, payload, label)
        t0 = Time.now
        io.write([BENCH_TYPE, 0].pack('VV'))
        io.write([payload.bytesize].pack('Q<'))
        yield payload
        io.flush
        ms   = (Time.now - t0) * 1000.0
        mbps = payload.bytesize / 1048576.0 / [ms / 1000.0, 1e-9].max
        say format('  %-22s %8.1f ms   %7.0f MB/s', label, ms, mbps)
        { label: label, ms: ms, mbps: mbps }
      rescue StandardError => e
        say format('  %-22s 실패: %s', label, e.message)
        nil
      end

      # syswrite 로 직접 씁니다. Ruby 의 버퍼 계층을 거치지 않습니다.
      # syswrite 는 **일부만 쓰고 돌아올 수 있으므로** 반드시 반복해야 합니다.
      def write_all(io, data, chunk)
        off = 0
        len = data.bytesize
        while off < len
          n = io.syswrite(data.byteslice(off, [chunk, len - off].min))
          break if n.nil? || n <= 0
          off += n
        end
        off
      end

      # ---------------------------------------------------------------- 자동 모드

      # 편집을 감시하다가 바뀌면 보냅니다. 이것이 "라이브 링크"의 모습입니다.
      #
      # 정의 캐시의 옵저버가 무효화한 항목이 있으면 동기화합니다. 델타 전송은
      # 아직 아니고(5단계) 전체를 다시 보내지만, 추출은 바뀐 정의만 합니다.
      def auto(interval: 1.0, pipe: 'iris')
        return say('iris_probe.rb 를 먼저 로드하십시오.') unless defined?(IRIS::Probe)
        auto_stop

        # 캐시와 옵저버를 세워 둡니다. 첫 동기화가 여기서 일어납니다.
        say format('자동 동기화 시작 (%.1f초 간격). 중지: IRIS::Link.auto_stop', interval)
        sync(pipe: pipe)

        @auto_pipe  = pipe
        @auto_busy  = false
        @auto_timer = UI.start_timer(interval, true) do
          begin
            tick
          rescue StandardError => e
            say "자동 동기화 오류: #{e.class} — #{e.message}"
          end
        end
        nil
      end

      def auto_stop
        if @auto_timer
          UI.stop_timer(@auto_timer)
          @auto_timer = nil
          say '자동 동기화 중지.'
        end
        nil
      end

      def auto?
        !@auto_timer.nil?
      end

      # ---------------------------------------------------------------- 상태

      def status
        say ''
        say "자동 동기화: #{auto? ? '켜짐' : '꺼짐'}"
        say "보낸 횟수: 씬 #{@sent_count.to_i} · 카메라 #{@cam_sent.to_i}"
        say "마지막 오류: #{@last_error || '없음'}"
        if defined?(IRIS::Probe)
          cache = IRIS::Probe.instance_variable_get(:@def_cache)
          if cache
            st = cache.status
            say "정의 캐시: 항목 #{st[:entries]} / 무효 #{st[:dirty]}"
          else
            say '정의 캐시: 없음 (IRIS::Probe.run 을 한 번 돌리십시오)'
          end
        end
        say "파이프: #{pipe_path(@auto_pipe || 'iris')}"
        nil
      end

      # ---------------------------------------------------------------- 내부

      def tick
        return if @auto_busy

        # 1) 카메라부터. 시점을 돌리는 것이 편집보다 훨씬 잦고, 씬을 다시
        #    보낼 필요가 없으므로 수백 바이트로 끝납니다.
        send_camera_if_moved

        cache = IRIS::Probe.instance_variable_get(:@def_cache)
        return unless cache

        dirty = cache.dirty_entries
        # 재질 속성만 바뀌면 정의는 하나도 무효화되지 않습니다(지오메트리가
        # 그대로이므로). 그것도 보내야 할 변경입니다 — 안 그러면 재질 조정이
        # 자동 모드에서 화면에 반영되지 않습니다.
        mats = cache.respond_to?(:materials_stale?) && cache.materials_stale?
        return if dirty.empty? && !mats

        @auto_busy = true
        begin
          # 이 줄도 매번 찍으면 시끄럽습니다. 실제로 보낸 경우만 sync 가 알립니다.
          if @skipped.to_i.zero?
            say(dirty.empty? ? '재질 변경 감지' : "변경 감지: 정의 #{dirty.size}개")
          end
          sync(pipe: @auto_pipe)
        ensure
          @auto_busy = false
        end
      end

      # Windows 명명 파이프 경로:  \\.\pipe\<이름>
      #
      # 역슬래시를 소스에 직접 쓰지 않고 문자 코드(92)로 만듭니다.
      # 편집 도구를 거치며 개수가 어긋나 실제로 한 번 깨진 적이 있습니다.
      # 뷰포트 카메라가 움직였으면 보냅니다.
      #
      # **씬은 건드리지 않습니다.** 시점을 돌릴 때마다 36 MB 를 다시 보내면
      # 렌더러가 BLAS 를 다시 짓고 누적을 초기화해 화면이 수렴하지 못합니다.
      # 05번 3절이 말한 "작고 잦은 제어" 가 이것입니다.
      def send_camera_if_moved(pipe: nil)
        model = Sketchup.active_model
        return unless model
        view = model.active_view
        cam  = view.camera

        sig = [cam.eye.to_a, cam.target.to_a, cam.up.to_a,
               cam.fov, cam.fov_is_height?, view.vpwidth, view.vpheight].flatten
        return if @last_cam_sig == sig
        @last_cam_sig = sig

        aspect = view.vpheight.to_f > 0 ? (view.vpwidth.to_f / view.vpheight.to_f) : 0.0
        payload = {
          'eye'           => point_m(cam.eye),
          'target'        => point_m(cam.target),
          'up'            => [cam.up.x.to_f, cam.up.y.to_f, cam.up.z.to_f],
          'fov_deg'       => cam.fov.to_f,
          'fov_is_height' => (cam.fov_is_height? rescue true),
          'aspect'        => aspect,
        }

        io = open_pipe(pipe_path(pipe || @auto_pipe || 'iris'))
        return unless io
        begin
          send_frame(io, MSG_HELLO, JSON.generate(hello_payload).b)
          type, _f, _body = recv_frame(io)
          return unless type == MSG_HELLO_ACK
          send_frame(io, MSG_CAMERA, JSON.generate(payload).b)
          send_frame(io, MSG_BYE, ''.b)
          @cam_sent = @cam_sent.to_i + 1
        rescue StandardError => e
          @last_error = e.message
        ensure
          io.close rescue nil
        end
        true
      end

      def point_m(p)
        m = 0.0254
        [(p.x * m).to_f, (p.y * m).to_f, (p.z * m).to_f]
      end

      def hello_payload
        {
          'protocol'     => PROTOCOL_VERSION,
          'app'          => "SketchUp #{Sketchup.version}",
          'model'        => Sketchup.active_model.title.to_s,
          'unit'         => 'meter',
          'up_axis'      => 'z',
          'generated'    => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
          'texture_base' => IRIS::Probe.default_out_dir,
        }
      end

      def pipe_path(name)
        b = 92.chr
        "#{b}#{b}.#{b}pipe#{b}#{name}"
      end

      # 단계별 시간을 남깁니다.
      #
      # 전송이 1066 ms 인데 실제 쓰기는 12 ms 였습니다(bench_transport).
      # 나머지 1000 ms 가 어디에 있는지는 **재서** 압니다. 두 번 틀렸습니다 —
      # 처음엔 추출이라 했고 그다음엔 Ruby 쓰기라 했습니다. 둘 다 아니었습니다.
      # 연결하고, 무엇을 보낼지 정하고, 보냅니다.
      #
      # 순서가 중요합니다. **무엇을 보낼지는 렌더러가 무엇을 갖고 있느냐에
      # 달렸고**, 그건 Hello 를 주고받아야 압니다. 그래서 직렬화가 연결 뒤에
      # 옵니다.
      #
      # 반환: [성공?, 보낸바이트, 크기, 직렬화ms]
      def transmit(pipe, scene, full: false)
        @phase = {}
        t = Time.now
        io = open_pipe(pipe_path(pipe))
        @phase[:open] = (Time.now - t) * 1000.0
        return [false, nil, nil, 0.0] unless io

        bytes = nil
        sizes = nil
        pack_ms = 0.0
        begin
          # --- Hello ---
          # 생성 시각과 텍스처 기준 경로는 **연결 단위 정보**입니다.
          # 씬 페이로드에 넣으면 편집이 없어도 바이트가 매번 달라져 변경
          # 감지가 무너집니다.
          t = Time.now
          send_frame(io, MSG_HELLO, JSON.generate(hello_payload).b)

          type, _flags, payload = recv_frame(io)
          @phase[:hello] = (Time.now - t) * 1000.0
          unless type
            fail_with('Hello 응답이 없습니다')
            return [false, nil, nil, 0.0]
          end
          ack = begin
            JSON.parse(payload)
          rescue StandardError
            {}
          end
          unless type == MSG_HELLO_ACK && ack['accepted']
            fail_with("렌더러가 연결을 거절했습니다: #{ack['reason'] || MSG_NAMES[type] || type}")
            return [false, nil, nil, 0.0]
          end

          # **세션이 다르면 렌더러는 아무것도 갖고 있지 않습니다.**
          #
          # 렌더러를 다시 띄워도 파이프는 같은 이름으로 열립니다. 호스트가
          # 그것을 모르면 바뀐 것만 보내고, 렌더러는 나머지를 영영 못 받아
          # **조용히 빈 화면**이 됩니다. 세션 번호가 그것을 막습니다.
          session = ack['session']
          @diag = { session: session, prev: @session,
                    sent_gen: (@sent_gen || {}).size, full: full }

          # 렌더러가 "지난번에 재사용할 메시가 없었다"고 하면 우리 기억이
          # 틀린 것입니다. 그대로 두면 그 물체가 화면에서 사라진 채 남습니다.
          if ack['need_full']
            say '렌더러가 전체 재전송을 요청했습니다.'
            full = true
          end

          if full || session.nil? || session != @session
            if @session && session != @session
              say '렌더러가 새로 떴습니다 — 전체를 보냅니다.'
            end
            @session  = session
            @sent_gen = {}
          end

          t = Time.now
          plan  = IRIS::Probe.plan_binary(scene, skip_geom: @sent_gen)
          bytes = plan[:head] + plan[:json] + plan[:plan].join
          sizes = plan[:sizes]
          pack_ms = (Time.now - t) * 1000.0
          IRIS::Probe.pack_phase[:join_ms] =
            pack_ms - IRIS::Probe.pack_phase[:blob_ms].to_f - IRIS::Probe.pack_phase[:json_ms].to_f
          @phase[:defs_full] = plan[:sent_gen].size

          # --- 씬 ---
          @seq = @seq.to_i + 1
          t = Time.now
          send_frame(io, MSG_SYNC_BEGIN, JSON.generate('seq' => @seq).b)
          send_frame(io, MSG_SCENE_BLOB, bytes)
          send_frame(io, MSG_SYNC_END,   JSON.generate('seq' => @seq).b)
          @phase[:write] = (Time.now - t) * 1000.0

          t = Time.now
          type, _flags, payload = recv_frame(io)
          @phase[:ack] = (Time.now - t) * 1000.0
          unless type == MSG_SYNC_ACK
            fail_with("SyncAck 를 받지 못했습니다 (#{MSG_NAMES[type] || type})")
            return [false, bytes, sizes, pack_ms]
          end

          # 렌더러가 받은 지오메트리를 기억합니다. 다음 번엔 건너뜁니다.
          @sent_gen = plan[:sent_gen]

          t = Time.now
          send_frame(io, MSG_BYE, ''.b)
          @phase[:bye] = (Time.now - t) * 1000.0
          @sent_count = @sent_count.to_i + 1
          @last_error = nil
          [true, bytes, sizes, pack_ms]
        rescue StandardError => e
          fail_with("#{e.class} — #{e.message}")
          [false, bytes, sizes, pack_ms]
        ensure
          io.close rescue nil
        end
      end

      def send_frame(io, type, payload)
        io.write([type, 0].pack('VV'))
        io.write([payload.bytesize].pack('Q<'))
        io.write(payload) unless payload.empty?
        io.flush
      end

      def recv_frame(io)
        head = io.read(16)
        return [nil, nil, nil] unless head && head.bytesize == 16
        type, flags = head[0, 8].unpack('VV')
        len = head[8, 8].unpack1('Q<')
        body = len.zero? ? ''.b : io.read(len)
        [type, flags, body.to_s]
      end

      def open_pipe(path)
        5.times do
          begin
            io = File.open(path, 'rb+')
            io.binmode
            io.sync = true
            return io
          rescue StandardError => e
            @last_error = e
            sleep 0.2
          end
        end

        case @last_error
        when Errno::ENOENT
          say '렌더러를 찾지 못했습니다 — Rtxpt.exe 가 실행 중인지 확인하십시오.'
        when Errno::EACCES
          say '파이프는 있는데 접근이 거부됐습니다. 렌더러를 다시 띄워 보십시오.'
        else
          say "파이프를 열지 못했습니다: #{@last_error.class} — #{@last_error&.message}"
        end
        say "  경로: #{path}"
        nil
      end

      def fail_with(msg)
        @last_error = msg
        say "전송 실패: #{msg}"
        false
      end

      # 두 문자열이 처음 달라지는 바이트 위치. 같으면 nil.
      def first_diff(a, b)
        n = [a.bytesize, b.bytesize].min
        step = 4096
        i = 0
        while i < n
          len = [step, n - i].min
          if a.byteslice(i, len) != b.byteslice(i, len)
            len.times { |k| return i + k if a.getbyte(i + k) != b.getbyte(i + k) }
          end
          i += len
        end
        a.bytesize == b.bytesize ? nil : n
      end

      def comma(n)
        n.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
      end

      def say(line)
        puts "[IRIS 링크] #{line}"
        @bench_log << line.to_s if @bench_log
        log_line(line)
        nil
      end

      # **콘솔은 밖에서 읽을 수 없습니다.**
      #
      # "파이프를 열지 못했습니다"는 콘솔에만 찍혔고 파일에는 아무것도 남지
      # 않았습니다. 그래서 "왜 아무 일도 없었는가"를 물을 방법이 없었고,
      # 실제로 그것 때문에 두 번 헛돌았습니다. 전부 남깁니다.
      def log_line(line)
        path = File.join(out_dir, 'sync_log.txt')
        # 무한정 쌓이지 않게 가끔 비웁니다.
        File.delete(path) if File.exist?(path) && File.size(path) > 262_144
        File.open(path, 'a:UTF-8') { |f| f.puts "#{Time.now.strftime('%H:%M:%S')}  #{line}" }
      rescue StandardError
        nil
      end

      def out_dir
        d = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        require 'fileutils'
        FileUtils.mkdir_p(d)
        d
      end
    end
  end
end

puts '[IRIS] 라이브 링크 로드 완료.'
puts '       IRIS::Link.sync       한 번 보내기'
puts '       IRIS::Link.auto       편집 감시 + 자동 전송'
puts '       IRIS::Link.auto_stop  중지'
puts '       (렌더러 Rtxpt.exe 가 먼저 떠 있어야 합니다)'
