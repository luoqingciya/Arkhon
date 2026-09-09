/**
 * T1 · VpnExtensionAbility 最小建链骨架（Phase 0 验证用）
 *
 * 依据 SDK 实测（API 26 @ohos.net.vpnExtension / @ohos.app.ability.VpnExtensionAbility）：
 *  - VpnExtensionAbility 只有 onCreate/onDestroy 两个显式回调；
 *  - startVpnExtensionAbility 是「启动(service/start 语义)」→ 系统回调 onRequest（非 onConnect）；
 *  - VpnExtensionContext 由 this.context 提供（Base 类 context 属性）；
 *  - vpnExtension.createVpnConnection(context) 为模块级方法，create() 返回虚拟网卡 fd；
 *  - 授权弹窗出现后用户点「允许」才真正放行，create 可能先于授权被调 → 需重试兜底。
 *
 * 注意（T1 刻意收紧，防代理黑洞）：
 *  - 路由用受限网段 10.22.0.0/16，不放全量（此时无内核收包，全量会断网）；
 *  - 真实内核接入后（T3）再放开全量路由 + DNS 内核接管。
 */
import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'VpnExtAbility';
const DOMAIN = 0x0000;

// 最小验证用隧道参数（真实实现随内核选型替换）
const VPN_ADDRESS = '10.21.0.2';      // 虚拟网卡本机地址
const VPN_ROUTE_IP = '10.22.0.0';     // 受限探测段（勿放开全量）
const VPN_ROUTE_PREFIX = 16;
const MAX_RETRY = 20;                  // 授权前 create 的重试上限（≈10s）
const RETRY_INTERVAL_MS = 500;

export default class VpnExtAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | null = null;
  private retryTimer: number = -1;
  private isUp: boolean = false;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'vpn onCreate, want=%{public}s', JSON.stringify(want));
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'vpn onDestroy');
    this.teardown();
  }

  /**
   * start 语义建链入口：系统启动 VPN 扩展进程后回调。
   * 用户授权(弹窗点允许)前后都可能走到这里，create 授权前会失败 → 重试。
   */
  onRequest(want: Want, startId: number): void {
    hilog.info(DOMAIN, TAG, 'vpn onRequest, startId=%{public}d', startId);
    this.tryCreate(0);
  }

  private tryCreate(attempt: number): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.isUp) {
      return; // 网卡已建立，重复 onRequest 幂等跳过
    }
    try {
      const conn: vpnExtension.VpnConnection = vpnExtension.createVpnConnection(this.context);
      this.connection = conn;
      conn.create(this.buildConfig())
        .then((fd: number) => {
          this.isUp = true;
          hilog.info(DOMAIN, TAG, 'vpn connection created, fd=%{public}d addr=%{public}s route=%{public}s/%{public}d',
            fd, VPN_ADDRESS, VPN_ROUTE_IP, VPN_ROUTE_PREFIX);
        })
        .catch((err: BusinessError) => {
          if (err.code === 2203002) {
            // 网卡已存在（此前已建或重试已建）：视为成功，幂等处理
            this.isUp = true;
            hilog.info(DOMAIN, TAG, 'vpn already up（虚拟网卡已建立）');
            return;
          }
          if (attempt < MAX_RETRY && err.code === 2200002) {
            // 授权未放行 / 服务未就绪：稍后重试
            hilog.warn(DOMAIN, TAG, 'create not ready, code=%{public}d retry=%{public}d', err.code, attempt);
            this.retryTimer = setTimeout(() => { this.tryCreate(attempt + 1); }, RETRY_INTERVAL_MS);
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
        { address: { family: 1, address: VPN_ADDRESS }, prefixLength: 32 }
      ],
      routes: [
        {
          interface: '',
          destination: { address: { family: 1, address: VPN_ROUTE_IP }, prefixLength: VPN_ROUTE_PREFIX },
          gateway: { family: 1, address: '0.0.0.0' },
          hasGateway: false,
          isDefaultRoute: false
        }
      ],
      dnsAddresses: ['8.8.8.8', '223.5.5.5'],
    };
  }

  private teardown(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.isUp = false;
    try {
      if (this.connection !== null) {
        this.connection.destroy()
          .then(() => { hilog.info(DOMAIN, TAG, 'vpn destroyed'); })
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