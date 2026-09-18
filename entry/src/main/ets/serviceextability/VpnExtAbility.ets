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
import { VpnExtensionAbility, vpnExtension, socket } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import httpRequest from '@ohos.net.http';
import fs from '@ohos.file.fs';
import goNative from 'libentry.so';

const TAG = 'VpnExtAbility';
const DOMAIN = 0x0000;

// 隧道参数（D5e：放开全量默认路由 0.0.0.0/0，系统真实流量经隧道→内核→上游节点出网）
const VPN_ADDRESS = '10.21.0.2';      // 虚拟网卡本机地址
const VPN_ROUTE_IP = '0.0.0.0';       // 全量默认路由（D5e 已放开；前提 protectProcessNet 已破自捕获回环）
const VPN_ROUTE_PREFIX = 0;
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
          // D5e 回环验证：暂不调 protectProcessNet。
          // 之前 protectProcessNet 后主进程「隧道出网」流量始终不进 fd（fd-probe 只抓到 MLD），
          // 怀疑 OHOS 的 protectProcessNet 保护整个 bundle 的全部进程（主+扩展），
          // 导致主进程探测被绕过 VPN 直连 → 外网超时。
          // 内核上游拨号回环改由 interface-name(wlan0) 绑定物理网卡防兜回，先行验证主进程流量是否进 fd。
          this.startKernelAndAttach(fd);
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
   */
  private startKernelAndAttach(fd: number): void {
    try {
      const ver = goNative.clashVersion() as Record<string, Object>;
      hilog.info(DOMAIN, TAG, '[D5] ext kernel loaded=%{public}d version=%{public}s',
        (ver.loaded as boolean) ? 1 : 0, String(ver.version ?? ''));
      if (!(ver.loaded as boolean)) {
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
      const cfgStr = '{"mode":"rule","log-level":"debug","log-file":"' + home + '/clash.log",'
        + '"bind-address":"127.0.0.1","mixed-port":1032,'
        // D5e：打开内核 DNS，节点域名走 mihomo 内置 resolver，绕开鸿蒙扩展进程系统 resolver 异常（502 根因嫌疑之一）。
        + '"dns":{"enable":true,"nameserver":["223.5.5.5","8.8.8.8"]},'
        // D5e：interface-name 强制上游拨号 socket 绑定物理网卡 wlan0。
        // 全量路由下 UPN(QUIC/hysteria2) 的 UDP 拨号会被默认路由兜回 tun↺回环，protectProcessNet 对 UDP 不生效；
        // 绑定网卡 → 拨号流量直出 wlan0，彻底绕开 tun（等效"对内核的 UDP 也 protect"）。
        + '"interface-name":"wlan0",'
        // D5e 诊断：先不传 mport（mihomo 可能不认该字段致节点建建失败）。
        // 若去掉后 /proxies 出现 Master Studio-zz 且 delay 有 ms → 问题就是 mport；
        // 若仍只有默认组 → 是 cfgStr 整体没被 mihomo 采纳（hub.Parse 传参问题）。
        + '"proxies":[{"name":"Master Studio-zz","type":"hysteria2","server":"70.39.183.3","port":29862,'
        + '"password":"7my4428n85v3619a","alpn":["h3"],"client-fingerprint":"chrome","obfs":"salamander",'
        + '"obfs-password":"2nrn7qtujssuynyf","sni":"device.yyyyyyz.site"}],'
        + '"proxy-groups":[{"name":"PROXY","type":"select","proxies":["Master Studio-zz","DIRECT"]}],'
        // D5e：私有/内网段 DNS 与局域网流量直连（否则系统 DNS 查询被 MATCH,PROXY 丢去远端节点导致解析失败）；
        // 对外流量才走 PROXY 组 → hy2 节点出网。
        + '"rules":["IP-CIDR,192.168.0.0/16,DIRECT","IP-CIDR,10.0.0.0/8,DIRECT","IP-CIDR,172.16.0.0/12,DIRECT","IP-CIDR,127.0.0.0/8,DIRECT","MATCH,PROXY"]}';
      hilog.info(DOMAIN, TAG, '[D5e] cfgStr=%{public}s', cfgStr);
      const startRet = goNative.clashStart(home, cfgStr, '127.0.0.1:9096') as Record<string, Object>;
      hilog.info(DOMAIN, TAG, '[D5] ext kernel start code=%{public}d err=%{public}s',
        startRet.code as number, String(startRet.err ?? ''));
      // attach 隧道 fd：成功则内核 TUN listener 绑定该 fd，系统下发的 IP 包进入内核代理链
      const attachRet = goNative.clashAttach(fd) as Record<string, Object>;
      hilog.info(DOMAIN, TAG, '[D5] ext kernel attach fd=%{public}d code=%{public}d err=%{public}s',
        fd, attachRet.code as number, String(attachRet.err ?? ''));
      // D5e 真机验证：全量默认路由下，用扩展进程内 @ohos.net.http 发真实请求，
      // 确认系统流量进隧道 fd → 内核 → 上游 hysteria2 节点出网（返回 200 即闭环）
      this.probeThroughTunnel();
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[D5] startKernelAndAttach 异常 code=%{public}d msg=%{public}s', err.code, err.message);
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