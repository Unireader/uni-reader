# ANIM-BLOCK-PLAN — 笔记里的分步演示（```anim 块）

> 2026-11-13。用户：「学习的时候有时需要可视化的教程、动态演示……比如对比数据链路层可靠传输的几种方案：停等、滑动窗口、回退 N 步、选择重传；或者数据结构的可视化。」
> 拍板：**自绘画布 + DSL**（不用 WebKit 显示 Agent 生成的 HTML）。
> 2026-11-13 用户确认方案与 §0 三条默认，A1 已写（实现记录见 §7）。

## 0. 已按默认处理、待用户确认的三件事

| 问题 | 默认 | 理由 |
|---|---|---|
| 放在哪 | 只放在 Markdown 笔记里（和 ```grapher 块一样） | 文字即真源，同步、搜索、Obsidian 都不受影响；PDF 页面上的批注以后再说 |
| 安卓 / 网页阅读器 | 第一阶段只显示文字 | 与 grapher 块同样处理；写法定稳后再各自实现渲染 |
| HTML 备用通道（```html 块 + WKWebView） | 不做 | 与「App 不带网页」的约定冲突；等 DSL 确实不够用再议 |

## 1. 它是什么

Markdown 笔记里写一个语言为 `anim` 的围栏块，里面是几十行文字：先声明场景里有什么（时序图、序号条、数组、树……），
再写一步步发生了什么。App 把它画成一块**可以逐步播放的演示**：

- **光标不在块里**：源码折起来，显示成一张图（第 1 步的画面 + 底下一行步骤说明 + 控制条的位置）。
- **实时视图**盖在图上（同 grapher 的覆盖层做法）：控制条一直可见——上一步 / 播放·暂停 / 下一步、进度滑块（按步对齐）、
  播放速度；点画布空白处 = 下一步；键盘 ← → 空格（视图有焦点时）。步与步之间的变化做成补间动画（位置、颜色、出现 / 消失）。
- **「编辑文字」**把光标放进块里，源码露出来；光标出来图又盖上。
- **文字是唯一真源**：文件里就是这几行字；Obsidian、安卓、网页阅读器里看到的是普通代码块。
- 写错的行：能跳过的跳过并在图下方列出「第 n 行：原因」；整块都解析不了时显示一张只有错误列表的图（不退回成代码块，免得用户不知道为什么）。

Agent 侧：MCP `get_anim_reference` 给写法全文，`render_anim` 把文字画成图（可指定第几步，或一次出所有步的缩略图）并按行报错，
写完先自查再 `edit_markdown` 写进笔记。另配 skill `skills/unireader-anim-block`。

## 2. 为什么是「语义级」DSL

绘图指令级（矩形、线、坐标）的 DSL 要 Agent 自己算坐标，容易重叠错位，风格也不统一。
这里的演示本质都是**离散状态一步步变化**，所以 DSL 只描述「有什么」「发生了什么」，**布局、配色、动画全由引擎决定**：

- 元素按声明顺序自上而下排（`row` 可以把几个元素横排）；元素内部的布局（树的层次、时序图的时间轴）引擎自动算。
- 颜色只有语义状态，不写色值：`normal` `active` `done` `wrong` `muted` `new`，映射到系统动态色（深浅色自动跟随）。
- 每一步的画面 = 初始状态依次执行前面所有动作后的结果（**纯函数**）；动画只是两步画面之间的插值。
  于是静态图、MCP 出图、实时播放、拖进度条跳到任意一步都是同一套代码，结果必然一致。

## 3. 写法（草案；实现后以 `AnimText.reference` 为准，MCP 原样提供）

### 3.1 总体

````
```anim
title 回退 N 步：窗口 4，帧 2 丢失
<元素声明…>

step <这一步的说明>
  <动作…>
step <说明>
  <动作…>
```
````

- 一行一条；`#` 后是注释；缩进只为好看，不影响含义（`step` 之后到下一个 `step` 之前的行都属于这一步）。
- 名字（元素名、节点名）：字母数字下划线或中文，不含空格；带空格的文字一律加双引号。
- `step` 之前的状态就是第 0 步（初始画面）。

### 3.2 元素（第一阶段）

| 声明 | 画出来 | 例 |
|---|---|---|
| `lanes A B …` | 时序图：几条竖线，时间向下走；消息是两线之间的斜箭头 | `lanes 发送方 接收方` |
| `seq S 0..7 window=4 [mod=8] [at=A]` | 序号条：一排格子 + 窗口框；`at=` 把它挂在某条竖线的上方 | `seq SW 0..7 window=4 at=发送方` |
| `array A = [3, 1, 4]` | 一排格子，下标在下方 | |
| `stack S = [a, b]` / `queue Q = [a, b]` | 竖着的栈（顶在上）/ 横着的队列（头在左） | |
| `var i = 0` | 一个带名字的小方框 | `var 期望序号 = 0` |
| `text "…"` | 一行说明文字 | |
| `row X Y …` | 把已声明的几个元素横排成一行 | `row SW RW` |

第二阶段再加：`list`（链表：`list L = a -> b -> c`）、`tree`（括号写法：`tree T = (8 (3 1 (6 4 7)) (10 _ 14))`，`_` 表示空孩子）、
`graph`（`graph G = A-B:4, B-C:2, A->C`）、`pointer`（指向数组下标 / 链表节点 / 树节点的箭头）、`grid`（二维表，动态规划用）。

### 3.3 动作

通用：

| 动作 | 含义 |
|---|---|
| `mark <目标> <状态>` | 改颜色状态；目标：`A[2]`、`A[1..3]`、`SW[5]`、`i`、某条消息的编号 |
| `unmark <目标>` | 回到 `normal` |
| `set <目标> = <值>` | 改值：`set A[2] = 9`、`set i = 3` |
| `swap A[i] A[j]` | 两格交换（动画是两个值互相换位） |
| `push S v` / `pop S` / `enqueue Q v` / `dequeue Q` | |
| `say "…"` | 画面上临时出现的一句提示（只在这一步） |

时序图 / 序号条：

| 动作 | 含义 |
|---|---|
| `send A -> B "DATA 2" [as=d2] [lost] [state=…]` | A 发一条消息给 B；同一步里的多条依次错开（流水线）；`lost` = 走到半路打叉 |
| `slide SW to=2` / `slide SW by=1` | 窗口框滑动 |
| `timer A "T2" start` / `stop` / `expire` | 竖线旁的计时器标记；`expire` 画成超时标志 |
| `deliver B "2"` / `discard B "3"` / `buffer B "3"` | 接收方交付 / 丢弃 / 缓存（画在竖线旁） |
| `note B "…" [state=…]` | 竖线旁的其他说明 |

一步的时间：时序图里每一步占一段纵向时间，本步发出的消息在本步内到达；想画「还在路上」的消息，用 `send … arrive=next`
（下一步才到）。这条规则让 Agent 不必算时间坐标。

### 3.4 对比：一块里放几个场景

````
```anim
title 三种方案对比：帧 2 丢失
scene 停等协议
  lanes 发送方 接收方
  step …
scene 回退 N 步
  lanes 发送方 接收方
  seq SW 0..7 window=4 at=发送方
  step …
scene 选择重传
  …
```
````

- 有 `scene` 时，每个场景自带元素与步骤；场景并排（宽度不够时上下排），**共用一套控制条**，按步号同时前进；
  步数少的场景停在最后一步。这正是「同一时刻 SR 只重发 2、GBN 重发 2~5」的对比方式——写的人负责让各场景的步一一对应。

### 3.5 完整示例（回退 N 步）

````
```anim
title 回退 N 步：窗口 4，帧 2 丢失
lanes 发送方 接收方
seq SW 0..7 window=4 at=发送方
var 期望序号 = 0

step 连续发出 0~3，不等确认
  send 发送方 -> 接收方 "0"
  send 发送方 -> 接收方 "1"
  send 发送方 -> 接收方 "2" lost
  send 发送方 -> 接收方 "3"
  timer 发送方 "T0" start
step 接收方收下 0、1 并确认；3 不是期望的 2，丢弃并重复确认 1
  deliver 接收方 "0"
  deliver 接收方 "1"
  set 期望序号 = 2
  discard 接收方 "3"
  send 接收方 -> 发送方 "ACK 0"
  send 接收方 -> 发送方 "ACK 1"
  send 接收方 -> 发送方 "ACK 1"
step 收到 ACK 1，窗口滑到 2~5，再发 4、5
  slide SW to=2
  send 发送方 -> 接收方 "4"
  send 发送方 -> 接收方 "5"
step 帧 2 超时：回退，2~5 全部重发
  timer 发送方 "T2" expire
  mark SW[2..5] active
  send 发送方 -> 接收方 "2"
  send 发送方 -> 接收方 "3"
  send 发送方 -> 接收方 "4"
  send 发送方 -> 接收方 "5"
```
````

### 3.6 套件（第三阶段，按需）

把常考题型写成一行展开成步骤、由引擎模拟保证结果正确，例如 `protocol gbn window=4 frames=8 lose=2 [lose-ack=…]`、
`sort quick A=[…]`。每个套件都是领域代码，**等某类内容反复出现再加**，第一阶段不做。

## 4. 实现

### 4.1 代码放哪

| 位置 | 内容 |
|---|---|
| `Sources/Anim/AnimText.swift` | 解析：文字 → 场景描述 + 按行的错误；`reference`（写法全文，MCP 直接给） |
| `Sources/Anim/AnimState.swift` | 状态与动作：`state(at: step)` 纯函数；动作作用到不存在的目标时报错（带行号） |
| `Sources/Anim/AnimLayout.swift` | 布局：状态 + 画布宽度 → 每个可见物件的位置大小（文字量宽经注入的测量函数，便于测试） |
| `Sources/Anim/AnimPainter.swift` | Core Graphics 绘制：`draw(from: 第 k 步布局, to: 第 k+1 步布局, t: 0…1, in: CGContext, dark:)`；物件按身份配对插值，新出现的淡入、消失的淡出 |
| `Sources/Anim/AnimBlockView.swift` | 实时视图（AppKit）：画布 `NSView` + 步骤说明 + 控制条（系统 `NSButton` / `NSSlider` / `NSPopUpButton`，不自绘）；动画用 `NSView.displayLink` 驱动 |
| `Sources/Markdown/AnimBlocks.swift` | `AnimFencedRenderer`（静态图 + 缓存）、`AnimBlockOverlay`（编辑区里盖实时视图） |
| `Sources/MCP/MCPTools+Anim.swift` | `get_anim_reference`、`render_anim` |

`Sources/Anim/` 前四个文件只依赖 Foundation / CoreGraphics / CoreText，spike 可以直接编：`swift spike/anim-test.swift`（解析、状态、布局不重叠等）。

### 4.2 和 grapher 块共用的部分（顺带整理）

- 引擎的 `services.fencedBlocks` 只能放一个渲染器：新增 `NoteFencedRenderer`，按语言分派给 `GrapherFencedRenderer` / `AnimFencedRenderer`，
  `fittingLatex(to:)` 改装它；指纹合并两者。
- `GrapherBlockScan` 改成按语言找块（`FencedBlockScan.blocks(in:language:)`），两种块共用。
- 覆盖层：`GrapherBlockOverlay` 的「找文字视图 / 跟随滚动与改动 / 视口内才建视图 / 光标进块就拆」抽成通用的
  `FencedBlockOverlay<View>`，grapher 与 anim 各给一个建视图的闭包；`MarkdownDocView` 挂一个就够。
  **这一步会动 grapher 现有代码，改完要按 `GRAPHER-BLOCK-PLAN.md §5` 的项目再验一遍。**
- Agent 面板（`AgentMarkdownView`）：anim 块显示第 0 步的静态图，和 grapher 一样只读。

### 4.3 画面纪律

- 只用系统动态色（`systemBlue` 等）与系统字体；深浅色跟随笔记主题（判定沿用 `GrapherFencedRenderer.isDark`）。
- 补间时长默认 0.45 秒，缓入缓出；拖进度条时不做补间，直接跳到那一步的画面。
- 一块的宽度夹在 280～720 点之间（时序图需要比 grapher 更宽）；高度由内容算出，播放中**高度不变**（取所有步里最高的那一帧），免得正文跟着跳。

### 4.4 MCP

- `get_anim_reference`：写法全文 + 三个示例（GBN、数组冒泡一趟、栈）。
- `render_anim(text, step?, width?, format?)`：给 `step` 出那一步的图；不给就出一张「所有步的缩略图拼板」（每格标步号与说明），
  方便 Agent 一次看完整个过程；同时返回 `errors: [{line, message}]` 与 `steps`。只读、不需要写入开关。
- `MCPTools+Markdown.swift` 的写作说明加一句 anim 块（像 `graphWriting` 那样）。

## 5. 分期

| 期 | 内容 | 验收 |
|---|---|---|
| A1 | 解析 / 状态 / 布局 / 绘制；元素 `lanes` `seq` `array` `stack` `queue` `var` `text` `row`；`scene` 对比；静态图 + 实时视图 + 控制条；`NoteFencedRenderer` 与通用覆盖层；MCP 两个工具；skill；spike 测试 | 用户的例子：停等 / GBN / SR 三场景对比块，在 Debug 包里逐步播放、拖进度、深浅色、光标进出块、撤销；grapher 块回归 |
| A2 | `list` `tree` `graph` `pointer` `grid` 及其动作（插入、删除、旋转、遍历标记） | BST 插入 + 一次旋转；BFS 一遍；链表反转 |
| A3 | 按需加套件（§3.6） | — |
| 以后 | 安卓 / 网页阅读器渲染；PDF 页面上的演示批注 | — |

## 6. 不做

- 不执行任何脚本，不支持自定义坐标与色值（表达不了的先记下来，评估后加元素，而不是开放绘图指令）。
- 不把播放到第几步写回块里（没有学习价值，还会让文件频繁变动、触发同步）。

## 7. 实现记录（A1，2026-11-13）

| 文件 | 内容 |
|---|---|
| `Sources/Anim/AnimText.swift` | 词法 + 解析（按行报错）；`AnimReference.swift` 是写法全文 `reference` 与 4 个示例（MCP 原样给） |
| `Sources/Anim/AnimState.swift` | `AnimEngine.run`：逐步执行出每一步的状态；时序图时间用单位记（`travel` 6、`gap` 1.6、两步间 1） |
| `Sources/Anim/AnimLayout.swift` | 状态 → 物件（框 / 字 / 线 / 叉，带稳定 id），高度取所有步的最大，各场景时间轴对齐 |
| `Sources/Anim/AnimPainter.swift` | 按 id 配对插值（新线「长出来」、横向换位走弧线、改字交叉淡入淡出）；`AnimBlockMetrics`（画布 + 错误行 + 控制条 32pt）；`AnimSnapshot`（单步图 / 拼板） |
| `Sources/Anim/AnimBlockView.swift` | 实时视图：不透明底（盖住下面的静态图）、控制条用系统按钮与滑块、`displayLink` 驱动补间与自动播放（每步停 1.4 秒） |
| `Sources/Markdown/FencedBlocks.swift` | `NoteFencedRenderer`（按语言分派）、`FencedBlockScan`、`FencedBlockOverlay`（原 `GrapherBlockOverlay` 抽成通用，grapher 与 anim 共用） |
| `Sources/Markdown/AnimBlocks.swift` | `AnimFencedRenderer` + `AnimImageCache`（第 0 步静态图，底部写「▶ 0 / N」占控制条位置） |
| `Sources/MCP/MCPTools+Anim.swift` | `get_anim_reference`、`render_anim`；`MCPTools.animWriting` 进 MCP 说明与 App 内 Agent 上下文 |
| `Sources/Window/AI/AgentMarkdownView.swift` | Agent 面板里 anim 块显示第 0 步静态图 |
| `skills/unireader-anim-block/SKILL.md` | Agent 操作说明 |

与草案的差别：去掉 `size`（高度按内容算）；加了 `note LANE "…"`；`timer … start` 记在这条竖线上一件事的时刻（写在哪条 `send` 后面就从哪条开始）。

已验证：`spike/anim-test.swift` 57 项（解析、执行、时序、布局不越界 / 各步等高 / id 不重复、示例无错）；`spike/anim-look.swift` 出图目检
（深浅色、拼板、补间中途帧）；Debug 包编译通过。

**待用户实测**（Debug 包 + 真实窗口）：笔记里放块后静态图 → 实时视图盖上不错位；播放 / 上一步 / 下一步 / 拖进度 / 点画布 / ← → 空格；
光标进出块；深浅色切换；grapher 块回归（`GRAPHER-BLOCK-PLAN.md §5` 各项，覆盖层是改过的）；MCP `render_anim`。

**2026-11-13 实测修正**：编辑区文字视图是透明底（引擎 `textView.backgroundColor = .clear`），实时视图取不到能盖住静态图的颜色，
播到第 2 步时第 0 步的窗口框、「▶ 0 / 3」从下面透出来（两个窗口框叠着）。改为：整篇笔记编辑区里（`fittingLatex(to:liveBlocks: true)`，
只有 `MarkdownDocEditor` 传）anim 块的静态图**只占位不画**，内容全由透明底的 `AnimBlockView` 画；气泡 / Agent 面板照旧是完整静态图。
覆盖层找文字视图时只读的也认（否则只读笔记里只剩空白占位）。

**2026-11-13 实测修正（二）**：格子的值、步骤说明变化时，旧字前半程淡出、新字后半程淡入，不再同时交叉淡化（同时出现会在一格里叠成「01」）；
说明文字的物件 id 不再带步号，才能走这条规则。用户认可的三场景对比样例存为 `spike/anim-compare.anim`。
