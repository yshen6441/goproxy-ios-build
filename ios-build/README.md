# goproxy for iOS（越狱版 · roothide）

为 **iPhone 12 mini (A14) / iOS 17 roothide 越狱环境** 交叉编译的 goproxy 代理程序。

## roothide 适配要点（依据官方文档 roothide/Developer）

1. **entitlements**：roothide 上所有越狱二进制默认被沙盒（容器）隔离，必须带官方 base entitlements，否则程序会被沙盒限制（无法绑定端口、无法读写配置文件）。本产物已用 `roothide.entitlements` 重签：

   ```
   platform-application
   com.apple.private.security.no-sandbox
   com.apple.private.security.storage.AppBundles
   com.apple.private.security.storage.AppDataContainers
   ```

2. **安装位置**：roothide 使用随机目录名的 jbroot，deb 包由 dpkg 安装时自动落到当前 jbroot（等价 `/var/jb/usr/local/bin/goproxy`）。重签后不要再改动文件位置，否则签名失效。

3. **动态库链接**：roothide 用 `@loader_path/.jbroot/...` 链接越狱库。goproxy 为纯 Go 二进制，仅依赖系统库（libSystem/CoreFoundation/Security），无越狱 dylib 依赖，不存在该问题。

4. **文件访问**：goproxy 默认读取/写 `blocked`、`direct` 文件在进程工作目录（jbroot 视图），无需使用 `jbroot()` API。

## 产物清单

| 文件 | 说明 |
|------|------|
| `goproxy-ios` | iOS arm64 可执行文件（已用 ldid 签名） |
| `goproxy_3.0_iphoneos-arm64e.deb` | 可直接用 Sileo / dpkg 安装的安装包 |
| `goproxy-entitlements.plist` | 签名用的 entitlements |
| `install.sh` | SSH 手动安装脚本 |

## 工具链（本环境已就绪）

- Go 1.25.6 官方 `ios/arm64` 交叉目标（强制 cgo 外部链接）
- iPhoneOS 17.5 SDK：`/opt/ios-sdk/iPhoneOS17.5.sdk`
- iOS clang：`/opt/zig/zig cc`（LLVM 19）+ 包装脚本 `/opt/ios-tools/ios-clang`
- 签名工具：`/opt/ios-tools/ldid/ldid`

重新构建命令：

```bash
cd /workspace/goproxy
SDKROOT=/opt/ios-sdk/iPhoneOS17.5.sdk \
GOOS=ios GOARCH=arm64 CGO_ENABLED=1 \
CC=/opt/ios-tools/ios-clang \
go build -trimpath -ldflags "-s -w" -o /opt/ios-build/goproxy-ios .
# roothide 官方 entitlements 重签
/opt/ios-tools/ldid/ldid -S/opt/ios-build/roothide-entitlements.plist /opt/ios-build/goproxy-ios
```

## 为什么不会被系统 kill（关键点）

1. **平台必须是 iOS**：使用 `GOOS=ios` 编译，Mach-O 的 `LC_BUILD_VERSION` platform=2 (IOS)。若误用 `darwin` 目标，产物是 macOS 二进制，iOS 内核会直接拒绝加载。
2. **架构 arm64**：匹配 A14 芯片，`cputype=0x0100000c (ARM64)`。
3. **minos 17.0**：最低系统版本 17.0，与设备系统匹配，加载命令校验通过。
4. **有效代码签名 + roothide entitlements**：已用 `ldid -S` 做 ad-hoc 签名，`LC_CODE_SIGNATURE` 段完整；含 roothide 官方 base entitlements（`no-sandbox` 等），程序不会被沙盒限制/杀死。
5. **只依赖系统库**：仅链接 `libSystem`、`CoreFoundation`、`Security`、`libobjc`、`libresolv`，均为 iOS 自带，无外部依赖导致启动崩溃。

## 部署与运行（iPhone 12 mini / iOS 17 roothide）

### 方式一：安装 deb 包（推荐）

1. 将 `goproxy_3.0_iphoneos-arm64e.deb` 用 `scp` 传到设备，例如：
   ```bash
   scp goproxy_3.0_iphoneos-arm64e.deb root@<设备IP>:/var/mobile/
   ```
2. 设备上通过 SSH 执行（roothide 的 dpkg 会把文件安装到当前 jbroot）：
   ```bash
   dpkg -i /var/mobile/goproxy_3.0_iphoneos-arm64e.deb
   ```
   或在 Sileo 中通过文件方式安装。

### 方式二：scp 直传二进制

```bash
# 在电脑上（注意：直传前需保证二进制已用 roothide entitlements 签名）
scp /opt/ios-build/goproxy-ios root@<设备IP>:/var/jb/usr/local/bin/goproxy
# 在设备 SSH 中
ssh root@<设备IP>
chmod 755 /var/jb/usr/local/bin/goproxy
```

### 运行示例

```bash
# HTTP 代理，监听 33080
/var/jb/usr/local/bin/goproxy http -p :33080

# TCP 端口映射（把设备 38080 转发到内网 192.168.1.10:8080）
/var/jb/usr/local/bin/goproxy tcp -p :38080 -T tcp -P 192.168.1.10:8080

# 内网穿透：服务端（公网机器）
/var/jb/usr/local/bin/goproxy tserver -p :38080 -k password
# 内网穿透：客户端（设备上运行，把本地服务暴露到公网）
/var/jb/usr/local/bin/goproxy tclient -P <公网IP>:38080 -k password --local :80
```

提示：roothide 的 jbroot 每次越狱是随机目录名，SSH 终端里直接以 `/` 为根访问 jbroot（等价路径 `/var/jb/...`）；若需转换路径可用 roothide 提供的 `jbroot`/`rootfs` 命令行工具。`goproxy` 还内置 `keygen` 命令生成 tls 证书：
```bash
/var/jb/usr/local/bin/goproxy keygen -C proxy.crt -K proxy.key
```

## 版本信息

- goproxy v3.0（`github.com/snail007/goproxy` 最新 master）
- 编译目标：`ios/arm64`，iPhoneOS SDK 17.5
