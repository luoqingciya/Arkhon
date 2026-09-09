# 交叉编译 hellogo 为 OpenHarmony（aarch64-linux-ohos / musl）c-shared .so
# 产物输出到模块 libs 目录，供 HAP 打包。
$ErrorActionPreference = 'Stop'

$ex   = $PSScriptRoot
$ndk  = "$ex\ndk"                 # 无空格联接，指向 DevEco native 目录；缺失时需先建
$sdkRoot = 'sdk\default\openharmony\native'
$devEco = 'D:\Apps\03_Dev_Environment\14_DevEco\DevEco Studio'

if (-not (Test-Path $ndk)) {
  if (Test-Path "$devEco\$sdkRoot") {
    New-Item -ItemType Junction -Path $ndk -Target "$devEco\$sdkRoot" | Out-Null
  } else {
    throw 'NDK junction missing. Set $devEco or create $ndk link.'
  }
}

$env:CC    = "$ndk\llvm\bin\clang.exe --target=aarch64-linux-ohos -D__MUSL__ --sysroot=$ndk\sysroot"
$env:CXX   = "$ndk\llvm\bin\clang++.exe --target=aarch64-linux-ohos -D__MUSL__ --sysroot=$ndk\sysroot"
$env:GOOS  = 'linux'
$env:GOARCH= 'arm64'
$env:CGO_ENABLED = '1'

$out = "$ex\libhellogo.so"
Push-Location "$ex\hellogo"
try {
  go build -buildmode=c-shared -o $out .
} finally { Pop-Location }

New-Item -ItemType Directory -Path "$ex\..\..\entry\libs\arm64-v8a" -Force | Out-Null
Copy-Item $out "$ex\..\..\entry\libs\arm64-v8a\libhellogo.so" -Force
Write-Host "built + staged: $out"