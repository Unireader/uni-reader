# GRAPHER-BLOCK-PLAN — 笔记里的函数图形（```grapher 块）

> 2026-10-14。用户：「能不能把绘图能力集成到 UniReader 里……阅读数学公式时让 AI 创建一个函数图形，我会理解得更多。」
> 拍板：**围栏代码块 + 点击进入操作 + 保存视角**（方案 B），之后再做 PDF 页面上的图形批注（方案 C，复用同一份文字与渲染）。

## 1. 它是什么

Markdown 笔记里写一个语言为 `grapher` 的围栏块，里面是几行文字，一行一个图层：

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

- **光标不在块里**：源码折起来，显示成一张图（暗 / 亮跟着笔记）。**点一下**图进入操作状态：描边、右上角小工具条、
  底下每个参数一根滑块（带播放）；拖动转（3D）/ 平移（2D），滚轮 / 捏合缩放，双击回到文字里写的视角。点块外或 Esc 退出。
- **「保存视角」**把当前视角和参数值写回块里（只改 `view:` 行与 `param` 行的数，别的字不动；可撤销）。
- **「编辑文字」**把光标放进块，源码露出来，随便改；光标出来图又盖上。
- 文字是**唯一的真源**：文件里就是这几行字，Obsidian 里看到的是一个普通代码块；安卓端（没有 Grapher）也只会看到文字。
- 写法全文：Grapher NG 的 `GrapherText.reference`（它的 MCP `get_text_reference`）。AI 写完用它的 `render_text` 看图、查错。

## 2. 谁做什么（三个仓库）

| 仓库 | 改了什么 |
|---|---|
| `grapher-ng` | `GrapherKit`：`GrapherText`（文字 ↔ 文档、按行报错、`patch` 回写）；`GrapherRender`：`GraphSnapshot.image(text:…)`；新 framework `GrapherEmbed`：`GrapherBlockView`（见 `../grapher-ng/docs/embedding.md`）；MCP `get_text_reference` / `render_text` |
| `swift-markdown-engine`（fork） | 本地分支 `feat/fenced-block-renderer`（基于 `0.14.0-xvan.1`）：`FencedBlockRenderer`（某种语言的围栏块画成图，光标进去露出源码）、`NSTextView.renderedBlockFrames`（查图画在哪，好盖实时视图） |
| `uni-reader`（本仓库） | `Sources/Markdown/GrapherBlocks.swift`：`GrapherFencedRenderer`（静态图 + 缓存）、`GrapherBlockScan`（找块）、`GrapherBlockOverlay`（在编辑区每张图上盖 `GrapherBlockView`）；`MarkdownDocView` 挂上它；`fittingLatex` 顺带让批注框、气泡也显示静态图；MCP 说明加一句；技能 `skills/unireader-grapher-block` |

## 3. 实现要点

- **引擎只画静态图**，所以气泡 / 批注框里看到的是静态图（`GrapherImageCache`：文字 + 宽度 + 深浅色为键，24 张封顶）。
  引擎在翻转坐标里用 `image.draw(in:)`；用小程序实测过：普通位图图片与「翻转」包装的图片画出来都是正的，代码里保留了包装（无害）。
- **实时视图盖在图上**：`GrapherBlockOverlay` 是整篇笔记编辑区（`MarkdownDocView`）的辅助，不是 SwiftUI。找到编辑区的 `NSTextView`，
  用 `renderedBlockFrames(in: 视口范围)` 查每张图的位置，只给视口里的块建 `GrapherBlockView`（几十个 Metal 视图太重），
  滚出去拆掉；光标进块 → 引擎露出源码 → 查询里没有这块 → 视图拆掉。视图是 `NSTextView` 的子视图，跟着文字一起滚。
  刷新触发：文字变、选区变、文本视图尺寸变、滚动、`box.$text` 变（外部改动 / MCP 写入）；合并成一次，再补一次等排版落定。
- **改回正文走文字视图的标准流程**（`shouldChangeText` → `replaceCharacters` → `didChangeText`）：可撤销，绑定与自动存盘照常。
- **块的定位**不用字符偏移存（打字会挪）：每次按当前正文重新扫（`GrapherBlockScan`，配对规则同引擎——开：以 ``` 开头的行；关：之后第一个以 ``` 开头的行）。
- **宽度**：文本容器宽夹在 200～640pt，高 = 宽 / `aspect:`（默认 3:2）。宽度变 → 渲染器指纹变 → 引擎重排。
- **只在整篇笔记编辑区有交互**；批注框 / 气泡是静态图。安卓端不支持（文字原样显示）。

## 4. 🔴 发布前必须做的事

1. `project.yml` 里引擎依赖现在是**本地路径** `../swift-markdown-engine-worktrees/fenced-block`：把 fork 的 `feat/fenced-block-renderer`
   合进 `xvan` 分支（`xvan` 比 `0.14.0-xvan.1` 多 24 个提交，合并后要 `swift test`）、推送、打新 tag（如 `0.14.0-xvan.2`），再把依赖换回 `url` + `exactVersion`。
2. `project.yml` 用工程引用 `../grapher-ng/GrapherNG.xcodeproj`：两个仓库必须在同一级目录。`scripts/package.sh` / `release.sh` 在干净机器上要先能构建 `grapher-ng`。
3. **许可证**：Grapher NG 是 GPL-3.0-or-later，本项目 AGPL-3.0。两者可以合并（GPLv3 §13 / AGPLv3 §13），合并后的整体按 AGPL 发布；
   两个仓库版权人都是你。发布日志里写一句。
4. Release 包里会多三个 framework（GrapherKit / GrapherRender / GrapherEmbed）和它们的本地化文字；签名公证照常。

## 5. 已验证（2026-10-14，Debug 包，测试工作区 + 真实窗口）

- 3D / 2D 块折成图；深色笔记里深色图；点一下进入操作状态（描边、工具条、滑块）；拖动转视角；「保存视角」把
  `view: azimuth=-25.0039 elevation=11.6654` 写进块（`read_markdown` 读得到），重启 App 后视角还在；
  「编辑文字」露出源码；平面图 `width=8` 取景正确、刻度文字不再上下颠倒。
- Grapher NG 里 `GrapherBlockViewTests`（模拟点击 / 拖动 / 存回）、`GrapherTextTests`、`GrapherTextRenderTests`；引擎里 `FencedBlockRendererTests`。

## 6. 没做 / 之后

- 方案 C：PDF 页面位置上的图形批注（复用 `GrapherText` 与 `GrapherBlockView`，批注模型要加一种）。
- 气泡 / 批注框里也能点（目前静态图）。
- 导出 PDF / HTML 时块的处理（现在导出的是文字）。
- 块里 `view:` 的 2D `width` 保存后，窗口宽度很不一样时看到的范围也会变（按宽度定，不是按像素）。
