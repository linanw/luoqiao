import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { setTunnelRecoveryForeground } from '../model/TunnelRecovery';

export default class EntryAbility extends UIAbility {
  onForeground(): void { setTunnelRecoveryForeground(this.context, true); }
  onBackground(): void { setTunnelRecoveryForeground(this.context, false); }
  onDestroy(): void { setTunnelRecoveryForeground(this.context, false); }
  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/NetworksPage');
  }
}
