/**
 * M3 · B2 规则页：生效规则只读展示 + 活跃连接命中统计
 *
 * 数据来源：
 *  - 隧道运行中：内核 REST /rules（权威规则表）；/connections 按 metadata.rule + rulePayload 聚合
 *    当前活跃连接的命中数（内核侧为 CamelCase 类型名，展示侧统一规范化后与 /rules 对齐）；
 *  - 未运行：以当前档案 + 预设勾选经 ConfigBuilder 生成配置，解析 rules 段做本地预览（命中数显示 —）。
 */
import { buildKernelConfig, EXT_MIXED_PORT } from '../core/ConfigBuilder';
import { KernelRest } from '../core/KernelRest';
import { ProfileStore } from '../core/ProfileStore';
import { KEY_STATE } from '../core/TunnelManager';
import { KernelConnectionsResp, KernelRulesResp, Profile, TunnelState } from '../model/Types';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { T } from './Theme';

const DOMAIN = 0x0000;
const TAG = 'RulesView';

interface RuleRow {
  type: string;
  payload: string;
  policy: string;
  /** 命中的活跃连接数；-1 = 本地预览（无实时数据） */
  hits: number;
}

/** 本地预览用的配置切片（仅取 rules 段） */
interface ConfigSlice {
  rules?: string[];
}

const POLL_INTERVAL_MS = 5000;

@Component
export struct RulesView {
  @StorageLink(KEY_STATE) @Watch('onTunnelState') tunnelState: number = TunnelState.Stopped;
  @StorageLink('storeRev') @Watch('onStoreRev') storeRev: number = 0;
  @State rows: RuleRow[] = [];
  @State note: string = '';
  private timer: number = -1;
  /** 代际计数：新一轮 load 开始即作废旧一轮的结果（替代易锁死的 busy 守卫） */
  private gen: number = 0;
  /** 里程碑日志签名（去重） */
  private lastSig: string = '';

  aboutToAppear(): void {
    this.load();
    this.timer = setInterval(() => {
      this.tick();
    }, POLL_INTERVAL_MS);
    hilog.info(DOMAIN, TAG, 'aboutToAppear 已挂载（%{public}dms 轮询）', POLL_INTERVAL_MS);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  onTunnelState(): void {
    this.load();
  }

  onStoreRev(): void {
    this.load();
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.ToolbarCard()
        this.RulesCard()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  ToolbarCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(`规则（${this.rows.length}）`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(T.text)
          .layoutWeight(1)
        Text(this.tunnelState === TunnelState.Running ? '运行中 · 5s 刷新' : '未连接')
          .fontSize(11)
          .fontColor(this.tunnelState === TunnelState.Running ? T.ok : T.dim)
      }
      .width('100%')

      Row({ space: 8 }) {
        Button('刷新')
          .height(38)
          .fontSize(13)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .onClick(() => {
            this.load();
          })
      }
      .width('100%')

      if (this.note !== '') {
        Text(this.note)
          .fontSize(11)
          .fontColor(T.dim)
          .width('100%')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  RulesCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('生效规则')
          .fontSize(14)
          .fontColor(T.text)
          .layoutWeight(1)
        Text(`命中 ${this.hitCount()} 条`)
          .fontSize(10)
          .fontColor(T.dim)
      }
      .width('100%')

      if (this.rows.length === 0) {
        Text('暂无可展示规则')
          .fontSize(12)
          .fontColor(T.dim)
          .width('100%')
      } else {
        ForEach(this.rows, (r: RuleRow, idx: number) => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(r.payload !== '' ? r.payload : r.type)
                .fontSize(13)
                .fontColor(T.text)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(r.type)
                .fontSize(10)
                .fontColor(T.dim)
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(r.policy)
              .fontSize(10)
              .fontColor(this.policyColor(r.policy))
              .backgroundColor(T.track)
              .borderRadius(6)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })

            Text(this.hitsText(r.hits))
              .fontSize(11)
              .fontColor(r.hits > 0 ? T.accent : T.dim)
              .width(44)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding(10)
          .backgroundColor(T.panel)
          .borderRadius(T.radiusS)
        }, (r: RuleRow, idx: number) => `${idx}-${r.type}-${r.payload}-${r.hits}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  // ---------------------------------------------------------------- 数据

  private tick(): void {
    if (this.tunnelState === TunnelState.Running) {
      this.load();
    }
  }

  /** 里程碑日志去重：仅在预览/实时状态签名变化时输出（避免 5s 轮询刷屏） */
  private logSig(sig: string, line: string): void {
    if (sig !== this.lastSig) {
      this.lastSig = sig;
      hilog.info(DOMAIN, TAG, '%{public}s', line);
    }
  }

  private async load(): Promise<void> {
    const g = ++this.gen;
    const profile = ProfileStore.activeProfile();
    if (this.tunnelState !== TunnelState.Running) {
      this.note = '隧道未启动：以下为按当前档案与预设生成的本地预览；启动后展示内核生效规则与实时命中';
      this.rows = this.previewRows(profile);
      this.logSig(`preview:${this.rows.length}`, `预览 rows=${this.rows.length}`);
      return;
    }
    try {
      const resp: KernelRulesResp | null = await this.fetchRules();
      if (g !== this.gen) {
        return; // 已有更新的一轮，丢弃本次结果
      }
      const list = resp === null ? undefined : resp.rules;
      if (!Array.isArray(list)) {
        this.note = '内核 /rules 暂不可达（隧道可能正在重建），显示本地预览';
        this.rows = this.previewRows(profile);
        hilog.warn(DOMAIN, TAG, 'load#%{public}d /rules 不可达 → 预览', g);
        return;
      }
      const hits = await this.loadHits();
      if (g !== this.gen) {
        return;
      }
      const rows: RuleRow[] = [];
      for (const r of list) {
        const key = `${canonRuleType(r.type)}|${r.payload}`;
        const h = hits[key];
        rows.push({ type: r.type, payload: r.payload, policy: r.proxy, hits: h === undefined ? 0 : h });
      }
      this.rows = rows;
      this.note = '命中数来自 /connections 活跃连接快照（仅统计当前在连，非累计）';
      const hc = this.hitCount();
      this.logSig(`live:${rows.length}:${hc}`, `实时 rows=${rows.length} 命中行=${hc}`);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'load#%{public}d 异常 code=%{public}d msg=%{public}s', g, err.code, err.message);
    }
  }

  /** /rules 拉取（硬超时兜底：底层请求即使不返回也不阻塞页面刷新） */
  private async fetchRules(): Promise<KernelRulesResp | null> {
    const fallback: KernelRulesResp | null = null;
    return Promise.race([
      KernelRest.rules(),
      new Promise<KernelRulesResp | null>((resolve: (v: KernelRulesResp | null) => void) => {
        setTimeout(() => {
          resolve(fallback);
        }, 8000);
      })
    ]);
  }

  /** /connections → 规则命中聚合（键 = 规范化类型 + payload；硬超时兜底同上） */
  private async loadHits(): Promise<Record<string, number>> {
    const out: Record<string, number> = {};
    const empty: KernelConnectionsResp | null = null;
    const resp: KernelConnectionsResp | null = await Promise.race([
      KernelRest.connections(),
      new Promise<KernelConnectionsResp | null>((resolve: (v: KernelConnectionsResp | null) => void) => {
        setTimeout(() => {
          resolve(empty);
        }, 8000);
      })
    ]);
    if (resp === null || !Array.isArray(resp.connections)) {
      return out;
    }
    for (const c of resp.connections) {
      const md = c.metadata;
      if (md === undefined) {
        continue;
      }
      const rule = md.rule;
      if (rule === undefined || rule === '') {
        continue;
      }
      const payload = md.rulePayload === undefined ? '' : md.rulePayload;
      const key = `${canonRuleType(rule)}|${payload}`;
      const prev = out[key];
      out[key] = (prev === undefined ? 0 : prev) + 1;
    }
    return out;
  }

  /** 未运行态：解析 ConfigBuilder 产物的 rules 段（字符串 → 类型/payload/策略） */
  private previewRows(profile: Profile | null): RuleRow[] {
    const cfg = buildKernelConfig(profile, EXT_MIXED_PORT, 'info', ProfileStore.rulePresetIds());
    const parsed = JSON.parse(cfg) as ConfigSlice;
    const lines: string[] = parsed.rules === undefined ? [] : parsed.rules;
    const rows: RuleRow[] = [];
    for (const line of lines) {
      const parts = line.split(',');
      if (parts.length >= 3) {
        rows.push({ type: parts[0].trim(), payload: parts[1].trim(), policy: parts[2].trim(), hits: -1 });
      } else if (parts.length === 2) {
        // MATCH 类无 payload：如 "MATCH,PROXY"
        rows.push({ type: parts[0].trim(), payload: '', policy: parts[1].trim(), hits: -1 });
      }
    }
    return rows;
  }

  private hitCount(): number {
    let n = 0;
    for (const r of this.rows) {
      if (r.hits > 0) {
        n++;
      }
    }
    return n;
  }

  private hitsText(h: number): string {
    return h >= 0 ? `${h}` : '—';
  }

  private policyColor(p: string): string {
    if (p === 'DIRECT') {
      return T.ok;
    }
    if (p === 'REJECT') {
      return T.err;
    }
    return T.accent;
  }
}

/** 规则类型规范化：DOMAIN-SUFFIX / DomainSuffix 统一为 DOMAINSUFFIX，保证 /rules 与 /connections 可对齐 */
function canonRuleType(t: string): string {
  const up = t.toUpperCase();
  let out = '';
  for (let i = 0; i < up.length; i++) {
    const ch = up.charAt(i);
    if ((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')) {
      out += ch;
    }
  }
  return out;
}