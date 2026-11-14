import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { readLegacyNetworkProfile } from '../model/MixedConnections';

// Preserve the old route while using the same editor for every Tailnet identity.
@Entry
@Component
struct TailnetPage {
  @State private error: string = '';
  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const legacy = readLegacyNetworkProfile(context.filesDir);
    router.replaceUrl({ url: 'pages/TunnelEditorPage', params: { profileId: legacy ? 'legacy' : '' } })
      .catch((e: Error) => this.error = e.message);
  }
  build() {
    Column({ space: 16 }) {
      Text('Tailnet 连接').fontSize(30).fontWeight(FontWeight.Bold).fontColor('#172033')
      Text(this.error || '正在打开连接管理…').fontSize(14).fontColor('#728097')
      Button('返回连接列表', { type: ButtonType.Normal }).height(44).fontSize(14)
        .fontColor('#315EFB').backgroundColor('#EEF2FF').borderRadius(12).onClick(() => router.back())
    }.padding(24).width('100%').height('100%').backgroundColor('#F4F6FA')
  }
}
