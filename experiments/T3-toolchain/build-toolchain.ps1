# 编译 openharmony-sig/ohos_golang_go（GOOS=openharmony 官方 Go fork）的 Windows 宿主工具链。
# 自举：GOROOT_BOOTSTRAP 用现有 go1.27.1；fork 版本为 go1.24.5。
$ErrorActionPreference = 'Stop'

$fork = 'd:\Project\Teyvat-Arkhon\Arkhon\experiments\T3-toolchain\ohos_golang_go'
$boot = 'D:\DevEnv\GO'
$src  = "$fork\src"

if (-not (Test-Path "$src\make.bat")) { throw "fork src missing: $src" }

$env:GOROOT_BOOTSTRAP = $boot
$env:GOROOT = ''          # 避免外部 GOROOT 干扰
$env:Path = "$env:GOROOT_BOOTSTRAP\bin;$env:Path"

Push-Location $src
try {
  # make.bat 会自行鉴权 GOROOT_BOOTSTRAP 并产出 fork 自身的 bin/go.exe
  cmd /c make.bat 2>&1
} finally {
  Pop-Location
}

$goexe = "$fork\bin\go.exe"
if (Test-Path $goexe) {
  Write-Host "TOOLCHAIN_BUILT: $goexe"
  & $goexe version
  & $goexe env GOOS GOARCH
} else {
  throw "toolchain build produced no bin\go.exe"
}