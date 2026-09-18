# Download a prebuilt OHOS c-shared .so from the kernel repo release,
# rename it to libclash.so and stage it to entry/libs/arm64-v8a/.
# Complement of build-clashlib.ps1 (local OHOS fork cross-compile): use this
# when no fork/NDK is installed.
# Usage:
#   .\download-clashlib.ps1 v1.2.3                  # explicit version
#   $env:CORE_TAG='v1.2.3'; .\download-clashlib.ps1 # or env var (empty = latest release)
# Note: the CI ohos job is a soft-fail scaffold; it yields
#       arkhon-ohos-arm64-<tag>.so once hardened via OHOS_NDK_URL.
param(
  [string]$Tag = ''
)
$ErrorActionPreference = 'Stop'

$OWNER = 'luoqingciya'
$REPO  = 'arkhon-core'
$stageDir = Join-Path $PSScriptRoot '..\..\entry\libs\arm64-v8a'
$dest     = Join-Path $stageDir 'libclash.so'

function Get-GhHeaders {
  $t = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $null }
  $h = @{ 'User-Agent' = 'arkhon-download' }
  if ($t) { $h['Authorization'] = "Bearer $t" }
  return $h
}

$tag = $Tag
if (-not $tag) { $tag = $env:CORE_TAG }
if (-not $tag) {
  try {
    $latest = Invoke-RestMethod -Uri "https://api.github.com/repos/$OWNER/$REPO/releases/latest" -Headers (Get-GhHeaders)
    $tag = $latest.tag_name
  } catch {
    throw "查询最新版本失败: $($_.Exception.Message)"
  }
}

$url = "https://github.com/$OWNER/$REPO/releases/download/$tag/arkhon-ohos-arm64-$tag.so"
Write-Host "[download-clashlib] 目标: $tag"
Write-Host "[download-clashlib] 下载: $url"

New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
try {
  Invoke-WebRequest -Uri $url -Headers (Get-GhHeaders) -OutFile $dest -ErrorAction Stop
} catch {
  throw "下载失败: $($_.Exception.Message)"
}

Write-Host "STAGED: $dest"