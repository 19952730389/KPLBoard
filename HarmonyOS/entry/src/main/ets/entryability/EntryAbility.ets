/* 应用入口：负责把「屏幕到底多大、哪里不能放内容」告诉页面
 * ---------------------------------------------------------------------------
 * 两件事：
 *  1) 沉浸式铺满整屏，然后量出：窗口 vp 尺寸、屏幕密度、顶部挖孔/状态栏高度、
 *     底部手势条高度，全部写进 AppStorage；页面用 @StorageLink 订阅后自动重排。
 *  2) 监听 windowSizeChange / avoidAreaChange —— 横竖屏、分屏、折叠屏开合、
 *     手势条隐藏都会触发，保证任何形态下都不顶挖孔、不被手势条压住。
 *
 * 单位说明：系统 API 给的是 px，UI 用的是 vp，必须除以 densityPixels 换算。
 */
import { UIAbility, AbilityConstant, Want, ConfigurationConstant, Configuration } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { display } from '@kit.ArkUI';
import { DeviceEnv } from '../common/DeviceEnv';
import { Theme } from '../common/Theme';
import { NetStore } from '../data/NetStore';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 这两项要持久化：主题选择与联网接口基址（必须在任何 AppStorage 读写之前注册）
    PersistentStorage.persistProp<string>(Theme.K_MODE, 'dark');
    PersistentStorage.persistProp<string>(NetStore.K_BASE, NetStore.DEFAULT_BASE);
    // 悬浮层材质与光感档位同样落盘
    PersistentStorage.persistProp<string>('ui.navMaterial', 'glass');
    PersistentStorage.persistProp<string>('ui.navLevel', 'balanced');

    AppStorage.setOrCreate(DeviceEnv.K_WIDTH, 360);
    AppStorage.setOrCreate(DeviceEnv.K_HEIGHT, 800);
    AppStorage.setOrCreate(DeviceEnv.K_BP, 'sm');
    AppStorage.setOrCreate(DeviceEnv.K_DPR, 2);
    AppStorage.setOrCreate(DeviceEnv.K_PORTRAIT, true);
    AppStorage.setOrCreate(DeviceEnv.K_SAFE_TOP, 0);
    AppStorage.setOrCreate(DeviceEnv.K_SAFE_BOTTOM, 0);
    AppStorage.setOrCreate(DeviceEnv.K_SAFE_LEFT, 0);
    AppStorage.setOrCreate(DeviceEnv.K_SAFE_RIGHT, 0);
    AppStorage.setOrCreate(Theme.K_SYS, 'dark');

    Theme.init();      // 恢复上次的外观选择
    this.recordSystemColorMode();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    try {
      NetStore.init(this.context); // 恢复上次联网成功的缓存
    } catch (e) {
      /* 拿不到目录就纯离线，不影响启动 */
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        return;
      }
      try {
        this.mainWindow = windowStage.getMainWindowSync();
        // 沉浸式：内容铺到状态栏与手势条之下，避让交给页面的 safeTop/safeBottom
        this.mainWindow.setWindowLayoutFullScreen(true);
        this.measure();
        this.mainWindow.on('windowSizeChange', () => this.measure());
        this.mainWindow.on('avoidAreaChange', () => this.measure());
      } catch (e) {
        /* 量不出来就按默认值，页面仍有兜底 */
      }
    });
  }

  /** 系统深浅色 → AppStorage['sys.colorMode']（「跟随系统」模式据此解析） */
  private recordSystemColorMode(): void {
    try {
      const cm = this.context.config.colorMode;
      AppStorage.setOrCreate(Theme.K_SYS, cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light');
    } catch (e) {
      AppStorage.setOrCreate(Theme.K_SYS, 'dark');
    }
  }

  /** 返回手势（左/右边缘侧滑、返回键）：
   *  设置页浮层打开时 → 只关浮层回主页（返回 true 表示应用自行处理，不退出）；
   *  已回到主页 → 返回 false，走系统默认行为（退出 App）。
   *  Index 页面已实现同逻辑，这里是兜底，防止页面未收到事件时直接退出。 */
  onBackPress(): boolean {
    const open = AppStorage.get<boolean>('ui.settingsOpen');
    if (open === true) {
      AppStorage.setOrCreate('ui.settingsOpen', false);
      return true;
    }
    return false;
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    try {
      AppStorage.setOrCreate(
        Theme.K_SYS,
        newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? 'dark' : 'light'
      );
      Theme.syncSystem(); // 只有「跟随系统」需要重算调色板
    } catch (e) {
      /* 忽略 */
    }
  }

  private measure(): void {
    const win = this.mainWindow;
    if (!win) {
      return;
    }
    try {
      const dpr: number = display.getDefaultDisplaySync().densityPixels || 1;
      const rect = win.getWindowProperties().windowRect;
      const wVp: number = Math.round(rect.width / dpr);
      const hVp: number = Math.round(rect.height / dpr);
      AppStorage.setOrCreate(DeviceEnv.K_WIDTH, wVp);
      AppStorage.setOrCreate(DeviceEnv.K_HEIGHT, hVp);
      AppStorage.setOrCreate(DeviceEnv.K_BP, DeviceEnv.bpOf(wVp));
      AppStorage.setOrCreate(DeviceEnv.K_DPR, dpr);
      AppStorage.setOrCreate(DeviceEnv.K_PORTRAIT, hVp >= wVp);

      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const cut = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      const top: number = Math.max(sys.topRect.height, cut.topRect.height);
      AppStorage.setOrCreate(DeviceEnv.K_SAFE_TOP, Math.round(top / dpr));
      AppStorage.setOrCreate(DeviceEnv.K_SAFE_BOTTOM, Math.round(nav.bottomRect.height / dpr));
      AppStorage.setOrCreate(DeviceEnv.K_SAFE_LEFT, Math.round(sys.leftRect.width / dpr));
      AppStorage.setOrCreate(DeviceEnv.K_SAFE_RIGHT, Math.round(sys.rightRect.width / dpr));
    } catch (e) {
      /* 忽略：页面会退回默认留白 */
    }
  }

  onWindowStageDestroy(): void {
    try {
      this.mainWindow?.off('windowSizeChange');
      this.mainWindow?.off('avoidAreaChange');
    } catch (e) {
      /* 忽略 */
    }
  }

  onDestroy(): void {
    /* 无后台常驻逻辑 */
  }
}
