<#
.SYNOPSIS
  engine/patches/ 의 수정분을 엔진 포크에 얹는다.

.DESCRIPTION
  iris/main 을 UPSTREAM.lock 의 고정 커밋으로 되돌린 뒤 패치를 순서대로 적용한다.
  **iris/main 의 기존 커밋은 사라집니다.** 고치던 것이 있으면 먼저
  export_engine_patches.ps1 로 뽑아 두십시오.

.PARAMETER Force
  확인 없이 진행한다.
#>
[CmdletBinding()]
param([switch]$Force)

. "$PSScriptRoot\_engine_common.ps1"
Assert-EnginePresent

$lock = Read-UpstreamLock
$dir  = Get-EngineDir

$patches = @()
if (Test-Path $PatchDir) {
    $patches = Get-ChildItem $PatchDir -Filter '*.patch' | Sort-Object Name
}
if ($patches.Count -eq 0) {
    Write-Host '적용할 패치가 없습니다.' -ForegroundColor Yellow
    return
}

# 되돌리면 없어질 커밋이 있는지 먼저 알린다.
$existing = '0'
Invoke-EngineGit @('rev-parse', '--verify', 'iris/main') -AllowFail | Out-Null
if ($LASTEXITCODE -eq 0) {
    $existing = (Invoke-EngineGit @('rev-list', '--count', "$($lock.Commit)..iris/main") -AllowFail).Trim()
}

Write-Host ''
Write-Host "패치 $($patches.Count) 개를 적용합니다." -ForegroundColor Cyan
if ($existing -ne '0' -and -not $Force) {
    Write-Host "  ! iris/main 에 커밋 $existing 개가 있습니다. 되돌리면 사라집니다." -ForegroundColor Red
    Write-Host '    보존하려면 먼저 export_engine_patches.ps1 을 실행하십시오.'
    $ans = Read-Host '    계속할까요? (y/N)'
    if ($ans -ne 'y') { Write-Host '중단했습니다.'; return }
}

$dirty = Invoke-EngineGit @('status', '--porcelain', '--untracked-files=no')
if (-not [string]::IsNullOrWhiteSpace(($dirty | Out-String))) {
    throw "엔진 작업 트리에 커밋되지 않은 변경이 있습니다. 정리한 뒤 다시 시도하십시오.`n$dirty"
}

Invoke-EngineGit @('checkout', '-B', 'iris/main', $lock.Commit) | Out-Null

foreach ($p in $patches) {
    Write-Host "  $($p.Name)"
    Invoke-EngineGit @('am', '--3way', $p.FullName) -AllowFail | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-EngineGit @('am', '--abort') -AllowFail | Out-Null
        throw "패치 적용 실패: $($p.Name)`n  상위가 바뀌었을 수 있습니다. 수동 병합이 필요합니다."
    }
}

Write-Host '완료.' -ForegroundColor Green
