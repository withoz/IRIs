<#
.SYNOPSIS
  명명 파이프 전송 실측용 수신 서버.

.DESCRIPTION
  프로토콜 전송 계층(미결정 A)을 정하기 전에 **Ruby -> 명명 파이프 -> 네이티브**
  경로가 실제로 얼마나 나오는지 잰다. 추정으로 정하지 않기 위한 것이다.

  주고받는 것
    클라이언트 -> 서버 : MAGIC(8) + 길이(u64 LE) + 페이로드
    서버 -> 클라이언트 : "IOK!" (4) + 수신 바이트수(u64 LE)

  왕복 확인이 목적이므로 페이로드는 버립니다.

.PARAMETER Name
  파이프 이름. 기본 iris-test  (실제 경로는 \.\pipe\iris-test)

.PARAMETER Once
  한 번 받고 종료. 기본은 계속 대기.

.EXAMPLE
  tools\setup\pipe_echo_server.ps1
#>
[CmdletBinding()]
param([string]$Name = 'iris-test', [switch]$Once)

$ErrorActionPreference = 'Stop'
$MAGIC = [Text.Encoding]::ASCII.GetBytes('IRISPIPE')

Write-Host ''
Write-Host "명명 파이프 수신 대기: \.\pipe\$Name" -ForegroundColor Cyan
Write-Host '  Ctrl+C 로 종료합니다.'
Write-Host ''

while ($true) {
    $server = New-Object IO.Pipes.NamedPipeServerStream(
        $Name, [IO.Pipes.PipeDirection]::InOut, 1,
        [IO.Pipes.PipeTransmissionMode]::Byte,
        [IO.Pipes.PipeOptions]::None,
        1MB, 1MB)
    try {
        $server.WaitForConnection()
        Write-Host '연결됨.' -ForegroundColor Green

        # --- 헤더 ---
        $head = New-Object byte[] 16
        $got = 0
        while ($got -lt 16) {
            $n = $server.Read($head, $got, 16 - $got)
            if ($n -le 0) { throw '헤더 도중 연결이 끊겼습니다.' }
            $got += $n
        }
        for ($i = 0; $i -lt 8; $i++) {
            if ($head[$i] -ne $MAGIC[$i]) { throw "MAGIC 불일치 (byte $i)" }
        }
        $len = [BitConverter]::ToUInt64($head, 8)
        Write-Host ("  선언 크기: {0:N0} bytes ({1:N1} MB)" -f $len, ($len / 1MB))

        # --- 페이로드 ---
        $buf   = New-Object byte[] (1MB)
        $total = 0L
        $sw    = [Diagnostics.Stopwatch]::StartNew()
        while ($total -lt $len) {
            $want = [Math]::Min([long]$buf.Length, $len - $total)
            $n = $server.Read($buf, 0, $want)
            if ($n -le 0) { break }
            $total += $n
        }
        $sw.Stop()

        $sec = [Math]::Max($sw.Elapsed.TotalSeconds, 1e-9)
        Write-Host ("  수신: {0:N0} bytes / {1:N1} ms = {2:N0} MB/s" -f `
                    $total, $sw.Elapsed.TotalMilliseconds, ($total / 1MB / $sec)) -ForegroundColor Yellow
        if ($total -ne [long]$len) {
            Write-Host "  ! 선언 크기와 다릅니다 ($total vs $len)" -ForegroundColor Red
        }

        # --- 응답 (양방향 확인) ---
        $ack = [Text.Encoding]::ASCII.GetBytes('IOK!') + [BitConverter]::GetBytes([uint64]$total)
        $server.Write($ack, 0, $ack.Length)
        $server.Flush()
        Write-Host '  응답 전송 완료.'
    }
    catch {
        Write-Host "  실패: $_" -ForegroundColor Red
    }
    finally {
        $server.Dispose()
    }
    Write-Host ''
    if ($Once) { break }
}
