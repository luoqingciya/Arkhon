/**
 * T1 · VPN 能力验证页（Phase 0）
 *
 * 操作：点击「启动 VPN」申请授权并拉起 VpnExtAbility（虚拟网卡 + 受限路由 + DNS），
 *       点击「停止 VPN」断开隧道；页面实时展示状态与扩展进程事件日志。
 *
 * T3 保活基线（本轮）：VPN 启动即申请 dataTransfer 长时任务（系统挂常驻通知），
 *       主进程每 30s 自检「长时任务 / VPN 网络 / 扩展内核 REST / 隧道出网」，
 *       发现隧道丢失即触发 stop→start 自动重建（自恢复），全部信号写 hilog 供取证。
 */
import { Want, childProcessManager, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vpnExtension } from '@kit.NetworkKit';
import { socket } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import goNative, { GoHelloResult, ClashVersionResult, ClashStartResult } from 'libentry.so';
import httpRequest from '@ohos.net.http';
import process from '@ohos.process';
import { KeepAlive } from '../common/KeepAlive';
import { AudioKeepAlive } from '../common/AudioKeepAlive';

const DOMAIN = 0x0000;
const TAG = 'T1Page';
const MONITOR_INTERVAL_MS = 30000;   // 主进程自检周期
const MONITOR_EGRESS_EVERY = 6;      // 每 N 次自检做一次隧道出网实测（约 3 分钟）
const MONITOR_REFRESH_EVERY = 8;     // 每 N 次自检刷新一次长时任务（约 4 分钟，对抗 >10min 未更新即取消）
const MONITOR_GRACE_MS = 90000;      // 建链宽限期：期间不做回收判定（网卡创建需要时间）
const VPN_MISS_LIMIT = 2;            // VPN 网络连续丢失次数阈值（30s × 2）
const RECOVER_COOLDOWN_MS = 60000;   // 自动重建冷却，避免抖动风暴
const EXT_KERNEL_FAIL_LIMIT = 3;     // 扩展内核 REST 连续失败阈值

@Entry
@Component
struct Index {
  @State status: string = '未启动';
  @State running: boolean = false;
  @State logs: string[] = [];
  @State keepInfo: string = '保活未启动';
  @State audioKeepOn: boolean = false;
  private observer: vpnExtension.VpnObserver | null = null;
  private proxyBuf: string = '';
  private proxyDone: boolean = false;
  // T3 保活：自检/自恢复状态
  private monTimer: number = -1;
  private monTick: number = 0;
  private extKernelFails: number = 0;
  private vpnMissCount: number = 0;
  private graceUntil: number = 0;
  private lastRecoverAt: number = 0;
  private lastKeepRetryAt: number = 0;

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
    // T3 保活：主进程 pid（与扩展进程对照，回收取证用）+ 注册长时任务回收信号监听
    hilog.info(DOMAIN, TAG, '[KEEP] main pid=%{public}d', process.pid);
    this.pushLog(`[KEEP] main pid=${process.pid}`);
    KeepAlive.watch((line: string) => {
      this.pushLog(line);
      // 实验 3 结论：取消/挂起事件在进程被冻结前送达 → 立刻重申请，抢在冻结前恢复"长时任务豁免"
      if (line.indexOf('长时任务被取消') >= 0 || line.indexOf('长时任务挂起') >= 0) {
        this.reArmKeepAlive('系统回收长时任务');
      }
    });
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

      Text('全量默认路由 0.0.0.0/0（系统流量→隧道→内核→上游节点出网）')
        .fontSize(12)
        .fontColor('#999999')

      Text(this.keepInfo)
        .fontSize(12)
        .fontColor('#7e9cff')

      Flex({ wrap: FlexWrap.Wrap }) {
        Button('启动 VPN').onClick(() => {
          if (this.running) {
            this.stopVpn();
          } else {
            this.startVpn();
          }
        }).margin({ right: 8, bottom: 8 })
        Button('加载 Go .so (T2)').onClick(() => {
          this.runT2();
        }).margin({ right: 8, bottom: 8 })
        Button('内核启动 (T3)').onClick(() => {
          this.runClash();
        }).margin({ right: 8, bottom: 8 })
        Button('隧道出网').onClick(() => {
          this.probeTunnelVpn();
        }).margin({ right: 8, bottom: 8 })
        Button('保活自检').onClick(() => {
          this.monitorOnce();
        }).margin({ right: 8, bottom: 8 })
        Button(this.audioKeepOn ? '深度保活: 开' : '深度保活: 关').onClick(() => {
          this.toggleAudioKeepAlive();
        })
      }
      .width('92%')

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
      // 部分设备（如平板）可能不支持 createVpnObserver，需容错处理
      if (this.observer === null && typeof vpnExtension.createVpnObserver === 'function') {
        try {
          this.observer = vpnExtension.createVpnObserver();
          this.observer.onAuthorizationResult((granted: boolean) => {
            if (granted) {
              this.setRunning(true);
              this.pushLog('[UI] 系统授权通过，等待建链');
              this.startKeepAlive();
              // D5e 关键：OHOS 三方 VPN 建链后系统不自动把应用流量切到 VPN 网络，
              // fd-probe 证实主进程流量从未进隧道 → 需要把主进程显式 setAppNet 绑到 VPN 网络。
              this.bindVpnNet(0);
            } else {
              this.setRunning(false);
              this.pushLog('[UI] 用户拒绝了授权');
            }
          });
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'createVpnObserver not supported, skip auth observer');
        }
      }
      // 该 SDK 的 startVpnExtensionAbility 单参且为 Want（目标扩展描述）
      const want: Want = {
        bundleName: 'cn.luoqingciya.arkhon',
        abilityName: 'VpnExtAbility',
      };
      vpnExtension.startVpnExtensionAbility(want)
        .then(() => {
          this.pushLog('[UI] startVpnExtensionAbility ok（等待系统授权…）');
          // 授权回调可能先于 VPN 网络注册，这里也兜底轮询绑定
          this.bindVpnNet(0);
        })
        .catch((err: BusinessError) => {
          this.fail(`startVpnExtensionAbility 失败 code=${err.code} msg=${err.message}`);
        });
    } catch (e) {
      const err = e as BusinessError;
      this.fail(`startVpnExtensionAbility 异常 code=${err.code} msg=${err.message}`);
    }
  }

  // 轮询找到 BEARER_VPN 网络并 setAppNet 绑定主进程（最多 30 次 × 1s）
  private bindVpnNet(tries: number): void {
    if (tries > 30) {
      this.pushLog('[D5e] 30s 内未发现 VPN 网络，放弃绑定');
      return;
    }
    connection.getAllNets().then((nets: connection.NetHandle[]) => {
      let found = false;
      const scan = (i: number): void => {
        if (found || i >= nets.length) {
          if (!found) {
            hilog.warn(DOMAIN, TAG, 'D5e no VPN net in %{public}d nets, retry=%{public}d', nets.length, tries);
            setTimeout(() => { this.bindVpnNet(tries + 1); }, 1000);
          }
          return;
        }
        connection.getNetCapabilities(nets[i]).then((cap: connection.NetCapabilities) => {
          if (cap.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
            found = true;
            const vpnId = nets[i].netId;
            connection.setAppNet(nets[i]).then(() => {
              this.pushLog(`[D5e] 主进程已绑定 VPN 网络 netId=${vpnId}`);
              hilog.info(DOMAIN, TAG, 'D5e setAppNet ok netId=%{public}d', vpnId);
              // 系统已记住授权时 onAuthorizationResult 可能不触发（不再弹窗）：
              // VPN 网络出现本身就是「授权已通过 + 隧道已建」的可靠信号 → 兜底置运行态并启动保活
              if (!this.running) {
                this.setRunning(true);
                this.startKeepAlive();
                this.pushLog('[KEEP] VPN 网络出现，兜底置为已连接并启动保活');
              }
              // 绑定成功后主动跑一次隧道出网闭环验证
              this.probeTunnelVpn();
            }).catch((e: BusinessError) => {
              this.warnLog(`[D5e] setAppNet 失败 code=${e.code} msg=${e.message}`);
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
      hilog.warn(DOMAIN, TAG, 'D5e getAllNets 失败 code=%{public}d retry=%{public}d', e.code, tries);
      setTimeout(() => { this.bindVpnNet(tries + 1); }, 1000);
    });
  }

  private stopVpn(): void {
    try {
      const want: Want = {
        bundleName: 'cn.luoqingciya.arkhon',
        abilityName: 'VpnExtAbility',
      };
      vpnExtension.stopVpnExtensionAbility(want)
        .then(() => {
          this.setRunning(false);
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
    if (v) {
      this.startMonitor();
    } else {
      this.stopMonitor();
      this.stopKeepAlive();
      this.keepInfo = '保活未启动';
    }
  }

  // ===== T3 保活基线：长时任务 + 自检 + 自动重建 =====

  private ctx(): common.UIAbilityContext {
    // getContext 已废弃：改走 UIContext.getHostContext（消除 IDE deprecated 告警）
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private startKeepAlive(): void {
    KeepAlive.start(this.ctx()).then((msg: string) => {
      this.keepInfo = msg;
      this.pushLog(`[KEEP] ${msg}`);
      // 立即盘一次任务状态，确认系统已挂上（常驻通知随之出现）
      this.monitorOnce();
    });
  }

  private stopKeepAlive(): void {
    KeepAlive.stop(this.ctx()).then((msg: string) => {
      this.pushLog(`[KEEP] ${msg}`);
    });
  }

  /** 长时任务被系统取消后的重申请（带冷却，避免高频抖动） */
  private reEnsureKeepAlive(): void {
    this.reArmKeepAlive('长时任务已被系统取消');
  }

  /** 即时重申请长时任务（短冷却 5s）：抢在进程被冻结前恢复"长时任务豁免" */
  private reArmKeepAlive(reason: string): void {
    const now = Date.now();
    if (now - this.lastKeepRetryAt < 5000) {
      return;
    }
    this.lastKeepRetryAt = now;
    hilog.warn(DOMAIN, TAG, '[KEEP] re-arm longtask: %{public}s', reason);
    this.pushLog(`[保活] ${reason} → 立即重申请长时任务`);
    KeepAlive.start(this.ctx()).then((msg: string) => {
      this.keepInfo = msg;
      this.pushLog(`[KEEP] ${msg}`);
    });
  }

  private startMonitor(): void {
    if (this.monTimer >= 0) {
      return;
    }
    this.monTick = 0;
    this.extKernelFails = 0;
    this.vpnMissCount = 0;
    this.graceUntil = Date.now() + MONITOR_GRACE_MS;
    this.monTimer = setInterval(() => { this.monitorOnce(); }, MONITOR_INTERVAL_MS);
    this.pushLog(`[保活] 自检已启动（每 ${MONITOR_INTERVAL_MS / 1000}s，宽限 ${MONITOR_GRACE_MS / 1000}s）`);
  }

  private stopMonitor(): void {
    if (this.monTimer >= 0) {
      clearInterval(this.monTimer);
      this.monTimer = -1;
    }
  }

  /**
   * 单次自检：长时任务状态 / VPN 网络存在性 / 扩展内核 REST 可达性；
   * 每 N 次追加一次隧道出网实测。异常信号达阈值触发自动重建。
   */
  private monitorOnce(): void {
    this.monTick++;
    const tick = this.monTick;
    // 1) 长时任务（回收检测一手信号）
    KeepAlive.report(this.ctx()).then((rep: string) => {
      hilog.info(DOMAIN, TAG, '[KEEP] tick#%{public}d %{public}s', tick, rep);
      this.keepInfo = rep;
      this.pushLog(`[保活] #${tick} ${rep}`);
      // 系统取消长时任务（低速/未更新等）时隧道仍在运行 → 重新申请，避免 App 随后被冻结
      if (this.running && KeepAlive.taskCount === 0) {
        this.reEnsureKeepAlive();
      }
    });
    // 2) VPN 网络存在性（宽限期内不判定；连续丢失达阈值才自恢复）
    this.findVpnNetId().then((netId: number) => {
      if (netId < 0) {
        this.vpnMissCount++;
      } else {
        this.vpnMissCount = 0;
      }
      hilog.info(DOMAIN, TAG, '[KEEP] tick#%{public}d vpn-net=%{public}d miss=%{public}d',
        tick, netId, this.vpnMissCount);
      if (netId < 0) {
        this.pushLog(`[保活] #${tick} VPN 网络不存在（第 ${this.vpnMissCount} 次）`);
        if (Date.now() < this.graceUntil) {
          this.pushLog(`[保活] #${tick} 宽限期内，不做回收判定`);
        } else if (this.running && this.vpnMissCount >= VPN_MISS_LIMIT) {
          this.recoverTunnel('VPN 网络连续丢失');
        }
      } else {
        // 3) 扩展内核 REST 可达性（跨进程 loopback；不可达=扩展内核疑似被回收）
        this.probeExtKernel(tick);
      }
    });
    // 4) 周期性隧道出网实测（走隧道→内核→上游节点）
    if (this.running && tick % MONITOR_EGRESS_EVERY === 0) {
      this.monitorEgress(tick);
    }
    // 5) 周期性刷新长时任务（对抗 DATA_TRANSFER「>10min 未更新即取消」）
    if (this.running && tick % MONITOR_REFRESH_EVERY === 0) {
      KeepAlive.refresh(this.ctx()).then((msg: string) => {
        hilog.info(DOMAIN, TAG, '[KEEP] tick#%{public}d refresh: %{public}s', tick, msg);
        this.pushLog(`[保活] #${tick} ${msg}`);
      });
    }
  }

  /** 找 BEARER_VPN 网络的 netId，找不到返回 -1 */
  private async findVpnNetId(): Promise<number> {
    try {
      const nets: connection.NetHandle[] = await connection.getAllNets();
      for (const net of nets) {
        try {
          const cap: connection.NetCapabilities = await connection.getNetCapabilities(net);
          if (cap.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
            return net.netId;
          }
        } catch (e) {
          // 单个 net 查询失败跳过
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, '[KEEP] getAllNets 失败 code=%{public}d', err.code);
    }
    return -1;
  }

  /** 扩展进程内核 REST /version 探测（127.0.0.1:9096，跨进程 loopback） */
  private probeExtKernel(tick: number): void {
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request('http://127.0.0.1:9096/version',
        { method: httpRequest.RequestMethod.GET, connectTimeout: 5000, readTimeout: 5000 })
        .then((resp: httpRequest.HttpResponse) => {
          this.extKernelFails = 0;
          const body = `${resp.result}`;
          hilog.info(DOMAIN, TAG, '[KEEP] tick#%{public}d ext-kernel OK code=%{public}d body=%{public}s',
            tick, resp.responseCode, body);
          this.pushLog(`[保活] #${tick} 扩展内核 OK ${body.slice(0, 40)}`);
          httpCfg.destroy();
        })
        .catch((err: BusinessError) => {
          this.extKernelFails++;
          hilog.error(DOMAIN, TAG, '[KEEP] tick#%{public}d ext-kernel FAIL(%{public}d) code=%{public}d msg=%{public}s',
            tick, this.extKernelFails, err.code, err.message);
          this.pushLog(`[保活] #${tick} 扩展内核失联（第 ${this.extKernelFails} 次）`);
          httpCfg.destroy();
          if (this.running && this.extKernelFails >= EXT_KERNEL_FAIL_LIMIT) {
            this.recoverTunnel('扩展内核连续失联');
          }
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[KEEP] probeExtKernel 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /** 隧道出网实测：主进程 HTTP 走系统 VPN 默认路由 → 隧道 → 扩展内核 → 上游节点。
 *  仅观测，不触发自恢复（隧道是否存活已由 VPN 网络 + 扩展内核 REST 判定；探针失败多为
 *  上游节点/DNS 问题，误杀运行态会造成抖动） */
  private monitorEgress(tick: number): void {
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request('http://example.com/', {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000
      }).then((resp: httpRequest.HttpResponse) => {
        hilog.info(DOMAIN, TAG, '[KEEP] tick#%{public}d tunnel-egress code=%{public}d',
          tick, resp.responseCode);
        this.pushLog(`[保活] #${tick} 隧道出网 code=${resp.responseCode}`);
        httpCfg.destroy();
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[KEEP] tick#%{public}d tunnel-egress FAIL code=%{public}d msg=%{public}s',
          tick, err.code, err.message);
        this.pushLog(`[保活] #${tick} 隧道出网失败 code=${err.code}（仅观测）`);
        httpCfg.destroy();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[KEEP] monitorEgress 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /**
   * T3 保活增强开关：静音音频保活（AUDIO_PLAYBACK + AVSession + 静音流）。
   * 正面对抗主进程后台冻结：AUDIO_PLAYBACK 无「10 分钟不更新」约束，
   * 代价是播控卡片/媒体通知常驻（后续应做成设置项并说明用途）。
   */
  private toggleAudioKeepAlive(): void {
    if (!this.audioKeepOn) {
      this.pushLog('[保活增强] 启动静音音频保活…');
      AudioKeepAlive.start(this.ctx()).then((msg: string) => {
        this.audioKeepOn = AudioKeepAlive.isOn();
        this.pushLog(`[保活增强] ${msg}`);
      });
    } else {
      this.pushLog('[保活增强] 停止静音音频保活…');
      AudioKeepAlive.stop(this.ctx()).then((msg: string) => {
        this.audioKeepOn = AudioKeepAlive.isOn();
        this.pushLog(`[保活增强] ${msg}`);
      });
    }
  }

  /** 自动重建自恢复：stop → start 扩展进程（重建 VPN + 重挂内核），带冷却 */
  private recoverTunnel(reason: string): void {
    const now = Date.now();
    if (now - this.lastRecoverAt < RECOVER_COOLDOWN_MS) {
      return; // 冷却期内不重复触发
    }
    this.lastRecoverAt = now;
    hilog.warn(DOMAIN, TAG, '[KEEP] auto-recover triggered: %{public}s', reason);
    this.pushLog(`[自恢复] 触发重建：${reason}`);
    const want: Want = {
      bundleName: 'cn.luoqingciya.arkhon',
      abilityName: 'VpnExtAbility',
    };
    vpnExtension.stopVpnExtensionAbility(want)
      .then(() => {
        hilog.info(DOMAIN, TAG, '[KEEP] auto-recover: ext stopped, restarting');
        return vpnExtension.startVpnExtensionAbility(want);
      })
      .then(() => {
        this.pushLog('[自恢复] 扩展已重启，重新绑定 VPN 网络');
        this.extKernelFails = 0;
        this.bindVpnNet(0);
      })
      .catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[KEEP] auto-recover failed code=%{public}d msg=%{public}s',
          err.code, err.message);
        this.pushLog(`[自恢复] 失败 code=${err.code} msg=${err.message}`);
      });
  }

  private probeTunnelVpn(): void {
    // D5e 系统流闭环验证：主进程普通 httpRequest → 系统 VPN 默认路由 → 隧道 fd → 扩展内核 → 上游节点。
    // 先走 IP 直连（绕系统 DNS，隔离「数据面」与「DNS」两类问题）：example.com 真实 IP 93.184.216.34。
    // 若 IP 探针 2xx/3xx/4xx（服务端已响应）→ 数据面闭环通，剩 DNS 分支问题；
    // 再探域名 example.com → 数据面 + DNS 全链路验证。
    try {
      this.tunnelIpProbe();
    } catch (e) {
      const err = e as BusinessError;
      this.warnLog(`[D5e] probeTunnelVpn 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private tunnelIpProbe(): void {
    try {
      const httpCfg = httpRequest.createHttp();
      // 目标换 Cloudflare 现网 IP（93.184.216.34 已失效）：Host 头补齐后返回 200；
      // 4xx 也证明数据面往返闭环（只有超时/拒绝才是链路失败）。
      httpCfg.request('http://172.66.147.243/', {
        method: httpRequest.RequestMethod.GET,
        header: { 'Host': 'example.com' },
        connectTimeout: 10000,
        readTimeout: 10000
      }).then((resp: httpRequest.HttpResponse) => {
        const body = `${resp.result}`;
        this.pushLog(`[D5e] 隧道出网(IP) code=${resp.responseCode} head=${body.slice(0, 40).replace(/\n/g, ' ')}`);
        hilog.info(DOMAIN, TAG, 'D5e tunnel-out-ip code=%{public}d len=%{public}d', resp.responseCode, body.length);
        httpCfg.destroy();
        // IP 通了再试域名（走系统 DNS → 隧道）
        this.tunnelDomainProbe();
      }).catch((err: BusinessError) => {
        this.warnLog(`[D5e] 隧道出网(IP) 失败 code=${err.code} msg=${err.message}`);
        httpCfg.destroy();
        this.tunnelDomainProbe();
      });
    } catch (e) {
      const err = e as BusinessError;
      this.warnLog(`[D5e] tunnelIpProbe 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private tunnelDomainProbe(): void {
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request('http://example.com/', {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000
      }).then((resp: httpRequest.HttpResponse) => {
        const body = `${resp.result}`;
        this.pushLog(`[D5e] 隧道出网(域名) code=${resp.responseCode} head=${body.slice(0, 40).replace(/\n/g, ' ')}`);
        hilog.info(DOMAIN, TAG, 'D5e tunnel-out-host code=%{public}d len=%{public}d', resp.responseCode, body.length);
        httpCfg.destroy();
      }).catch((err: BusinessError) => {
        this.warnLog(`[D5e] 隧道出网(域名) 失败 code=${err.code} msg=${err.message}`);
        httpCfg.destroy();
      });
    } catch (e) {
      const err = e as BusinessError;
      this.warnLog(`[D5e] tunnelDomainProbe 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private runT2(): void {
    try {
      const r: GoHelloResult = goNative.loadGoHello();
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
      const v: ClashVersionResult = goNative.clashVersion();
      this.pushLog(`[T3] kernel loaded=${v.loaded} version="${v.version}" err="${v.err}"`);
      hilog.info(DOMAIN, TAG, 'T3 kernel loaded=%{public}d version=%{public}s err=%{public}s',
        v.loaded ? 1 : 0, v.version, v.err);
      if (!v.loaded) {
        return;
      }
      // 最小内核配置：loopback 混合代理 + REST controller（ArkTS 禁止未声明对象字面量，直接给字符串）
      const cfg = '{"mode":"rule","log-level":"debug","bind-address":"127.0.0.1","mixed-port":1031,"dns":{"enable":false}}';
      const ctx = this.ctx();
      const home = `${ctx.filesDir}/clash`;
      const s: ClashStartResult = goNative.clashStart(home, cfg, '127.0.0.1:9097');
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

  /** 观测性日志：只记入列表与 hilog，不翻转运行状态（隧道探针类失败用，避免误杀运行态） */
  private warnLog(line: string): void {
    this.pushLog(line);
    hilog.warn(DOMAIN, TAG, '%{public}s', line);
  }

  private fail(msg: string): void {
    this.setRunning(false);
    this.status = '失败';
    this.pushLog(msg);
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }
}