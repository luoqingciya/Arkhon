import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ProfileStore } from '../core/ProfileStore';
import { TunnelManager } from '../core/TunnelManager';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // M2：档案库与隧道服务在 UI 之前就绪（AppStorage 状态键随之建立）
    try {
      ProfileStore.init(this.context);
      TunnelManager.init(this.context);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'M2 初始化失败: %{public}s', JSON.stringify(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    // 沉浸式系统栏：状态栏/导航条透明 + 浅色图标，页面渐变经 expandSafeArea 铺满两端，消除上下色差
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, 'testTag', 'setWindowLayoutFullScreen 失败 code=%{public}d', e.code);
      });
      const props: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        statusBarContentColor: '#FFFFFF',
        navigationBarColor: '#00000000',
        navigationBarContentColor: '#FFFFFF'
      };
      win.setWindowSystemBarProperties(props).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, 'testTag', 'setWindowSystemBarProperties 失败 code=%{public}d', e.code);
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', '设置沉浸系统栏失败: %{public}s', JSON.stringify(err));
    }

    try {
      // 全暗色 UI（提瓦特暗色玻璃拟态）：声明应用级深色模式，
      // 系统材质（HdsTabs 悬浮条 / 系统弹层）随深色渲染，避免浅灰玻璃与暗色主题割裂
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}