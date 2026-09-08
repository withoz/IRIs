# encoding: UTF-8
#
# IRIS — 도구 다시 읽기
#
# 왜 필요한가
#   SketchUp 콘솔에서 `load` 가 실패하면 그 예외는 콘솔에만 찍힙니다.
#   화면 밖의 사람에게는 **아무 일도 일어나지 않은 것처럼** 보입니다 —
#   실제로 그렇게 한 번 헛돌았습니다. 파일이 하나도 갱신되지 않는데
#   원인을 알 방법이 없었습니다.
#
#   로드를 감싸서 실패를 파일에 남깁니다.
#
# 사용법 — SketchUp Ruby 콘솔:
#   load 'E:/IRIS/tools/sketchup/iris_reload.rb'
#
# 성공하면 IRIS::Probe 와 IRIS::Link 가 최신 코드로 올라옵니다.

module IRIS
  module Reload
    FILES = %w[iris_enscape.rb iris_probe.rb iris_link.rb].freeze

    def self.run
      dir = File.dirname(__FILE__)
      out = File.expand_path(File.join(dir, '..', '..', 'out', 'sketchup'))
      require 'fileutils'
      FileUtils.mkdir_p(out)
      err_path = File.join(out, 'load_error.txt')
      File.delete(err_path) if File.exist?(err_path)

      loaded = []
      FILES.each do |name|
        path = File.join(dir, name)
        next unless File.exist?(path)
        load path
        loaded << name
      end

      puts "[IRIS] 로드 OK — #{loaded.join(', ')}"
      puts '       IRIS::Link.sync(force: true) 로 보내십시오.'
      true
    rescue Exception => e   # SyntaxError 는 StandardError 가 아닙니다
      begin
        File.open(err_path, 'w:UTF-8') do |f|
          f.puts Time.now.strftime('%Y-%m-%d %H:%M:%S')
          f.puts "마지막으로 성공한 파일: #{loaded.join(', ')}"
          f.puts "#{e.class}: #{e.message}"
          (e.backtrace || []).first(15).each { |l| f.puts "  #{l}" }
        end
        puts "[IRIS] 로드 실패 — #{err_path} 에 남겼습니다"
      rescue StandardError
        nil
      end
      puts "[IRIS] #{e.class}: #{e.message}"
      false
    end
  end
end

IRIS::Reload.run
