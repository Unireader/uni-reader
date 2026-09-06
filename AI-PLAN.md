# AI 面板方案（macOS 端，2026-08-25 定）

> **不接 API key**。做一个内嵌 webview 直接用各家 AI 平台的网页版，把「阅读位置 ↔ 网页对话」绑起来，
> 并让「把这一块发过去问」和「把答案收回笔记」都只要一两个动作。
>
> 本版**只做 macOS**。跨端（安卓/Windows）不实现，但存储 payload 按跨端可读设计（与 schema 一贯做法一致）。

---

## 0. 技术底座（已核 SDK swiftinterface，非凭印象）

macOS 26 有原生 SwiftUI `WebView` + `WebPage`，**不需要 NSViewRepresentable**：

| 能力 | API | 用途 |
|---|---|---|
| JS 注入 + JS→原生通道 | `WebPage.Configuration.userContentController`（公开）→ `WKUserScript` / `webkit.messageHandlers` | 适配器脚本、选区回传、SPA 路由回传 |
| 原生→JS | `WebPage.callJavaScript(_:arguments:in:contentWorld:)` | 塞附件、填提示词；**必须指定 `WKContentWorld.page`**，否则页面 React 拿不到我们造的对象 |
| UA 伪装 | `WebPage.customUserAgent` | Google 系登录 |
| 状态观察 | `webPage.url` / `.title` / `.isLoading` / `.navigations`（Observable / AsyncSequence） | 会话 URL 捕获、标题、失效检测 |
| 自定义 scheme | `Configuration.urlSchemeHandlers` | 备用资源通道（首版不用） |
| 右键菜单 | `.webViewContextMenu { info in … }` | ⚠️ `WebView.ActivatedElementInfo` **只有 `linkURL`**，拿不到选中文字 → 选区必须靠注入脚本回传 |

**与红线的关系**：「阅读区纯 SwiftUI，严禁 AppKit 视图」管的是阅读区。AI 面板在独立浮窗，且用的就是原生
SwiftUI 组件，不违红线，也不要为了它去包 `WKWebView`。

---

## 1. 存储：复用 `note` 表 kind=1，零 schema 迁移

`REQUIREMENTS.md §1.2` 早就预留了「会话笔记（kind=1，预留 AI 对话扩展）」，`TODO.md` 记着未做。直接用它。
好处与「草稿纸笔迹复用 note（kind=4）」完全同一个先例：级联删除、`mergeDocument` 文档合并迁移、
跨端 `SELECT` 全部原样继承，**不用建表、不用改 schema 版本**。

```
note(kind=1, document_id=库文档 id, page/anchor_* = contexts[0] 的页与页内归一化矩形)
payload JSON:
{
  "provider": "chatgpt",
  "url": "https://chatgpt.com/c/<uuid>",
  "title": "…",                       // 取 webPage.title
  "state": 0,                          // 0 正常 / 1 疑似失效
  "contexts": [                        // 发过去的东西，按时间顺序
    {"kind":"region","page":12,"rect":[x,y,w,h],"sent_at":"…"},
    {"kind":"page","page":13,"sent_at":"…"},
    {"kind":"quote","page":13,"rect":[…],"text":"…","sent_at":"…"}
  ],
  "last_opened_at": "…"
}
```

- **`contexts[0]` 就是「第一张图」**，它的 page/rect 直接写进 note 的列 → 页面图钉的位置、
  以及从这个会话回填笔记时的锚点，全都取它，不用另建表。
- ⚠️ **要改 `REQUIREMENTS.md §1.2` 那一行**：kind=1 的定义从「消息数组 + 锚点」改成「外链会话 + 上下文列表」。
  别让同一个 kind 在文档里留两种解释。
- **id 空间**：绑定用**库文档 id**（`note.document_id`），不是窗口会话 id、也不是内容哈希
  （`PROTOCOL.md §4.1` 的三 id 空间警告在这里同样适用）。

### 文字笔记加来源字段（回填用）

`TextNote` payload 加 `source`，旧 payload 无此键 → nil，**零迁移**（与 `type_id` 完全同一个先例）：

```json
"source": {"kind":"ai","provider":"chatgpt","url":"…","thread_id":"<会话 note.id>","at":"…"}
```

于是笔记能点回原会话，也能筛「哪些笔记是 AI 来的」。可选再内置一个 AI `NoteType`
（`quote.bubble` 已在 `NoteType.iconCandidates` 里），但真源仍是 `payload.source`。

---

## 2. 会话绑定

### 两段式提交（新会话在发第一条消息前没有 URL）

ChatGPT 新对话停在 `/`，发出去才 `history.replaceState` 到 `/c/<uuid>`；其余家同理。所以：

1. 用户从某个阅读位置发起 → 建 **pending 绑定**（记住文档 id + contexts[0]），不落库
2. 监听 URL 变化，匹配该 provider 的**会话 URL 正则**才 commit 落库
3. 双保险：`webPage.url` 观察 **+** 注入脚本 hook `pushState/replaceState/popstate` 回传
   （SPA 路由不保证产生 navigation 事件）

### 失效检测

打开一个已绑定会话后，落地 URL 不匹配正则（被重定向回首页/登录页）= 会话已删或掉登录 →
标 `state=1`，UI 上显示为「疑似失效」。**不要静默**。

### 三个反向入口

- **页面图钉**：同草稿纸图钉的做法（`render.ts drawPadPins` 的 Mac 侧对应物），
  形状必须和「文字笔记圆形蓝底」「草稿纸圆角方片」一眼区分
- **Inspector 笔记页**新增一段「AI 会话」列表（平台图标 + 标题 + 页码 + 时间 + 失效标记）
- **浮窗顶部上下文条**：显示当前会话绑到哪本书哪一页 + 已发送内容的缩略图列表

---

## 3. 发送：JS 适配器三级回退

### 🔴 不走系统级模拟 ⌘V

CGEvent 全局注入要辅助功能授权，而且焦点不在输入框就粘到别处。一律走 JS，且**都在 `WKContentWorld.page`**：

1. **`input[type=file]` + `DataTransfer` 塞 `File` + 派发 `change`** —— 最稳，主流平台都有隐藏 file input
2. **合成 `dragenter/dragover/drop`**（带 DataTransfer）
3. **合成 `ClipboardEvent('paste')`**

### 🔴 图片进 JS 不用 `fetch(dataURL)`

站点 CSP 的 `connect-src` 会挡。用 `callJavaScript(arguments:)` 把 base64 当**参数**传进去，
JS 里手工 `atob` → `Uint8Array` → `Blob` → `File`，全程不发任何请求。
（注入的 user script 本身不受站点 CSP 约束，但页面内的 fetch 受。）

### 文字注入

- `textarea` 是 React 受控组件，直接改 `.value` 无效 → 用原生 setter + 派发 `input`
- contenteditable / ProseMirror → `document.execCommand('insertText')`

### 自动发送默认关

填好内容让用户自己按发送键：对 ToS 友好，也避免被 Cloudflare 判成 bot。
「框选后自动发送」做成设置项，默认关。

### 适配器配置：内置为主，外部可覆盖

- **内置一份**（app 资源里的 JSON/JS），**同时支持外部文件覆盖**（工作区外，放用户配置目录），
  站点改版时不用重编译发版就能救
- 当前只用内置配置；外部通道先留着不宣传

### 🔴 适配器会腐坏 → 必须配套本地自检页

第三方站点没法写 spike 测试。做 `spike/ai-adapter-test.html`：本地 HTML 里摆三种目标
（隐藏 file input / 拖放区 / 粘贴监听区），跑同一份适配器脚本，三条链路各出一个 PASS/FAIL。
站点坏了能一分钟判断是**脚本坏了**还是**站点变了**。这是这个功能唯一能自动化的验证。

---

## 4. 发什么：四种截取形态 + 文本优先

| 形态 | 来源 | 备注 |
|---|---|---|
| **框选区域** | 新增 snip 手势（见 §5） | **最高频**，框一个公式/图表问 |
| 整页 | `PageRenderer` / `PageBitmap.render` | 已有 |
| 当前视口 | 视口矩形 → 同 snip 的渲染路径 | |
| 选中文字 | 已有 PDFKit 选择引擎 | quote |

**文本优先**：页面有文本层就直接发文字（PDFKit 已有），扫描页才发图（PaddleOCR 结果可一并带上）。
省 token，模型识别率高一个档次。

**图片规格**：长边 ≤ 2000px、JPEG q0.85。平台会二次压缩，发整页 PNG 只是白白慢。

**上下文前缀模板**（成本几乎为零，收益明显）：`{title} / p.{page} / {chapter}`（TOC 已有）/ `{quote}`，
用户可编辑。没有书名页码的裸截图，模型答得明显差。

---

## 5. 框选截图（snip）——「一定要方便」

### 入口三条

| 入口 | 手势 | 场景 |
|---|---|---|
| **⌥ 拖**（主入口） | 任何 `pointerTool` 下按住 ⌥ 拖 = 临时矩形截取，松手自动回原工具 | 零切换成本（Preview 的 ⌥拖矩形选择先例）|
| 常驻工具 `.snip` | `PointerTool` 加第 4 态，PenRack 加一枚按钮，快捷键 `s` | 连续截多块 |
| 右键菜单 | 「发送本页到 AI」/「问 AI（选中文字）」 | 不用框 |

- **⌥ 在阅读区没被占用**（只在 `ReaderSurface+Zoom.swift:228` 的滚轮守卫里出现），⇧ 已被尺子占了
- 快捷键 `s` 在三端约定（`e`/`1`~`9`/`n`/`b`/`v`/`l`/`i`/`t`）里是空的

### 🔴 截图质量：不截屏幕，按页重渲染

缩小状态下屏上的页位图本身就是低分辨率的，直接截屏发过去小字全糊。正确路径：

```
视口矩形 → 逐页求交 → 每页得「页显示坐标 subRect(pt)」
        → PageBitmap.renderTile(page:subRect:scale:)   // Sources/App/PageBitmap.swift:46，签名正好对上
        → scale = max(2, 目标像素宽 / subRect.width)，长边上限 2000px
跨页 → 各页切片纵向拼接（页间留 8px 分隔）
```

**不用新写渲染 API**。另外：**夜间反色不能进截图**（发给模型要原始白底黑字）。

### 手势与视觉

- 拖出矩形：区域外半透明压暗 + 1px accent 描边 + 实时尺寸/页码角标；Esc 取消
- 跨页允许（截图是像素，不受「仅页内」的笔迹语义约束）；**锚点取起始页**
- 松手 → 立即执行默认动作 + 右下角短暂 toast（缩略图 +「已加到 ChatGPT」+「改发…」+ ⌘Z 撤销）

### 默认动作

**附加图片 + 填入上下文前缀 + JS 聚焦输入框，不自动按发送。**
JS 的 `.focus()` 不抢窗口焦点（用户还在读书）。「框选后自动发送」设置项默认关。

- 目标会话 = 浮窗当前**激活会话**；没有 → 按当前 provider 新建 + pending 绑定到本次矩形
- 浮窗没开 → 自动开（可设为后台开、不抢焦点）；未登录 → 截图进「暂存区」并提示登录，别丢

### 实现位置（照 lasso 的模子）

新开 `Sources/Views/ReaderSurface+Snip.swift`：一个 `DragGesture` 按 `pointerTool` 门控，
与 `dragSelectGesture` / `localInkDragGesture` / `lassoGesture` 同挂容器、互斥门控。
**只画 overlay，不碰 `contentBody`**（`PDF-VIEWER-REBUILD-PLAN.md` 的零闪烁纪律）。

---

## 6. 回填笔记（webview 右键 → 文字笔记）

1. **选区靠注入拿**：`ActivatedElementInfo` 只有 `linkURL` → 注入脚本监听 `selectionchange`/`mouseup`
   → `webkit.messageHandlers.unireader.postMessage({sel})` → Swift 侧 `@State lastSelection`
   → `.webViewContextMenu` 的菜单项读它
2. **锚点** = `contexts[0]` 的 page + rect（正是 note 的 page/anchor 列）。
   contexts 为空（纯文字提问的会话）→ 回落到「创建会话时的阅读位置」，**别丢**
3. **内容原样存 Markdown**（含公式/代码），payload 带 §1 的 `source` 字段

---

## 7. 平台与登录

### provider 配置项（内置 JSON）

```
{ id, 显示名, 图标, homeURL, 会话URL正则, 适配器id, customUserAgent? }
```

**2026-08-25 用户拍板：内置表只留 DeepSeek**（「先只做 deepseek，我目前也只用 deepseek」）。
S2 的会话绑定与 S3 的发送适配器都只对它做，不摊薄。

DeepSeek 的两条 URL **已实测核对**：

```
首页  https://chat.deepseek.com/
会话  https://chat.deepseek.com/a/chat/s/66ecab55-6b60-4b56-8e92-39cb9e95c0e5
正则  ^https://chat\.deepseek\.com/a/chat/s/[0-9a-fA-F-]+
```

### 其他平台（参考，未实测，**不在代码里**）

想加就写外部配置（面板「更多 → 在访达中显示配置文件…」先导出模板再改）。下表的会话 URL 形态
**一条都没实测过**，照抄前务必自己发一条消息核对地址栏——所以它们留在文档里而不是内置表里，
免得被当成「已支持」：

| id | home | 会话 URL 形态（待核） | 备注 |
|---|---|---|---|
| chatgpt | `https://chatgpt.com/` | `/c/<uuid>` | 清数据要带 openai.com / auth0.com |
| kimi | `https://www.kimi.com/` | `/chat/<id>` | |
| qwen | `https://chat.qwen.ai/` | `/c/<uuid>` | |
| doubao | `https://www.doubao.com/chat/` | `/thread/<数字>` | |
| claude | `https://claude.ai/` | `/chat/<uuid>` | |
| grok | `https://grok.com/` | `/chat/<id>` | |
| gemini | `https://gemini.google.com/app` | `/app/<hex>` | Google 常拒 WKWebView 登录，需整条 Safari UA，仍可能不行 |

### 登录态

- `WKWebsiteDataStore.default()` 持久化 cookie；非沙盒落 `~/Library/WebKit/tech.xvanturing.UniReader`
- **面板是全局唯一浮窗**（`Window` scene，不是 `WindowGroup`），**每家平台一个 `WebPage`**，
  共享 `WKWebsiteDataStore.default()`。
  ⚠️ 这一条 2026-08-25 实现 S1 时改过：原先写的是「每个阅读窗口一个 WebPage」，那是给
  Inspector 内嵌准备的；改成单浮窗后每家一个页面就够，还顺带绕开「一个 WKWebView 不能
  同时挂两个视图」这条硬约束
- 每平台一个「清除登录数据」入口
- ⚠️ **Google 系（Gemini）大概率拒绝 WKWebView 登录**（"此浏览器可能不安全"）。
  `customUserAgent` 伪装 Safari 试一次，**不行就放弃该平台**（2026-08-25 用户拍板）

### 代理

走系统代理，**不内置代理设置**。

---

## 8. 浮窗形态与生命周期

- **浮窗是主形态**（`Window` scene，可置顶、记住尺寸位置）。UI 要认真做——不是塞个 webview 就完事：
  顶部上下文条（绑定的书/页 + 已发缩略图）、平台切换、会话列表入口、加载进度、失效提示
- Inspector 里只放「AI 会话列表 + 快捷发送」，不放 webview
  （`.inspectorColumnWidth(max: 400)` 对聊天太窄）
- **内存**：每个同时可见的面板 ≈ 100~110MB（实测，§11.6）；不可见的那份进程似被 WebKit 回收
- **teardown 纪律延用 `REQUIREMENTS.md §8.1`**：`onDisappear` 里显式把 `WebPage` 置 nil，别等 ARC。
  它不持 PDF 文件句柄（不影响弹移动硬盘），但内存和网络连接会一直挂着

---

## 9. 红线

- **不接 API key**，不做本地模型调用
- **不爬会话正文回存**：只存 URL + 用户手动回填的片段。扒 DOM 站点一改就废，ToS 也更灰
- **注入脚本只注入自有代码**，不碰凭证，不向任何自有服务器上传
- **AI webview 绝不接进已有的 LANServer**（那是给平板的局域网通道）
- **截图按页重渲染，不截屏幕**；夜间反色不进截图
- **snip overlay 不碰 `contentBody`**（零闪烁纪律）

---

## 10. 落地顺序

| 步 | 内容 | 验收 |
|---|---|---|
| S1 | 浮窗 + provider 内置配置 + 登录态持久 + UA | ✅ 已实现（2026-08-25），**待真机验证**：能登录、能正常聊、置顶/清数据/外部配置各按一次 |
| S2 | 会话绑定（note kind=1 + Inspector 列表 + 失效检测） | ✅ 已实现（2026-08-25），`spike/ai-thread-store-test.swift` 41/41；**页面图钉挪到 S2b 未做**；待真机验证 |
| S3 | 发送适配器：三级回退 + `spike/ai-adapter-test.html` | ✅ 已实现（2026-08-25），自检页 13/13；⚠️ 唯一有外部腐坏风险的一步，DeepSeek 真站待验 |
| S4 | 框选截图 snip（⌥拖 + `.snip` 工具 + 重渲染 + toast） | ✅ 已实现（2026-08-25），`spike/page-snip-test.swift` 34/34；截图清晰度与跨页拼接待真机 |
| S5 | 右键回填笔记（选区回传 + `source` 字段） | ✅ 已实现（2026-08-26），spike 扩到 53/53 |
| S6 | 其余截取形态（视口 / 整页 / 文本优先）+ 其他平台铺开 | |

**S3 单独一个自检页**，别和其他步骤混着验。

---

## 11. S1 已实现（2026-08-25）

新增 `Sources/AI/AIProvider.swift`（平台表 + 外部配置模型）、`Sources/AI/AIPanelModel.swift`
（页面池 / LRU / 登录数据 / 配置装载）、`Sources/Views/AIPanelView.swift`（浮窗 UI + `AIPanelMenu`），
`Sources/App/WindowAccessor.swift` 加 `WindowLevelAccessor`（置顶），`UniReaderApp.swift` 加
`Window` scene 与 `CommandMenu(L("AI"))`。中英双语文案已补齐。`xcodebuild` 通过。

要点：

- **全原生**：`WebView` + `WebPage`，没有 `NSViewRepresentable` 包 `WKWebView`；
  工具栏 = 系统 `.toolbar`（按 Tahoe 合并规则分两枚胶囊，中间 `ToolbarSpacer`），
  进度 = `ProgressView(.linear)`，空态 = `ContentUnavailableView`。零自绘仿系统样式。
- **UA**：默认走 `Configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"`
  （得到与 Safari 等价的 UA）；Gemini 另用 `AIProvider.userAgent` 整条覆盖。
- **内存**：`maxLive = 3` LRU 淘汰；关窗 `releaseIdle()` 只留当前这家。
- **置顶**用 AppKit 设 `NSWindow.level`，不用 scene 级 `.windowLevel()`——后者对已开着的窗口
  是否即时生效没把握，「按了没反应」正是最难查的静默失效。
- **`AIPanelView.body` 拆成 `shell` + 两层 background**：修饰符链挂一个表达式会超类型检查器时限
  （写的时候真撞上了，与 `ContentView` 拆 `mainSplit`/`eventRoutes` 同一个坑）。
- **外部配置**：`~/Library/Application Support/UniReader/ai-providers.json`，解得出至少一项合法才生效，
  否则回落内置；面板「更多」菜单里显示当前用的是哪份（不让它变成查不出的静默失效），
  并提供「在访达中显示配置文件…」（不存在就先导出内置表当模板）与「重新载入配置」。
- `page.isInspectable = true`：S3 调适配器脚本要靠 Web Inspector，发布前再决定是否收起来。
- **工具栏高度**（2026-08-25 用户报「太大太高」后改）：窗口加
  `.windowToolbarStyle(.unifiedCompact(showsTitle: false))`，并去掉 `.navigationSubtitle`
  （副标题把标题区撑成两行，是偏高的主因）。两处都是系统 API，没有自己压高度。
  ⚠️ 若仍嫌高，下一档是 `.windowStyle(.hiddenTitleBar)` + 内容区顶部一条标准控件组成的窄条
  （约 30pt），代价是要自己给红绿灯留位、并开 `isMovableByWindowBackground` 才能拖窗——
  **仍然只用标准控件，不自绘胶囊**。

### 🚧 S1 待真机验证（我不能自证）

1. 各平台能否在面板里**正常登录并聊天**（尤其 Gemini —— 不行就从内置表里去掉）
2. **置顶**按钮是否真的生效（`WindowLevelAccessor` 的唯一风险点）
3. 切平台后**回来是否保留原页面状态**（不重新登录、不丢草稿）
4. 「清除登录数据」后是否**确实需要重新登录**（域名单是否够——登录常挂在另一个域上）
5. 关面板再开是否**即时**（当前这家不该重新加载）

## 11.1 S2 已实现（2026-08-25）

新增 `Sources/AI/AIThread.swift`（模型 + note kind=1 序列化）与 `spike/ai-thread-store-test.swift`
（**41/41 全绿**）；`WorkspaceManager` 加三个 DAO、`DocSession` 加 `aiThreads`/`persistedAIThreads`、
`ContentView` 加 `aiRoutes` 一层与 clear/load/persist 三件套、`AIPanelModel` 加绑定状态机、
`AIPanelView` 加上下文条与 `PageObservers`、`InspectorView` 加「AI 会话」区块、
阅读区右键加「用 … 讨论本页」。`xcodebuild` 通过。

要点：

- **面板不碰库**。面板是 App 级单例，`LibraryStore` 是窗口级且同一个库只许一个连接
  （`REQUIREMENTS.md §8.1` 红线）。所以面板只发 `AIThreadUpsert` 请求，由 **sessionID + documentId
  双对** 的那个窗口认领，写进 `session.aiThreads`，再由既有增量对账落库——**不在 onChange 里直接写库**。
  （同 `padOpenDocRequest` 带 sessionID 的理由：不带的话每个窗口都会执行一遍。）
- **两段式绑定**：`beginBind` 只记 pending 上下文（此刻还没有会话 URL），等 `syncFromPage` 捕到匹配
  `threadPattern` 的 URL 才 commit 成一条 `AIThread`。`goHome()`（新对话）**不清 bindContext**——
  还是为那一页服务，下一条消息会开出一条新会话绑到同一页。
- **`WebPage` 是 Observation 类型，模型自己订阅不了**：URL/标题/加载状态的变化必须由视图
  （`PageObservers` 这个 ViewModifier）读到再转交模型。
- **失效检测**：只在「打开一条已存会话」后的第一次 `isLoading` 转 false 时判——落地 URL 不再匹配
  会话正则 = 被重定向回首页/登录页，标 `suspect`（列表与上下文条都有醒目标记，不静默）。
- **正则可自动化验证**：判定挪到 `AIProvider.matchesThread`，spike 第 ④ 块把「首页不命中 / 登录页
  不命中 / 别家域名夹带不命中 / 实测会话 URL 命中」全钉死了。正则写错 = 绑定永远不 commit，
  这是这个功能唯一能自动化的那条防线。
- **又撞了一次类型检查器时限**：两条 `onChange` 直接挂进 `mainSplit` 当场超时，照 `scratchRoutes`
  的先例抽出 `aiRoutes` 一层。

### 🚧 S2 待真机验证

1. 阅读区右键「用 DeepSeek 讨论本页」→ 面板开、新对话、上下文条显示《书名》+ 页码 +「等待第一条消息」
2. 发出第一条消息 → 上下文条变成 🔗 已绑定；Inspector「笔记」页的「AI 会话」里出现一条
3. 关文档再打开 → 列表里那条还在（落库成功）
4. 点列表条目 → 面板打开并回到那次对话；点 ⊙ → 阅读区跳到那一页
5. 在平台上删掉那个对话，再从列表打开 → 应当标成「⚠️ 可能已不存在」而不是静默显示首页
6. 换文档 / 关窗 → 上下文条不该还挂着上一本书

### S2b（未做）

- 页面**图钉**（形状要与文字笔记的圆形蓝底、草稿纸的圆角方片一眼分得开）
- 会话列表按「最近」排序的选项（当前按页排，与其他笔记列表一致）

## 11.2 S3 + S4 已实现（2026-08-25）

新增 `Sources/AI/PageSnip.swift`（纯几何）+ `PageSnipRender.swift`（按页重渲染 + 跨页拼接）、
`Sources/Views/ReaderSurface+Snip.swift`（手势 + 覆盖层 + 投递）、
`Sources/Resources/ai-adapters.js`（三级回退注入脚本）、
`spike/page-snip-test.swift`（**34/34**）、`spike/ai-adapter-test.html`（**13/13**，Chromium 实跑）。
`PointerTool` 加第 4 态 `.snip`，笔架加一枚，菜单 ⌥S。`xcodebuild` 通过。

### 要点

- **⌥ 拖是主入口**：任何工具下按住 ⌥ 拖即可，松手回原工具。另外三个拖拽手势（拖选 / 本机落墨 /
  框选移动）在 ⌥ 按下时让位，但**只让「尚未起手」的那一次**——已经在拖的不打断
  （各自 guard 读 `snipModifierDown` + 自己的锚点，等价于一个不用新状态的闩）。
- 🔴 **不截屏幕，按页重渲染**：`PageSnip.slices` 把框选折成逐页归一化矩形 →
  `PageBitmap.renderTile`（签名正好是「页显示坐标子矩形 + 像素/pt」）重出图，
  倍率按目标长边定（`scale`，夹在 1.5~4×），**与当前缩放无关**。缩小状态下直接截屏就是小字全糊。
- 🔴 **渲染走 `PageRenderEngine` 的队列**（新增 `renderOffMain`），不在主线程：阅读区页图渲染就在
  那条队列上，同一份 `PDFDocument` 不能并发使用。
- **夜间反色天然不进截图**：`renderTile` 本身不反色（反色是 `PageRenderEngine` 拿到图之后才加的）。
- **注入三级回退 + 逐级验证**：file input → 合成 drop → 合成 paste。光「派发了事件」不等于站点收下了，
  所以每级之后等一下看证据（冒出 `blob:`/`data:` 预览缩略图，**或**正文里出现了我们的文件名——
  所以文件名要取页面上不可能自然出现的串）。三级全哑就老实报失败。
- 🔴 **base64 走 `callJavaScript` 的参数传，JS 里手工 `atob`**——不用 `fetch(dataURL)`，
  站点 CSP 的 `connect-src` 会把那条挡掉。脚本注入 **`.page` world**（隔离世界里造的
  File/DataTransfer 页面的 React 拿不到）；user script 本身不受站点 CSP 约束。
- **不自动按发送**：填好图 + 一行上下文（`《书名》· p.12 · 章节`）后聚焦输入框，用户自己按发送。
  JS 的 `focus()` 只在页面内生效，不抢窗口焦点（用户还在读书）。
- **适配器外部可覆盖**：`~/Library/Application Support/UniReader/ai-adapters.js` 存在即用它，
  站点改版不用重编译发版。
- 发送成功会往当前绑定会话的 `contexts` 追加一条 `region`；**第一条决定图钉/锚点**（S2 的规则）。

### 🚧 S3 + S4 待真机验证

1. 阅读区按住 **⌥ 拖**一个框（或 ⌥S / 笔架那枚切到常驻）→ 区域外压暗、框上角显示 p.N
2. 松手 → 面板打开、右下角出现「已加到 DeepSeek」→ **DeepSeek 输入框里出现图片附件 + 一行上下文**
3. **截图清晰度**：把阅读区缩到很小再框一小块公式 —— 发过去应当依然清晰（这条是「按页重渲染」的意义）
4. **跨页框选**：从一页底部拖到下一页顶部 → 应当是两段纵向拼接、中间一条浅灰分隔
5. 夜间模式下框选 → 发过去的图应当是**白底黑字**（不是反色的）
6. 三级回退：若「没能放进输入框」，`~/Library/Logs/UniReader-ws.log` 里有 `[SNIP] 投递失败 tried=...`
   （先 `touch` 那个文件开日志），把那一行给我就能定位是哪一级断的
7. 回归：⌥ 没按住时拖选文字 / 本机落墨 / 框选移动都不受影响

### 站点坏了怎么办

先跑自检页 —— 三条链路各出一个 PASS/FAIL，一分钟分清是**脚本坏了**还是**站点变了**：

```bash
cd ~/agent-home/uni-reader && python3 -m http.server 8899 &
open http://127.0.0.1:8899/spike/ai-adapter-test.html
```

## 11.3 S5 已实现（2026-08-26）

`TextNote` 加 `source`（`NoteSource`：kind/provider/url/thread_id/at）、`ai-adapters.js` 加选区回传、
`AIPanelModel` 加 `AIMessageBridge` + `requestNoteFromSelection`、`AIPanelView` 加 `.webViewContextMenu`、
`ContentView` 加 `applyAINoteRequest`、Inspector 的笔记行加「回到出处对话」徽标。
`spike/ai-thread-store-test.swift` 扩到 **53/53**（新增第 ⑤ 块），自检页仍 13/13，`xcodebuild` 通过。

要点：

- **选区必须靠注入脚本推上来**：`.webViewContextMenu` 给的 `ActivatedElementInfo` **只有 `linkURL`**
  （已核 SDK）。脚本监听 `selectionchange`（节流 150ms）+ `mouseup`/`keyup` 补刀，
  经 `webkit.messageHandlers.unireader` 推给原生侧存着。
  ⚠️ **messageHandler 的 contentWorld 必须与脚本一致**（都是 `.page`）：不一致时
  `webkit.messageHandlers.unireader` 是 undefined，而那句 postMessage 包在 try 里 —— **不会报错，
  只会一声不响什么都收不到**。
- ⚠️ **`.webViewContextMenu` 取代系统默认网页右键菜单**，所以剪贴板三项要自己补回来
  （走 `NSApp.sendAction` 转发响应链，webview 就在链上，比自己实现靠谱）。
- **锚点规则落到实处**：笔记的 page/anchor 取 `boundThread.contexts.first`（用户定的「多张图用第一张」）；
  一次都没发过东西时回落到发起绑定的页 + 一个靠左上的零尺寸锚点（同「在此添加批注」的点注解形态），**别丢**。
- **正文原样存 Markdown/LaTeX**，不做转换；`quote` 填这次对话里发过的引文（有的话）。
- `source` 是**零迁移**：旧 payload 无此键 → nil；没有来源时也**不写** `source` 键（别给旧端/跨端塞个 null）。
  spike 第 ⑤ 块把这两条都钉死了。
- Inspector 笔记行的 💬 徽标点回出处对话；绑定记录已被解绑时走 `openLoose`
  ——**只按 URL 开、不重新建绑定**，否则点一下「看看出处」就凭空多出一条会话。

### 🚧 S5 待真机验证

1. 面板里选中 DeepSeek 的一段回答 → 右键 →「添加到文字笔记」→ 上下文条闪「已加到笔记」
2. Inspector（⌘I）笔记页出现这条，正文是那段回答，行尾有 💬 徽标
3. 点 💬 → 回到那次对话；点条目本身 → 阅读区跳到**第一张图那一页那一处**
4. 右键菜单里的剪切/拷贝/粘贴仍可用（这条菜单换掉了系统默认的）
5. 没选中文字 / 面板没绑定时，「添加到文字笔记」应当是灰的
6. 关文档再打开，笔记与徽标都还在

## 11.4 面板快捷键修复（2026-08-26）

用户报「webview 窗口的基本快捷键还是要有的，⌘C ⌘V 这些」。

- 🔴 **⌘C / ⌘A 在面板里是彻底不响应的**。根因在 `UniReaderApp` 那段
  `CommandGroup(replacing: .pasteboard)`：判据是 `NSApp.keyWindow?.firstResponder is NSText`，
  而面板的第一响应者是 **WKWebView**（既不是 NSText），于是走 else 分支发 `.readerCopy` 通知，
  可那时没有任何 ContentView 是 key 窗口 → **一声不响什么都不做**。
  改成 **先试响应链，没人接才回落阅读区**：`NSApp.sendAction(...)` 的返回值就是「有没有响应者接住」
  ——webview 与文本框都会接，纯 SwiftUI 的阅读区不在响应链上必然 false，正好当分流开关。
  ⌘X / ⌘V / Delete 本来就是无条件 `sendAction`，不受影响。
- 新增**窗口级**快捷键（挂在面板自己的按钮上，不外泄成 App 级命令）：
  ⌘R 重新载入、⌘[ 后退、⌘] 前进、⌘G / ⇧⌘G 查找上下条。
- **⌘F 页内查找**：WebKit for SwiftUI 没有 `findNavigator`，`WKWebView.find` 又够不着
  （我们持有的是 `WebPage`），所以走注入侧的 `window.find()`。⌘F 复用与阅读区同一条通知路由
  （App 级命令 → 通知 → key 窗口认领），面板靠 `WindowAccessor` 知道自己是不是 key。
- **⌘± / ⌘0 刻意不接**：捏合缩放（`webViewMagnificationGestures`）已经能用，而 CSS `zoom`
  会把聊天站点的固定定位布局搞坏，得不偿失。

## 11.5 吸附 + 内置模式（2026-08-26）

用户要的两件事：**浮窗默认贴在主窗口右侧并跟随移动**（主窗口非最大化时）；
**另做一个内置模式**——面板直接显示在阅读窗口里，收起时是右下角一枚气泡按钮。

### 吸附（`Sources/App/AIPanelDock.swift`）

- ✅ 用户实测「比想要的还好」：子窗口既能**自由拖动**、又**保持相对位置**跟随，
  主窗口缩放时还会重新贴回右侧（`didResize` → `reapply`）。这三条是 `addChildWindow` +
  resize 重贴自然长出来的，别为了「更可控」改回手算位移而弄丢。
- 跟随用 AppKit 的**子窗口**（`addChildWindow`）而不是「监听 didMove 再算位移」：
  子窗口的跟随由窗口服务器做，拖主窗口时严丝合缝；自己算位移在快拖时必然掉队抖动。
  代价是子窗口跟父窗口一起关、且恒在父窗口之上——对「贴着书的面板」正合适。
- **主窗口最大化/全屏时不吸附**（用户明确的条件）：那时右边没地方，硬贴会把面板顶出屏幕。
  判据用「近似铺满可用区域」而不是 `isZoomed`——手动拖到几乎满屏也一样没地方。
- ⚠️ `addChildWindow` 会把子窗口层级拉成与父窗口一致，**把「置顶」按钮的效果抹掉** →
  贴完要补一次 `panel.level`（`WindowLevelAccessor` 只在 SwiftUI 更新时跑，赶不上这一下）。
- 宿主 = 当前 key 的阅读窗口（`ContentView` 的 `onKeyChange` 里交接），换窗口就跟过去。
  主窗口 resize 时重新判定还能不能吸附。

### 内置模式（`Sources/Views/AIInlineLayer.swift`）

- 🔴 **两种形态互斥**：同一个 `WebPage` 只能被一个 `WebView` 挂着（底层就一个 WKWebView）。
  真源是 `AIPanelModel.mode`——内置时浮窗那边改画占位（`AIPanelView.pageArea`），
  切到内置会顺手 `dismissWindow`。网页区抽成共用的 `AIWebArea`（连右键菜单一起），不复制两份。
- **挂在 `PageStreamView` 这一层，不是 `ReaderSurface` 里**：阅读区那四个拖拽手势挂在 ScrollView
  容器上，用 `.overlay` 加在**同一个视图**上的覆盖层挡不住它们（草稿纸就是为此才要在每个 gesture
  里写 `openPadID == nil`）。挂到上一层就是普通遮挡关系，**一行门控都不用加**。
- **只在当前活跃的那扇阅读窗口里出现**：`app.activeSessionID` 单值，天然保证只有一个宿主；
  换窗口面板跟过去（同「平板跟随最后激活窗口」的既有语义）。
- 挂在 `.id(docKey)` **之后**：换文档不该把面板连同网页一起拆掉重建。
- 气泡 46pt 圆钮（material + 0.5 描边 + 阴影，与 PenRack 同一套），左缘可拖改宽度（300~900，持久化）。
- 各入口（右键讨论本页 / 框选投递 / 从列表打开会话 / ⌘⇧A）统一走 `AIPanelModel.present(_:)`：
  内置就展开侧面板，浮窗就开窗口，不用每处各写一遍分支。
- 框选 toast 靠右下，会被内置面板盖住 → 按面板宽度让开。
  **刻意不让 `ReaderSurface` observe `AIPanelModel`**：订阅一个 App 级 `@Published` 会让面板的任何
  变化都重算整个阅读区（`readZoom` 那条性能红线就是这么踩出来的），toast 出现那一刻现读一次就够。

### 🔴 WebPage 宿主交接（2026-08-26 修一次秒崩）

用户点「改为窗口内置」**当场崩溃**，栈停在 `_WebKit_SwiftUI` 的 `makeViewProvider` ——
就是第二个 `WebView` 去挂同一个 `WebPage` 的那一刻。

**光用 `mode` 当真源不够**：`mode` 一变，浮窗和阅读窗口的视图在**同一次更新里**各自重算，
谁先谁后没有保证，新宿主完全可能赶在旧宿主卸载之前挂上去。而且这个隐患不止切模式——
**切活跃阅读窗口**（A 窗内置层卸载、B 窗挂载）是一模一样的形状，原来的写法迟早也会在那儿崩。

改成显式交接（`AIPanelModel.webHostToken` + `requestHost`/`releaseHost`）：

- 每个宿主一个 token（浮窗一个常量；每扇阅读窗口的内置层用 `session.id`）
- 想挂就 `requestHost`；**被占着就排队**，等旧宿主 `releaseHost` 之后**隔一拍**（`main.async`）才交接
  —— 保证中间必然存在「没人挂」的一帧，旧的 NSView 已从层级里摘干净
- 渲染条件一律是 `webHostToken == 自己的 token`；不等就画一个 spinner，**那一帧绝不能挂 WebView**
- 自愈：`onChange(of: webHostToken)` 里，token 空出来而自己还想要就补一次申请

### 🚧 待真机验证

1. 主窗口**非最大化**时开面板 → 应当自动贴到右侧、上下同高；拖动主窗口面板**跟着走**
2. 把主窗口最大化 → 面板应当**松开**（不再跟随、也不被顶出屏幕）；还原窗口后重新贴上
3. 开两扇阅读窗口来回切 → 面板跟到当前那扇（吸附与内置模式都是）
4. 吸附状态下按「置顶」图钉仍然有效（这条是 `addChildWindow` 会抹掉层级的补丁）
5. 「更多 → 改为窗口内置」→ 浮窗关掉、右下角出现气泡；点气泡展开侧面板；拖左缘改宽度
6. 内置面板里「弹出为独立窗口」→ 回到浮窗形态，网页状态（登录/草稿/滚动）不丢
7. 内置面板展开时，在它上面拖动**不该**触发阅读区的拖选/落墨/框选
8. 内置模式下 ⌘⇧A 是展开/收起，不是开窗口

## 11.7 🔴 webview 的生命周期归我们自己管（2026-08-26，崩四次后的定案）

**弃用 macOS 26 那套 SwiftUI `WebView`/`WebPage`，改成自己持有 `WKWebView`。**

四次崩溃全停在 `_WebKit_SwiftUI.makeViewProvider` —— 视图一被重建，SwiftUI 就再造一个 `WebView`
去挂同一个 `WebPage`，WebKit 当场 trap。我四次的修法是：

| # | 修法 | 为什么没用 |
|---|---|---|
| 1 | 按 `mode` 分支，两边各自决定画网页还是占位 | 两扇窗口在同一次更新里各自重算，先后没保证 |
| 2 | token 交接 + `DispatchQueue.main.async` 隔一拍 | **`main.async` ≠「SwiftUI 已渲染完」**，更新是合并调度的 |
| 3 | 每个宿主一份自己的 `WebPage` | 只保证**不同宿主**不撞，挡不住**同一宿主的挂载点被重建** |
| 4 | 把挂载点移到「身份稳定」的 `readerColumn` | **「SwiftUI 保证不重建某个视图」这个前提本身不成立**——面包屑实测：连启动都会重建两次 |

前四次的共同错误：**试图约束 SwiftUI 的视图生命周期**。它有权随时重建任何视图，这不是可以商量的。

**定案**：把约束从「视图树里只能有一个 WebView」换成「**压根只有一个 webview 对象**」。

- `AIPageBox`（`Sources/AI/AIWebView.swift`）持有一个 `AIWebView: WKWebView`，
  KVO 把 `url`/`title`/`isLoading`/`estimatedProgress`/`canGoBack/Forward` 镜像成 `@Published`
- `AIWebHost: NSViewRepresentable` 只是个**空容器**：`updateNSView` 把那个 webview `addSubview` 进来。
  AppKit 的 `addSubview` 本来就会先从旧父移除 —— 重建 = 重新挂一次父，**合法、幂等、不可能 trap**
- 视图重建从「会崩」降级成「最多闪一下」

**顺带修好的**：右键菜单改由 `AIWebView.willOpenMenu` 往**系统菜单上追加**一项，
原生的剪切/拷贝/粘贴/查询/服务全部保留。之前用 SwiftUI 的 `.webViewContextMenu` 是把系统菜单
整个**取代**掉，我只能一条条手工补回来（还补不全）——那本身就是个我引入的回退。

**规则：往这个 app 里放任何 AppKit 承载的长驻视图（webview、播放器、相机预览…），
生命周期都要自己管，别指望 SwiftUI 不重建它。**

### 闪烁的两个成因（2026-08-26 用户报「不崩了，但会闪」）

不崩之后剩下视觉问题。拆开是两件事，第一件是可以彻底消掉的：

1. **`@State` 缓存页面 → 重建后先渲一帧占位。**
   视图一被重建 `@State page` 就归 nil，body 先画「没有页面」的占位，等 `onAppear` 把页面塞回来
   才切成网页 —— **这一下必然闪**。改成 body 直接 `panel.existingPage(for: host)`（纯查找、不创建），
   重建后第一帧就拿到同一份页面；创建仍只在 `onAppear`/`onChange` 里做。
   配套加了 `pagesRevision`（`pages` 是普通字典不发布，靠它触发刷新）。

2. **重新挂父带来的重排。** 两处优化：
   - `AIPageBox` 自持一个**常驻容器**，**webview 的父视图永远是它、从不更换**；
     SwiftUI 那边移动的是容器，webview 底下整棵渲染树原封不动。
   - 用 **Auto Layout 钉四边**，不用 `autoresizingMask`：新外壳初始 bounds 是 `.zero`，
     旧写法会先把 webview 压成 0×0 再撑开，WebKit 整页重排一次。

### 🔴 「整块变白，按个快捷键才回来」——容器被拆除中的外壳带走了

隔一层外壳**还不够**。实测（2026-08-26）：外壳被拆时会把当时挂在它里面的常驻容器一并带走，
而**活着的那个外壳不会再收到 `updateNSView`**（它的输入没变）→ 容器再也回不来，面板整块空白，
直到用户碰个快捷键触发一次更新才恢复。

修法是让外壳**自己会把容器抢回来**，规则一句话：**「谁在窗口里，谁才有资格抢」**
（`AIWebShell`，`viewDidMoveToWindow` / `layout` 里 `claim()`，`window != nil` 才动手）：

- 刚建好、还没进窗口的外壳 → 不抢（不会从活着的那个手里偷走）
- 正在被拆、已离开窗口的外壳 → 不抢（也就带不走）
- 真正在显示的那个 → 每次布局都把容器拉回来（自愈，不依赖 SwiftUI 何时更新）

外加一条**离场交接**：外壳发现自己 `window == nil` 且容器还在自己这儿时，
调 `box.rehome()` 把它交给还在窗口里的外壳。补的是「被拆的那个在离场**之前**刚好抢走了容器，
而活着的那个不保证会再布局一次」这个缝。

⚠️ `makeNSView` 仍然**不直接返回 `box.container`**：SwiftUI 拆除时摘的是它给出的那个视图，
让它摘自己那层外壳就好。

### 换文档**不**新开对话（2026-08-26 用户确认可接受）

内置面板的会话跟着**窗口**走，不跟着文档走：在同一扇窗口里换一本书，面板里那个对话原样继续。

这是刻意的，别当 bug 修掉：
- 网页按**宿主**（窗口）分配，本来就与文档无关；
- 常见用法是「拿另一本书里的图接着问同一个问题」，硬新开对话反而碍事；
- 真要为新书开一段，右键「用 … 讨论本页」或面板里「新对话」都是一步的事。

换文档时**会**做的只有一件：`noteDocumentChanged` 把旧的绑定上下文作废
（否则上下文条会一直显示上一本书）。

### 页面仍按宿主分配

（这条独立于上面的所有权问题，依然成立）每扇阅读窗口的内置面板、那扇浮窗，各一份 `AIPageBox`：

## 11.7b 每宿主一份页面（原 11.7，仍然有效）

**放弃「一个 `WebPage` 两边轮流挂」，改成每个宿主一份。** 用户提的方向，比我的交接方案对。

两次崩溃都停在 `_WebKit_SwiftUI.makeViewProvider`（第二个 `WebView` 去挂同一个 `WebPage`）：

| 尝试 | 为什么没挡住 |
|---|---|
| ① 按 `mode` 分支，两边各自决定画网页还是占位 | 两扇窗口在**同一次更新**里各自重算，谁先谁后没有保证 |
| ② token 交接：先置 nil，`DispatchQueue.main.async` 隔一拍再交给排队的那个 | **`main.async` 不等于「SwiftUI 已经渲染完」**——它的更新是合并调度的，很可能在那个 async 块之后才刷一次，于是只看到最终值，卸载与挂载仍在同一趟 |

两次都栽在同一个前提上：**以为能安排 SwiftUI 更新的先后。安排不了。**
所以把不变式从「靠时序维持」换成「靠结构成立」：

- `AIHost` = `.window` / `.inline(session.id)`，页面按 **宿主 × 平台** 分配（`PageKey`）
- 每个宿主渲染的永远是**自己那一份**，两个 `WebView` 挂同一个 `WebPage` 在结构上不可能发生
- 登录态不受影响（共用 `WKWebsiteDataStore.default()`）
- 切形态时 `carryURL` 把当前对话 URL 带给新宿主，至少停在同一个对话

### 🔴 内置层的挂载点必须是**稳定身份**

第三次同一处崩溃（2026-08-26「开着 webview 切换书」）。**「每宿主一份页面」只保证不同宿主不撞，
挡不住同一宿主的挂载点被重建**——重建时新实例向模型要页面，拿到的还是同一个 `WebPage`，
而旧的 `WebView` 尚未拆干净。

原来挂在 `PageStreamView.body` 里、`.id(docKey)` 之后，我以为「`.id` 之后的修饰符不受影响」。
实测不是：换文档时那一整段连同 overlay 一起重建。

现在挂在 `ContentView.readerColumn` 外层——**不在任何 `if` 分支里，也不在任何 `.id()` 下游**：

```swift
private var readerColumn: some View {
    readerContent                                   // 里面的 if / PageStreamView(.id(docKey)) 随便换
        .overlay { AIInlineLayer(session: session) }  // 这一层身份稳定
}
```

挂 `readerColumn` 而不是更外层的 `mainSplit`：这样只盖阅读区，不会盖住 Inspector。
同时它仍在阅读区手势所在视图的**上一层**，天然挡住那四个拖拽手势（一行门控都不用加）。

**规则：以后往阅读窗口里加任何长驻的 AppKit 承载视图（webview、播放器…），
挂载点都必须先确认身份稳定 —— 在 `if` 分支或 `.id()` 下游都不算。**

排障面包屑：`AIPanelModel.page(for:)` 里，同一宿主 0.5s 内重复取页面会往 `UniReader-ws.log`
写一行警告（`touch ~/Library/Logs/UniReader-ws.log` 开）。再崩先看有没有这一行。

### 🔴 内置模式：**每扇阅读窗口都显示自己的聊天**

用户 2026-08-26：「开两扇阅读窗口，还是只有一个窗口显示！我要每个 windows 同时显示聊天」。

我原来把内置层门控成 `app.activeSessionID == session.id`（只有活跃窗口显示）。**那是为了规避
崩溃临时加的限制，不是设计** —— 页面按宿主分配之后，这条限制已经没有任何存在理由，
却被我留在那里当成了产品行为。现在：

- `hosts = (mode == .inline)`，**每扇窗口都渲染自己的那一个**，各挂各的 `WebPage`
- 展开/收起**按窗口分别记**（`inlineOpenSessions: Set<UUID>`）；新窗口沿用持久化的
  `inlineOpenDefault`（session id 每次启动都是新的，存 id 没意义）
- ⚠️ **`activeHost` 由「哪扇窗口是 key」决定**（`ContentView.onKeyChange`），
  **不能在内置层的 `onAppear` 里抢** —— 多扇窗口的面板同时出现时，谁最后 appear 谁就赢，那是错的。
  模型级操作（绑定捕获 / 投递 / 导航按钮）都作用在 `activeHost` 那一份页面上。
- 各入口的 `present(session:)` 带上发起窗口的 session，顺手把 `activeHost` 指过去

### 页面只在「宿主消失」时释放

用户 2026-08-26：「保留页面这个很重要，并且多个窗口的状态本身就是不一样的」。所以：

- **淘汰只在同一个宿主内部发生**（同一扇窗口里切过几个平台时放掉不用的），
  `maxPagesPerHost = 2`；**绝不跨宿主淘汰**——被别的窗口挤掉就是丢对话状态
- 「切到别的阅读窗口」「收成气泡」都**不算宿主消失**，不放页面
- 真正的回收：浮窗关闭 → `releaseHost(.window)`；阅读窗口关闭 → `ContentView.onDisappear`
  里 `releaseHost(.inline(session.id))`

### 「谁在接键盘」不能按具体类型猜

内置面板把一个 webview 放进了阅读窗口，于是阅读区那套**单键**工具快捷键
（`e` 橡皮 / `1`~`9` 选笔 / `n b v l i t`）在面板里打字时把键抢走了（用户报：输入 `e` 变橡皮）。

根因与 ⌘C 在面板里失灵**完全同一类**：判据是 `firstResponder is NSText`，而 **WKWebView 不是 NSText**。
现在统一用 `aiWebInputHasFocus()`（沿响应链找 `WKWebView`），单键监视器与 Esc 监视器都加了这一条。

**以后凡是「阅读区要不要吃掉这个键」的判断，都必须把 webview 这条算进去。**
（已知仍未处理：`.commands` 里的 ⌥ 系菜单快捷键——⌥E 之类在任何文本框里也一样会被菜单抢，
是既有行为，未报问题，暂不动。）

## 11.6 webview 内存实测（2026-08-26）

量法：`footprint`（不是 `ps` 的 RSS）+ 按增量归属 WebContent 进程（`scripts/ai-mem.sh`）。

| 场景 | UniReader 本体 | WebContent 进程 | 新增合计 |
|---|---|---|---|
| 开 1 个内置 | 175 MB | 1 个（100 MB） | **100 MB** |
| 切成 1 个浮窗 | 182 MB | **仍是同一个 pid**（103 MB） | 103 MB |
| 2 个浮窗 | 190 MB | 2 个（104 + 110） | **214 MB** |
| 2 个内置 | 189 MB | 2 个（100 + 100） | **200 MB** |

**结论（可直接依赖）**

1. **每个宿主一个独立 WebContent 进程，同源也不共享**：约 **100~110 MB / 个**，线性叠加。
2. 代价按「**同时可见的面板数**」算 —— 两扇窗口都开着面板 ≈ +200 MB。
3. 所以现行策略不用改：`maxPagesPerHost = 2`、「只在宿主消失时释放」都够用。
   真正的上限由用户同时开几扇窗口决定，那是他自己的选择。

**推断（数据不足以坐实，别当结论用）**

「切成浮窗」那次仍然只有一个 WebContent，而按设计那时内置那份页面并没有被释放
→ **不可见的那份，其 WebContent 进程很可能被 WebKit 回收/复用了**。
数据只能证明「没有出现第二个进程」，复用是最合理的解释，但没有直接证据。
若哪天要做更激进的内存策略，先把这条坐实再动。

**顺带记一笔（与 AI 无关，另行排查）**：另一次长时间阅读后测到 UniReader 本体
**footprint 1361 MB**（CoreAnimation 558 MB + CG raster 553 MB），而设置里页图缓存上限默认 512 MB
—— 阅读区自己的内存占用值得单独看一次，别混进 AI 面板的账里。

### 量法（两个坑，不绕开必量错）

脚本：`scripts/ai-mem.sh`

```bash
scripts/ai-mem.sh mark            # 面板还没开时先打基准
scripts/ai-mem.sh "开了浮窗"       # 之后每变一次形态跑一次
```

- 🔴 **`ps` 的 RSS 严重低估**：同一进程 RSS 82 MB / footprint 1361 MB。一律看 footprint。
- 🔴 **WebContent 的 ppid 是 1**（launchd 起的 XPC 服务），没法靠父子关系归属到 app
  → 用 `mark` 记下基准时刻已有的进程，之后只算**新增**的（同时开着 Safari 的噪音也是这么排掉的）。

## 11.7 🔴 webview 的生命周期归我们自己管（2026-08-26，崩四次后的定案）

**弃用 macOS 26 那套 SwiftUI `WebView`/`WebPage`，改成自己持有 `WKWebView`。**

四次崩溃全停在 `_WebKit_SwiftUI.makeViewProvider` —— 视图一被重建，SwiftUI 就再造一个 `WebView`
去挂同一个 `WebPage`，WebKit 当场 trap。我四次的修法是：

| # | 修法 | 为什么没用 |
|---|---|---|
| 1 | 按 `mode` 分支，两边各自决定画网页还是占位 | 两扇窗口在同一次更新里各自重算，先后没保证 |
| 2 | token 交接 + `DispatchQueue.main.async` 隔一拍 | **`main.async` ≠「SwiftUI 已渲染完」**，更新是合并调度的 |
| 3 | 每个宿主一份自己的 `WebPage` | 只保证**不同宿主**不撞，挡不住**同一宿主的挂载点被重建** |
| 4 | 把挂载点移到「身份稳定」的 `readerColumn` | **「SwiftUI 保证不重建某个视图」这个前提本身不成立**——面包屑实测：连启动都会重建两次 |

前四次的共同错误：**试图约束 SwiftUI 的视图生命周期**。它有权随时重建任何视图，这不是可以商量的。

**定案**：把约束从「视图树里只能有一个 WebView」换成「**压根只有一个 webview 对象**」。

- `AIPageBox`（`Sources/AI/AIWebView.swift`）持有一个 `AIWebView: WKWebView`，
  KVO 把 `url`/`title`/`isLoading`/`estimatedProgress`/`canGoBack/Forward` 镜像成 `@Published`
- `AIWebHost: NSViewRepresentable` 只是个**空容器**：`updateNSView` 把那个 webview `addSubview` 进来。
  AppKit 的 `addSubview` 本来就会先从旧父移除 —— 重建 = 重新挂一次父，**合法、幂等、不可能 trap**
- 视图重建从「会崩」降级成「最多闪一下」

**顺带修好的**：右键菜单改由 `AIWebView.willOpenMenu` 往**系统菜单上追加**一项，
原生的剪切/拷贝/粘贴/查询/服务全部保留。之前用 SwiftUI 的 `.webViewContextMenu` 是把系统菜单
整个**取代**掉，我只能一条条手工补回来（还补不全）——那本身就是个我引入的回退。

**规则：往这个 app 里放任何 AppKit 承载的长驻视图（webview、播放器、相机预览…），
生命周期都要自己管，别指望 SwiftUI 不重建它。**

### 闪烁的两个成因（2026-08-26 用户报「不崩了，但会闪」）

不崩之后剩下视觉问题。拆开是两件事，第一件是可以彻底消掉的：

1. **`@State` 缓存页面 → 重建后先渲一帧占位。**
   视图一被重建 `@State page` 就归 nil，body 先画「没有页面」的占位，等 `onAppear` 把页面塞回来
   才切成网页 —— **这一下必然闪**。改成 body 直接 `panel.existingPage(for: host)`（纯查找、不创建），
   重建后第一帧就拿到同一份页面；创建仍只在 `onAppear`/`onChange` 里做。
   配套加了 `pagesRevision`（`pages` 是普通字典不发布，靠它触发刷新）。

2. **重新挂父带来的重排。** 两处优化：
   - `AIPageBox` 自持一个**常驻容器**，**webview 的父视图永远是它、从不更换**；
     SwiftUI 那边移动的是容器，webview 底下整棵渲染树原封不动。
   - 用 **Auto Layout 钉四边**，不用 `autoresizingMask`：新外壳初始 bounds 是 `.zero`，
     旧写法会先把 webview 压成 0×0 再撑开，WebKit 整页重排一次。

### 🔴 「整块变白，按个快捷键才回来」——容器被拆除中的外壳带走了

隔一层外壳**还不够**。实测（2026-08-26）：外壳被拆时会把当时挂在它里面的常驻容器一并带走，
而**活着的那个外壳不会再收到 `updateNSView`**（它的输入没变）→ 容器再也回不来，面板整块空白，
直到用户碰个快捷键触发一次更新才恢复。

修法是让外壳**自己会把容器抢回来**，规则一句话：**「谁在窗口里，谁才有资格抢」**
（`AIWebShell`，`viewDidMoveToWindow` / `layout` 里 `claim()`，`window != nil` 才动手）：

- 刚建好、还没进窗口的外壳 → 不抢（不会从活着的那个手里偷走）
- 正在被拆、已离开窗口的外壳 → 不抢（也就带不走）
- 真正在显示的那个 → 每次布局都把容器拉回来（自愈，不依赖 SwiftUI 何时更新）

外加一条**离场交接**：外壳发现自己 `window == nil` 且容器还在自己这儿时，
调 `box.rehome()` 把它交给还在窗口里的外壳。补的是「被拆的那个在离场**之前**刚好抢走了容器，
而活着的那个不保证会再布局一次」这个缝。

⚠️ `makeNSView` 仍然**不直接返回 `box.container`**：SwiftUI 拆除时摘的是它给出的那个视图，
让它摘自己那层外壳就好。

### 换文档**不**新开对话（2026-08-26 用户确认可接受）

内置面板的会话跟着**窗口**走，不跟着文档走：在同一扇窗口里换一本书，面板里那个对话原样继续。

这是刻意的，别当 bug 修掉：
- 网页按**宿主**（窗口）分配，本来就与文档无关；
- 常见用法是「拿另一本书里的图接着问同一个问题」，硬新开对话反而碍事；
- 真要为新书开一段，右键「用 … 讨论本页」或面板里「新对话」都是一步的事。

换文档时**会**做的只有一件：`noteDocumentChanged` 把旧的绑定上下文作废
（否则上下文条会一直显示上一本书）。

### 页面仍按宿主分配

（这条独立于上面的所有权问题，依然成立）每扇阅读窗口的内置面板、那扇浮窗，各一份 `AIPageBox`：

## 11.7b 每宿主一份页面（原 11.7，仍然有效）

**放弃「一个 `WebPage` 两边轮流挂」，改成每个宿主一份。** 用户提的方向，比我的交接方案对。

两次崩溃都停在 `_WebKit_SwiftUI.makeViewProvider`（第二个 `WebView` 去挂同一个 `WebPage`）：

| 尝试 | 为什么没挡住 |
|---|---|
| ① 按 `mode` 分支，两边各自决定画网页还是占位 | 两扇窗口在**同一次更新**里各自重算，谁先谁后没有保证 |
| ② token 交接：先置 nil，`DispatchQueue.main.async` 隔一拍再交给排队的那个 | **`main.async` 不等于「SwiftUI 已经渲染完」**——它的更新是合并调度的，很可能在那个 async 块之后才刷一次，于是只看到最终值，卸载与挂载仍在同一趟 |

两次都栽在同一个前提上：**以为能安排 SwiftUI 更新的先后。安排不了。**
所以把不变式从「靠时序维持」换成「靠结构成立」：

- `AIHost` = `.window` / `.inline(session.id)`，页面按 **宿主 × 平台** 分配（`PageKey`）
- 每个宿主渲染的永远是**自己那一份**，两个 `WebView` 挂同一个 `WebPage` 在结构上不可能发生
- 登录态不受影响（共用 `WKWebsiteDataStore.default()`）
- 切形态时 `carryURL` 把当前对话 URL 带给新宿主，至少停在同一个对话

### 🔴 内置层的挂载点必须是**稳定身份**

第三次同一处崩溃（2026-08-26「开着 webview 切换书」）。**「每宿主一份页面」只保证不同宿主不撞，
挡不住同一宿主的挂载点被重建**——重建时新实例向模型要页面，拿到的还是同一个 `WebPage`，
而旧的 `WebView` 尚未拆干净。

原来挂在 `PageStreamView.body` 里、`.id(docKey)` 之后，我以为「`.id` 之后的修饰符不受影响」。
实测不是：换文档时那一整段连同 overlay 一起重建。

现在挂在 `ContentView.readerColumn` 外层——**不在任何 `if` 分支里，也不在任何 `.id()` 下游**：

```swift
private var readerColumn: some View {
    readerContent                                   // 里面的 if / PageStreamView(.id(docKey)) 随便换
        .overlay { AIInlineLayer(session: session) }  // 这一层身份稳定
}
```

挂 `readerColumn` 而不是更外层的 `mainSplit`：这样只盖阅读区，不会盖住 Inspector。
同时它仍在阅读区手势所在视图的**上一层**，天然挡住那四个拖拽手势（一行门控都不用加）。

**规则：以后往阅读窗口里加任何长驻的 AppKit 承载视图（webview、播放器…），
挂载点都必须先确认身份稳定 —— 在 `if` 分支或 `.id()` 下游都不算。**

排障面包屑：`AIPanelModel.page(for:)` 里，同一宿主 0.5s 内重复取页面会往 `UniReader-ws.log`
写一行警告（`touch ~/Library/Logs/UniReader-ws.log` 开）。再崩先看有没有这一行。

### 🔴 内置模式：**每扇阅读窗口都显示自己的聊天**

用户 2026-08-26：「开两扇阅读窗口，还是只有一个窗口显示！我要每个 windows 同时显示聊天」。

我原来把内置层门控成 `app.activeSessionID == session.id`（只有活跃窗口显示）。**那是为了规避
崩溃临时加的限制，不是设计** —— 页面按宿主分配之后，这条限制已经没有任何存在理由，
却被我留在那里当成了产品行为。现在：

- `hosts = (mode == .inline)`，**每扇窗口都渲染自己的那一个**，各挂各的 `WebPage`
- 展开/收起**按窗口分别记**（`inlineOpenSessions: Set<UUID>`）；新窗口沿用持久化的
  `inlineOpenDefault`（session id 每次启动都是新的，存 id 没意义）
- ⚠️ **`activeHost` 由「哪扇窗口是 key」决定**（`ContentView.onKeyChange`），
  **不能在内置层的 `onAppear` 里抢** —— 多扇窗口的面板同时出现时，谁最后 appear 谁就赢，那是错的。
  模型级操作（绑定捕获 / 投递 / 导航按钮）都作用在 `activeHost` 那一份页面上。
- 各入口的 `present(session:)` 带上发起窗口的 session，顺手把 `activeHost` 指过去

### 页面只在「宿主消失」时释放

用户 2026-08-26：「保留页面这个很重要，并且多个窗口的状态本身就是不一样的」。所以：

- **淘汰只在同一个宿主内部发生**（同一扇窗口里切过几个平台时放掉不用的），
  `maxPagesPerHost = 2`；**绝不跨宿主淘汰**——被别的窗口挤掉就是丢对话状态
- 「切到别的阅读窗口」「收成气泡」都**不算宿主消失**，不放页面
- 真正的回收：浮窗关闭 → `releaseHost(.window)`；阅读窗口关闭 → `ContentView.onDisappear`
  里 `releaseHost(.inline(session.id))`

### 「谁在接键盘」不能按具体类型猜

内置面板把一个 webview 放进了阅读窗口，于是阅读区那套**单键**工具快捷键
（`e` 橡皮 / `1`~`9` 选笔 / `n b v l i t`）在面板里打字时把键抢走了（用户报：输入 `e` 变橡皮）。

根因与 ⌘C 在面板里失灵**完全同一类**：判据是 `firstResponder is NSText`，而 **WKWebView 不是 NSText**。
现在统一用 `aiWebInputHasFocus()`（沿响应链找 `WKWebView`），单键监视器与 Esc 监视器都加了这一条。

**以后凡是「阅读区要不要吃掉这个键」的判断，都必须把 webview 这条算进去。**
（已知仍未处理：`.commands` 里的 ⌥ 系菜单快捷键——⌥E 之类在任何文本框里也一样会被菜单抢，
是既有行为，未报问题，暂不动。）

## 11.6 ⚠️ webview 内存：还没实测过

**`100~300MB` 这个数是我按一般经验写的，没有在本项目上量过**（2026-08-26 用户问起才发现）。
它已经被当成既成事实写进了方案、TODO 和提交信息，还成了「per-host 页面划不划算」的论据之一——
在量出来之前，**别拿它当依据做取舍**。

量之前先记住两条结构事实（这两条是确定的）：

1. **WKWebView 的内容跑在独立进程里**（`com.apple.WebKit.WebContent`，另有共享的 Networking / GPU 进程）。
   所以**活动监视器里 UniReader 那一行根本不含它** —— 只看 app 自己的内存会得出完全错误的结论。
2. 同 dataStore、同源的多个 WKWebView **会不会共用一个 WebContent 进程**，正是决定
   「每宿主一份页面」到底是「再来一整份」还是「几乎不要钱」的关键。这条我不知道，只能量。

量法（app 跑着的时候执行，看进程数与总量）：

```bash
ps -Ao pid=,rss=,comm= | grep -E 'UniReader|WebKit\.(WebContent|Networking|GPU)' \
  | awk '{n=split($3,a,"/"); s+=$2; printf "%8.1f MB  pid %-6s %s\n", $2/1024, $1, a[n]} \
         END {printf "%8.1f MB  合计\n", s/1024}'
```

四个档位各量一次，差值才是结论：
① app 开着、AI 面板没开 → ② 开浮窗（一个 webview）→ ③ 切内置（另一个宿主）→
④ 开第二扇阅读窗口并在它的内置面板里也打开 → **看 WebContent 进程是变多了还是复用了**。

`ps` 的 RSS 会把共享页重复计入；要精确用 `footprint -p <pid>` 看 `phys_footprint`。

量完把数字填回这里，并据此重新决定 `maxLive`（现在是 3，也是拍的）。

## 11.8 划字发送 + 等页面就绪再投递（2026-09-06）

用户三条需求里的两条（第三条「DeepSeek 模式切换」见 §12 待办）。

### 划字发送（文本优先那条终于落地）

右键选区多一项「问 %@（选中文字）」（`ReaderSurface+Selection.askAIAboutSelection`）：
把 **`书名 · p.N · 章节` + 选中的原文** 填进输入框，同样**不自动按发送**——让用户自己补一句要问什么。

- 与框选截图是同一条链路的两半，投递入口 `AIPanelModel.attachText(_:)`（新增，只填字不带附件），
  适配器新增 `insert(text)`（复用既有 `insertText`，React 受控 textarea 的原生 setter 那套一字未改）。
- 上下文前缀 `aiContextPrefix(page:)` 从 snip 那边**抽出来共用**（原 `snipPrompt`），别抄第二份。
- 锚点 = 选区所在**最小页** + 该页行框并集；这条上下文若是本次对话第一条，它就决定绑定钉在哪
  （同「多张图用第一张」，`AIThread.addContext`）。
- 反馈复用 snip 的 toast（`showSnipToast` 改为非 private），两条投递路径的观感一致。

### 🔴 等页面就绪再投递（`AIPanelModel.waitUntilReady`）

用户报「首次打开 AI 窗口，填充扑空」。首次打开时三件事一件都还没发生：
① `present()` 只是把宿主亮出来，`AIPageBox` 是**宿主视图 `onAppear` 里才现建的**（这一刻
`current` 往往还是 nil）；② webview 建好还要拉首屏；③ 首屏拉完，主输入框还要等前端框架挂上来。
三种都是静默失败，而 toast 只会说一句「没能放进输入框」。

改法：投递前轮询（150ms）等 `current` 出现且适配器 `ready()`（＝脚本已注入 + `findEditor()` 有货），
上限 20s；等超过 1.2s 在面板上说一声「正在等 DeepSeek 加载…」。
**刻意不等 `isLoading` 转 false**——聊天站点首屏之后常年挂着长连接与懒加载，输入框早能用了，等它白等。
超时仍 best-effort 试一次（宁可试了失败也别把用户的图丢掉），但 `AttachOutcome.notReady` 会置位，
toast 改说「%@ 还没就绪（没加载完，或者没登录）」——**「页面没就绪」和「站点不收」是两回事**。

### 顺手修掉的丢数据

`noteSentContext` 的注释写着「还没 commit 时留在内存里，等 URL 出来一并落库」，
而实现是 `guard let boundThread else { return }` —— **直接丢**。新对话的第一条恰恰必然落在这个窗口里
（框选的第一张图、划字的第一段引文都赶在会话 URL 出现之前），丢了的后果是锚点规则失去依据、
选区回填笔记也拿不到 quote。现在攒进 `pendingContexts`，`syncFromPage` 建 `AIThread` 那一刻补记进去；
`beginBind`/`unbind`/`openThread` 各清一次（新绑定不继承旧的）。

### DeepSeek 模式（快速 / 专家 / 识图）

用户 2026-09-06 截图确认：**新对话页**输入框上方一条三段控件——「快速模式 / 专家模式 / 识图模式」
（输入框里那两枚「深度思考 / 智能搜索」是另一组开关，不归这里管）。
规则（用户定）：**有图 → 识图模式，无图 → 专家模式**；时机：**只在新建对话时切一次**。

- 配置进 `AIProvider`（`modes` + `mode_for_image` / `mode_for_text`），外部 `ai-providers.json` 可整份覆盖
  ——站点改文案时不必重编译。`AIMode.labels` 存的是**页面上的可见文字**，
  🔴 **不猜 class 名**（class 每周都在变；可见文字变了用户一眼看得出来）。
  内置只填**实际见过的中文**：英文界面的写法我没见过，猜一个塞进去反而可能在别处误匹配
  （"Pro" 这种短词到处都是）。
- 适配器 `setMode(labels)`：只认**整段可见文字完全相等**的元素，取最深那层点下去（事件照样冒泡到
  挂 onClick 的祖先）；已经在那一档就不重复点；**认不出就什么都不做**并如实返回 `found:false`。
- 🔴 **「只在新建对话时切一次」不靠我们记状态**：那条控件**只长在新对话页上**，聊起来站点自己就收走了
  ——找不到 = 不切，语义天然等价。也顺带避开「站点可能不允许对话中途换模型」这个未知数。
- 切不动**绝不挡住投递**（`applyMode` 的返回值只用于打点）：用户要的是那段文字/那张图先进输入框。
- 手动钉一档：`AIPanelModel.chatMode`（`auto` = 跟内容走），入口两处——浮窗工具栏的「更多」菜单、
  内置面板 header 的滑杆图标。⚠️ 与 `AIPanelModel.mode`（浮窗/内置的**面板形态**）是两回事，
  故一律带 `chat` 前缀。

自检页 `spike/ai-adapter-test.html` 补了模式条与三条用例（切档 / 已在那档不重复点 /
**认不出的标签绝不乱点**），连同 `ready()`、`insert()` 一起 **18 项全绿**（headless 实跑，非推演）。

### 🚧 待真机验证

1. 冷启动后**第一次**框选/划字发送：面板自己开起来 → 等一会儿 → 内容真的进了输入框（这条是本轮的主诉）
2. 没登录 DeepSeek 时发一次：应当明确说「还没就绪（没加载完，或者没登录）」，不是「没能放进输入框」
3. 划字发送后接着发第二段：应当**接着同一个对话**，不新开
4. 划字发送 → 在回答里选一段「添加到文字笔记」：笔记的 quote 应当是刚才发过去的那段原文（就是被修掉的那条丢数据）
5. **模式**：在新对话页框选发图 → 应当自动跳到「识图模式」；划字发文 → 自动跳到「专家模式」；
   在**已经聊起来的**对话里再发一次 → 页面上没有那条控件，应当**什么都不做**（不是报错、也不该乱点）；
   菜单里钉住某一档 → 之后一律用那一档。切不动时看 `UniReader-ws.log` 里那行 `[AI] 模式 …`。

## 12. 待办与未决

- [x] ~~DeepSeek 模式切换~~ —— 2026-09-06 落地，见 §11.8「DeepSeek 模式」。**真机待验**（§11.8 第 5 条）
- [ ] 首批 provider 清单最终确认（S1 内置八家，ChatGPT + DeepSeek 优先跑通 S3 适配器）
- [ ] `threadPattern` 各家会话 URL 正则**必须在 S2 逐条实测核对**（写错 = 绑定永远不 commit 的静默失效）
- [ ] `REQUIREMENTS.md §1.2` 的 kind=1 定义改写
- [ ] snip 快捷键 `s` 是否要同步进三端约定（安卓/web 端本版不做，暂不占位）
- [ ] 「暂存区」（未登录时截图先存哪儿）的形态
