import { WorkspaceShell } from '../components/WorkspaceShell';
import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import {
  clearResolvedIps, collectSplitRules, readCatalogCache, readDomainListCache,
  readProfileRules, writeCatalogCache, writeDomainListCache,
  writeProfileRules, ProfileRules,
} from '../model/SplitTunnel';
import { dedupeStrings, isDomainName, parseDomainList } from '../model/DomainRules';
import { parseIpPrefix } from '../model/WireGuardConfig';
import { listProfiles, ProfileMeta } from '../model/ProfileStore';
import { domainDatabaseCatalog } from '../net/DomainDatabase';
import { fetchCatalog, fetchDomainList } from '../net/DomainListSource';

const INK: string = '#172033';
const MUTED: string = '#728097';
const CANVAS: string = '#F4F6FA';
const ACCENT: string = '#315EFB';
const PAPER: string = '#FFFFFF';
const DANGER: string = '#9E392B';
const MAX_CACHED_FILES: number = 48;
const PROFILE_ID_PATTERN: RegExp = /^(main|legacy|[0-9a-fA-F-]{8,64})$/;

interface DomainListsPageParams {
  profileId?: string;
  profileName?: string;
  multiNetwork?: boolean;
}

@Entry
@Component
struct DomainListsPage {
  @State private contentWidth: number = 0;
  @State private contentHeight: number = 0;
  onBackPress(): boolean { return dismissWorkspaceDrawer(); }
  @State private multiNetwork: boolean = false;
  @State private profileId: string = '';
  @State private profileName: string = '';
  @State private rulesEnabled: boolean = false;
  @State private isDefault: boolean = false;
  @State private query: string = '';
  @State private catalog: string[] = [];
  @State private visible: string[] = [];
  @State private selectedNames: string[] = [];
  @State private manualDomains: string[] = [];
  @State private manualCidrs: string[] = [];
  @State private groupIds: string[] = [];
  @State private newDomain: string = '';
  @State private newCidr: string = '';
  @State private loading: boolean = true;
  @State private notice: string = '';
  @State private domainCount: number = 0;
  @State private missingCount: number = 0;

  aboutToAppear(): void {
    const params = router.getParams() as DomainListsPageParams;
    if (typeof params?.profileId === 'string' && PROFILE_ID_PATTERN.test(params.profileId)) {
      this.profileId = params.profileId;
      this.profileName = typeof params.profileName === 'string' ? params.profileName : '';
    } else {
      this.notice = '缺少有效的配置标识，无法编辑分流规则。';
      this.loading = false;
      return;
    }
    this.multiNetwork = params.multiNetwork === true;
    const rules = readProfileRules(this.sandboxDir(), this.profileId);
    this.rulesEnabled = rules.enabled;
    this.isDefault = rules.isDefault;
    this.selectedNames = rules.lists;
    this.manualDomains = rules.manualDomains;
    this.manualCidrs = rules.manualCidrs;
    this.groupIds = rules.groupIds;
    this.refreshSummary();
    this.loadCatalog(false);
  }

  private sandboxDir(): string {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      throw new Error('无法获取应用上下文。');
    }
    return (host as common.UIAbilityContext).filesDir;
  }

  private abilityContext(): common.UIAbilityContext {
    const host = this.getUIContext().getHostContext();
    if (host === undefined) {
      throw new Error('无法获取应用上下文。');
    }
    return host as common.UIAbilityContext;
  }

  private currentRules(): ProfileRules {
    const rules = new ProfileRules(this.rulesEnabled, this.isDefault);
    rules.lists = this.selectedNames;
    rules.manualDomains = this.manualDomains;
    rules.manualCidrs = this.manualCidrs;
    rules.groupIds = this.groupIds.slice();
    return rules;
  }

  private persist(): void {
    if (this.profileId.length === 0) {
      return;
    }
    writeProfileRules(this.sandboxDir(), this.profileId, this.currentRules());
    this.notice = '已保存，下次连接生效。';
  }

  private refreshSummary(): void {
    if (this.multiNetwork) { this.domainCount = this.manualDomains.length; this.missingCount = 0; return; }
    const collected = collectSplitRules(this.sandboxDir(), this.selectedNames);
    this.domainCount = dedupeStrings(collected.rules.domains.concat(collected.rules.exacts)
      .concat(this.manualDomains)).length;
    this.missingCount = collected.missing.length;
  }

  private applyFilter(): void {
    const keyword = this.query.trim().toLowerCase();
    if (keyword.length === 0) {
      this.visible = this.catalog;
      return;
    }
    this.visible = this.catalog.filter((name: string): boolean => name.includes(keyword));
  }

  private async loadCatalog(force: boolean): Promise<void> {
    if (this.multiNetwork) {
      this.loading = true;
      try { this.catalog = await domainDatabaseCatalog(this.sandboxDir(), force); this.applyFilter(); this.notice = ''; }
      catch (e) { this.notice = '完整域名数据库获取失败：' + (e as Error).message; }
      finally { this.loading = false; }
      return;
    }
    if (!force) {
      const cached = readCatalogCache(this.sandboxDir());
      if (cached !== undefined) {
        this.catalog = cached;
        this.applyFilter();
        this.loading = false;
        return;
      }
    }
    this.loading = true;
    try {
      const names = await fetchCatalog();
      writeCatalogCache(this.sandboxDir(), names);
      this.catalog = names;
      this.applyFilter();
      this.notice = '';
    } catch (_) {
      this.notice = '无法获取域名列表目录。请检查网络后点击“刷新列表”重试。';
    } finally {
      this.loading = false;
    }
  }

  private isSelected(name: string): boolean {
    return this.selectedNames.includes(name);
  }

  private async toggle(name: string): Promise<void> {
    const index = this.selectedNames.indexOf(name);
    if (index >= 0) {
      this.selectedNames.splice(index, 1);
    } else {
      this.selectedNames.push(name);
    }
    this.persist();
    clearResolvedIps(this.sandboxDir(), this.profileId);
    this.refreshSummary();
    if (index < 0 && !this.multiNetwork) {
      await this.ensureCached(name, new Set<string>());
    }
  }

  private async ensureCached(name: string, visited: Set<string>): Promise<void> {
    if (visited.has(name) || visited.size >= MAX_CACHED_FILES) {
      return;
    }
    visited.add(name);
    try {
      let content = readDomainListCache(this.sandboxDir(), name);
      if (content === undefined) {
        content = await fetchDomainList(name);
        writeDomainListCache(this.sandboxDir(), name, content);
        this.refreshSummary();
      }
      for (const include of parseDomainList(content).includes) {
        await this.ensureCached(include, visited);
      }
    } catch (_) {
      this.notice = `获取「${name}」列表失败。该列表暂时无法分流，可稍后重新勾选以重试。`;
    }
  }

  private addManualDomain(): void {
    const value = this.newDomain.trim().toLowerCase();
    if (value.length === 0) {
      return;
    }
    if (!isDomainName(value)) {
      this.notice = '域名格式无效，应形如 example.com。';
      return;
    }
    if (this.manualDomains.includes(value)) {
      this.newDomain = '';
      return;
    }
    this.manualDomains.push(value);
    this.newDomain = '';
    this.notice = '';
    this.persist();
    clearResolvedIps(this.sandboxDir(), this.profileId);
    this.refreshSummary();
  }

  private removeManualDomain(value: string): void {
    const index = this.manualDomains.indexOf(value);
    if (index >= 0) {
      this.manualDomains.splice(index, 1);
      this.persist();
      clearResolvedIps(this.sandboxDir(), this.profileId);
      this.refreshSummary();
    }
  }

  private addManualCidr(): void {
    const value = this.newCidr.trim();
    if (value.length === 0) {
      return;
    }
    const prefix = parseIpPrefix(value);
    if (prefix === undefined || prefix.prefixLength === 0) {
      this.notice = 'IP 段格式无效，应形如 192.0.2.0/24 或 2001:db8::/32（不支持默认路由）。';
      return;
    }
    const normalized = `${prefix.address}/${prefix.prefixLength}`;
    if (!this.manualCidrs.includes(normalized)) {
      this.manualCidrs.push(normalized);
    }
    this.newCidr = '';
    this.notice = '';
    this.persist();
    clearResolvedIps(this.sandboxDir(), this.profileId);
    this.refreshSummary();
  }

  private removeManualCidr(value: string): void {
    const index = this.manualCidrs.indexOf(value);
    if (index >= 0) {
      this.manualCidrs.splice(index, 1);
      this.persist();
      clearResolvedIps(this.sandboxDir(), this.profileId);
      this.refreshSummary();
    }
  }

  private async toggleDefault(): Promise<void> {
    if (this.isDefault) {
      this.isDefault = false;
      this.persist();
      return;
    }
    const directory = this.sandboxDir();
    const metas: ProfileMeta[] = listProfiles(this.abilityContext());
    for (const meta of metas) {
      if (meta.id === this.profileId) {
        continue;
      }
      const rules = readProfileRules(directory, meta.id);
      if (rules.isDefault) {
        rules.isDefault = false;
        writeProfileRules(directory, meta.id, rules);
      }
    }
    this.isDefault = true;
    this.rulesEnabled = false;
    this.persist();
  }

  private async clearRules(): Promise<void> {
    this.selectedNames = [];
    this.manualDomains = [];
    this.manualCidrs = [];
    this.rulesEnabled = false;
    this.persist();
    clearResolvedIps(this.sandboxDir(), this.profileId);
    this.refreshSummary();
  }

  @Builder
  private headerBar() {
    Column({ space: 10 }) {
      Button('‹ 返回', { type: ButtonType.Normal }).fontSize(14).fontColor(ACCENT)
        .backgroundColor(Color.Transparent).padding(0).onClick(() => router.back())
      Text(this.profileName.length > 0 ? this.profileName : '分流规则')
        .fontSize(this.contentWidth < 600 ? 25 : 28).fontWeight(FontWeight.Bold).fontColor(INK)
        .wordBreak(WordBreak.BREAK_ALL)
      Text('连接的域名库与手动规则').fontSize(14).fontColor(MUTED)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private roleCard() {
    Column({ space: 13 }) {
      Text('下次连接配置').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
      Text('下方显示已保存的规则，可在连接运行时编辑。当前连接和自动恢复继续使用启动时的规则，保存后手动断开并连接生效。')
        .fontSize(12).lineHeight(18).fontColor(MUTED)
      if (!this.multiNetwork) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('作为默认隧道').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('未匹配分流规则的流量走此配置，其余配置的默认角色会被取消')
            .fontSize(12).lineHeight(17).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.isDefault })
          .enabled(this.profileId.length > 0)
          .onChange((isOn: boolean) => {
            if (isOn !== this.isDefault) {
              this.toggleDefault();
            }
          })
      }.width('100%')
      Divider().color('#E1EBE7')
      }
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('启用站点分流').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('仅下方站点与 IP 段的流量走此配置，其余流量交给默认隧道或正常网络')
            .fontSize(12).lineHeight(17).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.rulesEnabled })
          .enabled(this.profileId.length > 0 && !this.isDefault)
          .onChange((isOn: boolean) => {
            this.rulesEnabled = isOn;
            this.persist();
          })
      }.width('100%')
      Divider().color('#E1EBE7')
      Column({ space: 5 }) {
        Text(this.isDefault ? '下次连接：此连接承接全部未匹配流量。' :
          (this.rulesEnabled ?
            `下次连接启用：${this.selectedNames.length} 个列表 · ${this.domainCount} 个${this.multiNetwork ? "手动" : ""}域名 · ${this.manualCidrs.length} 个 IP 段` :
            '下次连接：不启用此配置的站点规则。'))
          .fontSize(14).fontColor(INK)
        if (this.missingCount > 0) {
          Text(`${this.missingCount} 个所选列表尚未获取内容，连接前需要补齐。`)
            .fontSize(13).fontColor(DANGER)
        }
        Text(this.multiNetwork ? '域名及其子域名动态分流，支持 full、keyword、regexp 和 include。其余流量按其他连接配置或正常网络处理；规则冲突会阻止连接。' : 'WireGuard 按域名及子域名动态分流，full 精确匹配；keyword / regexp 暂不支持。请使用系统 DNS，关闭浏览器安全 DNS并重开浏览器以清除旧缓存。规则模式转发 TCP / UDP，选中连接失败时不回落到直连。')
          .fontSize(12).lineHeight(17).fontColor(MUTED)
      }.alignItems(HorizontalAlign.Start).width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor(PAPER)
    .borderRadius(20)
  }

  @Builder
  private manualCard() {
    Column({ space: 13 }) {
      Text('手动域名与 IP 段').fontSize(16).fontWeight(FontWeight.Bold).fontColor(INK)
      Row({ space: 8 }) {
        TextInput({ text: this.newDomain, placeholder: 'example.com' })
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor(INK)
          .backgroundColor(CANVAS)
          .enabled(this.profileId.length > 0 && !this.isDefault)
          .onChange((value: string) => { this.newDomain = value; })
        Button('添加', { type: ButtonType.Normal })
          .height(40).borderRadius(11).backgroundColor(ACCENT).fontColor(PAPER).fontSize(13)
          .enabled(this.profileId.length > 0 && !this.isDefault && this.newDomain.trim().length > 0)
          .onClick(() => this.addManualDomain())
      }.width('100%')
      if (this.manualDomains.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.manualDomains, (domain: string) => {
            Row({ space: 6 }) {
              Text(domain).fontSize(13).fontColor(INK).wordBreak(WordBreak.BREAK_ALL).layoutWeight(1)
              Text('×').fontSize(13).fontColor(MUTED)
                .onClick(() => this.removeManualDomain(domain))
            }
            .width('100%').padding({ left: 11, right: 11, top: 6, bottom: 6 })
            .backgroundColor(CANVAS)
            .borderRadius(14)
            .margin({ top: 3, bottom: 3 })
          }, (domain: string) => domain)
        }.width('100%')
      }
      Row({ space: 8 }) {
        TextInput({ text: this.newCidr, placeholder: 'IPv4 / IPv6 网段' })
          .fontSize(14)
          .height(40)
          .layoutWeight(1)
          .fontColor(INK)
          .backgroundColor(CANVAS)
          .enabled(this.profileId.length > 0 && !this.isDefault)
          .onChange((value: string) => { this.newCidr = value; })
        Button('添加', { type: ButtonType.Normal })
          .height(40).borderRadius(11).backgroundColor(ACCENT).fontColor(PAPER).fontSize(13)
          .enabled(this.profileId.length > 0 && !this.isDefault && this.newCidr.trim().length > 0)
          .onClick(() => this.addManualCidr())
      }.width('100%')
      if (this.manualCidrs.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.manualCidrs, (cidr: string) => {
            Row({ space: 6 }) {
              Text(cidr).fontSize(13).fontColor(INK).wordBreak(WordBreak.BREAK_ALL).layoutWeight(1)
              Text('×').fontSize(13).fontColor(MUTED)
                .onClick(() => this.removeManualCidr(cidr))
            }
            .width('100%').padding({ left: 11, right: 11, top: 6, bottom: 6 })
            .backgroundColor(CANVAS)
            .borderRadius(14)
            .margin({ top: 3, bottom: 3 })
          }, (cidr: string) => cidr)
        }.width('100%')
      }
      if (this.notice.length > 0) {
        Text(this.notice).fontSize(13).lineHeight(18).fontColor(DANGER).width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(18)
    .backgroundColor(PAPER)
    .borderRadius(20)
  }

  @Builder
  private listsCard() {
    Column({ space: 13 }) {
      Row({ space: 10 }) {
        Button('刷新列表', { type: ButtonType.Normal })
          .layoutWeight(1).height(40).borderRadius(12).backgroundColor('#EEF2FF').fontColor(ACCENT)
          .fontSize(14)
          .enabled(!this.loading)
          .onClick(() => this.loadCatalog(true))
      }.width('100%')
      TextInput({ text: this.query, placeholder: '搜索列表名称' })
        .fontSize(14)
        .height(42)
        .backgroundColor(PAPER)
        .fontColor(INK)
        .onChange((value: string) => {
          this.query = value;
          this.applyFilter();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private catalogRow(name: string) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(name).fontSize(15).fontColor(INK).wordBreak(WordBreak.BREAK_ALL)
        if (this.isSelected(name)) {
          Text('已选择').fontSize(11).fontColor(ACCENT)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Checkbox()
        .select(this.isSelected(name))
        .selectedColor(ACCENT)
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => this.toggle(name))
  }

  @Builder
  private catalogPanel() {
    Column({ space: 14 }) {
      this.listsCard()
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(34).height(34).color(ACCENT)
          Text('正在获取列表…').fontSize(13).fontColor(MUTED)
        }.width('100%').height(240).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 1 }) {
          ForEach(this.visible, (name: string) => {
            ListItem() {
              this.catalogRow(name)
            }
          }, (name: string) => name)
        }.width('100%').height(Math.max(360, Math.min(680, this.contentHeight - 180)))
          .backgroundColor(PAPER).borderRadius(16).scrollBar(BarState.Auto)
          .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
      }
    }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private pageContent() {
    Scroll() {
      Column({ space: 22 }) {
        this.headerBar()
        Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
          justifyContent: FlexAlign.SpaceBetween }) {
          Column({ space: 18 }) {
            this.roleCard()
            this.manualCard()
          }.width(this.contentWidth >= 800 ? '49%' : '100%').alignItems(HorizontalAlign.Start)
            .margin({ bottom: this.contentWidth >= 800 ? 0 : 22 })
          this.catalogPanel()
        }.width('100%')
      }.width('100%').constraintSize({ maxWidth: 1120 }).alignItems(HorizontalAlign.Start)
        .padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28, top: 24, bottom: 28 })
    }.width('100%').height('100%').backgroundColor(CANVAS).scrollBar(BarState.Auto).align(Alignment.Top)
      .onAreaChange((_oldArea: Area, area: Area) => {
        this.contentWidth = Number(area.width); this.contentHeight = Number(area.height);
      })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'domains', title: '连接分流规则' }) {
        this.pageContent()
      }
    }.width('100%').height('100%')
  }
}
