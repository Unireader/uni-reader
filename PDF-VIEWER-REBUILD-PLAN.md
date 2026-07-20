# 自研 PDF 阅读控件 v2 设计（纯 SwiftUI 页图流，Preview 级性能/UX）

> 2026-07-20 重写。v1（SwiftUI 首版 PageStreamView）已被用户删除（缩放/闪烁不达标）。
> 本文是 v2 的**严格设计**：先把五条硬指标逐条映射到机制，再实现。
> 红线不变：**纯 SwiftUI 阅读区，严禁 AppKit 视图（含 NSViewRepresentable 包 NSScrollView）进阅读区**；
> 严禁仿侧栏/浮层 hack；PDFKit 只用 `PDFDocument`/`PDFPage` 做解析与栅格化，严禁 `PDFView`。

---

## ✅ 状态（2026-07-20：v2 已实现，编译通过 + 4 组 spike 全绿，待用户真机手感验证）

**已落地文件**：`Sources/App/PageBitmap.swift`（渲染原语）+ `PageLayout.swift`（布局数学）+
`PageRenderEngine.swift`（串行后台渲染 + 限容缓存 + 多窗口 wanted 隔离）+
`Sources/Views/ScrollFollower.swift`（重构为纯 tick 驱动，算法不变）+
`Sources/Views/PageStreamView.swift`（阅读区，含 pinch/⌘±⌘0/resize/锚点/墨迹/hover/夜间/贴片）+
`ContentView.readerColumn` 接入 + View 菜单缩放命令（双语）。

**spike 实测结论（实现的依据，全部可重跑）**：
- `spike/atomic-commit-probe.swift`：**同一 runloop 周期内「改布局 + scrollTo」= 同一次 CA commit = 屏幕原子**
  （中间态几何回调存在但不上屏）；`scrollTo(y:)` 语义 = contentOffset 直接赋值。→ pinch commit 无需补偿保持，
  保留校验环兜底。
- `spike/scroll-x-probe.swift`（2026-07-20 修水平跳最左 bug 时补）：**单轴 `scrollTo(x:)`/`scrollTo(y:)` 是
  「后写覆盖前写 + 未指定轴重置为 0」语义（T1/T4）**——曾致放大 commit 时 x 丢失、水平跳最左闪烁；
  `scrollTo(point:)` 两轴同写 + 同 transaction 改尺寸 = 超旧范围也不夹取、同周期原子（T3b）。
  **规矩：全代码库禁用单轴 scrollTo，一律 point 形式。**
- `spike/render-rotation-test.swift`（9/9）：`page.draw(with:to:)` **自带旋转**；显示尺寸 90/270 换边；贴片=子矩形平移。
- `spike/page-layout-test.swift`（25/25）：布局/locate/docY 往返/间隙/边界/进度 clamp/commit 锚定代数不变量。
- `spike/follower-step-test.swift`：**真实 ScrollFollower 类**回归——低通/插值两路径零过冲、零反转、收敛停机。
- `spike/swiftui-api-probe.swift`：全部依赖 API `-typecheck` 通过。

**与本设计的三处落地修正**（实现优于原稿）：
① §1 的 LazyVStack 改为**自研虚拟化**（ZStack 精确总尺寸 + 只实化窗口内页）——LazyVStack 对未实化页高做估算，
   会导致滚动条比例漂移与 `scrollTo` 落点不准；自研虚拟化内容尺寸恒精确。
② §6 的「逐帧锚定 refit」改为**拖动期间布局冻结 + 稳定 0.2s 后单次原子锚定 refit**（默认）——
   拖动期间页面尺寸完全不动=纵向绝对零抖动；手动缩放态 refit 只重定标基准（零视觉变化，Preview 同款绝对尺寸语义）。
③ §5 的「放大=视觉变换相」废弃，**pinch 双向统一逐帧真 commit**（2026-07-20 修 bug：视觉相导致滚动条松手才出现；
   同时发现并修复单轴 scrollTo 重置另一轴 → 水平跳最左闪烁，见 spike 结论 `scroll-x-probe`）。

**待用户真机验证**：pinch 手感/锚定、⌘±/⌘0、窗口缩放/侧栏开合行为②③、SimPad↔Mac 锚点、墨迹/hover/夜间/进度回归、
玻璃 scroll-under 观感。已知遗留：`AppModel.push()` 在主线程渲染平板 PNG（服务开启+翻页时），历史问题不在本次范围。

---

## 0. 五条硬指标 → 机制映射（验收基准）

| # | 硬指标 | 机制 |
|---|---|---|
| 1 | 主线程不卡顿 | 主线程**零渲染**：所有页图/贴片在单一串行后台队列出图；主线程只做布局数学（O(可见页)）与 CGImage 赋值 |
| 2 | 预缓存页面 | 滚动几何驱动（非 cell 生命周期驱动）：可见页优先 + 滚动方向加权预取 ±N 页；NSCache 限容 LRU；缓存命中**同步**出图（cell 出现即有图，无 pop-in） |
| 3 | 窗口缩放/pinch 不闪烁 | 「五条零闪烁纪律」（§3）：白纸占位、只替换不清空、同 transaction 原子提交、禁隐式动画、cell 身份稳定 |
| 4 | pinch/缩放锚定不跳位 | 逐帧真 commit pinch（§5）：每帧「zoom + scrollTo(point:)」同 runloop 原子提交，锚定捏合点；校验环兜底。窗口缩放同理（§6） |
| 5 | 任何情况零闪烁 | 同 §3 + 图像交换永远是「新图就绪后原位替换」，旧图在替换前一直显示 |

**实现不达标 = 不如不做**。每一节的机制都要能回答「为什么这一步不可能闪」。

---

## 1. 架构总览

```
ContentView.readerColumn
└─ PageStreamView(session:, docKey:, nightMode:, interpEnabled:)   ← SwiftUI，唯一入口
   ├─ GeometryReader（未遮视口宽 = fit 基准）
   └─ ScrollView([.vertical, .horizontal])  + .ignoresSafeArea()
      ├─ .scrollPosition($pos) / .onScrollGeometryChange(offset/containerSize/insets)
      └─ content：自研虚拟化 ZStack(topLeading)（精确总尺寸；LazyVStack 估算会漂，弃用）{
            ForEach(实化窗口页) { PageCell(i).offset(x: 居中, y: offsets[i]×dispScale) }
         }
         .frame(width: max(unobW, pageW), height: 精确总高)  ← 页水平居中；>视口时可横向滚动（延伸到侧栏玻璃下）
         .scaleEffect(gestureK, anchor: 捏合点)    ← pinch 放大相视觉层（§5），恒等时无副作用
   PageCell(i)：白纸底色 + 页图 Image + [精细贴片 Image] + Ink Canvas + Hover 圆环
```

支撑（非视图，无 AppKit UI）：

- `PageLayout`（纯数学）：fit-width 布局。`pageW = unobW × zoom`，`pageH[i] = pageW × h/w`，
  `offsets/totalH`、`docY ↔ (page, frac)`。与 `PadRenderer` 同坐标约定（页+页内比例）。
- `PageRenderEngine`（单串行后台队列 + NSCache）：`(docKey, page, pixelW, night)` → CGImage；
  可见优先/预取/generation 失效丢弃；夜间 = 渲染时 CIColorInvert + CIHueAdjust(π)；
  高倍精细贴片 = 页内子矩形渲染（旋转页由 spike 校验）。
- `ScrollFollower`（现算法原样，改纯 tick 驱动）：去掉 CADisplayLink/NSView host，
  改 `step(now:) -> Bool`；由 `TimelineView(.animation)` 在跟随激活期间逐帧驱动。
  低通/时间戳插值/零过冲零反转性质不变（`spike/scroll-follow-sim.swift` 已验证的就是这套数学）。

**数据契约全部不变**：`DocSession`/`ScrollAnchor{page,frac,seq,origin,senderT}`/`emitAnchor`/
`strokes/liveStroke/hover`/`WorkspaceManager.saveProgress`。

## 2. 状态模型

- `zoom: CGFloat`，**1 = fit-width**（页宽恰好填满未遮视口宽），clamp 0.25…6。
- 布局唯一输入：`(unobW, zoom, doc)` → `PageLayout`。未遮宽来自 GeometryReader（safe area 已由
  ScrollView 自动转成 content inset，`.ignoresSafeArea` 只负责让画面延伸到玻璃下——spike 已验证）。
- 文档坐标 `docY`（zoom=1 的布局单位）与显示坐标 `dispY = docY × zoom` 分离；
  锚点 `(page, frac)` 只依赖 docY → 对 pad/SimPad/进度恢复天然稳定。
- `topDocY = (contentOffset.y + contentInsets.top) / zoom`（首次运行日志标定一次，防 inset origin 偏差——v1 的 §9.2 教训）。

## 3. 零闪烁五纪律（所有代码必须遵守）

1. **白纸占位**：cell 底色 = 纸色（夜间 = 深灰），未出图时它就是一张空白纸（Preview 快速滚动同款），
   永不出现灰块/黑块闪烁。
2. **只替换，不清空**：`images[i]` 只会被新 CGImage 覆盖，绝不先置 nil 再等新图；
   换清晰度/换夜间模式时旧图一直显示到新图就绪。
3. **同 transaction 原子提交**：凡「布局变化 + 偏移变化」成对出现（pinch commit、窗口缩放锚定、⌘±），
   必须在同一次状态更新里同时写 `zoom` 与 `pos.scrollTo`，禁止跨帧分步（onChange 链/async 派发）。
4. **禁隐式动画**：页图/贴片交换、布局跳变一律 `.transaction { $0.animation = nil }`。
5. **cell 身份稳定**：`ForEach(id: 页号)`，缩放/夜间只改 cell 的 frame 与内容，不销毁重建。

## 4. 渲染管线与缓存

- **像素宽** = `pageW(pt) × displayScale`；settle（缩放/resize 结束 0.15s）后按**精确宽**重渲。
- **基图上限** ≈ fit 宽 × displayScale（≈2400px@retina）：zoom ≤ ~1.2 全程原生清晰；
  更高倍时基图被拉伸（微软，Preview 同款），由**精细贴片**补清晰：
  可见区 ∩ 页 的子矩形按精确像素渲染，`.offset` 原位叠加在基图上，只在 settle 后刷新、替换式更新。
- **预取**：`onScrollGeometryChange` 算可见页区间 → 请求 [可见页] + 方向加权 [前 3 / 后 1] 页；
  队列 generation 化：布局代际变了的过期请求出队即弃。
- **缓存**：NSCache totalCostLimit ≈ 400MB（按字节计费），key=(docKey,page,pixelW,night)；
  cell 视图侧仅保留可见 ±K 页的图引用，远页交还缓存。
- **夜间**：queue 上 CI 反色+色相复原，独立缓存键；切换时逐页替换（纪律 2 保证不闪黑）。
- PDFPage 栅格化线程约定：全 app 后台渲染共两条串行队列（阅读区 engine + LANServer），与现状一致。

## 5. Pinch 缩放（核心难点）

> **2026-07-20 定稿（修 bug 后）**：原设计的「放大=视觉变换相 + 松手 commit」已废弃——
> 它导致滚动条要到松手才出现（布局在手势中不变，ScrollView 不知道内容超宽了）。
> 由于 atomic-commit-probe 证明同 runloop「重排+scrollTo」屏幕原子，**放大/缩小统一为逐帧真 commit**。

- **手势开始**：记 `c` = `value.startLocation`（content 坐标）、屏幕不动点 `P = c − offset`；`follower.reset()`。
- **每个 onChanged**：`z1 = clamp(startZoom × magnification)`；`c' = c×r`（r=z1/z0）；
  同 transaction 写 `zoom = z1` + `pos.scrollTo(point: c' − P)`（**必须 point 形式**，见 §0 spike 结论）。
  逐帧真布局 → 滚动条在内容超容器的瞬间出现并实时正确（Preview 同款）；新露出区域白纸补位。
- **校验环兜底**：commit 后几何回调若 `O_a ≠ O_t`，重发 `scrollTo(point:)`（≤5 次），超限记日志。
- settle（0.15s 稳定）后按新 zoom 精确重渲（原位替换）。
- ⌘+/⌘−：未遮视口中心为锚 ×1.25 / ÷1.25，走同一 commit 路径；⌘0 = 回 fit（基准重定标）。菜单命令 + 双语。

## 6. 窗口缩放 / 侧栏开合（锚定不跳位）

- 触发：`containerSize`/未遮宽变化（GeometryReader + onScrollGeometryChange）。
- 每帧：`unobW' → 布局整体比例 s = W'/W`，目标 offset `O_t = O×s`（保 (page,frac) 顶部锚 + 水平比例），
  与布局更新**同 transaction** `scrollTo`；不足一帧的落差由 §5 的补偿保持吸收。
- 效果：fit 模式页宽实时贴合窗口/未遮区（侧栏开 → 页挤到右侧可见区居中=既定行为②）；
  手动放大态页面允许被侧栏玻璃覆盖（行为③，横向可滚）。
- 若真机仍有肉眼可见抖动 → 内置开关退到「resize 期间冻结布局、松手一次性锚定重排」（一次原子跳，无抖动）。

## 7. 锚点同步 / 跟随 / 墨迹 / hover / 进度

- **发**：滚动几何变化（非程序化期间）→ `(page,frac)=layout.locate(topDocY)` → `emitAnchor(origin:"mac")`（节流 1/帧）。
- **收**（sim/pad/toc/restore）：`ScrollFollower.apply`（算法不变）→ TimelineView 逐帧 `step` →
  `docY(page+frac) × zoom − insets.top` → `pos.scrollTo(y:)`；`isSuppressing` 抑制回发（防回环，0.1s 释放）。
- **墨迹**：每页 Canvas，归一化点 × (pageW,pageH)，二次贝塞尔中点平滑 + 压感变宽（照 SimPad.drawStroke）；
  `inkTick` 只触发所涉页重绘；墨迹不随夜间反色；随页几何缩放天然对齐。
- **hover**：所在页 cell 叠圆环。
- **进度**：`scrollAnchor` onChange 节流保存（ContentView 现有逻辑零改动）。

## 8. 里程碑（每步可编译）

- M1 静态：布局 + 渲染管线 + 白纸占位 + 预取缓存 + 连续滚动 + 玻璃延伸。
- M2 缩放：双相 pinch + 补偿保持 + ⌘±/⌘0 + settle 重渲 + 精细贴片。
- M3 resize 锚定 + 侧栏开合行为②③。
- M4 锚点双向 + 跟随器接回（sim/pad/toc/restore）。
- M5 墨迹/hover/夜间/进度回归。
- M6 文档与内存清理、`xcodegen` + `xcodebuild`、spike 全绿。

## 9. 验证

- `spike/page-layout-test.swift`：布局/换算/锚定公式（含 commit O_t 公式、resize 比例保持）纯数学断言。
- `spike/render-rotation-test.swift`：0/90/180/270 旋转页 —— 子矩形渲染 vs `thumbnail` 逐像素抽样比对。
- `spike/scroll-follow-sim.swift`（已有）：跟随器零过冲零反转性质回归。
- 真机手感（只能用户测）：pinch 锚定、resize 无抖、fling 无 pop-in、玻璃观感。

## 10. 明确不做 / 后续

- 文本选择/搜索/OCR：座位已留（`PageText.swift`/`TEXT-SEARCH-OCR-PLAN.md`），T1 起另做。
- 链接点击、双击 smart-zoom：后续。
- v1 的 §9 遗留问题（scrollTo 每帧跟手性、inset 原点标定）由本设计的仪表日志在真机一次性定标。
