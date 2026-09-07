# encoding: UTF-8
#
# IRIS — 명명 파이프 전송 실측 (프로토콜 전송 계층, 미결정 A)
#
# 왜 재는가
#   현재 경로는 Ruby가 .irisb 를 **파일로 쓰고** 렌더러가 그 파일을 읽습니다.
#   제품에서는 프로세스 간 직접 전송이어야 하는데, 방식이 미결정입니다.
#
#     - 명명 파이프 : Ruby 표준 File 로 열립니다. 방화벽 창이 뜨지 않습니다
#     - TCP 루프백  : 표준 라이브러리로 되지만 포트·방화벽 문제가 있습니다
#     - 공유 메모리 : 가장 빠르나 Ruby에서 Fiddle 로 Win32 API 를 불러야 합니다
#
#   공유 메모리의 무복사 이점은 **Ruby가 어차피 블롭을 메모리에 만들기 때문에**
#   상당 부분 사라집니다. 그러면 남는 것은 "파이프가 충분히 빠른가"이고,
#   그건 재봐야 압니다.
#
# 사용법
#   1) PowerShell 에서 수신 서버를 먼저 띄웁니다
#        E:\IRIS\tools\setup\pipe_echo_server.ps1
#   2) SketchUp Ruby 콘솔에서
#        load 'E:/IRIS/tools/sketchup/iris_pipe_test.rb'
#        IRIS::PipeTest.run                       # 32 MB 합성 블롭
#        IRIS::PipeTest.run(file: 'E:/IRIS/out/sketchup/....irisb')
#        IRIS::PipeTest.run(chunk: 1 << 20)       # 청크 크기 바꿔보기
#
# 결과는 out/sketchup/pipe_test.txt 에도 남깁니다.

require 'fileutils'

module IRIS
  module PipeTest
    MAGIC     = 'IRISPIPE'.freeze
    PIPE_NAME = 'iris-test'.freeze

    class << self

      def run(name: PIPE_NAME, file: nil, size: 32 * 1024 * 1024,
              chunk: 1 << 20, out_dir: nil, repeat: 3)
        @log = []
        say ''
        say "명명 파이프 전송 실측  (Ruby #{RUBY_VERSION})"
        say "  파이프: \\.\pipe\#{name}"

        payload = build_payload(file, size)
        return write_log(out_dir) unless payload
        say format('  페이로드: %s bytes (%.1f MB)%s',
                   comma(payload.bytesize), payload.bytesize / 1048576.0,
                   file ? " — #{File.basename(file)}" : ' — 합성')
        say format('  청크: %s bytes', comma(chunk))
        say ''

        results = []
        repeat.times do |i|
          r = send_once(name, payload, chunk)
          unless r
            say '  중단합니다.'
            break
          end
          results << r
          say format('  [%d] %8.1f ms   %7.1f MB/s   응답 %s',
                     i + 1, r[:ms], r[:mbps], r[:ack] ? 'OK' : '없음')
        end

        if results.size >= 2
          best = results.max_by { |r| r[:mbps] }
          med  = results.map { |r| r[:mbps] }.sort[results.size / 2]
          say ''
          say format('  최고 %.1f MB/s · 중간값 %.1f MB/s', best[:mbps], med)
          say ''
          say '읽는 법'
          say '  .irisb 는 실측 36 MB 이고 전체 동기화 예산이 434 ms 입니다.'
          say format('  중간값 기준 36 MB 전송에 %.0f ms — 예산의 %.0f%% 입니다.',
                     36.0 / med * 1000, 36.0 / med * 1000 / 434.0 * 100)
          say '  이 값이 크면 공유 메모리를 다시 검토해야 합니다.'
        end

        write_log(out_dir)
      end

      # ------------------------------------------------------------ 내부

      def build_payload(file, size)
        if file
          unless File.exist?(file)
            say "  파일이 없습니다: #{file}"
            return nil
          end
          File.binread(file)
        else
          # 압축률에 좌우되지 않도록 사실상 랜덤한 바이트로 채운다.
          block = (0...65_536).map { |i| (i * 2_654_435_761) & 0xFF }.pack('C*')
          (block * ((size / block.bytesize) + 1))[0, size]
        end
      end

      def send_once(name, payload, chunk)
        path = "\\.\pipe\#{name}"
        io = open_pipe(path)
        return nil unless io

        begin
          header = MAGIC.dup.force_encoding(Encoding::BINARY)
          header << [payload.bytesize].pack('Q<')

          t0 = Time.now
          io.write(header)
          off = 0
          len = payload.bytesize
          while off < len
            io.write(payload.byteslice(off, chunk))
            off += chunk
          end
          io.flush
          ms = (Time.now - t0) * 1000.0

          ack = begin
            io.read(12)
          rescue StandardError
            nil
          end

          { ms: ms,
            mbps: payload.bytesize / 1048576.0 / [ms / 1000.0, 1e-9].max,
            ack: ack && ack.bytesize == 12 && ack[0, 4] == 'IOK!' }
        ensure
          io.close rescue nil
        end
      end

      def open_pipe(path)
        # 서버가 다음 연결을 준비하는 사이일 수 있으므로 몇 번 다시 시도한다.
        5.times do |i|
          begin
            io = File.open(path, 'rb+')
            io.binmode
            io.sync = true
            return io
          rescue StandardError => e
            @last_err = e
            sleep 0.2
          end
        end
        say "  파이프를 열지 못했습니다: #{@last_err&.message}"
        say '  수신 서버가 떠 있는지 확인하십시오:'
        say '    E:\IRIS\tools\setup\pipe_echo_server.ps1'
        nil
      end

      def comma(n)
        n.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
      end

      def say(line)
        @log ||= []
        @log << line
        puts line
      end

      def write_log(out_dir)
        dir = out_dir ||
              File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'out', 'sketchup'))
        FileUtils.mkdir_p(dir)
        path = File.join(dir, 'pipe_test.txt')
        File.open(path, 'w:UTF-8') { |f| f.write(@log.join("\n")) }
        puts ''
        puts "결과 저장: #{path}"
        { saved: path }
      rescue StandardError => e
        puts "결과 저장 실패: #{e.message}"
        nil
      end
    end
  end
end

puts '[IRIS] 파이프 전송 실측 로드 완료.'
puts '       1) PowerShell:  E:\IRIS\tools\setup\pipe_echo_server.ps1'
puts '       2) 여기서:      IRIS::PipeTest.run'
