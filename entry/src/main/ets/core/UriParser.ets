/**
 * M2 · 订阅内容解析（移植桌面端 core-bridge/uri-profiles.ts 的规则）
 *
 * 自动识别（混合/无法识别 → 可读报错）：
 *   1) 节点 URI 列表：hysteria2:// hysteria:// ss:// vmess:// vless:// trojan:// tuic:// socks5://
 *   2) sing-box 导出 JSON（outbounds 数组）/ SSD JSON（servers 数组 / 顶层数组）
 *   3) Surge 节点行（ss / trojan / hy2）
 *
 * 与桌面端差异：桌面端 URI 列表仅覆盖前 6 种；本实现补充 tuic:// 与 socks5://
 * （与桌面端「分享链接导出」格式互为逆操作，便于双向互导）。
 */
import { buffer } from '@kit.ArkTS';
import { ImportKind, ImportResult, ProxyNode } from '../model/Types';

const URI_PREFIXES: string[] = [
  'hysteria2://', 'hysteria://', 'ss://', 'vmess://', 'vless://', 'trojan://', 'tuic://', 'socks5://'
];

// ---------------------------------------------------------------- 对外入口

export function parseSubscriptionText(text: string): ImportResult {
  const trimmed = text === null || text === undefined ? '' : text.trim();
  if (trimmed === '') {
    return fail('内容为空：请粘贴节点 URI 列表、sing-box/SSD JSON 或 Surge 节点行');
  }

  const lines: string[] = [];
  for (const raw of trimmed.split(/\r?\n/)) {
    const l = raw.trim();
    if (l !== '' && !l.startsWith('#')) {
      lines.push(l);
    }
  }

  // 1) 节点 URI 列表
  if (lines.length > 0 && lines.every((l: string) => hasUriPrefix(l))) {
    const nodes: ProxyNode[] = [];
    for (let i = 0; i < lines.length; i++) {
      const node = parseUriLine(lines[i]);
      if (node === null) {
        return fail(`第 ${i + 1} 行节点链接无法解析（协议参数不完整或编码错误）：${head(lines[i])}`);
      }
      if (node.server === '' || node.port <= 0) {
        return fail(`第 ${i + 1} 行节点缺少有效服务器地址/端口：${head(lines[i])}`);
      }
      nodes.push(node);
    }
    return ok(ImportKind.UriList, uniqueNames(nodes));
  }

  // 2) JSON：sing-box / SSD
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const nodes = tryConvertJson(trimmed);
    if (nodes !== null && nodes.length > 0) {
      return ok(ImportKind.SingBox, uniqueNames(nodes));
    }
    return fail('JSON 内容无法识别：既不是 sing-box 导出（outbounds），也不是 SSD（servers/数组）');
  }

  // 3) Surge 节点行
  const surge = tryConvertSurgeLines(lines);
  if (surge !== null && surge.length > 0) {
    return ok(ImportKind.Surge, uniqueNames(surge));
  }

  return fail('无法识别的订阅格式：支持节点 URI 列表（hysteria2/ss/vmess/vless/trojan 等）、'
    + 'sing-box 导出 JSON、SSD JSON、Surge 节点行；若为 Clash/YAML 配置请在桌面端转换后导入');
}

export function parseUriLine(line: string): ProxyNode | null {
  const lower = line.toLowerCase();
  if (lower.startsWith('hysteria2://')) return parseHysteria2(line);
  if (lower.startsWith('hysteria://')) return parseHysteria(line);
  if (lower.startsWith('ss://')) return parseSs(line);
  if (lower.startsWith('vmess://')) return parseVmess(line);
  if (lower.startsWith('trojan://')) return parseTrojan(line);
  if (lower.startsWith('vless://')) return parseVless(line);
  if (lower.startsWith('tuic://')) return parseTuic(line);
  if (lower.startsWith('socks5://')) return parseSocks5(line);
  return null;
}

function hasUriPrefix(line: string): boolean {
  const lower = line.toLowerCase();
  for (const p of URI_PREFIXES) {
    if (lower.startsWith(p)) {
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------- URI 拆解

/** 手工拆解 URI（避免 WHATWG URL 对 base64 userinfo/host 的大小写与编码归一化，见 ss 形态 C） */
class UriParts {
  scheme: string = '';
  authorityRaw: string = '';
  userinfo: string = '';
  host: string = '';
  port: number = 0;
  query: string = '';
  fragment: string = '';
}

function splitUri(uri: string): UriParts | null {
  const idx = uri.indexOf('://');
  if (idx <= 0) {
    return null;
  }
  const out = new UriParts();
  out.scheme = uri.slice(0, idx).toLowerCase();
  let rest = uri.slice(idx + 3);
  const hi = rest.indexOf('#');
  if (hi >= 0) {
    out.fragment = rest.slice(hi + 1);
    rest = rest.slice(0, hi);
  }
  const qi = rest.indexOf('?');
  if (qi >= 0) {
    out.query = rest.slice(qi + 1);
    rest = rest.slice(0, qi);
  }
  const si = rest.indexOf('/');
  if (si >= 0) {
    rest = rest.slice(0, si); // 丢弃 path（mihomo 不需要）
  }
  out.authorityRaw = rest;
  const at = rest.lastIndexOf('@');
  let hostport = rest;
  if (at >= 0) {
    out.userinfo = rest.slice(0, at);
    hostport = rest.slice(at + 1);
  }
  if (hostport.startsWith('[')) {
    const close = hostport.indexOf(']');
    if (close > 0) {
      out.host = hostport.slice(1, close);
      const tail = hostport.slice(close + 1);
      if (tail.startsWith(':')) {
        out.port = toPort(tail.slice(1), 0);
      }
    }
    return out;
  }
  const colon = hostport.lastIndexOf(':');
  if (colon >= 0) {
    out.host = hostport.slice(0, colon);
    out.port = toPort(hostport.slice(colon + 1), 0);
  } else {
    out.host = hostport;
  }
  return out;
}

function toPort(s: string, def: number): number {
  const n = Number(s);
  return Number.isFinite(n) && n > 0 && n <= 65535 ? Math.floor(n) : def;
}

function pctDecode(s: string): string {
  if (s === '') {
    return '';
  }
  try {
    return decodeURIComponent(s);
  } catch (e) {
    return s;
  }
}

function parseQuery(q: string): Map<string, string> {
  const out = new Map<string, string>();
  if (q === '') {
    return out;
  }
  for (const seg of q.split('&')) {
    if (seg === '') {
      continue;
    }
    const eq = seg.indexOf('=');
    const k = eq >= 0 ? seg.slice(0, eq) : seg;
    const v = eq >= 0 ? seg.slice(eq + 1) : '';
    if (k !== '' && !out.has(k)) {
      out.set(k, pctDecode(v));
    }
  }
  return out;
}

function qGet(q: Map<string, string>, keys: string[]): string {
  for (const k of keys) {
    const v = q.get(k);
    if (v !== undefined && v !== '') {
      return v;
    }
  }
  return '';
}

function isInsecure(v: string): boolean {
  const lower = v.toLowerCase();
  return lower === '1' || lower === 'true' || lower === 'yes';
}

function appendMbps(v: string): string {
  return /^[.\d]+$/.test(v) ? `${v} Mbps` : v;
}

function splitOnce(s: string, sep: string): string[] {
  const i = s.indexOf(sep);
  return i === -1 ? [s, ''] : [s.slice(0, i), s.slice(i + sep.length)];
}

function nameOrDefault(name: string, host: string, port: number): string {
  return name !== '' ? name : `${host}:${port}`;
}

// ---------------------------------------------------------------- base64

function b64DecodeLoose(s: string): string | null {
  try {
    const norm = s.replace(/-/g, '+').replace(/_/g, '/').trim();
    if (norm === '') {
      return null;
    }
    return buffer.from(norm, 'base64').toString('utf-8');
  } catch (e) {
    return null;
  }
}

/** 与桌面端一致：解出结果必须是可打印 ASCII，避免把普通字符串误判为 base64 */
function maybeB64(s: string): string | null {
  const out = b64DecodeLoose(s);
  if (out === null) {
    return null;
  }
  if (/^[\x20-\x7e@:.\-_,/;=+]+$/.test(out)) {
    return out;
  }
  return null;
}

// ---------------------------------------------------------------- hysteria2

function parseHysteria2(uri: string): ProxyNode | null {
  const u = splitUri(uri);
  if (u === null || u.host === '') {
    return null;
  }
  const q = parseQuery(u.query);
  const host = u.host;
  const port = u.port > 0 ? u.port : 443;
  const user = pctDecode(u.userinfo.split(':')[0]);
  let password = user;
  const colonIdx = u.userinfo.indexOf(':');
  if (colonIdx >= 0) {
    const pass = pctDecode(u.userinfo.slice(colonIdx + 1));
    password = user === '' ? pass : `${user}:${pass}`;
  }
  const node: ProxyNode = {
    name: nameOrDefault(pctDecode(u.fragment), host, port),
    type: 'hysteria2',
    server: host,
    port: port,
    password: password
  };
  const sni = qGet(q, ['sni', 'peer']);
  if (sni !== '') node.sni = sni;
  if (isInsecure(qGet(q, ['insecure']))) node.skipCertVerify = true;
  const pin = qGet(q, ['pinSHA256', 'pin-sha256', 'fingerprint']);
  if (pin !== '') {
    const normalized = pin.replace(/[^0-9a-fA-F]/g, '');
    node.fingerprintPin = normalized !== '' ? normalized : pin;
  }
  const mport = qGet(q, ['mport']);
  if (mport !== '') {
    node.ports = mport;
    node.hopInterval = '30';
  }
  const obfs = qGet(q, ['obfs']);
  if (obfs !== '') node.obfs = obfs;
  const obfsPwd = qGet(q, ['obfs-password', 'obfsPassword']);
  if (obfsPwd !== '') node.obfsPassword = obfsPwd;
  const alpn = qGet(q, ['alpn']);
  if (alpn !== '') node.alpn = splitList(alpn);
  const up = qGet(q, ['up']);
  if (up !== '') node.up = appendMbps(up);
  const down = qGet(q, ['down']);
  if (down !== '') node.down = appendMbps(down);
  return node;
}

function splitList(s: string): string[] {
  const out: string[] = [];
  for (const seg of s.split(',')) {
    const t = seg.trim();
    if (t !== '') {
      out.push(t);
    }
  }
  return out;
}

// ---------------------------------------------------------------- hysteria(v1)

function parseHysteria(uri: string): ProxyNode | null {
  const u = splitUri(uri);
  if (u === null || u.host === '') {
    return null;
  }
  const q = parseQuery(u.query);
  const host = u.host;
  const port = u.port > 0 ? u.port : 443;
  const node: ProxyNode = {
    name: nameOrDefault(pctDecode(u.fragment), host, port),
    type: 'hysteria',
    server: host,
    port: port,
    up: appendMbps(qGet(q, ['up']) !== '' ? qGet(q, ['up']) : '50'),
    down: appendMbps(qGet(q, ['down']) !== '' ? qGet(q, ['down']) : '100')
  };
  const auth = pctDecode(u.userinfo);
  if (auth !== '') node.authStr = auth;
  const alpn = qGet(q, ['alpn']);
  if (alpn !== '') node.alpn = splitList(alpn);
  if (isInsecure(qGet(q, ['insecure']))) node.skipCertVerify = true;
  const sni = qGet(q, ['peer', 'sni']);
  if (sni !== '') node.sni = sni;
  const obfs = qGet(q, ['obfs']);
  if (obfs !== '') node.obfs = obfs;
  return node;
}

// ---------------------------------------------------------------- shadowsocks

function parseSs(uri: string): ProxyNode | null {
  const u = splitUri(uri);
  if (u === null) {
    return null;
  }
  const q = parseQuery(u.query);
  let host = u.host;
  let port = u.port > 0 ? u.port : 8388;
  let cipher = 'aes-256-gcm';
  let password = '';

  const rawUser = pctDecode(u.userinfo);
  if (rawUser !== '') {
    if (rawUser.indexOf(':') >= 0) {
      // 形态 B: ss://cipher:password@host:port（首冒号分隔）
      const parts = splitOnce(rawUser, ':');
      cipher = parts[0];
      password = parts[1];
    } else {
      // 形态 A: ss://base64(cipher:password)@host:port —— userinfo 为纯 base64
      const decoded = maybeB64(rawUser);
      if (decoded !== null && decoded.indexOf(':') >= 0 && decoded.indexOf('@') < 0) {
        const parts = splitOnce(decoded, ':');
        cipher = parts[0];
        password = parts[1];
      } else {
        // 形态 C: ss://base64(cipher:password@host:port) —— 整段 base64 被解析为 host
        const whole = maybeB64(u.authorityRaw);
        if (whole !== null && whole.indexOf('@') >= 0) {
          const at = splitOnce(whole, '@');
          const cp = splitOnce(at[0], ':');
          cipher = cp[0];
          password = cp[1];
          const hpIdx = at[1].lastIndexOf(':');
          if (hpIdx > 0) {
            host = at[1].slice(0, hpIdx);
            port = toPort(at[1].slice(hpIdx + 1), 8388);
          } else {
            host = at[1];
            port = 8388;
          }
        } else {
          return null;
        }
      }
    }
  } else {
    return null;
  }

  const node: ProxyNode = {
    name: nameOrDefault(pctDecode(u.fragment), host, port),
    type: 'ss',
    server: host,
    port: port,
    cipher: cipher,
    password: password
  };
  const plugin = qGet(q, ['plugin']);
  if (plugin !== '') {
    const parts = splitOnce(plugin, ';');
    node.plugin = parts[0];
    node.pluginOptsRaw = parts[1];
  }
  return node;
}



// ---------------------------------------------------------------- vmess

function parseVmess(uri: string): ProxyNode | null {
  const body = uri.slice('vmess://'.length).split('#')[0];
  const decoded = b64DecodeLoose(body);
  if (decoded === null || decoded.trim() === '') {
    return null;
  }
  let j: VmessJson;
  try {
    j = JSON.parse(decoded) as VmessJson;
  } catch (e) {
    return null;
  }
  const host = strOf(j.add) !== '' ? strOf(j.add) : strOf(j.server);
  if (host === '') {
    return null;
  }
  const port = numOf(j.port) > 0 ? numOf(j.port) : 443;
  const node: ProxyNode = {
    name: strOf(j.ps) !== '' ? strOf(j.ps) : `${host}:${port}`,
    type: 'vmess',
    server: host,
    port: port,
    uuid: strOf(j.id),
    alterId: numOf(j.aid),
    cipher: strOf(j.scy) !== '' ? strOf(j.scy) : (strOf(j.security) !== '' ? strOf(j.security) : 'auto'),
    udp: true
  };
  const net = strOf(j.net) !== '' ? strOf(j.net) : 'tcp';
  const hostHeader = strOf(j.host);
  const path = strOf(j.path);
  applyTransport(node, net, hostHeader, path, '');
  if (strOf(j.tls) === 'tls') {
    node.tls = true;
    const sni = strOf(j.sni);
    node.servername = sni !== '' ? sni : (hostHeader !== '' ? hostHeader : host);
    if (strOf(j.fp) !== '') node.clientFingerprint = strOf(j.fp);
    const alpn = strOf(j.alpn);
    if (alpn !== '') node.alpn = splitList(alpn);
    if (isInsecure(strOf(j.allowInsecure))) node.skipCertVerify = true;
  }
  return node;
}

/** vmess base64 JSON 字段（宽松：number/string 均可） */
interface VmessJson {
  add?: string;
  server?: string;
  port?: string | number;
  ps?: string;
  id?: string;
  aid?: string | number;
  scy?: string;
  security?: string;
  net?: string;
  host?: string;
  path?: string;
  tls?: string;
  sni?: string;
  fp?: string;
  alpn?: string;
  allowInsecure?: string;
}

function strOf(v: string | number | undefined): string {
  if (typeof v === 'string') {
    return v.trim();
  }
  if (typeof v === 'number') {
    return `${v}`;
  }
  return '';
}

function numOf(v: string | number | undefined): number {
  if (typeof v === 'number') {
    return Number.isFinite(v) ? v : 0;
  }
  if (typeof v === 'string' && v.trim() !== '') {
    const n = Number(v.trim());
    return Number.isFinite(n) ? n : 0;
  }
  return 0;
}

// ---------------------------------------------------------------- vless / trojan

function parseVless(uri: string): ProxyNode | null {
  const u = splitUri(uri);
  if (u === null || u.host === '') {
    return null;
  }
  const q = parseQuery(u.query);
  const host = u.host;
  const port = u.port > 0 ? u.port : 443;
  const node: ProxyNode = {
    name: nameOrDefault(pctDecode(u.fragment), host, port),
    type: 'vless',
    server: host,
    port: port,
    uuid: pctDecode(u.userinfo.split(':')[0]),
    udp: true
  };
  applyTlsExtras(node, q, host);
  return node;
}

function parseTrojan(uri: string): ProxyNode | null {
  const u = splitUri(uri);
  if (u === null || u.host === '') {
    return null;
  }
  const q = parseQuery(u.query);
  const host = u.host;
  const port = u.port > 0 ? u.port : 443;
  const node: ProxyNode = {
    name: nameOrDefault(pctDecode(u.fragment), host, port),
    type: 'trojan',
    server: host,
    port: port,
    password: pctDecode(u.userinfo),
    udp: true
  };
  applyTlsExtras(node, q, host);
  return node;
}

function applyTlsExtras(node: ProxyNode, q: Map<string, string>, host: string): void {
  const security = qGet(q, ['security']) !== '' ? qGet(q, ['security']) : 'none';
  const sni = qGet(q, ['sni', 'peer']);
  const fp = qGet(q, ['fp', 'fingerprint']);
  if (security === 'tls') {
    node.tls = true;
    if (sni !== '') node.servername = sni;
    if (fp !== '') node.clientFingerprint = fp;
  } else if (security === 'reality') {
    node.tls = true;
    node.servername = sni !== '' ? sni : (qGet(q, ['host']) !== '' ? qGet(q, ['host']) : host);
    if (fp !== '') node.clientFingerprint = fp;
    const pbk = qGet(q, ['pbk', 'public-key']);
    const sid = qGet(q, ['sid', 'short-id']);
    if (pbk !== '' || sid !== '') {
      node.realityPublicKey = pbk;
      node.realityShortId = sid;
    }
  }
  const flow = qGet(q, ['flow']);
  if (flow !== '') node.flow = flow;
  const alpn = qGet(q, ['alpn']);
  if (alpn !== '') node.alpn = splitList(alpn);
  if (isInsecure(qGet(q, ['allowInsecure', 'insecure']))) node.skipCertVerify = true;
  const type = qGet(q, ['type', 'net']);
  const hostHeader = qGet(q, ['host']);
  const path = qGet(q, ['path']);
  const serviceName = qGet(q, ['serviceName', 'service_name']);
  applyTransport(node, type !== '' ? type : 'tcp', hostHeader, path, serviceName);
}

function applyTransport(node: ProxyNode, net: string, hostHeader: string, path: string, serviceName: string): void {
  if (net === 'ws' || net === 'websocket') {
    node.network = 'ws';
    if (path !== '') node.wsPath = path;
    if (hostHeader !== '') node.wsHost = hostHeader;
  } else if (net === 'grpc') {
    node.network = 'grpc';
    const svc = serviceName !== '' ? serviceName : hostHeader;
    if (svc !== '') node.grpcServiceName = svc;
  } else if (net === 'http' || net === 'h2') {
    node.network = 'http';
    if (path !== '') node.httpPath = path;
    if (hostHeader !== '') node.httpHost = hostHeader;
  }
}

// ---------------------------------------------------------------- tuic / socks5

function parseTuic(uri: string): ProxyNode | null {
  const u = splitUri(uri);
  if (u === null || u.host === '') {
    return null;
  }
  const q = parseQuery(u.query);
  const host = u.host;
  const port = u.port > 0 ? u.port : 443;
  const colonIdx = u.userinfo.indexOf(':');
  const uuid = pctDecode(colonIdx >= 0 ? u.userinfo.slice(0, colonIdx) : u.userinfo);
  const node: ProxyNode = {
    name: nameOrDefault(pctDecode(u.fragment), host, port),
    type: 'tuic',
    server: host,
    port: port,
    uuid: uuid
  };
  if (colonIdx >= 0) node.password = pctDecode(u.userinfo.slice(colonIdx + 1));
  const cc = qGet(q, ['congestion_control', 'congestion-controller', 'congestion']);
  if (cc !== '') node.congestionController = cc;
  const sni = qGet(q, ['sni', 'peer']);
  if (sni !== '') node.sni = sni;
  if (isInsecure(qGet(q, ['allow_insecure', 'insecure']))) node.skipCertVerify = true;
  const alpn = qGet(q, ['alpn']);
  if (alpn !== '') node.alpn = splitList(alpn);
  // tuic 默认走 TLS
  if (qGet(q, ['disable_sni']) !== 'true') node.tls = true;
  return node;
}

function parseSocks5(uri: string): ProxyNode | null {
  const u = splitUri(uri);
  if (u === null || u.host === '') {
    return null;
  }
  const host = u.host;
  const port = u.port > 0 ? u.port : 1080;
  const node: ProxyNode = {
    name: nameOrDefault(pctDecode(u.fragment), host, port),
    type: 'socks5',
    server: host,
    port: port,
    udp: true
  };
  const colonIdx = u.userinfo.indexOf(':');
  if (colonIdx >= 0) {
    node.username = pctDecode(u.userinfo.slice(0, colonIdx));
    node.password = pctDecode(u.userinfo.slice(colonIdx + 1));
  } else if (u.userinfo !== '') {
    node.username = pctDecode(u.userinfo);
  }
  return node;
}

// ---------------------------------------------------------------- JSON：sing-box / SSD

function tryConvertJson(text: string): ProxyNode[] | null {
  let parsed: Object;
  try {
    parsed = JSON.parse(text) as Object;
  } catch (e) {
    return null;
  }
  if (Array.isArray(parsed)) {
    const out = ssdServers(parsed as SsdServer[]);
    return out.length > 0 ? out : null;
  }
  const rec = parsed as SbContainer;
  if (rec.outbounds !== undefined && Array.isArray(rec.outbounds) && rec.outbounds.length > 0) {
    const out = singBoxOutbounds(rec.outbounds);
    return out.length > 0 ? out : null;
  }
  if (rec.servers !== undefined && Array.isArray(rec.servers) && rec.servers.length > 0) {
    const out = ssdServers(rec.servers);
    return out.length > 0 ? out : null;
  }
  return null;
}

interface SbContainer {
  outbounds?: SbOutbound[];
  servers?: SsdServer[];
}

interface SbOutbound {
  type?: string;
  tag?: string;
  server?: string;
  server_port?: number;
  password?: string;
  uuid?: string;
  method?: string;
  flow?: string;
  congestion_control?: string;
  obfs?: SbObfs;
  tls?: SbTls;
  transport?: SbTransport;
}

interface SbObfs {
  type?: string;
  password?: string;
}

interface SbTls {
  enabled?: boolean | string;
  server_name?: string;
  insecure?: boolean | string;
  alpn?: string[];
  utls?: SbUtls;
  reality?: SbReality;
}

interface SbUtls {
  enabled?: boolean;
  fingerprint?: string;
}

interface SbReality {
  public_key?: string;
  short_id?: string;
}

interface SbTransport {
  type?: string;
  path?: string;
  host?: string;
  service_name?: string;
  headers?: Record<string, string>;
}

interface SsdServer {
  server?: string;
  server_port?: number;
  method?: string;
  password?: string;
  remarks?: string;
  name?: string;
  plugin?: string;
  plugin_opts?: string;
}

function ssdServers(servers: SsdServer[]): ProxyNode[] {
  const out: ProxyNode[] = [];
  for (const sv of servers) {
    const server = sv.server !== undefined ? sv.server.trim() : '';
    const port = sv.server_port !== undefined && sv.server_port > 0 ? sv.server_port : 0;
    if (server === '' || port <= 0) {
      continue;
    }
    const remarks = sv.remarks !== undefined && sv.remarks.trim() !== ''
      ? sv.remarks.trim() : (sv.name !== undefined ? sv.name.trim() : '');
    const node: ProxyNode = {
      name: remarks !== '' ? remarks : `${server}:${port}`,
      type: 'ss',
      server: server,
      port: port,
      cipher: sv.method !== undefined && sv.method.trim() !== '' ? sv.method.trim() : 'aes-256-gcm',
      password: sv.password !== undefined ? sv.password : ''
    };
    if (sv.plugin !== undefined && sv.plugin.trim() !== '') {
      const parts = splitOnce(sv.plugin.trim(), ';');
      node.plugin = parts[0];
      node.pluginOptsRaw = parts[1];
    }
    if (sv.plugin_opts !== undefined && sv.plugin_opts.trim() !== '') {
      node.pluginOptsRaw = sv.plugin_opts.trim();
    }
    out.push(node);
  }
  return out;
}

function singBoxOutbounds(outbounds: SbOutbound[]): ProxyNode[] {
  const out: ProxyNode[] = [];
  for (const ob of outbounds) {
    const type = ob.type !== undefined ? ob.type : '';
    const supported = type === 'vless' || type === 'vmess' || type === 'trojan'
      || type === 'shadowsocks' || type === 'hysteria2' || type === 'tuic' || type === 'socks';
    if (!supported) {
      continue;
    }
    const server = ob.server !== undefined ? ob.server.trim() : '';
    const port = ob.server_port !== undefined && ob.server_port > 0 ? ob.server_port : 0;
    if (server === '' || port <= 0) {
      continue;
    }
    const tag = ob.tag !== undefined && ob.tag.trim() !== '' ? ob.tag.trim() : `${server}:${port}`;
    const node: ProxyNode = {
      name: tag,
      type: type === 'shadowsocks' ? 'ss' : type,
      server: server,
      port: port
    };
    if (type === 'hysteria2') {
      node.password = ob.password !== undefined ? ob.password : '';
      if (ob.obfs !== undefined) {
        if (ob.obfs.type !== undefined && ob.obfs.type !== '') node.obfs = ob.obfs.type;
        if (ob.obfs.password !== undefined && ob.obfs.password !== '') node.obfsPassword = ob.obfs.password;
      }
    } else if (type === 'tuic') {
      node.uuid = ob.uuid !== undefined ? ob.uuid : '';
      node.password = ob.password !== undefined ? ob.password : '';
      if (ob.congestion_control !== undefined && ob.congestion_control !== '') {
        node.congestionController = ob.congestion_control;
      }
    } else if (type === 'shadowsocks') {
      node.cipher = ob.method !== undefined && ob.method !== '' ? ob.method : 'aes-256-gcm';
      node.password = ob.password !== undefined ? ob.password : '';
    } else if (type === 'socks') {
      node.username = ob.uuid !== undefined ? ob.uuid : '';
      node.password = ob.password !== undefined ? ob.password : '';
      node.udp = true;
    } else {
      node.uuid = ob.uuid !== undefined ? ob.uuid : '';
      node.udp = true;
      if (type === 'vless' && ob.flow !== undefined && ob.flow !== '') node.flow = ob.flow;
      if (type === 'vmess') {
        node.alterId = 0;
        node.cipher = 'auto';
      }
      if (type === 'trojan') {
        node.password = ob.password !== undefined ? ob.password : '';
      }
    }

    // TLS
    const tls = ob.tls;
    if (tls !== undefined && (tls.enabled === true || tls.enabled === 'true')) {
      node.tls = true;
      const servername = tls.server_name !== undefined && tls.server_name !== '' ? tls.server_name : server;
      if (servername !== '') node.servername = servername;
      if (tls.alpn !== undefined && Array.isArray(tls.alpn) && tls.alpn.length > 0) node.alpn = tls.alpn;
      if (tls.insecure === true || tls.insecure === 'true') node.skipCertVerify = true;
      if (tls.utls !== undefined && tls.utls.enabled === true
        && tls.utls.fingerprint !== undefined && tls.utls.fingerprint !== '') {
        node.clientFingerprint = tls.utls.fingerprint;
      }
      if (tls.reality !== undefined) {
        const pbk = tls.reality.public_key !== undefined ? tls.reality.public_key : '';
        const sid = tls.reality.short_id !== undefined ? tls.reality.short_id : '';
        if (pbk !== '' || sid !== '') {
          node.realityPublicKey = pbk;
          node.realityShortId = sid;
        }
      }
    }

    // 传输
    const tr = ob.transport;
    if (tr !== undefined && tr.type !== undefined) {
      if (tr.type === 'ws' || tr.type === 'websocket') {
        node.network = 'ws';
        if (tr.path !== undefined && tr.path !== '') node.wsPath = tr.path;
        if (tr.headers !== undefined && tr.headers['Host'] !== undefined) node.wsHost = tr.headers['Host'];
      } else if (tr.type === 'grpc') {
        node.network = 'grpc';
        if (tr.service_name !== undefined && tr.service_name !== '') node.grpcServiceName = tr.service_name;
      } else if (tr.type === 'http') {
        node.network = 'http';
        if (tr.path !== undefined && tr.path !== '') node.httpPath = tr.path;
        if (tr.host !== undefined && tr.host !== '') node.httpHost = tr.host;
      }
    }
    out.push(node);
  }
  return out;
}

// ---------------------------------------------------------------- Surge 行

function tryConvertSurgeLines(lines: string[]): ProxyNode[] | null {
  if (lines.length === 0) {
    return null;
  }
  const out: ProxyNode[] = [];
  for (const line of lines) {
    if (!line.includes('=')) {
      return null;
    }
    const eq = line.indexOf('=');
    const name = line.slice(0, eq).trim();
    const body = line.slice(eq + 1).trim();
    const m = /^(\w+)\s*,\s*([^,\s]+)\s*,\s*(\d+)(.*)$/.exec(body);
    if (m === null) {
      return null;
    }
    const type = m[1].toLowerCase();
    const host = m[2].trim();
    const port = toPort(m[3], 0);
    if (port <= 0) {
      return null;
    }
    const rest = m[4];
    const kv = parseSurgeKv(rest);
    const pos: string[] = [];
    for (const seg of rest.split(',')) {
      const t = seg.trim();
      if (t !== '') {
        pos.push(t);
      }
    }
    if (type === 'ss' || type === 'shadowsocks') {
      let cipher = kv.get('encrypt-method');
      if (cipher === undefined || cipher === '') {
        cipher = 'aes-256-gcm';
        for (const x of pos) {
          if (x.includes('aes') || x.includes('chacha')) {
            cipher = x;
            break;
          }
        }
      }
      const pwd = kv.get('password');
      out.push({
        name: name,
        type: 'ss',
        server: host,
        port: port,
        cipher: cipher,
        password: pwd !== undefined && pwd !== '' ? pwd : (pos.length > 0 ? pos[pos.length - 1] : '')
      });
    } else if (type === 'trojan') {
      const pwd = kv.get('password');
      const sni = kv.get('sni');
      out.push({
        name: name,
        type: 'trojan',
        server: host,
        port: port,
        password: pwd !== undefined && pwd !== '' ? pwd : (pos.length > 0 ? pos[pos.length - 1] : ''),
        sni: sni !== undefined && sni !== '' ? sni : host,
        udp: true
      });
    } else if (type === 'hy2' || type === 'hysteria2') {
      const pwd = kv.get('password');
      const auth = kv.get('auth');
      const node: ProxyNode = {
        name: name,
        type: 'hysteria2',
        server: host,
        port: port,
        password: pwd !== undefined && pwd !== '' ? pwd : (auth !== undefined ? auth : '')
      };
      const obfs = kv.get('obfs');
      if (obfs !== undefined && obfs !== '') node.obfs = obfs;
      const obfsPwd = kv.get('obfs-password');
      if (obfsPwd !== undefined && obfsPwd !== '') node.obfsPassword = obfsPwd;
      const sni = kv.get('sni');
      if (sni !== undefined && sni !== '') node.sni = sni;
      if (isInsecure(kv.get('insecure') !== undefined ? kv.get('insecure') as string : '')) {
        node.skipCertVerify = true;
      }
      out.push(node);
    } else {
      return null;
    }
  }
  return out.length > 0 ? out : null;
}

function parseSurgeKv(rest: string): Map<string, string> {
  const kv = new Map<string, string>();
  for (const seg of rest.split(',')) {
    const t = seg.trim();
    const m = /^([A-Za-z0-9\-_.]+)\s*=\s*(.*)$/.exec(t);
    if (m !== null) {
      kv.set(m[1].toLowerCase(), m[2].trim());
    }
  }
  return kv;
}

// ---------------------------------------------------------------- 组装

/** 节点重名去重（-2、-3 …），保证内核 proxies 唯一键 */
function uniqueNames(nodes: ProxyNode[]): ProxyNode[] {
  const seen = new Map<string, number>();
  for (const n of nodes) {
    const base = n.name !== '' ? n.name : 'node';
    let name = base;
    if (seen.has(name)) {
      let i = 2;
      while (seen.has(`${base}-${i}`)) {
        i++;
      }
      name = `${base}-${i}`;
    }
    seen.set(name, 1);
    n.name = name;
  }
  return nodes;
}

function head(s: string): string {
  return s.length > 48 ? `${s.slice(0, 48)}…` : s;
}

function ok(kind: ImportKind, nodes: ProxyNode[]): ImportResult {
  return { ok: true, kind: kind, nodes: nodes, error: '' };
}

function fail(error: string): ImportResult {
  return { ok: false, kind: ImportKind.Unknown, nodes: [], error: error };
}