# 画板笔记（Board Note）方案 — Mac + 网页 + 安卓两模式

> 状态：2026-09-24 定方案；**2026-09-26 Mac + 网页 + 安卓两模式落地**（实现记录与出入见 §8）。
> 用户原话：「做一个单纯的画板笔记，不需要 pdf，类似草稿纸模式，对应的功能可以迁移过去，pad 两个模式+网页需要适配」。
> 同日拍板的四条：① 库里**新建两张表**（不挂假文档）；② 第一批 = **草稿纸现有全部功能 + 图片**；
> ③ 平板（网页 + 安卓模式2）= **跟随 + 新建**；④ 安卓模式1 遇到没有新表的工作区 = **安卓自己补建表**。

## 0. 一句话定义

> **画板笔记 = 工作区里一篇独立的「无限白板」文档**，与 PDF、Markdown 笔记平级：侧栏里有自己一组、
> 在标签页里打开、整页就是一张草稿纸。它**不属于任何 PDF**，所以没有锚点、没有图钉、没有页面底图；
> 其余（笔、橡皮、尺子、框选缩放、剪贴板、撤销、纸样、minimap、回中 / 适应内容）照搬草稿纸，再加图片。

### 命名（🔴 避开已有的「画板模式」）

`0x4B canvas` / 「显示 › 画板模式」已经是 **PDF 页边可书写**那个功能。为了不撞名：

- 代码 / 表 / 协议一律叫 **board**（`BoardNote`、`board_note`、`boards`……），**不用 canvas**；
- 界面文案：中文「画板笔记」、英文「Board」。菜单「显示 › 画板模式」保持不动。

## 1. 与草稿纸的关系

| | 草稿纸 | 画板笔记 |
|---|---|---|
| 归属 | 挂在某篇 PDF 上（`scratch_pad.document_id`） | 独立，挂在工作区 |
| 打开方式 | 盖在阅读区上的一层，可关 | 占一个标签页，关 = 关标签 |
| 锚点 / 图钉 / 页面底图 | 有 | **没有** |
| 画布坐标系、笔宽、橡皮 ×800、网格步长 | `PROTOCOL.md §4.4` | **完全相同**（同一份契约） |
| 图片 | 无 | 有（§2.3） |

实现上的核心思路：**画板笔记的标签页里，`DocSession` 没有 PDF，只有一张「永远开着的草稿纸」**。
这样 Mac 的笔迹链路（`AppModel+Scratch`）、撤销栈（`scratchUndo`）、视图（`ScratchPadNSView`）、
平板下行（`scratchpads` / `scratchStrokes`）和上行（`ink` / `erase` 在纸开着时走画布坐标）**全部原样复用**，
只有「从哪读 / 往哪存」换成新表。

## 2. 数据（schema v15 → v16，跨端契约）

### 2.1 两张新表

```sql
-- v16：画板笔记（BOARD-NOTE-PLAN.md）。独立于 document；纸样两列与 scratch_pad 同语义。
CREATE TABLE IF NOT EXISTS board_note (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '',
  bg TEXT NOT NULL DEFAULT 'rgba(255,255,255,1.0)',
  pattern TEXT NOT NULL DEFAULT 'dots',          -- plain / dots / grid
  group_name TEXT NOT NULL DEFAULT '',           -- 预留：一级分组（同 document.group_name），第一批界面不用
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_opened_at TEXT
);
-- 画板上的东西：kind 1 = 笔迹，2 = 图片。每条一行（离线镜像按行合并，双方各加的笔迹能并起来）。
CREATE TABLE IF NOT EXISTS board_item (
  id TEXT PRIMARY KEY,
  board_id TEXT NOT NULL REFERENCES board_note(id) ON DELETE CASCADE,
  kind INTEGER NOT NULL,
  x REAL NOT NULL, y REAL NOT NULL, w REAL NOT NULL, h REAL NOT NULL,   -- 画布坐标包围盒
  payload BLOB NOT NULL,                         -- JSON，见 2.2 / 2.3
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_board_item_board ON board_item(board_id);
```

- 为什么不复用 `note` 表：`note.document_id` 是 `NOT NULL` + 外键，画板笔记没有文档可挂。
- 视口（滚动 / 缩放）照旧**不落库**，三端各自独立，打开一律回画布原点。
- 笔迹不分图层（同草稿纸）。

### 2.2 笔迹 payload（kind=1）

与草稿纸 kind=4 **同一份 JSON**（`pen` + `pts`，点是画布坐标），只是**不写 `padId`**（归属在 `board_id` 列上）。
三端现成的编解码直接复用。

### 2.3 图片 payload（kind=2）

```json
{ "image": "<sha256>", "caption": "", "source": { "kind": "file", "name": "a.png" } }
```

- 图片本体沿用图片笔记那套：`Images/<sha>.<ext>` + `image` 表（`IMAGE-NOTE-PLAN.md §2.1`）。
- 位置 = `x/y/w/h` 列（画布坐标，左上原点）。
- **层序**：纸色 → 底纹 → **图片** → 笔迹（笔迹永远能写在图上）。多张图之间按 `created_at` 叠放。
- 🔴 **引用计数要把 `board_item` kind=2 一起数**（`LibraryStore.imageRefCounts` / `imageRefCount`），
  否则画板上的图 30 天后会被当成没人用而删掉。回收站那边同理（§6）。

### 2.4 各端建表

- Mac：`migrate()` 里加上面两段，`schemaVersion = 16`。
- 安卓：`Schema.kt` 逐字抄同两段；并且**打开工作区时若没有这两张表就用同样的语句补建**
  （用户 2026-09-24 同意；2026-09-26 用户撤销了「安卓不改表结构」的规定，安卓与 Mac 一样正常迁移，见 `android/AGENTS.md`）。
  `meta.schema_version` 安卓仍然不写。

## 3. Mac

### 3.1 标签页与侧栏

- `DocTabModel` 加 `boardID: String?`，与 `docID` / `noteRef` **三者互斥**（开画板前先 `select(nil)`，同 Markdown 笔记）。
- `TabsModel.StoredTab` 加 `.board(id)`，键前缀 `board:`；跨启动恢复同 Markdown。
- 侧栏加一组「画板笔记」（`SidebarNode.Kind.board` + 分组标题），按最近打开排序；选中键 `"board:"+id`。
  右键：打开 / 改名 / 删除（进回收站）。分组标题上的「＋」与菜单「文件 › 新建画板笔记」新建。

### 3.2 运行时

- 开画板 = 读 `board_note` + `board_item` → `session.scratchPads = [这一张]`、`session.openPadID = 它的 id`、
  `session.scratchStrokes = 笔迹`、新增 `session.boardImages = 图片`。
- 落库：`persistScratchPads` / `persistScratchStrokes` 现在开头是 `guard let id = session.documentId`；
  画板标签走另一条分支写 `board_note` / `board_item`（同样是增量对账），图片另有 `persistBoardImages`。
- 撤销：沿用 `scratchUndo`；记账从「只有笔迹」扩成「笔迹 + 图片」（增删 / 挪动 / 缩放图片都能撤）。

### 3.3 视图

`ScratchPadNSView` 加一个「独立模式」开关（`standalone`），画板标签页里由窗格直接装它（不需要 `ReaderView`）：

- 工具条：去掉「关闭」「页面底图」；改名改的是画板笔记名；其余照旧。
- Esc 只清选区，**不关**。
- 笔架（`PenRackNSView`）在画板标签里也要出现（现在只在有 `ReaderView` 时建）；图层按钮在画板里隐藏。
- 图片：新增图片图层（在笔迹之下）。
  - 加图：拖文件进来 / ⌘V 粘贴图片 / 工具条「插入图片…」。落在光标或视口中心，默认宽度不超过 400 画布点。
  - 框选：自由框选同时能选中图片（包围盒与框选多边形相交即选中）；移动 / 手柄缩放对图片同样生效（图片等比）。
  - 删除 / 剪切 / 复制：复制图片走系统剪贴板的图片类型，与现有 `InkClipboard` 并存。
  - 双击图片看大图（复用现有看大图面板）。
  - 「内容包围盒」（软边界 / 适应内容 / minimap）= 笔迹 ∪ 图片。

### 3.4 本轮不做

- 从 PDF ⌥⇧ 拖截图直接放进某个画板笔记（以后可以在截图菜单里加一项）。
- 多图层、分组界面、MCP（用户没选）。

## 4. 协议（网页 + 安卓模式2）

### 4.1 复用的部分（一个字节不改）

当 Mac 被跟随的会话是画板标签时：

- 下行 `scratchpads`：`open = 0`，`list` 只有这一张（`page=0, nx=ny=0.5, showPage=0`）；`scratchStrokes` = 全部笔迹。
- 上行 `ink` / `erase` 照「纸开着」的规则走画布坐标；`scratchPaper` / `scratchRename`（`index=0`）改的是画板笔记；
  `undo` 走 `scratchUndo`。
- `scratchOpen(-1)` / `scratchAdd` / `scratchMove` / `scratchPageShow` / `scratchDelete` 在画板会话上**整帧丢弃**
  （客户端本来也不该发，见 4.3）。

### 4.2 新增消息

| opcode | 名称 | 方向 | payload |
|---|---|---|---|
| `0x52` | `boards` | S→C | `u8 kind` · `str current` · `u16 n` · `n ×( str id, str title )` |
| `0x53` | `boardOpen` | C→S | `str id` |
| `0x54` | `boardAdd` | C→S | 空 |
| `0x55` | `boardImages` | S→C | `u16 n` · `n ×( str id, str sha, f32 x, f32 y, f32 w, f32 h )` |

- `boards`：**全量镜像**。`kind` = 被跟随会话是什么：`0 = PDF`、`1 = Markdown 笔记`、`2 = 画板笔记`；
  `current` = `kind=2` 时是哪一篇的 id，否则空串；`list` = 当前工作区全部画板笔记（按最近打开排序）。
  发送时机：客户端接入、跟随的会话变化、画板笔记增删改名。
- `boardOpen`：请求 Mac 在被跟随的窗口里打开这篇（已开就切过去）。
- `boardAdd`：请求 Mac 新建一篇并打开。
- `boardImages`：当前画板上的图片全量镜像（不是画板会话时 `n=0`）。图片本体由客户端按
  `GET /image?h=<sha>` 取（同 `/page.png` 的鉴权口径），客户端按 sha 缓存。
- **平板只看不改图片**：本轮平板上不能加图、挪图、删图；框选在平板上只作用于笔迹。
- 顺手修一个老问题：`kind=1`（Markdown）时客户端显示「Mac 正在看 Markdown 笔记」的空状态，
  不再停在上一篇 PDF 的页面上（现在就是这么错的）。

### 4.3 客户端界面

`kind=2` 时（网页 / 安卓模式2 一样）：

- 草稿纸画布整屏显示，PDF 页面视图隐藏；
- 纸样面板里去掉「关闭」「页面底图」「列表里的其它草稿纸」「删除」，保留改名、纸样、回中、适应内容、minimap；
- 顶栏加一个「画板笔记」按钮：列出 `boards.list`（点一篇 = `boardOpen`）+「新建」（`boardAdd`）。
  这个按钮在 `kind=0/1` 时也在，所以平板随时能切到某篇画板笔记或新建一篇。

## 5. 安卓模式1（独立版）

- 书库页加一组「画板笔记」（读 `board_note`），可新建 / 改名 / 删除；没有表时先补建（§2.4）。
- 标签页支持画板标签：`TabSet` 存 `board:<id>`；画板标签整页是 `ScratchCanvas`（`setPageUnder(-1)`），
  由一个新的 `BoardController`（照 `ScratchController` 写，读写换成 `board_note` / `board_item`）接数据。
- 图片：从 `Images/<sha>.<ext>` 读来显示；**本轮只显示不编辑**（与平板一致）。
- 离线镜像：`MirrorFp` 加两张表（见 §6），`MirrorStore.snapshot` 对不存在的表要跳过。

## 6. 离线镜像 / 回收站 / 备份

- **离线镜像**（Mac `MirrorFingerprint` + 安卓 `MirrorFp`，两边同步改，`spike/mirror-fp-vectors.txt` 追加向量）：
  `board_note`、`board_item` 都按 `updated_at` 取新；顺序 `board_note` 在前。
  `board_item` 的「孤儿」判定看 `board_id` 是否还在（现在的孤儿判定只看 `document_id`，要加一条）。
  图片文件走现有的 `Images/` 追加通道，不用改。
- **回收站**：删画板笔记 = 先把 `board_note` + 它的 `board_item` 归档成一个回收站条目，再删（**顺序不许反**）；
  恢复 = 插回去。图片 30 天清理要跳过回收站里画板条目还引用着的图（同 `trashHeldImages`）。
- **定时备份**：`VACUUM INTO` 整库，自动包含，不用改。

## 7. 分步

1. **Mac 数据层**：v16 建表 + DAO + 模型 + 图片引用计数；spike `board-store-test.swift`。
2. **Mac 界面**：标签 / 侧栏 / 运行时 / `ScratchPadNSView` 独立模式 / 笔架；图片的加、选、移、缩放、撤销。
3. **Mac 其余**：离线镜像、回收站、图片清理。
4. **协议**：`PROTOCOL.md` + 三份编解码（`WireCodec.swift` / `wire.js` / 安卓 `WireCodec.kt`）+ Mac 收发 + `/image`。
5. **网页**：画板整屏、画板按钮、图片显示、Markdown 空状态；`build-web.sh`。
6. **安卓模式2**：同网页。
7. **安卓模式1**：建表、书库、画板标签、图片显示、离线镜像。

每一步编译通过再走下一步；视图部分我不能替你判断手感，做完一起交给你实测。

## 8. 实现记录（2026-09-26）

### 8.1 Mac 文件地图

| 文件 | 内容 |
|---|---|
| `Store/LibraryStore.swift` | v16 两张表 + DAO（`boards` / `upsertBoard` / `touchBoardOpened` / `boardItems` …）；`imageRefCounts` 并上 `board_item` kind=2 |
| `Store/LibraryModels.swift` | `LibBoard` / `LibBoardItem` |
| `App/BoardModel.swift` | `BoardNote`（`asPad` / `absorb`）、`BoardImage`（`placed` 默认摆放）、`ScratchBounds.contentBounds(_:images:)` |
| `App/InkModel.swift` | `InkStroke.toBoardItem` / `init(boardItem:padId:)` |
| `App/WorkspaceManager+Board.swift` | 列表 / 新建 / 改名 / 读内容 / 存笔迹与图 |
| `App/DocTabModel+Board.swift` | `openBoard` / `stageBoard` / `realizeBoard` / `leaveBoard` / `closeBoardIfGone` + 三个增量对账 |
| `App/AppModel+Board.swift` | `broadcastBoards` / `broadcastBoardImages`（顺带登记 `/image` 能取的文件）/ `boardOpen` / `boardAdd` |
| `App/TabsModel.swift` | `openBoard` / `newBoard` / `pruneMissingBoards`、`StoredTab.board`（键 `board:<uuid>`） |
| `Reader/Scratch/ScratchPadNSView.swift` | `standalone`（= 画板）：不能关、没有页面底图、多「插入图片」；图的加 / 选 / 移 / 缩放 / 删 / 复制 / 看大图 / 拖入 |
| `Reader/Scratch/ScratchCanvasNSLayers.swift` | `BoardImagesCALayer`；minimap 画图片色块 |
| `Reader/Pane/ReaderPaneController.swift` | 画板标签：不建阅读区，直接装纸 + 笔架；标签栏照常显示 |
| `Window/Sidebar/SidebarViewController.swift` | 「画板笔记」一段（空也显示段头，右键新建）；行右键：新建 / 改名 / 删除 |
| `Store/TrashStore.swift` + `App/WorkspaceManager+Trash.swift` | 回收站条目 kind `board`（`archiveBoard` → 删；恢复同一条 `restore`，`board_note` 按 OR IGNORE） |
| `Store/MirrorFingerprint.swift` / `MirrorApply.swift` / `MirrorReport.swift` | 镜像两张表 + `livingBoards` 孤儿过滤 |
| `Server/WireCodec.swift` / `Resources/wire.js` / `Server/LANServer.swift` | 0x52~0x55 + `GET /image?h=` |

测试：`spike/board-store-test.swift`（37 项）；`wire-codec-test` / `wire-cross-test.js` 追加 7 条向量；`mirror-fp-test` 追加两条行向量（`spike/mirror-fp-vectors.txt` 第 27、28 条）。

### 8.2 与方案的出入

- `boardImages` 去掉了 `ext` 字段：客户端只按 sha 取 `/image`，扩展名由 Mac 自己在 `Images/` 里找。
- 图的缩放：与笔迹用**同一个变换**（选中框两个对角各自变换再取包围盒）。角手柄默认等比，所以通常不变形；
  边中点手柄 / 按住 ⇧ 时图会跟着框一起被拉伸——这样选中框、光晕和结果三者始终一致。
- 快捷键：「文件 › 新建画板笔记」= **⌃⌘N**（⌥⌘N 已被夜间模式占用），已进 `Shortcuts.reserved`。
- 笔架上的「图层」按钮在画板里点了只响一声（画板不分图层，同草稿纸）。
- Inspector「笔记 › 草稿纸」在画板标签里只显示一句说明——否则会把画板本身当成一张草稿纸列出来，删它等于删掉整篇画板的笔迹。
- 网页在 Mac 看 Markdown 笔记时（`boards.kind = 1`）显示空状态，修掉「停在上一篇 PDF」的老问题；安卓模式2 同。

### 8.3 已知遗留（分页模式见 §9）

- 从 PDF ⌥⇧ 拖截图直接放进画板笔记（截图菜单加一项）——本轮没做。
- 平板上不能加图 / 挪图 / 删图（方案既定）。
- 画板没有分组界面（`group_name` 列已预留）。

## 9. 分页模式（2026-09-26 定）

用户原话：「画板做一下模式支持，一个是现在的无限画布模式，另外一个就是分页模式，一页一页的，可以预先创建 N 页，
也可以到底后上拉滚动添加页。分页支持设置页面大小，比如屏幕尺寸，A4 等等，然后分页支持各种草稿纸格式的底，
比如 cornell，两栏等等布局格式的背景图，允许单页使用不同的背景，也可以批量设置」。
同日拍板：**页面大小整本统一**；背景**只做内置模板**（程序画，不用图片）；平板（网页 + 模式2）= **书写 + 到底加页 +
改当前页背景**，插页 / 删页 / 批量设置只在 Mac 与安卓模式1；安卓照常建表（同日撤销了「安卓不改表结构」的规定）。

### 9.1 数据（schema v16 → v17）

```sql
-- v17：分页画板的页（BOARD-NOTE-PLAN.md §9）。一个画板有页 = 分页模式，没有页 = 无限画布（模式建画板时定，之后不转换）。
CREATE TABLE IF NOT EXISTS board_page (
  id TEXT PRIMARY KEY,
  board_id TEXT NOT NULL REFERENCES board_note(id) ON DELETE CASCADE,
  sort_key REAL NOT NULL,                 -- 页序：小数排序键，插页取前后两页的中点，不用改其它页
  width REAL NOT NULL, height REAL NOT NULL,   -- 页面尺寸（画布点）；整本统一 = 每页都存同一个值、一起改
  template TEXT NOT NULL DEFAULT 'blank', -- 背景模板，见 9.3
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_board_page_board ON board_page(board_id, sort_key);
```

- **分页画板上的条目（笔迹 / 图片）存「页内坐标」**：payload 多一个键 `"page": "<board_page.id>"`，
  点与 `x/y/w/h` 都相对该页左上角（画布点）。无限画布的条目没有这个键、照旧是画布坐标。
  这样**插页 / 删页 / 改尺寸都不用改别的页的条目**（离线镜像也不会因为插了一页就满屏「改过」）。
- 条目归哪一页：按它**第一个点**落在哪页定（页间空隙归上面那页，超出首末页的归首 / 末页）；笔迹可以画出页边，不裁。
- `page` 指向的页已不存在（镜像合并里一边删了页）→ 这条不显示（同草稿纸孤儿笔迹）。

### 9.2 布局契约（三端一致）

页按 `sort_key` 升序竖着排，**水平居中于画布 x = 0**：第 i 页（0 起）矩形 = `(-W/2, i × (H + 24), W, H)`，
页间距 **24** 画布点。运行时与线上一律用这个画布坐标（草稿纸整条链路照旧），只在落库 / 读库时与页内坐标互换。

页面尺寸预设（画布点，竖版；横版 = 宽高对调）：A4 595×842、A5 420×595、Letter 612×792、「当前屏幕」= 创建那台设备
屏幕的逻辑尺寸（Mac 取主屏可见区，平板取屏幕 dp）。

### 9.3 背景模板（三端一致，线上 u8）

`0 blank` 空白 · `1 lined` 横线 · `2 grid` 方格 · `3 dots` 点阵 · `4 cornell` 康奈尔 · `5 twoColumn` 两栏（只许尾部追加，
未知值按空白画）。几何全用页内画布点（与页面大小无关的固定间距，A4 与屏幕尺寸观感一致）：

| 模板 | 画法 |
|---|---|
| lined | 横线间距 28，自顶 72 起到底 36 止，左右各留 36 |
| grid | 20 × 20 方格铺满整页 |
| dots | 20 × 20 点阵铺满整页，点径 2 |
| cornell | 顶部标题区高 = 页高 12%（下边一条粗线）；底部总结区高 = 页高 20%（上边一条粗线）；中间左侧提示栏宽 = 页宽 30%（一条竖粗线）；中间区域加横线（间距 28） |
| twoColumn | 中线一条竖粗线（上下各留 48）；两栏各加横线（间距 28，中线两侧各留 12） |

线色由纸色明度推（同草稿纸底纹）：细线 alpha 0.14、粗线 alpha 0.30，线宽 1 / 1.5（画布点，随缩放）。
页面底色 = 画板纸色；页外（空隙与四周）= 窗口底色，页边一条淡描边。

### 9.4 交互

- **新建画板**时选模式：无限画布 / 分页；分页再选页面大小（含横竖）、背景模板、初始页数（1~100）。
- 分页视口：竖向滚动、横向夹在页宽内，打开时按页宽适配、停在第一页顶；工具条显示「第 i / N 页」，回中 = 回到当前页顶、
  适应内容 = 适配页宽；没有 minimap。
- **到底加页**：滚到最后一页底部后继续往上拉（Mac 触控板 / 滚轮继续往下滚），超过一段距离松手即在末尾加一页
  （沿用最后一页的背景），过程中底部有一行「继续上拉添加新页」的提示。
- Mac：页右键 = 在前面 / 后面插一页、删掉这一页（有内容要确认）、背景 ▸ 模板（这一页）；工具条「页面」弹层 =
  页列表多选 → 批量设背景 / 删除，整本页面大小（横竖、预设）。改尺寸 / 插页 / 删页后撤销栈清空（位置都变了）。
- 平板（网页 / 模式2）：书写、到底加页、改**当前页**背景（当前页 = 视口中心所在页）。
- 安卓模式1：与 Mac 相同（插页 / 删页 / 批量 / 改尺寸都有）。

### 9.5 协议（0x56~0x58）

| opcode | 名称 | 方向 | payload |
|---|---|---|---|
| `0x56` | `boardPages` | S→C | `f32 w` · `f32 h` · `u16 n` · `n ×( str id, u8 template )`（`n = 0` = 不是分页画板） |
| `0x57` | `boardPageAdd` | C→S | `u16 count`（在末尾加 count 页，沿用末页背景） |
| `0x58` | `boardPageTemplate` | C→S | `u16 index` · `u8 template` |

- `boardAdd`（0x54）尾部加**可选**字段：`u8 mode`（0 无限 / 1 分页）· `f32 w` · `f32 h` · `u8 template` · `u16 count`；
  老客户端发空 payload = 无限画布（行为不变）。
- 笔迹、图片仍走 `scratchStrokes` / `boardImages` 的画布坐标（Mac 按 9.2 换算），客户端按 9.2 自己排页画背景。

### 9.6 实现记录（2026-09-26，Mac + 网页 + 安卓两模式）

- Mac：`App/BoardModel.swift`（`BoardTemplate` / `BoardPage` / `BoardPageSize` / `BoardLayout` / `BoardTemplateGeometry`）、
  `App/DocSession+BoardPages.swift`（加页 / 插页 / 删页 / 改背景 / 改尺寸 + 连同对账快照一起平移）、`DocTabModel+Board`（页对账、
  条目按页换页内坐标落库）、`Reader/Scratch/BoardPagesPanel.swift`（「页面」弹层）、`Window/Sheets/NewBoardSheet.swift`（新建选模式）、
  `ScratchPadNSView`（`paged`：页面层 `BoardPagesCALayer`、夹取 `clamped`、`pageTop`、上拉加页 `notePull`、页右键菜单）。
- 网页：`web/src/lib/scratch.ts`（页绘制 / 模板几何 / 夹取 / 上拉加页 / 当前页背景）、`PadBar.svelte`（页码、背景面板、新建表单）。
- 安卓：`shared/BoardPaging.kt`（契约 Kotlin 版）+ `ScratchCanvas.setPages`、`shared/NewBoardSheet.kt`、模式1 `BoardController`
  「页面」弹层、模式2 `PadScratch`；**安卓改为正常迁移到 v17**（`Schema.migrate`，同日用户撤销了「安卓不改表结构」）。
- 测试：`spike/board-store-test.swift` 59 项（含布局 / 页内坐标换算 / 模板几何 / 回收站带页）；编解码向量 +5（Swift / JS / 安卓一致）；
  镜像指纹向量第 29 条 `row board_page`；安卓 `BoardPagingTest` 与 Mac 那几条逐条对应。
- 与方案的出入：安卓模式1 没有「页上长按菜单」，页操作都在「页面」弹层里、作用于视口中心那一页；安卓画板本来没有撤销栈
  （记在 `TODO.md` 模式1 对齐一条）；分页画板的纸样面板只保留纸色（底纹归每页模板）。

