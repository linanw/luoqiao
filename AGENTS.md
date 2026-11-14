# Codex 接手入口

本仓库是「络桥」HarmonyOS VPN 客户端，当前版本 1.9.0 / 1000017。已从最初的单 WireGuard 客户端扩展为 WireGuard + Tailscale / Headscale 多连接与规则分流。先读 [docs/HANDOFF.md](docs/HANDOFF.md)，再读 [README.md](README.md)、[环境搭建](docs/SETUP.md) 和 [架构](docs/ARCHITECTURE.md)。

## 用户偏好与工作边界

- 使用中文沟通。用户在本任务中明确要求由自己在 DevEco Studio 构建；接手默认做代码、文档和相应静态检查，不主动构建 HAP、安装设备或打断现有 VPN。后续用户明确要求构建或安装时，以新指令为准。
- 用户要求使用 DevEco **自动签名**。根目录 `build-profile.json5` 是被 Git 忽略的本机文件；公共配置改动写入 `build-profile.example.json5`，不要覆盖已有本机签名。
- 不改包名来绕开安装问题，不卸载来绕开签名问题；这会影响现有登录、配置或 Asset Store 密钥。保留 bundleName `dev.wireguard.harmony`。
- 不提交真实 WireGuard 配置、私钥、Tailnet 身份文件、签名材料、Cookie、登录 URL 或原始设备日志。测试中的固定样例密钥只是测试数据。
- 公共仓库只包含工程。原电脑中的 `artifacts/`、`outputs/`、`icloud-drive/` 和 `.toolchain/` 均不随 Git 迁移。

## 开发要点

- ArkTS 的 TypeScript 转译测试不能替代 DevEco 的 ArkTS 类型检查；宿主 Go 测试不能替代真机 VPN 通信。
- 原生构建必须使用支持 `openharmony/arm64` 的 Go 工具链。先按 SETUP 放置工具链并运行准备脚本应用网卡资源释放补丁。不要改为普通 Go 的 `GOOS=linux` 来规避检查。
- 两个 Go module 是相对路径关联的整体；不能只复制 `entry/` 而遗漏 `tailnet/`。
- UI 的实际入口是 `pages/NetworksPage`，不是旧版 `Index`。三个 VPN 扩展共享系统 VPN，启动协调要保持互斥。
- 保持路由安全语义：选中连接失败不得自动回退直连；自动恢复沿用原会话规则快照；主动断开不得自动重连。
- 存储使用模块 Context 的 `filesDir`；不要恢复成仅使用 `getApplicationContext().filesDir`。旧配置迁移与加密格式需兼容。
- 改动后运行与改动对应的 [测试](docs/TESTING.md)，明确报告实际执行范围。历史验收不是本次重新验证。
- 更新已知问题时区分代码证据、历史真机记录和当前设备复现；不要从计数、Running 或路由预测推断业务可达。
