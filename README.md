# Arkhon · 鸿蒙版

> HarmonyOS NEXT 原生网路代理客户端的 **Phase 0 可行性验证**仓库。当前处于 PoC 阶段（T1 已通过实机验证，T2/T3/T4 进行中）。

在手机/平板的移动网络下，通过 **VPN 隧道**统一接管流量，复用桌面端 [Teyvat Arkhon](https://github.com/luoqingciya/Teyvat-Arkhon) 已验证的订阅、分流与测速方法论，承载订阅与规则的「移动延伸」，最终实现 **手机 + 平板双形态统一代理体验**。

## 状态

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| T1 | VPN 能力复核（虚拟网卡 + 受限路由 + DNS + 授权） | ✅ 通过（API 26 实机） |
| T2 | Go 交叉编译工具链（arkhon-core / mihomo → OpenHarmony `.so`） | ⏳ PoC |
| T3 | 内核实载与保活（`.so` 加载 + VPN 接管 + 回收自恢复） | ⏳ PoC |
| T4 | 构建链路与三形态基准确认（Phone / Tablet / 折叠屏） | ⏳ PoC |

> 若「VPN 不受支持」或「内核编不进且裁剪库亦不可行」，则收缩至**纯订阅管理 + 节点测速 + 规则只读工具**（No-Go 判据，仍可发布）。详见 [`Arkhon 项目策划书.md`](Arkhon%20项目策划书.md)。

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
  ets/pages/Index.ets                       # T1 验证页（状态 + 授权监听 + 日志）
  module.json5                              # 权限与 VPN 扩展注册
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