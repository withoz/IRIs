<#
.SYNOPSIS
  엔진 포크의 수정분을 engine/patches/ 로 뽑아 저장소에 보존한다.

.DESCRIPTION
  UPSTREAM.lock 의 고정 커밋부터 iris/main 까지의 커밋을 패치 파일로 만든다.
  **엔진을 고친 뒤에는 반드시 이것을 돌리고 IRIS 저장소에 커밋하십시오.**
  그러지 않으면 작업이 이 머신에만 남습니다.

  기존 패치는 지우고 새로 씁니다 (히스토리를 다시 쓰는 경우가 있으므로).
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\_engine_common.ps1"
Assert-EnginePresent

$lock = Read-UpstreamLock
$dir  = Get-EngineDir

# 고정 커밋이 실제로 조상인지 본다. 아니면 lock 이 낡았거나 브랜치가 어긋난 것이다.
Invoke-EngineGit @('merge-base', '--is-ancestor', $lock.Commit, 'iris/main') -AllowFail | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "고정 커밋 $($lock.Commit) 이 iris/main 의 조상이 아닙니다.`n" +
          "  상위를 올렸다면 engine/UPSTREAM.lock 을 먼저 갱신하십시오."
}

$count = (Invoke-EngineGit @('rev-list', '--count', "$($lock.Commit)..iris/main")).Trim()
Write-Host ''
Write-Host "엔진 수정 커밋 $count 개" -ForegroundColor Cyan

if (Test-Path $PatchDir) {
    Get-ChildItem $PatchDir -Filter '*.patch' | Remove-Item -Force
} else {
    New-Item -ItemType Directory -Force $PatchDir | Out-Null
}

if ($count -eq '0') {
    Write-Host '뽑을 것이 없습니다.' -ForegroundColor Yellow
    return
}

# core.autocrlf=false 로 뽑는다. 머신마다 설정이 다르면 같은 커밋에서
# 줄바꿈이 다른 패치가 나와 저장소에 헛diff가 생기고, 적용 결과도 갈린다.
Invoke-EngineGit @('-c', 'core.autocrlf=false', 'format-patch', '--no-signature',
                   '--zero-commit', "$($lock.Commit)..iris/main", '-o', $PatchDir) | Out-Null

$files = Get-ChildItem $PatchDir -Filter '*.patch' | Sort-Object Name
foreach ($f in $files) {
    Write-Host ("  {0}  ({1:N0} bytes)" -f $f.Name, $f.Length)
}
Write-Host ''
Write-Host "저장 위치: $PatchDir" -ForegroundColor Green
Write-Host '이제 IRIS 저장소에 커밋하십시오.'
