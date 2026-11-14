import { router } from '@kit.ArkUI';

@Component
export struct WorkspaceNav {
  @Prop active: string = 'tunnels';
  private navigate(key: string, page: string): void {
    if (this.active !== key) { router.replaceUrl({ url: page }); }
  }
  @Builder
  private item(key: string, label: string, icon: Resource, page: string) {
    Column({ space: 6 }) {
      Image(icon).width(21).height(21).opacity(this.active === key ? 1 : 0.45)
      Text(label).fontSize(12).fontWeight(this.active === key ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.active === key ? '#315EFB' : '#728097')
    }
    .layoutWeight(1).padding({ top: 12, bottom: 10 })
    .backgroundColor(this.active === key ? '#EEF2FF' : Color.Transparent).borderRadius(14)
    .onClick(() => this.navigate(key, page))
    .accessibilityText(label).accessibilityDescription(this.active === key ? '当前页面' : '打开' + label)
  }
  build() {
    Row({ space: 8 }) {
      this.item('tunnels', '连接', $r('app.media.ic_tunnels'), 'pages/NetworksPage')
      this.item('domains', '域名库', $r('app.media.ic_library'), 'pages/DomainLibraryPage')
      this.item('rules', '自定义规则', $r('app.media.ic_rules'), 'pages/CustomRulesPage')
    }.width('100%').constraintSize({ maxWidth: 1000 }).padding({ top: 10, bottom: 12, left: 24, right: 24 })
      .backgroundColor(Color.White).border({ width: { top: 1 }, color: '#E4E9F2' })
  }
}
