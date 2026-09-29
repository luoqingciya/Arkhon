# Arkhon（鸿蒙版）

> **HarmonyOS NEXT 原生分流代理客户端**：以 VPN 隧道统一接管移动端流量；内核与桌面端同源（[arkhon-core](https://github.com/luoqingciya/arkhon-core)，mihomo fork），经 NAPI 在应用进程内实载运行。
>
> 当前进度：**M2 骨架出口达成**（2026-09-28，真实节点链路真机全通）→ 进入 **M3 V1.0 内测**（见[《后续开发计划》](docs/Arkhon%20后续开发计划.md)）。

## 项目定位

- **一句话**：HarmonyOS NEXT 上的开源分流代理客户端，通过 VPN 隧道统一接管移动网络流量。
- **单一接管路径**：`VpnExtensionAbility` 建虚拟网卡 + 全量路由统一接管系统流量（移动端承载代理的可靠通路是 VPN，而非 HTTP 代理 / 应用内透明代理）。
- **配置可携带**：订阅导入复用桌面端规则（hysteria2 / hysteria / ss / vmess / vless / trojan / tuic / socks5 等），分流与测速方法论与桌面端对齐。
- **提瓦特统一体验**：延续桌面端深色玻璃拟态与语义化图标，Phone / Tablet 双形态自适应。
- **非目标（V1 不做）**：root 级 TUN 之外功能、多用户计费、企业管控。

## 里程碑状态

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| Phase 0 / M1 | T1–T4 可行性 PoC + 汇总 | ✅ 完成（结论「继续」，引擎冻结为自编内核 `.so`，见 [PoC-REPORT](docs/PoC-REPORT.md)） |
| M2 | 骨架：导入 → 启停 → 测速 → UI 联动（双形态） | ✅ 出口达成（2026-09-28，真实节点链路真机全通） |
| M3 | V1.0 内测：P0 功能完整 + 真机冒烟 + 提审材料 | ⬜ 进行中（详见[《后续开发计划》](docs/Arkhon%20后续开发计划.md)） |
| M4 | V1.0 发布（港区上限 + 侧载主分发） | ⬜ |

**最低兼容版本：API 26**（`compatibleSdkVersion: "26.0.0"`），API 26 以下设备不可安装。

## 已落地能力（截至 M2）

- **订阅导入**：协议 URI（hysteria2 / hysteria / ss / vmess / vless / trojan / tuic / socks5）+ 配置格式（sing-box JSON / SSD JSON / Surge 节点行）自动识别转换；未知格式给可读报错；支持排除关键词过滤。
- **节点与策略组**：节点列表；Select 组手动切换（即时回读）、`url-test` 自动组测速；并发测速（6 路）+ 延迟结果本地缓存。
- **隧道与保活**：一键启停 + 系统授权回调 + 档案变更热重载；主进程 `setAppNet` 绑定 VPN 网络；长时任务 + 常驻通知随隧道生命周期；「长时任务取消即重申请」跨系统回收周期存活。
- **稳定性**：扩展进程内自愈（心跳 30s，连续 3 次失联 → 重建 fd + 内核重启）；主进程 30s 自检 / 进程级重建兜底；内核日志流断线自动重连。
- **连通性诊断**：gstatic / google / example / ipv4.google.com / ipv6.google.com / baidu 六站点 + 256KB 大文件实测，一键区分「节点侧 / DNS / 大包 / 未接管」类问题。
- **UI**：Phone（底部悬浮导航）/ Tablet（侧边栏）双形态；深色提瓦特玻璃拟态；沉浸系统栏。

## 技术架构

**请求链路**：系统流量 → VPN 虚拟网卡 fd → gvisor 用户态栈（用户态完成 TCP 握手，SYN-ACK 直接写回 fd）→ mihomo 内核 → 上游节点 → 出网。

**控制链路**：UI → `TunnelManager`（主进程）→ `want.parameters` 下发配置 → `VpnExtAbility` 落盘（系统重启回退用）并注入进程字段（`interface-name` 物理承载网卡、`log-file`）→ 内核 `clashStart` / `clashAttach(fd)`。

**数据面**：主进程经 loopback external-controller REST 读写节点 / 策略组 / 延迟。

**关键工程点**（真机证据见 [PoC-REPORT](docs/PoC-REPORT.md) / [T3-内核保活](docs/T3-内核保活.md)）：

- OHOS Go fork（`GOOS=openharmony`）解决 musl `initial-exec TLS` 的 `dlopen` 障碍（`TLS_GD`）；
- gvisor 栈绕过 OHOS 沙箱对 `fstat` 的 EPERM（改 `getsockopt(SO_TYPE)` 探测）；
- 配置显式 `profile.store-selected: false`，避免策略组选择被 `cache.db` 缓存带偏（防「连着却不走代理」）。

## 目录结构

```
AppScope/                              应用级配置（bundleName = cn.luoqingciya.arkhon）
entry/src/main/
  ets/
    core/                              主进程服务层：UriParser / ProfileStore / ConfigBuilder /
                                       TunnelManager / KernelRest / SpeedTester
    model/Types.ets                    共享类型
    views/                             总览 / 订阅 / 代理 / 设置 四视图 + Theme
    pages/Index.ets                    双形态外壳（Phone 底栏 ↔ Tablet 侧栏）
    serviceextability/VpnExtAbility.ets  VPN 建链 + 内核实载 + 扩展内自愈
    common/                            KeepAlive（长时任务）等
  cpp/                                 NAPI 桥（libentry.so：dlopen libclash.so / clashStart / clashAttach）
  libs/arm64-v8a/libclash.so           内核产物（arkhon-core 编出，见下）
experiments/                           工具链自举与 PoC 探针（T2 / T3）
docs/                                  策划书 / Phase 0 清单 / PoC 报告 / T2–T4 / 后续开发计划
```

## 快速开始

**环境**：DevEco Studio（HarmonyOS NEXT SDK）+ 真机（API 26 及以上）。

1. **准备内核 `.so`**（二选一，脚本均在 `experiments/T3-toolchain/`）：

```powershell
# A. 拉取内核 CI 预编译产物（推荐；缺省 tag 时自动取最新 release）
.\experiments\T3-toolchain\download-clashlib.ps1 v1.2.3    # → entry/libs/arm64-v8a/libclash.so

# B. 本地交叉编译（需先自举 OHOS Go fork 工具链）
.\experiments\T3-toolchain\build-toolchain.ps1
.\experiments\T3-toolchain\build-clashlib.ps1
```

2. **构建 HAP**（DevEco Studio Run，或 CLI）：

```powershell
$env:DEVECO_SDK_HOME = "<DevEco Studio>\sdk"
$node    = "<DevEco Studio>\tools\node\node.exe"
$hvigorw = "<DevEco Studio>\tools\hvigor\bin\hvigorw.js"
& $node $hvigorw --mode module -p module=entry@default -p product=default -p buildMode=debug assembleHap --no-daemon
# 产物：entry/build/default/outputs/default/entry-default-signed.hap
```

3. **安装到真机**（需解锁屏幕；`hdc` 位于 `<DevEco Studio>\sdk\default\openharmony\toolchains\`）：

```powershell
hdc install -r entry\build\default\outputs\default\entry-default-signed.hap
```

4. 打开 Arkhon → 导入订阅 → 总览页「启动 VPN」→ 系统授权弹窗点「允许」。

> 权限：`module.json5` 已声明 `INTERNET` / `GET_NETWORK_INFO` 等及 VPN 扩展（`VpnExtAbility`，type=`vpn`）。

## 已知限制

| # | 限制 | 说明 |
| --- | --- | --- |
| 1 | **接管范围** | 只能代理**鸿蒙三方应用**；系统应用（如华为浏览器）与「卓易通」内安卓应用不在接管范围（平台限制，非缺陷）。对照：卓易通内安卓代理软件可代理「兼容层安卓应用 + 鸿蒙三方应用」，接管面更大。 |
| 2 | **IPv6 视节点出口能力** | 已接管 IPv6（默认路由进隧道、不再直连泄漏；平台「v6 路由须显式网关」的坑已在 M3·B1 修复、真机实证）；实际 v6 站点可达性取决于订阅节点是否有 v6 出口——节点无 v6 时双栈站点回退 IPv4。 |
| 3 | **最低 API 26** | API 26 以下设备不可安装。 |
| 4 | 真机流程环境敏感 | `hvigorw` 需通过 DevEco 内置 node 执行；锁屏时 `aa start` 失败——规避步骤见 [T4-构建](docs/T4-构建.md)。 |

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [策划书](docs/Arkhon%20项目策划书.md) | 产品定位 / 判据 / 里程碑 / 风险 |
| [Phase 0 任务清单](docs/Arkhon%20Phase0-任务清单.md) | T1–T4 任务与结论登记（含实测 API 事实） |
| [PoC 汇总报告](docs/PoC-REPORT.md) | M1 出口：三态结论 / 指标对照 / 引擎冻结 |
| [T2-工具链](docs/T2-工具链.md) | OHOS Go fork 自举与交叉编译 |
| [T3-内核保活](docs/T3-内核保活.md) | 内核实载 + 保活 5 项真机实验 |
| [T4-构建](docs/T4-构建.md) | 构建 / 安装脚本、三形态基准、日志取证方法 |
| [后续开发计划](docs/Arkhon%20后续开发计划.md) | M2–M4 逐项任务、进度与排查记录 |
| [想法-卓易通容器流量接管](docs/想法-卓易通容器流量接管.md) | 接管范围扩展：ClashBox「兼容模式」参考与待讨论议题（待讨论） |

## 相关项目

- 桌面端客户端：[Teyvat Arkhon](https://github.com/luoqingciya/Teyvat-Arkhon)（Electron + arkhon-core）
- 定制内核：[arkhon-core](https://github.com/luoqingciya/arkhon-core)（MetaCubeX/mihomo fork；OHOS 产物 `arkhon-ohos-arm64-<tag>.so`）

## 安全说明

- 本仓库**不包含任何节点/订阅凭据**（历史遗留凭据已从代码与 git 历史清理）；导入的订阅数据仅存于本机。

## 协议

[GPL-3.0](LICENSE)