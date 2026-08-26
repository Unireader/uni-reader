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
- **内存**：每个 webview 100~300MB → 懒创建、面板关掉就释放、同时最多存活 N 个
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

## 12. 待办与未决

- [ ] 首批 provider 清单最终确认（S1 内置八家，ChatGPT + DeepSeek 优先跑通 S3 适配器）
- [ ] `threadPattern` 各家会话 URL 正则**必须在 S2 逐条实测核对**（写错 = 绑定永远不 commit 的静默失效）
- [ ] `REQUIREMENTS.md §1.2` 的 kind=1 定义改写
- [ ] snip 快捷键 `s` 是否要同步进三端约定（安卓/web 端本版不做，暂不占位）
- [ ] 「暂存区」（未登录时截图先存哪儿）的形态
