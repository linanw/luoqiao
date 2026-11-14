import { common } from '@kit.AbilityKit';
import { router, LengthMetrics } from '@kit.ArkUI';
import { WorkspaceShell } from '../components/WorkspaceShell';
import { dismissWorkspaceDrawer } from '../model/WorkspaceNavigation';
import { AddressGroup, readAddressGroups, saveAddressGroup, deleteAddressGroup, parseAddressGroupEntries,
  MAX_ADDRESS_GROUP_INPUT_LENGTH, MAX_ADDRESS_GROUP_NAME_LENGTH } from '../model/AddressGroups';
import { readRuleTargets, ruleConnectionsActive } from '../model/RuleTargets';
import { readProfileRules } from '../model/SplitTunnel';
import { validateCustomRuleAssignments } from '../model/CustomRuleConflicts';

class GroupAssignment {
  id: string;
  owners: string[];
  constructor(id: string, owners: string[]) { this.id = id; this.owners = owners; }
}

@Entry
@Component
struct AddressGroupsPage {
  @State private groups: AddressGroup[] = [];
  @State private assignments: GroupAssignment[] = [];
  @State private query: string = '';
  @State private contentWidth: number = 0;
  @State private connected: boolean = false;
  @State private ready: boolean = false;
  @State private formOpen: boolean = false;
  @State private editingId: string = '';
  @State private name: string = '';
  @State private members: string = '';
  @State private additions: string = '';
  @State private appendMode: boolean = false;
  @State private deleteId: string = '';
  @State private error: string = '';
  @State private notice: string = '';
  @State private preview: string = '';
  @State private revision: number = 0;
  private editingSnapshot: string = '';
  private timer: number = -1;
  private scroller: Scroller = new Scroller();

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private directory(): string { return this.context().filesDir; }

  aboutToAppear(): void { this.resume(); }
  onPageShow(): void { this.resume(); }
  onPageHide(): void { this.pause(); }
  onBackPress(): boolean { return dismissWorkspaceDrawer(); }
  aboutToDisappear(): void { this.pause(); }

  private resume(): void {
    this.reload();
    if (this.timer < 0) {
      this.timer = setInterval(() => { this.connected = ruleConnectionsActive(this.directory()); }, 2000);
    }
  }

  private pause(): void {
    if (this.timer >= 0) { clearInterval(this.timer); this.timer = -1; }
  }

  private reload(): void {
    this.ready = false;
    try {
      const groups = readAddressGroups(this.directory());
      const profiles = readRuleTargets(this.context());
      const assignments: GroupAssignment[] = [];
      for (const group of groups) { assignments.push(new GroupAssignment(group.id, [])); }
      for (const profile of profiles) {
        for (const id of readProfileRules(this.directory(), profile.ID).groupIds) {
          const assignment = assignments.find((item: GroupAssignment): boolean => item.id === id);
          if (assignment) { assignment.owners.push(profile.label()); }
        }
      }
      this.groups = groups; this.assignments = assignments;
      this.revision++;
      this.connected = ruleConnectionsActive(this.directory());
      this.ready = true;
    } catch (e) { this.error = '无法读取地址组，已暂停编辑：' + (e as Error).message; }
  }

  private visibleGroups(): AddressGroup[] {
    const keyword = this.query.trim().toLowerCase();
    return this.groups.filter((group: AddressGroup): boolean => !keyword || group.name.toLowerCase().includes(keyword) ||
      group.domains.some((value: string): boolean => value.toLowerCase().includes(keyword)) ||
      group.cidrs.some((value: string): boolean => value.toLowerCase().includes(keyword)));
  }

  private countDomains(): number {
    let count = 0;
    for (const group of this.groups) { count += group.domains.length; }
    return count;
  }

  private countCidrs(): number {
    let count = 0;
    for (const group of this.groups) { count += group.cidrs.length; }
    return count;
  }

  private owners(id: string): string[] {
    return this.assignments.find((item: GroupAssignment): boolean => item.id === id)?.owners || [];
  }

  private memberPreview(group: AddressGroup): string {
    const members = group.domains.concat(group.cidrs);
    return members.length > 0 ? members.slice(0, 4).join('  ·  ') + (members.length > 4 ? '  …' : '') :
      '空地址组，可编辑或批量追加成员。';
  }

  private startAdd(): void {
    if (!this.ready) { return; }
    this.editingId = ''; this.editingSnapshot = ''; this.name = ''; this.members = ''; this.additions = '';
    this.appendMode = false; this.error = ''; this.notice = ''; this.preview = ''; this.deleteId = '';
    this.formOpen = true; this.scroller.scrollEdge(Edge.Top);
  }

  private startEdit(group: AddressGroup, append: boolean = false): void {
    if (!this.ready) { return; }
    this.editingId = group.id; this.editingSnapshot = JSON.stringify(group);
    this.name = group.name; this.members = group.domains.concat(group.cidrs).join('\n'); this.additions = '';
    this.appendMode = append; this.error = ''; this.notice = ''; this.preview = ''; this.deleteId = '';
    this.formOpen = true; this.scroller.scrollEdge(Edge.Top);
  }

  private draftText(): string { return this.appendMode ? this.members + '\n' + this.additions : this.members; }

  private inspectDraft(): void {
    this.error = ''; this.preview = '';
    try {
      const parsed = parseAddressGroupEntries(this.draftText());
      this.preview = '有效成员：' + parsed.domains.length + ' 个域名、' + parsed.cidrs.length + ' 个 IP 段。' +
        (parsed.duplicates > 0 ? '已合并 ' + parsed.duplicates + ' 个重复项。' : '');
    } catch (e) { this.error = (e as Error).message; }
  }

  private save(): void {
    if (!this.ready) { return; }
    this.error = ''; this.notice = '';
    try {
      const currentGroups = readAddressGroups(this.directory());
      const current = currentGroups.find((group: AddressGroup): boolean => group.id === this.editingId);
      if (this.editingId && (!current || JSON.stringify(current) !== this.editingSnapshot)) {
        throw new Error('地址组已被更改或删除，请重新打开此组后编辑。');
      }
      if (this.appendMode && !this.additions.trim()) { throw new Error('请先粘贴要追加的域名或 IP 段。'); }
      const parsed = parseAddressGroupEntries(this.draftText());
      const group = new AddressGroup(this.editingId, this.name.trim(), parsed.domains, parsed.cidrs);
      if (group.id) { validateCustomRuleAssignments(this.directory(), readRuleTargets(this.context()), [], group); }
      const saved = saveAddressGroup(this.directory(), group);
      this.formOpen = false; this.editingId = ''; this.editingSnapshot = ''; this.preview = '';
      this.members = ''; this.additions = '';
      this.notice = '已保存「' + saved.name + '」：' + saved.domains.length + ' 个域名、' + saved.cidrs.length +
        ' 个 IP 段。下次连接生效。' + (parsed.duplicates > 0 ? '已合并 ' + parsed.duplicates + ' 个重复项。' : '');
      this.reload();
    } catch (e) { this.error = '保存失败：' + (e as Error).message; }
  }

  private requestDelete(group: AddressGroup): void {
    if (!this.ready) { return; }
    this.error = ''; this.notice = ''; this.reload();
    if (!this.ready) { return; }
    if (this.owners(group.id).length > 0) {
      this.error = '「' + group.name + '」仍被自定义规则引用，请先在自定义规则中移除此组规则，再删除地址组。';
      this.deleteId = ''; return;
    }
    this.deleteId = group.id;
  }

  private remove(group: AddressGroup): void {
    if (!this.ready) { return; }
    try {
      deleteAddressGroup(this.directory(), group.id);
      this.deleteId = ''; this.error = ''; this.notice = '已删除地址组「' + group.name + '」。下次连接配置已更新。';
      if (this.editingId === group.id) { this.formOpen = false; this.editingId = ''; this.editingSnapshot = ''; }
      this.reload();
    } catch (e) { this.error = '删除失败：' + (e as Error).message; this.deleteId = ''; this.reload(); }
  }

  private backToRules(): void {
    const url = 'pages/CustomRulesPage';
    const currentIndex = router.getState().index;
    if (router.getStateByUrl(url).some((state: router.RouterState): boolean => state.index < currentIndex)) {
      router.back({ url: url });
    } else {
      router.replaceUrl({ url: url });
    }
  }

  @Builder
  private editor() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Text(this.appendMode ? '批量追加成员' : (this.editingId ? '编辑地址组' : '新建地址组'))
          .fontSize(19).fontWeight(FontWeight.Bold).fontColor('#172033').layoutWeight(1)
        Button('取消').height(34).fontSize(13).fontColor('#728097').backgroundColor('#F4F6FA')
          .onClick(() => { this.formOpen = false; this.error = ''; this.preview = ''; })
      }.width('100%')
      Column({ space: 8 }) {
        Text('地址组名称').fontSize(13).fontColor('#728097')
        TextInput({ text: this.name, placeholder: '例如：工作服务、家庭设备' }).height(48).fontSize(15)
          .maxLength(MAX_ADDRESS_GROUP_NAME_LENGTH).fontColor('#172033').backgroundColor('#F4F6FA').borderRadius(12)
          .enabled(this.ready).onChange((value: string) => this.name = value)
      }.width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 8 }) {
        Text(this.appendMode ? '追加域名和 IP 段（原成员全部保留）' : '域名和 IP 段（此处为完整成员列表）')
          .fontSize(13).fontColor('#728097')
        TextArea({ text: this.appendMode ? this.additions : this.members,
          placeholder: 'example.com\n192.168.72.0/24\n2001:db8::/32' })
          .height(220).fontSize(14).fontColor('#172033').backgroundColor('#F4F6FA').borderRadius(12)
          .maxLength(MAX_ADDRESS_GROUP_INPUT_LENGTH).enabled(this.ready)
          .onChange((value: string) => {
            if (this.appendMode) { this.additions = value; } else { this.members = value; }
            this.preview = '';
          })
        Text('可混合使用换行、逗号、分号或空白分隔。域名包括子域名；IP 自动规范化，重复项合并。任一条无效时整次保存失败。')
          .fontSize(12).fontColor('#728097').lineHeight(19)
        if (this.appendMode) {
          Text('追加只增加新成员；要移除旧成员，请取消后使用“编辑”。').fontSize(12).fontColor('#5C6E94').lineHeight(19)
        }
      }.width('100%').alignItems(HorizontalAlign.Start)
      if (this.preview) { Text(this.preview).fontSize(13).fontColor('#167A68').width('100%') }
      Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(10), cross: LengthMetrics.vp(10) } }) {
        Button('检查条目').height(44).fontSize(14).fontColor('#315EFB').backgroundColor('#EAF0FF')
          .borderRadius(12).enabled(this.ready).onClick(() => this.inspectDraft())
        Button(this.appendMode ? '追加并保存' : '保存地址组').height(44).fontSize(14).fontColor(Color.White)
          .backgroundColor('#315EFB').borderRadius(12).flexGrow(1)
          .enabled(this.ready && this.name.trim().length > 0 && (!this.appendMode || this.additions.trim().length > 0))
          .onClick(() => this.save())
      }.width('100%')
    }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(20)
      .border({ width: 1, color: '#D9E3FF' })
  }

  @Builder
  private groupRow(group: AddressGroup) {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Text('组').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#315EFB')
          .width(42).height(42).textAlign(TextAlign.Center).backgroundColor('#EAF0FF').borderRadius(13)
        Column({ space: 5 }) {
          Text(group.name).fontSize(17).fontWeight(FontWeight.Medium).fontColor('#172033')
            .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(group.domains.length + ' 个域名  ·  ' + group.cidrs.length + ' 个 IP 段')
            .fontSize(12).fontColor('#728097')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text(this.memberPreview(group)).fontSize(13).fontColor('#728097').lineHeight(20).maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Text(this.owners(group.id).length > 0 ? '用于：' + this.owners(group.id).join('、') : '尚未加入自定义规则')
        .fontSize(12).fontColor(this.owners(group.id).length > 0 ? '#315EFB' : '#728097').width('100%').lineHeight(18)
      if (this.deleteId === group.id) {
        Column({ space: 10 }) {
          Text('删除此地址组及全部成员？此操作仅允许用于没有规则引用的地址组。')
            .fontSize(13).fontColor('#9B3A3A').lineHeight(19)
          Row({ space: 8 }) {
            Button('保留').height(34).fontSize(13).fontColor('#728097').backgroundColor(Color.White)
              .onClick(() => this.deleteId = '')
            Button('确认删除').height(34).fontSize(13).fontColor(Color.White).backgroundColor('#C74444')
              .enabled(this.ready).onClick(() => this.remove(group))
          }.width('100%').justifyContent(FlexAlign.End)
        }.width('100%').padding(12).backgroundColor('#FFF1F1').borderRadius(12)
      } else {
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
          Button('编辑').height(34).fontSize(13).fontColor('#315EFB').backgroundColor('#EAF0FF').borderRadius(10)
            .enabled(this.ready).onClick(() => this.startEdit(group))
          Button('批量追加').height(34).fontSize(13).fontColor('#315EFB').backgroundColor('#EAF0FF').borderRadius(10)
            .enabled(this.ready).onClick(() => this.startEdit(group, true))
          Button('删除').height(34).fontSize(13).fontColor('#728097').backgroundColor('#F4F6FA').borderRadius(10)
            .enabled(this.ready).onClick(() => this.requestDelete(group))
        }.width('100%')
      }
    }.width('100%').padding(18).backgroundColor(Color.White).borderRadius(20)
      .border({ width: 1, color: '#E4E9F2' })
  }

  @Builder
  private groupCollection() {
    Column({ space: 20 }) {
      TextInput({ text: this.query, placeholder: '搜索地址组名称、域名或 IP 段' }).height(48).fontSize(14)
        .fontColor('#172033').backgroundColor(Color.White).borderRadius(14)
        .border({ width: 1, color: '#E4E9F2' }).onChange((value: string) => this.query = value)
      if (this.visibleGroups().length === 0) {
        Column({ space: 12 }) {
          Text(this.groups.length === 0 ? '还没有地址组' : '没有匹配的地址组')
            .fontSize(19).fontWeight(FontWeight.Medium).fontColor('#172033')
          Text(this.groups.length === 0 ? '新建一个组，粘贴多个域名和 IP 段，之后可一次添加整组规则。' : '试试其他组名或成员地址。')
            .fontSize(14).fontColor('#728097').lineHeight(22).textAlign(TextAlign.Center)
        }.width('100%').padding(30).backgroundColor(Color.White).borderRadius(20)
      } else {
        GridRow({ columns: this.contentWidth >= 800 && !this.formOpen ? 2 : 1, gutter: 12 }) {
          ForEach(this.visibleGroups(), (group: AddressGroup) => {
            GridCol() { this.groupRow(group) }
          },
            (group: AddressGroup): string => group.id + ':' + this.revision)
        }.width('100%')
      }
      Text('同一地址组只能归属一个连接；可在自定义规则中编辑迁移。同一连接可以使用多个组。删除组规则会保留地址组，被规则引用的组不能直接删除。')
        .fontSize(12).fontColor('#728097').lineHeight(20).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private pageContent() {
    Scroll(this.scroller) {
      Column({ space: 20 }) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center, justifyContent: FlexAlign.SpaceBetween,
          space: { main: LengthMetrics.vp(16), cross: LengthMetrics.vp(12) } }) {
          Column({ space: 7 }) {
            Text('地址组').fontSize(this.contentWidth < 440 ? 26 : 30).fontWeight(FontWeight.Bold).fontColor('#172033')
            Text('一起管理域名和 IP 段').fontSize(14).fontColor('#728097')
          }.alignItems(HorizontalAlign.Start)
          Button('新建地址组').height(42).fontSize(14).fontColor(Color.White).backgroundColor('#315EFB')
            .borderRadius(14).enabled(this.ready).onClick(() => this.startAdd())
        }.width('100%')
        GridRow({ columns: 3, gutter: 12 }) {
          GridCol() {
            Column({ space: 6 }) {
              Text(this.groups.length.toString()).fontSize(27).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('地址组').fontSize(12).fontColor('#728097')
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
          GridCol() {
            Column({ space: 6 }) {
              Text(this.countDomains().toString()).fontSize(27).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('组内域名').fontSize(12).fontColor('#728097')
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
          GridCol() {
            Column({ space: 6 }) {
              Text(this.countCidrs().toString()).fontSize(27).fontWeight(FontWeight.Bold).fontColor('#172033')
              Text('组内 IP 段').fontSize(12).fontColor('#728097')
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
        }.width('100%').padding(20).backgroundColor(Color.White).borderRadius(20)
          .border({ width: 1, color: '#E4E9F2' })
        Column({ space: 10 }) {
          Text(this.connected ? '当前连接继续使用启动时的成员。这里保存的组和规则在下次手动断开并连接后生效，自动恢复不改变当前规则。' :
            '创建地址组后，在“自定义规则”中选择规则类型“地址组”，将整组分配给 WireGuard 或 Tailnet。保存后下次连接生效。')
            .fontSize(13).fontColor('#5C6E94').lineHeight(20).width('100%')
          Button('前往自定义规则').height(36).fontSize(13).fontColor('#315EFB').backgroundColor(Color.White)
            .borderRadius(10).onClick(() => this.backToRules())
        }.width('100%').padding(16).backgroundColor('#EAF0FF').borderRadius(14).alignItems(HorizontalAlign.Start)
        if (this.error) {
          Text(this.error).fontSize(13).fontColor('#B23D3D').lineHeight(20).width('100%')
            .padding(14).backgroundColor('#FFF0F0').borderRadius(14)
        }
        if (this.notice) {
          Text(this.notice).fontSize(13).fontColor('#167A68').lineHeight(20).width('100%')
            .padding(14).backgroundColor('#E7F5F0').borderRadius(14)
        }
        if (!this.ready) {
          Button('重新读取').height(38).fontSize(14).fontColor('#315EFB').backgroundColor('#EAF0FF')
            .onClick(() => { this.error = ''; this.reload(); })
        }
        Flex({ direction: this.contentWidth >= 800 ? FlexDirection.Row : FlexDirection.Column,
          alignItems: ItemAlign.Start }) {
          if (this.formOpen) {
            Column() { this.editor() }
              .width(this.contentWidth >= 800 ? '46%' : '100%')
              .padding({ right: this.contentWidth >= 800 ? 20 : 0, bottom: this.contentWidth >= 800 ? 0 : 20 })
          }
          Column() { this.groupCollection() }
            .width(this.formOpen && this.contentWidth >= 800 ? '54%' : '100%')
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
      WorkspaceShell({ active: 'groups', title: '地址组' }) { this.pageContent() }
    }.width('100%').height('100%')
  }
}
