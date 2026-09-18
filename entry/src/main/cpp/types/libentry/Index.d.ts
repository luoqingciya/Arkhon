/**
 * libentry.so 的 NAPI 类型声明。
 * 对齐 entry/src/main/cpp/napi_init.cpp 导出的 5 个函数。
 * 使 `import goNative from 'libentry.so'` 在 IDE 静态检查与 hvigor 构建中均能解析。
 */

export interface GoHelloResult {
  /** libgo.so 是否已 dlopen 加载 */
  loaded: boolean;
  /** GoRunHello 返回的 hello 字符串 */
  hello: string;
  /** GoAdd(1,2) 结果 3（验功能） */
  add: number;
  /** GoProbeNetCrypto 结果（-2=未导出可选项） */
  probe: number;
  /** 加载/调用错误信息（空串=无） */
  err: string;
}

export interface ClashVersionResult {
  /** libclash.so 是否已 dlopen 加载 */
  loaded: boolean;
  /** 内核版本号 */
  version: string;
  /** 错误信息（空串=无） */
  err: string;
}

export interface ClashStartResult {
  /** 0=成功 */
  code: number;
  /** 错误信息（空串=无） */
  err: string;
}

export interface ClashAttachResult {
  /** 0=成功 */
  code: number;
  /** 错误信息（空串=无） */
  err: string;
}

/** T2：加载 Go hello 库并执行加法/探测 */
export const loadGoHello: () => GoHelloResult;

/** T3：读取内核版本 */
export const clashVersion: () => ClashVersionResult;

/** T3/D5：启动内核。
 * @param home 数据目录（日志/缓存落盘处）
 * @param cfg  内核 JSON 配置（含 proxies/groups/rules）
 * @param extController external-controller REST 地址，如 "127.0.0.1:9096"
 */
export const clashStart: (home: string, cfg: string, extController: string) => ClashStartResult;

/** 停止内核 */
export const clashStop: () => ClashStartResult;

/** D5：把 VPN 隧道 fd 挂到内核 TUN listener。
 * @param fd VpnConnection.create() 返回的虚拟网卡句柄
 */
export const clashAttach: (fd: number) => ClashAttachResult;