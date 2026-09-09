# 用 openharmony-sig/ohos_golang_go 交叉编译 clashlib（mihomo 内核封装）为 c-shared .so。
# 前置：T3-toolchain\build-toolchain.ps1 已产出 fork 的 bin\go.exe。
$ErrorActionPreference = 'Stop'

$ex   = $PSScriptRoot
$fork = "$ex\ohos_golang_go"
$goex = "$fork\bin\go.exe"
if (-not (Test-Path $goex)) { throw "fork toolchain not built yet: $goex" }

$ndk  = Join-Path $ex '..\T2-toolchain\ndk'       # 无空格 junction → DevEco native
if (-not (Test-Path "$ndk\llvm\bin\clang.exe")) { throw "ndk missing: $ndk" }
$sysroot = "$ndk\sysroot"

$env:GOROOT = $fork
$env:Path   = "$fork\bin;$env:Path"
Remove-Item Env:GOOS,Env:GOARCH,Env:CGO_ENABLED -ErrorAction SilentlyContinue

$env:GOOS        = 'openharmony'
$env:GOARCH      = 'arm64'
$env:CGO_ENABLED = '1'
$env:CC  = "$ndk\llvm\bin\clang.exe --target=aarch64-linux-ohos -D__MUSL__ --sysroot=$sysroot"
$env:CXX = "$ndk\llvm\bin\clang++.exe --target=aarch64-linux-ohos -D__MUSL__ --sysroot=$sysroot"
$env:AR = "$ndk\llvm\bin\llvm-ar.exe"
$env:LD = "$ndk\llvm\bin\lld.exe"
$env:CGO_CFLAGS   = "--target=aarch64-linux-ohos -D__MUSL__ --sysroot=$sysroot"
$env:CGO_LDFLAGS  = "--target=aarch64-linux-ohos -fuse-ld=lld"
$env:GOFLAGS = ''
$env:GOTOOLCHAIN = 'local'    # 禁止 fork(1.24) 自动下载 host 版工具链
$env:GOPROXY = 'https://goproxy.cn,direct'   # 直连 proxy.golang.org 被墙，走国内镜像
$env:GOSUMDB  = 'off'

$src = "$ex\clashlib"
$out = "$ex\libclash.so"
Push-Location $src
try {
  Write-Host '>>> go mod tidy ...'
  & $goex mod tidy
  if ($LASTEXITCODE -ne 0) { throw "go mod tidy failed: $LASTEXITCODE" }

  Write-Host '>>> go build c-shared ...'
  & $goex build -buildmode=c-shared -o $out .
  if ($LASTEXITCODE -ne 0) { throw "go build failed: $LASTEXITCODE" }
} finally { Pop-Location }

Write-Host "BUILT: $out"
$env:GOROOT = ''