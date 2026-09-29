/**
 * M2 · 设置页：保活状态 · 诊断（T2/T3 回归路径保留）· 日志 · 关于
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import goNative, { GoHelloResult, ClashVersionResult } from 'libentry.so';
import { AudioKeepAlive } from '../common/AudioKeepAlive';
import { KernelRest } from '../core/KernelRest';
import { ProfileStore } from '../core/ProfileStore';
import { RulePreset, RULE_PRESETS } from '../core/RulePresets';
import { TunnelManager, KEY_KEEP, KEY_LOGS } from '../core/TunnelManager';
import { T } from './Theme';

const DOMAIN = 0x0000;
const TAG = 'Settings';

@Component
export struct SettingsView {
  @StorageLink(KEY_KEEP) keepInfo: string = '';
  @StorageLink(KEY_LOGS) logs: string[] = [];
  @State diag: string[] = [];
  @State audioOn: boolean = false;
  @State presetIds: string[] = [];

  aboutToAppear(): void {
    this.presetIds = ProfileStore.rulePresetIds();
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.KeepCard()
        this.PresetCard()
        this.DiagCard()
        this.LogCard()
        this.AboutCard()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  @Builder
  PresetCard() {
    Column({ space: 10 }) {
      Text('分流预设')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.text)
        .width('100%')
      Text('内置离线域名规则集（不依赖 geoip 数据）；开启/关闭会热重载内核配置。规则顺序：广告拦截 → 国内直连 → 流媒体 → AI → MATCH 兜底。')
        .fontSize(11)
        .fontColor(T.dim)
        .width('100%')
      ForEach(RULE_PRESETS, (p: RulePreset) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(p.label)
              .fontSize(13)
              .fontColor(T.text)
              .width('100%')
            Text(`${p.desc} · ${p.domains.length} 条 → ${p.policy}`)
              .fontSize(10)
              .fontColor(T.dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.isPresetOn(p.id) })
            .onChange((on: boolean) => {
              this.togglePreset(p.id, on);
            })
        }
        .width('100%')
        .padding(10)
        .backgroundColor(T.panel)
        .borderRadius(T.radiusS)
      }, (p: RulePreset) => p.id)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  KeepCard() {
    Column({ space: 8 }) {
      Text('保活（长时任务 + 常驻通知）')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.text)
        .width('100%')
      Text(this.keepInfo !== '' ? this.keepInfo : '未启动')
        .fontSize(12)
        .fontColor(T.sub)
        .width('100%')
      Text('隧道运行时由系统挂常驻通知；被回收后自动重申请（T3 实测结论：取消即重申请）。')
        .fontSize(11)
        .fontColor(T.dim)
        .width('100%')
      Row({ space: 8 }) {
        Button('保活自检')
          .height(36)
          .fontSize(12)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .onClick(() => {
            TunnelManager.monitorOnce();
            this.push('已触发一次自检（结果见总览/日志）');
          })
        Button(this.audioOn ? '深度保活：开' : '深度保活：关')
          .height(36)
          .fontSize(12)
          .backgroundColor(this.audioOn ? T.accentSoft : T.track)
          .fontColor(this.audioOn ? T.accent : T.dim)
          .onClick(() => {
            this.toggleAudio();
          })
      }
      .width('100%')
      Text('深度保活（静音音频）已被系统静音检测反制，默认关闭，仅保留回归验证。')
        .fontSize(11)
        .fontColor(T.dim)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  DiagCard() {
    Column({ space: 8 }) {
      Text('诊断（T2/T3 回归）')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.text)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('Go .so 加载(T2)')
          .height(34)
          .fontSize(12)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.runGoProbe();
          })
        Button('内核版本(T3)')
          .height(34)
          .fontSize(12)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.runKernelVersion();
          })
        Button('扩展内核探测')
          .height(34)
          .fontSize(12)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.probeExtKernel();
          })
        Button('连通性诊断')
          .height(34)
          .fontSize(12)
          .backgroundColor(T.track)
          .fontColor(T.text)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.probeTargets();
          })
      }
      .width('100%')

      if (this.diag.length > 0) {
        Column({ space: 3 }) {
          ForEach(this.diag, (line: string) => {
            Text(line)
              .fontSize(11)
              .fontColor(T.sub)
              .width('100%')
          }, (line: string, idx: number) => `${idx}-${line}`)
        }
        .width('100%')
      }
      Text(`数据目录：${ProfileStore.storePath() !== '' ? ProfileStore.storePath() : '（未初始化）'}`)
        .fontSize(10)
        .fontColor(T.dim)
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
    Column({ space: 6 }) {
      Row() {
        Text(`运行日志（${this.logs.length}）`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(T.text)
          .layoutWeight(1)
        Text('保留最近 60 条')
          .fontSize(10)
          .fontColor(T.dim)
      }
      .width('100%')
      if (this.logs.length === 0) {
        Text('（暂无）')
          .fontSize(12)
          .fontColor(T.dim)
          .width('100%')
      } else {
        ForEach(this.logs, (line: string) => {
          Text(line)
            .fontSize(11)
            .fontColor(T.sub)
            .width('100%')
        }, (line: string, idx: number) => `${idx}-${line}`)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  @Builder
  AboutCard() {
    Column({ space: 6 }) {
      Text('关于')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.text)
        .width('100%')
      Text('Arkhon（鸿蒙版） · M2 骨架已落地')
        .fontSize(12)
        .fontColor(T.sub)
        .width('100%')
      Text('内核：arkhon-core（mihomo fork）c-shared .so，与本仓库同源发布；GPL-3.0。')
        .fontSize(11)
        .fontColor(T.dim)
        .width('100%')
      Text('节点凭据仅存本机沙箱；日志导出前将做脱敏（M3 落地）。')
        .fontSize(11)
        .fontColor(T.dim)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(T.card)
    .borderRadius(T.radius)
    .border({ width: 1, color: T.cardBorder })
  }

  // ---------------------------------------------------------------- 动作

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private push(line: string): void {
    this.diag.unshift(`[${timeLabel()}] ${line}`);
    if (this.diag.length > 12) {
      this.diag.pop();
    }
    TunnelManager.log(line);
  }

  private runGoProbe(): void {
    try {
      const r: GoHelloResult = goNative.loadGoHello();
      this.push(`[T2] loaded=${r.loaded} hello="${r.hello}" add=${r.add} probe=${r.probe} err="${r.err}"`);
    } catch (e) {
      const err = e as BusinessError;
      this.push(`[T2] loadGoHello 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private runKernelVersion(): void {
    try {
      const v: ClashVersionResult = goNative.clashVersion();
      this.push(`[T3] libclash loaded=${v.loaded} version="${v.version}" err="${v.err}"`);
      hilog.info(DOMAIN, TAG, 'clashVersion loaded=%{public}d version=%{public}s',
        v.loaded ? 1 : 0, v.version);
    } catch (e) {
      const err = e as BusinessError;
      this.push(`[T3] clashVersion 异常 code=${err.code} msg=${err.message}`);
    }
  }

  private probeExtKernel(): void {
    KernelRest.version().then((v: string) => {
      this.push(v !== '' ? `扩展内核 /version → ${v}` : '扩展内核不可达（隧道未启动或正在重建）');
    });
  }

  private probeTargets(): void {
    this.push('连通性诊断中（gstatic / google.com / example.com）…');
    TunnelManager.probeTargets().then((summary: string) => {
      this.push(`诊断结果：${summary}`);
    });
  }

  private toggleAudio(): void {
    if (!this.audioOn) {
      AudioKeepAlive.start(this.ctx()).then((msg: string) => {
        this.audioOn = AudioKeepAlive.isOn();
        this.push(`[保活增强] ${msg}`);
      });
    } else {
      AudioKeepAlive.stop(this.ctx()).then((msg: string) => {
        this.audioOn = AudioKeepAlive.isOn();
        this.push(`[保活增强] ${msg}`);
      });
    }
  }

  private isPresetOn(id: string): boolean {
    return this.presetIds.indexOf(id) >= 0;
  }

  private togglePreset(id: string, on: boolean): void {
    if (this.isPresetOn(id) === on) {
      return; // 忽略 isOn 初值/程序化触发的重复回调
    }
    const next: string[] = [];
    for (const pid of this.presetIds) {
      if (pid !== id) {
        next.push(pid);
      }
    }
    if (on) {
      next.push(id);
    }
    this.presetIds = next;
    ProfileStore.setRulePresets(next);
    TunnelManager.onRulesChanged();
    this.push(`[分流] 预设「${id}」${on ? '开启' : '关闭'}（当前启用 ${next.length} 项）`);
  }
}

function timeLabel(): string {
  const d = new Date();
  const hh = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
  const mm = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
  const ss = d.getSeconds() < 10 ? `0${d.getSeconds()}` : `${d.getSeconds()}`;
  return `${hh}:${mm}:${ss}`;
}