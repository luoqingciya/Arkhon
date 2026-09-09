/**
 * T1 · VPN 能力验证页（Phase 0）
 *
 * 操作：点击「启动 VPN」申请授权并拉起 VpnExtAbility（虚拟网卡 + 受限路由 + DNS），
 *       点击「停止 VPN」断开隧道；页面实时展示状态与扩展进程事件日志。
 */
import { Want, childProcessManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import goNative from 'libentry.so';

const DOMAIN = 0x0000;
const TAG = 'T1Page';

interface GoHelloResult {
  loaded: boolean;
  hello: string;
  add: number;
  probe: number;
  err: string;
}

@Entry
@Component
struct Index {
  @State status: string = '未启动';
  @State running: boolean = false;
  @State logs: string[] = [];
  private observer: vpnExtension.VpnObserver | null = null;

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