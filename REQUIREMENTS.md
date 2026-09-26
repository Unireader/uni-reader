# UniReader — macOS PDF 阅读器需求分析

> 一款不修改 PDF 原文、笔记外挂存储的 macOS 阅读器，支持文件记录分组、三种笔记形态，以及通过局域网网页用安卓平板触控笔手写。

## 0. 已确认决策（2026-07-19）

| 决策 | 选择 | 影响 |
|---|---|---|
| 平板端形态 | **显示当前页图片 + 本地即时落墨** | 笔画用归一化页面坐标 (0~1)，与 Mac 缩放/视口解耦，坐标映射从"最高风险"降级 |
| 分发方式 | **直接分发 + 公证（非沙盒）** | 文件用普通路径 / bookmark，无需 security-scoped resource |
| 最低系统 | **macOS 26 Tahoe**（2026-07-19 从 15 上调，不做兼容） | Liquid Glass 全量 API 直接用（`backgroundExtensionEffect` 等），无 #available 分支 |
| 主窗口布局 | **框架 = 原生 NavigationSplitView（玻璃侧栏）+ 右侧 `.inspector`；PDF 阅读区 = 自研页图流 `PageStreamView` v2（2026-07-20 重写：纯 SwiftUI，Preview 级五硬指标——主线程零渲染/预缓存/pinch 锚定零跳位/resize 零跳/任何情况零闪烁；见 `PDF-VIEWER-REBUILD-PLAN.md`）** | 目标行为：① 侧栏叠加在 PDF 上（玻璃虚化真实内容）；② **侧栏/Inspector 开合不改变页面尺寸/位置**（2026-07-20 用户更新，取代旧「挤到右侧居中」）——页面被玻璃盖住、可横向拖出；③ 手动放大后允许被侧栏覆盖。fit 宽以滚动视图实测可用宽为准（兼容鼠标 legacy 占空间滚动条）。**红线：严禁仿侧栏/浮层 hack；阅读区纯 SwiftUI，严禁 AppKit 视图（含包 NSScrollView）** |

## 1. 功能需求

### 1.1 文件记录与分组

- 记录所有打开过的文件（最近列表）
- 支持自定义分组（右键「Move to Group」移入；**拖拽归组已于 2026-09-03 按用户要求移除**）
- 侧栏文档可**手动排序**：右键「上移 / 下移」，同一分组段内换位（2026-09-03；**拖拽排序做过三版、
  全部被用户否决，勿再尝试**，坑记在 `SidebarView` 头注释）。落 `document.sort_order`：排过的 ≥1，
  没排过的仍是 0 → 排在最前（新加的书照旧在顶上）。
- **hash 去重**：以文件内容 hash（SHA-256，分块读取）作为文档唯一标识
  - 同一文件存在多个路径（移动、复制）→ 识别为同一文档的多个存储位置
  - 打开时自动探测哪个路径仍然有效
  - 笔记与 hash 关联，文件移动后笔记不丢失
  - 文件内容被修改（hash 变化）→ 提示重关联，旧笔记保留

### 1.2 知识笔记

**核心原则：不在 PDF 文件上做任何修改**，所有笔记独立存储，通过 `hash + page + PDF坐标` 锚定。

| 类型 | 形态 | 存储内容 |
|---|---|---|
| 文字注解 | 锚定到页面位置/选区的便签 | 文本 + 锚点 + 展开方式 |
| AI 会话绑定 | 锚定到页面/选区的**外链**网页对话（2026-08-25 落地；原「会话笔记＝消息数组」的设想作废） | 会话 URL + 标题 + 已发上下文列表 + 锚点 |
| 手写笔记 | 矢量笔画，叠加渲染在页面上方 | 笔画点列（压感）+ page |

**文字注解的展开方式**（2026-08-27，三端同款）：正文可以直接摊在 PDF 页面上，**每条笔记各自设定**
（编辑器里的「展开方式」分段；落 payload 的 `display` 键、线上是 `notes`/`textNote` 尾部的 u8，
见 `PROTOCOL.md`）：

| 模式 | 行为 | 点图钉 |
|---|---|---|
| 点击（默认） | 点图钉展开/收起气泡 | 展开/收起 |
| 悬浮 | 指针（Mac）/ 笔（平板）悬停在图钉上才展开；**手指没有悬停 → 降级为点击展开** | 进编辑器 |
| 始终 | 一直摊开 | 进编辑器 |

- 气泡里**只有批注正文**（原文引文由页面上的荧光高亮体现，不重复占地方）；右上角一枚铅笔进编辑器
  （只有「常驻气泡」有：悬停预览一移开就收，那颗按钮够不着）。空正文的笔记不展开（没有可看的东西）。
- **正文是 Markdown 源**（2026-09-13 起；图片笔记的说明同）：编辑器 sheet 用 `swift-markdown-engine`
  （`MarkdownNoteEditor`，所见即所得，⌘↩ 保存）；**存的仍是纯文本**，库/协议/镜像不变。
  页面气泡也用同一个引擎**只读**渲染（`MarkdownNoteReader`；用户：「气泡渲染最好也用这个，关闭编辑即可」——
  纯 SwiftUI `Text` 的近似渲染效果不好）。这是阅读区「纯 SwiftUI」红线的唯一例外，限定在气泡正文。
  气泡高度由引擎报回（第一帧按 TextKit 估计占位），超行数上限裁掉；标题/列表缩进用笔记尺度
  （`MarkdownNoteEditor.applyNoteTypography`）。网页/安卓端目前画原样源码。
- **尺寸口径两种**（2026-09-13 用户改：「随 pdf 缩放可以保留，但默认关闭，设置里开」）：
  · **固定尺寸**（Mac 默认）：宽 280pt / 正文 12pt / 行高 1.25 / 内边距 5pt（「很窄的边」），页面缩放时气泡不动，最多 14 行；
  · **跟页缩放**（设置 → 阅读 →「笔记气泡跟随页面缩放」；2026-08-27 的原口径）：气泡宽/字号/行高/内边距全是**页宽的比例**，
  比例常数是三端契约（Mac `NoteBubble` / web `render.ts BUB` / 安卓 `NoteBubbleGeom`，改一处必须同步另外两处；
  2026-09-13 调小为字号 0.017 / 行高 1.25 / 内边距 0.30），折行交给各端自己的排版引擎；超 10 行截断（全文去编辑器看）。
  网页/安卓没有这个开关，恒跟页缩放。位置规则三端一致：图钉右侧优先 → 放不下翻左侧 → 整体钳进页内。
  两种口径都是 `NoteBubble.Metrics`，文字气泡与图片气泡共用。
  · **字号可设**（设置 → 阅读 →「气泡正文字号」/「编辑框字号」，2026-09-13 用户要）：气泡默认 12、编辑框默认 13，
  档位 10~24。编辑按钮/行距按「÷ 12」等比跟着字号走；跟页缩放口径下同一个倍率乘到字号比例上，
  三端契约的比例常数本身不动。
  · **宽度**（2026-09-13 用户定：「短文按内容收窄，有个最小和最大宽度，一样在设置里设」）：设置里「气泡最小宽度」
  （默认 120）/「气泡最大宽度」（默认 280），80~800 步进 20，互相钳住。文字气泡按内容最宽一行
  （`NoteMarkdown.naturalWidth`：不折行逐行量，标题按放大后的粗体、列表加缩进、引用加竖条，再加 4% + 6pt 余量）
  在两者之间收窄；图片气泡横图撑到最大宽、竖图收窄贴图但不低于最小宽。**宽度不随字号变**（都是设置项，各管各的）。
  跟页缩放口径下两个宽度按参考页宽 933pt（= 280 ÷ 0.30）折算，随页缩放。
- **「此刻哪几条展开着」是各端自己的瞬态状态**，不落库也不上线（同缩放/滚动的口径）——
  展开方式才是笔记的属性。

### 1.3 平板触控笔手写

- Mac 端内置局域网 HTTP + WebSocket 服务：HTTP 分发采集网页与**当前页渲染图**，WebSocket 双向传笔画 / 翻页
- 平板（小米平板 6 + 灵感触控笔）浏览器打开网页：**以当前 PDF 页图片为背景**，笔在页面上手写，**本地即时落墨**保证跟手
- 笔画以**归一化页面坐标（0~1）**实时推送到 Mac；Mac 端 `归一化坐标 × page.bounds` 换算为 PDF 页面点落墨
- 翻页：屏幕 prev/next 按钮，或「翻页模式」下**笔拖动左右滑翻页**，与 Mac 端页码双向同步
- 笔身侧键（PageUp/PageDown）**不用于翻页，改作工具/模式切换**（见 1.5）
- 配对方式：二维码 / 短码携带 token，token 作为 WebSocket 准入校验，无账号系统
- **平板可以自己开文档、自己用目录跳转**（2026-08-05 加，网页与安卓输入板两端同款左侧拉抽屉）：
  - **书库页**：列出平板当前跟随的那个窗口**所属工作区**的全部文档（不只 Mac 已打开的那几个），点未打开的 → **Mac 新开一个窗口**装它、平板自动跟过去（用户 2026-08-05 拍板：不顶掉当前窗口的文档、也不做「只在平板上换、Mac 不动」的隐藏会话）；点已打开的 → 等价切到那个窗口，不重复开窗。
  - **目录页**：Mac 把 PDF 目录（`TOCEntry.build` 的结果）先序拍平后下发，平板重建可折叠树，当前章节自动展开祖先链并定位；点条目**跳到章节标题那一行**（页 + 页内比例，不是页顶）。坏书签（destination 解不出目标页）渲染成不可点的灰行。
  - 线格式见 `PROTOCOL.md`：`library`(0x3B)／`toc`(0x3C)／`openDoc`(0x2A)／`gotoPage`(0x29) 的尾部可选 frac。

### 1.4 平板视口同步与悬停指示

- **视口同步（双向）**：Mac 为渲染真相源；平板可本地平滑滚动，两端画面保持一致。
  - Mac 推送「当前页 + 相邻页」的渲染图与页面布局元数据，平板组成可滚动的页面列，**本地滚动流畅**（不逐帧传图）
  - 平板滚动 → 上报「可见页 + 归一化偏移」→ Mac 的 `PDFView` 跟随滚动到同一位置
  - Mac 滚动 → 推「可见页 + 偏移」→ 平板同步
  - 手写坐标始终用归一化页面坐标，滚动 / 缩放不影响落墨
- **悬停指示（Firefox 可用，已实测）**：小米平板 6 实测，**Chrome 不把笔 hover 转发给网页，Firefox 可以**。故采集页在 **Firefox** 下持续上报悬停坐标（归一化页面坐标 + 页码），Mac 在页面上叠加显示笔尖位置（接触即转为落墨，离开近场即隐藏）。悬停圆环须画在与笔迹同坐标系的 overlay canvas 上，避免移动端 `position:fixed` 偏移。

**线格式（2026-07-25 更新）**：WebSocket 帧已从 JSON 文本改为**二进制线格式 v1**（opcode `.binary`），契约见 **`PROTOCOL.md`**（唯一真源），三端实现 `WireCodec.swift` + `wire.js`。下表仍是**语义参考**（消息名/字段/方向不变，只是打包方式变二进制）；实际字节布局见 `PROTOCOL.md §4`。后续 UDP 阶段：`RT` 高频流（ink/erase/scroll/hover/probe）可迁 UDP，控制类仍走 WS。

**WebSocket 消息草案（语义参考）：**

| 方向 | 消息 | 内容 |
|---|---|---|
| Mac→Pad | `pageImage` | 页码、图片（或 HTTP 取图 URL）、页面尺寸、旋转 |
| Mac→Pad | `viewport` | 可见页 + 归一化偏移（Mac 端滚动时） |
| Pad→Mac | `scroll` | 可见页 + 归一化偏移（平板滚动时） |
| Pad→Mac | `hover` | 归一化页面坐标 + 页码 + 倾斜 |
| Pad→Mac | `ink` | phase(begin/move/end) + 归一化点[含压感] + 当前笔(color/width) |
| Pad→Mac | `erase` | phase + 归一化擦除轨迹点 |
| Pad→Mac | `mode` | 当前模式（note / erase / page） |
| Pad→Mac | `pageTurn` | prev / next（屏幕按钮 / 翻页模式笔拖动） |

### 1.5 工具与模式（笔身侧键）

采集页维护「模式」与「当前笔」两个状态，用笔身两个侧键切换（不占用翻页）：

- **PageUp（上键）= 切换模式**，循环：笔记 → 擦除 → 翻页
  - 笔记：落墨（当前笔颜色/粗细 + 压感变宽）
  - 擦除：笔经过处抹除笔画
  - 翻页：笔拖动左右滑翻页 / 平移（后续接滚动）
- **PageDown（下键）= 切换笔**，在预设笔列表间循环（并切回笔记模式）
- 顶栏显示当前模式与笔色；屏幕 prev/next 按钮始终可用作后备
- **键盘快捷键**（三端同约定；文本框焦点/带修饰键时一律放行）：
  `e` 橡皮 ⇄ 笔记来回切、`1`~`9` 直选笔槽（并回笔记模式）、`n`/`b` 回笔记、`v` 翻页 ⇄ 笔记、`l` 框选 ⇄ 笔记
  - macOS 阅读区额外两个本机指针工具键：`i` 本机笔 ⇄ 文字选择、`t` 回文字选择；菜单有对应的 ⌥ 修饰键版本（⌥1~4/⌥E/⌥V/⌥B）
  - macOS 窗口级：⌘B 切侧栏、⌘I 切检查器（Inspector）、⌥⌘R 参考窗、⌘⇧A AI 面板（浮窗模式 = 显示 ⇄ 隐藏）
  - **macOS 上以上都是默认值，设置 › 快捷键可改**（2026-09-13，`Sources/App/Shortcuts.swift`）；数字键 1–9 与
    新建/打开/关闭/撤销/剪贴板/查找/退出这些基础命令固定不可改。`n` 只在有选区时用（加批注），书写用 `b`。
- 页面绘可见边框标出可落笔区（竖版 PDF 在横屏平板上居中留白属正常，占满屏可竖持平板或待步骤 4 适宽滚动）

### 1.6 多窗口与共享服务

- **多窗口**：macOS 可同时开多个窗口看多个 PDF（⌘N 新窗口，⌘O 打开）；同一 PDF 也可开多窗口，并发编辑笔记（少见但允许）。
- **共享 WS**：全窗口共用**一套** WebSocket 服务（`AppModel` 持有唯一 `LANServer`），避免端口冲突。
- **平板显示哪个**：默认跟随**最后激活**的窗口；平板顶栏下拉列表可手动切到任一打开的 PDF（S1b）。平板与 Mac **可不同缩放/范围，只同步文档滚动位置**。

### 1.7 长按切笔手势

- 笔**重压 + 静止**：超过 300ms 时，在 **Mac 笔尖处**显示圆形进度环；累计 >2s 呼出**切笔工具**（在 Mac 笔尖处）。
- 触发后这一笔（按下产生的墨点）**清除**。
- **关键**：正常落笔立即出墨（不等 300ms，避免延迟）；一旦判定为长按手势再**回溯清除**那一笔，保证书写零延迟。

### 1.8 草稿纸（无限白板覆盖层，2026-08-07；页面底图与客户端管理 2026-08-13）

**用户原话**：「在 pdf 任何一处创建一个草稿纸，打开后从该处显示，默认无限，覆盖在 pdf 上面，底色默认白色，
整个笔迹只能在草稿纸上使用……更像一个 UI 覆盖在 pdf 上，而不是在现有 pdf 上加，这样三端都能独立添加草稿纸、
有自己的缩放滚动；默认无限制但要避免滚动到无限位置，需要有个回中，以及一个 minimap。」

- **它是一层 UI，不是 PDF 的一部分**：不改 PDF 原文、不属于任何一页。因此三端各自独立地开/关/缩放/滚动，
  互不牵连；同步的只有「有哪几张纸、开着哪张、纸上有哪些笔迹」。
- **锚点**：在阅读区任意位置右键「在此新建草稿纸」→ 记下 (页, 页内归一化点)，页面上留一枚图钉。
  打开时视口回到**画布原点**（= 创建那一刻的位置），即「从该处显示」。
- **无限画布**：坐标无界可负。但**不允许滑到天边**——软边界把可视区限制在「内容包围盒 ± 1.5 屏」内，
  空白纸只能在原点附近小范围移动。另有「回中」（回原点）与「适应内容」（装下全部笔迹）两个按钮。
- **minimap**：右下角，全部笔迹骨架 + 当前视口框，点/拖即跳。可关。
- **笔迹只落草稿纸**：纸开着时，`ink`/`erase` 整条链路被拦下改走画布坐标，PDF 页面上不会留下任何东西。
  长按环形选笔盘在纸上**不生效**（那套判定建立在页内归一化 + `padGeom.pageW` 上，喂画布坐标会整个失真）。
- **纸样**（2026-08-07 加）：**底色 × 底纹**两个维度。底纹 = 纯色 / 点阵 / 小格（默认点阵——
  无限画布不给参照物的话，平移时看不出自己在动）；底色 = 一组预设纸色（纸白/米白/浅灰/牛皮/
  护眼绿/淡蓝；`bg` 本身是自由 CSS rgba，备选项只是各端 UI 的事）。底纹墨色由**纸色明度**推
  （浅纸配深纹），**不跟系统深浅外观走**。夜间模式下草稿纸**不反色**——它是一张纸，不是 PDF 内容。
  Mac 与网页都从工具条的「纸样」按钮进，改动跨端同步（`scratchPaper` 0x2D）。
- **页面底图**（2026-08-13 加，用户要求「所在 pdf 页面显示在草稿纸上面，可以切换显示」）：
  每张纸带一个开关，开着时把它**锚定的那一页**垫在纸下面当参照（层序：纸色 → 底纹 → 页图 → 笔迹）。
  仍然「不改 PDF」——纸上的笔迹属于这张纸，页图只是背景。几何是**三端契约**：页宽恒 800 画布点、
  锚点落在画布原点（于是「打开 = 回原点」正好摆出当初创建它的那一处），详见 `PROTOCOL.md §4.4`。
  开关是**纸的属性**（跟着纸走、跨端同步、重开文档还在，不是视口那种各端私有状态）：
  **新建的纸默认开**、v9 迁移过来的老纸默认关。开着底图时它也计入「内容包围盒」（软边界/适应内容/
  minimap），否则空白纸上垫了页也走不到页边。页图**不参与夜间反色**（同草稿纸整体）。
- **入口**：阅读区右键新建 / 页面图钉 / Inspector「笔记」页的草稿纸列表（打开、跳锚点、删除）/
  平板顶栏的草稿纸按钮（列表 + 新建 + 改名 + 删除）。
- **客户端也能管理**（2026-08-13 加）：网页采集页在草稿纸列表里逐行改名/删除（删除两步确认，
  纸上笔迹一并删）；安卓两模式在纸样面板的「管理」组里改名/删除。删/改都只是**请求**，
  Mac 判定 + 落库后以 `scratchpads` 全量回推为准（`scratchDelete` 0x48 / `scratchRename` 0x49）。
- **🔴 画布坐标系（三端契约）**：单位 = 逻辑点（pt / CSS px / dp），原点 = 创建点，可负无界；
  笔宽与页内笔迹同语义。这么定是为了让三端现成的笔迹渲染器原样复用（详见 `PROTOCOL.md §4.4`）。
- **范围**：四端全部落地——Mac + 网页平板（2026-08-07）、安卓两模式（2026-08-07）、
  页面底图与客户端删除/改名四端同步（2026-08-13，待真机验证）。

### 1.9 书签（2026-09-02 定需求，未实现）

**用户原话**：「补一个书签类型的记录，方便添加书签，书签可以和 toc 组合起来，这样方便在 toc 里面查看，
书签按照页数，显示在第一级 toc 组区间里（如果有）。」

**一句话定义**：书签 = 一条挂在「某文档某页某处」的、**带名字**的定位记录，只用来「回到这里」。
它不是笔记（没有正文、不铺色、不参与框选/图层/擦除），也不改 PDF 原文；它与 PDF 自带目录合并在
**同一棵树**里显示——目录是书自带的、只读的，书签是你自己加的、可增删改的。

#### 数据模型（跨端契约）

- **复用 `note` 表，`kind = 5`（bookmark）**，不新建表。同草稿纸笔迹 `kind=4` 的先例：
  增量对账（`DocTabModel.persist*`）、`ON DELETE CASCADE`、`mergeDocument` 迁移、安卓
  `local/store/LibraryStore` 的读写、离线镜像的行指纹（`MirrorFingerprint` 按表规格算，note 表结构没变）
  **全部原样继承**。表结构不动 → **不升 schema 版本**，只是多一个 kind 值。
- 字段落位：`page` = 0 基页号；`anchor_y` = 页内归一化纵向位置（frac，0 = 页顶）；
  `anchor_x` 恒 0（留给将来的「指到某一处」）；`anchor_w`/`anchor_h` = 0（点锚，同文字笔记的点注解）；
  `payload` = 显式 JSON `{"title":"…"}`（跨平台 payload 一律显式 JSON，不用任何语言的序列化器）。
- **一页可多枚**：身份是 `id` 不是页号。同页多枚按 `anchor_y` 升序、并列再按 `created_at` 升序（稳定序）。
- **名字必填**：新建时先弹输入框，**空白/全空格 = 放弃创建**（不落库，同 Mac 端丢弃空点注解的语义）。
  改名走同一个输入框。输入框**不预填**名字，只把「所在章节 · 第 N 页」放进 placeholder 当提示
  ——预填等于替用户按了确定，与「必须输入」相悖；改名那一路例外（初值就是原名）。

#### 与目录的合并显示（三端同一口径，规则写死）

1. **目录树本身一行不动**：先序 + depth 照旧，坏书签（`page = -1`）仍是不可点的灰行。
2. 书签是插进这棵树里的**另一种行**：图标与颜色区分，行尾同样显示页码。
3. **归组**：取目录里全部 `depth = 0` 且有页号的项，按页号升序得到区间边界 `p₀ ≤ p₁ ≤ …`；
   页号为 `b` 的书签落在 `[pᵢ, pᵢ₊₁)` → 挂到第 i 个一级组下，**作为它的直接子项**。
4. **没组可挂就平铺**：`b < p₀`（在第一个一级组之前）、或这本书**没有目录 / 目录里一个可用的
   `depth = 0` 项都没有** → 该书签显示在树的**最顶部**，不套任何组，也不造「书签」这种假分组标题。
5. **组内位置**：书签插在「该组直接子项中第一个页号大于它的那一项」之前（该项若无页号就顺延找下一个
   有页号的）；都不大于就排在该组直接子项末尾。**目录项之间的相对顺序一律不变**——绝不为了排序
   重排 PDF 自己的目录。
6. **当前章节追踪只认目录项**，书签行不参与（同坏书签的处置）：追踪回答的是「我在第几章」，
   让它跳到书签行上没有意义。
7. 点书签行 = 跳到 `(page, frac)`，与点目录项走**同一条**锚点路径（Mac 的 `origin:"toc"` / 平板的
   `gotoPage` 带 frac）。

> 🔴 **合并规则的参照实现是 `Sources/App/TOCMerge.swift`**（纯函数，只认「深度 + 页号」，
> 不认 PDFKit 也不认 SwiftUI），覆盖测试 `spike/toc-merge-test.swift`（19 项）。
> web 与安卓照它实现，别各自照着这段文字再推一遍——三端差一条规则，同一本书两端长得就不一样。

#### 入口

- **Mac**：① 阅读区右键菜单「在此添加书签」（落点 = 右键处的页 + 页内 frac，`readerContextMenu`）；
  ② **⌘D** = 在**当前阅读位置**加（`currentMark`，即滚动锚点；快捷键全项目未占用，已核）；
  ③ Inspector「目录」页顶部一枚「添加书签」（同 ⌘D 语义）。书签行右键 = 改名 / 删除。
  工具栏的目录弹窗也列书签（只跳转，改名/删除仍走 Inspector 那一份）。
- **页面上的标记**（2026-09-02 用户问「书签在 pdf 页上是不是没显示」后加）：贴**页右缘**、纵向落在
  书签自己的页内位置上的一面**红色缎带**（`BookmarkRibbon`：右端切 V 口，扁平纯色 + 0.5 描边，
  无渐变/高光/投影）。一页可多枚，所以不是页角。悬停出名字，**点它出小面板：名字 + 页码 +
  改名 / 删除**——书签点开没有内容可展示（跳转从目录去），页面上这一枚的用处是
  「一眼看出这一处标过」+ 就地改名/取消。
  > 首版做成了「暖橘圆底 + SF Symbol」（与两种图钉同一套形制），用户实测**根本没注意到**、
  > 「颜色还是橘色的说实话没有反应过来」。改成缎带的两条理由：红是书签的通用色；**形状本身**
  > 就是信号，于是与另外两种圆形图钉（文字注解黄圆 / 草稿纸蓝圆）一眼分得开，不必靠颜色去记。
  > 样张 `spike/bookmark-flag-look.swift`（四版对照；其中的 `RibbonShape` 是线上 `BookmarkRibbon`
  > 的复刻，**改一边必须同步另一边**）。
  > 🔴 另一条教训：缎带**不能探出页外**——页元胞会裁掉，第一版样张就是这么画错的。
  > 还有：**别用 `Menu` 做页面上的标记**，它是 AppKit 托管控件，ImageRenderer 直接画成「不支持」
  > 的黄框；用 `Button` + `.popover`，与两种图钉同一条渲染路径。
- **管理**：Inspector「笔记」页有独立的**书签分区**（平铺按页序，加 / 跳 / 改名 / 删）。
  分工是「目录页管看和跳，笔记页管加改删」——目录那棵树是阅读时用的，管理时要的是一眼看全。
  该页 2026-09-02 起分**二级分区**（文字 / 高亮 / 书签 / 笔迹 / 草稿纸 / AI 会话，系统 segmented
  图标栏，选中项记 `@AppStorage`）：用户报五类堆一页「太多了看不过来」。
- **网页采集页**：抽屉「目录」页顶部 `+`（当前视口顶）；书签行长按出改名/删除。
- **安卓两模式**：`shared/ReaderDrawer` 目录页顶部 `+`；行长按出菜单。模式1 直接落库，
  模式2 走协议上行由 Mac 落库。
- **不进环形选笔盘**：盘上已有 5 个扇区，书签是低频操作，不占那个位置。

#### 协议（拟案，落地时搬进 `PROTOCOL.md` 并补跨端向量）

- `bookmarks`(**0x4D**, S→C, 可靠)：全量镜像
  `str docId · u16 n · n ×( str id, u32 page, f32 frac, str title )`。
  `docId` = **内容哈希**，与 `toc`(0x3C)/`layout`(0x31) 同口径 → 客户端**必须核对**才敢渲染
  （切档时两条广播的先后没有保证，不核对就会把上一本的书签挂到新书上，`PROTOCOL.md §4.1` 的老账）。
- `bookmarkEdit`(**0x4E**, C→S, 可靠)：`u8 op（0 add / 1 rename / 2 delete） · str id · u32 page ·
  f32 frac · str title`。add 的 id 由客户端生成 UUID 串（同 `textNote` 先例）；**Mac 是唯一真源**，
  处理完以 `bookmarks` 全量回推为准（同 `scratchDelete`/`scratchRename` 的惯例）。
- 老客户端不认这两个 opcode 时走既有 `nack`(0x50)，不崩。

#### 范围与分期

实现顺序：**Mac 先行**（数据层 + 目录页合并显示 + 三个入口）→ 网页采集页 →
安卓两模式（模式1 直接读库，模式2 走协议）。

**四端 2026-09-02 全部落地**（同日，待真机验证）：

| 端 | 显示 | 加 / 改名 / 删 | 真源 |
|---|---|---|---|
| Mac | 目录页合并树 + 工具栏目录弹窗 + 页右缘红缎带 | 右键「在此添加书签」/ ⌘D / Inspector 笔记页书签分区 | 自己（`note kind=5`）|
| 网页采集页 | 抽屉目录合并树 | 抽屉顶「添加书签」+ 行尾两枚键 | Mac（`bookmarkEdit` → `bookmarks` 回推）|
| 安卓模式2 | 同上（`shared/ReaderDrawer`）| 同上 | Mac（同网页）|
| 安卓模式1 | 同上（同一份抽屉）| 同上 | 本机库（写完读回来再喂抽屉）|

- 协议：`bookmarks`(0x4D) / `bookmarkEdit`(0x4E) 已在 `PROTOCOL.md`，跨端向量 #86~#90。
- 合并规则四份实现同源：`TOCMerge.swift`（**参照实现** + `spike/toc-merge-test.swift` 19 项）
  ↔ `web/src/lib/tocMerge.ts` ↔ `android/shared/TocMerge.kt`（`TocMergeTest` 7 项逐条对应）。
- **页面上的红缎带四端都有**（安卓两模式 2026-09-02 同日补上：`PadOverlays.drawBookmarkRibbon` +
  `PageCanvasView` 的标记层，两模式共用一份——书签的身份两端都是 UUID 串，不像草稿纸图钉那样
  模式2 用下标、模式1 用库 id）。尺寸/形状/颜色与 Mac 逐项对齐（26×15、V 口 5、rgb(214,60,60)）。
  > 平板上**只认手指不认笔**（点它出改名/删除小菜单）——笔是用来写字的，让笔点标记必然会在
  > 标记上落笔时误触发。这是草稿纸图钉与 web `endTouch` 早就定下的决策，照搬即可。
  > 我一开始判断「平板不做页面标记，怕跟笔打架」是错的：那个问题本项目两年前就解决过。

> 🔴 **分期唯一的真风险**：安卓模式1 读的是**同一个库**。在它实现之前，它就会 `SELECT` 到 `kind=5`
> 的行——落地第一步必须先核实安卓侧按 kind 分流、不会把书签当笔迹画出来（`LibraryStore` 的
> `kind ==` 过滤）。网页/模式2 不读库，不受影响。

#### 验收（真机）

① 同一页加两枚不同位置的书签 → 目录里同页两行，按页内位置先后排；
② 名字留空点确定 = 不创建；
③ **有目录的书**：书签落在正确的一级组下，展开那组看得见，且目录项自身顺序一个没动；
④ **没有目录的书**：书签平铺在树顶，点得动；
⑤ 页号在第一个一级组之前的书签：也在树顶；
⑥ 点书签跳到**那一页那一处**（不是页顶）——拿章节从页中部起的书试才看得出来；
⑦ 改名/删除即时生效，重开文档还在；
⑧ 删掉文档 → 书签随级联一并清；
⑨ **离线镜像**：镜像里加的书签接回硬盘后能三方合并回来（走 note 表既有通路，不需额外代码，验一次）；
⑩ 当前章节高亮不会跳到书签行上。

### 1.10 图片笔记（2026-09-13 定需求并落地，Mac + 离线镜像；方案见 `IMAGE-NOTE-PLAN.md`）

**用户原话**：「支持从外部导入，或者从 pdf 节选出图片。图片保存在工作区中，管理完全由软件管理，
图片按照引用计数管理，全部引用被删除后，进入待删除状态，超过 30 天后则彻底删除。」

一句话定义：**图片笔记 = 一条挂在「某文档某页某处」的笔记，正文是一张图**；图片本体存在工作区包
`Images/<sha256>.<ext>`，由 App 全权管理。

| 项 | 定案 |
|---|---|
| 数据 | `note` 表 **kind=6**（payload：`image`(sha256) / `caption` / `display` / `source`）+ 新表 `image`（schema **v13**，主键 = 内容 SHA-256） |
| 引用计数 | **数出来的**（kind=6 且 payload `image` = 该 sha 的行数），不存计数列 |
| 待删除 | 引用归零那一刻记 `orphaned_at`；不重置；引用回来即清空；`orphaned_at` 早于 30 天前 → 删文件 + 删行（打开工作区时清；设置里可「立即清理」） |
| 入口 | **⌥⇧ 拖**（PDF 节选，⌥拖发 AI 不变）/ 拖图片文件到页面 / 右键「在此导入图片…」/ ⌘V |
| 呈现 | 图钉（淡青 `photo`）+ 气泡（缩略图 + 说明），展开方式与文字笔记同三态；双击缩略图看原图 |
| 镜像 | `image` 表走 OCR 那条纯 additive 通道：建镜像带 `Images/`；双向补「缺行或缺文件」的图；**`orphaned_at` 原样带过去** |
| 不做 | 平板/安卓（`notes` 广播不发 kind=6）；图片进 AI；图片参与框选/图层/擦除 |

### 1.11 画板笔记（2026-09-24 定需求，09-26 四端落地；方案见 `BOARD-NOTE-PLAN.md`）

**用户原话**：「做一个单纯的画板笔记，不需要 pdf，类似草稿纸模式，对应的功能可以迁移过去，pad 两个模式+网页需要适配」。

一句话定义：**画板笔记 = 工作区里一篇独立的无限白板文档**，与 PDF、Markdown 笔记平级（侧栏一段、标签页里打开），
整页就是一张草稿纸；不挂 PDF，所以没有锚点、图钉、页面底图。

| 项 | 定案 |
|---|---|
| 数据 | schema **v16** 新表 `board_note` + `board_item`（kind 1 笔迹 / 2 图片，一条一行）；图片本体沿用 `Images/` + `image` 表，引用计数并上画板上的图 |
| 功能 | 草稿纸现有全部（四种笔、橡皮、尺子、自由框选 + 手柄缩放、剪贴板、撤销、纸样、minimap、回中 / 适应内容）+ **图片**（拖入 / ⌘V / 「插入图片…」，框选可移动缩放，双击看大图） |
| 平板 | 网页 + 安卓模式2：跟随 Mac 整屏书写 + 列出 / 打开 / 新建画板（请 Mac 开标签）；图片只看不改 |
| 安卓模式1 | 独立读写两张表，书库与标签页都认画板；库里没有这两张表时**用与 Mac 逐字相同的语句补建**（2026-09-26 起安卓可以正常迁移表结构） |
| 兜底 | 删除进回收站（可恢复）；离线镜像按 `updated_at` 逐行合并 |
| 分页模式（2026-09-26，方案 §9） | 新建时选无限画布 / 分页；分页 = 页竖排、整本同尺寸（A4 / A5 / Letter / 当前屏幕，横竖）、每页一个背景模板（空白 / 横线 / 方格 / 点阵 / 康奈尔 / 两栏，可单页或批量设）、预建 N 页或到底上拉加页；schema **v17** 新表 `board_page`，条目存页内坐标；平板可书写、加页、改当前页背景 |
| 不做 | 从 PDF 截图直接放进画板、多图层、分组界面、MCP |

## 2. 目标设备验证（小米平板 6）

> ✅ **Step 0 已实测通过**（2026-07-19，小米平板 6 + 灵感触控笔，Chrome 与 Firefox，测试页 `spike/pen-test.html`）：
> - 压感真实可用（随力度变化，非恒定值）
> - `pointerType=pen` 可区分手指/笔，防误触成立
> - `getCoalescedEvents()` 高采样可用
> - Fullscreen API 可进全屏、隐藏浏览器控件
> - **笔身两个侧键 = `PageUp` / `PageDown` 键盘事件**（走 BLE HID，非 pointer 通道），可读、两键可区分
> - ✅ **笔悬停 hover：Firefox 可用**（Chrome 不转发给网页，Firefox 转发）→ 悬停预览可实现（Mac 上显示笔尖位置）；**目标浏览器定为 Firefox**
> - ⚠️ **笔迹平滑**：Firefox 采样率偏低，直线连点折角明显 → 需曲线平滑（二次贝塞尔中点法 / Catmull-Rom），采集页本地落墨与 Mac 端渲染都要做（测试页已加中点平滑）

- `pointerType: "pen"` 可区分手指与笔 → 防误触（检测到笔后忽略 touch）
- `event.pressure`：归一化 0~1，实测有真实压感（Chrome）
- `getCoalescedEvents()`：配合 144Hz 屏获取高采样率点，笔画顺滑
- `tiltX/tiltY`：大概率有但不稳定 → **只硬依赖压感，倾斜作为加分项**
- 侧键：采集页监听 `keydown` 的 `PageUp/PageDown`（忽略 `e.repeat`）→ **PageUp 切模式、PageDown 切笔**（见 1.5），不用于翻页
- 平板端渲染"页面图 + 本地墨迹"，负载轻（仅贴图 + canvas 线条），浏览器性能差异影响小
- **建议平板使用 Firefox 浏览器**（压感 / 防误触 / 合批 / 翻页键均支持，且能拿到笔悬停；Chrome 不转发 hover，退为备选）

## 3. 技术栈

| 模块 | 选型 | 理由 |
|---|---|---|
| UI | SwiftUI | 原生、开发快 |
| PDF 渲染 | **自研页图流 `PageStreamView`**（SwiftUI `ScrollView` + 按页 `PDFPage.draw(.mediaBox)` 出图；仍用 PDFKit 的 `PDFDocument`/`PDFPage` 做解析与栅格化，只弃 `PDFView`） | `PDFView` 与 macOS 26 Liquid Glass safe-area/浮动侧栏不兼容（`PDFClipView` 私有居中缺陷，页面恒偏左，无公开 API 可修）。自绘换来原生玻璃观感 + 跨平台页图流统一；代价：文本选择/搜索另补（已完成，见 `TODO.md` §T1/T2） |
| 本地存储 | SwiftData | Document / Group / Note 三张表，hash 唯一键 |
| 手写笔画 | 自定义笔画模型（点 + 压感 + 时间偏移，Codable）+ 自绘 overlay | 需压感变宽 → 自绘渲染；若放弃压感可退回 PDFKit ink 注解（缩放/坐标全自动） |
| 局域网服务 | Network framework (`NWListener` + `NWProtocolWebSocket`) | WS 握手/分帧系统内置；另写极简 HTTP 响应分发网页与页面图，不引入 Vapor |
| 平板端 | 纯 HTML/JS 网页（Canvas + Pointer Events + WebSocket） | 免安装，跨平台 |

## 4. 风险点

1. **坐标映射**（已降级）：平板显示页面图后，改用归一化页面坐标 (0~1) → `归一化 × page.bounds` 得 PDF 页面点，与 Mac 缩放/视口解耦；主要注意 Retina DPI 与页面旋转 `page.rotation`
2. **同步延迟**：局域网 + 点合批（10~20ms 一批）+ 平板本地即时落墨，满足手写跟手性
3. **笔记失联**：文件内容修改导致 hash 变化时，需 UI 提示重关联
4. **大文件 hash 性能**：分块读取 + 后台线程；缓存 `(path,size,mtime)→hash` 避免重复计算
5. **Local Network 授权**（macOS 15）：首次启动 server 会弹隐私授权，需处理未授权引导态
6. **配对安全**：QR / 短码携带 token，作为 WebSocket 准入校验，防止同网段他人接入
7. **视口同步带宽**：滚动逐帧传整页图会卡 → 只传「窗口内页面」图并缓存，平板本地滚动，仅回传归一化偏移
8. **hover 依浏览器**：Chrome 不转发笔悬停，**Firefox 可以** → 目标浏览器定为 Firefox，悬停预览可实现；圆环画在同坐标系 overlay 避免偏移
9. **笔迹平滑**：Firefox 采样率偏低，直线连点折角明显 → 落墨用曲线平滑（二次贝塞尔中点法 / Catmull-Rom），采集页与 Mac 渲染均需处理

## 5. 复杂度评估

**中等**。单机部分（文件记录分组 + 文字注解 + AI 会话绑定）较简单；约 70% 工作量集中在平板同步链路与手写渲染。

## 6. 开发进度（里程碑）

- ✅ **Step 0 spike**：触控笔能力实测（压感 / 防误触 / 合批 / 侧键翻页 / Firefox hover），测试页 `spike/pen-test.html`
- ✅ **M1 单机骨架**：xcodegen 工程、PDFKit 阅读、SHA-256 去重入库、SwiftData 四表、中英双语 —— 编译通过
- 🚧 **M2 局域网手写链路**
  - ✅ 步骤 1：HTTP(8770) + WebSocket(8771) 服务、token 鉴权、二维码配对、采集页、控制面板
  - ✅ 步骤 2：推当前页 PNG + 采集页显示 + 本地平滑落墨 + 防误触 + 悬停 + 归一化回传 + 翻页联动
  - ✅ 步骤 2.5：工具/模式（PageUp 切模式、PageDown 切笔）、可见边框、**WS 延迟显示**
  - 🚧 **S1 地基：多窗口 + 共享 WS**
    - ✅ S1a：服务改 App 级单例（`AppModel`）；多窗口会话注册表（`DocSession`）；平板跟随最后激活窗口；⌘N 新窗口 / ⌘O 打开（仅 key 窗口响应）
    - ✅ S1b：平板顶栏文档下拉列表（`selectDoc` / `docs` 广播），可手动切到任一打开的 PDF 或「⟳ 跟随 Mac」
  - 🚧 **S2 铺满与滚动**（架构定为**方案 B：桌面权威流转**）
    - ✅ S2a：平板**宽度铺满**（fit-width）+ 手指竖向滚动 + 墨迹随滚动重绘 + 右上角**全屏**按钮
    - ✅ S2b-1：`PadRenderer`（桌面按宽度做 fit-width 连续布局、渲染任意视口条带、视口↔(页,归一化)换算）+ **模拟平板窗口**（滚轮连续滚动、鼠标当笔，走共用落墨 API，Mac 主窗口同步显示）
    - ⬜ S2b-2：把 `PadRenderer` 条带**流转给真平板**（缓冲本地滚动 + progressive 多清晰度）；平板回传滚动/落墨
    - 🚧 S2b-3：**锚点同步**（文档位置=页+页内比例为唯一真相，连续镜像）
      - ✅ 双向：模拟窗口 ↔ Mac 主窗口连续同步滚动（origin 标记 + 0.3s 抑制窗防回环）
      - ⬜ 真平板接入同一锚点通道
  - ✅ **S3 实时渲染**：平板 `ink`/`erase` → Mac `InkOverlayView` 叠加渲染（压感变宽 + 笔色 + 擦除），随缩放/滚动重绘对齐。
  - ✅ **S3.5 笔迹持久化**（2026-07-20）：落工作区 SQLite `note` 表（kind=2，一笔=一行，`note.id==stroke.id`，page/归一化 anchor 走列，payload=JSON `{color,width,points[[x,y,pressure]]}`；**弃 SwiftData**）。`ContentView` `.onChange(session.strokes)` 增量对账 upsert/delete，重开 `loadInk` 恢复。测试 `spike/ink-store-test.swift` 21/21。
  - ⬜ **S5 长按切笔手势**：重压 + 静止 >2s；Mac 笔尖处进度环（>300ms 起）+ 切笔工具；那一笔**预测性立即清除**
- ✅ **阅读区页图流 v2**（2026-07-20 重写完成，编译通过 + 4 组 spike 全绿，待用户真机手感验证）：v1 因缩放跳位/闪烁被删；v2 纯 SwiftUI 重写（`PageStreamView`+`PageLayout`+`PageBitmap`+`PageRenderEngine`+tick 版 `ScrollFollower`），pinch 双相锚定缩放、⌘±/⌘0、resize 冻结+原子 refit、自研虚拟化、高倍贴片、后台渲染+预缓存。设计与 spike 实测结论见 `PDF-VIEWER-REBUILD-PLAN.md`。
- ✅ **文字搜索 / 文字选择 / 扫描版 OCR**（2026-07-21 完成）：选择走 PDFKit 原生选择引擎（`PageGeometry.swift`），搜索复用 `PDFDocument.findString`（`TextSearch.swift`），OCR 接 Paddle PP-OCRv6（`PaddleOCR.swift`，`ocr_page` 缓存表 schema v3）。详见 `TODO.md` §T1/T2、§T3。
- ⬜ **M3 三种笔记**：文字注解 / 手写笔记的编辑与渲染、重定位提示（原「会话笔记」一栏已由 **AI 会话绑定**取代并于 2026-08-25 落地，见 `AI-PLAN.md`）

## 7. 客户端页面显示与数据流（方案 B 现状，2026-07-20 对齐）

平板 canvas 显示 PDF 的完整流程与数据传输：

1. **布局元数据 `layout`（WS，低频）**：Mac 推整份文档「每页原始宽高数组 `pages:[[w,h],…]` + 页数 + docId/版本」。数据量：每页 2 个数，几百页 ≈ 几 KB，**仅文档切换时推一次**。
2. **平板本地连续布局**：收到 layout 后，按 fit-width 算每页显示高度（屏宽 × h/w）累加成一条可滚动页面列。滚动/缩放纯本地重绘，不回传图。
3. **页图按需取（HTTP）**：平板只对「可见 + 上下各一屏预取」的页发 `GET /page.png?i=N&v=版本`；Mac `renderPage` 渲染该页 PNG（宽 1600px，带 `NSCache`）返回，平板 `Image` 缓存复用。数据量：每页 PNG ≈ 0.5~1.5MB，只取窗口附近几页，滚动增量取、旧页留缓存。
4. **合成**：`#bg` canvas 按当前 scrollY/zoom 把已加载页图 drawImage 到位（未加载画灰底占位）；`#ink` 上层画墨迹、`#hover` 画笔尖圆环，均不随夜间反转。
5. **高频小包**：`scroll`/`viewport` 锚点（几十字节，rAF ~60/s）、`ink`/`erase`（合批 ~60/s）、`hover`（节流）、`ping/pong`（1s 心跳）。

**要点**：滚动/缩放**不逐帧传图**，只传几十字节锚点；页图进视口才取一次并缓存 → 带宽友好。粗估：连续浏览 10 页 ≈ 首次 5~15MB 页图，之后缓存命中 0 传输；锚点/心跳可忽略。

## 8. 工作区文件夹持久化（2026-07-20 定方案，首版已实现）

> 目标：一个**可移动文件夹 = 一个工作区**，替代「分组」。放移动硬盘上即可两台电脑/未来独立 app 复用同一套数据。

- **文件夹 = 工作区 = 一套相关 PDF**（原「分组」/`LibraryGroup` 已取消，工作区天然就是分组；§1.1 的「自定义分组」以此替代。2026-08-21 起工作区内另加**一级分组** `document.group_name` 做快速筛选，见 §8 schema v11——粒度在库内，不替代工作区）。**2026-07-28 起工作区文件夹为 `.unrd` 包**（UTI `tech.xvanturing.unireader.workspace`，conforms to `com.apple.package`，声明在 `Sources/Info.plist`）：Finder 显示为单文件、双击交给 UniReader 打开（路由见 §8.1）。**旧无扩展名工作区首次打开时原地改名迁移**为 `<工作区名>.unrd`（`WorkspaceManager.migrateToPackageIfNeeded`，只 rename 不动内容；工作区内改名也联动改包名，保持「包名 == 工作区名.unrd」）。包内布局不变（`UniReader/library.sqlite`、`PDFs/`），跨平台侧把 `.unrd` 当普通目录即可。
- **不直接存 PDF 本体**，只记录每个文档的「多个可能路径」（移动/复制后自动探测有效路径）。
- **一个文档可配多个文件 / 多个 hash**：给 PDF 加了 TOC → hash 变但页面内容一致 → 视为同一文档的多个版本（variant），笔记通用。

**已定决策（2026-07-20）：**
| 项 | 选择 | 理由 |
|---|---|---|
| 存储格式 | **自有 schema 的单个 SQLite**（`<工作区>/UniReader/library.sqlite`，无第三方依赖，用系统 libsqlite3） | **确定要做 Windows/Android 版**，数据须跨平台可读 → 排除 SwiftData/Core Data 不透明 schema；SQLite 全平台原生可读、ACID 保一致性、单文件易移动。已用 `sqlite3` CLI 验证可直读 |
| 多 hash 模型 | **document → variant(hash) → location(path)** 三层；notes 挂 document（按 page + 归一化锚点，版本无关） | 加 TOC = 新 variant，笔记全版本共用；打开时跨 variant 探测有效路径 |
| 多 hash 关联 | **手动**「关联为同一文档」（`LibraryStore.linkVariant` 已就绪，UI 待补）——hash 变了无法自动判定同一文档 | — |
| 工作区切换 | 侧栏文件夹菜单：**「打开工作区…」与「新建工作区…」严格分离**（2026-07-28）——打开时 `NSOpenPanel` 只认已存在的 `.unrd` 包（`canChooseDirectories=false`、无 `canCreateDirectories`），选中的文件夹若不含 `UniReader/library.sqlite` 会报错而非静默建空库（`WorkspaceManager.validate`）；新建走 `createWorkspace(at:)`，`NSSavePanel` 选位置+起名现场创建全新包。最近工作区同走 `validate` 校验；最近列表存**本机** UserDefaults，不进文件夹。**2026-07-29 起「切换」的语义 = 开一个属于该工作区的窗口**（见 §8.1），不再替换当前窗口 | 此前「打开」面板混用选择/创建/选目录，误选到无关或空文件夹会被静默建成一个新空库（表现为「打开工作区却看到空的」） |
| 多工作区并存 | **一个 `WorkspaceManager` 实例 = 一个工作区**，窗口级；实例由 `WorkspaceRegistry` 按路径分配（2026-07-29，详见 §8.1） | 原先是 App 级单例、靠换 `folder` 切工作区 → 双击另一个 `.unrd` 会把**所有**窗口一起换掉 |

**Schema v9（跨平台契约，见 `Sources/Store/`）：**
`meta(key,value)` · `document(id,title,page_count,added_at,last_opened_at,sort_order,read_page,read_frac,…,group_name)` · `variant(id,document_id→,content_hash UNIQUE,page_count,added_at)` · `location(id,variant_id→,path,is_valid,last_validated_at,in_workspace,is_relative)` · `note(id,document_id→,kind,page,anchor_x/y/w/h,payload BLOB=JSON,created_at,updated_at)` · **`ocr_page(content_hash,page,provider, payload BLOB=JSON,lang,created_at)` PK(content_hash,page,provider)**（v3 新增，扫描页 OCR 结果缓存；payload=`{w,h,runs:[{text,x,y,w,h}]}` 归一化 0~1）。时间戳 ISO-8601 文本、id UUID、payload JSON。**无 macOS security-scoped bookmark**（不跨平台）。`in_workspace=1` 时 `location.path` 为**工作区相对路径**。`is_relative=1`（v6 新增）：外部文件（未拷入工作区）但与工作区文件夹同属一块**可移动/外置卷**（`volumeIsInternal==false`，如移动硬盘/外置 SSD）时，`path` 也存**相对工作区文件夹的路径**（可含 `..`）——换电脑/换挂载点（`/Volumes/X` 变 `/Volumes/X 1`）仍可解析；系统内置盘不做此处理（挂载点稳定，绝对路径已足够，且避免「只挪工作区不挪源文件」时反而失效）。**`scratch_pad(id,document_id→,title,anchor_page,anchor_x,anchor_y,bg,pattern,created_at,updated_at)`**（v8 新增，草稿纸；`pattern`（v9）= 底纹 plain/dots/grid；挂逻辑文档、全版本共用，同 note/ink_layer。锚点＝创建时所在页 + 页内归一化点，`bg` 为 CSS `rgba(...)` 串）。草稿纸上的笔迹**不另建表**，仍在 `note` 但 `kind=4`、`page` 恒 0、payload 里带 `padId` 指回 `scratch_pad`，且点集是**画布坐标（逻辑点，可负无界）**而不是页内 0~1 归一化——坐标系契约见 `PROTOCOL.md §4.4`。**视口（滚动/缩放）刻意不落库**：三端各自独立，存了就变成「谁最后关谁说了算」的跨端争用。迁移：`meta.schema_version` + `ADD COLUMN IF missing` / `CREATE TABLE IF NOT EXISTS`（v1→v2、v2→v3、v7→v8、v8→v9 均已验证：`spike/store-test.swift` 32/32、`spike/ocr-store-test.swift` 15/15、`spike/scratch-store-test.swift` 44/44）。**v11（2026-08-21）**：`document.group_name TEXT NOT NULL DEFAULT ''`——工作区内**一级分组**（空串=未分组；刻意不建分组表：分组无独立元数据、按名字排序，整组改名/解散就是一条 `UPDATE document SET group_name=? WHERE group_name=?`；侧栏按分组分段 + 右键移动）。安卓端 `SELECT *` 忽略未知列，读取零改动兼容（分组 UI 未实现，见 `TODO.md` Backlog；`spike/store-test.swift` 38/38）。

**已实现**：`SQLite.swift`（libsqlite3 薄封装）+ `LibraryStore.swift`（建表/迁移/`findOrCreate` 去重/`mergeDocument`+`linkVariant`/`addVariant`/`add·removeLocation`/`updateProgress`/notes CRUD）+ `WorkspaceManager`（当前工作区、最近列表、导入、打开探测路径优先工作区副本、进度存取、复制/移出工作区、重定位、合并）；SwiftData 整套移除。UI：侧栏工作区切换 + **重命名**、文档右键 **复制到工作区/从工作区删除**、**关联为同一文档**（合并，带确认）、路径失效 **重新关联文件** 提示；**阅读进度**自动记录并重开恢复（切文档/关窗/滚动节流各存一次）。运行时验证：建库/schema/meta/WAL、v1→v2 迁移、32/32 DAO 测试（`spike/store-test.swift`）。
**待补**：① 旧 SwiftData 数据不迁移（全新开始，需重新导入）；② ✅ 手写笔迹已写入 `note` 表（kind=2，payload=JSON `InkStroke`；2026-07-20，见 §6 S3.5）；③ 合并的「拆分」逆操作暂无。

---

## 8.1 窗口 ↔ 工作区（多工作区并存，2026-07-29 定方案并实现）

> 用户定的行为：**双击另一个 `.unrd` = 新开一个窗口显示它，原有窗口纹丝不动**（Xcode/VS Code 打开另一个项目的手感）。
> 此前是 App 级单例，切工作区会把所有窗口一起换掉。

### 所有权模型

| 角色 | 职责 |
|---|---|
| `WorkspaceRegistry`（App 级单例） | 工作区实例池：**按路径分配 `WorkspaceManager`，同一路径全 app 只有一个实例**（池**弱持有**，强引用在窗口那边）。另持有本机全局状态：最近工作区列表、上次工作区、窗口↔工作区登记、`claimRestore` 闸 |
| `WorkspaceManager`（窗口级，可被多窗口共享） | **一个实例 = 一个工作区**，持有它的 `LibraryStore`。实例建好即绑定，**没有「换 folder」这条路** |
| `RootView`（每个窗口的根） | 决定本窗口归属哪个工作区，领到实例后 `.environmentObject` 注入子树 |
| `ContentView` 及下游 | 照旧 `@EnvironmentObject var workspace`，**因窗口而异**。侧栏/Inspector/阅读区的既有用法一行未改 |

**🔴 红线：同一工作区路径必须共享同一个 `WorkspaceManager` 实例。**
`LibraryStore` 是单 SQLite 连接、非线程安全，且笔迹/注解/高亮的落库走「内存快照 ↔ 库」增量对账
（`persistedStrokes`/`persistedTextNotes` 那套）。同一个库若开出两个 store，两份快照互不知情，
后写的一方会把先写的成果整段判为「已删除」而清库 —— **直接丢笔记**。这是数据安全约束，不是性能优化。
所以「同一工作区开多个窗口」（⌘N、在新窗口打开文档）走的是同一个实例。

**池按弱引用登记**（2026-07-29 加固）：强引用在 `RootView` 的 `@State`。早先是强引用 + 「计数归零就把
条目摘掉」，但那一刻旧实例**还活着**（SwiftUI 关窗后 `@State` 释放是延后的，`ContentView` 的尾随进度
补存最长还能再写 0.7s），这段空窗里同路径若被重新打开，就会给同一个库开出第二个 `LibraryStore` ——
正是红线禁止的状态。配套：`ContentView.onDisappear` 主动 `cancel()` 尾随补存任务（关窗本身紧接着同步
存一次，不丢进度）。

⚠️ 记一笔：唯一性登记挂在 `WorkspaceManager` 上，而真正必须唯一的是它的 `LibraryStore` —— `DocSession`
（OCR 缓存读写）也**强持有**同一个 store。目前两者都是窗口级、同时析构，所以等价；将来若让 store escape
到别处（后台任务、跨窗口缓存），唯一性就要改挂到 store 本身。

### 🔴 关掉工作区 = 当场放掉它的所有文件引用（2026-08-05，可移动硬盘弹不出去）

用户报：工作区放在移动硬盘上，**关掉窗口后 Finder 仍说「磁盘正在使用中」，必须退出整个 app 才能弹**。
根因不是某一处泄漏，而是**整条链路都在依赖 ARC 的时机**：`WorkspaceManager`→`LibraryStore`→SQLite 的
fd、`DocSession.pdf`/OCR 渲染副本这两份 `PDFDocument`，强引用全在 SwiftUI 的 `@State`/`@StateObject` 里，
关窗后何时释放**没有任何保证**；再加上 `AppModel.padRenderPDF` 是 App 级单例持有的第三份 PDF，压根不随
窗口走。只要还有一个 fd 开着，整块盘就弹不掉。

于是「关闭」改成**显式动作**，三处各自负责，缺一不可：

| 谁 | 放掉什么 | 触发点 |
|---|---|---|
| `DocSession.teardown()` | 阅读区 PDF + OCR 渲染副本 + 库引用 + 在途网络 OCR 任务（它们捕获着那份 PDF） | `ContentView.onDisappear` 末尾 |
| `WorkspaceManager.teardown()` | `LibraryStore.close()` → `sqlite3_close_v2`，`store` 置 nil（之后所有读写自动 no-op） | `WorkspaceRegistry.maybeTeardown` |
| `AppModel.releasePadRenderIfUnused()` | 平板渲染用的那份独立 `PDFDocument` + 页图缓存 | `unregister`（该书已无窗口在看时） |

**关库的时机由两个触发点合判**（`releaseKey` 与 `noteWindow(_:nil)` 都调 `maybeTeardown`，条件 =
「retain 归零」+「`windowPaths` 里没这条路径」）：AppKit 的 `willClose` 与 SwiftUI 的 `onDisappear`
**没有保证的先后**，而这两项恰好分别由这两条路清零，后发生的那一个才同时满足「窗口没了」+「该窗口的
最后一次写库（进度 / 打开集，都在 `onDisappear` 里同步完成）已落地」。**早关一步 = 静默丢进度。**

配套：`maybeTeardown` 会把池条目摘掉（连接已关、`store` 已 nil，旧实例再也写不进库 —— 红线约束的是
**活着的连接**，不是活着的实例），所以同路径重新打开时新建的实例仍是该库唯一的连接。

⚠️ **`DocSession.teardown` 严禁碰 `strokes`/`inkLayers`/`textNotes`/`highlights`**：那四个的落库是
`ContentView` 里的 `onChange` 增量对账，清空 = 对账认定「用户删光了」→ 把整篇笔记从库里删掉。
teardown 只碰文件引用。

诊断：teardown 后 2s 各查一次 weak 探针，`PDFDocument` 或 manager 仍存活就写 `wsLog`（默认关闭的通道，
见下文「诊断通道」）—— 这类「以为放掉了其实没放」正是只能靠打点发现的静默失效。

### 🔴 「窗口关闭」只能听 AppKit 的 `willClose`，不能用 SwiftUI 的 `onDisappear`

2026-07-29 实测（日志钉死）：`RootView` 的 `onDisappear` 在**窗口建立过程中就会空放一次**
（那时 `workspace` 还没绑定），真正关窗时再放一次。任何「一次性」的关窗处理都会被第一下烧掉：

```
17:01:47 RootView.onDisappear：released=false workspace=nil        ← 窗口刚建，空放
17:01:50 RootView.onDisappear：released=true  workspace=工作区测试2  ← 真关窗，被自己的幂等标志挡住
17:01:52 acquire：复用实例 retain=2                                  ← 引用计数从没减过
17:01:52 claimRestore = false → 留空窗口                             ← 记号没还回来
```

后果就是「关掉某工作区的全部窗口，再打开它 → 空窗口」。**为防重复释放加的幂等标志，反而制造了永久漏释放。**
现在关窗信号统一走 `WindowLifecycle`（`NSWindow.willCloseNotification`，每个窗口只发一次、就在关闭那刻），
`RootView` 不再有 `onDisappear`。两个配套约定：

- 关闭回调**只捕获不会变的 `windowId`**；「这个窗口持有哪个工作区」记在 registry（`bindRootWindow`），
  由 `closeRootWindow(id)` 去放手 —— 闭包在挂载时就定型，捕获 `workspace` 会拿到绑定前的旧值（nil）。
- `RootView` 的分支不用 `Group` 包（Group 会把外层修饰符逐个下发给分支，生命周期钩子容易跟着分支切换空放），
  改成 `@ViewBuilder` 计算属性。

### 窗口归属的决定顺序（`RootView.resolve`）

1. `WindowTarget.workspacePath` —— 显式指定（双击开的新窗口、「在新窗口打开文档」、⌘N）；
2. `AppDelegate.pendingWorkspacePath` —— 双击 `.unrd` 冷启动拉起 app 的那一下；
3. 上次使用的工作区（普通启动）。

**1、2 必须过 `WorkspaceManager.validate`，3 不校验。** 1、2 都是用户指着一个具体工作区说「打开它」，
和热启动的 `routeToWorkspace` 是同一件事，就得同一种严格；否则同一个双击手势会因 app 当时开没开而
两种结果 —— 热启动弹「这不是工作区」，冷启动却在那个包里**静默建一个空库**（`LibraryStore` 缺库即建），
正是 §8「打开/新建严格分离」要根除的表现。校验失败时 `RootView` 显示错误态而不是开一个假工作区。
3 是兜底，首次启动全靠它在默认位置建库，天然不能校验。

**⚠️ 第 2 条必须等到 `applicationDidFinishLaunching` 之后才能判定**（实测日志钉死的时序）：

```
ContentView/RootView.onAppear   ← SwiftUI 建窗口，最早
application(_:open:)            ← 双击带来的文档事件，之后才到
applicationDidFinishLaunching   ← AppKit 保证 open 事件在它之前投递完
```

在 `onAppear` 里就判定的话，缓冲还是空的 → 落到第 3 条打开**上一个**工作区，事件到达后再切走，
用户能看到明显的来回切换。故 `onAppear` 时若启动尚未完成就**挂起不决定**，等 `didFinishLaunching` 通知再来一次。

另一个同源的坑：**`isKeyWindow` 在冷启动时全为假**（由 `WindowAccessor` 异步回填），
凡是 `if isKeyWindow { 处理 }` 的分发都会被所有窗口一起跳过 = 请求静默丢弃。
热启动的双击路由改用「谁 `consumePendingWorkspace()` 抢到谁处理」——消费是一次性的且都在主线程，天然选出唯一认领者。

### 「打开工作区」的统一路由（`WorkspaceRegistry.route`）

双击 `.unrd` / 侧栏「打开工作区…」/ 最近工作区 / Dock 菜单，**全部等价于**：
校验（`WorkspaceManager.validate`，只查文件系统不建实例）→ 该工作区**已有窗口就激活它**，否则 `openWindow(value:)` 开新窗口。

**这件事是 app 级的，不能挂在某个窗口的 `ContentView` 上**（2026-07-29 实测踩到，一度就挂在那儿）：
屏幕上只剩一个「打不开工作区」的错误态窗口时，那个窗口**没有 `ContentView`**，于是全 app 没有任何
订阅者，双击请求被**静默丢弃**（`pendingWorkspacePath` 还留着陈旧值，会污染下一个窗口）。
现在决策逻辑只有 registry 这一份，热启动的通知订阅挂在 `RootView`（每个窗口都有，错误窗也有），
`openWindow` 只能从视图环境取，由调用方带进来。零窗口时无人订阅也不会丢：那种情况下激活带来的
空窗口不会被判为幻影（屏上没有其它窗口），它自己 `resolve` 时就把缓冲消费掉了。

**「新建工作区…」不覆盖已有工作区**：`NSSavePanel` 那句系统「替换」确认在用户眼里是「替换一个文件」，
真按它删下去却是连笔记一起删掉一整个库；多窗口之后那个目标还可能正被另一个窗口开着（连接活着、
目录被抽走 = 僵尸窗口）。故目标已含 `UniReader/library.sqlite` 时报 `alreadyAWorkspace` 让用户改名或改走
「打开」，只有同名的普通文件/文件夹才按面板确认过的语义覆盖。建包只建目录 + 建库，**不建 manager**
（实例一律由 `acquire` 在新窗口里分配）。

`restoreSession`（恢复上次打开的整组文档）**每个工作区只做一次**（`WorkspaceRegistry.claimRestore`）。
不设这道闸会连锁开窗：`restoreSession` 自己会 `openWindow`，而每个新窗口的 `ContentView` 又会再恢复一遍。
（原先靠 App 级 `didRestoreInitial` 挡着，改成多工作区后那个标志失效。）
这道闸**挂在池的生命周期上**：某工作区的窗口数归零时把记号还回去。否则同一次运行里关掉它的全部窗口
再打开，会得到一个空窗口 —— 而「打开集」在关最后一个窗口时是特意保留的（`WorkspaceManager.closeWindow`），
两边的时间尺度必须一致。

⌘N 由本 app 接管（`CommandGroup(replacing: .newItem)` → `.newWindowRequested`）：
系统默认那个开出来的窗口不带工作区，会跑去开「上次使用的工作区」而非当前这个。

### 🐛 SwiftUI 会凭空多开一个空窗口（未根治，已识别并关闭）

**现象**：app 每次被激活（双击 `.unrd` 必然激活），SwiftUI 都会额外开一个 `value == nil` 的 `WindowGroup` 窗口。
一次双击 = 两个窗口。

**已逐一排除**（都不是原因，别再往这些方向查）：

| 怀疑 | 排除依据 |
|---|---|
| `applicationShouldHandleReopen` | 该回调**压根没被调用**（SwiftUI 自己处理了重新打开，不转发给 delegate） |
| `NSDocumentController`（Dock 最近文稿引入） | `applicationShouldOpenUntitledFile` 同样没被调用 |
| `WindowGroup` 的 `defaultValue` | 去掉后照样出现 |
| 系统窗口状态恢复 | 那些窗口 `isRestorable=false`，identifier 形如 `SwiftUI.PresentedWindowContent<…>-AppWindow-N`；`.restorationBehavior(.disabled)` 加了也无效 |

**当前处理**（补丁，非根治）：`RootView` 识别并关掉它。两个关键实现细节，都是踩出来的：

- **判定必须在 body 求值时**（`isStrayWindow` 计算属性），**不能放 `onAppear`** —— onAppear 是窗口**显示之后**才调用的，那时已上屏，再关就是用户看到的「闪一下」。判定条件：尚未绑定工作区 + 不是错误态 + `target.workspacePath == nil` + 启动已完成 + **屏幕上已经有本 app 的其它窗口**（`WorkspaceRegistry.hasOtherRootWindow`）。用户开窗的两条路都显式带路径，不会误伤；冷启动第一个窗口那时 `didFinishLaunching` 还是假，也不会命中。
- **最后一条判据必须是「有没有其它窗口」这个直接量**，早先写的是「它要落到的那个工作区已有窗口」——间接量，会漏：2026-07-29 实测双击一个坏包后屏幕上只剩错误窗，「上次工作区」确实没有窗口，于是幻影窗口没被认出来、**转正成了一个用户根本没要的「上次工作区」窗口**。两处要点：① 计数要**排除自己**（`onAppear` 登记在前、`didFinishLaunching` 那轮判定在后，不排除的话冷启动第一个窗口会数到自己而自杀）；② 登记由 `RootView` 做且**错误态窗口也算**（不能拿 `ContentView` 维护的 `windowPaths` 代替 —— 错误窗不在那张表里，正是这次漏判的原因）。改成直接量后，`isStrayWindow` 也不再和 `resolve` 各写一套「本窗口会落到哪个工作区」的预测。
- **关窗要赶在窗口上屏之前**：`WindowCloser` 在 `viewWillMove(toWindow:)`（比 `viewDidMoveToWindow` 更早）就把 `alphaValue = 0` + `animationBehavior = .none` 设上 —— 窗口的出现动画由 CoreAnimation 驱动，只靠 `orderOut` 追不上，会被瞥见窗口底边冒出来一截。另外**不能给它 `.frame(width: 0, height: 0)`**：零尺寸时 SwiftUI 根本不创建那个 NSView，`viewDidMoveToWindow` 永不触发，窗口就留在屏幕上了。

**还没试过的一条根治线索**：每个真窗口都带着非 nil 的 `WindowTarget`，而 `RootView` 从不把解析结果写回
`$target` —— 从 SwiftUI 视角「没有任何窗口持有本 group 的默认值（nil）」，激活时补一个正好符合现象。
两个可测的实验：① `RootView` 把解析出的路径写回 `$target`（窗口 value = 它的真实身份）；若假设成立空窗口消失，
附带好处是 `openWindow(value:)` 原生就会「已有同 value 窗口则前置」，`windowPaths`/`activateWindow` 那套能瘦一圈。
② `.defaultLaunchBehavior(.suppressed)`（macOS 15+，本项目 target 26.0 可用）彻底不让 SwiftUI 自作主张开窗，
首个窗口由 app 层显式开 —— 顺带能消掉 `resolve` 里「挂起等 `didFinishLaunching`」那段时序体操。**都需实机验证。**

### Dock 右键「最近的工作区」

两套机制**各管一半场景**，都要接：

- **app 运行时** → `AppDelegate.applicationDockMenu`，用 registry 那份列表，点击走与双击 `.unrd` 相同的路由；
- **app 未运行时** → 上面那个方法根本不会被调用，Dock 显示的是系统维护的「最近使用的文稿」，
  由 `NSDocumentController.noteNewRecentDocumentURL` 喂（`WorkspaceRegistry.rememberRecent`；
  registry 初始化时会把已有列表**倒序补喂一次**，否则老用户升级后未运行时的 Dock 右键是空的）。
  点击它走 `application(_:open:)`，即冷启动路径。顺带「文件 → 打开最近使用」也有了内容。

### 已知边界（不是 bug，是还没做／没定）

- **重启只恢复最后一个工作区**：持久化的只有 `lastWorkspacePath` + 每个工作区自己的「打开集」。
  A、B 两个工作区开着 ⌘Q，下次启动只回来 B（及其文档窗口）。对齐 Xcode/VS Code 的手感需要再存一份
  「上次开着的工作区集合」，`didFinishLaunching` 后逐个开窗 —— **待定**。
- **同工作区开了多个窗口时，「已有窗口就激活它」激活的是任意一个**（`windowPaths.first(where:)` 走字典序）。
  应改成「最近成为 key 的那个」（key 变化 `ContentView` 已在追）。
- **打不开的工作区给的是一个死胡同窗口**：`RootView` 的错误态只有一句说明，没有「打开其它工作区…」
  之类的出路，用户只能关掉窗口重来。（2026-07-29 用户定：暂不补。）
- **零窗口时双击「非上次」的那个工作区，可能多出一个窗口**（推演，未实测）：app 在跑但窗口全关掉时
  双击 C，激活先于 open 事件到达 —— 那一刻缓冲还是空的，被转正的幻影窗口会落到第 ③ 条「上次工作区」
  开出 A，随后 open 事件才把 C 路由出来，于是屏上是 A + C。验法：关光全部窗口后
  `open -a <app> <另一个工作区>`，看是否冒出两个窗口。

### 诊断通道

这条链路横跨 LaunchServices → AppDelegate → 通知 → RootView → ContentView，任一环静默断掉都只表现为
「双击没反应」，为此改错过三轮。`wsLog()` 打点常驻代码，**默认关闭**，只在日志文件已存在时才写：

```
touch ~/Library/Logs/UniReader-ws.log    # 开启
rm    ~/Library/Logs/UniReader-ws.log    # 关闭
```

⚠️ 别指望 unified logging：实测 `log show`/`log stream` 抓不到本 app 的任何输出（按进程过滤零条，
连系统框架日志都没有），双击启动的 app 也不挂在 Xcode 控制台下，`print` 同样看不到。
