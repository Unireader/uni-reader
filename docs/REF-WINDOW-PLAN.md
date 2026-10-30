# 参考窗（Reference Window）方案 — 各端

> 状态：**方案已定，未动代码**。
> 2026-08-26 首版（对照卡片模型）；**2026-08-30 用户收窄需求后大幅简化**（见 §2），
> 并按当时代码现状（schema v12 / 多标签页 / 画板模式 / 页图性能重做）重新核对了全部依赖点（见 §10）。

## 1. 需求

**用户原话（2026-08-26）**：「弹出一个小窗，用于显示某一个 pdf，作为参考，特别是比如习题和答案，
一般要么在同一个 pdf 的不同页，要么在另外一个 pdf，需要能够有个对照参考。**参考窗口不需要有一个 window 对应**。」

**用户收窄（2026-08-30）**：「核心就是能在各端打开一个小窗口，这个小窗口**仅作为 pdf 的显示**
（**默认是从 pdf 的进度打开**），小窗**没有任何附加功能**（没有笔迹等等）。」

于是这个功能的定义只有一句话：

> **一个浮在阅读区上的、只读的、可自由滚动的 PDF 显示窗，打开时定位到那本书的阅读进度。**

- 「不需要有一个 window 对应」已经替各端做了对齐：web 与安卓**根本没有窗口概念**，Mac 若走 `NSWindow`
  就是各端各做各的。呈现形态只有一种——**阅读区之上的覆盖层浮窗**。
  （Mac 上「再开一扇窗/一个标签看答案」本来就能做，用户明确不要，本方案不提供。）
- 「仅作为显示」= **只读**：不落笔、不擦除、不框选、不选文字、不做批注、不出选笔盘。
- 「默认从进度打开」= 定位来源是**库里已存的阅读进度**（`document.read_page` / `read_frac` / `read_zoom`），
  不是新造一套锚点。

## 2. 🔴 相对首版方案，砍掉了什么（别再捡回来）

首版设计过一套「参考卡片 = 锚点 → 目标」的对照模型（`ref_card` 表 + 4 条线格式消息 + 页面图钉 +
框选钉参考 + 页偏移映射）。**2026-08-30 全部砍掉**，理由是用户把需求收敛成了「就是个显示窗」：

| 砍掉的东西 | 为什么 |
|---|---|
| `ref_card` 表（schema +1） | 定位来源改成库里现成的阅读进度 → **schema 零改动** |
| `refs`/`refAdd`/`refDelete`/`refRename` 四条线格式消息 | 小窗开着没有、开的哪本、滚到哪，全是**本端私有视口状态**，没有跨端真源可言 → **线格式零改动** |
| 页面图钉、框选「钉为参考」、Inspector 参考列表 | 都是「附加功能」，用户明确排除 |
| 对焦矩形（打开时高亮那一块） | 同上；且能自由滚动之后，「只看那一块」不再是刚需 |
| v3 页偏移映射（`答案页 = 当前页 + offset`） | 想法仍然成立，但属于「对照系统」，不属于「显示窗」。**要做先重新提需求**，别捎带进来 |

**保留下来的核心判断**（首版里唯一没被推翻的部分）：小窗要的是主页流的一个**很小子集**——
没有笔迹、没有 hover、没有选笔盘、没有框选、不上报滚动锚点，真正贵的那几条硬指标
（零闪烁、锚定缩放、滚动跟随）大多用不上，所以各端都**不必复制主阅读区**。

## 3. 状态模型：一份也不落库、一个字节不上线

| 东西 | 落库 | 上线 | 存在哪 |
|---|---|---|---|
| 小窗开着没有 / 摆在哪 / 多大 | ❌ | ❌ | 本端记忆（Mac `UserDefaults` / web `localStorage` / 安卓 `SharedPreferences`）|
| 小窗里开的是哪本书 | ❌ | ❌ | 同上（记住上次那本，下次打开直接就是它）|
| 小窗内滚到哪、缩放多少 | ❌ | ❌ | 内存；**关闭再开 = 回到那本书的进度** |

🔴 **小窗只读进度，绝不写回**。它是「参考」不是「阅读」：写回去会污染那本书真正的阅读进度，
而且那本书若同时在主视图/另一个标签里开着，两边就会互相盖（同「视口不上线」那条纪律的同源理由）。

一个直接的好处：**这个功能不碰 `PROTOCOL.md`，也不碰 schema**，因此不需要跨端字节向量，
各端可以完全并行做、先后上线互不影响。

## 4. 跨文档取图：两个 HTTP 端点，不进线格式

「打开另一本 PDF」在新需求里是**主线场景**（同一本书的话，「从进度打开」就等于当前位置）。
Mac 本机直接持第二份 `PDFDocument` 即可；**web / 安卓模式2 需要服务端支持**，现状是
`/page.png` 只认当前文档（`pageProvider` → `AppModel.renderPage` 用的是单份 `padRenderPDF`）。

增量只有两处，**都走 HTTP、不进线格式**：

| 端点 | 内容 |
|---|---|
| `GET /page.png?d=<libDocId>&i=N&w=…` | `d=` 缺省 = 当前文档（**旧客户端字节不变**）；带 `d=` 则从「参考文档渲染实例」取 |
| `GET /docmeta?d=<libDocId>` | JSON：`{title, pageCount, pages:[[w,h],…], readPage, readFrac}` —— 小窗要的页尺寸表与初始定位 |

🔴 **为什么不走线格式**：`/info` 已有先例——「加一个字段就要三端同步 + 重出字节向量，而这只是
展示用的数据」。参考窗是**纯客户端的只读显示**，没有推送需求（选哪本书是用户当场点的），
为它往 `PROTOCOL.md` 里塞一条带大数组的消息（页尺寸表）性价比极低。

客户端选哪本书：**复用现成的 `library`(0x3B) 全量镜像**（工作区里有哪些文档 + 标题 + 已打开标记），
一条新消息都不用加。

### Mac 侧实现的三条红线（都是踩过的账）

1. 🔴 **参考文档必须是独立的 `PDFDocument` 实例，且只能被一条队列碰**。现有三条管线各自持有独立实例
   （阅读区 `PageRenderEngine` 串行队列 / 平板页图 `LANServer` 服务 queue / OCR `ocrRenderQueue`），
   共用同一个文档对象 = 两个后台队列并发操作同一份 PDFKit 内部状态，2026-07-27 实测表现为
   **Mac 阅读区整片白屏、须手动翻页才恢复**。于是参考窗要**两份**：Mac 本机小窗那份归渲染队列，
   `/page.png?d=` 那份归服务 queue。
2. 🔴 **进 teardown**：这是「一直开着的文件」。2026-08-05 用户报过工作区在移动硬盘上关窗后弹不出去，
   根因就是漏了 `AppModel` 持有的那第三份 PDF。参考文档实例（两份）必须挂进关标签/关窗/关工作区的
   显式释放链路，小窗一关就放。
3. 🔴 **id → 路径的解析在主线程做**。`WorkspaceManager` 是 `@MainActor` 而 `AppModel` 不是，
   服务 queue 上按 `libDocId` 反查文件路径会撞 actor 隔离——照既有办法办：
   在 `syncWorkspaceSnapshot` 注入快照时**把解析好的 URL 一并带上**（`libraryDocs` 现在只有
   id/title/open，没有路径）。

## 5. 各端落地

**共同点**：小窗内是**连续页流**（可自由上下滚动 + 捏合/滚轮缩放，页宽 fit 小窗宽），
布局数学与主阅读区同源（fit-width 连续布局、页间 gap、锚点 = 页 + 页内 frac）。

| 端 | 复用什么 | 新写什么 |
|---|---|---|
| **macOS** | `PageLayout`（**纯数学**，`init(doc:)` 只读页尺寸、零 `DocSession` 依赖，现状已复核）+ `PageRenderEngine`（含新的 base/tile 双缓存与 `purge(doc:)`）| `ScrollView`+`LazyVStack` 的只读页流 + 一个极简 cell（只画 image）。🔴 **完全不碰 `ReaderSurface`** |
| **web** | `/page.png` 取图路径 | 一个独立的只读小渲染器（连续 y 布局 + 按需 `<img>` + 滚动/捏合，约百来行）。🔴 **不参数化全局 `G`**——`render.ts` 全线挂在那个单例上（`dispH`/`offY`/`scrollY`/`imgs` 都在 G），改它风险远大于另写一个子集 |
| **安卓** | `shared/PageCanvasView`（本就是「几何+输入+渲染，**不含提交给谁**」）+ `PageImageSource` 注入口 + `shared/PageDiskCache` | 一个只读子类（`onInk*`/`onErase*`/`onLasso*` 默认就是空实现，直接继承即可）+ 第二个 image source。**各端里最省的一端** |

### macOS
- 🔴 **挂载点 = `ContentView.readerColumn`**（与 `tabBar`、`AIInlineLayer` 同层），两条理由与那两位完全一致，
  代码注释里已经写死：① **身份要稳定**——不能落进 `PageStreamView` 内部 `.id(docKey)` 的下游，
  否则每换一次标签整个小窗跟着重建（闪一下，违反零闪烁纪律）；② **要挡得住阅读区手势**——
  那四个拖拽手势挂在 `ScrollView` 容器上，同视图 `.overlay` 挡不住（草稿纸就是为此才要在每个
  gesture 里写门控），挂到上一层就是普通遮挡关系，一行门控都不用加。
- 🔴 **一扇窗口一份，按 `windowID` 而不是会话 id 分**（同 AI 内置面板的拍板）：Mac 已改多标签页
  （`一个标签 = 从前的一个窗口`），按会话分的话**切标签就是换宿主**，小窗会被重建；
  按窗口分则「切到另一个标签，参考窗还在旁边摆着」——正是对照场景要的。
- 🔴 **独立 client id 声明 `setWanted`**（如 `"ref-<windowID>"`）：`PageRenderEngine` 会把
  入队超 1s 且无人认领的请求直接丢弃，不声明就是「完成回调永不触发、小窗永远停在占位图」。
- 入口：工具栏一枚按钮（开/关）+ 小窗顶部的文档选择器（列 `library` 那份工作区文档表）。
- 草稿纸（画板覆盖层）开着时不显示小窗——同标签栏的既有处理，避免三层浮层打架。

### web（采集页）
- 浮窗做成绝对定位 DOM 面板（内含 `<img>` 序列或一个小 canvas），z-index 置于 `#scratch`(7) 之上、
  `#topbar`(10) 之下。
- 🔴 面板必须 `touch-action:none` 且吞掉 pointer 事件，否则**笔在小窗上会穿透到 `#ink` 落墨**。
- 🔴 样式一律写进 `web/src/app.css`，组件内不写 `<style>`（Svelte 5 对带 `class:` 指令的元素会漏掉
  作用域类，PadBar 整块样式失效那次的教训）。

### 安卓（两模式共用）
- 覆盖层加在 chrome **之下**以让开顶栏（§7.1 白压白坑）；返回键优先关小窗。
- 取图直接复用 `shared/PageImageSource`：模式1 = `local/PdfSource`（本机 Pdfium，参考另一本书 =
  第二个 Pdfium 实例）、模式2 = `pad/PageFetcher`（HTTP，加 `d=` 参数）。**两模式零分叉**。
- 内存：模式1 现有约束是「标签页 LRU 只保活 3 篇 + 背景页 Pdfium 缓存 32MB」。参考窗**只保活
  视口 ±1 页的位图**，宽度按小窗尺度取（见 §6），小窗关闭即释放 Pdfium 实例。
- 🔴 笔落在小窗上不能画：`PageCanvasView` 的触摸分发要在小窗矩形内直接拦下（同图钉命中的处理方式）。

## 6. 浮窗规格（各端统一）

- 默认尺寸：短边的 ~40%，Mac 不小于 320pt；默认右下，可拖到任意角，本端记忆。
- 内容：连续页流，自由上下滚动；捏合/滚轮缩放 1~6x；页宽 fit 到小窗宽。
- 顶部一条极简控制：**换书（书本图标）· 目录 · 文档名 · 页码 n/N · 回到进度 · 折叠 · 关闭**。
  Mac 额外一枚「主视图跳到该页」。
  🔴 **文档名是拖拽把手，不是控件**（用户 2026-09-02）：它最初整块是「换书」菜单的 label，
  于是标题栏最顺手的那一片全被菜单吃掉、窗口拖不动（系统窗口的标题从来都是拖拽把手）。
  换书收进左边一枚图标，标题退回纯文本。
- **目录跳转**（用户 2026-09-02「参考小窗支持 toc 跳转」）：对照习题/答案时按章节翻比拖滚动条实在。
  仍不破「只读」——跳转只动小窗自己的视口，**不写回那本书的阅读进度**（§3 红线）。
  Mac 侧复用 `TOCEntry.build` + `TOCListView`（都与 `DocSession` 零耦合），跳转复用既有的
  `seedRev` 定位通路，不另写一套 scrollTo。
- 可折叠成一枚小图钉（同 `AIInlineLayer` 的 bubble 形态），不占版面又不丢上下文。
- 视口记忆分两级：**折叠→展开保持**滚动位置；**关闭→重开回到那本书的进度**。
- **只读**：不落笔、不选文字、不出选笔盘、不做批注。

### 档位公式（各端同一个，否则同一本书各端清晰度不一样）

```
wantPx = 小窗内容区宽度(px) × 当前缩放
```
再按 `LANServer.pageWidthSteps = [480,720,1080,1440,2160,2880]` 向上 snap
（安卓 `shared/PageWidths.kt` 是同一张阶梯）。**小窗物理宽度本来就小 → 天然落在低档位**，
这是渲染预算能控住的根本原因。夜间反色**跟随阅读区**（与草稿纸底图相反：小窗里就是在看 PDF 内容）。

## 7. 渲染预算与队列争用

小窗能滚 = 会连续请求一串页图，而它与主阅读区**共用同一条串行渲染队列**
（`PDFDocument` 不能并发）。快滚小窗时挤占正文渲染，表现就是「拖着参考窗滚，正文那边糊着回不来」。
四条对策，写死在实现里：

1. **档位天然低**（§6）：小窗宽常只有主视图的 1/3 → 多落在 480/720 档，单张成本比正文小一个量级。
2. 🔴 **实化窗口「只扩不缩 + 上界」**：2026-08-29 主阅读区刚踩过——无上界会让实化窗口在缩小时
   累积膨胀到 74 页、每帧构建约 26ms；而彻底去掉「只扩不缩」则页元胞反复销毁重建 = 闪烁。
   小窗照同一条纪律：**上界取「视口窗口 + 2 页」**（小窗比正文窗口小，不需要 +8）。
3. **独立 client id 声明 `setWanted`**（见 §5）：滚动中的过期请求出队即弃，停下再 settle 高清。
4. **内存**：只保活视口 ±1 页；小窗关闭即释放位图与 PDF 实例。按 `PageRenderEngine.cost(of:)`
   的真实份数口径记账（2026-08-29 vmmap 实测重定过），别再按「一张图一份」估。

**跨端这边反而变便宜了**：2026-08-29 新增的 `PageDiskCache`（编码后字节落 `Caches/`，键含内容哈希，
跨换文档/关窗/重启都在）意味着**参考那本书只要在这台 Mac 上渲过一次，之后的小窗取图基本不用再渲**；
安卓端 `shared/PageDiskCache` 同理。

## 8. 分期

| 期 | 内容 |
|---|---|
| **v1** | 各端只读可滚动浮窗 + 「从进度打开」+ 换书（当前文档 / 工作区任意文档）+ 两个 HTTP 端点 |
| **v2（要重新提需求，别捎带）** | 若日后仍想要「习题↔答案」的**固定对照关系**（图钉、页偏移映射），那是另一个功能，回头单独立项——见 §2 被砍清单 |

## 9. 验证清单

- 无 schema、无线格式改动 → **不需要跨端字节向量**；`wire-codec-test` / `wire-cross-test` 只做回归。
- `xcodebuild` / `tsc --noEmit` / `svelte-check` / `vite build` / `assembleDebug`。
- HTTP：`/docmeta?d=` 与 `/page.png?d=` 的 404/越界/`d=` 缺省兼容（不带 `d=` 必须与今天字节一致）。
- 🔴 **手感与观感一律由用户在真机上测**：小窗默认大小、拖动阻尼、滚动手感、
  **小窗快滚时正文渲染有没有被挤**（§7 是新引入的风险，只能真机验）、平板上笔会不会误触小窗。
  结论攒进 `ANDROID-STANDALONE-PLAN.md §11.1`。

## 10. 与代码现状的核对（2026-08-30）

首版方案写于 8-26，其后代码有较多改动（多标签页 / 画板模式 / 页图性能重做）。逐条复核结果：

| 首版方案里的假设 | 现状 | 处置 |
|---|---|---|
| schema `v11 → v12` 建 `ref_card` | **已是 v12**（画板模式用掉了） | 需求收窄后**整张表都不要了**，冲突自然消失 |
| 新增 opcode `0x4B refAdd` / `0x4C refDelete` | **`0x4B` = `canvas`（双向）、`0x4C` = `strokesAppend`**，已占 | 同上，四条消息全砍。将来若真要同步参考条目，空位从 `0x4D`/`0x4E`/`0x4F`/`0x51` 起 |
| 浮窗挂「`PageStreamView` 那一层」 | 准确挂载点是 **`ContentView.readerColumn`**（`tabBar`/`AIInlineLayer` 都在这儿，注释已写死两条理由） | 措辞已更新，结论不变 |
| 宿主 = 每扇窗口一份 | Mac 已改**多标签页**；AI 面板刻意按 `windowID` 而非会话 id 分宿主 | 结论不变且更有依据：参考窗同按 `windowID` |
| 独立 client id 声明 `setWanted` | `setWanted` 仍在；缓存已拆 base/tile 两个 store + `copiesPerImage` 真实份数计费 + 内存压力钩子 | 成立；内存估算改用新口径 |
| 「预取 ±1 页」 | 主阅读区 8-29 刚修过**实化窗口爆炸** | 补上「只扩不缩 + 上界」纪律（§7.2）|
| 渲染预算 | 新增 `PageDiskCache`；页图改 BGRX/mmap，内存 1604MB→275MB | §7 重写：跨端取图比首版估计便宜得多 |
| `/page.png` 加 `d=` | 仍只认 `padRenderPDF`（当前文档），无 `d=` | 确认要加；且新需求下它从 v2 提到 **v1 必需** |
| `PageLayout` 可直接复用 | 仍是纯数学（`init(doc:)` 只读页尺寸） | 成立 |
| `PageImageSource` / `PageCanvasView` 可直接复用 | 接口未变；`shared/` 另新增了 `PageDiskCache`/`CanvasMargin` 等 | 成立，且多一层磁盘缓存可蹭 |

## 11. 实现记录 — macOS 端（2026-08-30 落地，待真机验证）

| 文件 | 职责 |
|---|---|
| `Sources/App/RefWindowModel.swift` | 状态与文档持有：开/关/换书/回到进度、独立 `PDFDocument`、浮窗几何与视口记忆 |
| `Sources/Views/RefWindowView.swift` | 浮窗壳：标题栏（选书/页码/回到进度/在主视图显示这一页/折叠/关闭）、拖动、左上角尺寸手柄、折叠气泡 |
| `Sources/Views/RefPageStream.swift` | 只读连续页流：精确虚拟化 + `PageRenderEngine` 出图 + 捏合缩放 + 定位到进度 |
| `ContentView` | 工具栏开关一枚；`readerColumn` 第三层 overlay；`onDisappear` 里 `refWindow.close()` |
| `WorkspaceManager.refDocIndex()` | **纯查询**的 id → 路径/哈希/标题/进度（不像 `openTarget` 会写库） |
| `AppModel` + `LANServer` | `/page.png?d=` 与 `/docmeta?d=`；参考文档的第二份渲染实例 + 索引注入 |

落地时定的几件事（都在代码注释里留了理由）：

- **视口记忆放在 model 而不是页流的 `@State`**：折叠成气泡时面板整个离开视图树、`@State` 全归零，
  记在页流里就会把「折叠→展开」也当成首次打开重新定位到进度，两级语义就没了。
  三个字段（`viewDocY`/`viewZoom`/`seededRev`）**都不是 `@Published`**——滚动每帧都写 `viewDocY`，
  发布出去等于每帧重算整个浮窗视图树（同 `DocSession.readHFrac` 被排除在 @Published 之外的理由）。
- 🔴 **换书那一帧的越界防御**：`layout` 当帧就是新书的，而 `realized` 要等 `onChange(of: docKey)`
  才归零——两者不同步的那一帧里旧页号会去索引新书的 `heights[i]`，页数变少就是数组越界崩溃。
  页流里 `clampedRealized(_:)` 就是为这一帧存在的。
- **档位化像素宽是必须的**（`LANServer.snapPageWidth`，与平板同一张阶梯）：不 snap 的话捏合每停一档
  就产生一整套新键的页图（主阅读区 2026-08-29 实测 ⌘+ ×5 涨 723MB，堆的就是这批图）。
- **换书刻意不 `purge(doc:)`**：参考的若正是主视图那本，purge 会把阅读区的页图一并清掉；
  交给 LRU 自然淘汰，反复开关小窗还能直接命中。
- **参考索引的注入点是 `broadcastLibrary` 而不是 `push()`**：后者要求当前标签已经打开了 PDF，
  而参考窗恰恰可以在空标签上看别的书。
- 两份独立 `PDFDocument` 都进了释放链路：小窗那份在 `ContentView.onDisappear`（`refWindow.close()`），
  服务 queue 那份在 `releasePadRenderIfUnused()` 里连带 `releaseRefRender()`。

验证：`xcodebuild` 通过；`store-test`(38)／`ink-store-test`(21)／`scratch-store-test`(53)／
`wire-codec-test`(90) 全绿，且 `spike/wire-vectors-swift.txt` **零变化**——线格式确实一个字节没动。

### 11.1 首轮真机反馈与修复（2026-08-30）

用户实测报了 6 条（第 3 条是正面：「两个位置切换按钮功能很好」，指「回到进度」与「在主视图显示这一页」）。
其余 5 条里有 3 条**同源**——我把 `onScrollGeometryChange` 的回报当成了真源，而它**慢半拍、且带亚像素抖动**。

| 反馈 | 根因 | 修法 |
|---|---|---|
| 缩放没有用光标位置 | `applyZoom` 锚的是**视口中心** | 锚到捏合点 `MagnifyGesture.Value.startAnchor`（纵向按文档单位、横向按内容宽比例各锚一次）|
| 左上角缩放图标与书本图标重叠 | 手柄画成了一枚左上角图标，正压在 header 的文档选择器上 | 删掉图标，改成**左边缘 / 上边缘 / 左上角三条透明热区**（厚 5pt < header 的 8pt 内边距，压不到里面的控件），靠 `pointerStyle` 提示——系统窗口本来就是「边缘可拖、不画东西」|
| 折叠再打开滚动位置丢失 | ScrollView 重建后的**第一条几何回报必然是 `offsetY = 0`**，那一下把 `viewDocY` 记忆抹平了；之后才轮到恢复逻辑去读它 | 加 `scratch.positioned`：**初始定位完成之前，几何回报一律不许改写记忆** |
| 缩放会导致进度跑偏 | 缩放期间回报的是「旧偏移 × 新 scale」，拿它反推 docY 必然错，一路累积 | 加 `scratch.zooming`：捏合期间记忆由 `applyZoom` 按锚点自己维护；松手后**延迟 0.12s 才解冻**（等回报追上，否则第一条回来的仍是旧值）|
| 拖拽小窗时内容上下抖动 | 两条：① 拖动每帧写 `@Published offset` → 页流（`@ObservedObject`）整体重算；② `.offset` 拖动时容器宽有亚像素抖动，而 `页 y = offsets[i] × dispScale`，`offsets[i]` 动辄上万，scale 抖 0.0005 就是屏幕上好几像素 | ① 拖动/改尺寸**期间只动视图本地的 delta**，松手才写回 model（夹取规则抽成 `static clampOffset/clampSize`）；② **容器宽高量化到整点** |

顺带补上的一条：**改小窗尺寸时保持文档位置**（页宽跟着容器宽变，不补偿就越拖越偏）——
`geometryChanged` 里检测到容器宽变化就按记忆的 `viewDocY` 重新对位。

🔴 **这一轮的通用教训**：`onScrollGeometryChange` 的回报只可用来**驱动渲染**（实化窗口、出图、页码），
**不可用作位置真源**。凡是「我刚提交了一个 scrollTo」或「视图刚重建」的时刻，回报都是错的。
主阅读区 2026-08-29 修 `verifyPendingTarget` 自激时踩的是同一条，只是那边表现为掉帧、这边表现为位置漂移。

**二轮（同日）**：用户报「缩放时不跳，**松手后**位置跳变」。根因是逐帧 `scrollTo` **没有包
`withTransaction { animation = nil }`** —— 每帧各起一段隐式动画，手势期间被后一帧不断覆盖所以看着跟手，
松手后那些还在跑的动画继续落定，就是那一下跳。连带把锚点也改成主阅读区那套**账本式**的：
起手记下屏幕不动点 `viewportP` 与它对应的内容坐标 `cCur`，每次提交就地 `cCur *= r`，
**只认自己刚提交的目标（`pendingTarget`），不问几何回报**；另加 ~60Hz 限流与「陈旧回报识别」
（刚提交过 scrollTo 时回报若没追上目标就不拿它写记忆，0.4s 超时认输）。

🔴 **合并成一条纪律**：凡是逐帧改布局 + `scrollTo` 的地方，
**必须 `withTransaction(animation = nil)` 原子提交，且锚点只信自己刚提交的目标**。
主阅读区 `ReaderSurface+Zoom.commitZoom` 是这条的参考实现，新写滚动容器时照抄它，别重新发明。

### 11.2 摆位越界与 ⌘+滚轮缩放（2026-09-06，Mac）

| 反馈 | 根因 | 修法 |
|---|---|---|
| 小窗标题栏跑到系统标题栏底下，**拖不动了** | 摆位/尺寸是本端记忆（`UserDefaults`），而**夹取只发生在拖动/改尺寸的手势里**：容器一变小（缩窗口、开侧栏/Inspector、退出全屏、上次那扇窗更大）就再没人夹。`.offset` 又**不裁剪**，越界那截正好画在工具栏玻璃底下——鼠标点不到（事件归工具栏），于是「拖不动」 | `RefWindowView` 新增 `fitSize`/`fitOffset`（纯函数，**在 body 里算**，第一帧就是夹过的）+ `fitIntoContainer`（`onAppear` / 容器变化 / 打开那一刻写回状态与记忆）。面板、气泡、拖动手势一律走夹过的那份 |
| 小窗缺 ⌘+滚轮缩放（方案 §7 本来就写了「捏合/滚轮缩放」） | 只做了 `MagnifyGesture` | `RefPageStream` 装 `NSEvent` 本地滚轮监视器（**纯事件管道，不引 AppKit 视图**），照抄主阅读区 `ReaderSurface+Zoom` 那套：`exp(-delta*0.008)` 夹在 0.5~2、光标为锚、有级滚轮 ×10。锚点走 `onContinuousHover` 记的 `scratch.cursorP`——**它同时是「这一下归不归我」的判据**：光标不在小窗里就 `return event` 原样放行，主阅读区那个监视器照旧拿得到 |

复用而非另写：一次滚轮 = 一次性的 `RefPinch` 账本 → 仍走 `commitZoom`，
于是「锚点不动 / 禁隐式动画 / 记忆同步」与捏合完全同一条路径（同主阅读区 `zoomCommit` 的做法）。

### 11.3 独立窗口形态（2026-09-11，Mac，待真机验证）

用户：「参考小窗支持独立小窗口（类似 AI 窗口那样）」。§1 那句「参考窗口不需要有一个 window 对应」
说的是**不强制**要窗口（web / 安卓没有窗口概念），不是禁止 Mac 提供；Mac 上现在两种形态都有，
默认仍是覆盖层。

| 件 | 做法 |
|---|---|
| 形态 | `RefWindowModel.mode`（`overlay` / `window`），偏好全 app 一份（`UserDefaults` `refWindowMode`，同 `aiPanelMode`）；每扇阅读窗的 model 各持内存值，**只在从关闭状态打开时对齐偏好**——在这扇窗口弹出去，不会把另一扇正开着的覆盖层也拽出去 |
| 入口 | 覆盖层顶栏「弹出为独立窗口」（`macwindow`，同 AI 内置面板那枚）↔ 独立窗口工具栏「改为窗口内置」。两边都**只改 model**，窗口开合由 `ReaderWindowController` 一条 `CombineLatest($isOpen, $mode)` 订阅统一推——工具栏开关、红色关闭钮、⌘W 也都汇到 model |
| 窗口 | `RefWindowController`（`Sources/Window/`，一扇阅读窗一份，关掉即销毁，位置/尺寸靠 frame autosave `RefWindow`）。**阅读窗的子窗口**（`addChildWindow`，同 `AIPanelDock` 的机制但不贴边不定位）：恒在阅读窗之上（点回正文不会沉下去——对照场景要的正是这一点）、跟着阅读窗走、随它最小化；`.fullScreenAuxiliary` 让它能进全屏 space。首次弹出落在阅读窗右下角内侧、用覆盖层记着的尺寸 |
| 工具栏 | `NSToolbar` + `.unifiedCompact`、标题可见（文档名，副标题 = 页码 n / N）：选书（`NSMenuToolbarItem`）· 目录（带 view 的按钮 + `NSPopover`，内容与覆盖层**同一个** `RefTOCPopoverContent`）· 回到进度 · 在主视图显示这一页 · 改为窗口内置。没有「折叠」「关闭」（系统标题栏自带） |
| 内容 | `RefDetachedContent` = 一个 `RefPageStream(host: .window)`，与覆盖层同一份页流，一行不差 |
| 切换 | 视口记忆本来就在 model（§11 第一条），切换形态 = 旧页流 `onDisappear`、新页流 `onAppear` 走「折叠→展开」那条恢复路径：滚动位置与缩放原样接上 |

两条坑（都是切换形态时「新旧两个页流短暂并存」引出的）：

1. 🔴 **渲染认领 id 按页流实例分，不按 model 分**（`RefScratch.clientID`，原来是 `RefWindowModel.clientID`）：
   旧页流的 `onDisappear`（SwiftUI 提交）与新页流的 `onAppear`（AppKit 上屏）谁先谁后没有保证，
   共用一个 id 的话旧的收尾会把新的认领一并清空——引擎把入队超 1s 无人认领的请求直接丢弃，
   表现是新窗口停在占位图、滚一下才出图。登记表改成 `renderClients[clientID] = (host, cleanup)`
   （同 `DocSession.renderClients` 的形状）。
2. 🔴 **独立窗口关掉时只交自己那份认领**（`releaseViews(host: .window)`）：AppKit 直接销毁 hosting 视图，
   页流的 `onDisappear` 来不来没保证，所以 controller 的 `dismiss()` 要替它交；但切回覆盖层那一刻
   覆盖层的页流多半已经登记进来了，一锅端会把它的滚轮监视器与 wanted 一起没收（⌘+滚轮从此失灵，
   `installWheelMonitor` 只在 `onAppear` 跑一次，没有第二次机会）。`model.close()` 才是全清。
3. 🔴 **`windowWillClose` 要分辨「程序关的」还是「用户关的」**（首轮真机就报了：点「改为窗口内置」
   窗口消失、覆盖层没出来、工具栏开关灭了）：切回覆盖层时 model 仍是开着的（只是形态变了），
   `dismiss()` 关窗照样触发 `windowWillClose`，那里若一律按「用户点了红色关闭钮」处理就会顺手
   `model.close()`。加一个 `dismissing` 标记，由 `dismiss()` 关的不走 `model.close()`。

顺带：`currentPage` 从覆盖层壳视图的 `@State` 挪进 model（独立窗口的 AppKit 标题栏也要显示它）；
只在页号真变了才写，不是逐帧发布。

🔴 待真机验（同 §9 口径，由用户测）：子窗口在阅读窗全屏时会不会跟进 space、首次弹出的落点、
紧凑工具栏里标题 + 页码 + 五枚按钮在小窗宽度下的排法、⌘+滚轮在两种形态间切换后是否都还好使。

## 12. 实现记录 — web 采集页与安卓两模式（2026-08-30 落地，待真机验证）

### web（`web/src/RefWindow.svelte`）

- 面板是**绝对定位的 DOM**，z-index 置于 `#scratch`(7) 之上、`#topbar`(10) 之下；
  事件绑在 `ink` canvas 上（不是 window），所以 DOM 浮层天然不会触发落墨——一行门控都不用写。
- 滚动交给浏览器原生（`touch-action: pan-y`，惯性免费），**双指捏合自己接管**（`preventDefault`）。
- 🔴 **位置真源用 `(page, frac)` 而不是像素**：页宽一变像素全变，而 (page, frac) 天然守恒，
  于是缩放与改尺寸都不必写补偿计算——Mac 端在这上面栽过两轮（见 §11.1）。
- 取图 `/page.png?d=&i=&w=`，**档位只在停手 180ms 后才换**：捏合中途换 `src` 会让每张图重新加载、白一下。
- 状态整组挂在 `S`（`hud.svelte.ts`），位置/尺寸/看的哪本存 `localStorage`。
  🔴 样式一律在 `app.css`（Svelte 5 对带 `class:` 的元素会漏作用域类，PadBar 那次教训）。

### 安卓（`shared/RefWindow.kt`，两模式共用）

- **直接复用 `PageCanvasView`**，只读靠两件事：① 固定在 `MODE_PAGE`（笔只翻页、不落墨）；
  ② **不覆写任何提交钩子**——它们默认就是空实现，于是「提交给谁」在参考窗里根本不存在。
  唯一覆写的是 `onScrollReport`（标题栏页码）。这是各端里最省的一端，与方案 §5 的判断一致。
- **改尺寸时保持文档位置是白拿的**：`PageCanvasView.onSizeChanged` 本来就会「宽度一变就按
  页+页内比例锚回原处」（转屏那条老账），正是 Mac 端手写的那套。
- 差异全在 `Host` 三个方法：
  · 模式1 → 工作区书库 + 库里的 `read_page/read_frac` + **第二个 `PdfSource`**（换书/关窗当场 `close()`，
    别把文件吊着）；
  · 模式2 → `library` 镜像 + `GET /docmeta?d=` + `PageFetcher.fetch(..., docId)`。
- `PageFetcher` 加 `docId`：**缓存键与磁盘键都带上它**，否则参考窗与正文的同页号会互相顶掉；
  空串时键格式一字未变（老缓存不作废）。

验证：`xcodebuild` / `vite build`（a11y 零警告）/ `assembleDebug` / 安卓 `test` 全绿；
`capture.html` 已按 `build-web.sh` 的占位符自检回写（三项齐全）。
**手感与观感一律真机验**：小窗默认大小、拖动与捏合手感、笔会不会误触小窗、模式1 第二个 Pdfium 的内存。

### 12.1 安卓模式2 首轮真机反馈与修复（2026-08-30）

| 反馈 | 根因 | 修法 |
|---|---|---|
| 第一次打开小窗一片空白，换一次书就再没复现 | `open()` 只认 `SharedPreferences` 里记着的那本，**首次没有记忆就什么都不加载**（web 端做了兜底，安卓这份漏了） | `Host` 加 `refDefaultDoc()`：模式2 取 Mac 当前开着的那本、模式1 取当前标签那本 |
| 小窗没有阴影，边界难分辨 | 面板只有 `setBackgroundColor` 一块纯色矩形，压在 PDF 上糊成一片（Mac 是 material+描边+投影、web 是 border+box-shadow，只有安卓漏了） | 圆角 + 描边 + `elevation` 投影 + `clipToOutline` |
| 标题栏能拖的地方很少，文档名处拖不动 | 文档名有自己的点击监听、把触摸吃掉了，可拖的只剩按钮之间那点空隙 | 标题栏改成 `DragBar`：**按下先放给子 View，移动超过 touch slop 才接管**（子 View 收到 CANCEL，点击不触发）→ 点标题=选书、按住标题拖=移窗口 |

🔴 第三条 **web 端是一模一样的毛病**（按钮上 `stopPropagation` + `preventDefault` 把可拖区域切碎），
同轮一起改成阈值判定 + 拖过抑制那一次 click；监听挂 `window` 而不是 `setPointerCapture`——
捕获会打乱子按钮的 click 判定。

**教训**：「浮窗标题栏」这种既要点又要拖的控件，三端都得走同一条路子——
**按下不抢、超过阈值才接管**。哪一端图省事直接在子控件上拦事件，那一端的标题栏就废掉一半。
