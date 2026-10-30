# AGENTS.md — UniReader 服务器（`server/`）

独立的 Swift 服务器程序（方案 `../docs/SERVER-MODE-PLAN.md`）：工作区「从服务器打开 / 上传到服务器」，各设备本机缓存、只传改动。
macOS 上开发与测试；**Linux 版在 Mac 上交叉编译**成静态二进制（下面「Linux 版」）。与 App 同一个 git 仓库（不像 `android/` 是独立仓库）。

## 构建与测试

```bash
cd server
swift build --disable-automatic-resolution
swift test  --disable-automatic-resolution   # 核心 24 项 + HTTP 6 项
BIN=$(swift build --disable-automatic-resolution --show-bin-path)/unireader-server
$BIN serve --data <数据目录> --port 8790      # 默认只听 127.0.0.1；--help 看全部子命令
$BIN serve --host 0.0.0.0 --name 书房         # 让局域网里的设备连 + 发现它（Bonjour，方案 §3.7）
```

- ⚠️ 产物路径**问 `--show-bin-path` 要**，别写死 `.build/debug/`：Xcode 27 的 SwiftPM 放在 `.build/out/Products/Debug/`，
  而 `.build/debug` 这个符号链接会被最近一次交叉编译改指到 Linux 的目录。

- 改了接口或同步规则，再跑一次 App 侧客户端的端到端：仓库根目录 `bash spike/server-client-test.sh`
  （自己起临时服务器、端口 18790，跑完关掉；编的是 App 的 `ServerClient` / `ServerSyncIO`）。
- 产物在 `server/.build/`（根 `.gitignore` 的 `.build/` 已覆盖）。
- 🔴 第三方包**由用户执行拉取**（`swift package resolve`），我不代跑。2026-10-29 用户已拉取：hummingbird 2.28.0、
  swift-http-types 1.8.0、swift-crypto 3.15.1、swift-toolchain-sqlite 1.0.13（及其依赖，版本钉在 `Package.resolved`；
  后两个只在 Linux 上接到目标）。
  构建 / 测试一律带 `--disable-automatic-resolution`：依赖要变时它直接报错，不会悄悄去下载。
  加新依赖 = 改 `Package.swift` 后先让用户拉取，拉之前别构建。
- 默认端口 8790（App 自己占了 8770~8773）。默认数据目录：macOS `~/Library/Application Support/UniReaderServer/`，
  Linux `/var/lib/unireader`。

## Linux 版（方案 §13.6）

```bash
bash scripts/setup-linux-build.sh        # 一次性，用户跑：swift.org 工具链 + Static Linux SDK（不改默认的 swift）
scripts/build-linux.sh aarch64           # 或 x86_64；最后一行打印产物路径（musl 静态链接，单个文件）
scp <产物> nas:/storage/app_bin/unireader-server/unireader-server
# Linux 上的验证（单元测试跑不了，见下）：在 NAS 上起临时服务器、从 Mac 跑客户端端到端，跑完删掉
REMOTE=nas REMOTE_ADDR=192.168.1.160 REMOTE_DIR=/storage/data/98_Misc/unireader-server-test bash ../spike/server-client-test.sh
```

- 🔴 **钉在 Swift 6.2.3**（SDK 0.0.1）：6.2.4 起的静态 SDK 把 musl 的分配器换成 mimalloc（合进 `libc.a`），它用了 ARMv8.1 的原子指令，
  在 ARMv8.0 的板子（用户 NAS 的 RK3399、树莓派 4）上一启动就 `Illegal instruction`。升级前先查：
  `xcrun nm -A <SDK>/…/aarch64/usr/lib/libc.a | grep mimalloc.o`，有就别升。
- Swift 6.2 读不了 Xcode 27 的 macOS SDK（各包的 `Package.swift` 按 Mac 编）：`build-linux.sh` 自动用 CommandLineTools 里的
  `MacOSX26*.sdk`（`SDKROOT`）；哪天命令行工具里没有 26 的 SDK 了，这一步会报错。
- 静态 SDK **不带 XCTest / Swift Testing**：`--tests` 编不了测试。Linux 上的验证 = 上面那条远端端到端（28 项）。
- 局域网发现：Linux 上起 `avahi-publish-service` 子进程（要 `avahi-utils`）。服务器正常退出时一起停；被 `kill -9` 它会留下来，
  长期跑用 systemd（模板 `deploy/unireader-server.service`，装到 `/etc` 要用户点头）。组播不跨网段。
- 用户的 NAS：`ssh nas`（root），程序 `/storage/app_bin/unireader-server/`，**正式数据 `/storage/data/22_Exam/Unireader`**，
  测试用的临时目录 `/storage/data/98_Misc/unireader-server-test/`；`/storage` 是 mergerfs（`storage.mount`），SQLite（WAL）在上面实测正常。
  开机自启：`/etc/systemd/system/unireader-server.service`（`RequiresMountsFor` 等 `/storage` 挂好；`--host 0.0.0.0 --name NAS`，端口 8790）。
  换程序：`scp` 到 `.new` → 当前版本 `cp -p` 成 `.prev`（回退用）→ `mv` 覆盖 → `systemctl restart unireader-server`；
  ⚠️ `/storage` 是 mergerfs，**`chmod` 报「Operation not supported」**——文件本来就带执行权限，别写进脚本（`set -e` 会在那一步停下）；
  日志 `journalctl -u unireader-server`；
  配对码 `unireader-server pairing-code --data /storage/data/22_Exam/Unireader`。对外 HTTPS 由用户用 caddy 反向代理（NAS 上已装）。

## 结构

```
server/
  Package.swift
  Sources/UniServerCore/
    Store -> ../../../Sources/Store                 符号链接：App 的工作区库层（建表 / 迁移 / 指纹 / 三方判定 / 行写入）
    Sync  -> ../../../Sources/Sync                  符号链接：同步线格式 SyncWire + 行工具 SyncRows + 客户端算法 SyncClient
    BackupRetention.swift -> ../../../Sources/App/BackupRetention.swift   符号链接：备份保留策略
    ServerBasics.swift        数据目录布局 ServerPaths、错误 ServerError、哈希 / 随机串 ServerCrypto
    ServerStore.swift         server.sqlite：配对码、设备令牌（只存哈希）
    WorkspaceHost.swift       全部工作区：列表、按 id 打开、登记上传、删除（整个挪进回收站）/ 找回 / 到期清理
    HostedWorkspace.swift     一个工作区：登记、推送、拉取、快照、改名、修订号
    HostedWorkspace+Files.swift   PDF / 图片本体 / 备份
    ServerTrash.swift         删除先归档（按天一个小库）
  Sources/UniServerHTTP/ServerApp.swift   HTTP 接口（Hummingbird）：路由表在文件头；令牌中间件、错误→状态码、续传、配对限流
  Sources/UniServerHTTP/Discovery.swift   局域网发现（Bonjour `_unireader-srv._tcp`：macOS 系统 dnssd；Linux 起 avahi-publish-service 子进程）
  Sources/unireader-server/               命令行入口：serve / pairing-code / reset-pairing-code / devices / revoke / deleted / restore；
                                          每小时备份有改动的工作区、清 90 天前删掉的工作区
  Tests/UniServerCoreTests/               核心（直接调 `HostedWorkspace` / `SyncClient`）
  Tests/UniServerHTTPTests/               HTTP（HummingbirdTesting 的 `.router`，进程内调路由、不开端口）
  scripts/setup-linux-build.sh            一次性装 Linux 交叉编译的工具链与 SDK（用户跑）
  scripts/build-linux.sh                  交叉编译 Linux 静态二进制
  deploy/unireader-server.service         systemd 模板
```

HTTP 层只用 `UniServerCore` 的 public 接口（字节进、字节出：`push(body:)` / `pull(since:)` / `snapshotFile()` / `storePDF` …），
同步的编解码与判定都留在核心里。阻塞活（SQLite、哈希、拷文件）经 `Blocking.run` 挪到单独的队列上。

符号链接让 App 的源文件与服务器代码编成**同一个模块**：internal 就够用，App 那边一行 `public` 都不用加，文件也不用挪
（另一个 agent 与 `android/AGENTS.md` 都按 `Sources/Store/...` 引用 Mac 代码，挪走会打乱它们）。

## 规则

1. 🔴 **`Store/`、`Sync/`、`BackupRetention.swift` 是 App 的源文件**。改它们 = 改 App：改完两边都要验——这里 `swift test`，
   App 那边 `xcodegen generate` + Debug 编译 + 对应 spike（`AGENTS.md`「构建与验证」）。
2. 🔴 **冲突规则只有一份**：服务器推送、客户端拉取都交给 `MirrorDiff.compute`（`source` 一律指服务器），写入走 `MirrorApply.write`。
   别在服务器里另写一套判定。
3. 服务器私有的东西（`srv_rev` 表、`meta.srv_head_rev`）**只在服务器库里**，不进跨端 schema；`exportSnapshot` 交出去前去掉。
   客户端私有的是 `sync_base` 与 `meta.srv_pulled_rev`。
4. 修订号**每行一个、互不相同**（拉取按修订号分页，同号的行会在页边上漏掉）。
5. 删除**先归档再删**（红线⑪）：`ServerTrash.archive` 在删除事务之前调，连同外键会带走的子行；父行被删后
   `reconcileCascades` 把服务器上连带删掉的子行补记成「已删除」。
6. 一个工作区全进程只开一个 `HostedWorkspace`（`WorkspaceHost` 管），所有读写在它那把锁里。
7. 安全：工作区 id 必须是 UUID（会拼进路径）；文件路径一律经 `HostedWorkspace.resolveInside`（`..`、符号链接越界不认）；
   PDF / 图片收下前校验 SHA-256。所有 HTTP 接口都要令牌，没有例外（`../docs/REMOTE-ACCESS-PLAN.md §2` 的教训）。
8. 只用 Linux 上也有的 API：Foundation、SQLite、Crypto、NIO。**不 import** AppKit / Network / PDFKit。
   链进来的 Store 层里苹果独有的都包在 `#if canImport(...)` / `#if os(macOS)` 里：`SQLite3`（Linux 用 `SwiftToolchainCSQLite`）、
   `CryptoKit`（Linux 用 `Crypto`）、`CoreGraphics`（Linux 上 `CGRect` 由 Foundation 给）、`ImageAssets` 的解图 / 转码（Linux 上不编）、
   `MirrorBuilder.availableCapacity`。🔴 **改了 `Sources/Store/` / `Sources/Sync/` 要再跑一次 `scripts/build-linux.sh`**——
   macOS 上编译通过不代表 Linux 能过（Linux 的 Foundation 缺的键 / 方法只有交叉编译才报）。

## 同步要点（细节在方案 §4 与 §13）

- 推送：每行带客户端基线指纹；服务器比对「基线 / 客户端 / 服务器」三方，结果是 applied / keptServer / skippedOrphan /
  skippedClash / unchanged / missingFile。keptServer 的行随响应带回服务器那份（`PushResponse.serverRows`）。
- 拉取：`since` 之后的行按修订号升序分页；客户端**攒齐全部页再应用**（父行可能在子行之后的页）。
- 通道表（`ocr_page` / `image` / `page_align`）：只补不删 / 按 `updated_at` 取新；图片行要求文件先传上来。
- 客户端基线按行更新：没写成的行（孤儿）基线不动，否则下一轮会把「本机没有」误判成「本机删了」。
