import { common } from '@kit.AbilityKit';
import { router, LengthMetrics } from '@kit.ArkUI';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { RuleTarget, readRuleTargets, ruleConnectionsActive } from '../model/RuleTargets';
import { ProfileRules, readProfileRules, expandProfileRules, writeProfileRules, clearResolvedIps, readDomainListCache,
  MAX_INCLUDE_FILES, MAX_SPLIT_DOMAINS } from '../model/SplitTunnel';
import { parseDomainList, dedupeStrings } from '../model/DomainRules';
import { DomainListContent, writeCachedDomainLists } from '../model/DomainListCache';
import { fetchDomainList } from '../net/DomainListSource';
import { DomainDatabaseInfo, domainDatabaseCatalog, readDomainDatabaseInfo } from '../net/DomainDatabase';

const INK: string = '#172033';
const MUTED: string = '#728097';
const ACCENT: string = '#315EFB';
const CANVAS: string = '#F4F6FA';
const BORDER: string = '#E4E9F2';

class ListAssignment {
  profileKey: string = '';
  profileName: string = '';
  enabled: boolean = true;
  names: string[] = [];
}

interface DomainPageParams { profileId?: string; profileType?: string; }

class CatalogDataSource implements IDataSource {
  private items: string[] = [];
  private listeners: DataChangeListener[] = [];
  totalCount(): number { return this.items.length; }
  getData(index: number): string { return this.items[index]; }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) { this.listeners.push(listener); }
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((item: DataChangeListener): boolean => item !== listener);
  }
  replace(items: string[]): void {
    this.items = items;
    for (const listener of this.listeners) { listener.onDataReloaded(); }
  }
}

@Entry
@Component
struct DomainLibraryPage {
  @State private profiles: RuleTarget[] = [];
  @State private assignments: ListAssignment[] = [];
  @State private selectedKey: string = '';
  @State private selectedIndex: number = 0;
  @State private query: string = '';
  @State private contentWidth: number = 0;
  @State private filter: string = 'all';
  @State private catalog: string[] = [];
  @State private visibleCount: number = 0;
  @State private info: DomainDatabaseInfo = new DomainDatabaseInfo();
  @State private connected: boolean = false;
  @State private loading: boolean = false;
  @State private metadataReady: boolean = false;
  @State private error: string = '';
  @State private notice: string = '';
  private source: CatalogDataSource = new CatalogDataSource();
  private timer: number = -1;

  private directory(): string {
    return (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir;
  }

  aboutToAppear(): void {
    const params = router.getParams() as DomainPageParams;
    if (typeof params?.profileId === 'string') {
      this.selectedKey = params.profileType === 'tailnet' ? 'tailnet:' + params.profileId :
        params.profileType === 'wireguard' ? 'wireguard:' + params.profileId : params.profileId;
    }
    this.refreshProfiles();
    this.info = readDomainDatabaseInfo(this.directory());
    this.catalog = this.info.catalog;
    this.applyFilter();
    if (this.info.available && this.catalog.length === 0) { this.loadCatalog(false); }
    this.startTimer();
  }

  onPageShow(): void { this.refreshProfiles(); this.startTimer(); }
  onPageHide(): void { this.stopTimer(); }
  onBackPress(): boolean { return dismissWorkspaceDrawer(); }
  aboutToDisappear(): void { this.stopTimer(); }

  private startTimer(): void {
    if (this.timer >= 0) { return; }
    this.timer = setInterval(() => { this.connected = ruleConnectionsActive(this.directory()); }, 1500);
  }

  private stopTimer(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private refreshProfiles(): void {
    this.metadataReady = false;
    try {
      this.profiles = readRuleTargets(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.connected = ruleConnectionsActive(this.directory());
      let index = this.profiles.findIndex((profile: RuleTarget): boolean => profile.key() === this.selectedKey);
      if (index < 0) { index = this.profiles.findIndex((profile: RuleTarget): boolean => profile.ID === this.selectedKey); }
      this.selectedIndex = index >= 0 ? index : 0;
      this.selectedKey = this.profiles.length > 0 ? this.profiles[this.selectedIndex].key() : '';
      this.refreshAssignments();
      this.metadataReady = true;
    } catch (e) { this.error = '无法读取连接，已暂停规则编辑：' + (e as Error).message; }
  }

  private refreshAssignments(): void {
    const assignments: ListAssignment[] = [];
    for (const profile of this.profiles) {
      const rules = readProfileRules(this.directory(), profile.ID);
      const assignment = new ListAssignment();
      assignment.profileKey = profile.key();
      assignment.profileName = profile.label();
      assignment.enabled = rules.enabled && profile.Enabled && !profile.IsDefault;
      assignment.names = rules.lists;
      assignments.push(assignment);
    }
    this.assignments = assignments;
    this.applyFilter();
  }

  private selectedName(): string {
    if (this.profiles.length === 0) { return '选择连接'; }
    const profile = this.profiles[this.selectedIndex];
    return profile.label() + (profile.IsDefault ? ' · 默认路由' : (profile.Enabled ? '' : ' · 未启用'));
  }

  private options(): SelectOption[] {
    return this.profiles.map((profile: RuleTarget): SelectOption => {
      return { value: profile.label() + (profile.IsDefault ? ' · 默认路由' : (profile.Enabled ? '' : ' · 未启用')) };
    });
  }

  private isSelected(name: string): boolean {
    return this.assignments.some((assignment: ListAssignment): boolean =>
      assignment.profileKey === this.selectedKey && assignment.names.includes(name));
  }

  private assignedElsewhere(name: string): boolean {
    return this.assignments.some((assignment: ListAssignment): boolean =>
      assignment.profileKey !== this.selectedKey && assignment.names.includes(name));
  }

  private ownerLabel(name: string): string {
    const owners = this.assignments.filter((assignment: ListAssignment): boolean => assignment.names.includes(name));
    if (owners.length === 0) { return '尚未分配'; }
    return owners.map((assignment: ListAssignment): string =>
      assignment.profileName + (assignment.enabled ? '' : '（未启用）')).join('、');
  }

  private assignmentCount(): number {
    const names = new Set<string>();
    for (const assignment of this.assignments) {
      for (const name of assignment.names) { names.add(name); }
    }
    return names.size;
  }

  private currentCount(): number {
    const assignment = this.assignments.find((item: ListAssignment): boolean => item.profileKey === this.selectedKey);
    return assignment === undefined ? 0 : assignment.names.length;
  }

  private applyFilter(): void {
    const keyword = this.query.trim().toLowerCase();
    const assigned = new Set<string>();
    for (const assignment of this.assignments) {
      for (const name of assignment.names) { assigned.add(name); }
    }
    // Keep removed upstream lists visible so users can still remove their assignments.
    const names = this.catalog.slice();
    for (const name of assigned) { if (!names.includes(name)) { names.push(name); } }
    names.sort();
    const visible = names.filter((name: string): boolean =>
      name.includes(keyword) && (this.filter !== 'assigned' || assigned.has(name)));
    this.visibleCount = visible.length;
    this.source.replace(visible);
  }

  private updateDate(): string {
    if (!this.info.available || this.info.updatedAt <= 0) { return '尚未下载'; }
    const date = new Date(this.info.updatedAt);
    return date.getFullYear() + '-' + (date.getMonth() + 1).toString().padStart(2, '0') + '-' +
      date.getDate().toString().padStart(2, '0') + ' ' + date.getHours().toString().padStart(2, '0') + ':' +
      date.getMinutes().toString().padStart(2, '0');
  }

  private async loadCatalog(force: boolean): Promise<void> {
    if (this.loading) { return; }
    this.loading = true; this.error = ''; this.notice = '';
    try {
      this.catalog = await domainDatabaseCatalog(this.directory(), force);
      this.info = readDomainDatabaseInfo(this.directory());
      this.applyFilter();
      if (force) { this.notice = '数据库已保存，下次连接生效。已保留所有分流选择。'; }
    } catch (e) {
      this.error = (e as Error).message || '更新失败，请检查网络后重试。';
      if (this.catalog.length > 0) { this.notice = '当前列表和已有分流选择已保留。'; }
    } finally { this.loading = false; }
  }

  private selectedWireGuard(): boolean {
    return this.selectedIndex >= 0 && this.selectedIndex < this.profiles.length &&
      this.profiles[this.selectedIndex].Kind === 'wireguard';
  }

  private async ensureWireGuardLists(names: string[], manualDomains: string[], force: boolean = false): Promise<DomainListContent[]> {
    const visited = new Set<string>();
    const contents: DomainListContent[] = [];
    for (const name of names) { await this.ensureCached(name, visited, contents, force); }
    const domains = manualDomains.slice();
    for (const item of contents) {
      const parsed = parseDomainList(item.content);
      for (const domain of parsed.domains.concat(parsed.exacts)) { domains.push(domain); }
    }
    if (dedupeStrings(domains).length > MAX_SPLIT_DOMAINS) {
      throw new Error('所选集合超过 WireGuard 的 ' + MAX_SPLIT_DOMAINS + ' 个域名规则上限，请减少选择或改用 Tailnet。');
    }
    return contents;
  }

  private async ensureCached(name: string, visited: Set<string>, contents: DomainListContent[], force: boolean): Promise<void> {
    if (visited.has(name)) { return; }
    if (visited.size >= MAX_INCLUDE_FILES) {
      throw new Error('所选集合及其引用超过 WireGuard 的 ' + MAX_INCLUDE_FILES + ' 个列表上限，请减少选择或改用 Tailnet。');
    }
    visited.add(name);
    let content = force ? undefined : readDomainListCache(this.directory(), name);
    if (content === undefined) { content = await fetchDomainList(name); }
    contents.push(new DomainListContent(name, content));
    for (const include of parseDomainList(content).includes) { await this.ensureCached(include, visited, contents, force); }
  }

  private async updateWireGuardLists(): Promise<void> {
    if (this.loading || !this.metadataReady || !this.selectedWireGuard()) { return; }
    this.connected = ruleConnectionsActive(this.directory());
    const profile = this.profiles[this.selectedIndex];
    this.loading = true; this.error = ''; this.notice = '';
    try {
      const rules = readProfileRules(this.directory(), profile.ID);
      const expanded = expandProfileRules(this.directory(), rules);
      const expectedExpanded = JSON.stringify(expanded);
      const staged = await this.ensureWireGuardLists(rules.lists, expanded.manualDomains, true);
      this.connected = ruleConnectionsActive(this.directory());
      const current = readRuleTargets(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const currentRules = readProfileRules(this.directory(), profile.ID);
      if (!current.some((item: RuleTarget): boolean => item.key() === profile.key()) ||
        JSON.stringify(currentRules) !== JSON.stringify(rules) ||
        JSON.stringify(expandProfileRules(this.directory(), currentRules)) !== expectedExpanded) {
        throw new Error('连接或规则已变化，本次未更新缓存。');
      }
      writeCachedDomainLists(this.directory(), staged);
      clearResolvedIps(this.directory(), profile.ID);
      this.notice = '原始列表及引用已保存，下次连接生效。';
    } catch (e) { this.error = 'WireGuard 列表更新未完成，原缓存已保留：' + (e as Error).message; }
    finally { this.loading = false; }
  }

  private async changeAssignment(name: string, selected: boolean): Promise<void> {
    this.connected = ruleConnectionsActive(this.directory());
    if (this.loading || !this.metadataReady || this.selectedKey.length === 0) { return; }
    const requestedKey = this.selectedKey;
    this.refreshProfiles();
    if (!this.metadataReady || this.selectedKey !== requestedKey) { this.error = '连接已变更，请重新选择。'; return; }
    const selectedProfile = this.profiles[this.selectedIndex];
    this.loading = true; this.error = ''; this.notice = '';
    const directory = this.directory();
    const touched: string[] = [];
    const previous: ProfileRules[] = [];
    try {
      const desired = readProfileRules(directory, selectedProfile.ID);
      const expectedRules = JSON.stringify(desired);
      let expectedExpanded = '';
      let expandedDomains = desired.manualDomains;
      if (selected && selectedProfile.Kind === 'wireguard') {
        const expanded = expandProfileRules(directory, desired);
        expectedExpanded = JSON.stringify(expanded);
        expandedDomains = expanded.manualDomains;
      }
      desired.lists = desired.lists.filter((item: string): boolean => item !== name);
      if (selected) { desired.lists.push(name); }
      // WireGuard needs source files, including every include, before a selection is usable.
      let staged: DomainListContent[] = [];
      if (selected && selectedProfile.Kind === 'wireguard') {
        staged = await this.ensureWireGuardLists(desired.lists, expandedDomains);
      }
      this.connected = ruleConnectionsActive(directory);
      const current = readRuleTargets(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const currentRules = readProfileRules(directory, selectedProfile.ID);
      if (!current.some((profile: RuleTarget): boolean => profile.key() === requestedKey) ||
        JSON.stringify(currentRules) !== expectedRules || (expectedExpanded.length > 0 &&
        JSON.stringify(expandProfileRules(directory, currentRules)) !== expectedExpanded)) {
        throw new Error('连接配置或规则已变化，本次未保存分配。');
      }
      writeCachedDomainLists(directory, staged);
      if (selected) {
        for (const profile of current) {
          if (profile.key() === requestedKey) { continue; }
          const rules = readProfileRules(directory, profile.ID);
          if (!rules.lists.includes(name)) { continue; }
          touched.push(profile.ID); previous.push(readProfileRules(directory, profile.ID));
          rules.lists = rules.lists.filter((item: string): boolean => item !== name);
          writeProfileRules(directory, profile.ID, rules);
          clearResolvedIps(directory, profile.ID);
        }
      }
      const target = readProfileRules(directory, selectedProfile.ID);
      const wasDefault = target.isDefault;
      touched.push(selectedProfile.ID); previous.push(readProfileRules(directory, selectedProfile.ID));
      target.lists = target.lists.filter((item: string): boolean => item !== name);
      if (selected) {
        target.lists.push(name); target.enabled = true;
        if (selectedProfile.Kind === 'wireguard') { target.isDefault = false; }
      }
      writeProfileRules(directory, selectedProfile.ID, target);
      clearResolvedIps(directory, selectedProfile.ID);
      this.refreshProfiles();
      this.notice = '已保存，下次连接生效。' + (selected ? '已将 ' + name + ' 分配给 ' + selectedProfile.label() : '已取消 ' + name + ' 的分配');
      if (selected && selectedProfile.Kind === 'wireguard' && wasDefault) {
        this.notice += '；此连接下次将仅处理匹配规则的流量。';
      }
    } catch (e) {
      let rollbackFailed = false;
      for (let index = touched.length - 1; index >= 0; index--) {
        try { writeProfileRules(directory, touched[index], previous[index]); } catch (_) { rollbackFailed = true; }
      }
      this.refreshProfiles();
      this.error = '保存失败：' + (e as Error).message +
        (rollbackFailed ? '；部分规则无法恢复，请检查已分配列表后再连接。' : '；原规则已保留。');
    } finally { this.loading = false; }
  }

  @Builder
  private databaseCard() {
    Column({ space: 18 }) {
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(16), cross: LengthMetrics.vp(12) } }) {
        Column({ space: 5 }) {
          Text('v2fly').fontSize(19).fontWeight(FontWeight.Medium).fontColor(INK)
          Text('社区域名库').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).flexGrow(1)
        Button(this.loading ? '正在更新…' : (this.info.available ? '更新数据库' : '下载数据库'), { type: ButtonType.Normal })
          .height(42).borderRadius(12).fontSize(14).backgroundColor(ACCENT).fontColor(Color.White)
          .enabled(!this.loading).onClick(() => this.loadCatalog(true))
      }.width('100%')
      Text('domain-list-community · Tailnet 使用完整 GeoSite 数据库；WireGuard 使用原始列表缓存').fontSize(12).fontColor(MUTED).lineHeight(18)
      Divider().color(BORDER)
      Row({ space: 30 }) {
        Column({ space: 4 }) {
          Text(this.catalog.length.toString()).fontSize(25).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('站点集合').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start)
        Column({ space: 4 }) {
          Text(this.assignmentCount().toString()).fontSize(25).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('已分配').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text('最近更新：' + this.updateDate()).fontSize(12).fontColor(MUTED)
      if (this.loading) {
        Row({ space: 10 }) {
          LoadingProgress().height(20).width(20).color(ACCENT)
          Text('正在获取并校验数据库，请稍候…').fontSize(13).fontColor(MUTED).layoutWeight(1).lineHeight(19)
        }.width('100%')
      }
    }.width('100%').padding(22).alignItems(HorizontalAlign.Start).backgroundColor(Color.White)
      .borderRadius(20).border({ width: 1, color: BORDER })
  }

  @Builder
  private targetCard() {
    Column({ space: 12 }) {
      Text('下次连接的分配').fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
      Text('勾选后自动保存 · 已保存 ' + this.currentCount() + ' 项').fontSize(12).fontColor(MUTED)
      Select(this.options()).selected(this.selectedIndex).value(this.selectedName())
        .font({ size: 14 }).fontColor(INK).backgroundColor(CANVAS).borderRadius(12).width('100%').height(44)
        .enabled(!this.loading && this.metadataReady)
        .onSelect((index: number) => {
          if (index >= 0 && index < this.profiles.length) {
            this.selectedIndex = index; this.selectedKey = this.profiles[index].key(); this.applyFilter();
          }
        })
      if (this.selectedWireGuard()) {
        Text('WireGuard 按域名及子域名匹配；full: 条目仅匹配完整域名。不支持关键词和正则。勾选前会下载列表及全部引用。')
          .fontSize(12).fontColor(MUTED).lineHeight(18)
        Text('域名匹配需要系统 DNS。浏览器安全 DNS（DoH）或旧 DNS 缓存可能绕过识别；若结果异常，请关闭安全 DNS 并重开浏览器。')
          .fontSize(12).fontColor(MUTED).lineHeight(18)
        Text('添加分配会在下次连接时启用分流规则并取消此连接的默认路由角色；对端 AllowedIPs 须允许目标 IP。')
          .fontSize(12).fontColor('#9A6B23').lineHeight(18)
        Button('更新此连接的原始列表', { type: ButtonType.Normal }).height(36).fontSize(12).borderRadius(10)
          .backgroundColor('#EDF2FF').fontColor(ACCENT).constraintSize({ maxWidth: '100%' })
          .enabled(this.metadataReady && !this.loading && this.currentCount() > 0)
          .onClick(() => this.updateWireGuardLists())
      }
      if (this.connected) {
        Text('当前连接继续使用启动时的规则和域名库，可编辑下次连接的分配。保存后手动断开并连接生效，自动恢复不改变当前规则。')
          .fontSize(12).fontColor(ACCENT).lineHeight(18)
      } else {
        Text('一个站点集合只分配给一个连接。Tailnet 与 WireGuard 可在连接列表中同时启用并连接；Tailnet 访问公网网站需要配置出口节点，WireGuard 使用其对端出口。')
          .fontSize(12).fontColor(MUTED).lineHeight(18)
      }
    }.width('100%').padding(20).alignItems(HorizontalAlign.Start).backgroundColor(Color.White)
      .borderRadius(20).border({ width: 1, color: BORDER })
  }

  @Builder
  private catalogRow(name: string) {
    Row({ space: 14 }) {
      Column({ space: 5 }) {
        Text(name).fontSize(15).fontWeight(FontWeight.Medium).fontColor(INK)
          .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.ownerLabel(name) + (this.catalog.includes(name) ? '' : ' · 上游已移除'))
          .fontSize(12).fontColor(this.isSelected(name) ? ACCENT : MUTED)
          .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).lineHeight(18)
        if (this.assignedElsewhere(name)) {
          Button('移至此连接', { type: ButtonType.Normal }).height(34).fontSize(12).borderRadius(10)
            .backgroundColor('#EDF2FF').fontColor(ACCENT).margin({ top: 5 })
            .enabled(this.metadataReady && !this.loading && this.selectedKey.length > 0 && this.catalog.includes(name))
            .onClick(() => this.changeAssignment(name, true))
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Checkbox({ name: name }).select(this.isSelected(name)).selectedColor(ACCENT).width(22).height(22)
        .enabled(this.metadataReady && !this.loading && this.selectedKey.length > 0 &&
          (this.isSelected(name) || (!this.assignedElsewhere(name) && this.catalog.includes(name))))
        .onChange((selected: boolean) => {
          if (selected !== this.isSelected(name)) { this.changeAssignment(name, selected); }
        })
    }.padding({ left: 20, right: 20, top: 16, bottom: 16 }).width('100%')
      .backgroundColor(this.isSelected(name) ? '#F7F9FF' : Color.White).borderRadius(16)
      .border({ width: 1, color: this.isSelected(name) ? '#CEDAFF' : BORDER })
  }

  @Builder
  private pageHeader() {
    Column({ space: 16 }) {
      Column({ space: 7 }) {
        Text('域名库').fontSize(this.contentWidth < 440 ? 26 : 30).fontWeight(FontWeight.Bold).fontColor(INK)
        Text('已保存分配 · 下次连接使用').fontSize(14).fontColor(MUTED)
      }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 4 })
      Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
        alignItems: ItemAlign.Start }) {
        Column() { this.databaseCard() }
          .width(this.contentWidth >= 800 ? '44%' : '100%')
          .padding({ right: this.contentWidth >= 800 ? 20 : 0, bottom: this.contentWidth >= 800 ? 0 : 16 })
        Column() {
          if (this.profiles.length > 0) {
            this.targetCard()
          } else {
            Column({ space: 16 }) {
              Column({ space: 5 }) {
                Text('先添加一个连接').fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK)
                Text('可以先浏览域名库，再为站点指定网络。').fontSize(12).fontColor(MUTED)
              }.alignItems(HorizontalAlign.Start).width('100%')
              Button('添加连接', { type: ButtonType.Normal }).height(38).fontSize(13).borderRadius(10)
                .backgroundColor('#EDF2FF').fontColor(ACCENT)
                .onClick(() => router.replaceUrl({ url: 'pages/NetworksPage' }))
            }.width('100%').padding(20).alignItems(HorizontalAlign.Start).backgroundColor(Color.White).borderRadius(20)
          }
        }.width(this.contentWidth >= 800 ? '56%' : '100%')
      }.width('100%')
      if (this.error.length > 0) {
        Text(this.error).width('100%').fontSize(13).fontColor('#C24040').lineHeight(18)
          .padding(14).backgroundColor('#FFF0F0').borderRadius(12)
      }
      if (this.notice.length > 0) {
        Text(this.notice).width('100%').fontSize(12).fontColor(ACCENT).lineHeight(18)
          .padding(14).backgroundColor('#EAF0FF').borderRadius(12)
      }
      TextInput({ text: this.query, placeholder: '搜索站点集合，如 google、github' })
        .height(44).fontSize(14).fontColor(INK).backgroundColor(Color.White).borderRadius(12)
        .border({ width: 1, color: BORDER }).width('100%')
        .onChange((value: string) => { this.query = value; this.applyFilter(); })
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
        space: { main: LengthMetrics.vp(12), cross: LengthMetrics.vp(10) } }) {
        Button('全部', { type: ButtonType.Normal }).height(38).fontSize(13).borderRadius(10)
          .backgroundColor(this.filter === 'all' ? ACCENT : Color.White)
          .fontColor(this.filter === 'all' ? Color.White : MUTED)
          .onClick(() => { this.filter = 'all'; this.applyFilter(); })
        Button('已分配', { type: ButtonType.Normal }).height(38).fontSize(13).borderRadius(10)
          .backgroundColor(this.filter === 'assigned' ? ACCENT : Color.White)
          .fontColor(this.filter === 'assigned' ? Color.White : MUTED)
          .onClick(() => { this.filter = 'assigned'; this.applyFilter(); })
        Text(this.visibleCount + ' 项').fontSize(12).fontColor(MUTED).flexGrow(1).textAlign(TextAlign.End)
      }.width('100%')
    }.width('100%').padding({ bottom: 6 })
  }

  @Builder
  private pageContent() {
    List({ space: 10 }) {
      ListItem() { this.pageHeader() }
      if (this.visibleCount > 0) {
        LazyForEach(this.source, (name: string) => {
          ListItem() { this.catalogRow(name) }
        }, (name: string): string => name)
      } else {
        ListItem() {
          Column({ space: 10 }) {
            Text(this.info.available ? '没有匹配的站点集合' : '域名库尚未下载')
              .fontSize(17).fontWeight(FontWeight.Medium).fontColor(INK)
            Text(this.info.available ? '尝试其他关键词，或切换到“全部”。' : '点击“下载数据库”获取完整站点列表。')
              .fontSize(13).fontColor(MUTED).textAlign(TextAlign.Center).lineHeight(19)
          }.width('100%').padding({ left: 20, right: 20, top: 36, bottom: 36 })
            .justifyContent(FlexAlign.Center).backgroundColor(Color.White).borderRadius(20)
        }
      }
    }.width('100%').constraintSize({ maxWidth: 1440 }).height('100%').scrollBar(BarState.Auto)
      .padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28,
        top: 28, bottom: 24 })
      .onAreaChange((_oldArea: Area, area: Area) => {
        const width = Number(area.width);
        if (width > 0 && Math.abs(width - this.contentWidth) > 1) { this.contentWidth = width; }
      })
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'domains', title: '域名库' }) { this.pageContent() }
    }.width('100%').height('100%')
  }
}
