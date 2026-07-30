# 安卓模式1 独立版 — 设计与实施方案

> 「整体优化」需求③。目标：安卓平板**不依赖 Mac** 直接打开同一个 `.unrd` 工作区读 PDF、写笔迹。
> 这是当初弃 SwiftData、选「自有 schema 的跨平台 SQLite」时就预留好的那一步（`REQUIREMENTS.md §8`）。
> 代码进现有 `android/` 仓库（与模式2 输入板同一个 App）。**Mac 端不需要任何改动。**

## 0. 一句话

同一个 App 启动二选一：「打开工作区」= 本地读 `library.sqlite` + Pdfium 渲染 PDF + 笔迹直接落库；
「连 Mac」= 现有输入板模式。两条路**共用同一套几何 / 输入 / 渲染 / 笔迹算法**，只换两个注入口。

## 1. 已定决策（2026-07-29 用户拍板）

| 项 | 选择 | 含义 |
|---|---|---|
| 数据来源 | **全盘文件权限直接开工作区文件夹** | `MANAGE_EXTERNAL_STORAGE`，安卓端直接打开 `.unrd/UniReader/library.sqlite` 与 `.unrd/PDFs/`，与 Mac 是同一份数据、同一套 schema。工作区靠 U 盘/SMB/同步盘搬到平板。自用侧载，不上商店 |
| App 形态 | **同一个 App，启动二选一** | 共用 `WireCodec`/`InkRenderer`/`PadOverlays`/笔触公式。笔触公式已经是 Mac+JS+Kotlin 三份实现，再分裂就是第四份 |
| 首版范围 | **阅读 + 手写** | 见 §3。目录/搜索/文字选择/OCR/书库管理留给下一版 |

技术选型（本方案定，理由见 §4）：**PdfiumAndroid 渲染** · **裸 `SQLiteDatabase`（不用 Room）** ·
**Compose 做外壳、自定义 View 做画布**。

## 2. 必读契约与参考实现

| 材料 | 内容 |
|---|---|
| `REQUIREMENTS.md §8` | **工作区/schema 的唯一契约**：三层模型 document→variant→location、note 表、进度列、`in_workspace`/`is_relative` 语义 |
| `Sources/Store/LibraryStore.swift` | schema v7 的 DDL 与全部 DAO。安卓端照它写一份 Kotlin 版，**表结构一个字都不能改** |
| `Sources/App/InkModel.swift` | 笔迹落库形态（`note` kind=2 + payload JSON），§6 抄的就是它 |
| `Sources/App/InkEdit.swift` | `splitStroke`（局部擦除）/ `translated`（框选平移）/ `rulerSnap`——本地权威执行要用同一套算法 |
| `Sources/App/PageBitmap.swift` | **页面尺寸口径**：CropBox 有效则用 CropBox，否则 MediaBox。两端不一致 = 笔迹全漂（§9.1） |
| `android/app/src/main/java/.../PadView.kt` | 已有的连续页流几何/输入/惯性/缩放/擦除/框选，模式1 原样复用 |
| `Sources/Views/RadialMenuView.swift` + `AppModel` 的长按检测 | 环形选笔盘的判定逻辑，模式1 要搬到本地（模式2 是 Mac 判、平板画） |

## 3. 首版范围

**做**：
- 权限引导 + 启动页（打开工作区 / 最近工作区 / 连 Mac 当输入板）
- 工作区文档列表（标题、页数、上次打开、阅读进度）
- 阅读：连续页流、fit-width、双指缩放、单指平移 + 惯性、跳页、**进度恢复与保存**
- 手写：四种笔（圆珠/钢笔/马克/铅笔）、压感、尺子（45° 吸附）、**笔迹落 `note` 表**
- 擦除：整笔 / 局部两模式（与 Mac `splitStroke` 同一算法）
- 多图层：`ink_layer` 表读写、切换/显示隐藏/新建
- 框选移动（笔迹 + 文字注解），本地权威执行
- 文字注解（kind=0 点注解）：新建 / 编辑 / 删除
- 已有高亮（kind=3）**只渲染不新建**——新建高亮要先有文字选择，属下一版
- 环形选笔盘 + 长按进度环（判定搬到本地）

**不做**（下一版）：目录/书签、全文搜索、文字选择与复制、新建高亮、OCR、
书库导入/合并/重定位/多路径探测、笔记侧栏、设置页、深色主题打磨。

**明确不做**：Mac↔安卓的实时同步。工作区是**单写者**模型，约束见 §9.2。

## 4. 技术选型

| 模块 | 选型 | 理由 |
|---|---|---|
| PDF 渲染 | **PdfiumAndroid**（`io.legere:pdfiumandroid`，Apache/BSD 系） | 内置 `PdfRenderer` 只能出图，**没有文字层、没有书签**，下一版的搜索/选择/目录会全部卡死，届时换引擎等于重做。MuPDF 功能最全但 **AGPL**，自用也污染分发。Pdfium 出图 + `TextPage` 文字层 + 书签，一次到位 |
| 本地存储 | **`android.database.sqlite.SQLiteDatabase` 裸用** | schema 是 Mac 那边写死的跨平台契约，Room 要反过来拥有 schema、还会塞自己的 `room_master_table`，属于往共享库里拉屎。照 Mac 的 `SQLite.swift + LibraryStore.swift` 写一份薄封装即可 |
| UI 外壳 | **Compose** | 书库列表/启动页/设置这类常规 UI，Compose 写得快 |
| 阅读+书写画布 | **自定义 `View`（沿用 `PadView` 血统），Compose 里用 `AndroidView` 托住** | 手写笔的 `MotionEvent`（toolType/pressure/历史点/hover）掌控最直接，这条结论模式2 已经验证过（`ANDROID-MODE2-PLAN.md §3`）。Compose 在高压感采样和 hover 上反而绕 |
| 权限 | `MANAGE_EXTERNAL_STORAGE`（API 30+）+ 旧版 `READ/WRITE_EXTERNAL_STORAGE` | 直开任意路径的工作区（含 U 盘/SD/同步目录）。小米等国产 ROM 需在设置里额外允许，启动页要有引导 |

> ⚠️ **依赖我不装**：`io.legere:pdfiumandroid` 要加进 `android/app/build.gradle.kts` 后由你执行同步
> （首次要联网，不能 `--offline`）。命令见 §10 M0。

## 5. 工程结构

单 app module，按职责分包。`shared/` 是两种模式共用的部分——**改这里两边一起受益，这是「同一个 App」的全部意义**。

```
android/app/src/main/java/com/xvan/unireader/
  Launcher.kt              // 启动页：打开工作区 / 最近 / 连 Mac；权限引导
  shared/
    Ink.kt                 // Pen / Pt3 / Stroke / Layer / TextNote —— 中立模型（见 §5.1）
    InkRenderer.kt         // 笔迹绘制（已存在，改成吃中立模型）
    PadOverlays.kt         // 环形盘/进度环/笔记标记/橡皮圈/框选框（已存在）
    PadConst.kt            // 常量与公式（已存在）
    InkEdit.kt             // ✚ splitStroke / translated / rulerSnap（从 Mac 搬）
    PageCanvasView.kt      // ✚ 由现 PadView 抽出：几何+输入+渲染，不含"提交给谁"
    PageImageSource.kt     // ✚ 接口：request(page, widthPx) -> Bitmap?
    InkBackend.kt          // ✚ 接口：落笔/擦除/框选/注解的提交口 + 真源回推
  pad/                     // 模式2 输入板（现有代码，收敛到这两个接口的实现）
    WireCodec.kt  MacClient.kt  UdpSender.kt  PageFetcher.kt(=PageImageSource)
    WireInkBackend.kt      // ✚ 发帧 + 等 Mac 回传 strokes
    PadActivity.kt         // 现 MainActivity 改名
  local/                   // 模式1 独立版
    store/  Sqlite.kt  LibraryStore.kt  Models.kt      // schema v7 的 Kotlin 版
    Workspace.kt           // 打开/校验 .unrd、最近列表、PDFs/ 路径解析
    PdfSource.kt           // Pdfium 渲染 + 位图 LRU（=PageImageSource）
    LocalInkBackend.kt     // 本地权威执行 + 落库（=InkBackend）
    RadialController.kt    // ✚ 长按检测/扇区判定（从 Mac 搬，模式2 里这段在 Mac）
    LibraryScreen.kt  ReaderScreen.kt                  // Compose 外壳
```

### 5.1 核心设计：两种模式只差两个注入口

现在的 `PadView` 里，"这一笔提交给谁"和"页图哪来"是写死的（发 UDP / HTTP 取图）。抽成两个接口后，
**几何、输入、惯性、缩放、渲染、擦除命中、框选判定、尺子吸附全部原样共用**：

```kotlin
interface PageImageSource { fun request(page: Int, widthPx: Int, cb: (Bitmap?) -> Unit) }

interface InkBackend {
    fun inkBegin(page: Int, pen: Pen, pt: Pt3, line: Boolean)
    fun inkMove(pts: List<Pt3>)
    fun inkEnd()
    fun erase(page: Int, pts: List<Pt2>)
    fun lassoMove(page: Int, box: FloatArray, dx: Float, dy: Float)
    fun upsertNote(n: TextNote); fun deleteNote(id: String)
    /** 权威笔迹回推（模式2 = Mac 的 strokes 广播；模式1 = 本地提交后自己回推） */
    var onStrokes: (List<Stroke>) -> Unit
    var onNotes: (List<TextNote>) -> Unit
}
```

这不是为抽象而抽象——**Mac 端「客户端乐观预览 + 服务端复判执行」的既有惯例，在模式1 里天然退化成
「服务端就在进程内」**。`PadView` 里那套"本地先画、等真源回推再清"的代码一行都不用改：模式1 的
`LocalInkBackend` 只是把「发帧等 Mac」换成「就地算完立刻回推」，回推路径完全一样。
框选移动尤其如此：模式2 里 Mac 不信任平板的本地命中、要用真源复判（`PROTOCOL.md lassoMove`），
模式1 里这个"复判"就是 `LocalInkBackend` 拿自己那份 `strokes` 跑同一个 `lassoHitTest`。

## 6. 数据层：跨平台 schema 契约

**红线：安卓端只能读写 Mac 已定义的表和 payload 形状，不得新增列/表/键。** 需要新字段 = 先改
`REQUIREMENTS.md §8` + Mac 端 + 升 `schema_version`，两端一起动（同 `PROTOCOL.md` 的线格式红线）。

工作区布局（`.unrd` 在 macOS 上是包，在安卓上就是普通目录）：
```
<名字>.unrd/
  UniReader/library.sqlite      # 全部元数据、笔记、笔迹、图层
  PDFs/<uuid>.pdf               # 拷进工作区的文件（location.in_workspace=1，path 为工作区相对路径）
```

**schema v7 的表**（DDL 见 `LibraryStore.swift`，逐字照搬）：
`meta` · `document` · `variant` · `location` · `note` · `ocr_page` · `ink_layer`

**坐标系**：所有 anchor / points / rects 一律**页内归一化 0~1、左上原点**，与线格式、与 Mac 完全同系。
页面尺寸口径见 §9.1。

**`note` 的四种 kind 与 payload JSON**（首版用到 0/2/3）：

| kind | 含义 | anchor 列 | payload JSON |
|---|---|---|---|
| 0 | 文字注解 | 点注解为零尺寸（anchor=落点）；选区注解为 anchor 矩形 | `{quote, text, rects:[[x,y,w,h]], color:{r,g,b,a}, type_id}` |
| 1 | 会话笔记（预留 AI） | — | 用户已明确暂不做 |
| 2 | 手写笔迹 | 归一化点的**包围盒** | `{color:{r,g,b,a}, width, type, points:[[x,y,pressure]], layerId}` |
| 3 | 高亮 | 选区包围盒 | `{quote, rects:[[x,y,w,h]], color:{r,g,b,a}}` |

- `color.r/g/b` 是 **0~255 的浮点数**，`a` 是 0~1（Mac 的 `InkColor` 就这么存的，别当成 0~1 的 rgb）。
- `type` 是笔型**字符串**：`ballpoint` / `fountain` / `marker` / `pencil`（Swift enum 的 rawValue）。
  线格式那边是 u8 编号，两者的映射表在 `PROTOCOL.md §2`——**转换点只此一处，别到处散**。
- `layerId` / `type_id` 是 UUID 串；缺键要按 Mac 的兜底走（`layerId` 缺 → `InkLayer.defaultID`
  = `00000000-0000-0000-0000-000000000001`；`type_id` 缺 → null）。
- ⚠️ **`ink_layer` 存的是色名不是 RGB**：真库里该列是 `color_key='red'` 这种字符串键，
  而线格式的 `Layer` 原语是 u8 r/g/b（`PROTOCOL.md §4`）。模式1 必须把 Mac 那份
  **key → RGB 映射表**一起搬过来（M3），否则图层列表的色点与 Mac 上不是一个颜色。
  （2026-07-29 用真工作区实测发现，本节原先漏了这层转换。）
- `note.id` 是 UUID 串，**擦除靠它一一映射删除**，重开加载必须按 `note.id` 复原，不能重新生成。
- 时间戳一律 **ISO-8601 文本**。

**进度**：`document.read_page` / `read_frac` / `read_zoom`（相对 fit-width 的倍率）/ `read_hfrac`。
安卓端写同样四列，Mac 重开即续上。

**首版的简化**（写进代码注释，别装作支持了）：
- 只认 `location.in_workspace=1`（工作区内相对路径）与绝对路径两种；`is_relative=1`
  （外置卷相对路径）首版按"路径失效"处理，提示用户在 Mac 上把文件拷进工作区。
- 不做 variant 探测/合并/重定位——一个文档取**第一条能打开的 location** 即可。

## 7. 渲染层

- 几何完全沿用 `PadView`：连续页列、`GAP=8dp`、`dispH/offY/totalH`、`scrollY/scrollX` 单一真源、
  `topVisiblePage()` 的严格 `<` 边界。模式2 已经跑通，不重新发明。
- `layout` 的来源改为：打开 PDF 后一次性取全部页的 `(w, h)`（Pdfium `getPageSize`，
  **注意 §9.1 的 box 口径**），塞进同一个 `pagesWH`。
- 页图：`PdfSource` 按 `(page, 目标宽度档位)` 渲染并 LRU 缓存（按字节数上限，参考 Mac 的
  `PageRenderEngine` 512MB 口径按平板内存下调，建议 128~192MB）。渲染在后台线程池（2~3 线程），
  可见页优先、上下各一屏预取——与 `ensureImages()` 现有策略一致。
- 缩放时先用已有低清位图拉伸顶着，高清出来再换（Mac 端缩放掉帧那次的教训：**别在缩放过程中
  同步等渲染**，见 `HISTORY.md` 0.1.5）。

## 8. 笔迹层：复用与新写

| 能力 | 来源 |
|---|---|
| 笔触宽度/透明度公式、尺子吸附、盘/环几何常量 | `PadConst.kt` **原样复用**（已与 Mac/JS 对齐） |
| 笔迹绘制（marker 整条成 path、单点圆点、补末段） | `InkRenderer.kt` **原样复用** |
| 盘/环/笔记标记/橡皮圈/框选框绘制 | `PadOverlays.kt` **原样复用** |
| 擦除命中（整笔/局部）、框选命中、坐标 clamp | `PadView.kt` 现有实现**原样复用**（它本来就是 Mac 算法的复刻） |
| `splitStroke` / `translated` | ✚ 从 `Sources/App/InkEdit.swift` 搬一份 Kotlin 版 |
| 长按检测 → 进度环 → 环形盘 → 扇区判定 → 提交 | ✚ 从 Mac 的 `AppModel` 搬（模式2 里这段跑在 Mac，模式1 得自己判） |
| 笔迹持久化（增量落库、擦除后的增删映射） | ✚ 新写 `LocalInkBackend` + `LibraryStore` |

> 环形盘的取消区半径/长按位移阈值在模式2 里是 Mac 用 `padGeom.pageW`（dp）换算的；
> 模式1 里没有这层换算——直接用 `PadConst.RD.HUB` 的 dp 值即可，**两模式的手感因此天然一致**。

## 9. 关键风险与坑

### 9.1 页面尺寸口径必须两端一致（最要命）

Mac 用 **CropBox 有效则 CropBox、否则 MediaBox**（`PageBitmap.effectiveBox`）。
安卓端 Pdfium 的页尺寸若取了另一个 box，同一份 PDF 两端算出的宽高比就不同 →
归一化坐标换算出的位置不同 → **Mac 上写的笔迹在平板上整体偏移/缩放**，且是那种"看着差一点点、
说不清哪错了"的 bug。
**M2 的硬验收项**：拿 `tools/flatten-cropbox-pdf.swift` 处理前的那种「MediaBox 跨页 + CropBox 裁半」
的扫描件（Mac 端为此修过一次，见 `HISTORY.md` 0.1.2）在两端对比页宽高比，必须逐页相等。
若 Pdfium 口径不同，就在安卓端显式读 box 自己算，别指望默认值。

### 9.2 单写者约束（本方案不解决，只约束）

工作区没有任何同步/加锁机制。**同一时间只能有一端打开同一个工作区。**
- Mac 用 WAL 模式。安卓端**打开时与退出时各做一次 `PRAGMA wal_checkpoint(TRUNCATE)`**，
  让 `-wal`/`-shm` 落回主库文件——否则用同步盘/U 盘搬运时只搬 `.sqlite` 会丢掉最近的写入。
- 工作区放在**云盘同步目录**上尤其危险：文件级冲突会整库回退。建议 U 盘物理搬运，或 Syncthing 单向。
- 首版就在启动页写一行提醒即可，不做锁。将来要做，方向是 `meta` 里记 `last_writer`+租约。

### 9.3 其余

- `MANAGE_EXTERNAL_STORAGE` 在小米/HyperOS 上需要用户去设置里单独授予，且系统会警告。启动页要有
  「去授权」按钮 + 说明，不能默默失败（**静默失效先打点**：授权状态、选中路径、库打开结果都要有日志）。
- SQLite 放在 FAT32/exFAT 的 U 盘上时 WAL 可能建不起来（缺共享内存）。打开失败要给出明确文案，
  而不是"打不开"。**2026-07-30 已做**：`Db.open` 带 WAL 标志失败时**退一步不用 WAL 再开一次**
  （能打开总比打不开好），仍失败才抛，且异常消息里列出四种可能原因（卷被拔/FAT32/只读/损坏）
  ——`LibraryActivity` 的表头与 `ReaderActivity` 的弹窗直接显示这句。开成功但 WAL 没启用时，
  阅读界面弹一条 Toast 说明「checkpoint 变成空操作，搬运前整个文件夹一起拷」。
  **真 FAT32 U 盘上的表现模拟器验不了**（模拟器 `/sdcard` 是 FUSE，WAL 正常），进 §11.1。
- Pdfium 是 native 库，**不同 ABI 的 so 会把 APK 撑大**；自用只保留 `arm64-v8a` 即可。
- 笔迹落库频率：一笔一次 `INSERT`（同 Mac 的增量落库），别每帧写；擦除是"删若干 + 插若干"，
  放一个事务里。
- **模式2 的顶栏在竖屏下按钮全被挤没**（2026-07-30 发现，**同日已修**）：`topbar` 里
  `Space(weight=1)` 把装按钮的 `HorizontalScrollView` 压成 0 宽，1080 竖屏下 ◀▶/模式/笔/夜间…
  一个都点不到（胶囊和 PageUp 键还能用）。
  改成模式1 的排法：**按钮组 `weight=1` 可横滑、页码 wrap 钉最右**，去掉 `Space`。
  - 只做这一步还不够：真正的宽度大户是**延迟指标那行字**（`rtt/e2e/nackRTT/mv-s/nack/resend`
    整行要 650px，比竖屏能给按钮的还多）。`LinearLayout` 按顺序量非加权的孩子，排在后面的只能
    捡剩下的——所以第一版改完页码又被顶出屏幕了。最终：**窄屏给 `latText` 加 `maxWidth=120dp`
    + 省略号**，宽屏（模式2 的正常场景＝横屏）保持整行不变；旋转会重建 Activity，判一次即可。
  - 模拟器实测（`uiautomator dump` 的 bounds 为凭据）：竖屏 1080 下按钮组落在 x=645~872 之间、
    可横滑（滑一下就露出 ▶/笔记），页码固定在 [872,1054]；横屏 2400 下指标整行不截断、
    ◀▶/模式/笔/夜间/文字 一次全露出，页码在 [2192,2374]。

### 9.4 笔迹渲染观感与 Mac/网页不一致——**2026-07-30 已修**

2026-07-29 M2 实测发现，**两种模式都受影响**（共用 `shared/InkRenderer.kt`）。

> 口径变更（2026-07-30）：原先记的是「后面随三端算法统一一并处理」，而那条路线（`TODO.md` 路线图 ⑤
> Rust 笔迹核心）**用户已拍板搁置**——所以按下面的本地修法处理，不再等谁。

**现象**：同一条 marker（荧光笔，`rgba(255,214,40,0.4)`）在平板上偏暗发浊（近深橄榄），
Mac/网页上是浅黄透亮。ballpoint 那几条肉眼看一致。

**根因**：`InkRenderer` 用的是 `PorterDuffXfermode(PorterDuff.Mode.MULTIPLY)`——那是在**预乘 alpha**
上做 `Sc*Dc` 的老式合成；而网页 Canvas 的 `globalCompositeOperation='multiply'` 与 Mac 的 `.multiply`
是 W3C 规定的**混合模式**（先按 blend 公式混色，再按 alpha 走 source-over 合成）。
黄 40% 压白底：期望 `0.6*255 + 0.4*255 = (255,238,169)`，PorterDuff 实际给出 `0.4*黄 × 白 ≈ (102,86,16)`。

**修法（已落地）**：API 29+ 用 `paint.blendMode = BlendMode.MULTIPLY`（Skia 的规范混合模式，
与 CSS/Core Graphics 同义），API 26~28 保留 PorterDuff 兜底。开关两条路**统一收在一个
`multiply(on)` 私有函数里**——`xfermode` 与 `blendMode` 写的是 Paint 同一处状态，一处设、
另一处忘了清，下一条笔画就会继承上一条的混合模式。

**模拟器凭据（这条不是「看着对」，是算出来的）**：用 `adb exec-out screencap` 取原始 RGBA
逐像素读（脚本见提交记录）：
- 荧光笔压在纯白页上量到 `rgba(255,239,169)`，与 W3C multiply 公式 `0.4×(255,214,40)+0.6×255`
  **逐位相同**（旧的 PorterDuff 给的是 ≈(102,86,16) 的深橄榄）。
- 白底那次证明不了 multiply 真的生效（乘白等于不乘），所以又拿荧光笔**横穿一条蓝色圆珠笔**
  （实测底色 `rgba(36,98,212)`）：交叉处量到 `rgba(36,92,141)`，与 multiply 的预期 (36,92,140)
  差 1（取整），而普通 source-over 会给 (124,144,143)——差得一眼分得清。

**仍要真机看的**（模拟器只证明了数值，证明不了并排观感）：
- pencil 的 `opacityMultFor = 0.85`、fountain 的 `0.3 + p^1.6 * w * 1.3` 压感曲线，三端并排对同一条笔迹；
- 模式2 的真机观感（改的是共用文件，Mac 回传的笔迹也走这条路）；
- 夜间模式下 marker 的表现（`nightFilter` 只反页面层，墨迹不反，混合模式换了要重看一眼）。

### 9.5 打开工作区的 I/O 在主线程（慢卷上会 ANR）——**2026-07-30 已修**

2026-07-29 M3 实测：模拟器上点「最近打开」到书库列表出来要 **3 秒**，其中 `Workspace.check`
（几个 `File.exists/isFile/length`）在 `/sdcard`（FUSE）冷缓存下就花了 **2.1 秒**，`LibraryStore.open`
又一秒。全部跑在主线程上。

真机内部存储会快得多，但**工作区放 U 盘/SD/同步盘是本方案的常规用法**（§1 的数据来源就是这么定的），
那种卷上几秒起步，够触发 ANR。

**已修（2026-07-30）**：新增 `shared/Bg.kt`——`Activity.runInBackground(what, work, ok, fail, discard)`
（单发 I/O + 主线程回调，不引协程；耗时一律打点，超 700ms 打 warn）与 `Bg.submit`（甩出去的收尾 I/O）。
挪到后台的五处：

| 位置 | 挪走的活儿 | 界面上的反馈 |
| --- | --- | --- |
| `Launcher.openWorkspace` | `Workspace.check` | 不可取消的「正在打开…」（兼作连点保护，否则会开出两个书库） |
| `Launcher.browse` 的 `render` | `listFiles` + 逐条 `isDirectory` | 「正在读取目录…」；旧结果按 token 丢弃 |
| `LibraryActivity.reload` | 开库 + `allDocuments` + 每篇的 `noteCount`/`firstOpenablePdf` | 首次「正在读取工作区…」，之后**保留旧列表**（清空会闪几秒白屏） |
| `ReaderActivity.load` | 开库、找 PDF、`PdfSource` 构造（读全部页尺寸）、图层、笔迹 | 居中「正在打开…」；失败弹原因再退（原先静默 finish） |
| `ReaderActivity.onDestroy` / `Opened.discard` | 关库（含 `wal_checkpoint(TRUNCATE)`）+ 关 Pdfium | 无（退出动画不再等它） |

真机实测（模拟器 `/sdcard`，logcat 里 `UniReader/Bg` 逐项带耗时与 tid）：打开文档 **0.8~1.4s**、
返回书库重读一次撞上并发 checkpoint 实测 **4.6s**（比原记录的 3 秒更糟，主线程上这就是确定的 ANR）、
关库 **1.1s**——全部跑在 `unireader-io` 线程，主线程 `Choreographer: Skipped` 归零。

**顺手修掉一个由此暴露的时序 BUG**（`PageCanvasView.onFirstGeometry`）：它原先只在 `onSizeChanged`
里判「视口有尺寸 + 页表已到」，隐含假设页表先到。改成异步打开后顺序反了——布局时 `pageCount`
还是 0、页表 1.4 秒后才来，钩子于是**永不触发**，表现是阅读进度静默不复原（每次打开都停在页顶），
而日志照旧写着「复原到第 8 页」。现在 `setPages` 里也判一次，**谁后到都算**；对应地
`ReaderActivity` 必须在 `setPages` **之前**挂钩子，挂晚一步就永远等不到第二次机会。

**残留的主线程写库也修完了（2026-07-30）**：新增 `local/store/StoreQueue.kt`——一条单线程
executor（`unireader-store`）**独占** `LibraryStore`。给出去的是所有权不是一把锁：库开出来之后
主线程一次都不碰它，**读也走队列**（读同样要走磁盘）。`submit(what, work)` 是甩出去的写，
`submit(what, work, then)` 的 `work` 在队列线程跑、结果 `post` 回主线程给 `then`。
挪走的七处：落笔 INSERT、擦除事务、框选移动事务、文字注解 upsert/delete、图层可见性/新建、
进度 UPDATE，外加它们各自后面那次「重读回推」（原先也在主线程）。

顺带解决与顺带暴露的三件事：

- **顺序不再靠主线程消息队列排**：写完接着 `submit` 一次重读，FIFO 保证读到的是写之后的状态；
  原先靠 `post { reloadStrokes() }` 绕开「还在 `endPen` 里」的时序，现在天然满足。
  退出时 `close()` 也排在队尾——`onDestroy` 里刚提交的那次进度一定先落盘，再走关库的 checkpoint。
- **擦除的差异算法从 `LocalCanvasView` 挪进 `LibraryStore.reconcileStrokes`**（可插桩测试），
  并改成**头一段沿用原 id**（`updateStrokePoints`）而不是「删原条 + 全部新插」。
  必须改：写库放到后台之后，「擦 → 落库 → 回推」这条链变长了，用户完全可能在回推到达之前又擦一笔，
  而第二次的期望状态是照着**旧 id** 算出来的；原 id 若已被换成随机新 id，第二次比对会认定
  「库里这些 id 期望状态里一个都没有」，把整页笔迹删光。插桩测试 `回推没到就再擦一次不会把整页笔迹删光`
  在旧实现上实测 **3 段变 0 段**。顺带也对上了 `upsertNote` 那句注释的原意（`created_at` 不被擦除刷新）。
- **修掉一个由此暴露的丢数据 BUG**：`reconcileStrokes` 的入参是**画布上看得见的**笔迹
  （`applyStrokes` 按图层可见性滤过），而它遍历的是库里**全部**笔迹——隐藏图层的笔迹不在入参里，
  于是被当成「被擦光了」全删掉。**藏一个图层再随便擦一下，那一层就没了，界面上什么都看不出来。**
  现在按 Mac `eraseNear` 的 `vis.contains(layerId)` 口径跳过隐藏层。模拟器实测：藏掉 Layer 2
  再擦 7 次，`可见=N/N+1 隐藏图层=1` 的比例始终差 1，`sqlite3` 查 `layerId` 分组那条仍在。

实测凭据（模拟器，`logcat -v threadtime` 的 tid = 18089 = `unireader-store`，主线程是 17814）：
`落笔 page=10 点数=3` 与 `擦除落库：删 0 条，改 1 条，插 1 段`、`框选移动落库：笔迹 2 条 …`
全在 18089；紧随其后的 `回推笔迹 可见=…` 全在 17814。滑动两秒后 `sqlite3` 查 `read_page`
由 9 变 11——进度也确实是经队列写进去的。21 条插桩测试（含新增的 2 条 `StoreQueueTest`：
「只许一条线程碰库 + 执行顺序 = 提交顺序 + 关库排队尾」和 3 条擦除对齐）全绿。

## 10. 实施顺序

> 下面各条的「已完成」= **代码完成 + 模拟器/日志/`sqlite3` 对账能证明的部分**。
> 凡要人眼或手感判定的都攒在 **§11.1 待真机验证清单**，不算进「已完成」。

- **M0 骨架**：加 Pdfium 依赖、包结构重排（`shared/` `pad/` `local/`）、启动页 + 权限引导。
  模式2 必须重排后仍能跑通（这是回归基线）。
  ```
  # 依赖同步（首次要联网，不能 --offline）
  G=$(echo ~/.gradle/wrapper/dists/gradle-9.5.1-bin/*/gradle-9.5.1/bin/gradle)
  "$G" -p ~/agent-home/uni-reader/android :app:assembleDebug
  ```
  **状态：已完成（2026-07-29）**，离线构建 + 5 条 codec 单测全绿，真机手感待验。落地内容：
  - `shared/Ink.kt` 抽出中立模型（`Pen`/`Pt3`/`Pt2`/`Stroke`/`TextNote`/`Layer`/`RadialItem` +
    `MODE_*`/`RK_*` + 笔型编号↔名字唯一转换点），原先它们嵌在 `pad/WireCodec` 里，
    绘制被绑在线格式上。`PadConst`/`InkRenderer`/`PadOverlays` 一并进 `shared/`；
    **依赖方向已单向：`pad`/`local` → `shared`，`shared` 不 import 任何一边（有 grep 红线可复查）**。
  - `MainActivity` → `pad/PadActivity`；新增 `Launcher`（两模式入口 + 全盘权限引导 + 目录浏览器
    + 最近工作区）与 `local/Workspace.kt`（`.unrd` 校验：库文件在否/可读可写/`-wal` 残留字节数）。
  - `namespace`/`applicationId` 由 `com.xvan.unireader.pad` 改为 `com.xvan.unireader`
    → **旧 demo 是不同包名，需 `adb uninstall com.xvan.unireader.pad`**（host/token 偏好会重置）。
  - 与本方案的两处刻意偏差：① 启动页用**经典 View 而非 Compose**——不为两个按钮把 compose
    编译器插件拉进 AGP 9 的内置 Kotlin 里，Compose 推到 M2 真正做书库列表时再引；
    ② `abiFilters` 只留 `arm64-v8a`（§9.3），**x86_64 模拟器因此装不上**。
  - `PRAGMA wal_checkpoint(TRUNCATE)`（§9.2）属数据层，M1 随 `Sqlite.kt` 一起落地。
- **M1 数据层**：`Sqlite.kt` + `LibraryStore.kt`（schema v7 只读优先）+ `Workspace.kt`。
  **先写单测**：拿一个 Mac 造的真工作区，断言文档数/笔迹条数/payload 字段与 `sqlite3` CLI 一致。
  **状态：已完成（2026-07-29）**。`local/store/` 四件套（Sqlite/LibraryModels/Payloads/LibraryStore）
  + `Workspace.resolvePdf`。10 条**插桩**测试（数据层只能跑在设备上，`android.database.sqlite`
  在 JVM 单测里是空壳）全绿，fixture 用 Mac 真造的工作区、写路径只动 cacheDir 副本。
  实测对上了真 payload：键集恰好 `{color,width,type,points,layerId}`、`color` 的 r/g/b 是 0~255
  而 a 是 0~1、anchor 正是点集包围盒；5 条真笔迹全部解码（ballpoint×3 marker×2 共 142 点）。
  两处踩到的坑已写进代码注释：① Mac 的 `ISO8601DateFormatter` 开了 `.withFractionalSeconds`，
  **不带毫秒的时间戳它解析不出来**会静默回落成「现在」，于是按 `created_at` 排的绘制顺序就乱了
  → 安卓写库固定三位毫秒，不能用 `Instant.toString()`；② payload 一律在原始 JSONObject 上改，
  本端不认识的键必须原样保留。
- **M2 阅读**：`PdfSource` + 抽出 `PageCanvasView` + 文档列表 + 打开 + 进度恢复/保存。
  **验收含 §9.1 的 box 口径比对。**
  **状态：已完成（2026-07-29）**。
  - §9.1 **已验收**：47 页真文档（portrait 与 rotation 后变横向的页混排）两端 47/47 行逐字节相同
    （`tools/dump-page-sizes.swift` vs 安卓 logcat 的 PAGESIZE 行）。做法是**不信 Pdfium 的
    `getPageWidthPoint()`**，自己读 `getPageCropBox()/getPageMediaBox()/getPageRotation()`
    复刻 Mac 的 `PageBitmap.displaySize`。
  - `PageCanvasView` 的抽法：把整个 `PadView` **原地下移**成基类，只把 ~20 处发帧调用换成
    `protected open fun` 钩子——钩子长在原先发帧的同一位置，模式2 行为按构造不变；
    `PadView` 由 1389 行缩到 160 行。`PageImageSource` 同时落地（模式2 包住 PageFetcher）。
  - 进度双向续接实测通过（复原第 1 页 22% → 滑到第 4 页 → 重开落回第 4 页，文件层面核对过）。
  - 两个实测才暴露的 bug：只读连接上不能 checkpoint（FUSE 卷直接 IOERR）；进度复原必须等
    首次真实布局之后（否则 offY 是 width=0 时算的，等于滚到页顶）。
- **M3 手写**：`LocalInkBackend` 落库 + 读盘渲染 + 图层表 + 笔架/图层面板。
  验收：Mac 写的笔迹平板能显示，平板写的 Mac 能显示，形状/粗细/颜色一致。
  **状态：已完成（落笔/擦除/图层归属/回推 2026-07-29；笔架与图层面板 2026-07-30）**。
  - 面板不是新写的：`pad/PadPanels.kt` → `shared/PadPanels.kt`，笔面板参数从 `PadView` 改成基类
    `PageCanvasView`，图层面板的空表文案改由宿主给（两模式的「为什么空」不是一回事）；
    胶囊工厂与 `setTextIfChanged` 进 `shared/Widgets.kt`。**文档下拉没跟着进 shared**——它是纯
    线格式概念（模式1 的书库来自 SQLite），拆成 `pad/PadDocsPicker.kt`，`shared` 不许认识
    `WireCodec`（依赖方向红线，grep 可复查）。
  - 图层三个动作在模式2 里只是「请求」（等 Mac 回权威），模式1 **直接写 `ink_layer` 再整表重读**；
    新建即切为作画图层（同 Mac `layerAdd`）；隐藏只改 `visible`，笔迹数据一条不动。
    面板按**下标**交互（线格式就是按下标发的），所以给面板的列表与宿主换 id 用的列表必须同源
    → `List<LibInkLayer>.toUiLayers()` 是唯一转换点（各查一次库看着等价，实则给了两条能分叉的路，
    错位的表现是「点了图层 2 改到了图层 3」）。
- **M4 编辑**：擦除两模式、尺子、框选移动（含 `InkEdit` 搬运）。
  **状态：核心已完成（2026-07-30）**——擦除两模式随 M3 落地；尺子入口（顶栏「尺子✓」，
  走基类 `toggleRuler`，吸附算法仍是 `PadConst.rulerSnap` 一份）；框选移动落库
  （`LocalCanvasView.onLassoMoveCommit`，与 Mac `applyLassoMove` 逐条对齐）。
  - `InkEdit.translated` 搬成 `shared/InkEdit.kt`。**逐点 clamp**（不是整条按包围盒推回来），
    实测：把一条 h=0.1263 的笔迹上移 0.4692 出界后，`anchor_y=0`、`h` 收缩成 0.1061
    = 0.1263−0.0202，与 Mac 的 `min(1,max(0,…))` 逐位对齐；整体推回的话 h 会保持不变。
  - 命中口径「任一点落框内 + 只动锚定页 + dx/dy 全零不动 + 退化框（宽或高为 0）不动」照抄 Mac；
    可见性过滤靠基类 `strokes`（已滤掉隐藏图层）＝ Mac 的 `vis.contains(layerId)`，
    **实测同一个框在图层可见时命中 1 条、隐藏后命中 0 条**。
  - 落库是 `updateStrokePoints`（id 不变、`created_at` 不变、只 bump `updated_at`），
    整批一个事务；回推后基类自己清预览偏移，与模式2 「等 Mac 广播回来才归位」同构。
  - **剩下的**：文字注解那一半（`rect.intersects(anchor)` 分支）要等 M5 把 kind=0 读进 `notes`。
  - 顺带修：阅读顶栏按钮组改成可横滑 + 页码固定右侧。竖屏 1080 宽下第五个按钮就把页码
    （也是跳页入口）挤出屏幕了，而按钮以后还会加。
- **M5 注解**：文字注解 CRUD + 已有高亮渲染。
  **状态：已完成（2026-07-30）**。
  - `LibraryStore` 补四个门面：`textNotes`（kind=0 → 中立模型，`nx/ny` 取 `anchor_x/anchor_y`，
    **与 Mac `broadcastNotes` 发给平板的两列相同**，两模式标记落点因此一致）、`upsertTextNote`、
    `translateTextNote`、`textFills`。
  - **`upsertTextNote` 的红线：已有注解只改正文**。Mac 建的选区注解带 `quote/rects/color/type_id`
    与有宽高的 anchor，平板上点开改一句话若按「点注解」重建，这些字段连同 anchor 尺寸一起没了，
    且不可逆——与 Mac `applyTextNote` 逐条对齐（新建才是零尺寸 anchor 的点注解；空文本＝删除）。
  - 渲染多了一层 `TextFill`（页图之上、墨迹之下，同 Mac `PageCellView` 层序）：高亮按自身颜色
    0.38，选区注解按类型色/通用暖黄 0.32（`PadConst.FILL`）。**笔记类型是一条 `meta`（`note_types`）
    不是表**，查不到的 `type_id` 回落通用色。首版**只渲染不新建**高亮。
  - M4 剩下的那一半补齐：框选移动现在也移注解。**命中判定必须回库里取带宽高的 anchor**
    （`noteAnchors`）——内存里的 `TextNote` 只有落点一个坐标，拿它判的话 Mac 建的选区注解
    只有左上角那一个点落框才算命中。口径照抄 Mac：`rect ∩ anchor ≠ ∅ || rect ∋ anchor 中心`。
  - 编辑器面板/文字模式开关都是**模式2 那一份**（`shared/PadPanels.showNoteEditor` + 基类
    `noteMode`），模式1 只接了「保存去哪」这一根线。
  - 模拟器凭据（§11.2 的「能证明」那一栏）：插桩测试 16 条全绿（新增 6 条）+ 手工跑完一遍 CRUD——
    落库那行是 `kind=0 page=10 anchor=(0.4546,0.5325,0,0) payload={"quote":"","text":…,"rects":[]}`；
    往库里塞一条 Mac 形状的高亮 + 选区注解后重开，日志 `注解 1 条 铺色 2 片`；框选拖动
    `dx=0.0909 dy=0.1286` 后 anchor 与 payload 里的行框**同步**变成 0.2409/0.4286，
    `quote`/`type_id` 原样在，高亮（kind=3）没被动。人眼的部分（铺色好不好看、图钉位置）进 §11.1。
- **M6 手势**：长按 → 进度环 → 环形选笔盘（本地判定）。
  **状态：已完成（2026-07-30）**。`local/RadialController.kt` 是 Mac `AppModel` 那段判定的
  Kotlin 版：落笔起 1s 定时（`PadConst.LP`）、位移超 14dp 判为在画、呼出即丢弃半笔
  （调基类 `onInkCancel`，等价 Mac 广播的 `inkCancel`）、选择只看角度、中心 hub 为取消区、
  抬笔提交（选笔顺带回笔记模式）。**画盘的代码一行没动**——仍是 `PadOverlays.drawRadial`，
  两模式看到同一个盘。
  - 接线：笔记模式用 ink 流兼作探针，擦除/翻页模式用 probe 流——与模式2 上行给 Mac 的是同一批
    钩子、同一个时机。`RadialController.end()` 返回「这一笔被盘吃掉了」，`LocalCanvasView`
    据此**不落库**：它是一次选择，不是笔迹。
  - 阈值换算：模式2 是 Mac 拿平板上报的 `padGeom.pageW` 折成平板屏幕 dp，模式1 直接用
    `contentWidthDp()`，同一组常量、同一套公式（§8），手感天然一致；y 一律先乘
    `pageAspect(page)` 折成与 x 同尺度再量角/量距。
  - 模拟器凭据：用 `adb shell input stylus motionevent DOWN/MOVE/UP`（分几次调用，中间真的过 1 秒）
    跑完整条链路——按住 1s `长按呼出选笔盘 … 扇区=6`（4 笔 + 橡皮 + 翻页）；原地抬笔
    `选笔盘提交 → 取消区（不选）`；拖向 1 号扇区抬笔 `→ 第 2 支笔` 且顶栏与胶囊变成「钢笔 · 9.0pt」；
    拖向 4 号扇区 `→ 橡皮`，模式变「擦除」；**笔记模式下长按那一次日志里没有 `落笔`**
    （半笔确实没落库），随后快速划一笔照常 `落笔 点数=4`。
    手感（1s 长不长、会不会误触、扇区好不好选）模拟器证明不了，进 §11.1 第 14/15 条。
  - 踩到的坑（已修，留作凭据）：`end()` 里先 `close()` 复位 `highlight` 再提交，于是笔下标恒为 -1
    ——**日志照旧写着「选中第 N 支笔」，笔却没换**。而且只测 0 号扇区发现不了（0 号本来就是当前笔），
    必须换一个扇区才暴露。改法是提交前先把下标取出来。
- **M7 收尾**：最近工作区、异常态文案、日志、真机手感调参。
  **状态：进行中（2026-07-30 做掉三件不依赖设备的）**，剩下的是真机手感调参（等设备）。
  - 阅读顶栏补上**夜间 / 页图显隐 / 锁缩放**：能力早在基类（模式2 一直有这三个键），模式1 只是
    没接按钮。文案与模式2 逐字一致（`日间`/`页图✕`/`🔒`）——两模式得看起来是同一个 App。
    模拟器实测：切夜间后页面像素从 255 变成 26（`nightFilter` 只反页图那一层，墨迹不反）。
  - **工具状态持久化**（`local/ToolPrefs.kt`）：笔（含笔宽与当前选中那支）、橡皮设置、夜间模式
    存 SharedPreferences。模式2 不需要——它的笔架真源在 Mac，连上就整体推下来；模式1 没有 Mac，
    不存的话每次启动都回到基类那四支内置兜底笔，**拖完笔宽一退出就白拖了**。
    设备级、不挂工作区（同 Mac 的 `PenPreset` 存 UserDefaults，不进 `library.sqlite`——
    笔不是工作区的数据，往共享库里塞是越界）。存坏了一律按「没存过」走。
    模拟器实测：把圆珠笔拖到 37pt + 开夜间 → 退出重进，日志 `工具状态已复原：笔 4 支 当前=0
    夜间=true`，胶囊仍是「圆珠笔 · 37.0pt」。
  - **WAL 建不起来的异常态文案**（§9.3 那条）。

## 11. 验收标准（真机）

1. 同一个 `.unrd` 工作区，在 Mac 写一段笔迹 + 一条文字注解 → 拷到平板打开：**位置、粗细、颜色、
   图层归属、页码全部一致**；反向同理。
2. 平板上擦除（局部模式）切出的碎段，回到 Mac 打开与平板所见完全一致（同一套 `splitStroke`）。
3. 阅读进度双向续接：平板读到第 37 页 60% → Mac 打开即在该位置。
4. 页宽高比逐页比对通过（§9.1），含拼页扫描件那种畸形 PDF。
5. 200 页以上大文档：滚动不掉帧、缩放不白屏、内存不爆（LRU 生效）。
6. 模式2 输入板在重构后功能无回归（M0 起每个里程碑都跑一次）。

## 11.1 待真机验证清单（积压，2026-07-30 起攒）

用户 2026-07-30：**设备不在手上，后面统一测试**——所以每个里程碑照旧只做到「模拟器 + 日志 +
宿主机 `sqlite3` 能证明的部分」，凡是要人眼/手感判定的一律记到这里攒着，别在结论里写成「已验收」。
模拟器能证明的和不能证明的边界见 §11.2。

拿到设备后按这个顺序跑，每项都带**要回传的日志**（先 `adb logcat -c`，再
`adb logcat -v threadtime | grep UniReader`）：

| # | 操作 | 期望 | 日志凭据 |
|---|---|---|---|
| 1 | 工作区放 **U 盘/SD/同步盘**，从「最近打开」进书库、再开一篇几百页的文档 | 界面不卡死，各步有「正在打开…」，不出 ANR | `UniReader/Bg` 每步耗时；超 700ms 会带「（慢卷）」 |
| 2 | 读到某页某位置 → 退出 → 重进 | 落回原处（**这条曾静默失效**，见 §9.5 的 `onFirstGeometry`） | `复原滚动 → 第 N 页 x.xxx ok=true` |
| 3 | 开档过程中立刻按返回 | 不崩、不卡；再打开同一工作区正常 | `完成（…ms）但界面已关，丢弃结果` + 紧随其后的 `关闭…`/`wal_checkpoint` |
| 4 | 四种笔各写几笔，与 Mac 并排比 | 形状/粗细/颜色/压感一致。**marker 的混合模式 §9.4 已修**（像素值算准了），这次是看并排观感：荧光笔压在文字/彩图/别的笔迹上，浓淡与 Mac 一致；夜间模式下再看一眼 | `落笔 page=… 点数=… layer=…` |
| 5 | 开尺子写一笔 | 直线 + 45° 吸附是**看上去**的角度 | 落笔 `点数=2` |
| 6 | 局部擦除横穿一条笔迹 | 切成两段，回 Mac 打开与平板所见一致 | `擦除落库：删 N 条，改 M 条，插 K 段` |
| 7 | 框选一片笔迹 → 拖动 → 松手 | **松手到归位之间不该有回弹/跳位**（预览→权威回推那一下） | `框选 page=… 命中 笔迹=N` → `框选移动落库：N 条 dx=… dy=…` |
| 8 | 把笔迹拖出页边 | 贴边压扁的形状与 Mac 一模一样（逐点 clamp） | 同上 + 回 Mac 比对 |
| 9 | 图层面板：切换 / 隐藏 / 新建 | 隐藏后那层笔迹不画但数据不丢；新建即成为作画层 | `回推笔迹 可见=N/总数 隐藏图层=K` |
| 10 | 笔面板拖笔宽、改橡皮直径/整笔↔局部/圆环 | 即时生效，胶囊文案跟着变 | 胶囊 = 「笔型 · Xpt」 |
| 11 | 200 页以上大文档滚动/缩放 | 不掉帧、不白屏、内存不爆 | `Choreographer: Skipped` 应为零 |
| 12 | 模式2 输入板连 Mac 跑一遍 | 面板搬进 `shared` 后功能无回归 | 三个面板能开 + 笔迹上行正常 |
| 13 | 竖屏拿平板进阅读界面 | 顶栏按钮可横滑、页码始终在右 | — |
| 14 | 长按呼盘的**手感**（M6）：停 1s 呼出、写字时不该误呼、盘上选扇区 | 进度环起显示的时机不烦人；正常书写一次都不误触发；扇区好选（角度判定） | `长按呼出选笔盘 …` / `选笔盘提交 → …` |
| 15 | 呼出盘那一瞬间**半笔的消失是否突兀**（M6） | 环展开成盘、本地那半笔同时撤掉，不该看到残影或闪一下 | 同上 + 该次没有 `落笔` |
| 16 | Mac 上建一条**选区注解**与一条**高亮**（最好再建个自定义笔记类型），拷到平板打开（M5） | 铺色位置/颜色与 Mac 并排一致；图钉落在 anchor 左上角（与模式2 同）；自定义类型是类型色不是暖黄 | `回推文字注解 N 条，铺色 M 片` |
| 17 | 平板上新建/编辑/删除文字注解，回 Mac 打开（M5） | 位置、正文一致；**Mac 建的选区注解在平板上改完正文，回 Mac 仍是选区注解**（引文/行框/类型/颜色都在） | `文字注解落库 …` / `文字注解删除 …` |
| 18 | 框选一片含注解的区域拖动（M5 补齐的那一半） | 注解跟着走、铺色跟着走；松手到归位之间不回弹 | `框选移动落库：笔迹 N 条，注解 M 条 …` |
| 19 | 阅读顶栏新加的**夜间 / 页图 / 🔒**（M7） | 夜间只反页图不反墨迹（笔迹颜色不变）；关页图＝纯白手写板；锁缩放后双指只能整体拖动 | — |
| 20 | 改笔宽/橡皮/夜间 → 杀进程重开（M7 `ToolPrefs`） | 笔宽、当前那支笔、橡皮档位、夜间都还在 | `工具状态已复原：笔 N 支 当前=i 夜间=…` |
| 21 | 工作区放**真 FAT32/exFAT U 盘**（模拟器的 `/sdcard` 是 FUSE，验不了这条） | 能打开就正常用 + 弹一条「这个卷不支持 WAL」的 Toast；打不开则弹出的原因里列着四种可能，而不是一句「打不开」 | `WAL 没能启用（journal_mode=…）` 或 `带 WAL 标志打不开，退一步…` |
| 22 | **竖屏**拿平板进模式2 输入板（§9.3 已修） | ◀▶/模式/笔/夜间… 能横滑点到，页码固定在右；横屏下延迟指标整行不截断 | — |
| 23 | 工作区放**慢卷**（U 盘/同步盘），连着快写快擦十几笔（§9.5 的队列） | 写的当下不掉帧；**回推晚一拍是否看得出来**——落笔后那一笔从「活体层」换成「库里读回来的」的一瞬有没有闪/挪位；连续擦除时笔迹有没有反复出现又消失 | `StoreQ` 的「等 Xms 跑 Yms（慢卷）」；`落笔`/`擦除落库` 在 `unireader-store`，`回推笔迹` 在主线程 |
| 24 | 慢卷上写完一笔**立刻**按返回退出 | 那一笔不丢（关库排在队尾） | 退出时 `wal_checkpoint(TRUNCATE) → 0` 之前应先有 `落笔 …` |

## 11.2 模拟器能证明什么、不能证明什么

**能**（所以这些已经算验过了，不必重跑）：落库字段与 Mac 逐字段一致（宿主机 `sqlite3` 对账）、
线程归属（`logcat -v threadtime` 的 tid）、命中判定的数量与范围（框选/擦除的日志）、
时序（谁先谁后）、数据不丢（条数与 id）。

> 补充（2026-07-30）：**像素值是能证明的**——`adb exec-out screencap` 出原始 RGBA 逐点读，
> 拿去对混合公式，§9.4 就是这么定的案（白底 + 压在蓝笔上两组，与 W3C multiply 逐位相符）。
> 「颜色对不对」和「好不好看」是两件事，前者算得出来，后者仍要人眼。
> 布局同理：`uiautomator dump` 的 bounds 能证明按钮点得到、页码没被顶出屏幕（§9.3），
> 但证明不了比例好不好看。

**不能**：笔迹观感（浓淡在真实纸面/夜间下顺不顺眼——数值对了不等于好看）、手感（吸附/惯性/拖动回弹）、
真实慢卷的耗时（production 模拟器上 `adb root` 与 `drop_caches` 都不可用，冷缓存复现不了）、
横屏平板的布局比例、手写笔硬件（压感曲线、侧键、hover）。

> 三个模拟器验证的坑（会让人误判成 bug）：核对库必须连 `-wal`/`-shm` 一起 pull，否则读到旧数据；
> 点击要按 `uiautomator dump` 出的文本定位而不是记坐标（最近列表会重排）；
> `input stylus swipe` 的终点只走到全程 ~80%，短行程更夸张——靠日志里的实际归一化框对，别信自己给的坐标。

## 12. 未决 / 下一版

- 文字层相关：目录、全文搜索、文字选择与复制、**新建高亮**（首版只渲染已有的）。
- OCR（Paddle 云 API，无桌面依赖，`ocr_page` 表已在 schema 里预留）。
- 书库管理：导入 PDF、多路径探测、variant 合并、重定位、`is_relative` 外置卷路径。
- 两端并发写的真正方案（租约 / 增量同步 / 走局域网）。
- Windows 版——schema 已经是跨平台契约，这份文档的 §6 对它同样适用。
