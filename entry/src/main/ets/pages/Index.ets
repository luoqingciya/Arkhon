/**
 * 应用外壳：双形态骨架 + API 26 悬浮导航 / 沉浸光感
 *
 * 形态：
 *  - Phone（<840vp）：底部导航 + 单列内容；
 *  - Tablet / 折叠屏展开态（≥840vp）：侧边栏导航 + 内容区。
 *
 * 沉浸光感（液态玻璃，两条官方轨并用，互不混参）：
 *  - 悬浮导航（HDS 轨）：HdsTabs + barFloatingStyle，材质档位取
 *    hdsMaterial.MaterialType.ADAPTIVE / hdsMaterial.MaterialLevel.ADAPTIVE（系统按设备算力自适应选档）；
 *  - 壳层玻璃（ArkUI 轨）：顶栏与侧边栏用 `systemMaterial(T.glass())`（uiMaterial.ImmersiveStyle.ULTRA_THIN）。
 *  两轨同名 MaterialLevel 语义不同（HDS 可选策略 vs uiMaterial 设备算力只读），不可互换。
 *
 * 视图与状态经 AppStorage（TunnelManager/ProfileStore 发布）联动。
 */
import { mediaquery, window } from '@kit.ArkUI';
import { HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { OverviewView } from '../views/OverviewView';
import { ProfilesView } from '../views/ProfilesView';
import { ProxiesView } from '../views/ProxiesView';
import { SettingsView } from '../views/SettingsView';
import { T } from '../views/Theme';

const WIDE_QUERY = '(min-width: 840vp)';
/** 悬浮页签占位高度：内容底部留白，避免被悬浮条遮挡（条高 + barBottomMargin + 余量） */
const FLOATING_BAR_SPACE = 96;
/** AppStorage 键：状态栏高度（vp），沉浸全屏后由壳层自行补偿 */
const KEY_INSET_TOP = 'insetTop';

@Entry
@Component
struct Index {
  @State isWide: boolean = false;
  @State navIndex: number = 0;
  @StorageLink(KEY_INSET_TOP) insetTop: number = 0;
  private mq: mediaquery.MediaQueryListener | null = null;
  private tabsCtrl: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    const mq = mediaquery.matchMediaSync(WIDE_QUERY);
    this.isWide = mq.matches;
    mq.on('change', (result: mediaquery.MediaQueryResult) => {
      this.isWide = result.matches;
    });
    this.mq = mq;
    this.loadSafeInsets();
  }

  /** 沉浸全屏后系统状态栏不再占位：读避让区高度补偿顶栏（底部由悬浮页签自然避让） */
  private loadSafeInsets(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window) => {
        const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        AppStorage.setOrCreate(KEY_INSET_TOP, this.getUIContext().px2vp(area.topRect.height));
      }).catch((e: BusinessError) => {
        // 取不到避让区时保留默认 0：极端情况下顶栏会被状态栏覆盖，不影响功能
      });
    } catch (e) {
      // ignore
    }
  }

  aboutToDisappear(): void {
    if (this.mq !== null) {
      this.mq.off('change');
      this.mq = null;
    }
  }

  build() {
    Column() {
      if (this.isWide) {
        this.TabletLayout()
      } else {
        this.PhoneLayout()
      }
    }
    .width('100%')
    .height('100%')
    // 深空渐变底：给玻璃面提供可折射的内容；底部压暗，保证悬浮页签与文字对比度
    .linearGradient({
      angle: 155,
      colors: [['#12203a', 0.0], ['#0d1424', 0.52], ['#0a0f1a', 1.0]]
    })
    // 沉浸系统栏：绘制扩展到状态栏与底部手势条区域（内容布局仍避让安全区）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ---------------------------------------------------------------- Phone

  @Builder
  PhoneLayout() {
    Column() {
      this.TopBar()
      HdsTabs({ controller: this.tabsCtrl, index: this.navIndex }) {
        TabContent() {
          Column() {
            OverviewView()
          }
          .width('100%')
          .height('100%')
          .padding({ bottom: FLOATING_BAR_SPACE })
        }.tabBar(this.BarItem('总览', 0))

        TabContent() {
          Column() {
            ProfilesView()
          }
          .width('100%')
          .height('100%')
          .padding({ bottom: FLOATING_BAR_SPACE })
        }.tabBar(this.BarItem('订阅', 1))

        TabContent() {
          Column() {
            ProxiesView()
          }
          .width('100%')
          .height('100%')
          .padding({ bottom: FLOATING_BAR_SPACE })
        }.tabBar(this.BarItem('节点', 2))

        TabContent() {
          Column() {
            SettingsView()
          }
          .width('100%')
          .height('100%')
          .padding({ bottom: FLOATING_BAR_SPACE })
        }.tabBar(this.BarItem('设置', 3))
      }
      .layoutWeight(1)
      .barPosition(BarPosition.End)
      // 悬浮页签：内容从条下穿过（底部已留白），材质由系统自适应
      .barOverlap(true)
      .barFloatingStyle({
        // 抬离手势条：避免小白条贴着胶囊底沿
        barBottomMargin: 28,
        adaptToHandedness: true,
        // 页签下方的渐隐遮罩：渐变底最亮处不会顶到玻璃，保证图标/文字可读
        gradientMask: {
          maskColor: '#B30A0F1A',
          maskHeight: 132
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .scrollable(false)
      .onChange((index: number) => {
        this.navIndex = index;
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  BarItem(title: string, idx: number) {
    Column({ space: 2 }) {
      SymbolGlyph(NavIcons.of(idx))
        .fontSize(24)
        .fontColor([this.navIndex === idx ? T.accent : T.sub])
      Text(title)
        .fontSize(10)
        .fontWeight(this.navIndex === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.navIndex === idx ? T.accent : T.sub)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
  }

  // ---------------------------------------------------------------- Tablet

  @Builder
  TabletLayout() {
    Row() {
      Column({ space: 6 }) {
        Text('Arkhon')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(T.text)
          .margin({ bottom: 10 })
        this.SideItem('总览', 0)
        this.SideItem('订阅', 1)
        this.SideItem('节点', 2)
        this.SideItem('设置', 3)
        Blank()
        Text('悬浮导航 · 液态玻璃')
          .fontSize(10)
          .fontColor(T.dim)
      }
      .width(184)
      .height('100%')
      .padding({ left: 14, right: 14, bottom: 14, top: 14 + this.insetTop })
      // 半透明面板底：整条侧栏（含状态栏区域）统一，材质可用时被玻璃接管
      .backgroundColor('#B3121720')
      .systemMaterial(T.glass())
      .alignItems(HorizontalAlign.Start)

      Column() {
        this.TopBar()
        this.Content()
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  SideItem(title: string, idx: number) {
    Row({ space: 10 }) {
      SymbolGlyph(NavIcons.of(idx))
        .fontSize(20)
        .fontColor([this.navIndex === idx ? T.accent : T.sub])
      Text(title)
        .fontSize(14)
        .fontWeight(this.navIndex === idx ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.navIndex === idx ? T.accent : T.sub)
    }
    .width('100%')
    .height(42)
    .padding({ left: 12 })
    .backgroundColor(this.navIndex === idx ? T.accentSoft : Color.Transparent)
    .borderRadius(T.radiusS)
    .onClick(() => {
      this.navIndex = idx;
      // 形态切换时让 HdsTabs 索引跟随（未渲染时调用无效，忽略即可）
      if (!this.isWide) {
        this.tabsCtrl.changeIndex(idx);
      }
    })
  }

  @Builder
  Content() {
    Column() {
      if (this.navIndex === 0) {
        OverviewView()
      } else if (this.navIndex === 1) {
        ProfilesView()
      } else if (this.navIndex === 2) {
        ProxiesView()
      } else {
        SettingsView()
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  // ---------------------------------------------------------------- 公共

  @Builder
  TopBar() {
    Row() {
      Text(this.isWide ? '控制台' : 'Arkhon')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(T.text)
      Blank()
      Text(this.navTitle())
        .fontSize(12)
        .fontColor(T.dim)
    }
    .width('100%')
    .height(48 + this.insetTop)
    .padding({ left: 16, right: 16, top: this.insetTop })
    // 不设底色：材质可用时是玻璃，不可用时透出页面渐变，避免顶部出现横向色带
    .systemMaterial(T.glass())
  }

  private navTitle(): string {
    if (this.navIndex === 0) {
      return '总览';
    }
    if (this.navIndex === 1) {
      return '订阅';
    }
    if (this.navIndex === 2) {
      return '节点与策略组';
    }
    return '设置';
  }
}

/** 导航图标（系统符号库；换图标只改这里） */
class NavIcons {
  static of(idx: number): Resource {
    if (idx === 0) {
      return $r('sys.symbol.house');
    }
    if (idx === 1) {
      return $r('sys.symbol.square_and_pencil');
    }
    if (idx === 2) {
      return $r('sys.symbol.ohos_wifi');
    }
    return $r('sys.symbol.gearshape');
  }
}