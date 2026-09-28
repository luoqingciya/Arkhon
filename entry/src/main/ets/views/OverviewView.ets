/**
 * M2 · 总览页：隧道一键启停 + 运行态（档案/当前节点/保活）+ 最近事件
 */
import { TunnelManager, KEY_STATE, KEY_MESSAGE, KEY_PROFILE, KEY_NODE, KEY_KEEP, KEY_LOGS } from '../core/TunnelManager';
import { TunnelState } from '../model/Types';
import { T } from './Theme';

@Component
export struct OverviewView {
  @StorageLink(KEY_STATE) tunnelState: number = TunnelState.Stopped;
  @StorageLink(KEY_MESSAGE) message: string = '';
  @StorageLink(KEY_PROFILE) profile: string = '—';
  @StorageLink(KEY_NODE) currentNode: string = '—';
  @StorageLink(KEY_KEEP) keepInfo: string = '';
  @StorageLink(KEY_LOGS) logs: string[] = [];
  @State busy: boolean = false;

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.StatusCard()
        this.ActionBar()
        this.InfoCard()
        this.LogCard()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  StatusCard() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Circle({ width: 12, height: 12 })
          .fill(this.stateColor())
        Text(this.stateText())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(T.text)
        Blank()
        Text(this.tunnelState === TunnelState.Running ? 'VPN 全量接管' : '')
          .fontSize(11)
          .fontColor(T.dim)
      }
      .width('100%')

      Text(this.message)
        .fontSize(12)
        .fontColor(T.sub)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  ActionBar() {
    Row({ space: 10 }) {
      Button(this.tunnelState === TunnelState.Running || this.tunnelState === TunnelState.Starting
        ? '断开隧道' : '启动隧道')
        .layoutWeight(1)
        .height(46)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.tunnelState === TunnelState.Running ? T.track : T.accent)
        .fontColor(this.tunnelState === TunnelState.Running ? T.err : '#0b1220')
        .enabled(!this.busy)
        .onClick(() => {
          this.toggleTunnel();
        })
      Button('刷新状态')
        .width(100)
        .height(46)
        .fontSize(14)
        .backgroundColor(T.track)
        .fontColor(T.text)
        .onClick(() => {
          TunnelManager.monitorOnce();
          TunnelManager.log('[UI] 手动自检已触发');
        })
    }
    .width('100%')
  }

  @Builder
  InfoCard() {
    Column({ space: 6 }) {
      Row() {
        Text('当前档案')
          .fontSize(13)
          .fontColor(T.dim)
          .width(72)
        Text(this.profile)
          .fontSize(13)
          .fontColor(T.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Row() {
        Text('当前节点')
          .fontSize(13)
          .fontColor(T.dim)
          .width(72)
        Text(this.currentNode)
          .fontSize(13)
          .fontColor(T.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Row() {
        Text('保活')
          .fontSize(13)
          .fontColor(T.dim)
          .width(72)
        Text(this.keepInfo !== '' ? this.keepInfo : '未启动')
          .fontSize(13)
          .fontColor(T.text)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  LogCard() {
    Column({ space: 4 }) {
      Text('最近事件')
        .fontSize(13)
        .fontColor(T.dim)
        .width('100%')
      if (this.logs.length === 0) {
        Text('（暂无）')
          .fontSize(12)
          .fontColor(T.dim)
          .width('100%')
      } else {
        ForEach(this.logs.slice(0, 10), (line: string) => {
          Text(line)
            .fontSize(11)
            .fontColor(T.sub)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }, (line: string, idx: number) => `${idx}-${line}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  private toggleTunnel(): void {
    this.busy = true;
    if (this.tunnelState === TunnelState.Running || this.tunnelState === TunnelState.Starting) {
      TunnelManager.stop().then(() => {
        this.busy = false;
      });
    } else {
      TunnelManager.start().then(() => {
        this.busy = false;
      });
    }
  }

  private stateText(): string {
    if (this.tunnelState === TunnelState.Running) {
      return '已连接';
    }
    if (this.tunnelState === TunnelState.Starting) {
      return '连接中…';
    }
    if (this.tunnelState === TunnelState.Error) {
      return '异常';
    }
    return '未启动';
  }

  private stateColor(): string {
    if (this.tunnelState === TunnelState.Running) {
      return T.ok;
    }
    if (this.tunnelState === TunnelState.Starting) {
      return T.warn;
    }
    if (this.tunnelState === TunnelState.Error) {
      return T.err;
    }
    return T.dim;
  }
}