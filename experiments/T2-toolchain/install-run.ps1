# T2 真机运行时验证脚本：安装 HAP -> 启动 -> 抓 T2/T1 日志
$ErrorActionPreference = 'Stop'
$hdc = 'D:\Apps\03_Dev_Environment\14_DevEco\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
$hap = 'd:\Project\Teyvat-Arkhon\Arkhon\entry\build\default\outputs\default\entry-default-signed.hap'
$bundle = 'cn.luoqingciya.arkhon'
$ability = 'EntryAbility'

Write-Host '== 1. list targets =='
& $hdc list targets
$count = (& $hdc list targets | Where-Object { $_ -ne '' -and $_ -ne '[Empty]' }).Count
if ($count -eq 0) {
  Write-Host '[FAIL] 未检测到设备，请插入并授权后重试。'
  exit 1
}

Write-Host '== 2. install =='
& $hdc install -r $hap

Write-Host '== 3. launch =='
& $hdc shell aa force-stop $bundle
& $hdc shell aa start -a $ability -b $bundle

Write-Host '== 4. collect hilog (5s) =='
& $hdc shell hilog -c
Start-Sleep -Seconds 5
& $hdc shell hilog | Select-String 'T1Page|T2|loadGoHello|libentry|libhellogo'