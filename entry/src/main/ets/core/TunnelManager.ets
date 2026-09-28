/**
 * M2 · 隧道管理（控制面）
 *
 * 职责：VPN 扩展启停 · 内核配置下发（want.parameters）· 授权监听 · 主进程绑定 VPN 网络 ·
 *      长时任务保活（KeepAlive）· 周期自检与自动重建（T3 基线转正）· 运行态发布（AppStorage）。
 *
 * 与 T3 PoC 差异：
 *  - 配置不再内联在扩展进程，由本服务按「激活档案」生成后经 want.parameters 下发；
 *  - 自检/自恢复逻辑从页面抽出为服务，页面只读 AppStorage 状态；
 *  - 扩展进程内自愈（内核守护）由 VpnExtAbility 承担，本服务负责进程级重建兜底。
 */
import { Want, common } from '@kit.AbilityKit';
import { connection, vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import httpRequest from '@ohos.net.http';
import { KeepAlive } from '../common/KeepAlive';
import { ProfileStore } from './ProfileStore';
import { buildKernelConfig, EXT_MIXED_PORT } from './ConfigBuilder';
import { KernelRest } from './KernelRest';
import { Profile, TunnelState } from '../model/Types';

const DOMAIN = 0x0000;
const TAG = 'TunnelManager';
const BUNDLE = 'cn.luoqingciya.arkhon';
const EXT_ABILITY = 'VpnExtAbility';

const MONITOR_INTERVAL_MS = 30000;   // 自检周期
const MONITOR_EGRESS_EVERY = 6;      // 每 N 次自检做一次隧道出网实测（约 3 分钟）
const MONITOR_REFRESH_EVERY = 8;     // 每 N 次自检刷新一次长时任务（约 4 分钟）
const MONITOR_NODE_EVERY = 2;        // 每 N 次自检刷新一次「当前节点」
const MONITOR_GRACE_MS = 90000;      // 建链宽限期：期间不做回收判定
const VPN_MISS_LIMIT = 2;            // VPN 网络连续丢失阈值（30s × 2）
const RECOVER_COOLDOWN_MS = 60000;   // 自动重建冷却
const EXT_KERNEL_FAIL_LIMIT = 3;     // 扩展内核 REST 连续失败阈值
const RESTART_SETTLE_MS = 800;       // stop → start 间隔（等旧连接释放）

// AppStorage 键（UI 只读）
export const KEY_STATE = 'tunnelState';
export const KEY_MESSAGE = 'tunnelMessage';
export const KEY_PROFILE = 'tunnelProfile';
export const KEY_NODE = 'tunnelNode';
export const KEY_KEEP = 'keepInfo';
export const KEY_LOGS = 'tunnelLogs';

export class TunnelManager {
  private static ctx: common.UIAbilityContext | null = null;
  private static state: TunnelState = TunnelState.Stopped;
  private static observer: vpnExtension.VpnObserver | null = null;
  private static monTimer: number = -1;
  private static monTick: number = 0;
  private static extKernelFails: number = 0;
  private static vpnMissCount: number = 0;
  private static graceUntil: number = 0;
  private static lastRecoverAt: number = 0;
  private static lastKeepRetryAt: number = 0;

  /** 应用启动时初始化：注册授权监听 + 探测既有隧道 + 恢复自检 */
  static init(ctx: common.UIAbilityContext): void {
    if (TunnelManager.ctx !== null) {
      return;
    }
    TunnelManager.ctx = ctx;
    AppStorage.setOrCreate(KEY_STATE, TunnelState.Stopped);
    AppStorage.setOrCreate(KEY_MESSAGE, '未启动');
    AppStorage.setOrCreate(KEY_PROFILE, '—');
    AppStorage.setOrCreate(KEY_NODE, '—');
    AppStorage.setOrCreate(KEY_KEEP, '保活未启动');
    AppStorage.setOrCreate(KEY_LOGS, []);
    TunnelManager.registerObserver();
    KeepAlive.watch((line: string) => {
      TunnelManager.log(line);
      if (line.indexOf('长时任务被取消') >= 0 || line.indexOf('长时任务挂起') >= 0) {
        TunnelManager.reArmKeepAlive('系统回收长时任务');
      }
    });
    TunnelManager.detectExistingTunnel();
  }

  static getState(): TunnelState {
    return TunnelManager.state;
  }

  static isRunning(): boolean {
    return TunnelManager.state === TunnelState.Running || TunnelManager.state === TunnelState.Starting;
  }

  /** 启动隧道（用当前激活档案的配置） */
  static async start(): Promise<string> {
    const ctx = TunnelManager.ctx;
    if (ctx === null) {
      return '未初始化';
    }
    if (TunnelManager.isRunning()) {
      return '隧道已在运行';
    }
    const profile = ProfileStore.activeProfile();
    TunnelManager.publishProfile(profile);
    TunnelManager.setState(TunnelState.Starting,
      profile !== null ? `正在启动隧道（${profile.name}，${profile.nodes.length} 节点）…` : '正在启动隧道（无档案：直连模式）…');
    const want = TunnelManager.buildWant(profile);
    try {
      await vpnExtension.startVpnExtensionAbility(want);
      TunnelManager.log('[UI] startVpnExtensionAbility ok（等待系统授权/建链）');
    } catch (e) {
      const err = e as BusinessError;
      TunnelManager.setState(TunnelState.Error, `启动失败 code=${err.code} msg=${err.message}`);
      return TunnelManager.message();
    }
    TunnelManager.startMonitor();
    TunnelManager.bindVpnNet(0);
    return TunnelManager.message();
  }

  /** 停止隧道（扩展销毁 → VPN 网络撤销 → 内核随进程退出） */
  static async stop(): Promise<string> {
    const ctx = TunnelManager.ctx;
    if (ctx === null) {
      return '未初始化';
    }
    const want = TunnelManager.buildWant(null);
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
      TunnelManager.log('[UI] stopVpnExtensionAbility ok');
    } catch (e) {
      const err = e as BusinessError;
      TunnelManager.log(`[UI] stopVpnExtensionAbility 失败 code=${err.code} msg=${err.message}（忽略继续）`);
    }
    TunnelManager.stopMonitor();
    await KeepAlive.stop(ctx).then((msg: string) => {
      AppStorage.setOrCreate(KEY_KEEP, msg);
    });
    // 主进程网络解绑：恢复默认网络（best-effort）
    try {
      const def: connection.NetHandle = await connection.getDefaultNet();
      await connection.setAppNet(def);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '恢复默认网络失败（忽略）');
    }
    TunnelManager.setState(TunnelState.Stopped, '隧道已断开');
    return TunnelManager.message();
  }

  /** 重建（档案切换/刷新后热重载；亦用于自恢复兜底） */
  static async restart(reason: string): Promise<string> {
    const ctx = TunnelManager.ctx;
    if (ctx === null) {
      return '未初始化';
    }
    TunnelManager.log(`[重建] ${reason} → 重启扩展`);
    const want = TunnelManager.buildWant(null);
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (e) {
      // 旧实例可能已不存在，忽略
    }
    TunnelManager.stopMonitor();
    await sleep(RESTART_SETTLE_MS);
    TunnelManager.state = TunnelState.Stopped;
    return await TunnelManager.start();
  }

  /** 档案发生变化（导入/切换/删除/刷新）后调用：运行中则热重载配置 */
  static onProfileChanged(): void {
    const profile = ProfileStore.activeProfile();
    TunnelManager.publishProfile(profile);
    if (TunnelManager.state === TunnelState.Running) {
      TunnelManager.restart('档案变更，热重载内核配置');
    }
  }

  /** 单次自检（设置页诊断按钮亦可触发） */
  static monitorOnce(): void {
    TunnelManager.doMonitor();
  }

  /** 隧道出网实测（主进程 HTTP 走系统 VPN 默认路由），返回响应码；失败返回 -1 */
  static async egressProbe(): Promise<number> {
    return await TunnelManager.egressViaHttp();
  }

  /**
   * 连通性诊断：依次探测「google 系（IPv4/IPv6）与国内基线」，最后做大文件实测，逐个落日志。
   * 用途：区分「节点侧不可达」「IPv6 未走隧道」「DNS 解析异常」「MTU/大包卡死」「仅特定站点不通」几类问题。
   */
  static async probeTargets(): Promise<string> {
    const targets: string[] = [
      'http://www.gstatic.com/generate_204',
      'https://www.google.com/',
      'https://example.com/',
      'https://ipv4.google.com/',
      'https://ipv6.google.com/',
      'https://www.baidu.com/'
    ];
    const parts: string[] = [];
    for (const t of targets) {
      const code = await TunnelManager.httpGetCode(t);
      const host = hostOf(t);
      parts.push(`${host}=${code}`);
      TunnelManager.log(`[诊断] ${host} → ${code > 0 ? `HTTP ${code}` : '失败/超时'}`);
    }
    const bulk = await TunnelManager.probeBulk();
    parts.push(`bulk(256KB)=${bulk}`);
    TunnelManager.log(`[诊断] 汇总：${parts.join('，')}`);
    return parts.join('，');
  }

  /** 256KB 大文件实测：判定「小包通、大包卡」类问题（MTU / 数据面），走隧道 */
  static async probeBulk(): Promise<string> {
    const url = 'https://speed.cloudflare.com/__down?bytes=262144';
    const http = httpRequest.createHttp();
    const t0 = Date.now();
    try {
      const resp = await http.request(url, {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 20000,
        expectDataType: httpRequest.HttpDataType.ARRAY_BUFFER
      });
      const ms = Date.now() - t0;
      let bytes = 0;
      const r = resp.result;
      if (r instanceof ArrayBuffer) {
        bytes = r.byteLength;
      } else if (typeof r === 'string') {
        bytes = r.length;
      }
      try {
        http.destroy();
      } catch (e2) {
        // ignore
      }
      const msg = `HTTP ${resp.responseCode} ${bytes}B ${ms}ms`;
      TunnelManager.log(`[诊断] 大文件256KB → ${msg}`);
      return msg;
    } catch (e) {
      try {
        http.destroy();
      } catch (e2) {
        // ignore
      }
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '[诊断] 大文件256KB 失败 code=%{public}d msg=%{public}s ms=%{public}d',
        err.code, err.message, Date.now() - t0);
      return '失败/超时';
    }
  }

  /** 单次 GET，返回 HTTP 状态码；失败/超时返回 -1（与 egressViaHttp 同路径：走隧道） */
  private static async httpGetCode(url: string): Promise<number> {
    const http = httpRequest.createHttp();
    try {
      const resp = await http.request(url, {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      try {
        http.destroy();
      } catch (e) {
        // ignore
      }
      return resp.responseCode;
    } catch (e) {
      try {
        http.destroy();
      } catch (e2) {
        // ignore
      }
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '[诊断] %{public}s 失败 code=%{public}d msg=%{public}s',
        url, err.code, err.message);
      return -1;
    }
  }

  static message(): string {
    const v = AppStorage.get<string>(KEY_MESSAGE);
    return v === undefined ? '' : v;
  }

  static log(line: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', line);
    const prev = AppStorage.get<string[]>(KEY_LOGS);
    const arr: string[] = prev === undefined ? [] : prev;
    const next: string[] = [`[${timeLabel()}] ${line}`];
    for (const l of arr) {
      if (next.length >= 60) {
        break;
      }
      next.push(l);
    }
    AppStorage.setOrCreate(KEY_LOGS, next);
  }

  // ---------------------------------------------------------------- 内部

  private static setState(s: TunnelState, msg: string): void {
    TunnelManager.state = s;
    AppStorage.setOrCreate(KEY_STATE, s);
    AppStorage.setOrCreate(KEY_MESSAGE, msg);
    TunnelManager.log(`[状态] ${msg}`);
  }

  private static publishProfile(profile: Profile | null): void {
    AppStorage.setOrCreate(KEY_PROFILE,
      profile !== null ? `${profile.name}（${profile.nodes.length} 节点）` : '（无档案：直连模式）');
  }

  private static buildWant(profile: Profile | null): Want {
    const cfg = buildKernelConfig(profile, EXT_MIXED_PORT, 'info');
    const want: Want = {
      bundleName: BUNDLE,
      abilityName: EXT_ABILITY,
      parameters: { arkhonKernelConfig: cfg }
    };
    return want;
  }

  private static registerObserver(): void {
    if (TunnelManager.observer !== null) {
      return;
    }
    if (typeof vpnExtension.createVpnObserver !== 'function') {
      TunnelManager.log('[UI] 本设备不支持 createVpnObserver，跳过授权监听（以 VPN 网络出现为兜底信号）');
      return;
    }
    try {
      TunnelManager.observer = vpnExtension.createVpnObserver();
      TunnelManager.observer.onAuthorizationResult((granted: boolean) => {
        if (granted) {
          TunnelManager.log('[UI] 系统授权通过，等待建链');
          TunnelManager.bindVpnNet(0);
        } else {
          TunnelManager.setState(TunnelState.Error, '用户拒绝了 VPN 授权');
        }
      });
    } catch (e) {
      const err = e as BusinessError;
      TunnelManager.log(`[UI] createVpnObserver 异常 code=${err.code}（跳过）`);
    }
  }

  /** 轮询 BEARER_VPN 网络并 setAppNet 绑定主进程（最多 30 次 × 1s） */
  private static bindVpnNet(tries: number): void {
    if (tries > 30) {
      TunnelManager.log('[绑定] 30s 内未发现 VPN 网络，放弃绑定');
      return;
    }
    connection.getAllNets().then((nets: connection.NetHandle[]) => {
      let found = false;
      const scan = (i: number): void => {
        if (found || i >= nets.length) {
          if (!found) {
            setTimeout(() => {
              TunnelManager.bindVpnNet(tries + 1);
            }, 1000);
          }
          return;
        }
        connection.getNetCapabilities(nets[i]).then((cap: connection.NetCapabilities) => {
          if (cap.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
            found = true;
            const netId = nets[i].netId;
            connection.setAppNet(nets[i]).then(() => {
              TunnelManager.log(`[绑定] 主进程已绑定 VPN 网络 netId=${netId}`);
              if (TunnelManager.state !== TunnelState.Running) {
                TunnelManager.setState(TunnelState.Running, '隧道已连接');
                TunnelManager.startKeepAlive();
                TunnelManager.refreshCurrentNode();
              }
            }).catch((e: BusinessError) => {
              TunnelManager.log(`[绑定] setAppNet 失败 code=${e.code} msg=${e.message}`);
            });
          } else {
            scan(i + 1);
          }
        }).catch(() => {
          scan(i + 1);
        });
      };
      scan(0);
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'getAllNets 失败 code=%{public}d', e.code);
      setTimeout(() => {
        TunnelManager.bindVpnNet(tries + 1);
      }, 1000);
    });
  }

  private static startKeepAlive(): void {
    const ctx = TunnelManager.ctx;
    if (ctx === null) {
      return;
    }
    // 热重载/重建时旧长时任务仍在（隧道未断开）：刷新即可，避免重复申请报 9800005
    if (KeepAlive.isStarted()) {
      KeepAlive.refresh(ctx).then((msg: string) => {
        AppStorage.setOrCreate(KEY_KEEP, msg);
        TunnelManager.log(`[保活] ${msg}`);
      });
      return;
    }
    KeepAlive.start(ctx).then((msg: string) => {
      AppStorage.setOrCreate(KEY_KEEP, msg);
      TunnelManager.log(`[保活] ${msg}`);
    });
  }

  private static reArmKeepAlive(reason: string): void {
    const ctx = TunnelManager.ctx;
    if (ctx === null) {
      return;
    }
    const now = Date.now();
    if (now - TunnelManager.lastKeepRetryAt < 5000) {
      return;
    }
    TunnelManager.lastKeepRetryAt = now;
    TunnelManager.log(`[保活] ${reason} → 立即重申请长时任务`);
    KeepAlive.start(ctx).then((msg: string) => {
      AppStorage.setOrCreate(KEY_KEEP, msg);
      TunnelManager.log(`[保活] ${msg}`);
    });
  }

  private static startMonitor(): void {
    if (TunnelManager.monTimer >= 0) {
      return;
    }
    TunnelManager.monTick = 0;
    TunnelManager.extKernelFails = 0;
    TunnelManager.vpnMissCount = 0;
    TunnelManager.graceUntil = Date.now() + MONITOR_GRACE_MS;
    TunnelManager.monTimer = setInterval(() => {
      TunnelManager.doMonitor();
    }, MONITOR_INTERVAL_MS);
    TunnelManager.log(`[自检] 已启动（每 ${MONITOR_INTERVAL_MS / 1000}s）`);
  }

  private static stopMonitor(): void {
    if (TunnelManager.monTimer >= 0) {
      clearInterval(TunnelManager.monTimer);
      TunnelManager.monTimer = -1;
    }
  }

  private static doMonitor(): void {
    const ctx = TunnelManager.ctx;
    if (ctx === null) {
      return;
    }
    TunnelManager.monTick++;
    const tick = TunnelManager.monTick;
    // 1) 长时任务状态（回收检测一手信号）
    KeepAlive.report(ctx).then((rep: string) => {
      AppStorage.setOrCreate(KEY_KEEP, rep);
      TunnelManager.log(`[保活] #${tick} ${rep}`);
      if (TunnelManager.isRunning() && KeepAlive.taskCount === 0) {
        TunnelManager.reArmKeepAlive('长时任务已被系统取消');
      }
    });
    // 2) VPN 网络存在性（宽限期内不判定）
    TunnelManager.findVpnNetId().then((netId: number) => {
      if (netId < 0) {
        TunnelManager.vpnMissCount++;
      } else {
        TunnelManager.vpnMissCount = 0;
      }
      hilog.info(DOMAIN, TAG, '[自检] tick#%{public}d vpn-net=%{public}d miss=%{public}d',
        tick, netId, TunnelManager.vpnMissCount);
      if (netId < 0) {
        if (Date.now() < TunnelManager.graceUntil) {
          return;
        }
        if (TunnelManager.isRunning() && TunnelManager.vpnMissCount >= VPN_MISS_LIMIT) {
          TunnelManager.recover('VPN 网络连续丢失');
        }
      } else {
        TunnelManager.probeExtKernel(tick);
      }
    });
    // 3) 周期性隧道出网实测
    if (TunnelManager.isRunning() && tick % MONITOR_EGRESS_EVERY === 0) {
      TunnelManager.monitorEgress(tick);
    }
    // 4) 周期性刷新长时任务
    if (TunnelManager.isRunning() && tick % MONITOR_REFRESH_EVERY === 0) {
      KeepAlive.refresh(ctx).then((msg: string) => {
        TunnelManager.log(`[保活] #${tick} ${msg}`);
      });
    }
    // 5) 周期性刷新「当前节点」（内核 REST）
    if (TunnelManager.isRunning() && tick % MONITOR_NODE_EVERY === 0) {
      TunnelManager.refreshCurrentNode();
    }
  }

  private static async findVpnNetId(): Promise<number> {
    try {
      const nets: connection.NetHandle[] = await connection.getAllNets();
      for (const net of nets) {
        try {
          const cap: connection.NetCapabilities = await connection.getNetCapabilities(net);
          if (cap.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
            return net.netId;
          }
        } catch (e) {
          // 跳过单个失败
        }
      }
    } catch (e) {
      // ignore
    }
    return -1;
  }

  private static probeExtKernel(tick: number): void {
    KernelRest.version().then((v: string) => {
      if (v !== '') {
        TunnelManager.extKernelFails = 0;
        TunnelManager.log(`[自检] #${tick} 扩展内核 OK ${v}`);
      } else {
        TunnelManager.extKernelFails++;
        TunnelManager.log(`[自检] #${tick} 扩展内核失联（第 ${TunnelManager.extKernelFails} 次）`);
        if (TunnelManager.isRunning() && TunnelManager.extKernelFails >= EXT_KERNEL_FAIL_LIMIT) {
          TunnelManager.recover('扩展内核连续失联');
        }
      }
    });
  }

  private static monitorEgress(tick: number): void {
    TunnelManager.egressViaHttp().then((code: number) => {
      TunnelManager.log(`[自检] #${tick} 隧道出网 code=${code}`);
    });
  }

  /** 主进程 HTTP → 系统 VPN 默认路由 → 隧道 → 内核 → 上游节点（仅观测，不触发自恢复） */
  private static async egressViaHttp(): Promise<number> {
    const http = httpRequest.createHttp();
    try {
      const resp = await http.request('http://example.com/', {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      try {
        http.destroy();
      } catch (e) {
        // ignore
      }
      return resp.responseCode;
    } catch (e) {
      try {
        http.destroy();
      } catch (e2) {
        // ignore
      }
      return -1;
    }
  }

  private static refreshCurrentNode(): void {
    KernelRest.proxies().then((resp) => {
      if (resp === null || resp.proxies === undefined) {
        return;
      }
      const group = resp.proxies['PROXY'];
      if (group !== undefined && group.now !== undefined) {
        // DIRECT 说明当前未走代理（策略组被切到直连或被缓存带偏）→ 显式提示，避免"已连接但上不了外网"的困惑
        const label = group.now === 'DIRECT' ? 'DIRECT（未走代理，请在节点页选择节点）' : group.now;
        AppStorage.setOrCreate(KEY_NODE, label);
      }
    });
  }

  private static recover(reason: string): void {
    const now = Date.now();
    if (now - TunnelManager.lastRecoverAt < RECOVER_COOLDOWN_MS) {
      return;
    }
    TunnelManager.lastRecoverAt = now;
    TunnelManager.log(`[自恢复] 触发重建：${reason}`);
    TunnelManager.restart(reason);
  }

  /** 冷启动探测：App 被重开时隧道可能仍在运行（扩展进程由系统托管） */
  private static detectExistingTunnel(): void {
    const ctx = TunnelManager.ctx;
    if (ctx === null) {
      return;
    }
    TunnelManager.findVpnNetId().then((netId: number) => {
      if (netId < 0) {
        TunnelManager.log('[探测] 未发现 VPN 网络，隧道未运行');
        return;
      }
      TunnelManager.setState(TunnelState.Starting, `发现既有 VPN 网络 netId=${netId}，校验扩展内核…`);
      KernelRest.version().then((v: string) => {
        if (v !== '') {
          TunnelManager.setState(TunnelState.Running, '隧道已在运行（App 重启后接管）');
          TunnelManager.startKeepAlive();
          TunnelManager.startMonitor();
          TunnelManager.refreshCurrentNode();
        } else {
          TunnelManager.log('[探测] VPN 网络在而扩展内核不可达 → 触发重建');
          TunnelManager.restart('冷启动校验失败');
        }
      });
    });
  }
}

// ---------------------------------------------------------------- 小工具

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

function timeLabel(): string {
  const d = new Date();
  const hh = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
  const mm = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
  const ss = d.getSeconds() < 10 ? `0${d.getSeconds()}` : `${d.getSeconds()}`;
  return `${hh}:${mm}:${ss}`;
}

/** 从 URL 取主机名（仅用于诊断日志展示） */
function hostOf(url: string): string {
  const idx = url.indexOf('://');
  const rest = idx >= 0 ? url.slice(idx + 3) : url;
  const slash = rest.indexOf('/');
  return slash >= 0 ? rest.slice(0, slash) : rest;
}