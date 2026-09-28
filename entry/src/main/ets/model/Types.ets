/**
 * 数据模型：节点 / 档案 / 延迟缓存 / 内核视图 / 运行态
 *
 * 约定：
 *  - 应用内统一使用「节点模型 ProxyNode」（业务字段，不含内核格式细节）；
 *  - 下发内核前由 ConfigBuilder 序列化为 mihomo 配置字段（含连字符键）；
 *  - 档案（Profile）= 一次导入产出的节点集合 + 来源信息。
 */

/** 隧道运行态（UI 全局状态，AppStorage 键 'tunnelState'） */
export enum TunnelState {
  Stopped = 0,
  Starting = 1,
  Running = 2,
  Error = 3
}

/** 导入内容识别结果类型 */
export enum ImportKind {
  UriList = 'uri-list',
  SingBox = 'sing-box',
  Ssd = 'ssd',
  Surge = 'surge',
  Unknown = 'unknown'
}

/** 节点（支持协议：hysteria2 / hysteria / ss / vmess / vless / trojan / tuic / socks5） */
export interface ProxyNode {
  name: string;
  type: string;
  server: string;
  port: number;
  // 凭据
  password?: string;
  uuid?: string;
  username?: string;
  cipher?: string;
  alterId?: number;
  authStr?: string;
  // 传输与 TLS
  udp?: boolean;
  tls?: boolean;
  sni?: string;
  servername?: string;
  alpn?: string[];
  skipCertVerify?: boolean;
  clientFingerprint?: string;
  flow?: string;
  network?: string;
  wsPath?: string;
  wsHost?: string;
  grpcServiceName?: string;
  httpPath?: string;
  httpHost?: string;
  realityPublicKey?: string;
  realityShortId?: string;
  // hysteria2 专属
  fingerprintPin?: string;
  ports?: string;
  hopInterval?: string;
  obfs?: string;
  obfsPassword?: string;
  up?: string;
  down?: string;
  // ss 插件
  plugin?: string;
  pluginOptsRaw?: string;
  // tuic
  congestionController?: string;
}

/** 订阅档案 */
export interface Profile {
  id: string;
  name: string;
  url: string;          // 来源 URL；粘贴导入为空串
  kind: string;         // ImportKind 值，展示用
  nodes: ProxyNode[];
  updatedAt: number;
}

/** 延迟缓存项（按档案 id + 节点名缓存在本地） */
export interface DelayEntry {
  delay: number;        // >0 可用；-1 超时/失败
  at: number;           // 记录时间戳
}

/** 本地持久化数据（store.json） */
export interface StoreData {
  profiles: Profile[];
  activeId: string;
  /** 延迟缓存：档案 id → 节点名 → 最近延迟 */
  delays: Record<string, Record<string, DelayEntry>>;
}

/** 导入结果（可读报错） */
export interface ImportResult {
  ok: boolean;
  kind: ImportKind;
  nodes: ProxyNode[];
  error: string;
}

/** 内核 REST /proxies 单项（组与节点共用结构） */
export interface KernelProxyItem {
  type: string;
  now?: string;
  all?: string[];
  alive?: boolean;
  history?: KernelDelayHistory[];
}

/** 内核 /proxies/{name}/delay 响应 */
export interface KernelDelayResp {
  delay?: number;
  message?: string;
}

export interface KernelDelayHistory {
  time: string;
  delay: number;
}

/** 内核 /proxies 响应 */
export interface KernelProxiesResp {
  proxies: Record<string, KernelProxyItem>;
}

/** 内核 /version 响应 */
export interface KernelVersionResp {
  version?: string;
}

/** 策略组（UI 展示用，从内核 /proxies 归纳） */
export interface ProxyGroupView {
  name: string;
  type: string;
  now: string;
  members: string[];
}

/** 总览页状态快照（AppStorage 同步用） */
export interface TunnelStatus {
  state: number;         // TunnelState
  activeProfile: string; // 当前档案名
  currentNode: string;   // 当前出口节点（PROXY.now）
  message: string;       // 最近一条状态说明
}