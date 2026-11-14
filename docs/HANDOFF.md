# 给下一台电脑的 Codex

交接基线：**络桥 1.9.0 / 1000017**，包名 `dev.wireguard.harmony`，HarmonyOS 6.1 / API 23，ARM64。仓库为 <https://github.com/linanw/luoqiao>，主分支 `main`。

## 先做什么

1. 阅读根目录 [AGENTS.md](../AGENTS.md) 与本文。以当前代码为准：项目已包含多 WireGuard、多个 Tailnet、域名/IP 分流、地址组、PureVPN、恢复和自适应侧栏，不能按最早的单配置应用重写。
2. 按 [SETUP.md](SETUP.md) 克隆到英文路径，从公共模板生成本机 `build-profile.json5`，准备 OHOS Go 并应用补丁。
3. 让用户在 DevEco 配置自动签名。用户在本任务中明确说过自己构建；除非新指令要求，不主动构建、安装、卸载或打断运行中的 VPN。
4. 查阅 [ARCHITECTURE.md](ARCHITECTURE.md)、[TESTING.md](TESTING.md) 和 [VALIDATION.md](VALIDATION.md)，再处理用户下一项需求。此次交接本身不授权新增功能或变更设备连接。

## 当前状态和优先问题

最新文件与历史记录说明 1.9.0 已构建并覆盖安装，使用过真实 WireGuard/Tailscale 通信。**这不代表全部问题已完成验收**。本次发布没有重跑这些测试。

优先保留的已知问题是后台稳定性：工具链 FD/地址列表泄漏已有补丁，但 1.8.2 真机仍记录到 LowMemoryKill。应用回到前台能按原会话恢复，不能承诺杀进程后后台自行拉起。需要真实长时资源采样和退出原因来区分泄漏、系统压力与普通切网，不用计时重启或强制 GC 掩盖问题。

其他边界包括 Headscale/多个真实 Tailnet 未完成验收、原始重叠 IP 的系统旁路、DoH/DoT 绕过域名分流，以及 PureVPN 登录失效/真人验证仍需用户参与。详见 README 和公开验收摘要。

## 早期保存配置错误的上下文

本任务先后收到这些真机反馈：

1. 无法保存配置，请确认设备已解锁且配置不超过 128 KB。
2. 错误码 `13900002`。
3. 系统未能返回有效的应用配置目录。
4. 准备应用配置目录失败。

此前已改用模块 Context 的 `filesDir`，处理 Asset Store 首次建库/重复创建，加入分阶段错误、临时文件写入与原子替换；当前又已演进到多配置存储。后续本机记录包含配置编辑和 PureVPN 更新成功，因此不能直接把最早报错当成当前所有设备都不能保存，也没有足够证据单独关闭这些报错。

若用户再次反馈保存失败，先确定设备安装的 versionName/versionCode、操作页面、是新建还是编辑、完整阶段和数值错误码。当前路径：

```text
WireGuardEditorPage.context()
  → createProfile() / saveProfileText()
  → context.filesDir、migrateLegacyProfile()
  → encryptProfileFile()
  → ensureProfilesDirectory() 的 accessSync / mkdirSync
  → Asset Store 密钥 → AES-GCM → open/write/fsync/close/rename
  → 新建时 writeIndex()
```

`ProfileStore.ets` 里当前“准备应用配置目录”阶段只覆盖 `ensureProfilesDirectory()`；它检查或递归创建模块目录下的 `profiles/`。`context.filesDir` 和迁移在调用加密函数之前。不要将旧版本阶段与当前代码混为一谈。

日志 tag 是 `WireGuardProfile`。现有 catch 主要记录阶段和可选数值 code，没有完整原异常原因。必要时补充安全的错误类型、调用位置、目录是否有效和具体 API 名称；**不要输出配置、密钥、Cookie 或完整登录地址**。对无 code 的失败不要猜测成权限错误或文件过大。不要通过删除索引、Asset Store 密钥或卸载来排查。

## 新电脑不会带过去的内容

| 内容 | 处理方式 |
| --- | --- |
| 根 `build-profile.json5`、证书、签名密码 | 本机自动签名；公共模板为 `build-profile.example.json5` |
| `.toolchain/`、SDK、oh_modules、编译缓存 | 按 SETUP 重新准备 |
| 真机 WireGuard 配置与 Tailnet 登录 | 留在设备私有存储；Git 克隆不迁移账号身份 |
| 原始日志、截图、旧签名 HAP | 留在原电脑 `artifacts/`；公开库只保留脱敏摘要 |
| 其他项目和办公产物 | `icloud-drive/`、`outputs/` 不属于本工程，已忽略 |

根构建文件被忽略是刻意的设计，避免 DevEco 将签名材料再次写入 Git。修改通用 SDK/产品配置时更新模板，并提醒用户合并本机配置。不要 `git add -f build-profile.json5`。

## 值得后续处理的工程问题

- 多个宿主测试脚本硬编码 macOS DevEco 路径；跨电脑时可集中读取 `DEVECO_HOME`，然后运行相关测试。
- 无预编译包时的旧源码引导固定版本尚未对 Go 1.26.5 module 重新验收；不要在文档中承诺该路径已验证。
- 后续更新依赖时同步两个 module、go.sum 和第三方声明；本次交接没有升级依赖。
- 公开仓库目前只交付源码，不含签名发行包或自动构建 CI。

## 可直接粘贴的新任务提示

> 接手 https://github.com/linanw/luoqiao 的络桥 HarmonyOS 6.1 客户端。先读 AGENTS.md、docs/HANDOFF.md、docs/SETUP.md 和 docs/VALIDATION.md，以当前 1.9.0 多连接实现为基线。使用 DevEco 自动签名，保留包名、配置与登录。我会自己在 DevEco 构建，不要主动构建或安装。先检查工程与当前已知问题，再按我接下来提供的需求继续；不要把历史保存错误或旧验收当成本次复现结果。
