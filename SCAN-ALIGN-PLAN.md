# SCAN-ALIGN-PLAN.md — 扫描页对齐（歪斜 + 左右偏移）

> **一句话**：扫描件每页的正文栏角度、位置都不一样（翻页时正文左右跳、页内一行行往一边斜）。
> 开关打开后，Mac 把全书测一遍，给每页算一个「旋转 + 平移」，**对齐后的页面从此就是这篇文档的页面坐标**。
>
> 状态：2026-09-17 用户拍板，实现中。三端（Mac / web 采集页 / 安卓两模式）按本文件的契约实现。

---

## 1. 拍板记录（2026-09-17）

| 问题 | 结论 |
|---|---|
| 存原始坐标 + 显示时换算，还是对齐后的页面直接当页面坐标？ | **后者**。用户：「数据可以清理掉，我还是希望功能优先」。前者要改约 35 处坐标换算（笔迹 / 高亮 / 图钉 / 框选 / 拖动…），后者这些代码一行不动 |
| 安卓模式1 | **与 Mac 同一批做**（它自己用 Pdfium 出图，不改就错位） |
| 开关位置 | **「视图」菜单「对齐扫描页」，和画板模式放在一起**；按文件（内容哈希）记住，默认关 |
| 切换时已有批注 | **不换算**，切换前弹窗提示条数；这篇的 OCR 结果清掉重新识别 |
| 测量结果 | **存下就固定**，不因算法改进自动重测（否则批注又会偏）。本期不做「重新检测」入口 |

实测依据（`软件工程 2024张琼声_带目录.pdf`，228 页）：歪斜中位数 0.38°、最大 1.35°；相邻两页正文栏中心相差中位数 13pt、
最大 27pt（页宽 ~500pt）；页宽 489.6~506.9pt → 按页宽铺满时字号有 3.5% 的忽大忽小；能测到边的页栏宽全是 396pt ±1。

## 2. 坐标契约（🔴 三端必须逐式一致）

### 2.1 两个空间

- **原始显示空间**（第 i 页）：该页 effective box（CropBox 有效用 CropBox，否则 MediaBox）按 `/Rotate` 转正后的显示坐标，
  **左上原点、y 向下、单位 pt**，尺寸 `(sw, sh)`。就是对齐功能出现之前所有端的「页面」。
- **对齐显示空间**：尺寸 `(W, sh)`。`W` 是**全文档统一**的目标页宽（本期取各页 `sw` 的中位数）；高度沿用该页自己的 `sh`。

开关打开时，笔迹 / 高亮 / 笔记 / 书签 / 草稿纸锚点 / OCR 行框等**一切页内归一化坐标**都是相对对齐显示空间的 `(x/W, y/sh)`。
开关关闭时一切照旧（对齐显示空间 = 原始显示空间）。

### 2.2 每页变换（原始 → 对齐，y 向下）

每页参数 `(rot, dx, dy, sw, sh)`，`rot` 弧度，`dx`/`dy` pt。记 `c = cos(rot)`，`s = sin(rot)`：

```
u = p.x − sw/2          v = p.y − sh/2
q.x =  c·u + s·v + W/2  + dx
q.y = −s·u + c·v + sh/2 + dy
```

逆变换（对齐 → 原始）：

```
u = q.x − W/2 − dx      v = q.y − sh/2 − dy
p.x = c·u − s·v + sw/2
p.y = s·u + c·v + sh/2
```

- `rot` 的含义：原图里文字行的斜率角（y 向下坐标里「往右往下斜」为正）。上面的矩阵把它转平。
- 绕**原始页中心**转，再把中心挪到 `(W/2 + dx, sh/2 + dy)`。`dx` 把正文栏中心对到 `W/2`；`dy` 本期恒 0（预留，别省略这一项）。
- 出图时**先铺白底再画**：转出页外的角被裁掉、页内空出的角是白的。

**CoreGraphics（y 向上、左下原点）等价写法**（Mac `PageBitmap`），`X = p.x`、`Y = sh − p.y`：

```
CGAffineTransform(a: c, b: s, c: −s, d: c,
                  tx: −c·sw/2 + s·sh/2 + W/2 + dx,
                  ty: −s·sw/2 − c·sh/2 + sh/2 − dy)
```

两种写法的一致性由 `spike/scan-align-test.swift` 钉死。安卓 `android.graphics.Matrix`（y 向下）直接用 y 向下那组：
`setValues([c, s, W/2+dx − c·sw/2 − s·sh/2,  −s, c, sh/2+dy + s·sw/2 − c·sh/2,  0, 0, 1])`。

### 2.3 与 PDF 原生页坐标互转

原生页坐标（PDFKit 选区 / 搜索命中 / 目录落点，box 局部、左下原点、未旋转）→ 原始显示空间（既有 `PageGeometry`）
→ 本节变换 → 对齐显示空间。矩形过变换后取**四角包围盒**（最多 1.35° 的旋转，包围盒只比原框大一点点）。反向同理。

## 3. 存储（schema v14，跨端契约）

```sql
CREATE TABLE IF NOT EXISTS page_align (
  content_hash TEXT PRIMARY KEY,
  enabled INTEGER NOT NULL DEFAULT 0,
  page_count INTEGER NOT NULL,
  payload BLOB NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

- **按内容哈希**（同 `ocr_page`/`page_geom`）：参数是某一份文件的几何事实。开关也按内容哈希记——同一篇文档的另一个版本文件要单独开。
- `payload` = UTF-8 JSON，**显式数组**（与 note payload 同风格）：

  ```json
  {"v":1,"w":497.5,"pages":[[rot,dx,dy,sw,sh],[…],…]}
  ```

  `pages.count == page_count`。`v` = 格式版本（当前 1）；读到不认识的 `v` 一律当作没有对齐参数（按关处理）。
- `created_at` = 测量时刻；`updated_at` = 最近一次开 / 关的时刻（离线镜像按它取新，见 §5）。
- 关掉开关**不删行**（`enabled=0`），再打开不用重测、结果不变。
- **只有 Mac 会写这张表**（测量要跑像素统计）；安卓只读。

### 3.1 显示身份（缓存键）

`displayKey = content_hash`（未开）或 `content_hash + "~a" + stamp`（开着），
`stamp = SHA-256(payload) 的前 8 个十六进制小写字符`。

凡是「这份内容画出来长什么样」的缓存键一律用 `displayKey`：Mac 阅读区页图（内存 + 磁盘）、平板页图缓存、
安卓模式1 页图缓存、参考窗页图。`~` 与十六进制都不含 `#`，Mac 键格式（`isTileKey` 找 `#t`）不受影响。

## 4. 线协议（`PROTOCOL.md`）

**不加 opcode、不改字节布局**，只改几个字段的取值：

- `layout`(0x31) 的 `docId`/`v`、`toc`(0x3C) 的 `docId`、`bookmarks` 的 `docId`：从「内容哈希」改为 **`displayKey`**。
  客户端本来只拿它们比相等（核对目录 / 书签是不是当前这本、当页图缓存键），不解析，所以不用改客户端代码；
  开关一切换 `v` 就变，平板页图缓存自然换键。
- `layout` 的每页 `(w,h)`、`page`(0x30) 的 `w/h`、参考窗 `/docmeta` 的 `pages`：改为**对齐显示空间**尺寸 `(W, sh)`。
- 平板页图 `/page.png`（含参考窗 `?d=`）由 Mac 按对齐后出图。

于是 web 采集页与安卓模式2 **零改动**。

## 5. 离线镜像（`OFFLINE-MIRROR-PLAN.md` §4）

`page_align` 不进 `MirrorFp.specs`、不进 `sync_base`，另开一条通道（同 `ocr_page` 的性质，但要能传开关）：

- 两侧按 `content_hash` 对：一侧有另一侧没有 → 补过去；两侧都有且 `updated_at` 不同 → **较新的整行覆盖较旧的**。
- 删除不传播（本表没有删除操作）。事务外执行，幂等。
- 干跑报告单列一条「扫描页对齐：写入硬盘 N 本、拉回本机 M 本」。

## 6. 测量算法（只在 Mac，`Sources/App/ScanAlign.swift`）

1. 原始显示空间按 1.5 像素/pt 画灰度图，暗像素（<140）去掉 6pt 页边。
2. **歪斜角**：±3° 内粗扫（0.1°）再细扫（0.01°），打分 = 按「y − x·tanθ」分行累计（线性分摊到相邻两格，避免 0° 的取整假峰）
   后相邻格差的平方和，取最大。
3. **正文栏左右边缘**：按歪斜角转正，切出文字行（行高 7~20pt，自适应阈值 + 合并 ≤1.5pt 的碎缝），
   只看宽度 ≥ 半页的行，找「至少 25% 的行共用」的最左边缘与最右边缘。
4. **定中心**：栏宽 `W0` 取两边都可靠的页的中位数；两边都测到且宽度与 `W0` 相差 ≤4pt 的页直接用；
   否则只测到一边的按 `W0` 推另一边；再用前后 8 页内同奇偶页的中心中位数校验（偏差 >8pt 视为测错，改用邻页值）。
   整页都测不到（插图页、封面）→ 邻页值；邻页也没有 → 不平移（`dx` 使页面居中）。歪斜角测不准（全页无文字）→ 0。
5. 每页耗时 ~25ms（含出图），多份 `PDFDocument` 并行。

## 7. 各端落地要点

### Mac
- `ScanAlign.swift`：纯逻辑（变换、payload 编解码、测量、定中心），spike `scan-align-test.swift`。
- `PageBitmap`：`displaySize/render/renderTile` 带可选 `PageAlign`，画之前套 §2.2 的 CG 变换。**所有出图口**
  （阅读区引擎、缩略图、参考窗、草稿纸垫页、AI 截图、OCR、平板页图、MCP）都要传。
- `PageGeometry`：原生页坐标 ↔ 显示归一化带对齐参数（选字、搜索、目录跳转）。
- `DocSession.scanAlign`（开着才非 nil）+ `displayKey`；开文档时读库；`PageLayout` 高度按 `sh / W` 算，**开着时不读写 `page_geom`**。
- 开关：「视图」菜单「对齐扫描页」→ 确认弹窗（批注条数、OCR 会清掉）→ 无参数则测量（顶部进度提示）→ 落库 → 清 OCR → 重载文档。

### 安卓模式1（2026-09-17 落地）
- `Schema.kt` 建新库时带上表（v14，连同 v13 的 `image` 空表）；`LibraryStore.activePageAlign` 按**打开的那个文件**的内容 hash 读
  （`enabled=1` 且 `v` 认识；页数那道闸在 `PdfSource` 里补，读表时 Pdfium 还没开）。老库没这张表 → 按没开。
- `PdfSource`：`pageSizes` 报 `(W, sh)`；出图 = 原页按「像素/pt = 宽/W」出中间图 → `Canvas.drawBitmap` + §2.2 的 `Matrix` 画进白底成品。
  🔴 **别换成 pdfiumandroid 2.0.1 的带矩阵 `renderPageBitmap(bitmap, Matrix, RectF)`**：它把 `Matrix` 的两个斜切项
  （`MSKEW_X`/`MSKEW_Y`）原样塞进 PDFium `FS_MATRIX` 的 `b`/`c`，而两边含义正好互换 → 旋转方向反过来（看过 2.0.1 源码）。
- 页图内存缓存键带 `displayKey`（模式1 没有磁盘页图缓存）。
- 纯逻辑 `shared/ScanAlign.kt` ↔ `Sources/App/ScanAlign.swift`，戳的跨端向量：样例 payload
  `{"v":1,"w":497.5,"pages":[[0.0123457,-9.25,0,506.9,720],[-0.0063,0.75,0,489.6,706.7]]}` → `7438e8a2`。
- 离线镜像 §5 那条通道（`MirrorDiff.alignPlan` / `MirrorApply.fillAlign` 等 + `MirrorDiffTest` 三条、`MirrorApplyTest` 一条插桩）。

### 安卓模式2 / web 采集页
- 零改动（§4）。
