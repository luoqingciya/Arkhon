/**
 * M2 · 内核配置构建：档案（Profile）→ mihomo 配置 JSON
 *
 * 说明：
 *  - 内核 arkhon_core_start(home, cfg, ctrl) 接受 YAML/JSON 文本，JSON 为 YAML 子集，直接用 JSON 拼装；
 *  - 「进程相关」字段（log-file / interface-name）由扩展进程在启动内核前注入（见 VpnExtAbility）；
 *  - 组与规则对齐桌面端：节点 ≥2 生成 AUTO（url-test，lazy）并置于 PROXY 首位；
 *    规则 = 私网直连前缀 + 分流预设（RulePresets，opt-in）+ MATCH 兜底。
 */
import { Profile, ProxyNode } from '../model/Types';
import { presetRuleLines } from './RulePresets';

/** 默认端口/参数（与扩展进程内核保持一致：ext 内核独立占用 1032/9096） */
export const EXT_MIXED_PORT = 1032;
export const EXT_REST_PORT = 9096;

class J {
  static str(s: string): string {
    return JSON.stringify(s);
  }
}

function putStr(kv: string[], key: string, v: string | undefined): void {
  if (v !== undefined && v !== '') {
    kv.push(`"${key}":${J.str(v)}`);
  }
}

function putNum(kv: string[], key: string, v: number | undefined): void {
  if (v !== undefined && Number.isFinite(v)) {
    kv.push(`"${key}":${v}`);
  }
}

function putBool(kv: string[], key: string, v: boolean | undefined): void {
  if (v === true) {
    kv.push(`"${key}":true`);
  }
}

function putAlpn(kv: string[], alpn: string[] | undefined): void {
  if (alpn !== undefined && alpn.length > 0) {
    const items: string[] = [];
    for (const a of alpn) {
      items.push(J.str(a));
    }
    kv.push(`"alpn":[${items.join(',')}]`);
  }
}

/** 传输层（ws / grpc / http）与 mihomo 的 *-opts 结构 */
function putTransport(kv: string[], p: ProxyNode): void {
  if (p.network === 'ws') {
    putStr(kv, 'network', 'ws');
    const opts: string[] = [];
    putStr(opts, 'path', p.wsPath);
    if (p.wsHost !== undefined && p.wsHost !== '') {
      opts.push(`"headers":{"Host":${J.str(p.wsHost)}}`);
    }
    if (opts.length > 0) {
      kv.push(`"ws-opts":{${opts.join(',')}}`);
    }
  } else if (p.network === 'grpc') {
    putStr(kv, 'network', 'grpc');
    if (p.grpcServiceName !== undefined && p.grpcServiceName !== '') {
      kv.push(`"grpc-opts":{"grpc-service-name":${J.str(p.grpcServiceName)}}`);
    }
  } else if (p.network === 'http') {
    putStr(kv, 'network', 'http');
    const opts: string[] = [];
    if (p.httpPath !== undefined && p.httpPath !== '') {
      opts.push(`"path":[${J.str(p.httpPath)}]`);
    }
    if (p.httpHost !== undefined && p.httpHost !== '') {
      opts.push(`"headers":{"Host":${J.str(p.httpHost)}}`);
    }
    if (opts.length > 0) {
      kv.push(`"http-opts":{${opts.join(',')}}`);
    }
  }
}

/** TLS / Reality（vmess / vless / trojan / tuic） */
function putTls(kv: string[], p: ProxyNode, sniKey: string): void {
  putBool(kv, 'tls', p.tls);
  putStr(kv, sniKey, p.servername !== undefined && p.servername !== '' ? p.servername : p.sni);
  putAlpn(kv, p.alpn);
  putBool(kv, 'skip-cert-verify', p.skipCertVerify);
  putStr(kv, 'client-fingerprint', p.clientFingerprint);
  if (p.realityPublicKey !== undefined || p.realityShortId !== undefined) {
    const opts: string[] = [];
    putStr(opts, 'public-key', p.realityPublicKey !== undefined ? p.realityPublicKey : '');
    putStr(opts, 'short-id', p.realityShortId !== undefined ? p.realityShortId : '');
    kv.push(`"reality-opts":{${opts.join(',')}}`);
  }
}

/** ss 插件参数 → mihomo plugin-opts（对齐桌面端 parseSsPluginOpts） */
function pluginOptsJson(plugin: string, raw: string): string {
  const kv = new Map<string, string>();
  const rest: string[] = [];
  if (raw !== '') {
    for (const part of raw.split(';')) {
      const t = part.trim();
      if (t === '') {
        continue;
      }
      const eq = t.indexOf('=');
      if (eq >= 0) {
        kv.set(t.slice(0, eq).trim(), t.slice(eq + 1).trim());
      } else {
        rest.push(t);
      }
    }
  }
  const out: string[] = [];
  const g = (k: string): string => {
    const v = kv.get(k);
    return v === undefined ? '' : v;
  };
  if (plugin === 'obfs-local' || plugin === 'simple-obfs') {
    const mode = g('obfs') !== '' ? g('obfs') : (rest.length > 0 ? rest[0] : 'http');
    out.push(`"mode":${J.str(mode)}`);
    const host = g('obfs-host') !== '' ? g('obfs-host') : g('host');
    putStr(out, 'host', host);
    putStr(out, 'path', g('path'));
  } else {
    // v2ray-plugin（含 ws/tls 变体）
    const tlsVal = g('tls');
    out.push(`"mode":${J.str(g('mode') !== '' ? g('mode') : (rest.length > 0 ? rest[0] : 'websocket'))}`);
    out.push(`"tls":${tlsVal === 'true' || tlsVal === '1' ? 'true' : 'false'}`);
    putStr(out, 'host', g('host'));
    putStr(out, 'path', g('path'));
    putStr(out, 'tls-host', g('tls-host'));
    if (g('skip-cert-verify') !== '') {
      out.push(`"skip-cert-verify":${g('skip-cert-verify') === 'true' ? 'true' : 'false'}`);
    }
  }
  return `{${out.join(',')}}`;
}

/** 单节点 → mihomo proxy JSON（键名与 mihomo 字段一致，含连字符） */
export function proxyToKernelJson(p: ProxyNode): string {
  const kv: string[] = [];
  kv.push(`"name":${J.str(p.name)}`);
  kv.push(`"type":${J.str(p.type)}`);
  kv.push(`"server":${J.str(p.server)}`);
  kv.push(`"port":${p.port}`);

  if (p.type === 'hysteria2') {
    putStr(kv, 'password', p.password);
    putStr(kv, 'sni', p.sni);
    putBool(kv, 'skip-cert-verify', p.skipCertVerify);
    putStr(kv, 'fingerprint', p.fingerprintPin);
    putStr(kv, 'ports', p.ports);
    putStr(kv, 'hop-interval', p.hopInterval);
    putStr(kv, 'obfs', p.obfs);
    putStr(kv, 'obfs-password', p.obfsPassword);
    putAlpn(kv, p.alpn);
    putStr(kv, 'up', p.up);
    putStr(kv, 'down', p.down);
  } else if (p.type === 'hysteria') {
    putStr(kv, 'auth_str', p.authStr);
    putStr(kv, 'up', p.up);
    putStr(kv, 'down', p.down);
    putAlpn(kv, p.alpn);
    putBool(kv, 'skip-cert-verify', p.skipCertVerify);
    putStr(kv, 'sni', p.sni);
    putStr(kv, 'obfs', p.obfs);
  } else if (p.type === 'ss') {
    putStr(kv, 'cipher', p.cipher);
    putStr(kv, 'password', p.password);
    putStr(kv, 'plugin', p.plugin);
    if (p.plugin !== undefined && p.plugin !== '') {
      kv.push(`"plugin-opts":${pluginOptsJson(p.plugin, p.pluginOptsRaw !== undefined ? p.pluginOptsRaw : '')}`);
    }
    kv.push(`"udp":true`);
  } else if (p.type === 'vmess') {
    putStr(kv, 'uuid', p.uuid);
    putNum(kv, 'alterId', p.alterId);
    putStr(kv, 'cipher', p.cipher);
    putTls(kv, p, 'servername');
    putTransport(kv, p);
    kv.push(`"udp":true`);
  } else if (p.type === 'vless') {
    putStr(kv, 'uuid', p.uuid);
    putTls(kv, p, 'servername');
    putStr(kv, 'flow', p.flow);
    putTransport(kv, p);
    kv.push(`"udp":true`);
  } else if (p.type === 'trojan') {
    putStr(kv, 'password', p.password);
    putTls(kv, p, 'sni');
    putTransport(kv, p);
    kv.push(`"udp":true`);
  } else if (p.type === 'tuic') {
    putStr(kv, 'uuid', p.uuid);
    putStr(kv, 'password', p.password);
    putStr(kv, 'congestion-controller', p.congestionController);
    putTls(kv, p, 'sni');
    kv.push(`"udp":true`);
  } else if (p.type === 'socks5') {
    putStr(kv, 'username', p.username);
    putStr(kv, 'password', p.password);
    putBool(kv, 'tls', p.tls);
    kv.push(`"udp":true`);
  }
  return `{${kv.join(',')}}`;
}

/** 档案 → 完整内核配置 JSON（不含 log-file / interface-name，由扩展进程注入）
 *  presetIds：分流预设勾选（RulePresets id），展开顺序 = ad → direct-cn → stream → ai，置于私网直连之后、MATCH 之前 */
export function buildKernelConfig(profile: Profile | null, mixedPort: number, logLevel: string,
  presetIds: string[] = []): string {
  const nodes: ProxyNode[] = profile !== null ? profile.nodes : [];
  const names: string[] = [];
  const proxies: string[] = [];
  for (const n of nodes) {
    names.push(n.name);
    proxies.push(proxyToKernelJson(n));
  }

  const groups: string[] = [];
  const hasProxy = names.length > 0;
  if (names.length >= 2) {
    const memberList: string[] = [];
    for (const n of names) {
      memberList.push(J.str(n));
    }
    groups.push('{"name":"AUTO","type":"url-test","url":"http://www.gstatic.com/generate_204",'
      + `"interval":300,"tolerance":50,"lazy":true,"proxies":[${memberList.join(',')}]}`);
  }
  const proxyMembers: string[] = [];
  if (names.length >= 2) {
    proxyMembers.push('"AUTO"');
  }
  for (const n of names) {
    proxyMembers.push(J.str(n));
  }
  proxyMembers.push('"DIRECT"');
  groups.push(`{"name":"PROXY","type":"select","proxies":[${proxyMembers.join(',')}]}`);

  const rules: string[] = [
    '"IP-CIDR,192.168.0.0/16,DIRECT"',
    '"IP-CIDR,10.0.0.0/8,DIRECT"',
    '"IP-CIDR,172.16.0.0/12,DIRECT"',
    '"IP-CIDR,127.0.0.0/8,DIRECT"'
  ];
  // 分流预设（opt-in）：广告拦截 → 国内直连 → 流媒体 → AI，先于 MATCH 兜底
  for (const line of presetRuleLines(presetIds)) {
    rules.push(`"${line}"`);
  }
  rules.push(hasProxy ? '"MATCH,PROXY"' : '"MATCH,DIRECT"');

  const parts: string[] = [];
  parts.push('"mode":"rule"');
  parts.push(`"log-level":${J.str(logLevel)}`);
  parts.push('"bind-address":"127.0.0.1"');
  parts.push(`"mixed-port":${mixedPort}`);
  parts.push('"find-process-mode":"off"');
  // 不持久化策略组选择：否则上一次会话选过的 DIRECT 会被缓存带进新会话（表现为"隧道已连接但不走代理"）
  parts.push('"profile":{"store-selected":false,"store-fake-ip":false}');
  parts.push('"keep-alive-interval":30');
  parts.push('"keep-alive-idle":120');
  parts.push('"tcp-concurrent":true');
  parts.push('"unified-delay":true');
  parts.push('"dns":{"enable":true,"nameserver":["223.5.5.5","8.8.8.8","1.1.1.1"]}');
  parts.push(`"proxies":[${proxies.join(',')}]`);
  parts.push(`"proxy-groups":[${groups.join(',')}]`);
  parts.push(`"rules":[${rules.join(',')}]`);
  return `{${parts.join(',')}}`;
}