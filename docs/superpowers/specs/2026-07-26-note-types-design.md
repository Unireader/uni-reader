# 文字笔记类型（按工作区自定义）设计

日期：2026-07-26 · 状态：已确认

## 目标

给文字注解（`TextNote`，note 表 kind=0）增加"类型"概念：每个工作区可自定义类型（如错题、注意项），每个类型有名称、配色、图标。内置兜底类型"通用"。

## 已确认的决策

- 预置策略：仅内置"通用"（不可删、不落库），其余全部由用户在工作区内自建。
- 颜色/图标：固定候选集（色板 + 精选 SF Symbol），不做任意取色/任意符号。
- 侧边栏：笔记条目显示类型色+图标，支持按类型筛选。
- 管理入口：笔记编辑器内类型选择菜单底部挂"管理类型…"。
- 删除类型：引用该类型的笔记回落到"通用"。

## 数据模型

### NoteType（新，`Sources/App/NoteTypeModel.swift`）

```swift
struct NoteType: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String        // 显示名，如"错题"
    var colorKey: String    // 色板键，如 "red"
    var iconName: String    // SF Symbol 名，如 "exclamationmark.triangle"
}
```

- **通用类型**：代码内置常量 `NoteType.general`（固定 UUID，如全 0；`colorKey="gray"`、`iconName="note.text"`、名称走本地化 `L("General")`）。不出现在工作区类型列表里，不可编辑、不可删除。
- **色板**（约 8 个，key → Color 映射常量表）：red / orange / yellow / green / blue / purple / pink / gray。
- **图标候选**（约 16 个 SF Symbol）：exclamationmark.triangle、questionmark.circle、bookmark、flag、star、play.rectangle（视频）、lightbulb、flame、checkmark.circle、xmark.octagon、quote.bubble、book、tag、pencil.line、eye、link。图标合法性以候选集校验，未知图标回落通用的 `note.text`。

### TextNote 变更

`TextNotePayload` 增加 `typeId: String?`（UUID 字符串）。`TextNote` 增加 `typeId: UUID?`。

- 旧 payload 无该字段 → 解码为 nil → 视为通用（Codable optional 天然兼容，无需迁移）。
- typeId 指向工作区里不存在的类型（如类型被其他端删除）→ 渲染按通用处理。

## 持久化

- **类型列表**：序列化为 JSON 数组存工作区 SQLite `meta` 表，`key='note_types'`，复用 `LibraryStore.meta()`/`setMeta()`。通用类型不落库。
- **WorkspaceManager** 新增：
  - `noteTypes() -> [NoteType]`（读 meta JSON，损坏/缺失返回空数组）
  - `saveNoteTypes(_ types: [NoteType])`（整体重写）
- **笔记**：`typeId` 随 `TextNote.toNote()` 进 payload，现有增量落库链路（`persistTextNotes`）不变。
- 跨平台：meta JSON 与 payload JSON 都是显式结构，Android/Windows 端可直接读；字段命名 snake_case 对齐现有 payload 风格（rects 等已是小写单词，typeId 存为 `type_id`）。

## UI 变更

### 笔记编辑器（`NoteEditorSheet`）

- 标题行下方加类型 Picker（`Menu` 样式）：每项显示色点+图标+名称，当前选中打勾；第一项恒为"通用"。
- 菜单底部"管理类型…"→ 弹出管理面板（`.sheet`）：
  - 类型列表（色点+图标+名称），行内编辑或点击进入编辑态；
  - 编辑态：名称 TextField、色板（圆点网格，选中描边）、图标网格（选中高亮）；
  - 新建按钮；删除按钮（通用无此按钮）。
- 删除被引用的类型：确认对话框说明"N 条笔记将改为通用"，确认后批量把引用笔记的 `typeId` 置 nil（走现有内存改 → onChange 对账落库链路）。
- ⌘回车保存、Esc 取消行为不变；保存回调签名从 `(String)` 改为 `(String, UUID?)`（文本 + 类型）。

### 页面图钉（`PageCellView`）

- 图钉图标/背景色跟随笔记类型：通用保持现有样式（`note.text` + 黄色圆底）；其他类型用类型图标 + 类型色圆底。
- 选区高亮色（`noteHighlight`）跟随类型色（透明度不变）。

### 侧边栏（`InspectorView` textBlock）

- 每条笔记条目前显示类型色点+类型图标（替换固定的 `text.quote`）。
- 区块标题旁加筛选菜单：全部 / 通用 / 各自定义类型；选中某类型后列表只显示该类型笔记。筛选状态存 session（不落库，重启复位"全部"）。

## 数据流

1. `ContentView.loadDocument` 时：`session.noteTypes = workspace.noteTypes()`（`DocSession` 加 `@Published var noteTypes` 与 `noteTypeFilter`）。
2. 新建批注：`ReaderSurface+Selection` 创建 `TextNote` 时带编辑器选中的 `typeId`。
3. 类型增删改：管理面板改内存数组 → 立即 `workspace.saveNoteTypes()`（低频操作，直接整体落库，无需对账）。
4. 渲染：`PageCellView`/`InspectorView` 通过 `typeId` 在 `session.noteTypes` 里查类型，查不到按通用渲染。

## 本地化

新增字符串（en + zh-Hans）：General、Note Type、Manage Types…、New Type、Type Name、删除确认文案等，沿用 `L()` 宏。

## 验证

- 新增 spike 脚本 `spike/note-type-test.swift`：测 `NoteType` JSON 编解码、meta 存取回环、旧 payload（无 type_id）解码为 nil、未知 typeId 回落逻辑。
- `xcodegen generate` + `xcodebuild` 编译通过。
- 手测路径：新建笔记选类型 → 图钉/侧边栏变色变图标；管理面板增改删类型；删除被引用类型 → 笔记回落通用；重开文档/工作区类型与笔记类型保留。

## 明确不做（YAGNI）

- 类型排序/拖拽、类型跨工作区复制、按类型导出、类型用于高亮/墨迹（仅文字笔记）。
- 任意取色器、任意 SF Symbol 输入。
