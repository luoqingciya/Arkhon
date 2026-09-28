/**
 * UI 主题常量 + 沉浸光感材质（提瓦特深色玻璃拟态；亮色主题 M3）
 *
 * 沉浸光感（液态玻璃）走 API 26 的 ArkUI uiMaterial 轨：
 *  - 应用级开关：module.json5 metadata `ohos.arkui.UIMaterial.state = enable`；
 *  - 组件级：`systemMaterial(T.glass())`，style 用 ImmersiveStyle.ULTRA_THIN（最强通透感）；
 *  - 注意：材质生效后会接管组件的 backgroundColor / borderWidth，自绘背景不再叠加；
 *  - 设备不支持时 glass() 返回 undefined，组件保留自绘样式（先探测再归因）。
 *
 * 悬浮导航走 HDS 轨（见 pages/Index.ets）：HdsTabs + barFloatingStyle，
 * 材质档位用 hdsMaterial.MaterialLevel.ADAPTIVE（由系统按设备算力自适应选档）。
 */
import { uiMaterial } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'Theme';

export class T {
  static readonly bg: string = '#0d1017';
  static readonly panel: string = '#141a24';
  static readonly card: string = '#161d29';
  static readonly cardBorder: string = '#26303f';
  static readonly track: string = '#1d2532';
  static readonly text: string = '#e9eef7';
  static readonly sub: string = '#98a4b8';
  static readonly dim: string = '#6b7688';
  static readonly accent: string = '#6d9eff';
  static readonly accentSoft: string = '#1b2a45';
  static readonly ok: string = '#3ddc97';
  static readonly warn: string = '#ffb454';
  static readonly err: string = '#ff6b6b';
  static readonly radius: number = 14;
  static readonly radiusS: number = 10;

  private static glassInited: boolean = false;
  private static glassMat: uiMaterial.Material | undefined = undefined;

  /** 液态玻璃材质（缓存实例）；设备不支持沉浸材质时返回 undefined */
  static glass(): uiMaterial.Material | undefined {
    if (!T.glassInited) {
      T.glassInited = true;
      const supported: boolean = uiMaterial.isImmersiveMaterialSupported();
      hilog.info(DOMAIN, TAG, 'uiMaterial supported=%{public}d level=%{public}d',
        supported ? 1 : 0, uiMaterial.getGlobalMaterialLevel());
      if (supported) {
        T.glassMat = new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          // 壳层玻璃不加投影：暗色渐变底上材质阴影会形成横向分界线
          applyShadow: false,
          interactive: true
        });
      }
    }
    return T.glassMat;
  }
}