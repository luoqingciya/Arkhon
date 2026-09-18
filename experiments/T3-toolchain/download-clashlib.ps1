# 从内核仓库 GitHub Release 拉取预编译的 OHOS .so，改名 libclash.so 并 stage 到 entry/libs/arm64-v8a/
# 与 build-clashlib.ps1（本地 OHOS fork 工具链交叉编译）互补：本脚本适合不装 fork/NDK 时直接拿 CI 产物。
# 用法:
#   .\download-clashlib.ps1 v1.2.3                 # 指定版本
#   $env:CORE_TAG='v1.2.3'; .\download-clashlib.ps1 # 或环境变量
#   （均缺省时自动取 GitHub 最新 release）
# 注意：内核 CI 的 ohos job 当前为「软失败」脚手架，须先按 workflow 注释配置 OHOS_NDK_URL 硬化后才会有
#       arkhon-ohos-arm64-<tag>.so 资产可供下载；在此之前本脚本会因资产不存在而报 404（属预期）。
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