# 图片笔记（Image Note）方案 — Mac 端 + 离线镜像

> 状态：**2026-09-13 定方案并落地（Mac + 离线镜像）**；网页平板 / 安卓两模式**本轮不做**（见 §11）。
> 四条拍板（用户 2026-09-13 选的）：① 页面上**图钉 + 气泡**呈现；② PDF 节选入口 = **⌥⇧ 拖**
> （⌥拖发 AI 的行为不动）；③ 离线镜像**这轮一起带上图片**；④ 「待删除」只在**设置里加一行**。

## 1. 需求

**用户原话**：「开始做图片笔记的功能，支持从外部导入，或者从 pdf 节选出图片。图片保存在工作区中，
管理完全由软件管理，图片按照引用计数管理，全部引用被删除后，进入待删除状态，超过 30 天后则彻底删除。」

一句话定义：

> **图片笔记 = 一条挂在「某文档某页某处」的笔记，正文是一张图**（外部导入的文件，或从 PDF 页面上框出来重渲染的一块），
> 图片本体存在工作区包里、由 App 全权管理，笔记没了图片就进入待删除，30 天后真删。

与文字笔记（kind=0）的关系：**同一套壳、不同正文**——图钉、气泡、展开方式（点击/悬浮/始终）、Inspector 列表、
撤销、增量对账落库全部沿用；只是气泡里画的是缩略图 + 一行说明，编辑器里改的是说明文字。

## 2. 数据模型（跨端契约）

### 2.1 图片本体：`Images/` 目录 + `image` 表（schema v13）

```
<工作区>.unrd/
  UniReader/library.sqlite
  PDFs/…
  Images/<sha256>.<ext>          ← 新增；文件名 = 内容 SHA-256 十六进制小写 + 扩展名
```

- **按内容寻址**：同一张图导两次只落一个文件、一行记录、两条引用。文件名不含任何用户信息，
  也不会撞名（撞 = 同一张图）。
- **格式**：`png` / `jpg` / `gif` / `webp` 原字节直接存（不重编码，保画质、省事）；其它能解的
  （HEIC / TIFF / BMP / PDF 页…）统一**转 PNG**再存——网页/安卓将来要显示，不能指望它们认 HEIC。
  PDF 节选一律 **PNG**（文字页的清晰度优先于体积）。
- **尺寸上限**：长边 > 4096px 的导入图先等比缩到 4096（笔记里不需要原图级分辨率，一张 20MB 的照片
  塞进笔记只会拖慢一切）。
- 表结构（跨平台可读；**主键就是 sha256**，于是两端各自导入同一张图也天然合并）：

```sql
CREATE TABLE IF NOT EXISTS image (
  sha256      TEXT PRIMARY KEY,
  ext         TEXT NOT NULL,          -- 'png' / 'jpg' / 'gif' / 'webp'
  width       INTEGER NOT NULL,
  height      INTEGER NOT NULL,
  bytes       INTEGER NOT NULL,
  created_at  TEXT NOT NULL,          -- ISO-8601
  orphaned_at TEXT                    -- NULL = 还有引用；非 NULL = 从这一刻起没有任何引用（待删除）
);
```

### 2.2 笔记：复用 `note` 表，**kind = 6**（image）

同书签（kind=5）/ 草稿纸笔迹（kind=4）的先例：不新建表、不改 note 结构，增量对账 / `ON DELETE CASCADE` /
`mergeDocument` / 离线镜像的行指纹全部原样继承。

| note 列 | 取值 |
|---|---|
| `page` | 0 基页号 |
| `anchor_*` | 页内归一化矩形（0~1，左上原点）。**PDF 节选**：= 框出来的那块在起始页上的矩形（跨页时只记起始页那一段）；**导入**：点锚（x,y = 落点，w = h = 0） |
| `payload` | 显式 JSON（下） |

```json
{
  "image":   "<sha256>",                 // 指向 image 表
  "caption": "说明文字（可空）",
  "display": "tap" | "hover" | "always", // 同文字笔记的 display，缺省 tap
  "source":  { "kind": "pdf", "page": 12, "rect": [x, y, w, h], "pages": 2 }   // 从 PDF 节选：来源页 + 归一化矩形 + 跨了几页
          |  { "kind": "file", "name": "figure.png" },                         // 外部导入：原文件名（纯展示）
  "card":    { "dx": 12, "dy": -8, "w": 300, "h": 240 }  // 可缺：气泡卡片手动摆过的位置 / 宽 / 高度上限（2026-09-16，与文字笔记同一个键，见 `NoteCard`）
}
```

- `image` 是**唯一**的引用形态。「引用计数」= `note` 表里 `kind=6 AND json_extract(payload,'$.image') = sha` 的行数，
  **不存计数列**——存了就要在增删/撤销/镜像合并的每一条路径上维护它，任何一处漏掉就是永久错账；
  数出来的永远对。
- 图片笔记**不上线**（`notes` 广播只发 kind=0，平板本轮不认识 kind=6；`PROTOCOL.md` 不动）。

## 3. 引用计数 / 待删除 / 30 天清理

三条规则，全部在 `LibraryStore`（DAO）里，UI 只调：

1. **对账**（`reconcileImageOrphans(now:)`）：逐行看 `image`：有引用 → `orphaned_at = NULL`；无引用且
   `orphaned_at IS NULL` → `orphaned_at = now`。已经是非 NULL 的**不重置**（否则「删了又恢复又删」把 30 天越拖越长——
   反正一恢复引用就清零了）。
2. **清理**（`purgeImages(before:)`）：`orphaned_at < now − 30d` 的行 → 删文件 + 删行。文件不在了也照删行（幂等）。
3. **触发时机**：① 打开工作区（`WorkspaceManager.open`）先对账再清理；② 删一条图片笔记（对账落库那一步）
   对那一张 sha 单独对账；③ 撤销删除 → 引用回来 → 同一条路径把 `orphaned_at` 清掉；④ 离线镜像合并完两侧各对账一次；
   ⑤ 设置里「立即清理」= 对账 + 以「现在」为界清理待删除的全部（不等 30 天）。

**恢复**靠撤销（⌘Z 把笔记加回来 = 引用回来）。不做「从待删除里挑一张恢复成新笔记」的面板（用户选的）。

## 4. 入口

| 入口 | 动作 | 落点 |
|---|---|---|
| **⌥⇧ 拖**（PDF 节选，主入口） | 与 ⌥拖同一套框选覆盖层（`ReaderSurface+Snip`），松手按页重渲染 → PNG → 存图 → 建笔记 | 锚 = 框在起始页的矩形；图钉落在框**右上角**外侧 |
| 常驻 snip 工具 + ⇧ | 同上（工具已是 snip 时按 ⇧ 即存为笔记，不按 = 发 AI） | 同上 |
| **拖图片文件到页面上** | Finder 拖 png/jpg/… 进阅读区：每个文件一条笔记 | 锚 = 落点（点锚） |
| 右键「导入图片…」 | `NSOpenPanel` 多选 | 锚 = 右键处 |
| ⌘V（剪贴板里是图片、且不是笔迹剪贴板） | 粘贴为图片笔记 | 锚 = 光标位置（不在页面上则当前页视口中心） |

PDF 节选走 `PageSnip.render` 同一条渲染路径（不截屏、按页重渲、倍率按目标像素定），只是输出 PNG 而非 JPEG，
且**在渲染队列上做**（同一份 `PDFDocument` 不能并发用）。

## 5. 页面呈现 + 编辑

- **图钉**：与文字注解同一形制（扁平圆底 + SF Symbol + 0.5 描边），图标 `photo`、底色淡青（与黄/蓝/红三种现有标记一眼分开）。
- **气泡**（`ImageBubbleView`）：与文字气泡共用 `NoteBubble.Metrics`（固定尺寸 / 跟页缩放两种口径，见 `REQUIREMENTS.md §1.2`）；
  里面是缩略图 + 说明（有才画，最多 3 行）。横图撑满气泡宽；**竖图**高到上限（= 气泡宽）后按比例缩窄，气泡跟着收窄贴着图
  （下限 45% 宽）；图不在时占位一小条。**没有铅笔**（压在图上很突兀，2026-09-13 用户改）：点缩略图看原图，
  **右键**出「查看原图 / 编辑… / 删除」。位置规则同文字气泡（右侧优先 → 放不下翻左侧 → 钳进页内）。
  样张自查：`spike/image-bubble-look.swift`（改气泡必跑）。
- **展开方式**：`display` 三态与文字笔记完全一致（点击展开/悬浮/始终），点图钉的语义也一致。
- **看大图**：点气泡里的缩略图 / Inspector 条目右键「查看」→ `.sheet` 里等比铺满显示（原图分辨率），
  带「复制图片」「在 Finder 中显示」「关闭」。
- **编辑器**（`ImageNoteEditorSheet`）：缩略图预览 + 说明 `TextEditor` + 展开方式分段 + 删除。⌘回车保存、Esc 取消。
- **拖图钉**：与点注解同一条 `notePinDragGesture`（命中测试扩到图片图钉）。
- **撤销**：`InkPatch` 加 `images` 一栏，`inkEdit {}` 前后一比同样记账。
- **缩略图缓存**：`ImageThumbCache`（sha → CGImage，按像素宽分档，NSCache 上限 64MB）——页面气泡 / Inspector / 编辑器共用，
  别每帧从盘上解码。

## 6. Inspector

「笔记」页新增分段**「图片」**：缩略图（48pt）+ 说明或来源（「第 N 页节选」/ 原文件名）+ 页码；点条目跳转，
右键：编辑 / 查看大图 / 删除；× 删除。

## 7. 离线镜像

`image` 表**走 OCR 那条纯 additive 通道**，不进三方合并、不进 `sync_base`（`OFFLINE-MIRROR-PLAN.md §4` 的分类）：

- **建镜像**（`MirrorBuilder.create`）：`image` 表随 `VACUUM INTO` 整份过去；`Images/` 里**表里有行的文件**全部复制
  （小文件、不做选择性）；估算里计入字节数。
- **干跑**（`MirrorDiff.compute`）：`imagesToSource` / `imagesToMirror` = 对面**缺行或缺文件**的 sha 列表
  （`MirrorStore.imageKeys` 给出「有行 ∧ 文件在」的集合；已 orphan 超 30 天的不补——马上要删的东西没必要搬）。
- **应用**（`MirrorApply.fillImages`）：事务外、幂等——补行（`INSERT OR IGNORE`，**保留对面的 `orphaned_at`**）+ 拷文件
  （`.part` 原子写）。然后两侧各 `reconcileImageOrphans`。
  🔴 `orphaned_at` 补过去时**原样带过去**而不是重置成 now：两侧各自 30 天到期各自删；若重置，
  一侧先删、另一侧再补回来、再重置……永远删不干净。
- **报告**：多一行「图片：写入硬盘 N 张 / 拉回本机 M 张」。
- `isCleanPushToMirror` 的门槛**不看图片**（同 OCR 的理由：只增不改不删，不影响基线证据）。

## 8. 设置里那一行

设置 → 通用 → 「图片笔记」区块：列出**当前打开的每个工作区**：「《名字》 图片 N 张 · 待删除 M 张（30 天后自动清理）」+
「立即清理」（M = 0 时禁用）。设置窗是 App 级的，工作区是窗口级的，所以按打开着的工作区逐个列。

## 9. 代码落点

| 层 | 文件 | 内容 |
|---|---|---|
| Store | `Store/LibraryModels.swift` | `LibImage` |
| Store | `Store/LibraryStore.swift` | v13 建表；`images()` / `image(sha:)` / `insertImageIfAbsent` / `deleteImage` / `imageRefCount(s)` / `reconcileImageOrphans` / `purgeableImages` / `imageStats` |
| Store | `Store/ImageAssets.swift` | **纯文件层**：sha256、格式判定与转 PNG、长边限制、原子写、`url(sha:ext:)`、读尺寸（ImageIO，spike 可编） |
| App | `App/ImageNoteModel.swift` | `ImageNote`（kind=6）+ payload 编解码 + `ImageThumbCache` |
| App | `App/DocSession.swift` / `DocTabModel.swift` | `imageNotes` + `persistedImageNotes`；load/persist/clear/flush；删引用后对账 |
| App | `App/WorkspaceManager.swift` | `imageNotes(documentId:)` / `saveImageNote` / `deleteImageNote`（删完对账那张）/ `storeImage(data:)` / `imageURL` / `imageStats` / `purgeImagesNow`；open 时对账 + 清理 |
| App | `App/InkUndo.swift` + `DocSession+InkUndo.swift` | `InkPatch.images` |
| Views | `Views/ImageNoteViews.swift` | `ImageBubbleView` / `ImageNoteEditorSheet` / `ImageViewerSheet` |
| Views | `Views/PageCellView.swift` / `PageStreamSupport.swift` / `PageStreamView.swift` | 图钉 + 气泡 + buckets + 编辑器 sheet 挂点 |
| Views | `Views/ReaderSurface+Snip.swift` | ⌥⇧ 分流 → `saveSnipAsImageNote` |
| Views | `Views/ReaderSurface+ImageNote.swift` | 导入（拖放 / 面板 / ⌘V）、建笔记、编辑器分派、命中测试 |
| Views | `Views/InspectorView.swift` | 「图片」分段 |
| Views | `Views/SettingsView.swift` | 「图片笔记」区块 |
| Mirror | `Store/MirrorStore.swift` / `MirrorDiff.swift` / `MirrorApply.swift` / `MirrorBuilder.swift` / `MirrorReport.swift` | §7 |
| 测试 | `spike/image-store-test.swift` | DAO + 文件层 + 引用计数 / 待删除 / 清理 / payload 编解码 |
| 测试 | `spike/mirror-*.swift` | 图片补齐（行 + 文件 + orphaned_at 保留） |

## 10. 验证

- `spike/image-store-test.swift`、`mirror-build-test`、`mirror-apply-test`、`mirror-diff-test`、`store-test`、`ink-undo-test` 全绿；
  `xcodebuild` 过。
- 真机（用户）：⌥⇧ 拖存图 / 拖文件 / ⌘V / 右键导入；图钉三种展开方式；看大图；Inspector 跳转与删除；⌘Z 恢复后
  设置里「待删除」数字回落；建镜像后镜像上图片可见；镜像上删笔记同步回来后源盘进待删除。

## 11. 范围外（本轮不做）

- **网页平板 / 安卓两模式**：`notes` 广播不发 kind=6；安卓 `Schema.kt` 不建 `image` 表（老库由 Mac 端 `CREATE TABLE IF NOT EXISTS` 补），
  安卓读 note 时对不认识的 kind 应当跳过（现状即如此）。要做时的契约就是 §2，线格式需要新增「图片笔记列表 + 取图端点」。
- 图片笔记进 AI（把图发给模型）——`AIPanelModel.attach(imageJPEG:)` 现成，需要时一行接上。
- 图片笔记的框选/图层/擦除：与文字笔记同样不参与。
