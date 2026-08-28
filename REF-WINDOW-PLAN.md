# 参考窗（Reference Card）方案 — 三端

> 状态：**方案已定，未动代码**（2026-08-26 与用户确认三条：落库+跨端同步条目 / 同文档「整页+页内区域」/ 三端统一浮动小窗）。
> 契约相关改动同时要落到 `PROTOCOL.md`（线格式唯一真源）与 `REQUIREMENTS.md §1.9`。

## 1. 需求

**用户原话**：「弹出一个小窗，用于显示某一个 pdf，作为参考，特别是比如习题和答案，一般要么在同一个 pdf 的
不同页，要么在另外一个 pdf，需要能够有个对照参考。参考窗口不需要有一个 window 对应。」

「不需要有一个 window 对应」这句直接把三端对齐了：web 与安卓**根本没有窗口概念**，Mac 若走 `NSWindow`
就是三端各做各的。所以呈现形态只有一种——**阅读区之上的覆盖层浮窗**。
（Mac 上「再开一扇窗看答案」本来就能做——库里 `openDoc` 就是新开窗口——用户明确不要，本方案不提供。）

## 2. 模型：参考卡片 = 锚点 → 目标

一张参考卡片记的是一条**对照关系**，不是一个临时窗口：

```
锚点 anchor   (可选)  = (页, 页内归一化 nx, ny)   ← 习题在哪儿，页面上留一枚图钉
目标 target           = (页, 可选页内归一化矩形)   ← 答案在哪儿，小窗里显示的就是它
```

- **锚点**让「翻到习题页 → 看到图钉 → 点开答案」成立，机制与草稿纸图钉完全同款（画法、手指单击开、
  可拖动）。没有锚点的卡片只在列表里出现。
- **目标是「打开时定位到哪儿」，不是内容边界。**小窗里装的是一条**可自由滚动的连续页流**
  （用户 2026-08-26：「一般也不是固定一页哦」）——答案跨页是常态，往下滚就是了。
- 🔴 **矩形不裁剪内容，只做打开那一刻的对焦**：把这块摆到小窗中央、并据此定初始缩放，
  再淡淡高亮一下（~1s 淡出）。所以「框选跨页」也不必进数据模型（`PageSnip.Region` 的跨页拼接
  仍只服务 AI 截图那条路），取 `startPage` 那一段当对焦框即可，剩下的用户自己滚。
- 语义与草稿纸完全对齐：**「打开 = 回到当初记下的那一处」**，之后的视口是本端自己的事。

### 同步的边界（照抄草稿纸那条纪律）

| 东西 | 落库 | 上线 | 理由 |
|---|---|---|---|
| 卡片列表（锚点/目标/标题/顺序） | ✅ | ✅ 全量镜像 | 「这本习题册的答案在第 210 页」是稳定知识，值得存一次、三端复用 |
| 小窗开着没有 / 摆在哪 / 多大 / 内部缩放翻到第几页 | ❌ | ❌ | 视口纪律。**各端私有本端记忆**（Mac `UserDefaults` / web `localStorage` / 安卓 `SharedPreferences`）|

🔴 **「开着哪张」刻意不做成全局真源**——这一点与草稿纸不同。草稿纸的 `open` 必须唯一，是因为
「这一笔落到哪张纸上」需要唯一裁决者；参考窗**只读**，没有这个约束。我在 Mac 上开着答案，
不该强迫平板也弹一个。

## 3. 存储（schema v11 → v12）

```sql
CREATE TABLE IF NOT EXISTS ref_card (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES document(id) ON DELETE CASCADE,  -- 宿主文档（图钉画在它上面）
  title TEXT NOT NULL DEFAULT '',
  has_anchor INTEGER NOT NULL DEFAULT 1,
  anchor_page INTEGER NOT NULL DEFAULT 0,
  anchor_x REAL NOT NULL DEFAULT 0, anchor_y REAL NOT NULL DEFAULT 0,
  src_doc_id TEXT NOT NULL DEFAULT '',      -- 第二步跨文档用；空串 = 目标就在本文档内
  target_page INTEGER NOT NULL DEFAULT 0,
  has_rect INTEGER NOT NULL DEFAULT 0,
  rect_x REAL NOT NULL DEFAULT 0, rect_y REAL NOT NULL DEFAULT 0,
  rect_w REAL NOT NULL DEFAULT 0, rect_h REAL NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ref_card_document ON ref_card(document_id);
```

- 迁移 = 纯新增表，`CREATE TABLE IF NOT EXISTS` 一句覆盖，无需 `ALTER`（同 v7→v8 建 `scratch_pad`）。
- `src_doc_id` **首版就建列但恒为空串**：建列是白建的（不涉及线格式），第二步做跨文档时只改线格式尾部，
  库不用再迁一次。
- 矩形一律**页内归一化 0~1、左上原点**，与 `PageSnip.Slice.rect`、笔迹、注解同口径。

## 4. 协议增量（`PROTOCOL.md` 待补 §4.5）

opcode 取空位（`0x4A` 之后、`0x50 nack` 之前；S→C 段 `0x30~0x3F` 已满，故下行取 `0x51`）：

| opcode | 名称 | 方向 | payload |
|---|---|---|---|
| `0x51` | `refs` | S→C | `u16 n` · `n ×( str id, str title, u8 hasAnchor, u32 aPage, f32 anx, f32 any, u32 tPage, u8 hasRect, f32 rx, f32 ry, f32 rw, f32 rh )` |
| `0x4B` | `refAdd` | C→S | `u8 hasAnchor` · `u32 aPage` · `f32 anx` · `f32 any` · `u32 tPage` · `u8 hasRect` · `f32 rx` · `f32 ry` · `f32 rw` · `f32 rh` · `str title` |
| `0x4C` | `refDelete` | C→S | `u16 index` |
| `0x4D` | `refRename` | C→S | `u16 index` · `str title` |

- **每项定长**（`hasAnchor`/`hasRect` = 0 时后面那几个 f32 仍占位、写 0，解码端忽略），照 `toc` 的
  `hasPage`+恒定 `u32 page` 先例——定长最好写跨端字节向量。
- 沿用草稿纸那套防御风格：**`index` 越界整帧丢弃**；客户端的增删改只是**请求**，Mac 判定 + 落库后
  以 `refs` **全量回推**为权威，客户端不自作主张改本地列表。
- `refs` 发送时机：客户端接入、服务启动、卡片增删改、平板跟随的会话变化（换窗口＝换文档＝换一整套）。
- 预留（第二步再上，别提前占）：`refMove`(0x4E 挪锚点)、`refRetarget`(0x4F 改目标)；
  跨文档时 `refs`/`refAdd` **尾部追加** `str srcDocId`（空串 = 本文档），旧端遇到多余字节按现有惯例
  ——同 `gotoPage` 尾部可选 `frac`、`scratchpads` 尾部追加 `showPage` 的先例。

## 5. 🔴 取图契约：整页连续排布，按小窗尺度定档位

小窗里是连续页流，**不做任何裁剪**——整页图按 fit-width 依次排下去，与主阅读区同一套布局数学。

- **档位公式**（三端同一个，否则同一张卡片三端清晰度不一样）：
  ```
  wantPx = 小窗内容区宽度(px) × 当前缩放
  ```
  再按 `LANServer.pageWidthSteps = [480,720,1080,1440,2160,2880]` 向上 snap
  （安卓 `shared/PageWidths.kt` 是同一张阶梯）。**小窗物理宽度本来就小 → 天然落在低档位**，
  这是渲染预算能控住的根本原因（见 §8）。
- 打开带矩形的卡片时，初始缩放 = `小窗宽 ÷ rect.w`（clamp 到 1~6x），于是那一块正好铺满小窗；
  档位随之取到高档，字是清楚的。
- Mac 侧走 `PageRenderEngine.Request.pixelWidth`（整页），**与主阅读区共用同一份缓存**——
  参考的是同一份文档的另一页，那张图很可能已经在缓存里，等于零额外渲染。
- web / 安卓的取图路径（`/page.png?i=&w=`、`PageImageSource.request(page,widthPx)`）
  **一个字节都不用改**。
- **夜间反色跟随阅读区**（与草稿纸底图相反）：参考窗里就是在看 PDF 内容，不是一张纸。
  Mac 走 `Request.night` 现成字段；web/安卓沿用各自页图的反色滤镜。

## 6. 三端落地要点

**参考窗要的是主页流的一个很小子集**：没有笔迹、没有 hover、没有选笔盘、没有框选、不上报滚动锚点。
真正贵的那几条硬指标（零闪烁、锚定缩放、滚动跟随）大多用不上，所以三端都不必复制主阅读区。

| 端 | 复用什么 | 新写什么 |
|---|---|---|
| macOS | `PageLayout`（**纯数学**，`init(doc:)` 只读页尺寸、零 `DocSession` 依赖）+ `PageRenderEngine` | `ScrollView`+`LazyVStack` 的只读页流 + 一个极简 cell（只画 image）。🔴 **完全不碰 `ReaderSurface`** |
| web | `/page.png` 取图路径 | 一个独立的只读小渲染器（连续 y 布局 + 按需 `<img>` + 滚动/捏合，约百来行）。🔴 **不参数化全局 `G`**——`render.ts` 全线挂在那个单例上，改它风险远大于另写一个子集 |
| 安卓 | `shared/PageCanvasView`（本就是「几何+输入+渲染，不含提交给谁」）+ `PageImageSource` 注入口 | 一个只读子类（`onInk*`/`onErase*`/`onLasso*` 默认就是空实现，直接继承即可）+ 第二个 image source。**三端里最省的一端** |

### macOS
- 🔴 浮窗挂在 **`PageStreamView` 这一层**（与 `AIInlineLayer` 同层），**不要**用 `ReaderSurface` 的
  `.overlay`：阅读区那四个拖拽手势（拖选/落墨/框选移动/框选截图）挂在 `ScrollView` 容器上，
  同视图的 overlay 挡不住它们（草稿纸当年因此要在每个 gesture 里写 `openPadID == nil` 门控）。
  挂到上一层就是普通遮挡关系，一行门控都不用加。
- 🔴 **参考窗必须用独立 client id 声明 `setWanted`**（如 `"ref-<sessionID>"`）：`PageRenderEngine`
  对入队超 1s 且无人认领的请求会直接丢弃，不声明就是「完成回调永不触发、小窗永远停在占位」。
- 关窗 teardown 里要清掉自己的 wanted 集合与位图引用（移动硬盘弹不出去那条红线的既有清单里加一项）。
- 入口：① 阅读区框选 →「钉为参考」（复用 `PageSnip` 已有的框选手势与归一化，只取 `startPage` 那一段）；
  ② 目录 / 搜索结果 / 缩略图右键「在参考窗打开」（临时，不落库；再点「钉住」才建卡片）；
  ③ Inspector「笔记」页加一个「参考」列表（与草稿纸列表并排：打开、跳锚点、改名、删除）。

### web（采集页）
- 浮窗做成绝对定位 DOM 面板（内含一张 `<img>` + CSS 裁剪，或一个小 canvas），z-index 置于
  `#scratch`(7) 之上、`#topbar`(10) 之下。
- 🔴 面板必须 `touch-action:none` 且吞掉 pointer 事件，否则**笔在小窗上会穿透到 `#ink` 落墨**。
- 🔴 样式一律写进 `web/src/app.css`，组件内不写 `<style>`（Svelte 5 对带 `class:` 指令的元素会漏掉
  作用域类，PadBar 整块样式失效那次的教训）。

### 安卓（两模式共用）
- 覆盖层加在 chrome **之下**以让开顶栏（§7.1 白压白坑）；返回键优先关小窗。
- 取图直接复用 `shared/PageImageSource`：模式1 = `local/PdfSource`（本机 Pdfium），
  模式2 = `pad/PageFetcher`（HTTP）。**两模式零分叉**。
- 内存：模式1 现有约束是「标签页 LRU 只保活 3 篇 + 背景页 Pdfium 缓存 32MB」。参考窗**只保一张位图**，
  且宽度按上面的 `wantPx` 取（不是整页 2160）。小窗关闭即释放。
- 🔴 笔落在小窗上不能画：`PageCanvasView` 的触摸分发要在小窗矩形内直接拦下（同图钉命中的处理方式）。

## 7. 浮窗规格（三端统一）

- 默认尺寸：短边的 ~40%，Mac 不小于 320pt；位置默认右下，可拖到任意角，本端记忆。
- 内容：**连续页流，可自由上下滚动**；捏合/滚轮缩放 1~6x；页宽 fit 到小窗宽。
- 顶部一条极简控制：标题 · 当前页/总页 · 「回到锚点」· 关闭。Mac 额外一枚「主视图跳到该页」。
- 可折叠成一枚小图钉（同 `AIInlineLayer` 的 bubble 形态），不占版面又不丢上下文。
- **视口记忆的粒度**（刻意分两级）：折叠→展开**保持**滚动位置；关闭→重新打开**回到卡片锚点**
  （同草稿纸「打开一律回画布原点」）。
- **只读**：不落笔、不选文字（首版）。这样不必再引入一套坐标系。

## 8. 渲染预算与队列争用（可滚动带来的新风险）

小窗能滚 = 会连续请求一串页图，而它与主阅读区**共用同一条串行渲染队列**
（Mac 是 `PageRenderEngine` 那条，`PDFDocument` 不能并发）。快滚小窗时挤占主阅读区的渲染，
表现就是「拖着参考窗滚，正文那边糊着回不来」。三条对策，写死在实现里：

1. **档位天然低**：`wantPx` 按小窗宽算（§5），小窗宽通常只有主视图的 1/3 → 常落在 480/720 档，
   单张渲染成本比正文小一个量级。
2. **预取窗口只取 ±1 页**（主阅读区的实化窗口更大）。小窗是拿来对照的，不是拿来快速翻阅的。
3. **独立 client id 声明 `setWanted`**（如 `"ref-<sessionID>"`）：滚动中的过期请求出队即弃，
   停下来再 settle 高清。🔴 不声明的话，`PageRenderEngine` 会把入队超 1s 无人认领的请求直接丢弃，
   结果是「完成回调永不触发、小窗永远停在占位图」。
4. 内存：只保活 ±1 页的位图，小窗关闭即释放；关窗 teardown 里一并清（移动硬盘弹不出去那条红线）。

## 9. 分期

| 期 | 内容 | 说明 |
|---|---|---|
| **v1** | schema v12 + 4 条协议 + 三端可滚动只读页流浮窗 + 同文档定位（页/区域）+ 三个入口 | 本方案主体 |
| **v2** | 跨文档（工作区里另一份 PDF） | Mac 加第二份 `PDFDocument`（🔴 **只能被 `PageRenderEngine` 那条队列碰**——2026-07-27 阅读区白屏那条；且必须进关窗 teardown）；`/page.png` 加 `d=<libDocId>`；安卓两模式各加一个 `PageImageSource`；`refs`/`refAdd` 尾部追加 `str srcDocId` |
| **v3（值钱）** | 页偏移 / 区间映射 | `答案页 = 当前页 + offset`，或按章节区间映射。配一次全书受用，翻页时小窗自动跟着切——这才是「对照系统」而不只是「小窗」。等 v1 手感确认后再定 |

## 10. 验证清单

- `spike/ref-store-test.swift`：`ref_card` DAO + v11→v12 迁移 + 级联删除（删文档连带删卡片）。
- `wire-codec-test` / `wire-cross-test` / 安卓 `WireCodecTest`：4 条新消息的跨端字节向量，
  含 `hasAnchor=0`/`hasRect=0`（占位 f32 不能被默认值吃掉）与 `index` 越界丢帧。
- `xcodebuild` / `tsc --noEmit` / `svelte-check` / `vite build` / `assembleDebug`。
- 🔴 **手感与观感一律由用户在真机上测**（小窗默认大小、拖动阻尼、滚动手感、小窗快滚时正文渲染有没有被挤、
  平板上笔会不会误触小窗），结论攒进 `ANDROID-STANDALONE-PLAN.md §11.1`。
