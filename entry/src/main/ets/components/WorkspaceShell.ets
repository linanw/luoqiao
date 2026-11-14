import { router } from '@kit.ArkUI';
import { registerWorkspaceDrawer, releaseWorkspaceDrawer } from '../model/WorkspaceNavigation';

@Builder
function emptyWorkspaceContent() {}

@Component
export struct WorkspaceShell {
  @Prop active: string = 'tunnels';
  @Prop title: string = '络桥';
  @Prop navigationLocked: boolean = false;
  @BuilderParam content: () => void = emptyWorkspaceContent;
  @State private viewportWidth: number = 0;
  @State private drawerOpen: boolean = false;
  private dismiss: () => void = () => this.closeDrawer();

  aboutToDisappear(): void { this.closeDrawer(); }
  private compact(): boolean { return this.viewportWidth < 600; }
  private rail(): boolean { return this.viewportWidth >= 600 && this.viewportWidth < 960; }
  private closeDrawer(): void {
    this.drawerOpen = false;
    releaseWorkspaceDrawer(this.dismiss);
  }
  private openDrawer(): void {
    this.drawerOpen = true;
    registerWorkspaceDrawer(this.dismiss);
  }
  private navigate(key: string, page: string): void {
    if (this.navigationLocked) { return; }
    this.closeDrawer();
    if (this.active !== key || this.title !== this.pageTitle(key)) {
      router.replaceUrl({ url: page });
    }
  }
  private pageTitle(key: string): string {
    switch (key) {
      case 'domains': return '域名库';
      case 'rules': return '自定义规则';
      case 'groups': return '地址组';
      case 'checker': return '路由检查';
      case 'subnets': return '重叠网段';
      case 'diagnostics': return '运行诊断';
      default: return '连接';
    }
  }

  @Builder
  private navItem(key: string, label: string, icon: Resource, page: string) {
    Button({ type: ButtonType.Normal }) {
      Flex({ direction: this.rail() ? FlexDirection.Column : FlexDirection.Row,
        alignItems: ItemAlign.Center, justifyContent: this.rail() ? FlexAlign.Center : FlexAlign.Start }) {
        Image(icon).width(21).height(21).opacity(this.active === key ? 1 : 0.6)
          .margin(this.rail() ? { bottom: 5 } : { right: 12 })
        Text(label).fontSize(this.rail() ? 11 : 14)
          .fontWeight(this.active === key ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.active === key ? '#315EFB' : '#52627D').maxLines(1)
      }.width('100%')
    }.width('100%').height(this.rail() ? 66 : 48).padding({ left: this.rail() ? 2 : 14, right: this.rail() ? 2 : 14 })
      .backgroundColor(this.active === key ? '#EAF0FF' : Color.Transparent).borderRadius(12)
      .enabled(!this.navigationLocked)
      .onClick(() => this.navigate(key, page))
      .accessibilityText(label).accessibilityDescription(this.active === key ? '当前栏目' : '打开' + label)
      .id('workspace-nav-' + key)
  }

  @Builder
  private sidebar() {
    Column({ space: 16 }) {
      Row({ space: 10 }) {
        Image($r('app.media.ic_tunnels')).width(38).height(38).padding(8).backgroundColor('#EAF0FF').borderRadius(12)
        if (!this.rail()) {
          Column({ space: 4 }) {
            Text('络桥').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#172033')
            Text('让连接各得其所').fontSize(11).fontColor('#728097')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }
        if (this.compact()) {
          Button({ type: ButtonType.Normal }) {
            Image($r('app.media.ic_close')).width(18).height(18)
          }.width(40).height(40).borderRadius(10).backgroundColor('#F4F6FA')
            .onClick(() => this.closeDrawer()).accessibilityText('关闭导航').id('workspace-close-menu')
        }
      }.width('100%').justifyContent(this.rail() ? FlexAlign.Center : FlexAlign.Start)
        .padding({ top: 8, bottom: 12, left: this.rail() ? 0 : 6, right: this.rail() ? 0 : 6 })
      Scroll() {
        Column({ space: 5 }) {
          if (!this.rail()) {
            Text('工作区').fontSize(11).fontColor('#8A97AC').letterSpacing(1).width('100%').padding({ left: 14, bottom: 6 })
          }
          this.navItem('tunnels', '连接', $r('app.media.ic_tunnels'), 'pages/NetworksPage')
          this.navItem('domains', '域名库', $r('app.media.ic_library'), 'pages/DomainLibraryPage')
          this.navItem('rules', '自定义规则', $r('app.media.ic_rules'), 'pages/CustomRulesPage')
          this.navItem('groups', '地址组', $r('app.media.ic_groups'), 'pages/AddressGroupsPage')
          Divider().color('#E8ECF3').margin({ top: 14, bottom: 14 })
          if (!this.rail()) {
            Text('网络工具').fontSize(11).fontColor('#8A97AC').letterSpacing(1).width('100%').padding({ left: 14, bottom: 6 })
          }
          this.navItem('checker', '路由检查', $r('app.media.ic_route'), 'pages/RouteCheckerPage')
          this.navItem('subnets', '重叠网段', $r('app.media.ic_subnets'), 'pages/SubnetRoutesPage')
          this.navItem('diagnostics', '运行诊断', $r('app.media.ic_diagnostics'), 'pages/VpnDiagnosticsPage')
        }.width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
      if (!this.rail()) {
        Column({ space: 4 }) {
          Text('WireGuard + Tailnet').fontSize(12).fontColor('#52627D')
          Text('连接与分流，统一管理').fontSize(11).fontColor('#8A97AC')
        }.alignItems(HorizontalAlign.Start).width('100%').padding({ left: 14, bottom: 12 })
      }
    }.width('100%').height('100%').padding({ left: this.rail() ? 8 : 14, right: this.rail() ? 8 : 14, top: 16, bottom: 12 })
      .backgroundColor('#FBFCFE').border({ width: { right: 1 }, color: '#E4E9F2' })
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row() {
        if (!this.compact()) {
          Column() { this.sidebar() }.width(this.rail() ? 84 : 224).height('100%').flexShrink(0)
        }
        Column() {
          if (this.compact()) {
            Row({ space: 12 }) {
              Button({ type: ButtonType.Normal }) {
                Image($r('app.media.ic_menu')).width(22).height(22)
              }.width(44).height(44).backgroundColor('#EEF2FF').borderRadius(12)
                .onClick(() => this.openDrawer()).accessibilityText('打开导航').id('workspace-open-menu')
              Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#172033').layoutWeight(1)
              Text('络桥').fontSize(13).fontColor('#728097')
            }.height(64).width('100%').padding({ left: 16, right: 20 }).backgroundColor('#FBFCFE')
              .border({ width: { bottom: 1 }, color: '#E4E9F2' }).flexShrink(0)
          }
          Column() { this.content() }.layoutWeight(1).width('100%')
        }.layoutWeight(1).height('100%').constraintSize({ minWidth: 0 })
          .accessibilityLevel(this.drawerOpen ? 'no-hide-descendants' : 'auto')
      }.width('100%').height('100%')
      if (this.compact() && this.drawerOpen) {
        Row() {}.width('100%').height('100%').backgroundColor('#660E1930')
          .onClick(() => this.closeDrawer()).accessibilityText('关闭导航')
        Column() { this.sidebar() }.width(Math.min(288, Math.max(240, this.viewportWidth - 48))).height('100%')
          .shadow({ radius: 24, color: '#25172033', offsetX: 8, offsetY: 0 })
      }
    }.width('100%').height('100%').backgroundColor('#F4F6FA')
      .onAreaChange((_old: Area, area: Area) => {
        this.viewportWidth = Number(area.width);
        if (!this.compact()) { this.closeDrawer(); }
      })
  }
}
