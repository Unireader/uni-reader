# 文字笔记类型（按工作区自定义）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给文字注解（TextNote）加按工作区自定义的类型（名称+固定色板+SF Symbol 图标），编辑器可选类型并就地管理，页面图钉/高亮与侧边栏列表跟随类型配色，侧边栏可按类型筛选。

**Architecture:** 类型定义（`NoteType`）以 JSON 数组存工作区 SQLite `meta(key='note_types')`（无 schema 迁移）；笔记侧 `TextNote` payload 加 `type_id`（旧数据零迁移，nil=通用）。"通用"为内置兜底类型，不落库、不可删。UI 三处消费：NoteEditorSheet（选择+管理）、PageCellView（图钉/高亮配色）、InspectorView（标识+筛选）。

**Tech Stack:** Swift 5 / SwiftUI / 系统 libsqlite3（自有封装，见 `Sources/Store/`）；验证走 spike 脚本（无测试 target）。

**Spec:** `docs/superpowers/specs/2026-07-26-note-types-design.md`

## Global Constraints

- macOS 26+，阅读区**纯 SwiftUI**，严禁 AppKit 视图（红线）。
- UI 外观严禁自绘仿系统样式；色板/图标网格是纯功能选择器，不仿系统控件外观。
- 存储零第三方依赖；跨平台 payload 用显式 JSON，键名 snake_case（对齐 `rects`/`type_id` 约定）。
- UI 文案一律走 `L()`（`Sources/Support/L.swift`），key 用英文原文，翻译放 `Sources/en.lproj` 与 `Sources/zh-Hans.lproj` 的 `Localizable.strings`；禁硬编码中文字面量。
- 新增/删除源文件后必须 `xcodegen generate`（`UniReader.xcodeproj` 是生成物，勿手改）。
- 无测试 target：逻辑验证走 spike 脚本（编译真实 Sources 文件驱动）。
- **git 提交需用户逐次确认**：每个任务的 Commit 步骤执行前先问用户；用户也可要求最后统一提交。
- 代码注释风格跟随所在文件（中文注释、说明"为什么"）。

---

### Task 1: NoteType 模型 + spike 测试

**Files:**
- Create: `Sources/App/NoteTypeModel.swift`
- Create: `spike/note-type-test.swift`

**Interfaces:**
- Produces（后续任务依赖）:
  - `struct NoteType: Identifiable, Equatable, Codable { id: UUID; name: String; colorKey: String; iconName: String }`（JSON 键：id/name/`color_key`/`icon_name`）
  - `NoteType.generalID: UUID`（全 0）、`NoteType.general: NoteType`
  - `NoteType.palette: [(key: String, r: Double, g: Double, b: Double)]`（0~255，8 色）
  - `NoteType.paletteRGB(_ key: String) -> (r: Double, g: Double, b: Double)`（未知 key → gray）
  - `NoteType.iconCandidates: [String]`（16 个 SF Symbol）
  - `NoteType.icon(_ raw: String) -> String`（候选集外 → "note.text"）
  - `NoteType.resolve(_ typeId: UUID?, in types: [NoteType]) -> NoteType`（nil/未知/generalID → general）
  - `NoteType.icon: String`（合法化后的实例图标）
  - `enum NoteTypeFilter: Equatable { case all; case only(UUID?) }`

- [ ] **Step 1: 写 spike 失败测试**

创建 `spike/note-type-test.swift`：

```swift
// NoteType 模型 + 工作区 meta 持久化回归测试。运行：
//   cp spike/note-type-test.swift /tmp/nt_main.swift && swiftc Sources/Store/*.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/nt_main.swift -o /tmp/nt && /tmp/nt
// （须命名为 main.swift 风格编译：swiftc 多文件时顶层代码只允许在一个文件；这里借 /tmp/nt_main.swift）

import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

// 1) NoteType JSON 回环 + snake_case 键
let t = NoteType(name: "错题", colorKey: "red", iconName: "exclamationmark.triangle")
let data = try! JSONEncoder().encode([t])
let json = String(data: data, encoding: .utf8)!
check(json.contains("\"color_key\"") && json.contains("\"icon_name\""), "JSON 键为 snake_case（color_key/icon_name）")
let back = try! JSONDecoder().decode([NoteType].self, from: data)
check(back == [t], "NoteType 数组编解码回环")

// 2) 色板/图标兜底
check(NoteType.paletteRGB("red").r == 255, "色板 red 命中")
check(NoteType.paletteRGB("nope") == NoteType.paletteRGB("gray"), "未知色 key → gray")
check(NoteType.icon("flame") == "flame", "候选图标命中")
check(NoteType.icon("not-a-symbol") == "note.text", "未知图标 → note.text")

// 3) 通用兜底
check(NoteType.general.id == NoteType.generalID, "通用 id 固定")
check(NoteType.resolve(nil, in: [t]).id == NoteType.generalID, "nil typeId → 通用")
check(NoteType.resolve(UUID(), in: [t]).id == NoteType.generalID, "未知 typeId → 通用")
check(NoteType.resolve(t.id, in: [t]) == t, "已知 typeId → 命中")

// 4) 工作区 meta 回环（模拟 WorkspaceManager.noteTypes/saveNoteTypes 的编解码）
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws_nt_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let store = try LibraryStore(workspaceFolder: tmp)
try store.setMeta("note_types", json)
let read = store.meta("note_types").flatMap { $0.data(using: .utf8) }
    .flatMap { try? JSONDecoder().decode([NoteType].self, from: $0) } ?? []
check(read == [t], "meta(note_types) 写入/读回")
check(store.meta("note_types") != nil, "meta 键存在")
let broken = "{oops".data(using: .utf8)!
check((try? JSONDecoder().decode([NoteType].self, from: broken)) == nil, "损坏 JSON → 解码 nil（上层回落空数组）")

print("\n通过 \(pass)，失败 \(fail)")
if fail > 0 { exit(1) }
```

- [ ] **Step 2: 跑测试确认失败（NoteType 未定义）**

Run: `cp spike/note-type-test.swift /tmp/nt_main.swift && swiftc Sources/Store/*.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/nt_main.swift -o /tmp/nt && /tmp/nt`
Expected: 编译失败，`cannot find 'NoteType' in scope`（NoteTypeModel.swift 尚不存在，swiftc 报 file not found 也算失败确认）

注意：编译带上 `TextNoteModel.swift`（依赖 InkColor）→ `InkModel.swift`（依赖 PenBrushType）→ `PenPreset.swift`（import SwiftUI）+ `L.swift`。swiftc CLI 编译 import SwiftUI 的文件可行但稍慢；若 `PenPreset.swift` 因 SwiftUI 依赖报错，备选方案：编译列表去掉 `PenPreset.swift`，在 `/tmp/nt_main.swift` 顶部加一行 stub `enum PenBrushType: String, Codable { case ballpoint }`。

- [ ] **Step 3: 实现 NoteTypeModel**

创建 `Sources/App/NoteTypeModel.swift`（纯 Foundation，不 import SwiftUI/AppKit，保证 spike 可编译；SwiftUI 颜色换算在 Task 5 的 UI 层做）：

```swift
import Foundation

/// 文字笔记类型（工作区级自定义）：名称 + 固定色板 key + SF Symbol 图标。
/// 落工作区 `meta(key='note_types')` 的 JSON 数组（snake_case 键，跨平台可读）；
/// 笔记侧 payload 存 `type_id`（见 TextNoteModel）。「通用」是内置兜底（generalID），
/// 不落库、不可编辑/删除；笔记 typeId 为 nil 或指向不存在类型时一律按通用渲染。
struct NoteType: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String
    var colorKey: String    // 色板 key，如 "red"
    var iconName: String    // SF Symbol 名，如 "exclamationmark.triangle"

    enum CodingKeys: String, CodingKey {
        case id, name
        case colorKey = "color_key"
        case iconName = "icon_name"
    }
}

extension NoteType {
    /// 内置「通用」类型的固定 id（全 0）。显示名不走模型，UI 层用 `L("General")`。
    static let generalID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let general = NoteType(id: generalID, name: "", colorKey: "gray", iconName: "note.text")

    /// 固定色板（0~255 RGB）。新建类型默认取第一个（red）。
    static let palette: [(key: String, r: Double, g: Double, b: Double)] = [
        ("red",    255,  59,  48),
        ("orange", 255, 149,   0),
        ("yellow", 255, 204,   0),
        ("green",   52, 199,  89),
        ("blue",     0, 122, 255),
        ("purple", 175,  82, 222),
        ("pink",   255,  45,  85),
        ("gray",   142, 142, 147),
    ]
    /// 色板查色：未知 key（手改坏/跨端未同步）回落 gray。
    static func paletteRGB(_ key: String) -> (r: Double, g: Double, b: Double) {
        palette.first { $0.key == key }.map { ($0.r, $0.g, $0.b) } ?? (142, 142, 147)
    }

    /// 图标候选（SF Symbol）。新建类型默认取第一个。
    static let iconCandidates: [String] = [
        "note.text", "exclamationmark.triangle", "questionmark.circle", "bookmark",
        "flag", "star", "play.rectangle", "lightbulb",
        "flame", "checkmark.circle", "xmark.octagon", "quote.bubble",
        "book", "tag", "pencil.line", "eye",
    ]
    /// 合法化图标名：候选集外一律回落通用图标（SF Symbol 名非法会渲染空白）。
    static func icon(_ raw: String) -> String { iconCandidates.contains(raw) ? raw : "note.text" }

    /// 笔记类型解析：nil / 未知 id / 通用 id → 通用；否则取工作区类型。
    static func resolve(_ typeId: UUID?, in types: [NoteType]) -> NoteType {
        guard let typeId, typeId != generalID,
              let t = types.first(where: { $0.id == typeId }) else { return general }
        return t
    }

    /// 合法化后的实例图标（模型的 iconName 可能被手改坏）。
    var icon: String { NoteType.icon(iconName) }
}

/// 侧边栏笔记筛选（仅内存，不落库）：全部 / 仅某类型（nil = 通用）。
enum NoteTypeFilter: Equatable {
    case all
    case only(UUID?)
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2 命令
Expected: 全部 ✅，`通过 13，失败 0`（Task 2 会再追加用例）

- [ ] **Step 5: Commit（先经用户确认）**

```bash
git add Sources/App/NoteTypeModel.swift spike/note-type-test.swift
git commit -m "feat: NoteType 模型（工作区自定义笔记类型：名称/色板/图标 + 通用兜底）"
```

---

### Task 2: TextNote payload 加 type_id

**Files:**
- Modify: `Sources/App/TextNoteModel.swift`
- Modify: `spike/note-type-test.swift`

**Interfaces:**
- Consumes: `NoteType`（Task 1）
- Produces: `TextNote.typeId: UUID?`（nil=通用）；payload JSON 键 `type_id`（String?，旧 payload 无此键 → nil，零迁移）

- [ ] **Step 1: spike 追加失败用例**

在 `spike/note-type-test.swift` 的 `print` 汇总行前追加：

```swift
// 5) TextNote payload：旧数据无 type_id → nil（通用）；新数据回环保留
let docId = "doc-1"
var note = TextNote(page: 2, anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05),
                    quote: "原文", text: "批注", rects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)])
let oldPayload = Data("{\"quote\":\"原文\",\"text\":\"批注\",\"rects\":[[0.1,0.2,0.3,0.05]]}".utf8)
let oldRow = LibNote(id: note.id.uuidString, documentId: docId, kind: TextNote.noteKind,
                     page: 2, anchor: note.anchor, payload: oldPayload,
                     createdAt: note.createdAt, updatedAt: note.updatedAt)
check(TextNote(note: oldRow)?.typeId == nil, "旧 payload（无 type_id）→ typeId nil")
note.typeId = t.id
let row = note.toNote(documentId: docId)!
check(String(data: row.payload, encoding: .utf8)!.contains("\"type_id\""), "payload 含 type_id 键")
check(TextNote(note: row)?.typeId == t.id, "typeId 编解码回环")
```

- [ ] **Step 2: 跑测试确认失败**

Run: 同 Task 1 Step 2 命令
Expected: 编译错误 `extra argument 'typeId' in call` 或断言失败（typeId 尚不存在）

- [ ] **Step 3: 改 TextNoteModel**

`Sources/App/TextNoteModel.swift` 三处改动：

1. `TextNote` 结构体加字段（放 `color` 之后）：

```swift
    var color: InkColor?        // 预留：高亮色（高亮形态复用）
    var typeId: UUID? = nil     // 笔记类型（工作区 NoteType.id）；nil/未知 = 通用
```

2. `TextNotePayload` 加字段与 CodingKeys：

```swift
private struct TextNotePayload: Codable {
    var quote: String
    var text: String
    var rects: [[Double]]
    var color: InkColor?
    var typeId: String?     // JSON 键 type_id；旧 payload 无此键 → nil（通用），零迁移

    enum CodingKeys: String, CodingKey {
        case quote, text, rects, color
        case typeId = "type_id"
    }
}
```

3. `toNote` 与 `init?(note:)` 接线：

```swift
        let payload = TextNotePayload(quote: quote, text: text,
                                      rects: rects.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                      color: color, typeId: typeId?.uuidString)
```

```swift
        self.init(id: uuid, page: note.page, anchor: note.anchor, quote: p.quote, text: p.text,
                  rects: rects, color: p.color, typeId: p.typeId.flatMap { UUID(uuidString: $0) },
                  createdAt: note.createdAt, updatedAt: note.updatedAt)
```

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Task 1 Step 2 命令
Expected: 全部 ✅，`通过 16，失败 0`

- [ ] **Step 5: Commit（先经用户确认）**

```bash
git add Sources/App/TextNoteModel.swift spike/note-type-test.swift
git commit -m "feat: TextNote payload 加 type_id（旧数据零迁移，nil=通用）"
```

---

### Task 3: WorkspaceManager 类型持久化

**Files:**
- Modify: `Sources/App/WorkspaceManager.swift`（文字注解持久化区块附近，约 line 307 后）

**Interfaces:**
- Consumes: `NoteType`（Task 1）、`LibraryStore.meta(_:)`/`setMeta(_:_:)`（已存在）
- Produces: `WorkspaceManager.noteTypes() -> [NoteType]`、`WorkspaceManager.saveNoteTypes(_ types: [NoteType])`

- [ ] **Step 1: 实现（spike 已在 Task 1 覆盖 meta+编解码回环，此任务为薄封装，直接实现）**

在 `WorkspaceManager` 的「文字注解持久化」MARK 区块前插入：

```swift
    // MARK: - 笔记类型持久化（工作区级，meta key=note_types，JSON 数组；通用不落库）

    /// 读取工作区自定义笔记类型（损坏/缺失 → 空数组；「通用」内置兜底不在其中）。
    func noteTypes() -> [NoteType] {
        guard let s = store?.meta("note_types"), let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([NoteType].self, from: data) else { return [] }
        return arr.filter { $0.id != NoteType.generalID }
    }

    /// 整体重写工作区自定义笔记类型（管理面板增删改后调用；自动剔除误混入的通用）。
    func saveNoteTypes(_ types: [NoteType]) {
        let filtered = types.filter { $0.id != NoteType.generalID }
        guard let data = try? JSONEncoder().encode(filtered),
              let s = String(data: data, encoding: .utf8) else { return }
        try? store?.setMeta("note_types", s)
    }
```

- [ ] **Step 2: 编译验证**

Run: `xcodegen generate && xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED（新文件 NoteTypeModel.swift 首次纳入工程）

- [ ] **Step 3: Commit（先经用户确认）**

```bash
git add Sources/App/WorkspaceManager.swift
git commit -m "feat: WorkspaceManager 笔记类型持久化（meta note_types JSON）"
```

---

### Task 4: DocSession 状态 + ContentView 载入

**Files:**
- Modify: `Sources/App/DocSession.swift`（textNotes 区块，约 line 104 后）
- Modify: `Sources/Views/ContentView.swift`（loadDocument 内 `loadTextNotes(documentId: id)` 调用处，约 line 437）

**Interfaces:**
- Consumes: `NoteType`/`NoteTypeFilter`（Task 1）、`WorkspaceManager.noteTypes()`（Task 3）
- Produces: `DocSession.noteTypes: [NoteType]`（@Published）、`DocSession.noteTypeFilter: NoteTypeFilter`（@Published）

- [ ] **Step 1: DocSession 加状态**

`Sources/App/DocSession.swift` 在 `persistedTextNotes` 声明后插入：

```swift
    // 笔记类型（工作区级，meta JSON 持久化）。阅读区（图钉/编辑器）与 Inspector（标识/筛选）共读；
    // 由 ReaderSurface.saveNoteTypes 增删改并整体落库；「通用」为内置兜底，不在此数组。
    @Published var noteTypes: [NoteType] = []
    /// Inspector 笔记列表筛选：.all 全部 / .only(nil) 通用 / .only(id) 指定类型。仅内存，重启复位。
    @Published var noteTypeFilter: NoteTypeFilter = .all
```

- [ ] **Step 2: ContentView 载入**

`Sources/Views/ContentView.swift` loadDocument 中 `loadTextNotes(documentId: id)`（约 line 437）前一行插入：

```swift
        session.noteTypes = workspace.noteTypes()   // 工作区笔记类型（通用内置兜底，不在列）
        session.noteTypeFilter = .all               // 筛选仅内存，开文档复位
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit（先经用户确认）**

```bash
git add Sources/App/DocSession.swift Sources/Views/ContentView.swift
git commit -m "feat: session 持有工作区笔记类型与筛选状态，开文档时载入"
```

---

### Task 5: 编辑器类型选择 + 类型管理面板

**Files:**
- Modify: `Sources/Views/NoteEditorSheet.swift`（重写）
- Create: `Sources/Views/NoteTypeManagerView.swift`
- Modify: `Sources/Views/PageStreamSupport.swift`（NoteEditorTarget 加 initialTypeId，约 line 47-69）
- Modify: `Sources/Views/ReaderSurface+Selection.swift`（saveEditor/commitNote/updateNote，约 line 172-198；加 saveNoteTypes）
- Modify: `Sources/Views/PageStreamView.swift`（ReaderSurface 加 workspace 环境对象，约 line 48-57；sheet 调用点，约 line 167-171）

**Interfaces:**
- Consumes: `NoteType`/`NoteTypeFilter`（Task 1）、`TextNote.typeId`（Task 2）、`WorkspaceManager.saveNoteTypes`（Task 3）、`session.noteTypes`（Task 4）
- Produces:
  - `NoteEditorSheet(quote:initialText:initialTypeId:noteTypes:usageCount:saveTitle:onSave:onChangeTypes:onCancel:)`，`onSave: (String, UUID?) -> Void`
  - `NoteTypeManagerView(noteTypes:usageCount:onChange:onClose:)`
  - `NoteType.uiColor: Color`（SwiftUI 换算扩展，定义在 NoteTypeManagerView.swift 顶部，Task 6/7 复用）
  - `NoteEditorTarget.initialTypeId: UUID?`
  - `ReaderSurface.saveEditor(_:text:typeId:)`、`commitNote(draft:text:typeId:)`、`updateNote(_:text:typeId:)`、`saveNoteTypes(_:)`

- [ ] **Step 1: NoteEditorTarget 加 initialTypeId**

`Sources/Views/PageStreamSupport.swift` 的 `NoteEditorTarget` 内（`initialText` 之后）加：

```swift
    var initialTypeId: UUID? {
        switch self {
        case .new: return nil
        case .edit(let n): return n.typeId
        }
    }
```

- [ ] **Step 2: 重写 NoteEditorSheet（类型选择 Menu + 管理面板入口）**

`Sources/Views/NoteEditorSheet.swift` 全文替换为：

```swift
import SwiftUI

/// 文字注解编辑器（新建 / 编辑复用）。上方展示被注解的原文（只读引文），下方 TextEditor 输入批注。
/// 标题行右侧挂类型选择（Menu：通用 + 工作区自定义类型，底部「管理类型…」弹管理面板）。
/// 走标准 `.sheet` 呈现（原生模态，无浮层 hack）；⌘回车保存、Esc 取消。
struct NoteEditorSheet: View {
    let quote: String
    let saveTitle: String
    let noteTypes: [NoteType]                 // 工作区自定义类型（不含通用）
    let usageCount: (UUID) -> Int             // 某类型被多少条笔记引用（删除确认用）
    let onSave: (String, UUID?) -> Void       // 批注文本 + 类型（nil=通用）
    let onChangeTypes: ([NoteType]) -> Void   // 管理面板增删改后整体回写
    let onCancel: () -> Void

    @State private var text: String
    @State private var typeId: UUID?
    @State private var managing = false
    @FocusState private var editorFocused: Bool

    init(quote: String, initialText: String, initialTypeId: UUID?,
         noteTypes: [NoteType], usageCount: @escaping (UUID) -> Int,
         saveTitle: String = L("Save"),
         onSave: @escaping (String, UUID?) -> Void,
         onChangeTypes: @escaping ([NoteType]) -> Void,
         onCancel: @escaping () -> Void) {
        self.quote = quote
        self.saveTitle = saveTitle
        self.noteTypes = noteTypes
        self.usageCount = usageCount
        self.onSave = onSave
        self.onChangeTypes = onChangeTypes
        self.onCancel = onCancel
        _text = State(initialValue: initialText)
        _typeId = State(initialValue: initialTypeId)
    }

    /// 当前选中类型（nil/未知 id → 通用）。
    private var current: NoteType { NoteType.resolve(typeId, in: noteTypes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Note")).font(.headline)
                Spacer()
                typePicker
            }

            if !quote.isEmpty {
                Text(quote)
                    .font(.callout).italic().foregroundStyle(.secondary)
                    .lineLimit(4).multilineTextAlignment(.leading)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(width: 380, height: 140)
                .focused($editorFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Spacer()
                Button(L("Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave(text, typeId) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { editorFocused = true }
        .sheet(isPresented: $managing) {
            NoteTypeManagerView(noteTypes: noteTypes, usageCount: usageCount,
                                onChange: onChangeTypes, onClose: { managing = false })
        }
    }

    /// 类型选择：通用恒为第一项；label 显示当前类型色点 + 名称。
    private var typePicker: some View {
        Menu {
            Button { typeId = nil } label: {
                Label(L("General"), systemImage: NoteType.general.iconName)
            }
            ForEach(noteTypes) { t in
                Button { typeId = t.id } label: {
                    Label(t.name, systemImage: t.icon)
                }
            }
            Divider()
            Button(L("Manage Types…")) { managing = true }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(current.uiColor).frame(width: 10, height: 10)
                Text(current.id == NoteType.generalID ? L("General") : current.name).font(.callout)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}
```

- [ ] **Step 3: 新建类型管理面板**

创建 `Sources/Views/NoteTypeManagerView.swift`：

```swift
import SwiftUI

/// 类型色板 key → SwiftUI 颜色（模型层只存 RGB，UI 换算集中于此；图钉/侧边栏同用）。
extension NoteType {
    var uiColor: Color {
        let rgb = NoteType.paletteRGB(colorKey)
        return Color(red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255)
    }
}

/// 笔记类型管理面板（编辑器内「管理类型…」弹出）：列表 + 新建/编辑/删除。
/// 「通用」内置兜底不在列、不可改。改动经 onChange 整体回写（调用方负责落库 + 被删类型的笔记回落）。
struct NoteTypeManagerView: View {
    let noteTypes: [NoteType]
    let usageCount: (UUID) -> Int
    let onChange: ([NoteType]) -> Void
    let onClose: () -> Void

    @State private var draft: NoteType?      // 非 nil = 新建/编辑中（sheet）
    @State private var deleting: NoteType?   // 非 nil = 删除确认中（alert）

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Manage Types")).font(.headline)

            if noteTypes.isEmpty {
                Text(L("No custom types yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(noteTypes) { t in
                    HStack(spacing: 8) {
                        Circle().fill(t.uiColor).frame(width: 10, height: 10)
                        Image(systemName: t.icon).frame(width: 16)
                        Text(t.name).lineLimit(1)
                        Spacer()
                        Button { draft = t } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).help(L("Edit Type"))
                        Button { deleting = t } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).help(L("Delete"))
                    }
                }
            }

            HStack {
                Button(L("New Type")) {
                    draft = NoteType(name: "", colorKey: NoteType.palette[0].key,
                                     iconName: NoteType.iconCandidates[0])
                }
                Spacer()
                Button(L("Done")) { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
        .sheet(item: $draft) { t in
            NoteTypeEditView(draft: t, isNew: !noteTypes.contains(t),
                             onDone: { saved in
                                 var types = noteTypes
                                 if let i = types.firstIndex(where: { $0.id == saved.id }) {
                                     types[i] = saved
                                 } else {
                                     types.append(saved)
                                 }
                                 onChange(types)
                                 draft = nil
                             },
                             onCancel: { draft = nil })
        }
        .alert(item: $deleting) { t in
            let n = usageCount(t.id)
            return Alert(title: Text(String(format: L("Delete type “%@”?"), t.name)),
                         message: n > 0 ? Text(String(format: L("%d note(s) will revert to General."), n)) : nil,
                         primaryButton: .destructive(Text(L("Delete"))) {
                             onChange(noteTypes.filter { $0.id != t.id })
                         },
                         secondaryButton: .cancel())
        }
    }
}

/// 单个类型的新建/编辑：名称 + 固定色板 + 图标网格。名称为空禁存。
struct NoteTypeEditView: View {
    @State var draft: NoteType
    let isNew: Bool
    let onDone: (NoteType) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? L("New Type") : L("Edit Type")).font(.headline)

            TextField(L("Type Name"), text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                ForEach(NoteType.palette, id: \.key) { sw in
                    Circle()
                        .fill(Color(red: sw.r / 255, green: sw.g / 255, blue: sw.b / 255))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(0.6),
                                                 lineWidth: draft.colorKey == sw.key ? 2 : 0))
                        .onTapGesture { draft.colorKey = sw.key }
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 8), spacing: 8) {
                ForEach(NoteType.iconCandidates, id: \.self) { name in
                    Image(systemName: name)
                        .frame(width: 28, height: 28)
                        .background(draft.iconName == name ? Color.accentColor.opacity(0.25) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .onTapGesture { draft.iconName = name }
                }
            }

            HStack {
                Spacer()
                Button(L("Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Save")) { onDone(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
```

- [ ] **Step 4: ReaderSurface 接线（保存分派带 typeId + 类型回写落库）**

`Sources/Views/ReaderSurface+Selection.swift`：

1. `saveEditor` 改为（约 line 172）：

```swift
    /// 编辑器保存分派：新建 → 追加；编辑 → 就地改文本与类型。
    func saveEditor(_ target: NoteEditorTarget, text: String, typeId: UUID?) {
        switch target {
        case .new(let draft): commitNote(draft: draft, text: text, typeId: typeId)
        case .edit(let note): updateNote(note, text: text, typeId: typeId)
        }
        editorTarget = nil
    }
```

2. `commitNote` 改为（约 line 182）：

```swift
    /// 新建批注：落成 `TextNote` 追加到 `session.textNotes`（ContentView 的 onChange 增量落库）。
    /// 点注解（无引文）必须有文字，否则是个空图钉——直接丢弃不落库。选区注解允许空文字（=纯高亮标记）。
    func commitNote(draft: PendingNote, text: String, typeId: UUID?) {
        if draft.quote.isEmpty, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearSelection(); return
        }
        session.textNotes.append(TextNote(page: draft.page, anchor: draft.anchor, quote: draft.quote,
                                          text: text, rects: draft.rects, typeId: typeId))
        clearSelection()
    }
```

3. `updateNote` 改为（约 line 192）：

```swift
    /// 编辑批注：就地改文本 + 类型 + bump updatedAt → 数组变更触发 onChange，对账识别为“变更”并 upsert。
    func updateNote(_ note: TextNote, text: String, typeId: UUID?) {
        guard let idx = session.textNotes.firstIndex(where: { $0.id == note.id }) else { return }
        var n = session.textNotes[idx]
        n.text = text
        n.typeId = typeId
        n.updatedAt = .now
        session.textNotes[idx] = n
    }
```

4. `updateNote` 后追加类型回写：

```swift
    /// 类型增删改回写（编辑器管理面板 → onChangeTypes）：更新内存 + 整体落库（meta JSON）；
    /// 被删类型的引用笔记回落通用（typeId=nil，走 textNotes 对账落库，无需逐条手动 upsert）。
    func saveNoteTypes(_ types: [NoteType]) {
        let removed = Set(session.noteTypes.map(\.id)).subtracting(types.map(\.id))
        session.noteTypes = types
        workspace.saveNoteTypes(types)
        guard !removed.isEmpty else { return }
        for i in session.textNotes.indices where session.textNotes[i].typeId.map({ removed.contains($0) }) ?? false {
            session.textNotes[i].typeId = nil
            session.textNotes[i].updatedAt = .now
        }
    }
```

`Sources/Views/PageStreamView.swift`：

5. `ReaderSurface` 声明区（约 line 49 `@EnvironmentObject var app: AppModel` 后）加：

```swift
    @EnvironmentObject var workspace: WorkspaceManager
```

6. sheet 调用点（约 line 167-171）改为：

```swift
        .sheet(item: $editorTarget) { target in
            NoteEditorSheet(quote: target.quote, initialText: target.initialText,
                            initialTypeId: target.initialTypeId,
                            noteTypes: session.noteTypes,
                            usageCount: { id in session.textNotes.filter { $0.typeId == id }.count },
                            onSave: { saveEditor(target, text: $0, typeId: $1) },
                            onChangeTypes: { saveNoteTypes($0) },
                            onCancel: { editorTarget = nil })
        }
```

- [ ] **Step 5: 编译验证**

Run: `xcodegen generate && xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED（NoteTypeManagerView.swift 首次纳入工程）

- [ ] **Step 6: Commit（先经用户确认）**

```bash
git add Sources/Views/NoteEditorSheet.swift Sources/Views/NoteTypeManagerView.swift Sources/Views/PageStreamSupport.swift Sources/Views/ReaderSurface+Selection.swift Sources/Views/PageStreamView.swift
git commit -m "feat: 批注编辑器支持选类型 + 类型管理面板（增删改/删除回落通用）"
```

---

### Task 6: PageCellView 图钉/高亮跟随类型

**Files:**
- Modify: `Sources/Views/PageCellView.swift`（属性区约 line 18；注解高亮 Canvas 约 line 76-83；图钉 ForEach 约 line 104-116；静态色约 line 149-150）
- Modify: `Sources/Views/PageStreamView.swift`（PageCellView 调用点，约 line 256）

**Interfaces:**
- Consumes: `NoteType.resolve`（Task 1）、`NoteType.uiColor`（Task 5）、`session.noteTypes`（Task 4）
- Produces: `PageCellView.noteTypes: [NoteType]`（新入参）

- [ ] **Step 1: PageCellView 接入类型配色**

`Sources/Views/PageCellView.swift` 四处改动：

1. 属性区（`var notes: [TextNote] = []` 后）加：

```swift
    var noteTypes: [NoteType] = []         // 工作区笔记类型：图钉/高亮配色（通用保持既有黄色样式）
```

2. 注解荧光高亮 Canvas（约 line 76-83）改为按类型取色：

```swift
            // 文字注解荧光高亮（持久层，居搜索/选择高亮之下）：通用铺暖黄，自定义类型铺类型色。
            if !notes.isEmpty {
                Canvas { ctx, sz in
                    for n in notes {
                        let col = n.typeId == nil ? Self.noteHighlight
                            : NoteType.resolve(n.typeId, in: noteTypes).uiColor.opacity(0.32)
                        for r in n.rects { fillNorm(r, in: &ctx, size: sz, color: col) }
                    }
                }
                .allowsHitTesting(false)
            }
```

3. 图钉 ForEach（约 line 104-116）改为：

```swift
            // 批注图钉（可点）：点开编辑器查看/编辑。悬停显示批注/原文预览。
            // 通用保持既有样式（note.text + 黄底）；自定义类型用类型图标 + 类型色底。
            ForEach(notes) { n in
                let typed = n.typeId != nil
                let t = NoteType.resolve(n.typeId, in: noteTypes)
                Button { onOpenNote(n) } label: {
                    Image(systemName: typed ? t.icon : "note.text")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.75))
                        .padding(3)
                        .background(typed ? t.uiColor : Self.noteMarker, in: Circle())
                        .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(n.text.isEmpty ? n.quote : n.text)
                .position(markerPos(n, size: size))
            }
```

- [ ] **Step 2: 调用点传入 noteTypes**

`Sources/Views/PageStreamView.swift` PageCellView 调用点（约 line 256 `notes: session.textNotes.filter { $0.page == i },` 后一行）加：

```swift
                     noteTypes: session.noteTypes,
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit（先经用户确认）**

```bash
git add Sources/Views/PageCellView.swift Sources/Views/PageStreamView.swift
git commit -m "feat: 页面图钉与注解高亮跟随笔记类型配色/图标"
```

---

### Task 7: InspectorView 类型标识 + 筛选

**Files:**
- Modify: `Sources/Views/InspectorView.swift`（textBlock 约 line 200-241）

**Interfaces:**
- Consumes: `NoteType.resolve`/`icon`（Task 1）、`NoteType.uiColor`（Task 5）、`session.noteTypes`/`session.noteTypeFilter`（Task 4）

- [ ] **Step 1: textBlock 重写（筛选菜单 + 条目类型标识）**

`Sources/Views/InspectorView.swift` 的 `textBlock`（约 line 200-241）整体替换为：

```swift
    /// 当前筛选下的笔记列表：.all 全部 / .only(nil) 通用 / .only(id) 指定类型。
    private var filteredTextNotes: [TextNote] {
        session.textNotes.filter { n in
            switch session.noteTypeFilter {
            case .all: return true
            case .only(let id): return n.typeId == id
            }
        }
    }

    private var textBlock: some View {
        block("\(L("Text Notes")) · \(filteredTextNotes.count)") {
            if session.textNotes.isEmpty {
                Text(L("No text notes yet.")).foregroundStyle(.secondary).font(.callout)
            } else {
                noteTypeFilterMenu
                ForEach(filteredTextNotes) { n in
                    let t = NoteType.resolve(n.typeId, in: session.noteTypes)
                    HStack(alignment: .top, spacing: 6) {
                        Button {
                            onJumpTo(n.page, max(0, n.anchor.minY - 0.03))   // 跳到该批注所在页/位置
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle().fill(t.uiColor).frame(width: 8, height: 8)
                                    Label(String(format: L("Page %d"), n.page + 1), systemImage: t.icon)
                                        .font(.callout)
                                    if t.id != NoteType.generalID {
                                        Text(t.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if !n.text.isEmpty {
                                    Text(n.text).font(.callout).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !n.quote.isEmpty {
                                    Text(n.quote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            deleteTextNote(n)   // × → 从内存移除 → ContentView onChange 对账删 note 行
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.body).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Delete this note"))
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    /// 类型筛选菜单：全部 / 通用 / 各自定义类型。选中项显示在 label 上。
    private var noteTypeFilterMenu: some View {
        Menu {
            Button { session.noteTypeFilter = .all } label: {
                Label(L("All Types"), systemImage: "line.3.horizontal.decrease.circle")
            }
            Button { session.noteTypeFilter = .only(nil) } label: {
                Label(L("General"), systemImage: NoteType.general.iconName)
            }
            ForEach(session.noteTypes) { t in
                Button { session.noteTypeFilter = .only(t.id) } label: {
                    Label(t.name, systemImage: t.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(filterLabel)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var filterLabel: String {
        switch session.noteTypeFilter {
        case .all: return L("All Types")
        case .only(let id):
            guard let id else { return L("General") }
            return session.noteTypes.first { $0.id == id }?.name ?? L("General")
        }
    }
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit（先经用户确认）**

```bash
git add Sources/Views/InspectorView.swift
git commit -m "feat: 侧边栏笔记列表显示类型标识并支持按类型筛选"
```

---

### Task 8: 本地化 + 全量验证 + 文档

**Files:**
- Modify: `Sources/en.lproj/Localizable.strings`
- Modify: `Sources/zh-Hans.lproj/Localizable.strings`
- Modify: `HISTORY.md`

**Interfaces:**
- Consumes: 所有前序任务

- [ ] **Step 1: 补本地化字符串**

`Sources/en.lproj/Localizable.strings` 追加（英文区 key=value 相同；沿用现有 `"key" = "value";` 格式，插入到文件按字母序合适位置或末尾，跟随现有条目风格）：

```
"General" = "General";
"Manage Types" = "Manage Types";
"Manage Types…" = "Manage Types…";
"New Type" = "New Type";
"Edit Type" = "Edit Type";
"Type Name" = "Type Name";
"No custom types yet." = "No custom types yet.";
"Delete type “%@”?" = "Delete type “%@”?";
"%d note(s) will revert to General." = "%d note(s) will revert to General.";
"All Types" = "All Types";
```

`Sources/zh-Hans.lproj/Localizable.strings` 追加：

```
"General" = "通用";
"Manage Types" = "管理类型";
"Manage Types…" = "管理类型…";
"New Type" = "新建类型";
"Edit Type" = "编辑类型";
"Type Name" = "类型名称";
"No custom types yet." = "还没有自定义类型。";
"Delete type “%@”?" = "删除类型“%@”？";
"%d note(s) will revert to General." = "%d 条笔记将改为通用。";
"All Types" = "全部类型";
```

注意：`"Done"`/`"Cancel"`/`"Save"`/`"Delete"` 已存在（zh 文件 line 25/35/69 等），不重复添加；若 en 文件缺 `"Done"` 则补 `"Done" = "Done";`。

- [ ] **Step 2: spike 全量回归**

Run: `cp spike/note-type-test.swift /tmp/nt_main.swift && swiftc Sources/Store/*.swift Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/nt_main.swift -o /tmp/nt && /tmp/nt`
Expected: `通过 16，失败 0`

顺带跑既有 store 回归确认无破坏：
Run: `cp spike/store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/st && /tmp/st`
Expected: 全 ✅

- [ ] **Step 3: 全量编译**

Run: `xcodegen generate && xcodebuild -project UniReader.xcodeproj -scheme UniReader -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: 手测清单（逐项过）**

1. 选一段文字 → 右键「添加批注」→ 编辑器右上角类型菜单选「管理类型…」→ 新建类型「错题」（红色 + 感叹号三角）→ 保存 → 选该类型保存批注 → 页面图钉变红色感叹号图标、选区高亮变红色调。
2. 再建一条通用批注 → 图钉保持既有黄色 note.text 样式。
3. 侧边栏「笔记」页：两条笔记分别显示色点+图标；筛选菜单选「错题」→ 只剩错题那条；选「全部类型」恢复。
4. 管理面板把「错题」改名/换色/换图标 → 已有笔记图钉与侧边栏立即跟随。
5. 管理面板删除「错题」→ 确认框提示 N 条回落 → 确认后该笔记图钉/条目回到通用样式。
6. 退出 App 重开同一工作区与文档 → 自定义类型仍在、笔记类型保留。
7. 新建工作区 → 类型列表为空、只有「通用」（工作区级隔离）。

- [ ] **Step 5: 更新 HISTORY.md**

按现有条目风格在 `HISTORY.md` 追加完成记录（特性一句话 + 关键机制：meta JSON 类型表 / payload type_id 零迁移 / 通用兜底 / 编辑器内管理 / 图钉侧边栏联动）。`TODO.md` 若有对应待办条目则移除。

- [ ] **Step 6: Commit（先经用户确认）**

```bash
git add Sources/en.lproj/Localizable.strings Sources/zh-Hans.lproj/Localizable.strings HISTORY.md TODO.md
git commit -m "feat: 笔记类型本地化与文档收尾"
```
