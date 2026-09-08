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

    MSG_NAMES = {
      MSG_HELLO => 'Hello', MSG_HELLO_ACK => 'HelloAck',
      MSG_SYNC_BEGIN => 'SyncBegin', MSG_SCENE_BLOB => 'SceneBlob',
      MSG_SYNC_END => 'SyncEnd', MSG_SYNC_ACK => 'SyncAck', MSG_BYE => 'Bye'
    }.freeze

    class << self

      # ---------------------------------------------------------------- 주 진입점

      # 한 번 보냅니다. 추출·직렬화·전송을 전부 합니다.
      #
      # 캐시가 살아 있으면 바뀐 정의만 다시 추출합니다 — 실측 47배 차이입니다
      # (docs/05-씬-델타-프로토콜.md 7절).
      def sync(pipe: 'iris', textures: true)
        model = Sketchup.active_model
        return say('활성 모델이 없습니다.') unless model
        return say('iris_probe.rb 를 먼저 로드하십시오.') unless defined?(IRIS::Probe)

        t_extract0 = Time.now
        IRIS::Probe.run(dump: false, textures: textures, cache: true)
        scene = IRIS::Probe.last_scene
        return say('씬 추출에 실패했습니다.') unless scene
        extract_ms = (Time.now - t_extract0) * 1000.0

        t_pack0 = Time.now
        bytes, sizes = IRIS::Probe.pack_binary(scene)
        pack_ms = (Time.now - t_pack0) * 1000.0

        t_send0 = Time.now
        ok = transmit(pipe, bytes)
        send_ms = (Time.now - t_send0) * 1000.0

        st = scene['stats'] || {}
        say ''
        say format('추출 %7.1f ms   삼각형 %s · 인스턴스 %s',
                   extract_ms, comma(st['triangles'].to_i), comma(st['instances'].to_i))
        say format('직렬화 %6.1f ms   %s bytes (JSON %s + 블롭 %s)',
                   pack_ms, comma(bytes.bytesize), comma(sizes[:json]), comma(sizes[:bin]))
        say format('전송 %8.1f ms   %.0f MB/s', send_ms,
                   bytes.bytesize / 1048576.0 / [send_ms / 1000.0, 1e-9].max)
        say format('합계 %8.1f ms', extract_ms + pack_ms + send_ms)
        say(ok ? '렌더러 화면이 바뀌어야 합니다.' : '전송 실패 — 위 메시지를 보십시오.')
        ok
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
        say "보낸 횟수: #{@sent_count.to_i}"
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

        cache = IRIS::Probe.instance_variable_get(:@def_cache)
        return unless cache

        dirty = cache.dirty_entries
        return if dirty.empty?

        @auto_busy = true
        begin
          say "변경 감지: 정의 #{dirty.size}개"
          sync(pipe: @auto_pipe)
        ensure
          @auto_busy = false
        end
      end

      # Windows 명명 파이프 경로:  \\.\pipe\<이름>
      #
      # 역슬래시를 소스에 직접 쓰지 않고 문자 코드(92)로 만듭니다.
      # 편집 도구를 거치며 개수가 어긋나 실제로 한 번 깨진 적이 있습니다.
      def pipe_path(name)
        b = 92.chr
        "#{b}#{b}.#{b}pipe#{b}#{name}"
      end

      def transmit(pipe, bytes)
        io = open_pipe(pipe_path(pipe))
        return false unless io

        begin
          # --- Hello ---
          hello = {
            'protocol'     => PROTOCOL_VERSION,
            'app'          => "SketchUp #{Sketchup.version}",
            'model'        => Sketchup.active_model.title.to_s,
            'unit'         => 'meter',
            'up_axis'      => 'z',
            # 텍스처는 파일로 두고 경로만 알려줍니다. 라이브 씬은 파일로
            # 존재하지 않아 렌더러가 "씬 파일 옆"을 기준으로 쓸 수 없습니다.
            'texture_base' => IRIS::Probe.default_out_dir,
          }
          send_frame(io, MSG_HELLO, JSON.generate(hello).b)

          type, _flags, payload = recv_frame(io)
          return fail_with("Hello 응답이 없습니다") unless type
          ack = begin
            JSON.parse(payload)
          rescue StandardError
            {}
          end
          unless type == MSG_HELLO_ACK && ack['accepted']
            return fail_with("렌더러가 연결을 거절했습니다: #{ack['reason'] || MSG_NAMES[type] || type}")
          end

          # --- 씬 ---
          @seq = @seq.to_i + 1
          send_frame(io, MSG_SYNC_BEGIN, JSON.generate('seq' => @seq).b)
          send_frame(io, MSG_SCENE_BLOB, bytes)
          send_frame(io, MSG_SYNC_END,   JSON.generate('seq' => @seq).b)

          type, _flags, payload = recv_frame(io)
          unless type == MSG_SYNC_ACK
            return fail_with("SyncAck 를 받지 못했습니다 (#{MSG_NAMES[type] || type})")
          end

          send_frame(io, MSG_BYE, ''.b)
          @sent_count = @sent_count.to_i + 1
          @last_error = nil
          true
        rescue StandardError => e
          fail_with("#{e.class} — #{e.message}")
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

      def comma(n)
        n.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
      end

      def say(line)
        puts "[IRIS 링크] #{line}"
        nil
      end
    end
  end
end

puts '[IRIS] 라이브 링크 로드 완료.'
puts '       IRIS::Link.sync       한 번 보내기'
puts '       IRIS::Link.auto       편집 감시 + 자동 전송'
puts '       IRIS::Link.auto_stop  중지'
puts '       (렌더러 Rtxpt.exe 가 먼저 떠 있어야 합니다)'
