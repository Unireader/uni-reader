# 文字搜索 / 文字选择 / 扫描版 OCR 方案（预留架构）

> 给「下一步执行 agent」的落地方案。地基（协议骨架 + 缓存表 + 阅读区叠加位）**已随 PDF 预览重建一起落地**，
> 本文档定死架构与里程碑，接手时**不需要再决策架构**，直接按 T1→T3 实现即可。
>
> 动手前先读：`REQUIREMENTS.md`、`PDF-VIEWER-REBUILD-PLAN.md`，以及 memory 里 `ux-take-user-literally`。

---

## 0. 背景（为什么要文本层）

Mac 阅读区已从 PDFKit `PDFView` 换成自研**页图流**（`PageStreamView`，见 `PDF-VIEWER-REBUILD-PLAN.md`）。
页面是渲染出来的**位图**，因此丢掉了 `PDFView` 自带的文本选择/搜索/复制。补法：在页图之上叠一层**文本层**。

**核心思想：一个统一的「页面文本层」`PageTextLayer`**，让文字选择 / 搜索 / 复制**只消费它**，
不关心文本从哪来——两个来源喂同一个模型：

```
PageTextLayer { page, runs:[TextRun{ text, x,y,w,h(归一化0~1,左上原点) }], source }
   ├─ 来源① NativePDFTextProvider  ← 数字版 PDF，PDFPage 免费拿字符/词框
   └─ 来源② OCR(provider)          ← 扫描版 PDF（无原生文本）
```

文本层与页图**正交叠加**，坐标全走 `PageLayout` 的归一化↔视图换算（与墨迹层同一套），滚动/缩放自动对齐。

---

## 1. 已落地的「座位」（skeleton，勿重写）

| 资产 | 位置 | 状态 |
|---|---|---|
| `TextRun` / `PageTextLayer` / `PageTextProvider` | `Sources/App/PageText.swift` | 模型 + 协议**已定**；`NativePDFTextProvider.textLayer` 待实现 |
| `NativePDFTextProvider.isLikelyScanned(_:)` | `Sources/App/PageText.swift` | **已实现**（`page.string` 稀疏判定，可直接用于走 OCR 分支） |
| `OCRProvider` 协议 + `VisionOCRProvider` / `HTTPOCRProvider` | `Sources/App/OCR.swift` | 协议**已定**；两个 provider 的 `recognize` 待实现 |
| `OCRRemoteConfig` / `OCRProviderKind` / `OCRPagePayload` | `Sources/App/OCR.swift` | 配置与 payload 契约**已定** |
| `ocr_page` 表（`content_hash,page,provider` PK；payload=JSON） | `Sources/Store/LibraryStore.swift`（schema **v3**） | **已落 + 迁移已验证**（`spike/ocr-store-test.swift` 15/15） |
| OCR 缓存 DAO：`ocrPage` / `upsertOCRPage` / `deleteOCRPages` | `Sources/Store/LibraryStore.swift` | **已实现 + 测试** |
| `OCRPage` 模型 | `Sources/Store/LibraryModels.swift` | **已定** |
| 阅读区叠加位（页图之上叠层） | `Sources/Views/PageStreamView.swift` `pageCell` | 已有墨迹/hover 叠层，文本/选择层照它加 |

---

## 2. 里程碑（建议顺序）

### T1 — 原生文本层 + 文字选择
- 实现 `NativePDFTextProvider.textLayer(forPage:)`：从 `PDFPage` 取字符/词框
  （`page.selection(for: page.bounds)` 逐行、或 `page.numberOfCharacters` + `characterBounds(at:)`），
  用 **mediaBox** 归一化成 `TextRun`（0~1，**左上原点**，与页图/墨迹同约定，注意 PDF 页坐标是左下原点，y 要翻）。
- `PageCell` 叠一层「选择层」：命中测试 `TextRun` → 拖选 → 高亮框（半透明蓝）→ ⌘C 复制拼接文本。
- **交互机制未决**（见 §4）：优先「自绘选择」（命中 run、跨行拼接），**保持原生味**，不引入不可选的 hack。

### T2 — 全文搜索
- ⌘F 搜索栏（原生 `.searchable` 或工具栏输入框）。
- 数字版：直接 `pdf` 逐页 `page.string` 找匹配 + `page.selection(for:)` 拿框；或复用 T1 的 `PageTextLayer`。
- 结果：高亮所有匹配 + 上一个/下一个跳转（走 `session.emitAnchor(origin:"toc")` 定位，复用现成锚点通道）。

### T3 — 扫描版 OCR（两部分：缓存 + 可插拔引擎）
- **判定**：`NativePDFTextProvider.isLikelyScanned(page)` → 该页走 OCR 分支。
- **取缓存**：`store.ocrPage(contentHash:page:provider:)`；命中直接组 `PageTextLayer(source:.ocr)`。
- **miss → 真跑**：渲染该页位图（复用 `PageImageCache.render`）→ `provider.recognize(image:pageSize:)` → 得 `[TextRun]`
  → `OCRPagePayload` 编码 → `store.upsertOCRPage(...)` 回填 → 组文本层。**后台跑，别卡 UI**；跑完刷新该页选择/搜索层。
- **引擎**：
  - `VisionOCRProvider`：`VNRecognizeTextRequest`（离线、免配置、默认）。`VNRecognizedTextObservation.boundingBox`
    是 0~1 **左下原点**，翻 y 成左上原点。
  - `HTTPOCRProvider`：按 `OCRRemoteConfig`（endpoint/apiKey）上传页图 PNG、解析响应框+文本。
    **具体请求/响应契约后面再定**（不一定是 PaddleOCR）。
- **设置 UI**：在偏好里选 `OCRProviderKind`（system/remote）+ 填 `OCRRemoteConfig`。

---

## 3. 数据流 & 缓存/配置拆分（要点）

- **OCR 结果** → 工作区 SQLite `ocr_page`（跨平台、随文件夹移动、换机复用；key = 内容 hash + 页 + 引擎）。
- **provider 配置**（API URL / key）→ **App 设置 / UserDefaults**（本机级、含密钥，**不进工作区共享文件夹**，防外泄）。
- 缓存键用 `content_hash`（= variant 物理内容）而非 document/variant UUID：OCR 是「页面像素 + 引擎」的纯函数，
  这样文件移动/复制/换机只要内容一致就命中同一份缓存。
- hash 变化（改了 PDF）→ `deleteOCRPages(contentHash:)` 清旧缓存（可选，或留着无害）。

---

## 4. 未决点（实现时与用户对齐）

1. **选择交互机制**：自绘选择（命中 `TextRun`、跨行拼接、高亮框）vs 透明可选文本覆盖层。
   倾向自绘（原生味、可控），但 macOS 上跨行选择的手感需落地后对齐。
2. **OCR 触发 UX**：打开即自动检测扫描页并后台 OCR，还是手动「对本文档做 OCR」动作 + 进度。
3. **HTTP OCR 契约**：请求（页图编码/尺寸/参数）与响应（框坐标系/文本分组）的字段映射——**后面再看具体接口**。
4. **文本层粒度**：字符框 / 词框 / 行框——搜索用行足够，选择要词或字符级更顺手，权衡后定。

---

## 附：关键契约速查（已定，别改）

- `TextRun{ text, x,y,w,h }`：归一化 0~1，**左上原点**（与 `PageLayout` / `InkStroke` 一致）。
- `PageTextLayer{ page, runs, source(.native | .ocr(provider)) }`。
- `OCRProvider.recognize(image:CGImage, pageSize:CGSize) -> [TextRun]`；`id` 作缓存 provider 列。
- `ocr_page(content_hash, page, provider, payload BLOB, lang, created_at)`，PK `(content_hash,page,provider)`。
- `ocr_page.payload` = JSON `OCRPagePayload{ w, h, runs:[TextRun] }`。
- 缓存 DAO：`store.ocrPage(contentHash:page:provider:)` / `upsertOCRPage(_:)` / `deleteOCRPages(contentHash:)`。
