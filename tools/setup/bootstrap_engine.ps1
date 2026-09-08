<#
.SYNOPSIS
  IRIS 엔진 포크(RTXPT)를 새 머신에 재현한다.

.DESCRIPTION
  engine/UPSTREAM.lock 이 가리키는 커밋으로 NVIDIA RTXPT 를 받고,
  브랜치 iris/main 을 만든 뒤 engine/patches/ 의 수정분을 얹는다.

  받는 양이 큽니다. Assets 까지 받으면 약 12 GB, 빼면 약 7 GB.
  Assets 는 NVIDIA 테스트 씬입니다 — IRIS 자체 씬으로 작업할 때는 없어도 됩니다.
  다만 RTXPT 샘플을 원본 그대로 띄워 비교하려면 필요합니다.

.PARAMETER NoAssets
  Assets 서브모듈(4.9 GB)을 건너뛴다.

.PARAMETER SkipPatches
  패치 적용 없이 상위 원본 상태로만 둔다.

.EXAMPLE
  tools\setup\bootstrap_engine.ps1
  tools\setup\bootstrap_engine.ps1 -NoAssets
#>
[CmdletBinding()]
param([switch]$NoAssets, [switch]$SkipPatches)

. "$PSScriptRoot\_engine_common.ps1"

$lock = Read-UpstreamLock
$dir  = Get-EngineDir

Write-Host ''
Write-Host 'IRIS 엔진 포크 부트스트랩' -ForegroundColor Cyan
Write-Host "  상위 : $($lock.Repo)"
Write-Host "  커밋 : $($lock.Commit)"
Write-Host "  경로 : $dir"
Write-Host "  Assets: $(if ($NoAssets) { '건너뜀' } else { '포함 (4.9 GB)' })"
Write-Host ''

if (Test-Path (Join-Path $dir '.git')) {
    Write-Host '이미 존재합니다. 클론을 건너뜁니다.' -ForegroundColor Yellow
} else {
    $parent = Split-Path $dir -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force $parent | Out-Null }

    Write-Host '클론 중… (오래 걸립니다)'
    & git clone --origin upstream $lock.Repo $dir
    if ($LASTEXITCODE -ne 0) { throw "클론 실패 (exit $LASTEXITCODE)" }
}

Write-Host "고정 커밋으로 이동: $($lock.Commit)"
Invoke-EngineGit @('fetch', 'upstream') | Out-Null
Invoke-EngineGit @('checkout', '--detach', $lock.Commit) | Out-Null

Write-Host '서브모듈 초기화…'
foreach ($path in $lock.Submodules.Keys) {
    if ($NoAssets -and $path -eq 'Assets') {
        Write-Host "  건너뜀: $path"
        continue
    }
    Write-Host "  $path"
    Invoke-EngineGit @('submodule', 'update', '--init', '--recursive', $path) | Out-Null
}

# iris/main 이 없으면 고정 커밋에서 만든다. 있으면 건드리지 않는다 (작업분 보호).
$branches = Invoke-EngineGit @('branch', '--list', 'iris/main') -AllowFail
if ([string]::IsNullOrWhiteSpace(($branches | Out-String))) {
    Write-Host '브랜치 iris/main 생성'
    Invoke-EngineGit @('checkout', '-b', 'iris/main') | Out-Null
} else {
    Write-Host 'iris/main 이 이미 있습니다 — 그대로 둡니다.' -ForegroundColor Yellow
    Invoke-EngineGit @('checkout', 'iris/main') | Out-Null
}

if (-not $SkipPatches) {
    & "$PSScriptRoot\apply_engine_patches.ps1"
}

Write-Host ''
Write-Host '완료.' -ForegroundColor Green
Write-Host "  다음: $dir 에서 CMake 구성 → 빌드"
