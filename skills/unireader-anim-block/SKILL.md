---
name: unireader-anim-block
description: 在 UniReader（macOS PDF / Markdown 笔记阅读器）的 Markdown 笔记里放一个能逐步播放的演示（```anim 块）：协议时序图（停等、滑动窗口、回退 N 步、选择重传）、算法过程（排序一趟、双指针、动态规划填表）、数据结构操作（栈 / 队列、链表反转、二叉搜索树插入与旋转、堆、图的遍历）。当用户说「做个动画演示」「一步步演示一下这个过程」「对比这几种方案怎么传的」，或要改笔记里已有的演示时使用。
---

# 在笔记里放分步演示

笔记里的 ` ```anim ` 块是几十行文字：先声明画面里有什么，再一步步写发生了什么。UniReader 把它画成可以
上一步 / 播放 / 下一步 / 拖进度的演示；布局、颜色、动画都是自动的。**你只写文字**。方案见仓库里的 `docs/ANIM-BLOCK-PLAN.md`。

## 前提

- UniReader 正在运行，MCP 服务已开，写入开关已打开。
- 只经 MCP 改笔记（`edit_markdown`）。**绝不直接改 `.unrd` 包里的文件。**

## 流程

1. `get_state` 看用户开着哪篇笔记；`read_markdown`（先 `outline` 或 `search`）找到要放演示的位置——**放在讲这个过程的那一段后面**，
   前后各留一个空行。
2. **每次写之前**先调 `get_anim_reference`，照它的写法和示例写，不要凭印象（不支持的写法整行会被跳过）。
3. **先看有没有套件**：协议（`stopwait` / `gbn` / `sr`）、排序（`bubble` / `selection` / `insertion` / `quick`）、`crc`、
   树的遍历（`preorder` / `inorder` / `postorder` / `levelorder`）、`bfs` / `dfs`、`dijkstra`——用户问的正好是这些，就写一行 `kit …`，
   步骤由引擎推演，保证对（写法见 `get_anim_reference` 的 Kits 一节；对比几种协议就每个 `scene` 放一个 kit）。
   套件不够用时，`render_anim` 返回的 `expanded` 是展开后的文字，拿它改。
   没有合适的套件才手写。手写原则：
   - 一步只讲一件事，每步的 `step` 行写一句完整的说明（用户的语言，通常是中文）；全程 3～12 步。
   - 协议题用 `lanes` 时序图 + `seq … at=发送方` 序号条；同一步里按真实先后写动作（发送、到达后的交付 / 丢弃、确认）。
   - 要对比几种方案就用 `scene`，**让每个场景的第 N 步讲同一时刻**（例如都在「帧 2 丢失被发现」那一步）。
   - 数据结构用对应元素：`list`、`tree`（括号写法）、`graph`、`grid`；遍历 / 双指针用 `pointer` + `move`，比反复 `mark` 清楚。
   - 竖式计算（长除法、进制转换的短除、二进制加减）用 `sheet`：一步写一两行、画横线、用 `arrow` 把数字落下来，像教材那样一层一层写，
     别在一排格子里原地改数字（看不出每个数是怎么来的）。
   - 树的节点按**值**定位（`T[8]`），值重复时只认先序第一个——这种题换成不重复的值再演示。
   - 颜色只用状态词：`active`（正在看）、`done`、`wrong`、`muted`、`new`；不写坐标和色值。
4. **写进去之前**先 `render_anim`（带你要写的文字）：它按行报错，不给 `step` 时返回所有步的缩略图拼板。
   有错就改，图不对（顺序、窗口位置、哪一帧丢了）就改了再看，直到 `No errors.` 且每一步都对。
5. 用 `edit_markdown` 把块插进笔记（`insert_line`，或 `old_text` / `new_text`）：

   ````
   ```anim
   title 回退 N 步：窗口 4，帧 2 丢失
   lanes 发送方 接收方
   seq SW 0..7 window=4 at=发送方

   step 连续发出 0~3，不等确认
     send 发送方 -> 接收方 "0"
     send 发送方 -> 接收方 "1"
     send 发送方 -> 接收方 "2" lost
     timer 发送方 "T2" start
     send 发送方 -> 接收方 "3"
   step 接收方收下 0、1；3 失序，丢弃
     deliver 接收方 "0"
     deliver 接收方 "1"
     discard 接收方 "3"
     send 接收方 -> 发送方 "ACK 1"
   ```
   ````

6. 告诉用户放在哪了、一共几步；用户想看就 `open_markdown`。

## 改已有的演示

`read_markdown` 读出整块文字，改完同样先 `render_anim` 再用 `edit_markdown` 的 `old_text` / `new_text` 整块替换。

## 别做

- 别在一个块里塞太多：超过 12 步或一屏放不下时拆成两个块。
- 安卓端与网页阅读器只显示文字（代码块），别向用户承诺那边能播放。
