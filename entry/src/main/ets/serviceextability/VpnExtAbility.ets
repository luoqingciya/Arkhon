/**
 * M2 · VpnExtensionAbility：隧道建链 + 内核实载 + 扩展内自愈
 *
 * 职责（相对 T3 PoC 的变化）：
 *  - 配置由主进程经 want.parameters['arkhonKernelConfig'] 下发（按激活档案生成）；
 *    下发内容落盘到扩展 home（kernel-config.json），供系统无参数重启时回退读取；
 *  - 内核启动前注入进程相关字段：log-file（绝对路径）+ interface-name（运行时探测物理承载网卡）；
 *  - 扩展内自愈（T3 约束「自恢复下沉」）：心跳 30s 探测本进程内核 REST，连续 3 次失联 →
 *    destroy 旧 VpnConnection → 重建 fd → 内核重启 → 重新 attach，主进程被冻结时隧道也能自恢复。
 *
 * API 事实（API 26 实测：见 `docs/Arkhon Phase0-任务清单.md`「T1 实测 API 事实」与 `docs/T3-内核保活.md`）：
 *  - VpnExtensionAbility 显式回调仅 onCreate/onDestroy；start 语义入口为 onRequest(want, startId)；
 *  - vpnExtension.createVpnConnection(this.context).create(config) 返回虚拟网卡 fd；
 *  - 重复 create 报 2203002（已存在）→ 需 destroy + recreate 拿回新 fd。
 */
import { VpnExtensionAbility, vpnExtension, socket, connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import httpRequest from '@ohos.net.http';
import fs from '@ohos.file.fs';
import process from '@ohos.process';
import { buffer } from '@kit.ArkTS';
import goNative, { ClashVersionResult, ClashStartResult, ClashAttachResult } from 'libentry.so';
import { buildKernelConfig, EXT_MIXED_PORT, EXT_REST_PORT } from '../core/ConfigBuilder';

const TAG = 'VpnExtAbility';
const DOMAIN = 0x0000;

// 隧道参数（全量默认路由 0.0.0.0/0，平板 API 26 已实测放开）
const VPN_ADDRESS = '10.21.0.2';
const VPN_ROUTE_IP = '0.0.0.0';
const VPN_ROUTE_PREFIX = 0;
const MAX_RETRY = 20;                  // 授权前 create 的重试上限（≈10s）
const RETRY_INTERVAL_MS = 500;
const RECOVER_RETRY = 2;               // 2203002 残留连接的销毁重建上限
const BIND_HOME = 'clash-ext';         // 内核数据目录（扩展进程沙箱）
const CONFIG_KEY = 'arkhonKernelConfig';
const KERNEL_CONFIG_FILE = 'kernel-config.json';

// 扩展内自愈
const HB_INTERVAL_MS = 30000;          // 心跳周期：探测本进程内核 REST
const KERNEL_FAIL_LIMIT = 3;           // 连续失败阈值 → 自愈
const HEAL_SETTLE_MS = 800;            // 重建前等待旧连接释放
const KLOG_CAP = 240;                  // klog 流常规行上限（调试期放大，便于抓浏览器流量）
const KLOG_ERR_CAP = 240;              // klog 流错误行上限（常规行用满后仍继续透传）
const KLOG_RETRY_MS = 2000;            // klog 流断线重连间隔

export default class VpnExtAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | null = null;
  private retryTimer: number = -1;
  private isUp: boolean = false;
  private fd: number = -1;
  // 内核配置（主进程下发；落盘回退）
  private kernelConfig: string = '';
  private appliedConfig: string = '';
  // 扩展进程心跳 / 自愈
  private hbTimer: number = -1;
  private hbCount: number = 0;
  private kernelFails: number = 0;
  private healing: boolean = false;
  // 内核日志流（断线自动重连）
  private klogRetry: number = -1;
  private klogSeq: number = 0;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'vpn onCreate, pid=%{public}d', process.pid);
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'vpn onDestroy, pid=%{public}d hbCount=%{public}d',
      process.pid, this.hbCount);
    this.stopHeartbeat();
    this.teardown();
  }

  /** start 语义建链入口（系统授权前后均可能回调；授权前 create 失败 → 重试） */
  onRequest(want: Want, startId: number): void {
    hilog.info(DOMAIN, TAG, 'vpn onRequest, startId=%{public}d', startId);
    this.captureConfig(want);
    if (this.isUp) {
      // 已在运行：仅当配置变更时热重载（重建连接与内核）
      if (this.kernelConfig !== '' && this.kernelConfig !== this.appliedConfig) {
        hilog.info(DOMAIN, TAG, 'config changed while up → reload (rebuild)');
        this.selfHeal('配置变更');
      }
      return;
    }
    this.tryCreate(0);
  }

  // ---------------------------------------------------------------- 配置下发

  private captureConfig(want: Want): void {
    const params = want.parameters;
    if (params !== undefined) {
      const raw = params[CONFIG_KEY];
      if (typeof raw === 'string' && raw !== '') {
        this.kernelConfig = raw;
        this.persistConfig(raw);
        hilog.info(DOMAIN, TAG, 'kernel config from want, len=%{public}d', raw.length);
        return;
      }
    }
    if (this.kernelConfig === '') {
      const fromFile = readText(`${this.context.filesDir}/${BIND_HOME}/${KERNEL_CONFIG_FILE}`);
      if (fromFile !== '') {
        this.kernelConfig = fromFile;
        hilog.info(DOMAIN, TAG, 'kernel config from file fallback, len=%{public}d', fromFile.length);
      }
    }
  }

  private persistConfig(cfg: string): void {
    const dir = `${this.context.filesDir}/${BIND_HOME}`;
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      // 目录已存在时也会抛错，忽略（下同）
    }
    try {
      writeText(`${dir}/${KERNEL_CONFIG_FILE}`, cfg);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'persist config 失败 code=%{public}d', (e as BusinessError).code);
    }
  }

  /** 注入进程相关字段（log-file / interface-name）后的最终配置 */
  private effectiveConfig(ifName: string): string {
    const base = this.kernelConfig !== '' ? this.kernelConfig : buildKernelConfig(null, EXT_MIXED_PORT, 'info');
    const home = `${this.context.filesDir}/${BIND_HOME}`;
    const inject = `"log-file":${JSON.stringify(home + '/clash.log')},`
      + (ifName !== '' ? `"interface-name":${JSON.stringify(ifName)},` : '');
    const trimmed = base.trim();
    if (trimmed.startsWith('{')) {
      return `{${inject}${trimmed.slice(1)}`;
    }
    return base;
  }

  // ---------------------------------------------------------------- 建链

  private tryCreate(attempt: number): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.isUp) {
      return;
    }
    try {
      const conn: vpnExtension.VpnConnection = vpnExtension.createVpnConnection(this.context);
      this.connection = conn;
      conn.create(this.buildConfig())
        .then((fd: number) => {
          this.isUp = true;
          this.fd = fd;
          hilog.info(DOMAIN, TAG, 'vpn connection created, fd=%{public}d addr=%{public}s route=%{public}s/%{public}d',
            fd, VPN_ADDRESS, VPN_ROUTE_IP, VPN_ROUTE_PREFIX);
          this.startKernelAndAttach(fd);
        })
        .catch((err: BusinessError) => {
          if (err.code === 2203002) {
            // 网卡已存在：上一进程被回收后系统重启本扩展，残留连接还在但 fd 已丢失
            // → destroy + recreate 拿回新 fd，否则内核永远挂不上（隧道黑洞）
            if (attempt < RECOVER_RETRY) {
              hilog.warn(DOMAIN, TAG, 'vpn existed (2203002), recover attempt=%{public}d', attempt);
              const conn2 = this.connection;
              if (conn2 !== null) {
                conn2.destroy()
                  .then(() => {
                    this.retryTimer = setTimeout(() => {
                      this.tryCreate(attempt + 1);
                    }, RETRY_INTERVAL_MS);
                  })
                  .catch((e2: BusinessError) => {
                    this.isUp = true;
                    hilog.error(DOMAIN, TAG, 'destroy residual failed code=%{public}d（内核未挂）', e2.code);
                  });
              }
            } else {
              this.isUp = true;
              hilog.warn(DOMAIN, TAG, 'vpn already up, no fd → kernel not attached（放弃重建）');
            }
            return;
          }
          if (attempt < MAX_RETRY && err.code === 2200002) {
            this.retryTimer = setTimeout(() => {
              this.tryCreate(attempt + 1);
            }, RETRY_INTERVAL_MS);
          } else {
            hilog.error(DOMAIN, TAG, 'vpn create failed, code=%{public}d msg=%{public}s', err.code, err.message);
          }
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'createVpnConnection exception, code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  private buildConfig(): vpnExtension.VpnConfig {
    return {
      vpnId: 'arkhon-t1',
      addresses: [
        { address: { family: 1, address: VPN_ADDRESS }, prefixLength: 32 },
        { address: { family: 2, address: 'fdfe:dcba:9876::2' }, prefixLength: 126 }
      ],
      routes: [
        {
          interface: '',
          destination: { address: { family: 1, address: VPN_ROUTE_IP }, prefixLength: VPN_ROUTE_PREFIX },
          gateway: { family: 1, address: '0.0.0.0' },
          hasGateway: false,
          isDefaultRoute: true
        },
        {
          interface: '',
          destination: { address: { family: 2, address: '::' }, prefixLength: 0 },
          gateway: { family: 2, address: '::' },
          hasGateway: false,
          isDefaultRoute: true
        }
      ],
      dnsAddresses: ['8.8.8.8', '223.5.5.5'],
      blockedApplications: [],
    };
  }

  // ---------------------------------------------------------------- 内核实载

  /** 探测物理承载网卡（Wi-Fi > 以太 > 蜂窝，跳过 VPN）→ 起内核 → attach 隧道 fd */
  private startKernelAndAttach(fd: number): void {
    this.pickPhysicalInterface().then((ifName: string) => {
      this.startKernelWith(fd, ifName);
    });
  }

  private async pickPhysicalInterface(): Promise<string> {
    let wifi = '';
    let eth = '';
    let cell = '';
    try {
      const nets: connection.NetHandle[] = await connection.getAllNets();
      for (const net of nets) {
        try {
          const cap: connection.NetCapabilities = await connection.getNetCapabilities(net);
          if (cap.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
            continue;
          }
          const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
          const name: string = props.interfaceName ?? '';
          if (name === '') {
            continue;
          }
          if (wifi === '' && cap.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
            wifi = name;
          } else if (eth === '' && cap.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) {
            eth = name;
          } else if (cell === '' && cap.bearerTypes.includes(connection.NetBearType.BEARER_CELLULAR)) {
            cell = name;
          }
        } catch (e) {
          // 单个 net 查询失败跳过
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'pickPhysicalInterface 失败 code=%{public}d', err.code);
    }
    const picked = wifi !== '' ? wifi : (eth !== '' ? eth : cell);
    hilog.info(DOMAIN, TAG, 'physical-if picked="%{public}s" (wifi="%{public}s" eth="%{public}s" cell="%{public}s")',
      picked, wifi, eth, cell);
    return picked;
  }

  private startKernelWith(fd: number, ifName: string): void {
    try {
      const home = `${this.context.filesDir}/${BIND_HOME}`;
      try {
        fs.mkdirSync(home, true);
      } catch (e2) {
        // 目录已存在：忽略
      }
      const ver: ClashVersionResult = goNative.clashVersion();
      hilog.info(DOMAIN, TAG, 'ext kernel loaded=%{public}d version=%{public}s',
        ver.loaded ? 1 : 0, ver.version ?? '');
      if (!ver.loaded) {
        return;
      }
      const cfg = this.effectiveConfig(ifName);
      hilog.info(DOMAIN, TAG, 'ext kernel start cfgLen=%{public}d if=%{public}s', cfg.length, ifName);
      const startRet: ClashStartResult = goNative.clashStart(home, cfg, `127.0.0.1:${EXT_REST_PORT}`);
      hilog.info(DOMAIN, TAG, 'ext kernel start code=%{public}d err=%{public}s',
        startRet.code, startRet.err ?? '');
      if (startRet.code !== 0) {
        return;
      }
      this.appliedConfig = this.kernelConfig;
      const attachRet: ClashAttachResult = goNative.clashAttach(fd);
      hilog.info(DOMAIN, TAG, 'ext kernel attach fd=%{public}d code=%{public}d err=%{public}s',
        fd, attachRet.code, attachRet.err ?? '');
      this.kernelFails = 0;
      this.startHeartbeat();
      // 启动时挂一次内核日志流（REST /logs），运行日志进 hilog 供排障
      this.streamKernelLogs();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'startKernelWith 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  // ---------------------------------------------------------------- 扩展内自愈

  private startHeartbeat(): void {
    if (this.hbTimer >= 0) {
      return;
    }
    this.hbCount = 0;
    this.hbTimer = setInterval(() => {
      this.heartbeat();
    }, HB_INTERVAL_MS);
    hilog.info(DOMAIN, TAG, '[KEEP] ext heartbeat started pid=%{public}d interval=%{public}dms',
      process.pid, HB_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.hbTimer >= 0) {
      clearInterval(this.hbTimer);
      this.hbTimer = -1;
    }
  }

  /** 心跳：探测本进程内核 REST；连续失败 → 扩展内自愈（重建 fd + 内核） */
  private heartbeat(): void {
    this.hbCount++;
    const count = this.hbCount;
    const pid = process.pid;
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request(`http://127.0.0.1:${EXT_REST_PORT}/version`,
        { method: httpRequest.RequestMethod.GET, connectTimeout: 5000, readTimeout: 5000 })
        .then((resp: httpRequest.HttpResponse) => {
          this.kernelFails = 0;
          hilog.info(DOMAIN, TAG, '[KEEP] ext hb #%{public}d pid=%{public}d kernel=OK code=%{public}d',
            count, pid, resp.responseCode);
          httpCfg.destroy();
        })
        .catch((err: BusinessError) => {
          this.kernelFails++;
          hilog.warn(DOMAIN, TAG, '[KEEP] ext hb #%{public}d pid=%{public}d kernel=FAIL(%{public}d) code=%{public}d',
            count, pid, this.kernelFails, err.code);
          httpCfg.destroy();
          if (this.kernelFails >= KERNEL_FAIL_LIMIT) {
            this.selfHeal('内核连续失联');
          }
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'heartbeat 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /**
   * 扩展内自愈：destroy 旧连接 → 重建 fd → 内核重启（clashStart 幂等 stop+start）→ 重新 attach。
   * 与主进程自恢复互补：主进程覆盖「扩展进程被回收」，本方法覆盖「内核异常但进程存活」。
   */
  private selfHeal(reason: string): void {
    if (this.healing) {
      return;
    }
    this.healing = true;
    hilog.warn(DOMAIN, TAG, '[HEAL] triggered: %{public}s', reason);
    this.kernelFails = 0;
    this.stopHeartbeat();
    // 销毁旧连接（含旧 fd）；失败也继续尝试重建
    const conn = this.connection;
    const finish = (): void => {
      this.connection = null;
      this.isUp = false;
      this.fd = -1;
      this.retryTimer = setTimeout(() => {
        this.healing = false;
        this.tryCreate(0);
      }, HEAL_SETTLE_MS);
    };
    if (conn !== null) {
      conn.destroy()
        .then(() => {
          hilog.info(DOMAIN, TAG, '[HEAL] old vpn destroyed, recreate');
          finish();
        })
        .catch((e: BusinessError) => {
          hilog.warn(DOMAIN, TAG, '[HEAL] destroy 失败 code=%{public}d（继续重建）', e.code);
          finish();
        });
    } else {
      finish();
    }
  }

  // ---------------------------------------------------------------- 诊断（日志流）

  /** 挂内核 REST /logs 流（raw TCP 长连接），运行日志透传 hilog：常规行前 240 行 + 错误/告警行持续透传；断线自动重连 */
  private streamKernelLogs(): void {
    if (this.klogRetry >= 0) {
      clearTimeout(this.klogRetry);
      this.klogRetry = -1;
    }
    try {
      const seq = ++this.klogSeq;
      const tcp = socket.constructTCPSocketInstance();
      let buf = '';
      let cap = 0;      // 常规行上限（前 N 行）
      let errCap = 0;   // 错误/告警行上限（后续持续透传，便于定位拨号类问题）
      tcp.on('message', (info: socket.SocketMessageInfo) => {
        const ab = info.message as ArrayBuffer;
        const bytes = new Uint8Array(ab);
        let s = '';
        for (const b of bytes) {
          s += String.fromCharCode(b);
        }
        buf += s;
        let nl = buf.indexOf('\n');
        while (nl >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          // 常规流量行只透传前 KLOG_CAP 行（防刷屏）；错误/告警行始终透传（拨号失败根因靠它）
          const isEvent = line.indexOf('"payload"') >= 0 || line.indexOf('"type"') >= 0;
          const isErr = /error|warn|fail|timeout|deadline|refused|unreachable|EOF/i.test(line);
          if (isEvent && (cap < KLOG_CAP || (isErr && errCap < KLOG_ERR_CAP))) {
            if (cap < KLOG_CAP) {
              cap++;
            } else {
              errCap++;
            }
            hilog.info(DOMAIN, TAG, '[klog] %{public}s', line.slice(0, 400));
          }
          nl = buf.indexOf('\n');
        }
      });
      tcp.on('close', () => {
        hilog.warn(DOMAIN, TAG, 'klog-stream #%{public}d closed → 自动重连', seq);
        this.scheduleKlogReconnect();
      });
      tcp.on('error', (e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'klog-stream #%{public}d 错误 code=%{public}d → 自动重连', seq, e.code);
        this.scheduleKlogReconnect();
      });
      tcp.connect({ address: { address: '127.0.0.1', port: EXT_REST_PORT }, timeout: 5000 }).then(() => {
        hilog.info(DOMAIN, TAG, 'klog-stream #%{public}d subscribed', seq);
        tcp.send({
          data: `GET /logs HTTP/1.1\r\nHost: 127.0.0.1:${EXT_REST_PORT}\r\nConnection: keep-alive\r\n\r\n`
        });
      }).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'klog-stream #%{public}d connect 失败 code=%{public}d', seq, e.code);
        try {
          tcp.close();
        } catch (e2) {
          // ignore
        }
        this.scheduleKlogReconnect();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'streamKernelLogs 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /** 内核日志流断线重连（隧道在线时 2s 后重挂） */
  private scheduleKlogReconnect(): void {
    if (!this.isUp) {
      return;
    }
    if (this.klogRetry >= 0) {
      clearTimeout(this.klogRetry);
    }
    this.klogRetry = setTimeout(() => {
      this.klogRetry = -1;
      this.streamKernelLogs();
    }, KLOG_RETRY_MS);
  }

  private teardown(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.klogRetry >= 0) {
      clearTimeout(this.klogRetry);
      this.klogRetry = -1;
    }
    this.isUp = false;
    try {
      if (this.connection !== null) {
        this.connection.destroy()
          .then(() => {
            hilog.info(DOMAIN, TAG, 'vpn destroyed');
          })
          .catch((err: BusinessError) => {
            hilog.error(DOMAIN, TAG, 'vpn destroy failed, code=%{public}d msg=%{public}s', err.code, err.message);
          });
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'vpn destroy exception, code=%{public}d msg=%{public}s', err.code, err.message);
    } finally {
      this.connection = null;
    }
  }
}

// ---------------------------------------------------------------- 文件工具

function readText(path: string): string {
  try {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const stat = fs.statSync(path);
    if (stat.size <= 0) {
      fs.closeSync(file);
      return '';
    }
    const buf = new ArrayBuffer(stat.size);
    const readLen = fs.readSync(file.fd, buf);
    fs.closeSync(file);
    const view = new Uint8Array(buf.slice(0, readLen));
    return buffer.from(view.buffer as ArrayBuffer, view.byteOffset, view.byteLength).toString('utf-8');
  } catch (e) {
    return '';
  }
}

function writeText(path: string, text: string): void {
  const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, text);
  fs.closeSync(file);
}