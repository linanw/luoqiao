# 络桥 for HarmonyOS

络桥是一款统一管理 WireGuard、Tailscale / Headscale 连接与分流规则的 HarmonyOS 应用。1.7.1 起采用此名称，支持覆盖升级并保留已有配置和登录。

当前源码版本 **1.9.0 / 1000017**，面向 HarmonyOS 6.1（API 23）ARM64 手机和平板。公共仓库交付源码，不含签名安装包、个人配置或证书。由使用者在 DevEco Studio 自动签名并构建。

**另一台电脑或 Codex 接手：**先读 [接手文档](docs/HANDOFF.md) 和 [AGENTS.md](AGENTS.md)。环境配置见 [SETUP](docs/SETUP.md)，代码结构见 [ARCHITECTURE](docs/ARCHITECTURE.md)，测试命令见 [TESTING](docs/TESTING.md)，历史结果与限制见 [VALIDATION](docs/VALIDATION.md)。

1.9.0 改为自适应侧栏：窗口宽度达到 960vp 时显示完整侧栏，600–959vp 使用图标与标签的紧凑侧栏，低于 600vp 使用菜单抽屉。连接、域名库、自定义规则、地址组、路由检查、重叠网段和运行诊断均可直接进入。连接卡片、规则编辑区和配置表单随可用内容宽度切换列数；竖屏和悬浮窗保持单列可滚动布局。调整窗口时保留未保存的编辑内容，PureVPN 网页保持同一组件，窄屏可收起设置扩大网页空间。

1.8.2 增加回到前台后的原会话恢复、每分钟资源采样和「运行诊断」页面，并减少重复域名索引与 DNS 缓冲分配。恢复前检查扩展心跳、系统 VPN 和配置更新状态；主动断开不恢复，自动恢复使用原规则快照。**整个应用在后台被系统终止后，目前仍需要重新打开应用触发恢复，不具备系统托管的后台自动拉起能力。**

1.8.2 真机熄屏／唤醒测试仍出现一次系统 `LowMemoryKill`，持续不断线验收未通过；回到应用后约 9 秒恢复原 WireGuard 与 Tailnet 会话，NAS MagicDNS 实际通信恢复。详情与资源样本见[验收记录](docs/VALIDATION.md)。

1.8.1 修复所用 OpenHarmony Go 工具链在查询网卡时未关闭 UDP 句柄、未释放地址列表的问题。真机曾记录到句柄持续增长后被系统终止；补丁同时进入 WireGuard 组合与独立 Tailnet 原生库，构建脚本会自动校验并应用。资源释放修复不等于免受低内存回收，详见[公开验收摘要](docs/VALIDATION.md)。

首页使用「连接」统一管理 Tailnet（Tailscale / Headscale）与 WireGuard，每份配置直接显示在列表中，支持搜索和类型筛选。点「新建」选择连接类型：Tailnet 填写网络信息，WireGuard 导入或粘贴 `.conf`。侧栏分别管理 v2fly 域名库、自定义域名 / IP 规则和地址组，两种连接都能作为规则目标。原有 Tailnet 登录保留独立卡片。实现范围和构建方式见 [Tailnet 说明](tailnet/README.md)。

1.4.0 起，在列表启用需要的 WireGuard 和 Tailnet，再点「连接所选连接」，可在同一个系统 VPN 内同时运行多份连接。每条 WireGuard 使用独立加密设备与网络栈，每个 Tailnet 保持独立身份；分别显示握手、流量或登录状态。原有 Tailnet 登录可直接参与组合。WireGuard 卡片的「单独连接」仍只启动该配置。

1.5.0 将原有 Tailnet 与新建 Tailnet 的配置页统一：名称、节点名、控制服务器、公网出口和参与开关采用相同布局，运行中可查看组合状态、设备地址、MagicDNS 及打开浏览器登录。原有登录身份沿用，控制服务器保持固定；设备与路由详情可展开查看。

域名 / IP 规则决定每个请求的出口，Tailnet 设备、已公布子网及完整 MagicDNS 名称自动识别。1.4.2 同时识别控制服务器下发的真实节点短名；不同 Tailnet 有同名节点时，需要用明确规则指定归属。局域网主机简称不等于已注册的 MagicDNS 名称。未匹配流量按唯一默认 WireGuard 的 AllowedIPs 路由，没有默认出口则直连。多个完整默认出口会拒绝启动；为其他连接设置站点 / IP 规则后即可并行。两种连接都命中同等优先级规则时拒绝该流量；选中连接失败不会退回直连。组合中一条连接尚未握手或等待登录，不妨碍其他已就绪连接转发。

1.5.0 已在真机验证 2 个 WireGuard + 1 个 Tailscale 的 4G→Wi-Fi→4G 自动恢复，切换期间保留同一 VPN 会话、两条独立出口及 MagicDNS。浏览器可能在切换瞬间报 `ERR_NETWORK_CHANGED`，需要刷新，不能承诺页面请求零中断。Wi-Fi 与 Tailnet 子网重叠时，不以裸 IP 网页可达证明隧道；本轮使用 MagicDNS 页面及对应 Tailnet 路由事件交叉验证。尚未确认系统对重叠裸 IP 的强制 VPN 路由能力。详见 [验收记录](docs/VALIDATION.md)。

1.6.0 新增「连接 → 重叠网段」，可为每个 IPv4／IPv6 网段独立选择本地或指定 Tailnet 优先。域名经应用 DNS 解析后按偏好转发，并随底层网络变化重选；原始 IP 仍受系统本地路由优先级限制。详见文末说明。

1.7.0 新增「连接 → 路由检查」，可输入域名或 IP 查看当前生效的连接。运行中可以编辑分流规则，保存后在下一次手动连接生效，自动恢复继续使用原会话快照。PureVPN 支持正常登录会话持久化及有证据的恢复队列；完全后台、无人参与的续期仍有限制。

1.8.0 新增「自定义规则 → 管理地址组」。可以创建命名地址组，混合粘贴多条域名、IPv4／IPv6 地址和 CIDR 网段，支持换行、空格、逗号及分号分隔；支持批量追加、编辑成员、重命名和搜索。保存时自动去重、规范化网段，遇到无效地址则提示位置并拒绝整批保存，避免只导入部分内容。

在自定义规则中选择「地址组」，即可将整组分配给 WireGuard 或 Tailnet，包括原有 Tailnet 身份。组规则保留引用，之后修改组成员会一起更新下次连接的规则；删除组规则只取消分配，仍被引用的地址组不能删除。空组可先保存，添加成员后才能分配给连接。手动规则和地址组中的相同域名或相同网段不能分配到不同连接，重叠后缀或网段仍按最长匹配处理。最多 128 组，每组最多 1200 个域名及 3000 个 IP 网段；WireGuard 合并域名库、手动规则和地址组后仍受 1200 条域名总上限约束。连接启动时固定展开结果，组修改不会影响同会话的自动恢复。

## 断线恢复与运行诊断（1.8.2）

系统 VPN 已由 `VpnExtensionAbility` 承载，退回桌面不依赖界面继续转发。若整个应用进程被系统终止，重新打开应用会检查原会话：先验证独立心跳与状态更新，再查询系统 VPN；只有原连接确已停止、没有其他 VPN、没有 PureVPN 更新事务且原规则快照完整时才恢复。恢复沿用原连接选择、身份、路由模式和规则快照，不应用运行期间编辑的规则。

主动断开会取消恢复意图；恢复过程中断开、切换新会话、离开前台或进行 PureVPN 配置更新都会让旧恢复请求失效。连续失败最多尝试三次，按 5／15／45 秒退避；启动保留 90 秒等待窗口，持续正常连接五分钟后重置失败次数。已明确报错的会话、缺失规则快照或无法核实系统 VPN 时会显示原因，要求手动处理。

「连接 → 运行诊断」展示进程编号、RSS 内存、打开句柄、Go 活跃堆、协程及活动流数，同时显示采样时间和系统 VPN 状态。VPN 内每 60 秒采样，页面每 5 秒读取；历史样本或过时状态不会作为当前连通证明。资源指标不可读取时显示「暂无数据」，不会伪装为零。

应用私有目录保留两份最多各 128 KiB 的诊断日志，以及最多 8 KiB 的最近样本；日志记录数值资源、生命周期与系统内存压力回调，不记录配置密钥、Cookie、登录地址或流量内容。采样失败不会中断 VPN。此次同时减少重复域名索引和 DNS 查询缓冲分配，未通过定时强制 GC 或任意内存硬上限干扰转发。

这项恢复能力仍由前台应用触发，不能保证系统杀进程后在后台自行复活，也不豁免低内存回收。短时真机验证见 [1.8.2 验收记录](docs/VALIDATION.md)，不能替代 24／48 小时稳定性测试。

## WireGuard 连接

原生 HarmonyOS WireGuard 客户端，面向运行 HarmonyOS 6.1.0（API 23）及以上版本的 ARM64 手机和平板。支持同时保存多份 WireGuard 客户端配置：多配置模式可设置一份默认连接，其余按站点（v2fly 域名列表、手动域名、手动 IP 段）分流。首页明确区分「等待握手」和「已握手」，显示发送 / 接收字节与最后握手时间；多配置会话统计注明合计。

## 构建与安装

推荐采用历史已使用的 Apple Silicon Mac、DevEco SDK 26.0.0.105 和 OpenHarmony Go 1.27.1 环境。工程路径需使用 ASCII 字符。

```sh
git clone https://github.com/linanw/luoqiao.git
cd luoqiao
test -f build-profile.json5 || cp build-profile.example.json5 build-profile.json5
```

接着按 [新电脑环境搭建](docs/SETUP.md) 安装并校验 OHOS Go，运行准备脚本应用网卡资源释放补丁，再在 DevEco 打开根目录、同步依赖并启用自动签名。根 `build-profile.json5` 是本机文件，不上传 Git；通用设置保存在 `build-profile.example.json5`。

CMake 自动查找 `.toolchain/ohos-go/bin/go`。必须支持 `openharmony/arm64`，普通 Go 的 Linux 交叉编译不能替代。两个 Go module 当前要求 1.26.5 或以上；不能仅依据旧引导脚本的最低 bootstrap 版本判断兼容性。详细下载、校验、签名和故障排查均见 SETUP。

构建由用户在 DevEco Studio 完成，产物位于 `entry/build/default/outputs/default/`。新电脑的签名配置需在本机生成，覆盖安装前核对证书，不通过卸载丢弃原有配置与登录。

## 使用

1. 从 WireGuard 服务端取得客户端的 `.conf`，在「连接 → 新建 → WireGuard」导入文件或粘贴内容，填写名称后保存。最多保存 16 份 WireGuard 配置。
2. 启用需要的多个 WireGuard / Tailnet，点顶部「连接所选连接」，在系统弹窗中授权 VPN。也可在 WireGuard 卡片点「单独连接」。每份规则连接需先配置域名或 IP 规则；多个 WireGuard 应使用独立配置，重复客户端和服务端密钥会拒绝启动。
3. 点「断开组合」或顶部「断开当前连接」停止整个 VPN。每份配置的卡片提供编辑、域名库、自定义规则和删除操作。添加规则会启用站点分流并取消该配置的默认角色，页面会说明这一变化。

支持 `Address`、`DNS`、`MTU`、`ListenPort`、`Endpoint`、`AllowedIPs`、`PresharedKey`、`PersistentKeepalive` 和多个 `[Peer]`。IPv4 和 IPv6 均可用于外层 UDP。对每个通过 VPN 路由的地址族，`Address` 中须配置同族的隧道地址。例如，使用 `::/0` 时须配置服务端分配的 IPv6 隧道地址。

`Table = auto` 可导入。系统路由表编号、`PreUp` / `PostUp` 等脚本钩子以及 `SaveConfig` 会显示为不支持的字段。域名端点会在连接和底层网络变化时解析，使用系统返回的首个有效地址。切网时采用新的受保护 UDP 源端口，以便保留现有 WireGuard 会话；因此迁移后的源端口可能不同于配置的 `ListenPort`。导入文件使用 UTF-8，最大 128 KB。

### 分流规则（按站点分流）

每份配置的「分流规则」页面可将该配置设定为「默认隧道」或「规则隧道」：

- **默认隧道**：未匹配任何分流规则的流量走这份隧道；同时也可以勾选站点列表参与分流。系统内同一时刻仅允许一份默认隧道，切换开关会自动取消其他配置的默认角色。
- **规则隧道**：开启「启用站点分流」后，可勾选 [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community/tree/master/data) 域名列表（GitHub 不可达时自动改用 jsDelivr 镜像）、手动添加域名或 IP 段（`203.0.113.7` 或 `198.51.100.0/24` 形式）。连接时这些目标会经此隧道转发。

连接时应用按以下方式聚合所有参与连接的配置：

- 存在规则连接时，由系统送入 VPN 的双栈 TCP / UDP 先进入本地转发层。系统 DNS 对命中的域名提供会话内虚拟地址；每个请求在指定 WireGuard 的独立网络栈中解析和拨号。`domain:` 与普通条目匹配域名及子域名，`full:` 精确匹配，`include:` 递归获取。`keyword:` / `regexp:` 仍未支持。每份配置最多 48 个列表、1200 条域名规则。
- 浏览器的 IPv6 虚拟地址连接也可由 IPv4-only WireGuard 的实际 IPv4 出口转发，避免因配置缺少 IPv6 而将所选域名交回移动网络。原来的 12 小时静态解析缓存不再参与规则连接。
- 域名精确规则优先，其次最长后缀；IP 段按最长前缀分配。每份配置使用独立 wireguard-go 设备及网络栈；无规则命中的流量按默认角色的 AllowedIPs 处理，没有默认出口时直连。选择某个连接后，解析或拨号失败不会尝试物理网络。
- 保留配置原有 `AllowedIPs`，选中目标及 DNS 必须能通过对端访问。选中域名使用该配置的 `DNS`；未配置 DNS 时通过该 WireGuard 查询 `1.1.1.1`（IPv6-only 时使用 Cloudflare IPv6 DNS）。未选域名使用底层网络 DNS。
- 规则模式要求 MTU 至少 1280，目前转发 TCP / UDP。浏览器应使用系统 DNS；自带 DoH / DoT、旧的真实 IP 缓存及硬编码 IP 仍无法凭域名选网，应关闭安全 DNS、重开浏览器或增加明确的 IP 规则。动态模式排除本应用自身流量，防止出站再次进入 VPN。
- 本地虚拟网卡地址与 DNS 服务地址分离，避免 DNS 被系统当作本机流量。监听默认网络可用、断开和属性变化，并以约 3 秒轮询兜底；网络 ID、接口地址、路由或 DNS 变化时刷新解析、重绑每条 WireGuard 的受保护 UDP 套接字，并通知 Tailnet 重新探测链路。保留系统 TUN、身份、规则和虚拟 DNS 映射；底层短时失联时重试恢复。

## 实现与验证

- `VpnExtensionAbility` 在创建 TUN 前保护原生 UDP 套接字。原配置路由继续使用 `startMany` 的包转发路径；包含分流规则时使用 `startRouted` 的 gVisor 双栈入口与每配置 WireGuard NetTUN，按域名和 CIDR 转发流。
- 配置保存在应用沙箱内，使用 AES-256-GCM 加密，密钥保存在系统 Asset Store；单份配置及索引分别存于 `profiles/<id>.enc` 与 `profiles.json`，旧版单配置文件会自动迁移。启动 VPN 时的跨进程参数只包含会话 ID 与参与连接的配置 ID 列表。
- 原生测试使用本地 UDP 和成对的模拟 TUN 验证握手、按前缀分发、fake AAAA 经 IPv4-only WireGuard 的加密 DNS / TCP / UDP 通信、未选流量直连及失败不回落。测试可在 macOS 或 Linux 上运行。

```sh
cd entry/src/main/cpp/wireguard
../../../../../.toolchain/ohos-go/bin/go test ./...
```

在 HarmonyOS 6.1 真机上验收时，应连接自己的对端并验证首次授权、分流或全局路由、DNS 和断开后路由恢复。可在切换 Wi-Fi 和移动数据后再次访问隧道内地址，检查最近握手与收发统计。

参考 [HarmonyOS VPN 开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension/)、[DevEco Studio 自动签名](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-signing-auto/) 和 [wireguard-go](https://git.zx2c4.com/wireguard-go/)。

## 多个 Tailscale / Headscale 网络与动态站点分流

在「连接」首页点击「新建 → Tailnet」，选择 Tailscale 或 Headscale 并保存独立配置。在「域名库」选择目标连接后勾选站点集合，在「自定义规则」新增域名 / IP 段并指定归属。未匹配的 TCP / UDP 流量走当前网络；选择公网网站前，需要在对应配置中填写该网络可用的出口节点 Tailnet IP。

启用需要的 Tailnet 和 WireGuard，点击「连接所选连接」，分别完成各 Tailnet 的浏览器登录。登录后页面显示节点地址和可用出口。配置变更需重新连接。各新建 Tailnet 使用独立身份，即使控制地址相同也不会共用登录文件。完整相同规则分配给不同 Tailnet 时，会提示冲突而停止启动。

此模式使用动态 DNS 虚拟地址及独立 TCP / UDP 转发，Tailnet 支持列表的子域名、full、keyword、regexp。数据库采用 v2fly 官方编译产物并校验 SHA-256；上游 include、属性筛选和归属规则已经展开。规则界面可刷新数据库。WireGuard 仍支持子域名和 full 规则。TCP / UDP 以外的协议和应用自带加密 DNS 存在限制，详见 [验收记录](docs/VALIDATION.md)。旧页面的独立启动模式与组合模式互斥，避免抢占同一系统 VPN。

可重复验证：

```sh
cd tailnet && ../.toolchain/ohos-go/bin/go test -race ./...
# 在项目根目录执行：
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tools/test-models.cjs
```

## 1.2.2 界面

- **连接**：Tailnet 和 WireGuard 统一列表，按名称、服务器或类型搜索；支持类型筛选、新建、编辑、删除和连接控制。WireGuard 配置通过系统密钥加密，打开编辑页时默认隐藏配置内容。Tailnet 的控制服务器在创建后固定，切换服务器应新建配置以保持身份隔离。
- **域名库**：查看更新时间与站点集合数量、下载或更新；为 Tailnet 或 WireGuard 勾选站点集合与迁移归属。Tailnet 使用完整 GeoSite 数据库；WireGuard 下载原始列表及引用，最多 48 个列表、1200 条域名规则，超过限制会拒绝保存。WireGuard 可单独更新原始列表。
- **自定义规则**：按域名 / IP 段筛选，新增、编辑、删除及更换归属连接。域名规范化为小写，CIDR 规范化为网段，重复规则会提示已有归属。WireGuard 也按域名及子域名动态分流，页面说明系统 DNS 和缓存要求。

连接期间身份、密钥等连接配置只读；1.7.0 起允许修改域名库、自定义域名 / IP 规则和重叠网段偏好，保存后在下一次手动连接生效。Tailnet 的启用开关控制是否参与多网络连接，原有配置未设置此字段时默认启用。导航保留「原有 Tailnet 连接」，已有登录无需迁移或重新创建。

## 1.3.1 PureVPN 配置助手

WireGuard 卡片的「PureVPN 配置」及编辑页均可打开官方会员网页。首次需要在应用内登录并完成真人验证；外部浏览器的会话不会自动共享。地区选项来自会员网页，不维护推测的静态国家列表。网页布局暂时无法识别时，在官网选择地区并填写一致的地区备注。

「生成新配置」按真实会员页执行国家展开、该国家的下载入口、WireGuard 协议、Linux 设备格式和 Generate Configuration。官网正常下载的配置经过校验后加密导入。生成前的弹窗国家、生成结果的 Location 必须与所选国家完全一致；每个操作只点击一次生成，离开页面、取消或更换地区会使旧回调失效。已适配真实账号的中英混合页面，真机读取到 93 个国家／地区；不同地区的可用性仍以官网实际提供的协议为准。

也支持接收官网正常下载的 `.conf`，包括会员页 Blob 下载：限定来源与 128 KB 大小，在应用私有缓存中校验，交给导入流程前删除临时明文。下载取消、失败或退出页面时清理；下次进入清理本功能的中断残留。其他类型或来源的下载不会自动导入。

更新保留同一连接 ID、名称与全部分流规则。已连接时只允许更新单独运行的同一 WireGuard；先确认旧扩展停止，再使用新配置，并以本次会话的新握手确认更新。组合运行期间可以访问官网和下载，但导入与前台自动更新暂停，需先断开组合后更新。失败恢复原加密备份；进程退出留下的事务在下次打开助手时恢复。不会覆盖更新过程中用户新发起的连接操作。

「前台尝试自动更新」在 1.7.0 起使用持久恢复队列：同一配置、同一会话连续在线，已实际发包但仍未获得首次握手，且等待达到 90 秒，才记录待处理任务。WireGuard 的发送计数包括已成功发出的握手包；没有任何发送的闲置连接不排队，旧握手或配置年龄也不作为过期证据。已建立连接后来出现连续请求失败时，仅标记「需要检查」（`needs-check`），不能据此确认服务商配置失效或自动换配置。

打开助手后会重新核对队列、当前配置、会话和网络，再在官方会员网页执行生成、导入与新握手验证。离开页面暂停并保留可恢复任务；登录或真人验证完成后可继续，用户明确取消则不会被页面重新登录自动撤销。普通更新失败按 1 分钟至 30 分钟退避。后台 VPN 只观察连接，不在后台驱动网页，所以不能保证无人值守续期。官方所述 15 分钟是首次配置／激活窗口，不是健康会话的有效期；不同指南写有 5 分钟或 15 分钟，另有扩展至 24 小时的附加服务，应用不据此硬编码健康连接的轮换时间。[首次连接窗口说明](https://support.purevpn.com/en_US/other-devices-guides/wireguard-command-line-interface-cli-setup-guide-for-raspberry-pi-debian)、[配置窗口扩展说明](https://support.purevpn.com/en_US/account/how-to-add-wireguard-via-member-area)。

配置与备份均加密保存；关联文件和恢复观察只记录地区、时间、状态、收发统计与自动更新偏好，不保存密码、Cookie、认证 token 或验证码。官网允许持久化的 Cookie 由 ArkWeb 保存，助手在适当时机调用 `saveCookieAsync`，不提取或改写登录 Cookie。华为明确说明平板、PC 和二合一设备的临时 session cookies 即使调用该方法也不写盘，因此应用重启后仍可能需要登录，不能承诺永久保留会话。[ArkWeb Cookie 持久化说明](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-webview-webcookiemanager/)。

生成流程依据[官方手动配置指南](https://support.purevpn.com/en_US/mac-manual-/how-to-setup-wireguard-on-mac)。公开的令牌续期 API 属于 [PureWL 合作伙伴方案](https://www.purevpn.com/white-label/purevpn-apis-documentation-explained-for-developers/)，要求 Partner Console 订阅与 Secret Key；未找到面向个人订阅的公开 WireGuard 配置续期 API。本实现只操作官方可见网页，不调用未公开的账号 API、不操作真人验证控件，也不修改浏览器指纹或证书验证。

便携测试：

```sh
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tools/test-purevpn-provider.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tools/test-purevpn-apply.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tools/test-purevpn-web.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tools/test-purevpn-download.cjs
/Applications/DevEco-Studio.app/Contents/tools/node/bin/node tools/test-purevpn-page.cjs
```

## 1.6.0 重叠网段偏好

「连接 → 重叠网段」可按 IPv4／IPv6 CIDR 保存本地网络或 Tailnet 优先，最多 128 条。Tailnet 可自动选择唯一匹配的网络，或明确指定已有 Tailscale／Headscale 连接；更具体的网段优先。保存后重新连接应用。当前默认 Wi-Fi／有线网络的本地网段会自动识别，切回蜂窝后停用重叠偏好，恢复原有选路。

普通域名经应用 DNS 解析到已配置网段时，返回会话内虚拟地址并保留真实目标 IP；新连接按照当前网络和网段偏好走本地或 Tailnet。提前建立的映射在切网后重新判断，不把 DNS 缓存固定在旧出口。选择 Tailnet 后不可用或无法唯一确定归属时，拒绝新连接，不回退本地。生效的网段偏好优先于常规 IP 分流规则；已有站点规则、MagicDNS 和默认 WireGuard 出口保持原来的域名归属。

**平台边界：直接输入重叠网段的原始 IP，仍可能由系统优先走 Wi-Fi。** 公开 VPN API 没有调整系统路由表优先级的字段，声明更具体的 VPN 路由也不等于能覆盖系统本地表。该设置不能保证强制接管这类原始 IP。应用自带 DoH／DoT、保存偏好前的真实 IP 缓存也可能绕过应用 DNS；重新连接后应重新打开目标页面。已建立的 TCP／UDP 流不会中途迁移到另一出口。

存在网段偏好时，普通域名的 HTTPS／SVCB 查询暂返回空结果，以免地址提示绕过 A／AAAA 合成；这会暂时失去这些 DNS 记录提供的 HTTP/3／ECH 提示。明确归属的域名不受此变更影响。

系统行为参考：[华为 VPN API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-vpnextension)、[OpenHarmony 本地／VPN 路由规则](https://github.com/openharmony/communication_netmanager_base/blob/master/services/netmanagernative/src/manager/route_manager.cpp)、[物理子网路由更新](https://github.com/openharmony/communication_netmanager_base/blob/master/services/netconnmanager/src/network.cpp)。上游源码说明限制的原因，实际设备结果以验收记录为准。

## 1.7.0 路由检查与运行中编辑

「连接 → 路由检查」接受单个 IP、域名、host:port 或 HTTP/HTTPS URL，从当前 VPN 的实际分流引擎返回连接归属、匹配原因、规则及必要的 A/AAAA 解析。已经明确归属 WireGuard、Tailnet 或 MagicDNS 的域名不会为了检查向本地 DNS 泄露；未指定归属的域名使用当前物理 DNS 解析后逐 IP 判断。DNS 总预算 5 秒，不发业务 TCP/HTTP 探测，不把选路成功等同服务可用。原配置路由模式可解释 IP 的 AllowedIPs，无法凭域名预测系统解析和路由时明确提示。

检查显示的是本次运行规则；运行中修改的 v2fly 选择、原始列表、GeoSite、自定义域名/IP 与网段优先级都作为下次连接配置保存。每次新连接创建非敏感规则快照，WireGuard 域名列表提前展开、Tailnet GeoSite 保存固定副本。自动恢复及同一 session 重建继续使用原快照；只有手动停止再连接才读取新规则。损坏的会话快照拒绝回退到新规则，防止异常恢复时悄悄切换出口。密钥不写入规则快照。

路由检查与 VPN 通过应用私有目录中的有界请求/应答交换，使用 session、请求 UUID、目标和有效期过滤陈旧结果；网络切换和 transport 重建期间的迟到结果不展示。重叠局域网原始 IP 的系统旁路限制仍适用，页面明确提示；动态域名结果要求实际业务使用应用 DNS。

PureVPN 恢复队列仅在同一配置、同一会话已实际发出握手等数据包、连续在线等待至少 90 秒仍无首次握手时进入待处理；零发送闲置、旧握手和超过 15 分钟均不会触发自动换配置。曾建立的连接后来连续请求失败只提示 `needs-check`。队列可跨页面保留，前台执行前会重新核对配置、会话、网络和官方页面，成功导入仍必须由新握手确认；组合运行期间仍禁止替换其中的配置。

官网允许持久化的 Cookie 由 ArkWeb 落盘，密码和 token 不进入应用元数据；平板上的临时 session cookies 不会因此变成持久会话，重启后可能需重新登录。账号会话失效和真人验证仍需要用户完成，后台 VPN 不运行网页登录流程。因此这些改进不等于所有失效场景均可无人参与续期；详细条件和官方依据见上文「PureVPN 配置助手」。
