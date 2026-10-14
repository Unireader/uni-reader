---
name: unireader-grapher-block
description: 在 UniReader（macOS PDF / Markdown 笔记阅读器）的 Markdown 笔记里放一个能转动、能拖滑块的函数图形（```grapher 块）。当用户在读公式 / 定理时说「画个图帮我理解」「把这个曲面画出来」「加一个切平面的图」「让参数能拖动」，或要改笔记里已有的图形时使用。
---

# 在笔记里放函数图形

笔记里的 ` ```grapher ` 块是几行文字，一行一个图层；UniReader 把它画成图，读者点一下就能转动、拖参数滑块，
并把喜欢的视角存回块里。**你只写文字**，写法和检查都交给 Grapher NG 的 MCP 服务。方案见仓库里的 `GRAPHER-BLOCK-PLAN.md`。

## 前提

- UniReader 正在运行，MCP 服务已开，写入开关已打开。
- 另有一个 `grapher-ng` MCP 连接（Grapher NG 的 MCP 服务，工具 `get_text_reference`、`render_text`）。
  没有它也能写简单的块，但写完没法先看图，容易出错——这时只用最简单的一两行，并告诉用户没检查过。
- 只经 MCP 改笔记（`edit_markdown`）。**绝不直接改 `.unrd` 包里的文件。**

## 流程

1. `get_state` 看用户开着哪篇笔记；`read_markdown`（先 `outline` 或 `search`）找到要放图的位置——**放在讲到这个公式的那一段后面**，
   前后各留一个空行。用户在读 PDF 时说的「这个公式」，用 `get_current_view` / `read_pages` 看清是哪一条再画。
2. 第一次用先调 `grapher-ng` 的 `get_text_reference`，照它的写法和示例写，不要凭印象。
3. 写块。原则：
   - 只画能帮助理解的东西：曲面 + 一个点 + 切平面；曲线 + 切线；两个曲面 + 交线。图层少而清楚。
   - 有「想看它怎么变」的量就写成 `param`（1～3 个滑块），位置（切点、小球）可以直接用参数写公式。
   - 曲面里面还有东西时加 `opacity=0.5`～`0.85`；用 `view:` 摆好一个一眼能看懂的视角（3D 给 `azimuth` `elevation`，必要时 `range` `center`）。
   - 参数名不能用 `x y z t u v r e pi theta` 和函数名。
4. **写进去之前**先 `render_text`（带你要写的文字）看一眼：有错误它按行号报，被跳过的行不会画；图不对就改了再看。
5. 用 `edit_markdown` 把块插进笔记（`insert_line`，或 `old_text` / `new_text`）。块的写法：

   ````
   ```grapher
   space
   param s = 0.8 [-2, 2]
   view: azimuth=30 elevation=30
   surface S: (x^2 + y^2)/4; opacity=0.6
   point P: s; 0.5; (s^2 + 0.25)/4
   tangent-plane: of=S; at=s, 0.5; color=orange
   ```
   ````

6. 告诉用户：图已放在哪一段后面；**点一下图**可以拖动旋转、拖滑块，满意的视角点工具条上的「保存」存进笔记；要改文字点「编辑文字」。

## 改已有的图

- `read_markdown` 读出块，**只改要改的行**。块里的 `view:` 行和 `param` 行的数值常常是读者自己存的，**别动它们**，除非用户要求换视角 / 换参数范围。
- 改完同样先 `render_text` 看。

## 别做

- 不要在 ` ```grapher ` 里写 JSON 或别的格式；也不要把公式写进粗体 / 斜体里（笔记公式规则不变）。
- 不要往 PDF 页面批注（`add_note`）里放这种块，它只在 Markdown 笔记里有图。
- 安卓端看不到图（只显示文字）：用户说要在平板上看时提醒一句。
