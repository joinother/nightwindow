import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info('EntryAbility onCreate');
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (e) {
      Logger.error('setColorMode failed');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error('loadContent failed: ' + JSON.stringify(err));
        return;
      }
      this.applyImmersive(windowStage);
    });
  }

  /** 沉浸式：内容延伸到状态栏/导航栏下方，状态栏图标转浅色 */
  private applyImmersive(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        Logger.info('full screen ok');
      }).catch((e: BusinessError) => {
        Logger.error('setWindowLayoutFullScreen failed: ' + e.message);
      });

      // 平板窗口场景下系统不会采用应用的状态栏配色，直接隐藏，由页面自绘时间
      win.setWindowSystemBarEnable(['navigation']).then(() => {
        Logger.info('system bar: navigation kept');
      }).catch((e: BusinessError) => {
        Logger.error('setWindowSystemBarEnable failed: ' + e.message);
      });
    } catch (e) {
      Logger.error('applyImmersive failed: ' + JSON.stringify(e));
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info('EntryAbility onNewWant');
  }

  onDestroy(): void {
    Logger.info('EntryAbility onDestroy');
  }
}
