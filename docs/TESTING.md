# 验证入口

选择与改动有关的测试。文档与发布整理不需要完整 HAP 构建；用户当前要求在 DevEco 自行构建。以下命令供后续开发使用，是否实际运行应写入交付说明。

## 宿主 ArkTS 模型和页面逻辑

大部分脚本使用 DevEco 自带 TypeScript，将 `.ets` 转译并用 mock 提供 HarmonyOS API。部分页面测试包含结构检查，不能证明真实 UI 渲染或 ArkTS 类型合法。

```sh
DEVECO_HOME=/Applications/DevEco-Studio.app/Contents
"$DEVECO_HOME/tools/node/bin/node" tools/test-models.cjs
"$DEVECO_HOME/tools/node/bin/node" tools/test-mixed-connections.cjs
"$DEVECO_HOME/tools/node/bin/node" tools/test-session-rules.cjs
"$DEVECO_HOME/tools/node/bin/node" tools/test-tunnel-recovery.cjs
"$DEVECO_HOME/tools/node/bin/node" tools/test-vpn-diagnostics.cjs
```

| 改动领域 | 脚本（`tools/`） |
| --- | --- |
| WireGuard 解析、域名基础模型 | `test-models.cjs`，读取 `tests/*.test.ts` |
| 混合连接与 Tailnet | `test-mixed-connections.cjs`、`test-multi-network-session.cjs`、`test-tailnet-connection-view.cjs` |
| 会话、恢复与资源 | `test-session-rules.cjs`、`test-tunnel-recovery.cjs`、`test-vpn-diagnostics.cjs` |
| 规则与地址组 | `test-live-rule-editing.cjs`、`test-address-groups.cjs`、`test-address-group-rules.cjs`、`test-address-groups-page.cjs` |
| DNS、重叠路由与检查 | `test-domain-cache.cjs`、`test-subnet-preferences.cjs`、`test-route-checker.cjs` |
| PureVPN | `test-purevpn-provider.cjs`、`test-purevpn-apply.cjs`、`test-purevpn-web.cjs`、`test-purevpn-download.cjs`、`test-purevpn-page.cjs` |

`test-models.cjs` 支持 `DEVECO_HOME`；多个其他脚本当前硬编码 macOS 默认 DevEco TypeScript 路径。新电脑路径不同或使用其他系统时，需要先调整测试加载路径，不能把环境缺失当成应用失败。

## Go 宿主测试

两个 module 的 `go` 指令均为 1.26.5，使用满足要求的宿主 Go。下面使用已经准备好的 OHOS Go 的宿主模式；不要设置 `GOOS=openharmony` 去运行电脑上的测试。

```sh
export GOTOOLCHAIN=local
(cd entry/src/main/cpp/wireguard && ../../../../../.toolchain/ohos-go/bin/go test -race ./...)
(cd tailnet && ../.toolchain/ohos-go/bin/go test -race ./...)
python3 tools/test-ohos-interface-resources.py --iterations 1000 --race
```

涵盖本地 UDP WireGuard 握手、模拟 TUN、TCP/UDP 分流、DNS、出口失败不回落、socket 重绑、关闭取消以及资源采样。工具链资源测试读取已安装工具链的实际函数正文，在宿主中替换平台 ioctl/getifaddrs 适配并构造未修复对照。它不等于真机长期内存测量。

## 真机验收

由用户在 DevEco 构建并覆盖安装后，至少区分以下证据：

1. 版本与签名安装成功；配置、规则及 Tailnet 登录保留。
2. 新建、保存、修改、删除配置与重启后读取；记录明确失败阶段，不记录配置正文。
3. WireGuard 新握手与实际目标服务响应；Tailnet Running 与实际 MagicDNS/子网通信分别验证。
4. 规则命中出口、未命中策略与选中出口失败时的行为。路由检查预测不替代业务请求。
5. Wi-Fi/移动网络双向切换；区分会话恢复与页面请求零中断。
6. 主动断开不恢复；重新打开后的恢复使用原快照；后台回收的系统原因与采样时效。
7. UI 全屏、竖横屏、窄窗口及编辑草稿保留。

设备标识、网络地址、节点名称和原始日志只保留在用户指定的私有位置。公共记录仅包含脱敏结论与局限。历史已执行范围见 [VALIDATION.md](VALIDATION.md)，当前交接事项见 [HANDOFF.md](HANDOFF.md)。
