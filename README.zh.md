# UniReader

一款 macOS 上的 PDF 阅读器：所有笔记都存在 PDF **之外**，还能用平板触控笔
通过局域网直接写在页面上。

[![Release](https://img.shields.io/github/v/release/Unireader/uni-reader)](https://github.com/Unireader/uni-reader/releases/latest)
![Platform](https://img.shields.io/badge/macOS-26%2B-blue)
[![License](https://img.shields.io/badge/license-AGPL--3.0-green)](LICENSE)

[English](README.md) · 中文

---

## 这是什么

UniReader 只有一条原则：**绝不改动 PDF 文件本身**。高亮、文字笔记、手写、书签、
图片都存在你自己的工作区里，按文件内容哈希（SHA-256）+ 页码 + 页面坐标锚定。
文件改名或换个位置，笔记照样跟着走。

在这之上它补了看书真正需要的两件事：平板触控笔的手写，以及和书放在一起的
Markdown 笔记——不用再开另一个软件。

![正在读论文，右侧开着 Agent 面板](docs/images/Agentic%20Noting.png)

*页面上的高亮、笔记气泡和手写，右侧检查器里是 Agent 面板。*

## 功能

### 阅读

- 自己实现的页面渲染（不用 `PDFView`）：滚动和缩放都稳，捏合、拖窗口、开合侧栏
  都不闪、不跳位
- 多窗口、多标签页；PDF 和 Markdown 笔记可以混在同一排标签里，重开 App 后按原顺序回来
- 侧栏文档库支持分组和手动排序；文档按内容哈希识别，同一个文件放在好几处也还是同一篇
- 目录、全文搜索（⌘F）、跳转历史（⌘[）、跳转到指定页（⌃G）
- 扫描件 OCR，选字和搜索会自动跳过成片重复的水印块
- **扫描页对齐**：给歪掉的扫描页逐页做旋转和平移（「视图」菜单 ›「对齐扫描页」）——
  打开之后对齐后的页面就是页面，笔迹也按它算
- 参考窗：另开一扇只读浮窗看第二篇文档
- 夜间显示

![浮在阅读区上的参考窗](docs/images/Reference%20Window.png)

*参考窗把另一页一直摆在眼前（图里是同一篇的第 6 页），底下该看看、该写写。*

### 不碰 PDF 的笔记

| 类型 | 是什么 |
|---|---|
| 文字笔记 | 锚在某个位置或选区上的图钉，正文是 Markdown，在页面上以气泡显示（点击 / 悬停 / 一直摊开三种） |
| 高亮 | 给选中的文字上色 |
| 书签 | 文档里的命名位置 |
| 图片笔记 | ⌥⇧ 拖出页面上的一块做成笔记；图片按内容寻址、引用计数 |
| 手写 | 带压感的矢量笔迹，四种笔型、图层、自由框选、橡皮、撤销和剪贴板 |

另外还有**草稿纸**（盖在文档上的无限白板）和**画板模式**（把页边撑开，留出写字的地方）。

### 工作区里的 Markdown 笔记

- 就是 Obsidian 那套格式。三种入口：新建笔记、**导入**一个目录（整个复制进工作区）、
  **引用**一个目录（不复制，就地编辑你原来的目录）
- 侧栏按真实的目录层级展开；笔记在标签页里打开，停手、切走、退出 App 都会自动保存
- 支持 `[[笔记名]]` 链接、`![[图片]]` 嵌入，以及 `$公式$` / `$$公式$$`
- **正文永远以你的文件为准**：导入、改名、挪目录都不会替你改动正文里的内容

### 用平板触控笔写字

- Mac 上跑一个局域网服务，平板扫二维码配对后，浏览器里显示当前页的图，
  用笔直接在上面写，笔迹实时落到 Mac 上
- 笔迹按归一化页面坐标走二进制协议传输（WebSocket，当前这一笔走 UDP），
  所以 Mac 这边不管缩放成什么样，位置都对得上
- 笔身侧键切工具，长按出选笔盘
- **安卓客户端**在单独的仓库：
  [Unireader/uni-reader-android](https://github.com/Unireader/uni-reader-android)，
  两种模式——独立阅读器（用工作区的离线副本，断网也能看能写）和给 Mac 当输入板

### Agent 与自动化

- 检查器里的 **Agent 面板**（走 ACP 协议，目前接 [Kimi](https://github.com/MoonshotAI)）：
  它知道你在看哪一篇、第几页，能帮你找页面、加文字笔记 / 高亮 / 书签、跳到某一页，
  也能读写你正在编辑的 Markdown 笔记。用之前先在终端里装好并登录，再到
  「设置 › Agent」里打开
- App 内置 **MCP 服务**，给外部 Agent 用——默认只监听回环地址，也可以加口令后绑定所有网卡
- `unireader://open?ws=…&doc=…&page=…&note=…` 链接：在 Obsidian 里或 Agent 写的清单里
  点一下，就回到 App 的那一页、那条笔记

### 工作区

工作区是一个 `.unrd` 包，里面装着文档库、笔迹、图片和笔记。它可以放在移动硬盘上；
**离线镜像**会把整份复制到本机，硬盘拔走之后照样能看能写，下次插上再三方合并回去。

## 系统要求

macOS 26（Tahoe）或更高版本。App 不在沙盒里运行，已用 Developer ID 签名并通过
Apple 公证。不支持更低的系统版本。

## 安装

到 [Releases](https://github.com/Unireader/uni-reader/releases/latest) 下载
`.dmg` 或 `.zip`，把 `UniReader.app` 放进「应用程序」。App 通过 Sparkle 自动更新
（菜单「UniReader › 检查更新…」，或「设置 › 通用 › 更新」）。

## 从源码构建

需要 Xcode 26 和 [xcodegen](https://github.com/yonaskolb/XcodeGen)
（`brew install xcodegen`），以及构建平板采集页用的 Node.js。

```bash
# 1. 构建平板采集页（生成 Sources/Resources/capture.html）
scripts/build-web.sh

# 2. 生成 Xcode 工程（UniReader.xcodeproj 是生成物，勿手改）
xcodegen generate

# 3. 解析 Swift 包，只需第一次（要联网）
xcodebuild -project UniReader.xcodeproj -scheme UniReader \
  -derivedDataPath build/dev -resolvePackageDependencies

# 4. 编译
xcodebuild -project UniReader.xcodeproj -scheme UniReader \
  -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath build/dev build CODE_SIGNING_ALLOWED=NO
# → build/dev/Build/Products/Debug/UniReader.app
```

`scripts/package.sh` 出签名并公证过的包，`scripts/release.sh` 发布 GitHub release
并更新 `appcast.xml`；这两个都需要 Developer ID 和公证配置。

用到的 Swift 包：[swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine)
（Markdown 编辑与渲染，公式部分靠 SwiftMath）、
[Sparkle](https://github.com/sparkle-project/Sparkle)（自动更新）、
[swift-acp](https://github.com/Unireader/swift-acp)（Agent 客户端）。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `Sources/App/` | App 级状态：工作区、会话、渲染管线、笔迹逻辑 |
| `Sources/Reader/` | 阅读区（AppKit）：页面图层、缩放、笔迹、选择、浮层 |
| `Sources/Window/` | 窗口壳、侧栏、检查器、面板与弹窗 |
| `Sources/Store/` | 工作区 SQLite schema 与数据访问 |
| `Sources/Server/` | 局域网 WebSocket 服务、二维码配对、UDP 传输 |
| `Sources/MCP/` | 内置的 MCP 服务 |
| `Sources/Agent/` | ACP Agent 面板 |
| `web/` | 平板采集页前端（Svelte + Vite，构建成单个 HTML 文件） |
| `spike/` | 独立验证脚本（`swift spike/<name>.swift`） |

开发笔记与方案文档都在仓库根目录，入口是 `AGENTS.md`，其余文档（`REQUIREMENTS.md`、
`PROTOCOL.md` 以及各功能的方案文档）的地图在它里面。

## 许可证

[GNU Affero General Public License v3.0](LICENSE)。
