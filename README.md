# Arkhon · 鸿蒙版

> HarmonyOS NEXT 原生网路代理客户端的 **Phase 0 可行性验证**仓库。当前处于 PoC 阶段（T1/T2 已通过实机验证；T3 进行中：Gate-A/B/D1-D5 已真机闭环；**D5e 全量路由+上游代理出网已在 Mate 80 Pro 真机关闭环**：主进程 TCP 隧道出网 code=200、域名全链路 code=200）。

在手机/平板的移动网络下，通过 **VPN 隧道**统一接管流量，复用桌面端 [Teyvat Arkhon](https://github.com/luoqingciya/Teyvat-Arkhon) 已验证的订阅、分流与测速方法论，承载订阅与规则的「移动延伸」，最终实现 **手机 + 平板双形态统一代理体验**。

## 状态

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| T1 | VPN 能力复核（虚拟网卡 + 受限路由 + DNS + 授权） | ✅ 通过（API 26 实机） |
| T2 | Go 交叉编译工具链（arkhon-core / mihomo → OpenHarmony `.so`） | ✅ 通过（Gate-B 真机可加载） |
| T3 | 内核实载与保活（`.so` 加载 + VPN 接管 + 回收自恢复） | 🟡 进行中（真实内核已在进程内起内核 + 数据面通流；D5 隧道喂流真机 attach 成功；**D5e 已闭环：gvisor 栈下主进程隧道出网 TCP/域名全链路 200**） |
| T4 | 构建链路与三形态基准确认（Phone / Tablet / 折叠屏） | ⏳ PoC |

> 若「VPN 不受支持」或「内核编不进且裁剪库亦不可行」，则收缩至**纯订阅管理 + 节点测速 + 规则只读工具**（No-Go 判据，仍可发布）。详见 [`docs/Arkhon 项目策划书.md`](docs/Arkhon%20项目策划书.md) 与 [`docs/Arkhon Phase0-任务清单.md`](docs/Arkhon%20Phase0-任务清单.md)。

### Gate-B 技术要点（T2/T3 关键突破）

股票 Go 编译的 c-shared `.so` 在 OHOS musl 下会因 `initial-exec TLS` 无法 `dlopen`（报 `initial-exec TLS resolves to dynamic definition`）。**正解**是使用 OpenHarmony SIG 官方 Go fork（`GOOS=openharmony`，内置 general dynamic `TLS_GD`）交叉编译，使 TLS 重定位变为 `R_AARCH64_TLSDESC`。已在 **Mate 80 Pro** 实测通过：

```
T2 loaded=1 hello="hello, arkhon" add=5   // Go 导出函数经 NAPI/dlsym 真实运行
```

工具链自举与交叉编译脚本见 `experiments/T3-toolchain/`。

### Gate-D 真机实测（T3 · 真实内核在进程内跑通）

用上面工具链把**真实内核**编为 `libclash.so`，应用进程内 NAPI 加载并启动，已验证三层：

```
T3 kernel loaded=1 version=1.10.0                 // libclash.so dlopen 成功
T3 kernel start code=0 err=                        // hub.Parse 启动内核成功
T3 REST /version  {"meta":true,"version":"1.10.0"} // 内核 REST 控制器存活
T3 proxy HTTP     HTTP/1.1 200 OK len=868          // 经内核混合代理真实通流
```

至此「手机本地真实内核 + 进程内运行 + 数据面可达」已证（与 ClashBox 同路线）。**D5 隧道喂流已在 Mate 80 Pro 真机关闭环**：确认 `GOOS=openharmony` 通过 OHOS Go fork 映射 `linux` 构建标签，sing-tun `tun_linux.go`（`NativeTun` 支持 `FileDescriptor`）被编译；clashlib 新增导出 `arkhon_core_attach(fd)`，VpnExtAbility 在**VPN 扩展进程内**起内核并把 fd attach。真机实测日志（进程 `cn.luoqingciya.arkhon:vpn`）：

```
vpn connection created, fd=33 addr=10.21.0.2 route=10.22.0.0/16  // 隧道 fd
[D5] ext kernel loaded=1 version=1.10.0                            // 扩展进程内 libclash 加载
[D5] ext kernel start code=0 err=                                  // hub.Parse 起内核成功
[D5] ext kernel attach fd=33 code=0 err=                          // arkhon_core_attach → TUN listener 绑定 fd
```

（`ReCreateTun` 同步建 gvisor TUN 栈绑定 fd，失败会返回错误串，此处 code=0 即绑定成功。）构建脚本 `experiments/T3-toolchain/build-clashlib.ps1`，NAPI `entry/src/main/cpp/napi_init.cpp`（`clashAttach(fd)`），页面 `entry/src/main/ets/pages/Index.ets`，隧道喂流入口 `entry/src/main/ets/serviceextability/VpnExtAbility.ets`。

### Gate-D D5e 真机实测（全量路由 + 上游节点出网，✅ 已闭环）

放开 `0.0.0.0/0` 默认路由 + 注入上游 hysteria2 节点（IP 直连 + 开内核 DNS 修复节点拨号）后，真机关键证据：

```
[D5e] rest /proxies 200  PROXY.now = Master Studio-zz（type=Hysteria2）   // 节点注册进内核
[D5e] delay(node)  200   {"delay":823}                                    // 内核→hy2 节点拨号通
[D5e] loopback-proxy       HTTP/1.1 200 OK len=297                        // 扩展进程→内核混合代理→节点→目标
[D5e] klog (REST /logs 实时流)
  [TCP] 10.21.0.2:33850 → 172.66.147.243:80 match PROXY[Master Studio-zz]  // 主进程隧道出网进内核
  [UDP] 10.21.0.2:41538 → 8.8.8.8:53        match PROXY[Master Studio-zz]  // 隧道内系统 UDP DNS
[D5e] tunnel-out-ip   code=200 len=559   // 主进程→隧道→内核→节点→公网（IP 直通）
[D5e] tunnel-out-host code=200 len=559   // 域名 DNS + 数据面全链路
```

**全链路已闭环**：系统真实流量（源=虚拟网卡 10.21.0.2）→ 隧道 fd → **gvisor 用户态栈（用户态完成 TCP 握手，SYN-ACK 直接写回 fd）** → mihomo 内核 → 上游 hy2 节点 → 出网。

**关键技术决策（TUN 栈选型）**：
- **首轮 system 栈失败**：`system` 栈 TCP 机制是「进程内 NAT：SYN 改写为目标 `127.0.0.1:随机端口` 并写回 fd，依赖宿主本机 TCP 栈完成握手后再交给 mihomo」。但 OHOS VPN 隧道 fd 写回路径是『发往 VPN 网络转发』而非『注入宿主协议栈』→ 改写后的 SYN 有去无回（真机 `/proc/net/tcp`：`10.21.0.2 → 公网IP:80` 状态 `SYN_SENT` 重传 N 次，SYN-ACK 永远缺席）。
- **最终方案 gvisor 栈**：在用户态独立完成 TCP 握手，SYN-ACK 直接写回 fd，不依赖宿主栈。
- **OHOS Fstat 绕过**：gvisor fdbased 创建端点时 `IsSocketFD` 调 `unix.Fstat` 被 OHOS 沙箱 EPERM → 已在 `mihomo-teyvat/third_party/gvisor/pkg/tcpip/link/fdbased/endpoint.go` 改为 `getsockopt(SO_TYPE)` 探测（受限环境容忍为 false → readv dispatcher）；`clashlib/go.mod` 加 `replace github.com/metacubex/gvisor => mihomo-teyvat/third_party/gvisor`；`clashlib/main.go` TUN 栈 `TunSystem`→`TunGvisor`、网段 `198.18.0.1/30`+`fdfe:dcba:9876::1/126`。

## 产品定位

- **一句话**：HarmonyOS NEXT 上的开源分流代理客户端，通过 VPN 隧道统一接管移动网络流量。
- **单一接管路径（VPN 为主）**：以 `VpnExtensionAbility` 建虚拟网卡 + 路由统一接管系统流量（行业已由 ClashBox 实证：移动端承载代理的可靠通路是 VPN，而非 HTTP 代理 / 应用内透明代理）。
- **配置可携带**：订阅 URI 导入复用桌面端格式（hysteria2 / vless / vmess / trojan / ss 等），分流预设逻辑与桌面端对齐。
- **提瓦特统一体验**：继承桌面端深色玻璃拟态与语义化图标。
- **非目标（V1 不做）**：root 级 TUN 之外功能、多用户计费、企业管控。

## 快速开始

1. 使用 **DevEco Studio**（HarmonyOS NEXT / OpenHarmony SDK，API 11+）打开本目录。
2. 真机开启开发者模式并连接，选择设备点击 **Run**。
3. API 26 实机流程：首页点击「启动 VPN」→ 系统弹出授权 → 点「允许」→ 校验是否建链（设置 → 系统 → VPN 应出现 Arkhon 条目）。

### 权限声明

`entry/src/main/module.json5` 已声明 VPN 扩展与必要权限：

```json5
// ohos.permission.INTERNET / GET_NETWORK_INFO / ACCESS_EXTENSIONAL_DEVICE_DRIVER
// extensionAbilities: { "name": "VpnExtAbility", "type": "vpn", "exported": true }
```

## 目录结构

```
AppScope/                         # 应用级配置（bundleName 等）
entry/src/main/
  ets/entryability/EntryAbility.ets
  ets/serviceextability/VpnExtAbility.ets   # VPN 建虚拟网卡 + 路由 + DNS 核心
  ets/pages/Index.ets                       # T1 VPN 验证 + T2/T3 Go .so 加载探针
  module.json5                              # 权限与 VPN 扩展注册
experiments/
  T2-toolchain/                             # 交叉编译探针（hellogo + NDK junction）
  T3-toolchain/                             # OHOS Go fork 自举 + GOOS=openharmony 交叉编译
```

## 迭代目标里程碑

- **P0 · Phase 0 PoC**：T1–T4 全部落结论为「继续」，固化技术路线。
- **P1 · V1 主线**：订阅管理 + 节点测速 + 分流规则 + 内核实载 + VPN 隧道一体化客户端。
- **多形态**：Phone / Tablet / 折叠屏三形态自适应，后台长时任务保活。

## 相关项目

- 桌面端客户端：[Teyvat Arkhon](https://github.com/luoqingciya/Teyvat-Arkhon)（Electron + arkhon-core 内核）
- 定制内核：[arkhon-core](https://github.com/luoqingciya/arkhon-core)（MetaCubeX/mihomo fork）

## 协议

[GPL-3.0](LICENSE)