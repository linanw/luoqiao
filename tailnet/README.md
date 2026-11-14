# HarmonyOS Tailnet

面向 HarmonyOS 6.1（API 23）ARM64 的原生 Tailnet 客户端。使用 Tailscale v1.102.0 的 tsnet 自定义 TUN 接口，控制面和数据面都运行在 VPN 扩展内。

## 使用

在首页「新建 → Tailnet」选择 Tailscale 或 Headscale。Headscale 输入 HTTPS 控制服务器地址；节点名默认 harmony。启用需要的 Tailnet 和 WireGuard，点击「连接所选连接」，完成系统 VPN 授权后按卡片提示登录。Headscale 的注册／OIDC 流程由你的服务器提供。每份新配置使用独立身份，原有 Tailnet 卡片可直接复用旧登录。

组合模式共用一个双栈系统 VPN；`multinet.Manager` 为每个 Tailnet 运行独立客户端，由 WireGuard 模块的共同入口将 TCP / UDP 转发到选定连接。节点、已公布子网、完整 MagicDNS 名称及其真实短名随状态更新自动识别；短名来自正式 DNSName，不能用显示名称猜测。明确域名 / IP 规则优先，无明确规则的重叠地址／同名节点拒绝转发。应用自身通过 blockedApplications 绕过 VPN，避免控制面和 DERP 自循环。

可为每个 Tailnet 配置域名库、手动域名 / IP 规则及出口节点。选择公网网站时，需要该 Tailnet 中可用且允许访问的出口节点。连接失效时独立退避重连，选定连接的流量不会自动泄漏到其他出口。旧管理页的独立 VPN 模式仍保留，但不能与组合模式同时启动。组合转发当前限于 TCP / UDP，域名分流要求应用使用系统 DNS。

## 构建

先完成根目录 [新电脑搭建](../docs/SETUP.md)，包括生成被 Git 忽略的本机构建配置、工具链补丁及自动签名。以下是用户要求命令行构建时的可选入口：

```sh
./tools/prepare-tailnet.sh  # 可选：标准 Go 模块下载不畅时使用，保留 sum.golang.org 校验
./tools/build-hap.sh
```

下载辅助程序仅监听 127.0.0.1:18763，使用 curl 分段获取模块，停止脚本时关闭。正常网络构建会按 go.sum 下载依赖，无需先执行 tidy。tidy 会修改依赖文件，仅在需要维护依赖时使用。SDK、Go 工具链与签名配置沿用根目录 README。

```sh
cd tailnet
../.toolchain/ohos-go/bin/go test ./...
```

测试验证输入配置、TUN 双向传输、关闭时解除阻塞、DNS、自动子网 / MagicDNS 分流及身份目录隔离。真机已验证两个 WireGuard 与一个 Tailscale 同时运行、各 WG 独立出口、Tailnet 子网 HTTPS，以及 MagicDNS 短名下的 HTTPS 服务。1.5.0 又验证同一 VPN 会话内 4G→Wi-Fi→4G 自动恢复；浏览器切换瞬间仍可能报网络变化，需要刷新。Wi-Fi 与远端子网同为 192.168.72.0/24，隧道结论使用 MagicDNS 及对应 Tailnet 路由事件，不以重叠裸 IP 页面可达作证。详细范围见 [公开验收摘要](../docs/VALIDATION.md)。多个真实 Tailnet、Headscale 和 24/48 小时稳定性仍未完成验收。

实现入口：`client.go` 为节点管理，`tun.go` 为延迟绑定 TUN，`cmd/native` 提供 C ABI。ArkTS 界面通过 N-API Promise 调用，避免在 UI 线程执行网络等待。

上游参考：
- https://tailscale.com/docs/features/tsnet
- https://github.com/tailscale/tailscale/tree/v1.102.0
- https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension/

1.6.0 的「连接 → 重叠网段」可逐 CIDR 选择本地或指定 Tailnet 优先；普通 DNS 地址合成后在每条新流重选，Wi-Fi／4G 切换同步更新本地前缀。重叠偏好优先于常规 IP 规则，明确域名／MagicDNS／默认 WG 域名归属不变。真机已用同一 NAS 的普通 DNS 名称验证 Wi-Fi 本地和 Tailnet 两种路径，以及切网后的切换。直接输入重叠原始 IP 仍受系统本地表优先级限制，无法保证强制通过 Tailnet；详见根目录 README 与验收记录。

1.7.0 支持运行中保存下次连接的分流规则与数据库。新连接创建不可变规则快照，自动恢复和同一会话重建继续使用旧规则；Tailnet 身份目录不变，GeoSite 使用会话副本的 DatabasePath。「连接 → 路由检查」从当前组合引擎返回域名/IP归属及匹配原因，包含 MagicDNS、节点/子网和不可用/冲突说明。真实恢复与关闭行为、PureVPN 限制见根目录验收记录。
