/**
 * M2 · 档案存储：订阅导入（文本/URL）· 档案持久化 · 延迟缓存
 *
 * 落盘：`${filesDir}/arkhon/store.json`（仅应用沙箱内，节点凭据不外泄）
 * 结构：{ profiles: Profile[], activeId: string, delays: Record<profileId, Record<nodeName, DelayEntry>> }
 */
import fs from '@ohos.file.fs';
import httpRequest from '@ohos.net.http';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buffer } from '@kit.ArkTS';
import { DelayEntry, ImportKind, ImportResult, Profile, StoreData } from '../model/Types';
import { parseSubscriptionText } from './UriParser';

const DOMAIN = 0x0000;
const TAG = 'ProfileStore';
const SUB_UA = 'Arkhon/1.0 (HarmonyOS)';

export class ProfileStore {
  private static data: StoreData = emptyStore();
  private static dir: string = '';
  private static filePath: string = '';
  private static inited: boolean = false;

  /** 应用启动时初始化（创建目录 + 载入 store.json） */
  static init(ctx: common.UIAbilityContext): void {
    if (ProfileStore.inited) {
      return;
    }
    ProfileStore.dir = `${ctx.filesDir}/arkhon`;
    ProfileStore.filePath = `${ProfileStore.dir}/store.json`;
    try {
      fs.mkdirSync(ProfileStore.dir, true);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'mkdir 失败 code=%{public}d', (e as BusinessError).code);
    }
    const text = readFileText(ProfileStore.filePath);
    if (text !== '') {
      try {
        const parsed = JSON.parse(text) as StoreData;
        ProfileStore.data = normalize(parsed);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'store.json 解析失败，重建空库');
        ProfileStore.data = emptyStore();
      }
    }
    ProfileStore.inited = true;
    hilog.info(DOMAIN, TAG, 'store loaded profiles=%{public}d active=%{public}s',
      ProfileStore.data.profiles.length, ProfileStore.data.activeId);
  }

  static storePath(): string {
    return ProfileStore.filePath;
  }

  static listProfiles(): Profile[] {
    return ProfileStore.data.profiles;
  }

  static activeId(): string {
    return ProfileStore.data.activeId;
  }

  static activeProfile(): Profile | null {
    for (const p of ProfileStore.data.profiles) {
      if (p.id === ProfileStore.data.activeId) {
        return p;
      }
    }
    return null;
  }

  static findProfile(id: string): Profile | null {
    for (const p of ProfileStore.data.profiles) {
      if (p.id === id) {
        return p;
      }
    }
    return null;
  }

  /** 文本导入（粘贴）：解析成功即建档并激活 */
  static importText(text: string, name: string, url: string): ImportResult {
    const res = parseSubscriptionText(text);
    if (!res.ok) {
      return res;
    }
    ProfileStore.addProfile(name, url, res);
    return res;
  }

  /** URL 导入：抓取订阅内容 → 解析 → 建档并激活 */
  static async importUrl(url: string, name: string): Promise<ImportResult> {
    const fetched = await fetchText(url);
    if (!fetched.ok) {
      return { ok: false, kind: ImportKind.Unknown, nodes: [], error: fetched.error };
    }
    const res = parseSubscriptionText(fetched.text);
    if (!res.ok) {
      return res;
    }
    ProfileStore.addProfile(name !== '' ? name : hostOf(url), url, res);
    return res;
  }

  /** 刷新档案：重新抓取其 URL（无 URL 的粘贴档案返回可读报错） */
  static async refresh(id: string): Promise<ImportResult> {
    const p = ProfileStore.findProfile(id);
    if (p === null) {
      return { ok: false, kind: ImportKind.Unknown, nodes: [], error: '档案不存在' };
    }
    if (p.url === '') {
      return { ok: false, kind: ImportKind.Unknown, nodes: [], error: '该档案为粘贴导入（无来源 URL），请重新粘贴导入' };
    }
    const fetched = await fetchText(p.url);
    if (!fetched.ok) {
      return { ok: false, kind: ImportKind.Unknown, nodes: [], error: fetched.error };
    }
    const res = parseSubscriptionText(fetched.text);
    if (!res.ok) {
      return res;
    }
    p.nodes = res.nodes;
    p.updatedAt = Date.now();
    ProfileStore.save();
    return res;
  }

  static remove(id: string): void {
    const kept: Profile[] = [];
    for (const p of ProfileStore.data.profiles) {
      if (p.id !== id) {
        kept.push(p);
      }
    }
    ProfileStore.data.profiles = kept;
    // 重建 delays（ArkTS 约束：避免 delete 动态键）
    const nextDelays: Record<string, Record<string, DelayEntry>> = {};
    for (const k of Object.keys(ProfileStore.data.delays)) {
      if (k !== id) {
        nextDelays[k] = ProfileStore.data.delays[k];
      }
    }
    ProfileStore.data.delays = nextDelays;
    if (ProfileStore.data.activeId === id) {
      ProfileStore.data.activeId = kept.length > 0 ? kept[0].id : '';
    }
    ProfileStore.save();
  }

  static activate(id: string): void {
    ProfileStore.data.activeId = id;
    ProfileStore.save();
  }

  /** 延迟缓存读取（无记录返回 0） */
  static delayOf(profileId: string, nodeName: string): DelayEntry | null {
    const m = ProfileStore.data.delays[profileId];
    if (m === undefined) {
      return null;
    }
    const e = m[nodeName];
    return e === undefined ? null : e;
  }

  /** 批量写入延迟缓存（整档一次落盘） */
  static setDelays(profileId: string, entries: Record<string, DelayEntry>): void {
    ProfileStore.data.delays[profileId] = entries;
    ProfileStore.save();
  }

  static delayMap(profileId: string): Record<string, DelayEntry> {
    const m = ProfileStore.data.delays[profileId];
    return m === undefined ? {} : m;
  }

  private static addProfile(name: string, url: string, res: ImportResult): void {
    const p: Profile = {
      id: `${Date.now().toString(36)}${Math.floor(Math.random() * 1000)}`,
      name: name !== '' ? name : (url !== '' ? hostOf(url) : `导入 ${timeLabel()}`),
      url: url,
      kind: res.kind,
      nodes: res.nodes,
      updatedAt: Date.now()
    };
    ProfileStore.data.profiles.push(p);
    ProfileStore.data.activeId = p.id;
    ProfileStore.save();
  }

  private static save(): void {
    const text = JSON.stringify(ProfileStore.data);
    if (!writeFileText(ProfileStore.filePath, text)) {
      hilog.error(DOMAIN, TAG, 'store 落盘失败 path=%{public}s', ProfileStore.filePath);
    }
    // 通知 UI 刷新（AppStorage 版本号）
    const rev = AppStorage.get<number>('storeRev');
    AppStorage.setOrCreate('storeRev', (rev === undefined ? 0 : rev) + 1);
  }
}

// ---------------------------------------------------------------- 工具

interface FetchResult {
  ok: boolean;
  text: string;
  error: string;
}

async function fetchText(url: string): Promise<FetchResult> {
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return { ok: false, text: '', error: '订阅地址需以 http:// 或 https:// 开头' };
  }
  const http = httpRequest.createHttp();
  try {
    const resp = await http.request(url, {
      method: httpRequest.RequestMethod.GET,
      header: { 'User-Agent': SUB_UA },
      connectTimeout: 15000,
      readTimeout: 20000
    });
    const body = typeof resp.result === 'string' ? resp.result : `${resp.result}`;
    if (resp.responseCode !== 200) {
      http.destroy();
      return { ok: false, text: '', error: `订阅下载失败：HTTP ${resp.responseCode}（请检查地址/网络）` };
    }
    http.destroy();
    if (body.trim() === '') {
      return { ok: false, text: '', error: '订阅内容为空' };
    }
    return { ok: true, text: body, error: '' };
  } catch (e) {
    const err = e as BusinessError;
    http.destroy();
    return { ok: false, text: '', error: `订阅下载失败 code=${err.code} msg=${err.message}` };
  }
}

function emptyStore(): StoreData {
  return { profiles: [], activeId: '', delays: {} };
}

function normalize(parsed: StoreData): StoreData {
  const out = emptyStore();
  if (parsed === null || parsed === undefined) {
    return out;
  }
  if (Array.isArray(parsed.profiles)) {
    out.profiles = parsed.profiles;
  }
  out.activeId = typeof parsed.activeId === 'string' ? parsed.activeId : '';
  if (parsed.delays !== undefined && parsed.delays !== null) {
    out.delays = parsed.delays;
  }
  return out;
}

function hostOf(url: string): string {
  const idx = url.indexOf('://');
  if (idx < 0) {
    return url.slice(0, 24);
  }
  const rest = url.slice(idx + 3);
  const slash = rest.indexOf('/');
  const host = slash >= 0 ? rest.slice(0, slash) : rest;
  return host !== '' ? host : '订阅';
}

function timeLabel(): string {
  const d = new Date();
  return `${d.getMonth() + 1}-${d.getDate()} ${d.getHours()}:${pad2(d.getMinutes())}`;
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function readFileText(path: string): string {
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

function writeFileText(path: string, text: string): boolean {
  try {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, text);
    fs.closeSync(file);
    return true;
  } catch (e) {
    hilog.error(DOMAIN, TAG, '写文件失败 code=%{public}d', (e as BusinessError).code);
    return false;
  }
}