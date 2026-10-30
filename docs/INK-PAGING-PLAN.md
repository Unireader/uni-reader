# 笔迹内存：点压缩 + 按页窗口加载 — 方案

> 状态：**① ② 均已落地（2026-09-10，用户拍板 §8 四项照推荐），待用户实测 §6**。落地与方案的出入见 §9。
> 起因：用户问「笔迹读库 158ms · 2616 条，是一次性读全部吗」→ 是。读库/解码已挪到后台（见 HISTORY
> 「打开耗时」第 4 点），但**整篇笔迹常驻内存**这件事没变。用户定的线：「**1~10MB 以内可以全部加载，
> 再多就很有问题**」。

## 1. 现状与数字

| 项 | 现状 |
|---|---|
| 装载 | 开文档一次读整篇 kind=2 行（`LibraryStore.inkRows`），后台解码，全部进 `session.strokes` |
| 点 | `SIMD3<Double>`：size 24、**stride 32**（8 B 纯填充） |
| 这篇 2616 笔 | ≈ 26 万点 → 点 8.4 MB + 笔迹头 0.3 MB + 对账字典 0.3 MB ≈ **9~10 MB 常驻** |
| 开文档峰值 | `[LibInkRow]` 的 payload 13~15 MB + 解码期副本 → **25~30 MB** |
| 佐证 | 内存排查那轮（HISTORY 同日）：三篇文档 11,335 个点数组共 37 MB，≈ 12 MB/篇 |
| 线性规律 | **每点 32 B**；100 万点（整本教材写满）= 32 MB 常驻；每个开着的标签各一份 |

所以这篇正好卡在 10 MB 线上，再大一点的文档就超。两步走：

- **①点压缩**：常数倍（2×），改动集中、风险低，单独就能让这篇降到 4~5 MB。
- **②按页窗口**：内存与文档大小**无关**（只装实化范围附近几页），是真正对应「全部读到内存很没有必要」的做法。

两者独立，①先做（②的 spike 与数字都建立在新点类型上，省得改两遍）。

## 2. 硬指标

1. 常驻笔迹内存 = O(窗口页数)，与文档总笔数无关；这篇实测目标 **< 1 MB**（窗口 ~20 页 × ~10 笔 × 100 点 × 16 B ≈ 320 KB）。
2. 开文档不比现在慢：首窗读库 + 解码在后台，页图先出、笔迹随后（现有纪律不变）。
3. **零闪烁纪律不破**：滚动中不许因装载/淘汰而每帧写 `@Published`（`reader-perframe-published-fanout` 教训）；
   装载/淘汰只在 settle 时提交，一次窗口变化最多一次 `strokes` 赋值。
4. 落库语义不变：schema 不动、payload 格式不动（`[x, y, pressure]` 三端契约）、线格式不动。
   （2026-09-26 起点集另有二进制列 `note.points`，见 `BINARY-INK-PLAN.md`——那是后来的决定，不属于本方案；
   `inkRows` 两条窄查询顺带多取了 `points` 与「二进制是否最新」两列。）
5. 编辑路径（擦除 / 框选 / 粘贴 / 撤销 / 图层）在窗口内行为与现在逐字节一致；窗口外的整篇操作
   （删整层 / 删整页 / 计数）结果与现在一致。

## 3. ① 点压缩：`SIMD3<Double>` → `InkPoint = SIMD3<Float>`

**为什么是 Float**：平板上行线格式本来就是 f32（`PROTOCOL.md §2` `pt3`），Double 在内存里没多装任何信息；
本机鼠标/触控板落笔归一化到 0~1 后，f32 分辨率 ~6e-8 → 页宽 1 万像素时 0.0006 px；草稿纸画布坐标
（逻辑点、可负）到 5 万 pt 时分辨率 0.004 pt——都远超任何显示需要。`z` 槽位装页号那条约定
（`InkEdit.splitStroke`）Float 到 1600 万整数精确。

**为什么不是 12 B 的手写结构体**：SIMD3<Float> stride 16（还是补齐到 4 lane），比 12 B 多 25%；
但 `InkEdit` / 擦除 / 框选一堆向量算术（`p - q`、`length`）靠 SIMD 现成运算，手写结构体要重写这些，
且 ② 落地后内存已经与文档大小无关，这 25% 不值一次全量重写。**选 SIMD3<Float>**。

改动面（`grep SIMD3<Double>` 共 30 处、7 个文件）：

| 位置 | 改法 |
|---|---|
| `InkModel.swift` | `typealias InkPoint = SIMD3<Float>`；`InkStroke.points: [InkPoint]`；`InkPayloadFast` 解出 Double 后转 Float；回落路径同 |
| `InkStrokePayload` 编码 | `points` 编码用 `[[Float]]`（JSON 写最短 Float 表示，payload 反而变短）；解码仍认 `[[Double]]`（别的端写的），JSONDecoder 数值 token 解成 Float 无障碍 |
| `WireCodec.swift` | `pt3` f32 ↔ `InkPoint` **不再转换**（原来 f32→Double→f32 来回） |
| `AppModel` / `AppModel+Scratch` | 入参类型换名；`points(_ any:)` 解析平板 JSON 兜底路径转 Float |
| `InkEdit` / `InkPaste` / `CanvasMargin` | 类型换名；阈值常量（半径 r、slack）保持 Double，比较处 `Float(r)` 或 `Double(p.x)`，**别让半径也变 Float 后精度累积** |
| `InkLayers` / `ReaderSurface+Lasso` / `ScratchPadView` | `map: (InkPoint) -> CGPoint` 换名 |
| spike | `ink-payload-fast-test`「逐位相同」改为与 `Float(JSONDecoder 的 Double)` 逐位比；`ink-edit-test` / `ink-undo-test` / `ink-store-test` 跟着编译通过 |

**对账不受影响**：`persistInk` 按内存值比较，装载后 `persisted == strokes`，**没编辑过的笔迹不会因精度变化被重写**；
只有真被编辑的笔迹才以新精度落库（Android/Windows 读 Double 照常）。`MirrorFingerprint` 同理不受影响。

## 4. ② 按页窗口加载 + 淘汰

### 4.1 一句话

> `session.strokes` 从「整篇」变成「**已装载页**的集合」；装载窗口 = 阅读区实化范围 ± `pad` 页，
> 淘汰线 = 实化范围 ± `keep` 页（`keep > pad`，滞回）；只在 settle 时变动。

- `pad = 4`、`keep = 12`（先定这个，spike 里可调）。实化范围本身 = 可见 ± 一屏（`PageStreamView` `buffer`），
  所以窗口通常 10~20 页。
- 读库按页：`SELECT id, kind, page, payload FROM note WHERE document_id=? AND kind=2 AND page BETWEEN ? AND ?
  ORDER BY page, created_at`——走现有索引 `idx_note_document_page`，**schema 零改动**。
- 新状态（`DocSession`，非 @Published）：`inkLoadedPages: Set<Int>`、`inkPinnedPages`（见 4.4）。

### 4.2 装载

`DocTabModel.ensureInkWindow(realized:)`，由阅读区在 `realized` 变化且 settle 后调（不是每帧）：

1. `want = realized ± pad` ∩ 文档页数；`missing = want − inkLoadedPages`，按离当前页近→远排序。
2. 缺页成一批读（一条 `BETWEEN`，或几段），**后台**读库 + `decodeAll`，回主线程按 `inkLoadGeneration`
   + 「这些页仍在 want 里」核对。
3. 合并规则（沿用 `applyLoadedInk` 的正确性）：对每个到达的页 p，先摘出内存里 p 页**期间新画**的笔迹
   （id 不在库批里的），再 `append(库批) + append(新画的)`——**后画的在上**，z 序与现在一致。
   `persistedStrokes` 加进库批那些 id。一次窗口变化只做一次 `strokes` 赋值。
4. 到位后：`ensureInkLayers`（图层自愈按批做）、`broadcastStrokes`（4.5）、账本 `笔迹到位` 记「窗口 pA–pB N 笔」。
5. 开文档：首窗 = 进度页 ± pad（`load()` 里已知进度页，不必等首帧）。

### 4.3 淘汰

同一入口里，`evict = inkLoadedPages − (realized ± keep) − inkPinnedPages`，满足：

- 页上每条笔迹 `persistedStrokes[id] == stroke`（已落库、无未写差异）——不满足就跳过这一页，下次再说；
  实际上 `persistInk` 是 Combine 订阅同步跑的，几乎总满足。
- `strokes.removeAll { evict.contains($0.page) }` 与 `persistedStrokes` 删同一批 id **在同一同步块里完成**，
  这样紧随其后的 `persistInk` 看不到「persisted 里有、strokes 里没有」的假删除。

### 4.4 与撤销栈的关系

`InkPatch` 增量按 id 存前后值并带原下标；淘汰掉一页后撤销它上面的编辑，`before` 插回时下标失效、
且页不在内存里。规矩：**撤销栈引用到的页一律钉住不淘汰**（`inkPinnedPages` = 栈里所有 change 的
before/after 涉及的页）。栈上限 100 条，钉住的页有界。换文档 `reset()` 时自然解钉。

### 4.5 平板

平板 `G.strokes` 是「Mac 回传的全文档笔迹」，渲染时按视口裁页（`render.ts:312`）。平板视口与 Mac 互相跟随，
Mac 的装载窗口（实化 ± pad）⊇ 平板可见页。做法：**窗口变化后 settle 时用现有 `strokes` 消息整替一次**
（内容 = 当前窗口），`strokesAppend` 照旧。一次 ≈ 20 页 × 10 笔 × 100 点 × 12 B ≈ 240 KB，LAN 无压力。
**线格式零改动**（`PROTOCOL.md` 只补一句语义：`strokes` 的 list 是 Mac 当前装载窗口，不保证全篇）。
平板刷新/重连后的恢复照旧走 `strokes` 全量（= 当前窗口）。

平板对**未装载页**的编辑（跳页瞬间的竞态）：`AppModel` 的擦除/框选/粘贴入口先 `guard page ∈ inkLoadedPages`，
不在就**同步**读那一页（一页十几行，主线程几毫秒）再应用。

### 4.6 假定「`strokes` 是全集」的地方，逐个改

| 地方 | 现在 | 改成 |
|---|---|---|
| `CanvasMargin.overflow(session.strokes)`（画板模式页边） | 扫全部点 | 开文档一条 SQL：`SELECT MIN(anchor_x), MAX(anchor_x+anchor_w) FROM note WHERE document_id=? AND kind=2`（anchor 列 = `normalizedBounds`，不读 payload）作首值；落笔中的逐笔生长照旧 |
| `LayerRack` 每层笔数 | `strokes.filter{layerId}.count` | `SELECT json_extract(payload,'$.layerId') AS l, COUNT(*) GROUP BY l`（系统 SQLite 3.51 有 JSON 函数，已验证）；后台查、按 `inkRev` 缓存 |
| `LayerRack.delete` 删整层 | `strokes.removeAll{layerId}` → 对账删库 | 内存照旧 removeAll + persisted 同步摘掉 + **一条 `DELETE … WHERE json_extract(payload,'$.layerId')=?`** 删窗口外的；一个事务 |
| `InspectorView` 按页列表 / 笔数 | `Dictionary(grouping: strokes, by: page)` | `SELECT page, COUNT(*) GROUP BY page`；打开检查器时查一次、`inkRev` 变了再查 |
| `InspectorView.deleteInk(page:)` | `strokes.removeAll{page}` | 页已装载：照旧（撤销可用）；未装载：先装载再删（保持可撤销），不走 SQL 直删 |
| `ensureInkLayers` 图层自愈 | 开文档扫全篇 | 每批装载后扫这一批（孤儿层随滚动逐步补建，可接受）；如需一次到位，`SELECT DISTINCT json_extract(payload,'$.layerId')` 后台一次 |
| `broadcastStrokes` | 全篇 | 当前窗口（4.5） |
| `visibleStrokesByPage(in:)` / `PageBuckets` | 扫全篇 | 不改（扫的自然只是窗口） |
| 擦除 / 框选 / 剪贴板 / 粘贴 / 尺子 | 只碰当前页 | 不改（当前页必在窗口）+ 4.5 的守卫 |
| 草稿纸笔迹 kind=4 | 整篇装载 | **不改**：按纸归属、通常很少；要分页也没有「页」的概念 |
| 离线镜像 / 指纹 / 借出 | 直接读库 | 不受影响 |
| 安卓两种模式 | 自己的代码读同一个库 | 不受影响（点精度变化只在被编辑的笔迹上体现） |

### 4.7 多标签

切走的标签**保留窗口**（几百 KB，不值得为它再走一遍装载；切标签 30~60ms 的指标不能倒退）。
关标签随会话释放。

## 5. 不做的事

- 不改 schema、不加 `kind` 进索引（`BETWEEN page` 已走 `(document_id, page)`；kind 过滤在几十行里做）。
- 不改 payload 格式、不做二进制 payload（本方案范围内；2026-09-26 用户另定点集改存二进制，见 `BINARY-INK-PLAN.md`）。
- 不做逐笔懒解码（窗口内笔迹全解，解码已经很快）。
- 不做平板端分页协议（整替够用；将来窗口真大了再谈 `strokesPages`）。
- 不动安卓。

## 6. 验证

- spike（纯函数，新建 `spike/ink-window-test.swift`）：want/keep/evict 集合的滞回；装载合并的 z 序（库批 + 期间新画）；
  淘汰时 `strokes` 与 `persistedStrokes` 同步一致（模拟对账不产生假删除）；撤销钉页；
  `inkRows(page range)` 排序与整篇读一致；SQL 聚合（层计数 / 页计数 / 页边 min-max）与内存计算一致。
- 现有 spike 全绿：`ink-store-test`、`ink-edit-test`、`ink-undo-test`、`ink-payload-fast-test`、`canvas-margin-test`。
- 用户实测（我不能替测，见 `verify-backlog-not-verified`）：
  1. 同一篇文档 `footprint` 对比（前 ~10 MB → 后 < 1 MB）；
  2. 快速滚动 / 跳页 / 平板 gotoPage 时笔迹不闪、不缺、不重；
  3. 擦除→撤销、滚远再滚回、撤销仍正确；
  4. 删整层 / 删整页后重开文档，库里确实没了；
  5. 画板模式页边宽度开文档即正确（不用滚到那页才撑开）。

## 7. 实施顺序

1. ①点压缩（一个提交）：类型换名 + 编解码边界 + spike 全绿 + `xcodebuild`。
2. ②-a 存储层：`inkRows(documentId:kind:pages:)` + 三条聚合 SQL + `DELETE by layerId`，进 `ink-store-test`。
3. ②-b 窗口纯函数（want/keep/evict/merge/pin）+ `spike/ink-window-test.swift`。
4. ②-c 接线：`DocTabModel.ensureInkWindow` / 阅读区 settle 入口 / `applyLoadedInk` 改批式 / 淘汰 / 撤销钉页。
5. ②-d 全集消费者逐个改（4.6 表）+ 平板整替 + `PROTOCOL.md` 一句话。
6. Debug 包给用户实测 §6。

## 8. 用户拍板（2026-09-10，四项照推荐）

1. 点类型 **SIMD3<Float>**（16 B）而非 12 B 手写结构体。
2. 窗口参数 `pad = 4` / `keep = 12` 起步。
3. 平板走「窗口变化 settle 时 `strokes` 整替」、不加新消息。
4. 整篇操作（删层 / 计数 / 页边）走 SQL（含 `json_extract`）而不是「先装满再操作」。

## 9. 落地记录（与方案的出入，改代码前看这里）

代码落点：`Sources/App/InkWindow.swift`（纯函数 + `InkPageSummary`）、`DocTabModel.ensureInkWindow / applyInkBatch /
evictInk / ensureInkPageLoaded`、`DocSession` 的 `inkLoadedPages / inkLoadingPages / inkWindowRequests /
inkEnsureLoaded / inkOverflowSeed / inkOverflow() / inkStrokeCount / deleteInkStrokes`、`LibraryStore` 的
`inkRows(pages:) / inkPageSummaries / inkLayerCounts / deleteInkStrokes / inkCount / inkXExtent`、
`InkUndoStack.referencedPages`；阅读区入口在 `ReaderSurface+Render.settleRender`（settle 后 `inkWindowRequests.send`）。
spike：`spike/ink-window-test.swift` 29 项。

- **点压缩**：`InkPoint = SIMD3<Float>`，配 `init(Double, Double, Double)`（`@_disfavoredOverload`，三个字面量时走标准
  Float 版不报 ambiguous）与 `.dx/.dy/.dz`（取 Double）。约定「存 Float、算 Double」：变换在 Double 里算完存回；
  距离命中在 Float 里比，半径 `Float(r)` 转一次。payload 写 `[[Float]]`（JSON 最短十进制，比 Double 短一半）、
  读 `[[Double]]` 再 `Float(d)`，与 `InkPayloadFast` 同一种转换，两条路逐位相同。spike 容差从 1e-9 放到 1e-6。
- **首窗**由 `load()` 在读到进度页后用 `progress ± pad` 装，不等首帧；阅读区首次 settle 再按真实实化范围补齐。
- **检查器按页列表**改读库汇总（`InkPageSummary.load`，后台 + 0.3s 防抖）：色点从「前 6 笔的颜色」变成
  「该页出现过的颜色去重取前 6」（`json_group_array(DISTINCT …)`）；跳转落点用 `anchor_y` 列的最小值。
- **删整页**先 `inkEnsureLoaded` 再走内存删除（可撤销）；**删整层**内存 removeAll + `DELETE … json_extract(payload,'$.layerId')`
  （`COLLATE NOCASE`；默认层连 `layerId IS NULL` 的老行一起）；层计数同样问库，老行归默认层。
- **页边溢出**首值随第一批读库一起算（`inkXExtent`），**只增不减**：擦掉远处笔迹后边界要到重开文档才收回来。
- **撤销栈**引用的页钉住不淘汰；但别的页被淘汰会让后面笔迹的数组下标前移，撤销「删除」时按原下标插回可能落到
  同页更靠上的位置——只影响同页重叠笔迹的叠放序，接受。
- **平板**：`applyInkBatch` 里 `added` 非空才整替一次；淘汰不通知平板（它那份多出来的远页笔迹只是陈旧，
  下一次整替就没了）。`PROTOCOL.md` `strokes` 行补了一句语义。
- `MirrorApply` 等直接写库的路径与内存窗口互不知情——与从前「开文档一次装满」一样，不属本次范围。
