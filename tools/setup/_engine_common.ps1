# IRIS — 엔진 스크립트 공통부. 단독 실행용이 아닙니다.
# dot-source 해서 씁니다:  . "$PSScriptRoot\_engine_common.ps1"

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$script:LockFile = Join-Path $RepoRoot 'engine\UPSTREAM.lock'
$script:PatchDir = Join-Path $RepoRoot 'engine\patches'

function Get-EngineDir {
    if ($env:IRIS_ENGINE_DIR) { return $env:IRIS_ENGINE_DIR }
    return 'E:\iris-ext\RTXPT'
}

# UPSTREAM.lock 을 읽어 해시테이블로 돌려준다.
#   .Repo .Commit .Submodules(경로=>SHA)
function Read-UpstreamLock {
    if (-not (Test-Path $LockFile)) { throw "고정 파일이 없습니다: $LockFile" }
    $out = @{ Repo = $null; Commit = $null; Submodules = @{} }
    foreach ($line in Get-Content $LockFile) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $p = $t -split '\s+', 3
        switch ($p[0]) {
            'repo'      { $out.Repo   = $p[1] }
            'commit'    { $out.Commit = $p[1] }
            'submodule' { $out.Submodules[$p[1]] = $p[2] }
        }
    }
    if (-not $out.Commit) { throw "$LockFile 에 commit 항목이 없습니다." }
    return $out
}

# 엔진 디렉터리에서 git 을 실행한다. 실패하면 던진다.
function Invoke-EngineGit {
    param([Parameter(Mandatory)][string[]]$Args, [switch]$AllowFail)
    $dir = Get-EngineDir
    $res = & git -C $dir @Args 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        throw "git $($Args -join ' ') 실패 (exit $LASTEXITCODE)`n$res"
    }
    return $res
}

function Assert-EnginePresent {
    $dir = Get-EngineDir
    if (-not (Test-Path (Join-Path $dir '.git'))) {
        throw "엔진 포크가 없습니다: $dir`n  먼저 tools\setup\bootstrap_engine.ps1 을 실행하십시오." +
              "`n  (경로가 다르면 IRIS_ENGINE_DIR 환경변수를 설정하십시오)"
    }
}
