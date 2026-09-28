/**
 * M2 · 订阅页：导入（URL 抓取 / 文本粘贴）+ 档案列表（启用/刷新/删除）
 */
import { ProfileStore } from '../core/ProfileStore';
import { TunnelManager } from '../core/TunnelManager';
import { Profile } from '../model/Types';
import { T } from './Theme';

@Component
export struct ProfilesView {
  @StorageLink('storeRev') @Watch('onStoreRev') storeRev: number = 0;
  @State url: string = '';
  @State pasteText: string = '';
  @State feedback: string = '';
  @State feedbackOk: boolean = true;
  @State busy: boolean = false;
  /** 档案行快照：由 storeRev 变更驱动重建（保证 ForEach 数据源整体刷新） */
  @State rows: Profile[] = [];

  aboutToAppear(): void {
    this.rows = ProfileStore.listProfiles().slice();
  }

  onStoreRev(): void {
    this.rows = ProfileStore.listProfiles().slice();
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.ImportCard()
        this.ListCard()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  ImportCard() {
    Column({ space: 10 }) {
      Text('导入订阅')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.text)
        .width('100%')

      Row({ space: 8 }) {
        TextInput({ placeholder: '订阅链接 https://…', text: this.url })
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .placeholderColor(T.dim)
          .onChange((v: string) => {
            this.url = v;
          })
        Button('下载导入')
          .height(40)
          .fontSize(13)
          .backgroundColor(T.accentSoft)
          .fontColor(T.accent)
          .enabled(!this.busy)
          .onClick(() => {
            this.doUrlImport();
          })
      }
      .width('100%')

      TextArea({ placeholder: '粘贴节点 URI 列表 / sing-box JSON / SSD / Surge 节点行', text: this.pasteText })
        .width('100%')
        .height(96)
        .fontSize(12)
        .backgroundColor(T.track)
        .fontColor(T.text)
        .placeholderColor(T.dim)
        .onChange((v: string) => {
          this.pasteText = v;
        })

      Row({ space: 8 }) {
        Button('粘贴导入')
          .height(40)
          .fontSize(13)
          .backgroundColor(T.accent)
          .fontColor('#0b1220')
          .enabled(!this.busy && this.pasteText.trim() !== '')
          .onClick(() => {
            this.doPasteImport();
          })
        Button('清空')
          .height(40)
          .fontSize(13)
          .backgroundColor(T.track)
          .fontColor(T.sub)
          .onClick(() => {
            this.pasteText = '';
          })
      }
      .width('100%')

      if (this.feedback !== '') {
        Text(this.feedback)
          .fontSize(12)
          .fontColor(this.feedbackOk ? T.ok : T.err)
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
  ListCard() {
    Column({ space: 10 }) {
      Text(`档案（${this.rows.length}）`)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.text)
        .width('100%')

      if (this.rows.length === 0) {
        Text('暂无档案：请先导入订阅（URL 或粘贴文本）')
          .fontSize(12)
          .fontColor(T.dim)
          .width('100%')
      } else {
        ForEach(this.rows, (p: Profile) => {
          this.ProfileRow(p);
        }, (p: Profile) => `${p.id}-${p.updatedAt}-${p.id === ProfileStore.activeId() ? 'a' : ''}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  ProfileRow(p: Profile) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(p.name)
          .fontSize(14)
          .fontColor(T.text)
          .fontWeight(p.id === ProfileStore.activeId() ? FontWeight.Bold : FontWeight.Normal)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (p.id === ProfileStore.activeId()) {
          Text('使用中')
            .fontSize(10)
            .fontColor(T.accent)
            .backgroundColor(T.accentSoft)
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        }
      }
      .width('100%')

      Text(`${p.nodes.length} 节点 · ${p.kind} · ${timeText(p.updatedAt)}${p.url !== '' ? ' · 可刷新' : ' · 粘贴导入'}`)
        .fontSize(11)
        .fontColor(T.dim)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 8 }) {
        Button(p.id === ProfileStore.activeId() ? '已启用' : '启用')
          .height(32)
          .fontSize(12)
          .backgroundColor(p.id === ProfileStore.activeId() ? T.track : T.accentSoft)
          .fontColor(p.id === ProfileStore.activeId() ? T.dim : T.accent)
          .enabled(p.id !== ProfileStore.activeId())
          .onClick(() => {
            ProfileStore.activate(p.id);
            TunnelManager.onProfileChanged();
            this.feedbackOk = true;
            this.feedback = `已切换到「${p.name}」`;
          })
        Button('刷新')
          .height(32)
          .fontSize(12)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .enabled(!this.busy && p.url !== '')
          .onClick(() => {
            this.doRefresh(p);
          })
        Button('删除')
          .height(32)
          .fontSize(12)
          .backgroundColor(T.track)
          .fontColor(T.err)
          .onClick(() => {
            ProfileStore.remove(p.id);
            TunnelManager.onProfileChanged();
            this.feedbackOk = true;
            this.feedback = `已删除「${p.name}」`;
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .backgroundColor(T.panel)
    .borderRadius(T.radiusS)
  }

  private doUrlImport(): void {
    const url = this.url.trim();
    if (url === '') {
      this.feedbackOk = false;
      this.feedback = '请先填写订阅链接';
      return;
    }
    this.busy = true;
    this.feedback = '下载中…';
    this.feedbackOk = true;
    ProfileStore.importUrl(url, '').then((res) => {
      this.busy = false;
      this.feedbackOk = res.ok;
      if (res.ok) {
        this.feedback = `导入成功：${res.nodes.length} 个节点（${res.kind}）`;
        this.url = '';
        TunnelManager.onProfileChanged();
      } else {
        this.feedback = `导入失败：${res.error}`;
      }
    });
  }

  private doPasteImport(): void {
    const text = this.pasteText;
    if (text.trim() === '') {
      this.feedbackOk = false;
      this.feedback = '粘贴内容为空';
      return;
    }
    this.busy = true;
    const res = ProfileStore.importText(text, '', '');
    this.busy = false;
    this.feedbackOk = res.ok;
    if (res.ok) {
      this.feedback = `导入成功：${res.nodes.length} 个节点（${res.kind}）`;
      this.pasteText = '';
      TunnelManager.onProfileChanged();
    } else {
      this.feedback = `导入失败：${res.error}`;
    }
  }

  private doRefresh(p: Profile): void {
    this.busy = true;
    this.feedback = `刷新「${p.name}」中…`;
    this.feedbackOk = true;
    ProfileStore.refresh(p.id).then((res) => {
      this.busy = false;
      this.feedbackOk = res.ok;
      if (res.ok) {
        this.feedback = `刷新成功：${res.nodes.length} 个节点`;
        TunnelManager.onProfileChanged();
      } else {
        this.feedback = `刷新失败：${res.error}`;
      }
    });
  }
}

function timeText(ts: number): string {
  const d = new Date(ts);
  const mm = d.getMonth() + 1;
  const dd = d.getDate();
  const hh = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
  const mi = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
  return `${mm}-${dd} ${hh}:${mi}`;
}