# 在另一台电脑搭建

当前基线是络桥 1.9.0，目标 HarmonyOS 6.1.0（API 23），仅支持 ARM64。历史成功构建环境为 Apple Silicon Mac、DevEco SDK 26.0.0.105、Hvigor 6.26.9、OpenHarmony Go `go1.27.1-ohos`。其他宿主平台尚未完成本工程的整体验证。

## 1. 克隆与生成本机配置

工程路径使用纯英文，避免 Hvigor 的非 ASCII 路径错误。

```sh
mkdir -p ~/Projects
cd ~/Projects
git clone https://github.com/linanw/luoqiao.git
cd luoqiao
test -f build-profile.json5 || cp build-profile.example.json5 build-profile.json5
```

`build-profile.example.json5` 是公共模板，保留 API、产品及模块设置，不含签名信息。`build-profile.json5` 由本机 DevEco 管理并被 Git 忽略。以后拉取模板更新时，手工合并公共设置到本机文件，保留自动签名部分；不要重复覆盖本机文件。

## 2. 安装 DevEco 与 SDK

安装支持 HarmonyOS 6.1 / API 23 项目的 DevEco Studio 和 HarmonyOS SDK，包含 Native/CMake 工具链。推荐使用 DevEco 自带的 Node、ohpm 和 JBR。项目没有自带完整 SDK 或 Hvigor 可执行程序。

macOS 默认安装路径：

```sh
export DEVECO_HOME=/Applications/DevEco-Studio.app/Contents
export JAVA_HOME="$DEVECO_HOME/jbr/Contents/Home"
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export PATH="$JAVA_HOME/bin:$DEVECO_HOME/tools/node/bin:$DEVECO_HOME/tools/ohpm/bin:$PATH"
```

## 3. 准备 OpenHarmony Go

### 已使用的 Apple Silicon 预编译包

从 [sysit/ohos-go v1.27.1-ohos 发布页](https://github.com/sysit/ohos-go/releases/tag/v1.27.1-ohos) 获取 `go1.27.1-ohos-darwin-arm64.tar.gz`。这是第三方 OpenHarmony Go 移植，不是普通 Go 官方发行包。下面 SHA-256 对应本工程此前使用的原始归档。

仅在 `.toolchain/ohos-go` 不存在时执行解压；已有工具链时先检查版本和补丁，不要覆盖。

```sh
mkdir -p .toolchain/downloads
curl -fL --retry 3 \
  https://github.com/sysit/ohos-go/releases/download/v1.27.1-ohos/go1.27.1-ohos-darwin-arm64.tar.gz \
  -o .toolchain/downloads/go1.27.1-ohos-darwin-arm64.tar.gz
shasum -a 256 -c <<'SHA256'
eb60dd115ea775073a06bb2152c3d9c7935e56a2dba0cc8f871538b9a67cef2b  .toolchain/downloads/go1.27.1-ohos-darwin-arm64.tar.gz
SHA256
test ! -e .toolchain/ohos-go && \
  tar -xzf .toolchain/downloads/go1.27.1-ohos-darwin-arm64.tar.gz -C .toolchain && \
  mv .toolchain/go1.27.1-ohos .toolchain/ohos-go
./tools/prepare-ohos-go.sh
.toolchain/ohos-go/bin/go version
.toolchain/ohos-go/bin/go tool dist list
```

最后一项必须包含 `openharmony/arm64`。准备脚本还会幂等应用 `tools/patches/openharmony-go-interface-resources.patch`，修复网卡枚举的 socket 与 getifaddrs 资源释放。**解压完成后仍需运行准备脚本**，DevEco 直接调用 CMake 不会替你应用补丁。

CMake 自动查找工程内 `.toolchain/ohos-go/bin/go`，适合从图形界面启动 DevEco。也支持 `WIREGUARD_OHOS_GO` 指定完整可执行文件路径，但从终端导出的环境变量不一定传给已打开的 IDE。外部工具链应先执行 `./tools/prepare-ohos-go.sh /absolute/toolchain/directory`，并确保补丁兼容。

普通 Go 的 `GOOS=linux` 产物可能生成 HarmonyOS 动态加载器不支持的静态 TLS 重定位，不能作为替代。构建使用 `GOOS=openharmony`、`GOARCH=arm64`、CGO、`netcgo,osusergo` 和 c-archive。

### 源码引导路径的限制

没有预编译目录时，`prepare-ohos-go.sh` 会获取 GitCode 的 `openharmony-sig/ohos_golang_go` 固定提交 `302a5306b6fad2f47196360b82561d1db1f954cf` 并执行 `make.bash`。这是保留的旧引导路径；当前两个 module 均要求 Go **1.26.5 或以上**，这条源码路径尚未按当前依赖重新验收，不能据此承诺在任意电脑首次运行即可构建。优先采用上述已使用的 1.27.1 包。其他宿主请选匹配宿主架构的工具链并先确认 Go 版本、OHOS 目标和补丁兼容性，不要直接运行 macOS ARM64 包。

## 4. 自动签名与 DevEco 构建

1. 在 DevEco 打开工程根目录并同步，必要时先执行 `"$DEVECO_HOME/tools/ohpm/bin/ohpm" install --all`。
2. 真机开启开发者模式和 USB 调试，在 DevEco 中确认设备连接。
3. 打开 **File → Project Structure → Project → Signing Configs**，启用 **Automatically generate signature**，登录相应华为开发者账号完成自动签名。[官方自动签名说明](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/ide-signing-auto/)
4. 确认本机 `build-profile.json5` 中产品 `default` 关联到生成的 signingConfig，例如 `default`；证书文件均须在本机存在。模板本身不预先引用不存在的签名。
5. 由用户在 DevEco 构建并运行 `entry`。不要将旧电脑的签名密码或证书上传 GitHub。

新电脑的自动签名不自动保证能覆盖旧设备上的安装。若 IDE 提示签名不一致，应核对同一开发者账号、应用及证书配置；不要通过卸载丢弃用户数据。需要迁移的证书仅通过用户选择的私密方式处理。

## 可选命令行构建

仅在用户要求时运行：

```sh
./tools/build-hap.sh
```

脚本会准备默认工程内 Go 工具链、安装 ohpm 依赖，再执行 debug `assembleHap`。输出位于 `entry/build/default/outputs/default/`；是否签名取决于本机配置。项目没有提交可下载的签名 HAP。

若 Go 依赖下载失败，先检查正常网络及代理。`./tools/prepare-tailnet.sh` 是可选下载辅助，它在 `127.0.0.1:18763` 启动临时代理并运行 `go mod tidy`，会修改依赖文件；它不是每次构建必需步骤。不要关闭校验和验证或无理由提交依赖升级。

## 常见问题

| 现象 | 检查位置 |
| --- | --- |
| 找不到根构建配置 | 从 `build-profile.example.json5` 创建本机配置 |
| CMake 提示运行 prepare-ohos-go | 检查 `.toolchain/ohos-go/bin/go`、宿主架构及 `openharmony/arm64` 目标 |
| Go 版本不满足 go.mod | 当前 module 要求 1.26.5；推荐已使用的 1.27.1-ohos |
| 工具链补丁无法应用 | 检查 VERSION、来源与源码，不要跳过资源释放补丁 |
| 更换工具链后 CMake 仍引用旧路径 | 在 DevEco 清理 Native/CMake 缓存并重新同步 |
| 自动签名后仍无签名 | 核对产品的 signingConfig 关联及证书路径 |
| 错误 13900002 / 保存目录准备失败 | 按 [HANDOFF](HANDOFF.md) 的存储排查步骤取证，不重置配置或密钥 |
