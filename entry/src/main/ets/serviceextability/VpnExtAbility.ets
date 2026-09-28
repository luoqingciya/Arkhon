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
 * 注意（D5e 已放开全量）：
 *  - D5e 阶段内核已接入且带上游代理节点，放开默认路由 0.0.0.0/0，
 *    系统真实流量经隧道 fd → 内核代理链 → 上游节点出网；
 *  - T1 骨架期（无内核收包）用受限网段 10.22.0.0/16，防代理黑洞。
 */
import { VpnExtensionAbility, vpnExtension, socket, connection } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import httpRequest from '@ohos.net.http';
import fs from '@ohos.file.fs';
import process from '@ohos.process';
import goNative, { ClashVersionResult, ClashStartResult, ClashAttachResult } from 'libentry.so';

const TAG = 'VpnExtAbility';
const DOMAIN = 0x0000;

// 隧道参数（D5e：放开全量默认路由 0.0.0.0/0，系统真实流量经隧道→内核→上游节点出网）
const VPN_ADDRESS = '10.21.0.2';      // 虚拟网卡本机地址
const VPN_ROUTE_IP = '0.0.0.0';       // 全量默认路由（D5e 已放开；前提 protectProcessNet 已破自捕获回环）
const VPN_ROUTE_PREFIX = 0;
const MAX_RETRY = 20;                  // 授权前 create 的重试上限（≈10s）
const RETRY_INTERVAL_MS = 500;
const RECOVER_RETRY = 2;               // 2203002（残留 VPN 连接）销毁重建尝试上限
const HB_INTERVAL_MS = 60000;          // T3 保活：扩展进程心跳周期（存活取证）

export default class VpnExtAbility extends VpnExtensionAbility {
  private connection: vpnExtension.VpnConnection | null = null;
  private retryTimer: number = -1;
  private isUp: boolean = false;
  // T3 保活：扩展进程心跳（定时器只在进程未被冻结时触发 → 断档即冻结/回收证据）
  private hbTimer: number = -1;
  private hbCount: number = 0;

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'vpn onCreate, pid=%{public}d want=%{public}s',
      process.pid, JSON.stringify(want));
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'vpn onDestroy, pid=%{public}d hbCount=%{public}d',
      process.pid, this.hbCount);
    this.stopHeartbeat();
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
          // D5e 回环验证：暂不调 protectProcessNet。
          // 之前 protectProcessNet 后主进程「隧道出网」流量始终不进 fd（fd-probe 只抓到 MLD），
          // 怀疑 OHOS 的 protectProcessNet 保护整个 bundle 的全部进程（主+扩展），
          // 导致主进程探测被绕过 VPN 直连 → 外网超时。
          // 内核上游拨号回环改由 interface-name(wlan0) 绑定物理网卡防兜回，先行验证主进程流量是否进 fd。
          this.startKernelAndAttach(fd);
        })
        .catch((err: BusinessError) => {
          if (err.code === 2203002) {
            // 网卡已存在。两种来源：
            //  a) 本进程此前已建（isUp 应为 true，正常不会走到这）；
            //  b) 上一进程被系统回收后系统重启本扩展进程，残留连接还在但 fd 已随旧进程丢失
            //     → 必须 destroy + recreate 拿回新 fd，否则内核永远挂不上（隧道黑洞）。
            if (attempt < RECOVER_RETRY) {
              hilog.warn(DOMAIN, TAG, 'vpn existed (2203002), recover destroy+recreate attempt=%{public}d', attempt);
              const conn = this.connection;
              if (conn !== null) {
                conn.destroy()
                  .then(() => {
                    hilog.info(DOMAIN, TAG, 'residual vpn destroyed, recreate');
                    this.retryTimer = setTimeout(() => { this.tryCreate(attempt + 1); }, RETRY_INTERVAL_MS);
                  })
                  .catch((e2: BusinessError) => {
                    this.isUp = true;
                    hilog.error(DOMAIN, TAG, 'destroy residual failed code=%{public}d msg=%{public}s（内核未挂）',
                      e2.code, e2.message);
                  });
              }
            } else {
              this.isUp = true;
              hilog.warn(DOMAIN, TAG, 'vpn already up, no fd → kernel not attached（残留态放弃重建）');
            }
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
    // 平板系统限制：不支持 isDefaultRoute: true（全量默认路由），
    // 需收缩为受限路由（仅接管特定网段），避免系统流量无法进隧道。
    // 检测当前设备类型：通过系统参数或配置判断是否为平板
    const isTablet = this.isTabletDevice();
    if (isTablet) {
      return this.buildTabletConfig();
    }
    return this.buildPhoneConfig();
  }

  private isTabletDevice(): boolean {
    // 通过系统参数判断设备类型（平板/手机）
    // 可通过 deviceInfo 或系统属性判断，这里简化处理：默认手机，平板需显式配置
    return false; // TODO: 实现设备类型检测
  }

  private buildPhoneConfig(): vpnExtension.VpnConfig {
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
          isDefaultRoute: true // 手机支持全量默认路由
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

  private buildTabletConfig(): vpnExtension.VpnConfig {
    return {
      vpnId: 'arkhon-t1',
      addresses: [
        { address: { family: 1, address: VPN_ADDRESS }, prefixLength: 32 },
        { address: { family: 2, address: 'fdfe:dcba:9876::2' }, prefixLength: 126 }
      ],
      routes: [
        {
          interface: '',
          destination: { address: { family: 1, address: '10.22.0.0' }, prefixLength: 16 },
          gateway: { family: 1, address: '0.0.0.0' },
          hasGateway: false,
          isDefaultRoute: false // 平板受限路由：仅接管 10.22.0.0/16 网段
        },
        {
          interface: '',
          destination: { address: { family: 2, address: 'fdfe:dcba:9876::' }, prefixLength: 64 },
          gateway: { family: 2, address: '::' },
          hasGateway: false,
          isDefaultRoute: false
        }
      ],
      dnsAddresses: ['8.8.8.8', '223.5.5.5'],
      blockedApplications: [],
    };
  }

  /**
   * D5e 隧道喂流：在 VPN 扩展进程内起真实内核（libclash.so），注入上游 hysteria2 节点，
   * 再把隧道 fd attach 上去，并放开全量默认路由。
   * fd 是扩展进程私有的句柄，必须与本进程内的内核同进程才能 read/write。
   * 验证「系统流量 → fd → gvisor → 内核 → PROXY(上游 hysteria2 节点) → 出网」全链路闭环。
   *
   * T3 修正：interface-name 不再写死 wlan0（Wi-Fi 断开走蜂窝时，绑定无连通的网卡会让
   * 上游拨号全部 context deadline exceeded）。改为运行时探测当前物理承载网卡。
   */
  private startKernelAndAttach(fd: number): void {
    // 先探测物理承载网卡（Wi-Fi 优先，其次以太/蜂窝，跳过 VPN 自身），再起内核
    this.pickPhysicalInterface().then((ifName: string) => {
      this.startKernelWith(fd, ifName);
    });
  }

  /** 探测当前物理承载网卡名（非 VPN）：Wi-Fi > 以太 > 蜂窝；失败返回空串 */
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
            continue; // 跳过 VPN 自身（否则拨号又兜回 tun）
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
      hilog.warn(DOMAIN, TAG, '[D5e] pickPhysicalInterface 失败 code=%{public}d msg=%{public}s', err.code, err.message);
    }
    const picked = wifi !== '' ? wifi : (eth !== '' ? eth : cell);
    hilog.info(DOMAIN, TAG, '[D5e] physical-if picked="%{public}s" wifi="%{public}s" eth="%{public}s" cell="%{public}s"',
      picked, wifi, eth, cell);
    return picked;
  }

  private startKernelWith(fd: number, ifName: string): void {
    try {
      const ver: ClashVersionResult = goNative.clashVersion();
      hilog.info(DOMAIN, TAG, '[D5] ext kernel loaded=%{public}d version=%{public}s',
        ver.loaded ? 1 : 0, ver.version ?? '');
      if (!ver.loaded) {
        return;
      }
      const home = `${this.context.filesDir}/clash-ext`;   // 扩展进程自身上下文（勿用 getContext）
      hilog.info(DOMAIN, TAG, '[D5e] ext home=%{public}s', home);
      // 确保日志目录存在（内核 log-file 不会自己 mkdir，缺目录则静默丢日志，导致接近抓不到拨号错误）
      try {
        fs.mkdirSync(home, true);
      } catch (e2) {
        hilog.warn(DOMAIN, TAG, 'mkdir clash-ext 失败 code=%{public}d msg=%{public}s',
          (e2 as BusinessError).code, (e2 as BusinessError).message);
      }
      // D5e：注入上游 hysteria2 节点 + 规则走 PROXY 组 → 系统真实流量经 隧道→内核→代理 出网
      // ArkTS 禁止未声明对象字面量，故直接给 JSON 字符串。
      // log-file 用绝对路径（实测 mihomo 不 Join homeDir，相对名落盘失败导致 readKernelLog 报 ENOENT）。
      // 端口避开主进程 T3 内核占用的 9097/1031：扩展内核独用 9096(REST)/1032(mixed)，否则诊断打错内核。
      // interface-name 绑定物理承载网卡：全量路由下上游 UDP(QUIC/hysteria2) 拨号会被默认路由兜回 tun 回环，
      // protectProcessNet 对 UDP 不生效；绑定物理网卡 → 拨号流量直出，彻底绕开 tun。探测不到则省略该字段。
      //
      // TODO(M2)：proxies / proxy-groups / rules 应由「档案（订阅导入）」生成后下发；
      //   D5e 阶段的测试节点与凭据已按 T3 收尾要求移除，当前为无凭据的最简配置（隧道直通）。
      const ifPart = ifName !== '' ? '"interface-name":"' + ifName + '",' : '';
      const cfgStr = '{"mode":"rule","log-level":"debug","log-file":"' + home + '/clash.log",'
        + '"bind-address":"127.0.0.1","mixed-port":1032,'
        // D5e：打开内核 DNS，节点域名走 mihomo 内置 resolver，绕开鸿蒙扩展进程系统 resolver 异常（502 根因嫌疑之一）。
        + '"dns":{"enable":true,"nameserver":["223.5.5.5","8.8.8.8"]},'
        + ifPart
        // 私有/内网段与其余流量暂走直连（无上游节点）；M2 接入档案后改为 MATCH,PROXY。
        + '"rules":["IP-CIDR,192.168.0.0/16,DIRECT","IP-CIDR,10.0.0.0/8,DIRECT","IP-CIDR,172.16.0.0/12,DIRECT","IP-CIDR,127.0.0.0/8,DIRECT","MATCH,DIRECT"]}';
      hilog.info(DOMAIN, TAG, '[D5e] cfgStr=%{public}s', cfgStr);
      const startRet: ClashStartResult = goNative.clashStart(home, cfgStr, '127.0.0.1:9096');
      hilog.info(DOMAIN, TAG, '[D5] ext kernel start code=%{public}d err=%{public}s',
        startRet.code, startRet.err ?? '');
      // attach 隧道 fd：成功则内核 TUN listener 绑定该 fd，系统下发的 IP 包进入内核代理链
      const attachRet: ClashAttachResult = goNative.clashAttach(fd);
      hilog.info(DOMAIN, TAG, '[D5] ext kernel attach fd=%{public}d code=%{public}d err=%{public}s',
        fd, attachRet.code, attachRet.err ?? '');
      // T3 保活：内核就位后启动扩展进程心跳（60s 一次，断档即冻结/回收证据）
      this.startHeartbeat();
      // D5e 真机验证：全量默认路由下，用扩展进程内 @ohos.net.http 发真实请求，
      // 确认系统流量进隧道 fd → 内核 → 上游 hysteria2 节点出网（返回 200 即闭环）
      this.probeThroughTunnel();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5] startKernelAndAttach 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /**
   * T3 扩展进程心跳：每 60s 打一条（含 pid 与本进程内核 REST 自探）。
   * 该定时器只在扩展进程存活且未被冻结时触发 → 心跳断档 = 扩展进程被冻结/回收的直接证据。
   */
  private startHeartbeat(): void {
    if (this.hbTimer >= 0) {
      return;
    }
    this.hbCount = 0;
    this.hbTimer = setInterval(() => { this.heartbeat(); }, HB_INTERVAL_MS);
    hilog.info(DOMAIN, TAG, '[KEEP] ext heartbeat started pid=%{public}d interval=%{public}dms',
      process.pid, HB_INTERVAL_MS);
  }

  private stopHeartbeat(): void {
    if (this.hbTimer >= 0) {
      clearInterval(this.hbTimer);
      this.hbTimer = -1;
    }
  }

  private heartbeat(): void {
    this.hbCount++;
    const count = this.hbCount;
    const pid = process.pid;
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request('http://127.0.0.1:9096/version',
        { method: httpRequest.RequestMethod.GET, connectTimeout: 5000, readTimeout: 5000 })
        .then((resp: httpRequest.HttpResponse) => {
          hilog.info(DOMAIN, TAG, '[KEEP] ext hb #%{public}d pid=%{public}d kernel=OK code=%{public}d',
            count, pid, resp.responseCode);
          httpCfg.destroy();
        })
        .catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, '[KEEP] ext hb #%{public}d pid=%{public}d kernel=FAIL code=%{public}d msg=%{public}s',
            count, pid, err.code, err.message);
          httpCfg.destroy();
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[KEEP] heartbeat 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /**
   * D5e：raw TCP 长连接挂上内核 REST /logs 流（mihomo 会持续输出运行日志），
   * 把 gvisor 入站连接 / 上游拨号错误实时透传进 hilog（clash.log 落盘不可靠时的兜底证据源）。
   */
  private streamKernelLogs(): void {
    try {
      const tcp = socket.constructTCPSocketInstance();
      let buf = '';
      let cap = 0;
      tcp.on('message', (info: socket.SocketMessageInfo) => {
        const ab = info.message as ArrayBuffer;
        const bytes = new Uint8Array(ab);
        let s = '';
        for (const b of bytes) {
          s += String.fromCharCode(b);
        }
        buf += s;
        // /logs 每行一个 JSON 事件；凑齐完整行就拆出来打 hilog（上限 60 行防刷屏）
        let nl = buf.indexOf('\n');
        while (nl >= 0 && cap < 60) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          if (line.length > 2) {
            cap++;
            hilog.info(DOMAIN, TAG, '[D5e] klog %{public}s', line.slice(0, 450));
          }
          nl = buf.indexOf('\n');
        }
      });
      tcp.on('error', (e: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[D5e] klog-stream 错误 code=%{public}d msg=%{public}s', e.code, e.message);
      });
      tcp.connect({ address: { address: '127.0.0.1', port: 9096 }, timeout: 5000 }).then(() => {
        tcp.send({
          data: 'GET /logs HTTP/1.1\r\nHost: 127.0.0.1:9096\r\nConnection: keep-alive\r\n\r\n'
        });
      }).catch((e: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[D5e] klog-stream connect 失败 code=%{public}d msg=%{public}s', e.code, e.message);
        tcp.close();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5e] streamKernelLogs 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /**
   * D5e 隧道内探针：扩展进程自身发起的网络请求会走系统路由进入全量默认路由 → 隧道 fd。
   * 命中 MATCH,PROXY 后经上游 hysteria2 节点出网。
   * 先用 IP 直连目标（免系统 DNS，隔离「数据面」与「DNS」两类问题），再探域名目标。
   */
  private probeThroughTunnel(): void {
    // 先挂上内核 /logs 流（raw TCP 长连接），把 mihomo 运行日志持续透传到 hilog：
    // 能看到 gvisor 入站连接与上游拨号的真实错误（clash.log 落盘路径被 mihomo Join 拼接弄丢，改走 REST 流）。
    this.streamKernelLogs();
    // protectProcessNet 后扩展进程自身 socket 已绕过 tun，只保留「内核→上游 hy2 节点」链路验证。
    // 若此处 200/204 → 节点/配置 OK，回环已破；系统流量经隧道→内核→节点的闭环由主进程探针验证。
    this.probeLoopbackProxy();
    // 查节点拨号错误：内核 REST 延迟测试失败会返回具体 message（定位 mport/obfs/连通性等）
    this.probeNodeDelay();
    // 延迟读内核日志：等 probeNodeDelay 的败 qry + 内核 QUIC 拨号落盘后再 dump，定位真实拨号失败根因
    setTimeout(() => { this.readKernelLog(); }, 3000);
    // D5e：延迟读 fd-probe.txt（Go 侧后台 25s 窗口抢 12 帧首包后落盘），确认哪些流量类型真的进隧道 fd
    setTimeout(() => { this.readFdProbe(); }, 18000);
  }

  /**
   * 读 Go 内核落盘的 fd-probe.txt（隧道 fd 首包 hex），打印到 hilog。
   * 首字节 0x45=纯 IPv4 包（system 栈可解）；0x00/0x02=带地址族头（需换 gvisor fdbased 语义）。
   */
  private readFdProbe(): void {
    try {
      const path = `${this.context.filesDir}/clash-ext/fd-probe.txt`;
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const buffer = new ArrayBuffer(stat.size > 4096 ? 4096 : stat.size);
      const bytesRead = fs.readSync(file.fd, buffer);
      let s = '';
      const bytes = new Uint8Array(buffer);
      for (let i = 0; i < bytesRead; i++) {
        s += String.fromCharCode(bytes[i]);
      }
      hilog.info(DOMAIN, TAG, '[D5e] fd-probe:\n%{public}s', s);
      fs.closeSync(file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '[D5e] readFdProbe 失败 code=%{public}d msg=%{public}s',
        (e as BusinessError).code, (e as BusinessError).message);
    }
  }

  /**
   * 读取内核自己写的 clash.log（log-file 落盘 ∈ 扩展 home），把最近的拨号错误行 dump 到 hilog。
   * 这是定位「内核→上游 hysteria2 节点」失败根因的最硬证据（比 REST delay 的 message 更全）。
   */
  private readKernelLog(): void {
    try {
      const path = `${this.context.filesDir}/clash-ext/clash.log`;
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(path);
      const readLen = stat.size > 8192 ? 8192 : stat.size;
      const buffer = new ArrayBuffer(readLen);
      const bytesRead = fs.readSync(file.fd, buffer);
      let s = '';
      const bytes = new Uint8Array(buffer);
      for (let i = 0; i < bytesRead; i++) {
        s += String.fromCharCode(bytes[i]);
      }
      hilog.info(DOMAIN, TAG, '[D5e] kernel-log tail (%{public}d bytes):\n%{public}s', bytesRead, s);
      fs.closeSync(file);
    } catch (e) {
      hilog.error(DOMAIN, TAG, '[D5e] readKernelLog 失败 code=%{public}d msg=%{public}s',
        (e as BusinessError).code, (e as BusinessError).message);
    }
  }

  /**
   * 扩展进程内 → 自身内核 REST(127.0.0.1:9097) 对上游节点做延迟测试。
   * 成功回 {"delay":..}，失败回 {"message":"具体错误"} → 直接定位拨号失败根因。
   */
  private probeNodeDelay(): void {
    try {
      const httpCfg = httpRequest.createHttp();
      // 直接对具体节点做 delay，并 dump /proxies 列表确认组/节点是否注册进内核。
      // 节点名含空格 → 用 URL 编码 %20。
      const nodeDelay = 'http://127.0.0.1:9096/proxies/Master%20Studio-zz/delay?timeout=8000&url=http://www.gstatic.com/generate_204';
      httpCfg.request('http://127.0.0.1:9096/proxies', {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((resp: httpRequest.HttpResponse) => {
        hilog.info(DOMAIN, TAG, '[D5e] rest /proxies code=%{public}d body=%{public}s',
          resp.responseCode, `${resp.result}`);
        // 对具体节点做延迟测试：返回 {"delay":ms} 即节点连通；返回 {"message":err} 即拨号失败根因
        this.requestDelay(nodeDelay, 'node');
        // 看 mihomo 实际加载的 config（proxies/groups/rules 到底有没有进）与当前 rules
        this.requestConfigs();
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[D5e] rest /proxies 失败 code=%{public}d msg=%{public}s', err.code, err.message);
        httpCfg.destroy();
        this.requestConfigs();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5e] probeNodeDelay 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  /**
   * dump REST 实际 config（确认 proxies/proxy-groups/rules 是否真被内核接纳）
   */
  private requestConfigs(): void {
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request('http://127.0.0.1:9096/configs', {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((resp: httpRequest.HttpResponse) => {
        hilog.info(DOMAIN, TAG, '[D5e] rest /configs code=%{public}d body=%{public}s',
          resp.responseCode, `${resp.result}`);
        httpCfg.destroy();
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[D5e] rest /configs 失败 code=%{public}d msg=%{public}s', err.code, err.message);
        httpCfg.destroy();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5e] requestConfigs 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  private requestDelay(url: string, tag: string): void {
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request(url, {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000
      }).then((resp: httpRequest.HttpResponse) => {
        hilog.info(DOMAIN, TAG, '[D5e] delay(%{public}s) code=%{public}d body=%{public}s',
          tag, resp.responseCode, `${resp.result}`);
        httpCfg.destroy();
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[D5e] delay(%{public}s) 失败 code=%{public}d msg=%{public}s', tag, err.code, err.message);
        httpCfg.destroy();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5e] requestDelay(%{public}s) 异常 code=%{public}d msg=%{public}s', tag, err.code, err.message);
    }
  }

  /**
   * 扩展进程内 → 自身内核混合代理(127.0.0.1:1031) → 上游 hy2 节点 → 出网。
   * 用绝对 URL 形式即 HTTP proxy 语义（同 Index.ets probeProxyHttp）。
   */
  private probeLoopbackProxy(): void {
    try {
      const tcp = socket.constructTCPSocketInstance();
      let buf = '';
      let done = false;
      tcp.on('message', (info: socket.SocketMessageInfo) => {
        const ab = info.message as ArrayBuffer;
        const bytes = new Uint8Array(ab);
        let s = '';
        for (const b of bytes) {
          s += String.fromCharCode(b);
        }
        buf += s;
        if (buf.indexOf('\r\n\r\n') >= 0 && !done) {
          done = true;
          const firstLine = buf.split('\r\n')[0];
          hilog.info(DOMAIN, TAG, '[D5e] loopback-proxy HTTP -> "%{public}s" len=%{public}d',
            firstLine, buf.length);
          tcp.close();
        }
      });
      tcp.on('error', (e: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[D5e] loopback-proxy 错误 code=%{public}d msg=%{public}s', e.code, e.message);
      });
      tcp.connect({ address: { address: '127.0.0.1', port: 1032 }, timeout: 15000 }).then(() => {
        // 目标换 Cloudflare 现网 IP（93.184.216.34 已失效，本机直连也超时）。
        // 绝对 URL = HTTP 代理语义；403/200 任一响应头都证明「内核→节点→公网」往返闭环。
        const req = 'GET http://172.66.147.243/ HTTP/1.1\r\nHost: example.com\r\nUser-Agent: arkhon-d5e\r\nConnection: close\r\n\r\n';
        tcp.send({ data: req });
      }).catch((e: BusinessError) => {
        tcp.close();
        hilog.error(DOMAIN, TAG, '[D5e] loopback-proxy connect 失败 code=%{public}d msg=%{public}s', e.code, e.message);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5e] probeLoopbackProxy 异常 code=%{public}d msg=%{public}s', err.code, err.message);
    }
  }

  private tunnelHttpGet(url: string, tag: string): void {
    try {
      const httpCfg = httpRequest.createHttp();
      httpCfg.request(url, {
        method: httpRequest.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000
      }).then((resp: httpRequest.HttpResponse) => {
        const body = `${resp.result}`;
        hilog.info(DOMAIN, TAG, '[D5e] %{public}s HTTP code=%{public}d head=%{public}s',
          tag, resp.responseCode, body.slice(0, 40).replace(/\n/g, ' '));
        httpCfg.destroy();
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, '[D5e] %{public}s 失败 code=%{public}d msg=%{public}s', tag, err.code, err.message);
        httpCfg.destroy();
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5e] tunnelHttpGet(%{public}s) 异常 code=%{public}d msg=%{public}s', tag, err.code, err.message);
    }
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