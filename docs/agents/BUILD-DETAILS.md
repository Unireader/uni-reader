# 构建细则 — 发布 / 第三方包 / 采集页 / 子工程约定

从 `AGENTS.md`「构建与验证」拆出的完整细节（2026-09-26 拆分）。主文件只留常用构建命令与产物纪律。

## 发布到 GitHub（`scripts/release.sh`，2026-09-16 加，2026-09-18 补 Sparkle 自动更新）

公开仓库 `Unireader/uni-reader` 的 release，附件 = 公证并装订过的 zip + dmg；正式版还会把这次更新
写进仓库根目录的 `appcast.xml`（Sparkle 用，托管在 `raw.githubusercontent.com` 的 `main` 分支，
Swift 侧集成见 `Sources/App/UpdaterService.swift`）。流程：

1. **Agent 先写发布日志** `release-notes/v<版本>.md`：中文 + 英文各一份，只写上次发布以来的改动，
   按功能归类、用日常说法（commit 里的内部实现细节不写），界面文案以 `Localizable.strings` 为准。
   两段标题（`## 中文` / `## English`）前各加一行不可见的 `<!-- lang:zh -->` / `<!-- lang:en -->`
   HTML 注释——GitHub 正文渲染不受影响，release.sh 靠它把 appcast 里的更新说明拆成中英文两份，
   Sparkle 按用户系统语言显示对应的那份；没打这两行 marker 的旧发布日志会退化成一份不分语言的说明。
2. 演练：`./scripts/release.sh <版本> --notes-file release-notes/v<版本>.md --dry-run`
   （检查 + 改版本号 + Debug 编译，跑完还原 `project.yml`；不提交、不公证、不推送、不碰 appcast）。
3. 正式发布：同一条命令去掉 `--dry-run`。会推送 main 和 tag 并公开发布，**Agent 跑之前必须先得到用户确认**。
   2026-09-16 在 Agent 会话里 `notarytool history` 曾两次报「No Keychain password item found」，
   过一会儿又能读到（原因未确认）；再遇到就重试一次，仍失败再问用户。

- 版本号由脚本改（构建号自动 +1），发布日志随版本号一起提交成 `release: v<版本>`；要求工作区干净（发布日志除外）、在 `main` 上、不落后 `origin/main`。
- 公证全部通过后才打 tag、`git push --atomic` 推 main + tag，再 `gh release create --verify-tag`；中途失败远端不变，脚本会打印撤销命令。
- appcast.xml 的提交/推送放在 `gh release create` **之后**（这样 appcast 里的下载链接一发布出去就能打开）；
  这一步失败时 release 本身已经发出去了，脚本会打印手动补推 appcast 的命令。
- 编译走 `-derivedDataPath build/dev -disableAutomaticPackageResolution`，不联网拉包；采集页走 `build-web.sh --no-install`，不装依赖；
  Sparkle 的 `sign_update`/`generate_keys` 工具也是从 `build/dev/SourcePackages` 这份缓存里找，同样不现场拉包。
- 公证配置名默认 `noticky-notary`，不同就 `NOTARY_PROFILE=<配置名> ./scripts/release.sh …`。
- **`--prerelease` 版本不进 Sparkle 更新通道**（appcast.xml 只收录正式版）——本项目暂不做「预发布 beta
  channel」这层偏好开关，2026-09-18 与用户确认过，以后要加再补；用这个方式最简单也最安全，不会有人被
  自动推到未测试的构建。
- **Sparkle EdDSA 密钥**（`Sources/Info.plist` 的 `SUPublicEDKey` + 本机登录钥匙串里的私钥）首次发布前
  只需生成一次：`xcodegen generate` → 解析 SPM（`xcodebuild … -resolvePackageDependencies`）→
  `build/dev/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys` 打印公钥，粘进
  `Sources/Info.plist` 再 `xcodegen generate` 一次。⚠️ 公钥一旦随首次发布公开，**严禁更换**——换了
  老版本会拒绝所有未来更新。密钥生成这步涉及本机 Keychain 写入，按项目规矩交给用户自己跑，Agent 不代跑。

## 第三方包（SPM）

目前三个：

- **`swift-markdown-engine`**（2026-09-26 起用自家 fork `Unireader/swift-markdown-engine` 的 `unireader` 分支——
  上游把智能引号写死为开，笔记里 `'` 会变 `’`，fork 加了 `SpellCheckingPolicy.automaticQuoteSubstitution`，两处编辑区都关掉；
  `project.yml` 里 `exactVersion` 钉死，现 **0.13.0-unireader.1**，改 fork 的做法写在 `project.yml` 注释里；
  🔴 **升级前后都跑一遍 `spike/markdown-relayout-cost.swift`**——0.9.0 每敲一个字按整篇算账，17K 字的笔记 56ms/字、
  52K 字 159ms/字（一帧才 16.7ms），0.13.0 恒定 9~12ms/字不随全文长度涨；量的是主线程 CPU 时间，用法见文件头，
  改动前后对比一眼就知道有没有退步）——笔记编辑器 sheet（`MarkdownNoteEditor`）与气泡正文只读渲染
  （`MarkdownNoteReader`，允许 SwiftUI 的两处之一）用它。取两个产品：核心 `MarkdownEngine`（零外部依赖）+
  `MarkdownEngineLatex`（2026-09-16 加，笔记里的 `$…$` / `$$…$$` 公式；传递依赖 **SwiftMath**，MIT，
  带 ~7MB 数学字体进 app 包）。公式渲染器 = `NoteLatexRenderer`（套在引擎的 `SwiftMathBridge` 外面：
  `$$` 块加 `\displaystyle` 按块排版 + 缓存封顶）；某条公式能不能渲染，用 `spike/latex-look.swift` 出样张看
  （SwiftMath 不支持的命令会原样显示源码）。
- **Sparkle**（`from: "2.9.1"`，2026-09-18 加）——`Sources/App/UpdaterService.swift` 薄封装
  `SPUStandardUpdaterController`，菜单「UniReader › 检查更新…」与设置 ›「通用」的「更新」区块共用它；
  UniReader 不在 sandbox，不需要 Installer XPC service 或额外 entitlements。
- **`swift-acp`**（自家 fork `Unireader/swift-acp`，`exactVersion: 0.1.0-unireader.1`，2026-09-18 加，MIT）——
  Agent 面板的 ACP 客户端，取 `ACP` + `ACPModel` 两个产品；fork 怎么改、怎么打 tag 见 `ACP-AGENT-PLAN.md §2`。

包解析落在 `build/dev/SourcePackages/`，新克隆或 `rm -rf build` 之后首次编译要先
`xcodebuild … -derivedDataPath build/dev -resolvePackageDependencies`（联网拉包 = 装依赖，
**按用户规矩给命令让用户跑**，别自己跑）。升版本只改 `project.yml` 再解析。

## 采集页前端（`web/`）

改动后跑 `scripts/build-web.sh`（npm install + 单文件构建 + 占位符自检 + 覆盖 `Sources/Resources/capture.html`），
再重新编译 App。`capture.html` 是构建产物、**不入 git**——新克隆先跑一次 `build-web.sh`；
`scripts/package.sh` 打包时会自动重建（`release.sh` 用 `--no-install` 只构建不装依赖）。

工程本身的结构说明见 `AGENTS.md`「结构要点」的 `web/` 一条（全文在 `docs/agents/STRUCTURE.md`）。

## 产物纪律补充（细则在 AGENTS.md 表格里，这里只留背景）

- 定这条的起因（2026-09-03）：同一份 app 在 `build/` 和 DerivedData 各躺了一个。
- `-derivedDataPath build/dev` 省掉时，xcodebuild 写进
  `~/Library/Developer/Xcode/DerivedData/UniReader-<一长串随机码>/`：路径随机、用户找不到、
  也不知道该清哪个。编译验证也走这条，别为「反正不要产物」而省。
- 给用户实测**别跑 `package.sh`**：那是 Release + Developer ID + 公证（要等几分钟）且会自动 bump 版本号。
  Debug 包够用。（同款规矩：安卓是 `android/pack.sh --debug`，产物在 gradle 标准位
  `android/app/build/outputs/apk/debug/`。）
- `package.sh` 只清自己的 archive/export/zip，**不碰 `build/dev`**，两者可以长期共存。
- 整个 `build/` 已在 `.gitignore` 里；要清干净就 `rm -rf build`。
- 例外只有一个：**用 Xcode GUI 打开项目时它仍写自己的 DerivedData**，那份不归本约定管、也别拿它
  当交付物；命令行一律按表来。

## 子目录自带 AGENTS.md（`android/` 就是这么做的）

`android/` 是**独立 git 仓库**（根仓库 `.gitignore` 忽略了它，安卓改动在那边单独提交），所以安卓端的规则
**写在 `android/AGENTS.md` 里**（`android/CLAUDE.md` 是它的软链，与根目录同款约定），跟着安卓仓库一起走；
根目录那份只留一句引用，不复制内容——**同一条规则只在一处维护**，避免两边各改一半互相矛盾。

新增其他子工程（如将来的 Windows 端）照此办理：子目录自己写 `AGENTS.md` + `CLAUDE.md` 软链，
根目录在「文档地图」加一行指过去。跨端契约（`PROTOCOL.md`、schema、跨平台方案文档）仍留在根目录，
子目录用 `../` 相对路径引用，别在子目录里复制一份。
