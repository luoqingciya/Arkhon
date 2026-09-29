/**
 * M2 · 代理页：策略组切换（内核 /proxies）+ 节点列表 + 并发测速（/proxies/{name}/delay）
 *
 * 数据来源：
 *  - 隧道运行中：内核 REST /proxies（权威视图：组、选中、存活、测速历史）；
 *  - 未运行：档案节点 + 本地延迟缓存（只读）。
 */
import { KernelRest } from '../core/KernelRest';
import { ProfileStore } from '../core/ProfileStore';
import { SpeedTester } from '../core/SpeedTester';
import { TunnelManager, KEY_STATE } from '../core/TunnelManager';
import { DelayEntry, KernelProxyItem, KernelProxiesResp, Profile, ProxyNode, TunnelState } from '../model/Types';
import { T } from './Theme';

interface ProxyRow {
  name: string;
  type: string;
  delay: number;
  selected: boolean;
}

interface GroupRow {
  name: string;
  type: string;
  now: string;
  members: string[];
}

/** 内核内置代理项（无档案兜底展示时过滤） */
const BUILTIN_PROXIES: string[] = [
  'DIRECT', 'REJECT', 'GLOBAL', 'PASS', 'COMPATIBLE', 'REJECT-DROP', 'PASS-RULE'
];

@Component
export struct ProxiesView {
  @StorageLink(KEY_STATE) @Watch('onTunnelState') tunnelState: number = TunnelState.Stopped;
  @StorageLink('storeRev') @Watch('onStoreRev') storeRev: number = 0;
  @State rows: ProxyRow[] = [];
  @State groups: GroupRow[] = [];
  @State note: string = '';
  @State testing: boolean = false;
  @State delayRev: number = 0;
  private liveDelay: Record<string, number> = {};

  aboutToAppear(): void {
    this.load();
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
        if (this.groups.length > 0) {
          this.GroupsCard()
        }
        this.NodesCard()
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
        Text('节点与策略组')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(T.text)
          .layoutWeight(1)
        Text(this.testing ? '测速中…' : (this.canTest() ? '可测速' : '未连接'))
          .fontSize(11)
          .fontColor(this.testing ? T.warn : (this.canTest() ? T.ok : T.dim))
      }
      .width('100%')

      Row({ space: 8 }) {
        Button(this.testing ? '测速中…' : '一键测速')
          .height(38)
          .fontSize(13)
          .backgroundColor(T.accent)
          .fontColor('#0b1220')
          .enabled(!this.testing && this.canTest())
          .onClick(() => {
            this.startTest();
          })
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
  GroupsCard() {
    Column({ space: 10 }) {
      Text('策略组')
        .fontSize(14)
        .fontColor(T.text)
        .width('100%')
      ForEach(this.groups, (g: GroupRow) => {
        Column({ space: 6 }) {
          Row({ space: 8 }) {
            Text(g.name)
              .fontSize(13)
              .fontColor(T.text)
            Text(this.groupTypeLabel(g.type))
              .fontSize(10)
              .fontColor(g.type === 'Selector' ? T.accent : T.ok)
              .backgroundColor(T.track)
              .borderRadius(6)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            Blank()
            Text(`当前：${g.now}`)
              .fontSize(11)
              .fontColor(T.dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')

          Select(this.optionsOf(g.members))
            .selected(this.selectedIndex(g))
            .value(g.now)
            .font({ size: 13 })
            .width('100%')
            .onSelect((index: number, value: string) => {
              this.switchMember(g, value);
            })
        }
        .width('100%')
        .padding(10)
        .backgroundColor(T.panel)
        .borderRadius(T.radiusS)
      }, (g: GroupRow) => `${g.name}-${g.now}`)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  NodesCard() {
    Column({ space: 8 }) {
      Text(`节点（${this.rows.length}）`)
        .fontSize(14)
        .fontColor(T.text)
        .width('100%')
        if (this.rows.length === 0) {
        Text('暂无节点：请先在「订阅」页导入')
          .fontSize(12)
          .fontColor(T.dim)
          .width('100%')
      } else {
        ForEach(this.rows, (r: ProxyRow) => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(r.name)
                .fontSize(13)
                .fontColor(r.selected ? T.accent : T.text)
                .fontWeight(r.selected ? FontWeight.Bold : FontWeight.Normal)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(r.type)
                .fontSize(10)
                .fontColor(T.dim)
                .width('100%')
            }
            .layoutWeight(1)

            Text(this.delayText(this.delayOfRow(r)))
              .fontSize(12)
              .fontColor(this.delayColor(this.delayOfRow(r)))
              .width(64)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding(10)
          .backgroundColor(r.selected ? T.accentSoft : T.panel)
          .borderRadius(T.radiusS)
          .onClick(() => {
            this.selectNode(r);
          })
        }, (r: ProxyRow) => `${r.name}-${this.delayOfRow(r)}-${r.selected ? 1 : 0}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  // ---------------------------------------------------------------- 数据

  private canTest(): boolean {
    return this.tunnelState === TunnelState.Running;
  }

  private async load(): Promise<void> {
    const profile = ProfileStore.activeProfile();
    const emptyDelays: Record<string, DelayEntry> = {};
    const cached = profile !== null ? ProfileStore.delayMap(profile.id) : emptyDelays;
    if (this.tunnelState !== TunnelState.Running) {
      this.note = '隧道未启动：显示档案节点与本地缓存延迟；启动隧道后可测速/切换';
      this.groups = [];
      this.rows = this.rowsFromProfile(profile, cached);
      return;
    }
    const resp: KernelProxiesResp | null = await KernelRest.proxies();
    if (resp === null || resp.proxies === undefined) {
      this.note = '内核 REST 暂不可达（隧道可能正在重建），显示本地数据';
      this.groups = [];
      this.rows = this.rowsFromProfile(profile, cached);
      return;
    }
    this.note = '';
    const groups: GroupRow[] = [];
    const rows: ProxyRow[] = [];
    // 出口链下钻（PROXY → AUTO 等组 → 最终节点）：高亮真正生效的节点
    const egress = this.ultimateEgress(resp);
    const keys = Object.keys(resp.proxies);
    for (const k of keys) {
      const item: KernelProxyItem = resp.proxies[k];
      if (item === undefined) {
        continue;
      }
      if (item.all !== undefined && item.all.length > 0) {
        if (k !== 'GLOBAL' && k !== 'DIRECT' && k !== 'REJECT') {
          groups.push({
            name: k,
            type: item.type,
            now: item.now !== undefined ? item.now : '',
            members: item.all
          });
        }
      }
    }
    if (profile !== null && profile.nodes.length > 0) {
      // 以档案节点为准（内核内置项 COMPATIBLE/PASS/REJECT-DROP 等不展示），叠加内核实时数据
      for (const n of profile.nodes) {
        const item: KernelProxyItem | undefined = resp.proxies[n.name];
        rows.push({
          name: n.name,
          type: item !== undefined ? item.type : n.type,
          delay: item !== undefined ? this.historyDelay(item) : 0,
          selected: egress === n.name
        });
      }
    } else {
      for (const k of keys) {
        const item: KernelProxyItem = resp.proxies[k];
        if (item === undefined || (item.all !== undefined && item.all.length > 0)) {
          continue;
        }
        if (BUILTIN_PROXIES.indexOf(k) >= 0) {
          continue;
        }
        rows.push({
          name: k,
          type: item.type,
          delay: this.historyDelay(item),
          selected: egress === k
        });
      }
    }
    this.groups = groups;
    this.rows = this.sortRows(rows, cached);
  }

  private rowsFromProfile(profile: Profile | null, cached: Record<string, DelayEntry>): ProxyRow[] {
    const rows: ProxyRow[] = [];
    if (profile !== null) {
      for (const n of profile.nodes) {
        const c = cached[n.name];
        rows.push({
          name: n.name,
          type: n.type,
          delay: c !== undefined ? c.delay : 0,
          selected: false
        });
      }
    }
    return this.sortRows(rows, cached);
  }

  /** 排序：有延迟升序 → 未测 → 超时；保证实时结果（liveDelay）优先 */
  private sortRows(rows: ProxyRow[], cached: Record<string, DelayEntry>): ProxyRow[] {
    for (const r of rows) {
      if (this.liveDelay[r.name] !== undefined) {
        r.delay = this.liveDelay[r.name];
      } else if (r.delay === 0 && cached[r.name] !== undefined) {
        r.delay = cached[r.name].delay;
      }
    }
    rows.sort((a: ProxyRow, b: ProxyRow) => {
      const da = a.delay;
      const db = b.delay;
      const ra = da > 0 ? 0 : (da === 0 ? 1 : 2);
      const rb = db > 0 ? 0 : (db === 0 ? 1 : 2);
      if (ra !== rb) {
        return ra - rb;
      }
      return da - db;
    });
    return rows;
  }

  private historyDelay(item: KernelProxyItem): number {
    const h = item.history;
    if (h === undefined || h.length === 0) {
      return 0;
    }
    const last = h[h.length - 1];
    return last !== undefined && Number.isFinite(last.delay) ? last.delay : 0;
  }

  /** 出口链下钻：从 PROXY 起沿组链（AUTO 等）走到叶节点，返回最终出口名 */
  private ultimateEgress(resp: KernelProxiesResp): string {
    let cur = 'PROXY';
    for (let depth = 0; depth < 8; depth++) {
      const item: KernelProxyItem | undefined = resp.proxies[cur];
      if (item === undefined) {
        return '';
      }
      const next = item.now;
      if (next === undefined || next === '') {
        return cur; // 叶节点（无 now）
      }
      cur = next;
    }
    return '';
  }

  private delayOfRow(r: ProxyRow): number {
    const live = this.liveDelay[r.name];
    return live !== undefined ? live : r.delay;
  }

  private delayText(d: number): string {
    if (d > 0) {
      return `${d} ms`;
    }
    if (d === -1) {
      return '超时';
    }
    return '—';
  }

  private delayColor(d: number): string {
    if (d > 0) {
      return d < 300 ? T.ok : (d < 800 ? T.warn : T.err);
    }
    if (d === -1) {
      return T.err;
    }
    return T.dim;
  }

  private optionsOf(members: string[]): SelectOption[] {
    const out: SelectOption[] = [];
    for (const m of members) {
      const o: SelectOption = { value: m };
      out.push(o);
    }
    return out;
  }

  private selectedIndex(g: GroupRow): number {
    for (let i = 0; i < g.members.length; i++) {
      if (g.members[i] === g.now) {
        return i;
      }
    }
    return 0;
  }

  private groupTypeLabel(t: string): string {
    if (t === 'Selector') {
      return '手动';
    }
    if (t === 'URLTest') {
      return '自动选优';
    }
    if (t === 'Fallback') {
      return '故障转移';
    }
    if (t === 'LoadBalance') {
      return '负载均衡';
    }
    return t;
  }

  // ---------------------------------------------------------------- 动作

  private switchMember(g: GroupRow, member: string): void {
    TunnelManager.log(`[UI] 切换 ${g.name} → ${member}`);
    KernelRest.select(g.name, member).then((ok: boolean) => {
      if (ok) {
        this.load();
      } else {
        this.note = `切换失败：${member}（内核未接受）`;
      }
    });
  }

  private selectNode(r: ProxyRow): void {
    if (this.tunnelState !== TunnelState.Running) {
      return;
    }
    TunnelManager.log(`[UI] 选择节点 ${r.name}`);
    KernelRest.select('PROXY', r.name).then((ok: boolean) => {
      if (ok) {
        this.load();
      } else {
        this.note = `选择失败：${r.name}`;
      }
    });
  }

  private startTest(): void {
    const profile = ProfileStore.activeProfile();
    if (profile === null || profile.nodes.length === 0) {
      this.note = '当前档案没有可测速节点';
      return;
    }
    this.testing = true;
    this.note = `测速中（${profile.nodes.length} 节点，6 并发）…`;
    const emptyDelays: Record<string, DelayEntry> = {};
    SpeedTester.testAll(profile.id, profile.nodes, (name: string, delay: number) => {
      this.liveDelay[name] = delay;
      this.delayRev++;
      // 重建数组驱动列表即时刷新（含重排序）
      this.rows = this.sortRows(this.rows, emptyDelays);
    }).then(() => {
      this.testing = false;
      this.note = '测速完成（结果已写入本地缓存）';
      this.load();
    });
  }
}