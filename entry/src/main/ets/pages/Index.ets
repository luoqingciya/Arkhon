/**
 * T1 · VPN 能力验证页（Phase 0）
 *
 * 操作：点击「启动 VPN」申请授权并拉起 VpnExtAbility（虚拟网卡 + 受限路由 + DNS），
 *       点击「停止 VPN」断开隧道；页面实时展示状态与扩展进程事件日志。
 */
import { Want, childProcessManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension } from '@kit.NetworkKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import goNative from 'libentry.so';
import httpRequest from '@ohos.net.http';

const DOMAIN = 0x0000;
const TAG = 'T1Page';

interface GoHelloResult {
  loaded: boolean;
  hello: string;
  add: number;
  probe: number;
  err: string;
}

interface ClashVersionResult {
  loaded: boolean;
  version: string;
  err: string;
}

interface ClashStartResult {
  code: number;
  err: string;
}

@Entry
@Component
struct Index {
  @State status: string = '未启动';
  @State running: boolean = false;
  @State logs: string[] = [];
  private observer: vpnExtension.VpnObserver | null = null;
  private proxyBuf: string = '';
  private proxyDone: boolean = false;

  aboutToAppear(): void {
    // T3 gate-A：原生子进程能力探测
    let ark = 'n/a';
    let native = 'n/a';
    try {
      native = String(childProcessManager.isNativeChildProcessSupported());
    } catch (e) {
      ark = 'err'; // 占位
    }
    try {
      ark = String(childProcessManager.isArkChildProcessSupported());
    } catch (e2) {
      ark = 'err';
    }
    this.pushLog(`[T3] children: ark=${ark} native=${native}`);
    hilog.info(DOMAIN, TAG, 'T3 children ark=%{public}s native=%{public}s', ark, native);
    // T2：启动即触发 Go .so 加载，便于 hilog 采集与验证
    this.runT2();
    // T3 Gate-D：加载并启动真实内核（libclash.so），REST /version 回显即证明内核在跑
    this.runClash();
  }

  build() {
    Column({ space: 16 }) {
      Text('Arkhon · T1 VPN 能力验证')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 32 })

      Text(`状态：${this.status}`)
        .fontSize(16)
        .fontColor(this.running ? '#00c853' : '#f57c00')

      Text('受限路由 10.22.0.0/16（非全量，防黑洞）')
        .fontSize(12)
        .fontColor('#999999')

      Row({ space: 8 }) {
        Button('启动 VPN').onClick(() => {
          if (this.running) {
            this.stopVpn();
          } else {
            this.startVpn();
          }
        })
        Button('加载 Go .so (T2)').onClick(() => {
          this.runT2();
        })
        Button('内核启动 (T3)').onClick(() => {
          this.runClash();
        })
      }

      List({ space: 4 }) {
        ForEach(this.logs, (line: string, idx: number) => {
          ListItem() {
            Text(line)
              .fontSize(12)
              .fontColor(idx === 0 ? '#00c853' : '#aaaaaa')
              .width('100%')
          }
        }, (line: string) => line)
      }
      .layoutWeight(1)
      .width('92%')
      .border({ width: 1, color: '#333' })
      .borderRadius(8)
      .padding(8)
    }
    .width('100%')
    .height('100%')
  }

  private startVpn(): void {
    try {
      // API 26：监听授权弹窗结果（点「允许/拒绝」回调）
      if (this.observer === null) {
        this.observer = vpnExtension.createVpnObserver();
        this.observer.onAuthorizationResult((granted: boolean) => {
          if (granted) {
            this.setRunning(true);
            this.pushLog('[UI] 系统授权通过，等待建链');
          } else {
            this.setRunning(false);
            this.pushLog('[UI] 用户拒绝了授权');
          }
        });
      }
      // 该 SDK 的 startVpnExtensionAbility 单参且为 Want（目标扩展描述）
      const want: Want = {
        bundleName: 'cn.luoqingciya.arkhon',
        abilityName: 'VpnExtAbility',
      };
      vpnExtension.startVpnExtensionAbility(want)
        .then(() => {
          this.pushLog('[UI] startVpnExtensionAbility ok（等待系统授权…）');
        })
        .catch((err: BusinessError) => {
          this.fail(`startVpnExtensionAbility 失败 code=${err.code} msg=${err.message}`);
        });
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`startVpnExtensionAbility 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private stopVpn(): void {
    try {
      const want: Want = {
        bundleName: 'cn.luoqingciya.arkhon',
        abilityName: 'VpnExtAbility',
      };
      vpnExtension.stopVpnExtensionAbility(want)
        .then(() => {
          this.status = '未启动';
          this.running = false;
          this.pushLog('[UI] stopVpnExtensionAbility ok');
        })
        .catch((err: BusinessError) => {
          this.fail(`stopVpnExtensionAbility 失败 code=${err.code} msg=${err.message}`);
        });
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`stopVpnExtensionAbility 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private setRunning(v: boolean): void {
    this.running = v;
    this.status = v ? '已连接' : '未启动';
  }

  private runT2(): void {
    try {
      const raw = goNative.loadGoHello() as Record<string, Object>;
      const r: GoHelloResult = {
        loaded: raw.loaded as boolean,
        hello: raw.hello as string,
        add: raw.add as number,
        probe: raw.probe as number,
        err: (raw.err as string) ?? '',
      };
      this.pushLog(`[T2] loaded=${r.loaded} hello="${r.hello}" add=${r.add} probe=${r.probe} err="${r.err}"`);
      hilog.info(DOMAIN, TAG, 'T2 loaded=%{public}d hello=%{public}s add=%{public}d probe=%{public}d err=%{public}s',
        r.loaded ? 1 : 0, r.hello, r.add, r.probe, r.err);
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`[T2] loadGoHello 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private runClash(): void {
    try {
      const ver = goNative.clashVersion() as Record<string, Object>;
      const v: ClashVersionResult = {
        loaded: ver.loaded as boolean,
        version: (ver.version as string) ?? '',
        err: (ver.err as string) ?? '',
      };
      this.pushLog(`[T3] kernel loaded=${v.loaded} version="${v.version}" err="${v.err}"`);
      hilog.info(DOMAIN, TAG, 'T3 kernel loaded=%{public}d version=%{public}s err=%{public}s',
        v.loaded ? 1 : 0, v.version, v.err);
      if (!v.loaded) {
        return;
      }
      // 最小内核配置：loopback 混合代理 + REST controller（ArkTS 禁止未声明对象字面量，直接给字符串）
      const cfg = '{"mode":"rule","log-level":"debug","bind-address":"127.0.0.1","mixed-port":1031,"dns":{"enable":false}}';
      const ctx = getContext(this) as common.UIAbilityContext;
      const home = `${ctx.filesDir}/clash`;
      const startRet = goNative.clashStart(home, cfg, '127.0.0.1:9097') as Record<string, Object>;
      const s: ClashStartResult = {
        code: startRet.code as number,
        err: (startRet.err as string) ?? '',
      };
      this.pushLog(`[T3] kernel start code=${s.code} err="${s.err}"`);
      hilog.info(DOMAIN, TAG, 'T3 kernel start code=%{public}d err=%{public}s', s.code, s.err);
      if (s.code === 0) {
        this.probeKernelRest();
        this.probeProxyHttp();
      }
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`[T3] runClash 异常 code=${err.code} msg=${err.message}`);
    }
  }

  // REST /version 回显 == 真内核已在跑（signal of liveness）
  private probeKernelRest(): void {
    const httpCfg = httpRequest.createHttp();
    httpCfg.request('http://127.0.0.1:9097/version',
      { method: httpRequest.RequestMethod.GET, connectTimeout: 5000, readTimeout: 5000 })
      .then((resp: httpRequest.HttpResponse) => {
        const body = `${resp.result}`;
        this.pushLog(`[T3] REST /version -> ${body}`);
        hilog.info(DOMAIN, TAG, 'T3 REST /version %{public}s', body);
        httpCfg.destroy();
      })
      .catch((err: BusinessError) => {
        this.fail(`[T3] REST /version 失败 code=${err.code} msg=${err.message}`);
        httpCfg.destroy();
      });
  }

  // 数据面验证：经内核混合代理(127.0.0.1:1031)发真实 HTTP 请求。绝对 URL 形式即 HTTP proxy。
  private probeProxyHttp(): void {
    try {
      const tcp = socket.constructTCPSocketInstance();
      this.proxyBuf = '';
      this.proxyDone = false;
      tcp.on('message', (info: socket.SocketMessageInfo) => {
        const ab = info.message as ArrayBuffer;
        const bytes = new Uint8Array(ab);
        let s = '';
        for (const b of bytes) {
          s += String.fromCharCode(b);
        }
        this.proxyBuf += s;
        if (this.proxyBuf.indexOf('\r\n\r\n') >= 0 && !this.proxyDone) {
          this.proxyDone = true;
          const firstLine = this.proxyBuf.split('\r\n')[0];
          this.pushLog(`[T3] proxy HTTP -> "${firstLine}" len=${this.proxyBuf.length}`);
          hilog.info(DOMAIN, TAG, 'T3 proxy HTTP first=%{public}s len=%{public}d', firstLine, this.proxyBuf.length);
          tcp.close();
        }
      });
      tcp.on('error', (e: BusinessError) => {
        this.fail(`[T3] proxy HTTP 错误 code=${e.code} msg=${e.message}`);
      });
      tcp.connect({ address: { address: '127.0.0.1', port: 1031 }, timeout: 5000 }).then(() => {
        const req = 'GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nUser-Agent: arkhon-t3\r\nConnection: close\r\n\r\n';
        tcp.send({ data: req });
      }).catch((e: BusinessError) => {
        tcp.close();
        this.fail(`[T3] proxy connect 失败 code=${e.code} msg=${e.message}`);
      });
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`[T3] probeProxyHttp 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private pushLog(line: string): void {
    this.logs.unshift(`[${new Date().toLocaleTimeString()}] ${line}`);
    if (this.logs.length > 30) {
      this.logs.pop();
    }
  }

  private fail(msg: string): void {
    this.setRunning(false);
    this.status = '失败';
    this.pushLog(msg);
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }
}