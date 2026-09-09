# Arkhon · 鸿蒙版

> HarmonyOS NEXT 原生网路代理客户端的 **Phase 0 可行性验证**仓库。当前处于 PoC 阶段（T1/T2 已通过实机验证；T3 进行中：Gate-A/B/D1-D4 已真机闭环，剩 D5 VPN 隧道喂流）。

在手机/平板的移动网络下，通过 **VPN 隧道**统一接管流量，复用桌面端 [Teyvat Arkhon](https://github.com/luoqingciya/Teyvat-Arkhon) 已验证的订阅、分流与测速方法论，承载订阅与规则的「移动延伸」，最终实现 **手机 + 平板双形态统一代理体验**。

## 状态

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| T1 | VPN 能力复核（虚拟网卡 + 受限路由 + DNS + 授权） | ✅ 通过（API 26 实机） |
| T2 | Go 交叉编译工具链（arkhon-core / mihomo → OpenHarmony `.so`） | ✅ 通过（Gate-B 真机可加载） |
| T3 | 内核实载与保活（`.so` 加载 + VPN 接管 + 回收自恢复） | 🟡 进行中（真实内核已在进程内起内核 + 数据面通流；剩 D5 隧道喂流） |
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

至此「手机本地真实内核 + 进程内运行 + 数据面可达」已证（与 ClashBox 同路线）。剩余 **D5**：VPN 扩展进程内把 `requestId` 隧道 fd 喂给内核，实现系统流量透明接管。构建脚本 `experiments/T3-toolchain/build-clashlib.ps1`，NAPI 探针 `entry/src/main/cpp/napi_init.cpp`，页面 `entry/src/main/ets/pages/Index.ets`。

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