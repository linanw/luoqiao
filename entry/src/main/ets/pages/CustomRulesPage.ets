import { common } from '@kit.AbilityKit';
import { router, LengthMetrics } from '@kit.ArkUI';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { RuleTarget, readRuleTargets, ruleConnectionsActive } from '../model/RuleTargets';
import { dedupeStrings, isDomainName } from '../model/DomainRules';
import { parseIpPrefix } from '../model/WireGuardConfig';
import { AddressGroup, readAddressGroups } from '../model/AddressGroups';
import { CustomRuleOverride, validateCustomRuleAssignments } from '../model/CustomRuleConflicts';
import { clearResolvedIps, collectSplitRules, MAX_SPLIT_DOMAINS, ProfileRules, readProfileRules,
  writeProfileRules, expandProfileRules } from '../model/SplitTunnel';

class CustomRule {
  profileId: string;
  targetKey: string;
  profileName: string;
  protocol: string;
  kind: string;
  value: string;
  enabled: boolean;
  groupName: string = '';
  domainCount: number = 0;
  cidrCount: number = 0;

  constructor(profile: RuleTarget, kind: string, value: string, enabled: boolean,
    group: AddressGroup | undefined = undefined) {
    this.profileId = profile.ID;
    this.targetKey = profile.key();
    this.profileName = profile.label();
    this.protocol = profile.Kind;
    this.kind = kind;
    this.value = value;
    this.enabled = enabled;
    if (kind === 'group') {
      this.groupName = group?.name || '地址组已缺失';
      this.domainCount = group?.domains.length || 0;
      this.cidrCount = group?.cidrs.length || 0;
    }
  }

  key(): string { return this.targetKey + ':' + this.kind + ':' + this.value; }
}

interface CustomRulesParams {
  profileId?: string;
  profileType?: string;
}

@Entry
@Component
struct CustomRulesPage {
  @State private profiles: RuleTarget[] = [];
  @State private rules: CustomRule[] = [];
  @State private groups: AddressGroup[] = [];
  @State private query: string = '';
  @State private contentWidth: number = 0;
  @State private filter: string = 'all';
  @State private locked: boolean = false;
  @State private connected: boolean = false;
  @State private formOpen: boolean = false;
  @State private editingKey: string = '';
  @State private editingTarget: string = '';
  @State private editingKind: string = '';
  @State private editingValue: string = '';
  @State private kind: string = 'domain';
  @State private value: string = '';
  @State private targetKey: string = '';
  @State private deleteKey: string = '';
  @State private error: string = '';
  @State private notice: string = '';
  private metadataReady: boolean = false;
  private paramsRead: boolean = false;
  private timer: number = -1;
  private scroller: Scroller = new Scroller();

  private directory(): string {
    return (this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir;
  }

  aboutToAppear(): void { this.resume(); }
  onPageShow(): void { this.resume(); }
  onPageHide(): void { this.pause(); }
  onBackPress(): boolean { return dismissWorkspaceDrawer(); }
  aboutToDisappear(): void { this.pause(); }

  private resume(): void {
    if (!this.paramsRead) {
      this.paramsRead = true;
      const params = router.getParams() as CustomRulesParams;
      if (typeof params?.profileId === 'string' && /^(main|legacy|[0-9a-fA-F-]{8,64})$/.test(params.profileId)) {
        this.targetKey = params.profileType === 'tailnet' ? 'tailnet:' + params.profileId :
          params.profileType === 'wireguard' ? 'wireguard:' + params.profileId : params.profileId;
      }
    }
    this.reload();
    this.refreshLock();
    if (this.timer < 0) {
      this.timer = setInterval(() => this.refreshLock(), 2000);
    }
  }

  private pause(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private refreshLock(): void {
    this.locked = !this.metadataReady;
    this.connected = ruleConnectionsActive(this.directory());
  }

  private reload(): void {
    this.metadataReady = false;
    try {
      const profiles = readRuleTargets(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const groups = readAddressGroups(this.directory());
      if (!Array.isArray(profiles)) { throw new Error('连接配置文件格式无效'); }
      const rows: CustomRule[] = [];
      for (const profile of profiles) {
        if (!profile || typeof profile.ID !== 'string' || typeof profile.Name !== 'string' ||
          !/^(main|legacy|[0-9a-fA-F-]{8,64})$/.test(profile.ID)) {
          throw new Error('连接配置信息不完整');
        }
        const rules = readProfileRules(this.directory(), profile.ID);
        for (const value of rules.manualDomains) {
          rows.push(new CustomRule(profile, 'domain', value, rules.enabled && profile.Enabled && !profile.IsDefault));
        }
        for (const value of rules.manualCidrs) {
          rows.push(new CustomRule(profile, 'ip', value, rules.enabled && profile.Enabled && !profile.IsDefault));
        }
        for (const id of rules.groupIds) {
          rows.push(new CustomRule(profile, 'group', id, rules.enabled && profile.Enabled && !profile.IsDefault,
            groups.find((group: AddressGroup): boolean => group.id === id)));
        }
      }
      this.profiles = profiles;
      this.rules = rows;
      this.groups = groups;
      if (!this.profiles.some((profile: RuleTarget): boolean => profile.key() === this.targetKey)) {
        const requested = this.profiles.find((profile: RuleTarget): boolean => profile.ID === this.targetKey);
        this.targetKey = requested !== undefined ? requested.key() : (this.profiles.length > 0 ? this.profiles[0].key() : '');
      }
      this.metadataReady = true;
    } catch (e) { this.locked = true; this.error = '无法读取规则，已暂停编辑：' + (e as Error).message; }
  }

  private visibleRules(): CustomRule[] {
    const keyword = this.query.trim().toLowerCase();
    return this.rules.filter((rule: CustomRule): boolean =>
      (this.filter === 'all' || this.filter === rule.kind) &&
      (!keyword || rule.value.toLowerCase().includes(keyword) || rule.groupName.toLowerCase().includes(keyword) ||
        rule.profileName.toLowerCase().includes(keyword)));
  }

  private count(kind: string): number {
    return this.rules.filter((rule: CustomRule): boolean => rule.kind === kind).length;
  }

  private canonical(kind: string, value: string): string {
    if (kind === 'group') { return value.trim(); }
    if (kind === 'domain') { return value.trim().toLowerCase().replace(/\.$/, ''); }
    const prefix = parseIpPrefix(value);
    return prefix === undefined ? value.trim() : `${prefix.address}/${prefix.prefixLength}`;
  }

  private selectedIndex(): number {
    return this.profiles.findIndex((profile: RuleTarget): boolean => profile.key() === this.targetKey);
  }

  private selectedName(): string {
    const index = this.selectedIndex();
    return index >= 0 ? this.profileLabel(this.profiles[index]) : '选择连接';
  }

  private profileLabel(profile: RuleTarget): string {
    return profile.label() + (profile.IsDefault ? '（默认路由）' : (profile.Enabled ? '' : '（未启用）'));
  }

  private selectedWireGuard(): boolean {
    const index = this.selectedIndex();
    return index >= 0 && this.profiles[index].Kind === 'wireguard';
  }

  private profileOptions(): SelectOption[] {
    return this.profiles.map((profile: RuleTarget): SelectOption => ({ value: this.profileLabel(profile) }));
  }

  private groupOptions(): SelectOption[] {
    return this.groups.map((group: AddressGroup): SelectOption => ({
      value: group.name + ' · ' + group.domains.length + ' 域名 / ' + group.cidrs.length + ' IP 段'
    }));
  }

  private selectedGroupIndex(): number {
    return this.groups.findIndex((group: AddressGroup): boolean => group.id === this.value);
  }

  private selectedGroupName(): string {
    const group = this.groups.find((item: AddressGroup): boolean => item.id === this.value);
    return group?.name || '选择已保存的地址组';
  }

  private changeKind(kind: string): void {
    if (this.kind === kind) { return; }
    this.kind = kind; this.error = '';
    this.value = kind === 'group' && this.groups.length > 0 ? this.groups[0].id : '';
  }

  private openGroups(): void { router.pushUrl({ url: 'pages/AddressGroupsPage' }); }

  private startAdd(): void {
    this.refreshLock();
    if (this.locked) { return; }
    this.editingKey = ''; this.editingTarget = ''; this.editingKind = ''; this.editingValue = '';
    this.kind = 'domain'; this.value = ''; this.error = ''; this.notice = ''; this.deleteKey = '';
    this.formOpen = true;
    this.scroller.scrollEdge(Edge.Top);
  }

  private startEdit(rule: CustomRule): void {
    this.refreshLock();
    if (this.locked) { return; }
    this.editingKey = rule.key(); this.editingTarget = rule.targetKey;
    this.editingKind = rule.kind; this.editingValue = rule.value;
    this.kind = rule.kind; this.value = rule.value; this.targetKey = rule.targetKey;
    this.error = ''; this.notice = ''; this.deleteKey = ''; this.formOpen = true;
    this.scroller.scrollEdge(Edge.Top);
  }

  private without(rules: ProfileRules, kind: string, value: string): void {
    if (kind === 'domain') {
      rules.manualDomains = rules.manualDomains.filter((item: string): boolean => item !== value);
    } else if (kind === 'ip') {
      rules.manualCidrs = rules.manualCidrs.filter((item: string): boolean => item !== value);
    } else {
      rules.groupIds = rules.groupIds.filter((item: string): boolean => item !== value);
    }
  }

  private insert(rules: ProfileRules, kind: string, value: string): void {
    if (kind === 'domain') { rules.manualDomains.push(value); }
    else if (kind === 'ip') { rules.manualCidrs.push(value); }
    else { rules.groupIds.push(value); }
    rules.enabled = true;
  }

  private save(): void {
    this.refreshLock();
    if (this.locked) { this.error = '连接信息尚未完整读取，请刷新后修改规则。'; return; }
    this.error = ''; this.notice = '';
    const normalized = this.canonical(this.kind, this.value);
    if (this.kind === 'domain') {
      if (!isDomainName(normalized) || parseIpPrefix(normalized) !== undefined) {
        this.error = '请输入有效域名，例如 example.com，不包含网址协议或路径。'; return;
      }
    } else if (this.kind === 'ip') {
      const prefix = parseIpPrefix(normalized);
      if (prefix === undefined || prefix.prefixLength === 0) {
        this.error = '请输入有效 IPv4／IPv6 地址或 CIDR 段，不支持 /0 默认路由。'; return;
      }
    }
    const requestedTarget = this.targetKey;
    this.reload();
    if (!this.metadataReady) { return; }
    if (this.kind === 'group' && !this.groups.some((group: AddressGroup): boolean => group.id === normalized)) {
      this.error = '请选择已保存的地址组；如尚未创建，请先打开“管理地址组”。'; return;
    }
    if (!requestedTarget || !this.profiles.some((profile: RuleTarget): boolean => profile.key() === requestedTarget)) {
      this.error = '所选连接已不存在，请重新选择连接。'; return;
    }
    this.targetKey = requestedTarget;
    if (this.editingKey && !this.rules.some((rule: CustomRule): boolean => rule.key() === this.editingKey)) {
      this.error = '此规则已被更改，请关闭表单后重新选择。'; return;
    }
    const duplicate = this.rules.find((rule: CustomRule): boolean => rule.key() !== this.editingKey &&
      rule.kind === this.kind && this.canonical(rule.kind, rule.value) === normalized);
    if (duplicate !== undefined) {
      this.error = '此规则已归属「' + duplicate.profileName + '」，请编辑已有规则调整归属。'; return;
    }
    const dir = this.directory();
    const targetProfile = this.profiles.find((profile: RuleTarget): boolean => profile.key() === this.targetKey);
    const sourceProfile = this.profiles.find((profile: RuleTarget): boolean => profile.key() === this.editingTarget);
    if (targetProfile === undefined || (this.editingKey && sourceProfile === undefined)) {
      this.error = '连接已不存在，请重新选择。'; return;
    }
    try {
      const target = readProfileRules(dir, targetProfile.ID);
      const beforeTarget = new ProfileRules(target.enabled, target.isDefault, target.lists.slice(),
        target.manualDomains.slice(), target.manualCidrs.slice(), target.groupIds.slice());
      if (this.editingKey && this.editingTarget === this.targetKey) {
        this.without(target, this.editingKind, this.editingValue);
      }
      this.insert(target, this.kind, normalized);
      if (targetProfile.Kind === 'wireguard') {
        target.isDefault = false;
        const collected = collectSplitRules(dir, target.lists);
        const expanded = expandProfileRules(dir, target);
        if (dedupeStrings(collected.rules.domains.concat(collected.rules.exacts).concat(expanded.manualDomains)).length > MAX_SPLIT_DOMAINS) {
          throw new Error('此 WireGuard 连接超过 ' + MAX_SPLIT_DOMAINS + ' 个域名规则上限，请减少域名库选择。');
        }
      }
      let source: ProfileRules | undefined = undefined;
      const overrides: CustomRuleOverride[] = [new CustomRuleOverride(targetProfile.ID, target)];
      if (this.editingKey && this.editingTarget !== this.targetKey && sourceProfile !== undefined) {
        source = readProfileRules(dir, sourceProfile.ID);
        this.without(source, this.editingKind, this.editingValue);
        overrides.push(new CustomRuleOverride(sourceProfile.ID, source));
      }
      validateCustomRuleAssignments(dir, this.profiles, overrides);
      writeProfileRules(dir, targetProfile.ID, target);
      if (source !== undefined && sourceProfile !== undefined) {
        try {
          writeProfileRules(dir, sourceProfile.ID, source);
        } catch (e) {
          writeProfileRules(dir, targetProfile.ID, beforeTarget);
          throw e as Error;
        }
        clearResolvedIps(dir, sourceProfile.ID);
      }
      clearResolvedIps(dir, targetProfile.ID);
      this.notice = '已保存，下次连接生效。' +
        (targetProfile.Kind === 'wireguard' && beforeTarget.isDefault ? '此 WireGuard 连接下次将仅处理匹配规则的流量。' : '');
      this.formOpen = false; this.editingKey = ''; this.value = ''; this.reload();
    } catch (e) { this.error = '保存失败：' + (e as Error).message; this.reload(); }
  }

  private remove(rule: CustomRule): void {
    this.refreshLock();
    if (this.locked) { this.error = '连接信息尚未完整读取，请刷新后删除规则。'; return; }
    this.reload();
    if (!this.metadataReady || !this.profiles.some((profile: RuleTarget): boolean => profile.key() === rule.targetKey)) {
      this.error = '连接已不存在或信息冲突，请重新选择。'; return;
    }
    try {
      const rules = readProfileRules(this.directory(), rule.profileId);
      this.without(rules, rule.kind, rule.value);
      writeProfileRules(this.directory(), rule.profileId, rules);
      clearResolvedIps(this.directory(), rule.profileId);
      this.deleteKey = ''; this.error = ''; this.notice = '已保存，下次连接生效。' +
        (rule.kind === 'group' ? '已移除组规则，地址组及成员仍保留。' : '此规则已从下次连接配置中删除。');
      if (rule.key() === this.editingKey) { this.formOpen = false; this.editingKey = ''; }
      this.reload();
    } catch (e) { this.error = '删除失败：' + (e as Error).message; }
  }

  @Builder
  private filterButton(value: string) {
    Button(value === 'all' ? '全部 ' + this.rules.length :
      value === 'domain' ? '域名 ' + this.count('domain') :
        value === 'group' ? '地址组 ' + this.count('group') : 'IP 段 ' + this.count('ip'))
      .fontSize(13).fontWeight(FontWeight.Medium).height(36)
      .fontColor(this.filter === value ? '#315EFB' : '#728097')
      .backgroundColor(this.filter === value ? '#EAF0FF' : '#FFFFFF')
      .borderRadius(12).padding({ left: 14, right: 14 })
      .onClick(() => this.filter = value)
  }

  @Builder
  private form() {
    Column({ space: 16 }) {
      Row() {
        Text(this.editingKey ? '编辑规则' : '添加规则').fontSize(19).fontWeight(FontWeight.Bold).fontColor('#172033')
        Blank()
        Button('取消').fontSize(13).height(32).backgroundColor('#F4F6FA').fontColor('#728097')
          .onClick(() => { this.formOpen = false; this.error = ''; })
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        Button('域名').height(38).padding({ left: 14, right: 14 }).borderRadius(12).fontSize(14)
          .backgroundColor(this.kind === 'domain' ? '#315EFB' : '#F4F6FA')
          .fontColor(this.kind === 'domain' ? Color.White : '#728097')
          .enabled(!this.locked).onClick(() => this.changeKind('domain'))
        Button('IP / CIDR').height(38).padding({ left: 14, right: 14 }).borderRadius(12).fontSize(14)
          .backgroundColor(this.kind === 'ip' ? '#315EFB' : '#F4F6FA')
          .fontColor(this.kind === 'ip' ? Color.White : '#728097')
          .enabled(!this.locked).onClick(() => this.changeKind('ip'))
        Button('地址组').height(38).padding({ left: 14, right: 14 }).borderRadius(12).fontSize(14)
          .backgroundColor(this.kind === 'group' ? '#315EFB' : '#F4F6FA')
          .fontColor(this.kind === 'group' ? Color.White : '#728097')
          .enabled(!this.locked).onClick(() => this.changeKind('group'))
      }.width('100%')
      Column({ space: 8 }) {
        Text(this.kind === 'group' ? '已保存的地址组' : (this.kind === 'domain' ? '域名' : 'IP 地址或 CIDR 段'))
          .fontSize(13).fontColor('#728097')
        if (this.kind === 'group') {
          if (this.groups.length > 0) {
            Select(this.groupOptions()).selected(this.selectedGroupIndex()).value(this.selectedGroupName())
              .width('100%').height(48).font({ size: 15 }).fontColor('#172033').backgroundColor('#F4F6FA')
              .borderRadius(12).enabled(!this.locked)
              .onSelect((index: number) => {
                if (index >= 0 && index < this.groups.length) { this.value = this.groups[index].id; }
              })
          }
          Text(this.groups.length > 0 ? '整组域名和 IP 段使用下方连接；编辑成员后，下次连接会使用更新后的地址组。' :
            '还没有地址组。先创建一个组并批量加入域名和 IP 段，再回到此处分配连接。')
            .fontSize(12).fontColor('#728097').lineHeight(18)
          Button('管理地址组').height(36).fontSize(13).fontColor('#315EFB').backgroundColor('#EAF0FF')
            .borderRadius(10).onClick(() => this.openGroups())
        } else {
          TextInput({ text: this.value, placeholder: this.kind === 'domain' ? 'example.com' : '192.168.1.0/24 或 2001:db8::/32' })
          .height(48).fontSize(15).backgroundColor('#F4F6FA').borderRadius(12).fontColor('#172033')
          .enabled(!this.locked).onChange((value: string) => this.value = value)
          Text(this.kind === 'domain' ? '同时匹配该域名及其子域名，无需填写 *。' : '单个 IP 会自动转换为 /32 或 /128；网段会自动规范化。')
          .fontSize(12).fontColor('#728097').lineHeight(18)
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 8 }) {
        Text('使用连接').fontSize(13).fontColor('#728097')
        Select(this.profileOptions()).selected(this.selectedIndex()).value(this.selectedName())
          .width('100%').height(48).font({ size: 15 }).fontColor('#172033').backgroundColor('#F4F6FA')
          .borderRadius(12).enabled(!this.locked)
          .onSelect((index: number) => {
            if (index >= 0 && index < this.profiles.length) { this.targetKey = this.profiles[index].key(); }
          })
      }.width('100%').alignItems(HorizontalAlign.Start)
      if (this.selectedWireGuard()) {
        Text('下次连接会启用此 WireGuard 连接的分流规则，并取消它的默认路由角色。IP 段须由对端 AllowedIPs 允许。')
          .fontSize(12).fontColor('#9A6B23').lineHeight(18)
        Text('域名匹配需要系统 DNS。浏览器安全 DNS（DoH）或旧 DNS 缓存可能绕过识别；若结果异常，请关闭安全 DNS 并重开浏览器。')
          .fontSize(12).fontColor('#728097').lineHeight(18)
      }
      Button(this.editingKey ? '保存修改' : '添加规则').width('100%').height(46).borderRadius(14)
        .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Color.White).backgroundColor('#315EFB')
        .enabled(!this.locked && this.value.trim().length > 0 && this.targetKey.length > 0)
        .onClick(() => this.save())
    }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(20)
      .border({ width: 1, color: '#D9E3FF' })
  }

  @Builder
  private ruleRow(rule: CustomRule) {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Text(rule.kind === 'group' ? '组' : (rule.kind === 'domain' ? '域' : 'IP')).fontSize(rule.kind === 'ip' ? 13 : 17)
          .fontWeight(FontWeight.Bold).fontColor(rule.kind === 'domain' ? '#315EFB' : '#167A68')
          .width(42).height(42).textAlign(TextAlign.Center).borderRadius(13)
          .backgroundColor(rule.kind === 'domain' ? '#EAF0FF' : '#E7F5F0')
        Column({ space: 5 }) {
          Text(rule.kind === 'group' ? rule.groupName : rule.value).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#172033')
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text((rule.kind === 'group' ? '地址组 · ' + rule.domainCount + ' 域名 / ' + rule.cidrCount + ' IP 段' :
            (rule.kind === 'domain' ? '域名及子域名' : 'IP 段')) + '  ·  ' + rule.profileName)
            .fontSize(12).fontColor('#728097').width('100%').maxLines(2)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (!rule.enabled) {
          Text('未启用').fontSize(11).fontColor('#9A6B23').padding({ left: 7, right: 7, top: 4, bottom: 4 })
            .backgroundColor('#FFF5DF').borderRadius(6)
        }
      }.width('100%').alignItems(VerticalAlign.Center)
      if (this.deleteKey === rule.key()) {
        Column({ space: 10 }) {
          Text(rule.kind === 'group' ? '移除此地址组规则？地址组和成员会保留，下次连接不再通过此组规则分流。' :
            '删除此规则？下次连接时，该目标将不再通过这条规则使用连接。').fontSize(13).fontColor('#9B3A3A').lineHeight(19)
          Row({ space: 8 }) {
            Button('保留').height(34).fontSize(13).fontColor('#728097').backgroundColor(Color.White)
              .onClick(() => this.deleteKey = '')
            Button('确认删除').height(34).fontSize(13).fontColor(Color.White).backgroundColor('#C74444')
              .enabled(!this.locked).onClick(() => this.remove(rule))
          }.width('100%').justifyContent(FlexAlign.End)
        }.width('100%').padding(12).backgroundColor('#FFF1F1').borderRadius(12)
      } else {
        Row({ space: 8 }) {
          Text('→ ' + rule.profileName).fontSize(12).fontColor('#315EFB').layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('编辑').height(32).fontSize(12).fontColor('#315EFB').backgroundColor('#EAF0FF').borderRadius(10)
            .enabled(!this.locked).onClick(() => this.startEdit(rule))
          Button('删除').height(32).fontSize(12).fontColor('#728097').backgroundColor('#F4F6FA').borderRadius(10)
            .enabled(!this.locked).onClick(() => { this.refreshLock(); if (!this.locked) { this.deleteKey = rule.key(); } })
        }.width('100%')
      }
    }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: '#E4E9F2' })
  }

  @Builder
  private ruleCollection() {
    Column({ space: 20 }) {
      if (this.profiles.length === 0) {
        Column({ space: 14 }) {
          Text('先创建一个连接').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#172033')
          Text('添加 Tailscale、Headscale 或 WireGuard 连接后，就可以为域名和 IP 段分配出口。')
            .fontSize(14).fontColor('#728097').textAlign(TextAlign.Center).lineHeight(22)
          Button('前往连接').height(42).fontSize(14).fontColor(Color.White).backgroundColor('#315EFB')
            .borderRadius(13).onClick(() => router.replaceUrl({ url: 'pages/NetworksPage' }))
        }.width('100%').padding({ left: 24, right: 24, top: 36, bottom: 36 })
          .backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: '#E4E9F2' })
      } else {
        Column({ space: 12 }) {
          TextInput({ text: this.query, placeholder: '搜索域名、IP、地址组或连接名称' }).height(48).fontSize(14)
            .backgroundColor(Color.White).borderRadius(14).fontColor('#172033')
            .border({ width: 1, color: '#E4E9F2' }).onChange((value: string) => this.query = value)
          Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
            this.filterButton('all')
            this.filterButton('domain')
            this.filterButton('ip')
            this.filterButton('group')
          }.width('100%')
        }.width('100%')
        if (this.visibleRules().length === 0) {
          Column({ space: 12 }) {
            Text(this.rules.length === 0 ? '还没有自定义规则' : '没有匹配的规则')
              .fontSize(19).fontWeight(FontWeight.Medium).fontColor('#172033')
            Text(this.rules.length === 0 ? '添加域名、IP 段或整个地址组，指定它们使用的连接。' : '试试其他关键词，或切换到全部规则。')
              .fontSize(14).fontColor('#728097').lineHeight(22).textAlign(TextAlign.Center)
            if (this.rules.length === 0 && !this.formOpen) {
              Button('添加第一条规则').height(42).fontSize(14).fontColor('#315EFB').backgroundColor('#EAF0FF')
                .borderRadius(13).enabled(!this.locked).onClick(() => this.startAdd())
            }
          }.width('100%').padding({ left: 24, right: 24, top: 36, bottom: 36 })
            .backgroundColor(Color.White).borderRadius(20).border({ width: 1, color: '#E4E9F2' })
        } else {
          GridRow({ columns: this.contentWidth >= 800 && !this.formOpen ? 2 : 1, gutter: 12 }) {
            ForEach(this.visibleRules(), (rule: CustomRule) => {
              GridCol() { this.ruleRow(rule) }
            },
              (rule: CustomRule): string => rule.key() + ':' + rule.enabled.toString() + ':' + rule.profileName +
                ':' + rule.groupName + ':' + rule.domainCount + ':' + rule.cidrCount)
          }.width('100%')
        }
        Text('可同时启用多个 Tailnet 和 WireGuard，按域名及子域名、IP 段分配出口，支持 TCP / UDP。已匹配的规则连接失败时不会改走直连；完全相同的规则只能归属一个连接。')
          .fontSize(12).fontColor('#728097').lineHeight(20).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private pageContent() {
    Scroll(this.scroller) {
      Column({ space: 20 }) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceBetween,
          space: { main: LengthMetrics.vp(16), cross: LengthMetrics.vp(12) } }) {
          Column({ space: 7 }) {
            Text('自定义规则').fontSize(this.contentWidth < 440 ? 26 : 30).fontWeight(FontWeight.Bold).fontColor('#172033')
            Text('已保存规则 · 下次连接使用').fontSize(14).fontColor('#728097')
          }.alignItems(HorizontalAlign.Start)
          if (this.profiles.length > 0) {
            Button('＋ 添加').height(42).fontSize(14).fontWeight(FontWeight.Medium).fontColor(Color.White)
              .backgroundColor('#315EFB').borderRadius(14).padding({ left: 16, right: 16 })
              .enabled(!this.locked).onClick(() => this.startAdd())
          }
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center,
          space: { main: LengthMetrics.vp(16), cross: LengthMetrics.vp(12) } }) {
          Column({ space: 5 }) {
            Text('地址组').fontSize(17).fontWeight(FontWeight.Medium).fontColor('#172033')
            Text('批量维护域名和 IP 段，再整组分配给连接。').fontSize(13).fontColor('#728097').lineHeight(19)
          }.alignItems(HorizontalAlign.Start).flexGrow(1).constraintSize({ maxWidth: '100%' })
          Button('管理地址组').height(40).fontSize(14).fontColor('#315EFB').backgroundColor('#EAF0FF')
            .borderRadius(12).onClick(() => this.openGroups())
        }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(18)
          .border({ width: 1, color: '#D9E3FF' })
        GridRow({ columns: this.contentWidth < 520 ? 2 : 4, gutter: 16 }) {
          GridCol() {
            Column({ space: 6 }) {
              Text(this.count('domain').toString()).fontSize(27).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('域名规则').fontSize(12).fontColor('#728097')
            }.alignItems(HorizontalAlign.Start).width('100%')
          }
          GridCol() {
            Column({ space: 6 }) {
              Text(this.count('group').toString()).fontSize(27).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('地址组规则').fontSize(12).fontColor('#728097')
            }.alignItems(HorizontalAlign.Start).width('100%')
          }
          GridCol() {
            Column({ space: 6 }) {
              Text(this.count('ip').toString()).fontSize(27).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('IP 段规则').fontSize(12).fontColor('#728097')
            }.alignItems(HorizontalAlign.Start).width('100%')
          }
          GridCol() {
            Column({ space: 6 }) {
              Text(this.profiles.length.toString()).fontSize(27).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('可分配连接').fontSize(12).fontColor('#728097')
            }.alignItems(HorizontalAlign.Start).width('100%')
          }
        }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(20)
          .border({ width: 1, color: '#E4E9F2' })
        if (this.connected && this.metadataReady) {
          Text('当前连接继续使用启动时的规则，可在此编辑下次连接配置。保存后手动断开并连接生效，自动恢复不改变当前规则。')
            .fontSize(13).fontColor('#5C6E94').lineHeight(20).width('100%')
            .padding(16).backgroundColor('#EAF0FF').borderRadius(14)
        }
        if (this.error) {
          Text(this.error).fontSize(13).fontColor('#B23D3D').lineHeight(20).width('100%')
            .padding(14).backgroundColor('#FFF0F0').borderRadius(14)
        }
        if (this.notice) {
          Text(this.notice).fontSize(13).fontColor('#167A68').lineHeight(20).width('100%')
            .padding(14).backgroundColor('#E7F5F0').borderRadius(14)
        }
        Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
          alignItems: ItemAlign.Start }) {
          if (this.formOpen && this.profiles.length > 0) {
            Column() { this.form() }
              .width(this.contentWidth >= 800 ? '42%' : '100%')
              .padding({ right: this.contentWidth >= 800 ? 20 : 0, bottom: this.contentWidth >= 800 ? 0 : 20 })
          }
          Column() { this.ruleCollection() }
            .width(this.formOpen && this.profiles.length > 0 && this.contentWidth >= 800 ? '58%' : '100%')
        }.width('100%')
      }.width('100%').constraintSize({ maxWidth: 1440 })
        .padding({ left: this.contentWidth < 600 ? 16 : 28, right: this.contentWidth < 600 ? 16 : 28,
          top: 28, bottom: 32 })
        .onAreaChange((_oldArea: Area, area: Area) => {
          const width = Number(area.width);
          if (width > 0 && Math.abs(width - this.contentWidth) > 1) { this.contentWidth = width; }
        })
    }.width('100%').height('100%').align(Alignment.Top).scrollBar(BarState.Auto)
  }

  build() {
    Column() {
      WorkspaceShell({ active: 'rules', title: '自定义规则' }) { this.pageContent() }
    }.width('100%').height('100%')
  }
}
