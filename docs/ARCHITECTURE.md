# 代码与数据流

## 工程地图

| 路径 | 职责 |
| --- | --- |
| `AppScope/app.json5` | 包名与应用版本；当前 1.9.0 / 1000017 |
| `entry/src/main/module.json5` | UIAbility、三个 VPN 扩展及网络权限 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 实际启动 `pages/NetworksPage`，通知前后台恢复器 |
| `entry/src/main/ets/pages/NetworksPage.ets` | 连接概览、选择、组合连接与恢复协调 |
| `entry/src/main/ets/components/WorkspaceShell.ets` | 完整侧栏、紧凑侧栏和窄屏抽屉 |
| `entry/src/main/ets/pages/` | WireGuard/Tailnet 编辑、规则、地址组、路由检查、诊断、PureVPN |
| `entry/src/main/ets/model/ProfileStore.ets` | 加密 WireGuard 配置、索引、旧版迁移与分阶段错误 |
| `entry/src/main/ets/model/NetworkProfiles.ets` | 多个 Tailnet 的元数据与独立身份目录 |
| `entry/src/main/ets/model/MixedConnections.ets` | 组合选择、配置验证与启动计划 |
| `entry/src/main/ets/model/SessionRules.ets` | 会话规则快照，恢复时保持原出口策略 |
| `entry/src/main/ets/model/TunnelRecovery.ets` | 前台恢复、退避、取消与健康预算 |
| `entry/src/main/ets/model/VpnDiagnostics.ets` | 有界、白名单化的资源诊断存储 |
| `entry/src/main/ets/vpn/` | WireGuard、独立 Tailnet、组合 VPN 生命周期 |
| `entry/src/main/cpp/napi_bridge.cpp` | `libwireguard.so` 的 N-API 边界 |
| `entry/src/main/cpp/tailnet_bridge.cpp` | `libtailnet.so` 的 N-API 边界 |
| `entry/src/main/cpp/wireguard/` | WireGuard 设备、TUN、UDP、gVisor 分流与组合网关 |
| `tailnet/` | tsnet 客户端、TUN、DNS、multi-network 管理及 C ABI |
| `tools/`、`tests/` | 工具链准备、构建辅助、宿主回归测试 |

## 连接生命周期

UI 保存配置，创建带会话 ID 的连接请求和规则快照，再启动指定 `VpnExtensionAbility`。原生 socket 需排除 VPN 自循环；扩展创建系统 TUN，将 fd 交给原生引擎。状态、心跳和请求在应用私有目录中交换，包含会话标识以拒绝旧回调。

三个扩展是兼容不同模式的入口，同一时刻不能各自占用系统 VPN。组合模式让多个 WireGuard 和 Tailnet 共用一个系统 TUN；每个连接保留独立设备、身份与状态。WireGuard 原配置路径按 AllowedIPs 转发；规则路径通过 gVisor TCP/UDP 入口、动态 DNS 虚拟地址和独立网络栈分配出口。

显式域名或 IP 规则选择连接后，失败不得回退物理网络。无规则命中的流量按唯一默认 WireGuard 的 AllowedIPs 处理，没有默认出口则直连。同优先级归属冲突拒绝流量。MagicDNS 与节点短名取控制面真实名称，不凭显示名称猜测。

底层网络变化刷新解析和受保护 socket，并通知 Tailnet 重新探测；保留会话、TUN 和规则。短时切网恢复不保证现有浏览器请求不中断。自动恢复只在应用回到前台后协调；系统杀死整个应用后，没有已验证的后台自动拉起能力。

## 配置与身份

- 当前目录来源为模块 Context 的 `filesDir`。WireGuard 元数据在 `profiles.json`，内容在 `profiles/<id>.enc`；最多 16 份、每份不超过 128 KiB。
- 密文格式为版本字节、12 字节 IV、AES-256-GCM 密文与认证标签；主密钥保存在 Asset Store，别名 `wireguard-profile-aes256-v1`。不得因读取异常覆盖已有密钥。
- 旧单配置 `wireguard-profile.enc` 可迁移；保留对旧应用级目录的兼容查找。迁移问题需同时检查索引与密文，不能只删除索引重试。
- Tailnet 身份与控制服务器绑定；新建网络使用独立目录，已有 legacy 身份保留。不将登录身份放进规则快照或公共仓库。
- 会话快照固定域名、IP、地址组和数据库结果。运行中编辑保存的是下次手动连接的规则；当前会话自动恢复继续使用旧快照。
- PureVPN 配置更新有加密备份与恢复事务。官方会员网页的 Cookie 由 ArkWeb 管理；配置更新应防止迟到回调覆盖用户新连接。

## 原生构建约束

`wireguard/go.mod` 通过相对 `replace` 引用根目录 `tailnet`。两套 C archive 分别带 Go runtime，链接使用 `--exclude-libs,ALL` 隔离内部符号。OHOS 的 Go fork 与网卡资源释放补丁都是构建输入；不要只搬运 `.so` 或只复制一个 module。

当前代码仅声明 ARM64，最低和目标 API 为 23。Native API 声明在 `entry/src/main/cpp/types/`，修改导出时需同时核对 ArkTS 声明、C++ N-API 和 Go ABI。TLS 验证在 `verify_elf.cmake`，目前由 WireGuard 库构建后触发。
