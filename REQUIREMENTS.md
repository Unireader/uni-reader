# UniReader — macOS PDF 阅读器需求分析

> 一款不修改 PDF 原文、笔记外挂存储的 macOS 阅读器，支持文件记录分组、三种笔记形态，以及通过局域网网页用安卓平板触控笔手写。

## 0. 已确认决策（2026-07-19）

| 决策 | 选择 | 影响 |
|---|---|---|
| 平板端形态 | **显示当前页图片 + 本地即时落墨** | 笔画用归一化页面坐标 (0~1)，与 Mac 缩放/视口解耦，坐标映射从"最高风险"降级 |
| 分发方式 | **直接分发 + 公证（非沙盒）** | 文件用普通路径 / bookmark，无需 security-scoped resource |
| 最低系统 | **macOS 26 Tahoe**（2026-07-19 从 15 上调，不做兼容） | Liquid Glass 全量 API 直接用（`backgroundExtensionEffect` 等），无 #available 分支 |
| 主窗口布局 | **框架 = 原生 NavigationSplitView（玻璃侧栏）+ 右侧 `.inspector`；PDF 阅读区 = 自研页图流 `PageStreamView` v2（2026-07-20 重写：纯 SwiftUI，Preview 级五硬指标——主线程零渲染/预缓存/pinch 锚定零跳位/resize 零跳/任何情况零闪烁；见 `PDF-VIEWER-REBUILD-PLAN.md`）** | 目标行为：① 侧栏叠加在 PDF 上（玻璃虚化真实内容）；② **侧栏/Inspector 开合不改变页面尺寸/位置**（2026-07-20 用户更新，取代旧「挤到右侧居中」）——页面被玻璃盖住、可横向拖出；③ 手动放大后允许被侧栏覆盖。fit 宽以滚动视图实测可用宽为准（兼容鼠标 legacy 占空间滚动条）。**红线：严禁仿侧栏/浮层 hack；阅读区纯 SwiftUI，严禁 AppKit 视图（含包 NSScrollView）** |

## 1. 功能需求

### 1.1 文件记录与分组

- 记录所有打开过的文件（最近列表）
- 支持自定义分组，文件可拖拽归入分组
- **hash 去重**：以文件内容 hash（SHA-256，分块读取）作为文档唯一标识
  - 同一文件存在多个路径（移动、复制）→ 识别为同一文档的多个存储位置
  - 打开时自动探测哪个路径仍然有效
  - 笔记与 hash 关联，文件移动后笔记不丢失
  - 文件内容被修改（hash 变化）→ 提示重关联，旧笔记保留

### 1.2 知识笔记

**核心原则：不在 PDF 文件上做任何修改**，所有笔记独立存储，通过 `hash + page + PDF坐标` 锚定。

| 类型 | 形态 | 存储内容 |
|---|---|---|
| 文字注解 | 锚定到页面位置/选区的便签 | 文本 + 锚点 |
| 会话笔记 | 锚定到页面/选区的聊天消息流（预留 AI 对话扩展） | 消息数组 + 锚点 |
| 手写笔记 | 矢量笔画，叠加渲染在页面上方 | 笔画点列（压感）+ page |

### 1.3 平板触控笔手写

- Mac 端内置局域网 HTTP + WebSocket 服务：HTTP 分发采集网页与**当前页渲染图**，WebSocket 双向传笔画 / 翻页
- 平板（小米平板 6 + 灵感触控笔）浏览器打开网页：**以当前 PDF 页图片为背景**，笔在页面上手写，**本地即时落墨**保证跟手
- 笔画以**归一化页面坐标（0~1）**实时推送到 Mac；Mac 端 `归一化坐标 × page.bounds` 换算为 PDF 页面点落墨
- 翻页：屏幕 prev/next 按钮，或「翻页模式」下**笔拖动左右滑翻页**，与 Mac 端页码双向同步
- 笔身侧键（PageUp/PageDown）**不用于翻页，改作工具/模式切换**（见 1.5）
- 配对方式：二维码 / 短码携带 token，token 作为 WebSocket 准入校验，无账号系统

### 1.4 平板视口同步与悬停指示

- **视口同步（双向）**：Mac 为渲染真相源；平板可本地平滑滚动，两端画面保持一致。
  - Mac 推送「当前页 + 相邻页」的渲染图与页面布局元数据，平板组成可滚动的页面列，**本地滚动流畅**（不逐帧传图）
  - 平板滚动 → 上报「可见页 + 归一化偏移」→ Mac 的 `PDFView` 跟随滚动到同一位置
  - Mac 滚动 → 推「可见页 + 偏移」→ 平板同步
  - 手写坐标始终用归一化页面坐标，滚动 / 缩放不影响落墨
- **悬停指示（Firefox 可用，已实测）**：小米平板 6 实测，**Chrome 不把笔 hover 转发给网页，Firefox 可以**。故采集页在 **Firefox** 下持续上报悬停坐标（归一化页面坐标 + 页码），Mac 在页面上叠加显示笔尖位置（接触即转为落墨，离开近场即隐藏）。悬停圆环须画在与笔迹同坐标系的 overlay canvas 上，避免移动端 `position:fixed` 偏移。

**WebSocket 消息草案：**

| 方向 | 消息 | 内容 |
|---|---|---|
| Mac→Pad | `pageImage` | 页码、图片（或 HTTP 取图 URL）、页面尺寸、旋转 |
| Mac→Pad | `viewport` | 可见页 + 归一化偏移（Mac 端滚动时） |
| Pad→Mac | `scroll` | 可见页 + 归一化偏移（平板滚动时） |
| Pad→Mac | `hover` | 归一化页面坐标 + 页码 + 倾斜 |
| Pad→Mac | `ink` | phase(begin/move/end) + 归一化点[含压感] + 当前笔(color/width) |
| Pad→Mac | `erase` | phase + 归一化擦除轨迹点 |
| Pad→Mac | `mode` | 当前模式（note / erase / page） |
| Pad→Mac | `pageTurn` | prev / next（屏幕按钮 / 翻页模式笔拖动） |

### 1.5 工具与模式（笔身侧键）

采集页维护「模式」与「当前笔」两个状态，用笔身两个侧键切换（不占用翻页）：

- **PageUp（上键）= 切换模式**，循环：笔记 → 擦除 → 翻页
  - 笔记：落墨（当前笔颜色/粗细 + 压感变宽）
  - 擦除：笔经过处抹除笔画
  - 翻页：笔拖动左右滑翻页 / 平移（后续接滚动）
- **PageDown（下键）= 切换笔**，在预设笔列表间循环（并切回笔记模式）
- 顶栏显示当前模式与笔色；屏幕 prev/next 按钮始终可用作后备
- 页面绘可见边框标出可落笔区（竖版 PDF 在横屏平板上居中留白属正常，占满屏可竖持平板或待步骤 4 适宽滚动）

### 1.6 多窗口与共享服务

- **多窗口**：macOS 可同时开多个窗口看多个 PDF（⌘N 新窗口，⌘O 打开）；同一 PDF 也可开多窗口，并发编辑笔记（少见但允许）。
- **共享 WS**：全窗口共用**一套** WebSocket 服务（`AppModel` 持有唯一 `LANServer`），避免端口冲突。
- **平板显示哪个**：默认跟随**最后激活**的窗口；平板顶栏下拉列表可手动切到任一打开的 PDF（S1b）。平板与 Mac **可不同缩放/范围，只同步文档滚动位置**。

### 1.7 长按切笔手势

- 笔**重压 + 静止**：超过 300ms 时，在 **Mac 笔尖处**显示圆形进度环；累计 >2s 呼出**切笔工具**（在 Mac 笔尖处）。
- 触发后这一笔（按下产生的墨点）**清除**。
- **关键**：正常落笔立即出墨（不等 300ms，避免延迟）；一旦判定为长按手势再**回溯清除**那一笔，保证书写零延迟。

## 2. 目标设备验证（小米平板 6）

> ✅ **Step 0 已实测通过**（2026-07-19，小米平板 6 + 灵感触控笔，Chrome 与 Firefox，测试页 `spike/pen-test.html`）：
> - 压感真实可用（随力度变化，非恒定值）
> - `pointerType=pen` 可区分手指/笔，防误触成立
> - `getCoalescedEvents()` 高采样可用
> - Fullscreen API 可进全屏、隐藏浏览器控件
> - **笔身两个侧键 = `PageUp` / `PageDown` 键盘事件**（走 BLE HID，非 pointer 通道），可读、两键可区分
> - ✅ **笔悬停 hover：Firefox 可用**（Chrome 不转发给网页，Firefox 转发）→ 悬停预览可实现（Mac 上显示笔尖位置）；**目标浏览器定为 Firefox**
> - ⚠️ **笔迹平滑**：Firefox 采样率偏低，直线连点折角明显 → 需曲线平滑（二次贝塞尔中点法 / Catmull-Rom），采集页本地落墨与 Mac 端渲染都要做（测试页已加中点平滑）

- `pointerType: "pen"` 可区分手指与笔 → 防误触（检测到笔后忽略 touch）
- `event.pressure`：归一化 0~1，实测有真实压感（Chrome）
- `getCoalescedEvents()`：配合 144Hz 屏获取高采样率点，笔画顺滑
- `tiltX/tiltY`：大概率有但不稳定 → **只硬依赖压感，倾斜作为加分项**
- 侧键：采集页监听 `keydown` 的 `PageUp/PageDown`（忽略 `e.repeat`）→ **PageUp 切模式、PageDown 切笔**（见 1.5），不用于翻页
- 平板端渲染"页面图 + 本地墨迹"，负载轻（仅贴图 + canvas 线条），浏览器性能差异影响小
- **建议平板使用 Firefox 浏览器**（压感 / 防误触 / 合批 / 翻页键均支持，且能拿到笔悬停；Chrome 不转发 hover，退为备选）

## 3. 技术栈

| 模块 | 选型 | 理由 |
|---|---|---|
| UI | SwiftUI | 原生、开发快 |
| PDF 渲染 | **自研页图流 `PageStreamView`**（SwiftUI `ScrollView` + 按页 `PDFPage.draw(.mediaBox)` 出图；仍用 PDFKit 的 `PDFDocument`/`PDFPage` 做解析与栅格化，只弃 `PDFView`） | `PDFView` 与 macOS 26 Liquid Glass safe-area/浮动侧栏不兼容（`PDFClipView` 私有居中缺陷，页面恒偏左，无公开 API 可修）。自绘换来原生玻璃观感 + 跨平台页图流统一；代价：文本选择/搜索用「文本层」补（见 `TEXT-SEARCH-OCR-PLAN.md`） |
| 本地存储 | SwiftData | Document / Group / Note 三张表，hash 唯一键 |
| 手写笔画 | 自定义笔画模型（点 + 压感 + 时间偏移，Codable）+ 自绘 overlay | 需压感变宽 → 自绘渲染；若放弃压感可退回 PDFKit ink 注解（缩放/坐标全自动） |
| 局域网服务 | Network framework (`NWListener` + `NWProtocolWebSocket`) | WS 握手/分帧系统内置；另写极简 HTTP 响应分发网页与页面图，不引入 Vapor |
| 平板端 | 纯 HTML/JS 网页（Canvas + Pointer Events + WebSocket） | 免安装，跨平台 |

## 4. 风险点

1. **坐标映射**（已降级）：平板显示页面图后，改用归一化页面坐标 (0~1) → `归一化 × page.bounds` 得 PDF 页面点，与 Mac 缩放/视口解耦；主要注意 Retina DPI 与页面旋转 `page.rotation`
2. **同步延迟**：局域网 + 点合批（10~20ms 一批）+ 平板本地即时落墨，满足手写跟手性
3. **笔记失联**：文件内容修改导致 hash 变化时，需 UI 提示重关联
4. **大文件 hash 性能**：分块读取 + 后台线程；缓存 `(path,size,mtime)→hash` 避免重复计算
5. **Local Network 授权**（macOS 15）：首次启动 server 会弹隐私授权，需处理未授权引导态
6. **配对安全**：QR / 短码携带 token，作为 WebSocket 准入校验，防止同网段他人接入
7. **视口同步带宽**：滚动逐帧传整页图会卡 → 只传「窗口内页面」图并缓存，平板本地滚动，仅回传归一化偏移
8. **hover 依浏览器**：Chrome 不转发笔悬停，**Firefox 可以** → 目标浏览器定为 Firefox，悬停预览可实现；圆环画在同坐标系 overlay 避免偏移
9. **笔迹平滑**：Firefox 采样率偏低，直线连点折角明显 → 落墨用曲线平滑（二次贝塞尔中点法 / Catmull-Rom），采集页与 Mac 渲染均需处理

## 5. 复杂度评估

**中等**。单机部分（文件记录分组 + 文字注解 + 会话笔记）较简单；约 70% 工作量集中在平板同步链路与手写渲染。

## 6. 开发进度（里程碑）

- ✅ **Step 0 spike**：触控笔能力实测（压感 / 防误触 / 合批 / 侧键翻页 / Firefox hover），测试页 `spike/pen-test.html`
- ✅ **M1 单机骨架**：xcodegen 工程、PDFKit 阅读、SHA-256 去重入库、SwiftData 四表、中英双语 —— 编译通过
- 🚧 **M2 局域网手写链路**
  - ✅ 步骤 1：HTTP(8770) + WebSocket(8771) 服务、token 鉴权、二维码配对、采集页、控制面板
  - ✅ 步骤 2：推当前页 PNG + 采集页显示 + 本地平滑落墨 + 防误触 + 悬停 + 归一化回传 + 翻页联动
  - ✅ 步骤 2.5：工具/模式（PageUp 切模式、PageDown 切笔）、可见边框、**WS 延迟显示**
  - 🚧 **S1 地基：多窗口 + 共享 WS**
    - ✅ S1a：服务改 App 级单例（`AppModel`）；多窗口会话注册表（`DocSession`）；平板跟随最后激活窗口；⌘N 新窗口 / ⌘O 打开（仅 key 窗口响应）
    - ✅ S1b：平板顶栏文档下拉列表（`selectDoc` / `docs` 广播），可手动切到任一打开的 PDF 或「⟳ 跟随 Mac」
  - 🚧 **S2 铺满与滚动**（架构定为**方案 B：桌面权威流转**）
    - ✅ S2a：平板**宽度铺满**（fit-width）+ 手指竖向滚动 + 墨迹随滚动重绘 + 右上角**全屏**按钮
    - ✅ S2b-1：`PadRenderer`（桌面按宽度做 fit-width 连续布局、渲染任意视口条带、视口↔(页,归一化)换算）+ **模拟平板窗口**（滚轮连续滚动、鼠标当笔，走共用落墨 API，Mac 主窗口同步显示）
    - ⬜ S2b-2：把 `PadRenderer` 条带**流转给真平板**（缓冲本地滚动 + progressive 多清晰度）；平板回传滚动/落墨
    - 🚧 S2b-3：**锚点同步**（文档位置=页+页内比例为唯一真相，连续镜像）
      - ✅ 双向：模拟窗口 ↔ Mac 主窗口连续同步滚动（origin 标记 + 0.3s 抑制窗防回环）
      - ⬜ 真平板接入同一锚点通道
  - ✅ **S3 实时渲染**：平板 `ink`/`erase` → Mac `InkOverlayView` 叠加渲染（压感变宽 + 笔色 + 擦除），随缩放/滚动重绘对齐。
  - ✅ **S3.5 笔迹持久化**（2026-07-20）：落工作区 SQLite `note` 表（kind=2，一笔=一行，`note.id==stroke.id`，page/归一化 anchor 走列，payload=JSON `{color,width,points[[x,y,pressure]]}`；**弃 SwiftData**）。`ContentView` `.onChange(session.strokes)` 增量对账 upsert/delete，重开 `loadInk` 恢复。测试 `spike/ink-store-test.swift` 21/21。
  - ⬜ **S5 长按切笔手势**：重压 + 静止 >2s；Mac 笔尖处进度环（>300ms 起）+ 切笔工具；那一笔**预测性立即清除**
- ✅ **阅读区页图流 v2**（2026-07-20 重写完成，编译通过 + 4 组 spike 全绿，待用户真机手感验证）：v1 因缩放跳位/闪烁被删；v2 纯 SwiftUI 重写（`PageStreamView`+`PageLayout`+`PageBitmap`+`PageRenderEngine`+tick 版 `ScrollFollower`），pinch 双相锚定缩放、⌘±/⌘0、resize 冻结+原子 refit、自研虚拟化、高倍贴片、后台渲染+预缓存。设计与 spike 实测结论见 `PDF-VIEWER-REBUILD-PLAN.md`。
- 🅿️ **文字搜索 / 文字选择 / 扫描版 OCR 预留架构**（2026-07-20 已落座位）：统一「页面文本层」`PageTextLayer`（native | ocr 同模型）+ `ocr_page` 缓存表(schema v3，`spike/ocr-store-test.swift` 15/15) + `OCRProvider` 可插拔（系统 Vision / 用户配 API）协议骨架。实现按 `TEXT-SEARCH-OCR-PLAN.md` 的 T1(原生文本+选择)→T2(搜索)→T3(OCR)。
- ⬜ **M3 三种笔记**：文字注解 / 会话笔记 / 手写笔记的编辑与渲染、重定位提示

## 7. 客户端页面显示与数据流（方案 B 现状，2026-07-20 对齐）

平板 canvas 显示 PDF 的完整流程与数据传输：

1. **布局元数据 `layout`（WS，低频）**：Mac 推整份文档「每页原始宽高数组 `pages:[[w,h],…]` + 页数 + docId/版本」。数据量：每页 2 个数，几百页 ≈ 几 KB，**仅文档切换时推一次**。
2. **平板本地连续布局**：收到 layout 后，按 fit-width 算每页显示高度（屏宽 × h/w）累加成一条可滚动页面列。滚动/缩放纯本地重绘，不回传图。
3. **页图按需取（HTTP）**：平板只对「可见 + 上下各一屏预取」的页发 `GET /page.png?i=N&v=版本`；Mac `renderPage` 渲染该页 PNG（宽 1600px，带 `NSCache`）返回，平板 `Image` 缓存复用。数据量：每页 PNG ≈ 0.5~1.5MB，只取窗口附近几页，滚动增量取、旧页留缓存。
4. **合成**：`#bg` canvas 按当前 scrollY/zoom 把已加载页图 drawImage 到位（未加载画灰底占位）；`#ink` 上层画墨迹、`#hover` 画笔尖圆环，均不随夜间反转。
5. **高频小包**：`scroll`/`viewport` 锚点（几十字节，rAF ~60/s）、`ink`/`erase`（合批 ~60/s）、`hover`（节流）、`ping/pong`（1s 心跳）。

**要点**：滚动/缩放**不逐帧传图**，只传几十字节锚点；页图进视口才取一次并缓存 → 带宽友好。粗估：连续浏览 10 页 ≈ 首次 5~15MB 页图，之后缓存命中 0 传输；锚点/心跳可忽略。

## 8. 工作区文件夹持久化（2026-07-20 定方案，首版已实现）

> 目标：一个**可移动文件夹 = 一个工作区**，替代「分组」。放移动硬盘上即可两台电脑/未来独立 app 复用同一套数据。

- **文件夹 = 工作区 = 一套相关 PDF**（原「分组」/`LibraryGroup` 已取消，工作区天然就是分组；§1.1 的「自定义分组」以此替代）。
- **不直接存 PDF 本体**，只记录每个文档的「多个可能路径」（移动/复制后自动探测有效路径）。
- **一个文档可配多个文件 / 多个 hash**：给 PDF 加了 TOC → hash 变但页面内容一致 → 视为同一文档的多个版本（variant），笔记通用。

**已定决策（2026-07-20）：**
| 项 | 选择 | 理由 |
|---|---|---|
| 存储格式 | **自有 schema 的单个 SQLite**（`<工作区>/UniReader/library.sqlite`，无第三方依赖，用系统 libsqlite3） | **确定要做 Windows/Android 版**，数据须跨平台可读 → 排除 SwiftData/Core Data 不透明 schema；SQLite 全平台原生可读、ACID 保一致性、单文件易移动。已用 `sqlite3` CLI 验证可直读 |
| 多 hash 模型 | **document → variant(hash) → location(path)** 三层；notes 挂 document（按 page + 归一化锚点，版本无关） | 加 TOC = 新 variant，笔记全版本共用；打开时跨 variant 探测有效路径 |
| 多 hash 关联 | **手动**「关联为同一文档」（`LibraryStore.linkVariant` 已就绪，UI 待补）——hash 变了无法自动判定同一文档 | — |
| 工作区切换 | 侧栏文件夹菜单：选择/新建工作区（选目录面板）+ 最近工作区；最近列表存**本机** UserDefaults，不进文件夹 | — |

**Schema v3（跨平台契约，见 `Sources/Store/`）：**
`meta(key,value)` · `document(id,title,page_count,added_at,last_opened_at,sort_order,read_page,read_frac)` · `variant(id,document_id→,content_hash UNIQUE,page_count,added_at)` · `location(id,variant_id→,path,is_valid,last_validated_at,in_workspace)` · `note(id,document_id→,kind,page,anchor_x/y/w/h,payload BLOB=JSON,created_at,updated_at)` · **`ocr_page(content_hash,page,provider, payload BLOB=JSON,lang,created_at)` PK(content_hash,page,provider)**（v3 新增，扫描页 OCR 结果缓存；payload=`{w,h,runs:[{text,x,y,w,h}]}` 归一化 0~1）。时间戳 ISO-8601 文本、id UUID、payload JSON。**无 macOS security-scoped bookmark**（不跨平台）。`in_workspace=1` 时 `location.path` 为**工作区相对路径**。迁移：`meta.schema_version` + `ADD COLUMN IF missing` / `CREATE TABLE IF NOT EXISTS`（v1→v2、v2→v3 均已验证：`spike/store-test.swift` 32/32、`spike/ocr-store-test.swift` 15/15）。

**已实现**：`SQLite.swift`（libsqlite3 薄封装）+ `LibraryStore.swift`（建表/迁移/`findOrCreate` 去重/`mergeDocument`+`linkVariant`/`addVariant`/`add·removeLocation`/`updateProgress`/notes CRUD）+ `WorkspaceManager`（当前工作区、最近列表、导入、打开探测路径优先工作区副本、进度存取、复制/移出工作区、重定位、合并）；SwiftData 整套移除。UI：侧栏工作区切换 + **重命名**、文档右键 **复制到工作区/从工作区删除**、**关联为同一文档**（合并，带确认）、路径失效 **重新关联文件** 提示；**阅读进度**自动记录并重开恢复（切文档/关窗/滚动节流各存一次）。运行时验证：建库/schema/meta/WAL、v1→v2 迁移、32/32 DAO 测试（`spike/store-test.swift`）。
**待补**：① 旧 SwiftData 数据不迁移（全新开始，需重新导入）；② ✅ 手写笔迹已写入 `note` 表（kind=2，payload=JSON `InkStroke`；2026-07-20，见 §6 S3.5）；③ 合并的「拆分」逆操作暂无。
