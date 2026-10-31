import Foundation

/// 侧栏拖拽排出来的手动顺序（`SIDEBAR-DRAG-PLAN.md`，用户 2026-10-31 要求）。
///
/// - 书库的书：沿用 `document.sort_order`（`reorderDocuments`，右键「上移 / 下移」写的也是它）。
/// - 画板、练习库里的书、Markdown 笔记：库里没有现成的列（笔记的 `md_doc` 只覆盖内建 `Notes/`，引用的外部目录没有行），
///   各存一个 `meta` 键（JSON），跟着工作区同步（`MirrorFp.syncedMetaKeys`）。不升表结构，安卓不用跟。
/// - 排法一律：存过的按存的先后，没存过的（新加的）在最前（`SidebarOrder.apply`）。
extension WorkspaceManager {
    static let boardOrderKey = "board_order"
    static let exerciseOrderKey = "exercise_order"
    static let noteOrderKey = "note_order"

    private func metaJSON<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let s = store?.meta(key), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private func setMetaJSON<T: Encodable>(_ key: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value), let s = String(data: d, encoding: .utf8) else { return }
        do { try store?.setMeta(key, s) } catch { lastError = "\(error)" }
    }

    // MARK: 画板

    /// 画板的手动顺序（board id）。
    var boardOrder: [String] { metaJSON(Self.boardOrderKey, as: [String].self) ?? [] }

    /// 侧栏拖完：存下整组的新顺序，重排 `boards`（侧栏、平板的画板列表都跟着它）。
    func setBoardOrder(_ ids: [UUID]) {
        setMetaJSON(Self.boardOrderKey, ids.map(\.uuidString))
        refreshBoards()
    }

    // MARK: 习题那一段

    /// 习题那一段顶层各行的手动顺序（`ExerciseScope.key`：`all` / `wrong` / `starred` / `doc:<id>`）。没拖过 = 空。
    /// 2026-10-31 开发包里存过一版只有 document id 的（那时只有书能拖），读的时候当成 `doc:<id>`。
    var exerciseOrder: [String] {
        (metaJSON(Self.exerciseOrderKey, as: [String].self) ?? []).map { k in
            ["all", "wrong", "starred"].contains(k) || k.contains(":") ? k : ExerciseScope.document(k).key
        }
    }

    /// 书的先后（错题本 / 收藏底下的书也按它）：拖过的按拖的，没拖过的在最前、按书库顺序。
    var exerciseBooks: [(id: String, title: String)] {
        let prefix = ExerciseScope.document("").key   // "doc:"
        let ids = exerciseOrder.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        return SidebarOrder.apply(documents, order: ids, id: \.id).map { ($0.id, $0.title) }
    }

    /// 侧栏「习题」那一段（平板抽屉 `exGroups`、⌘P 用同一份）：`ExerciseGroupNode.build` 建好，顶层各行按手动顺序排。
    func exerciseGroups() -> [ExerciseGroupNode] {
        let rows = ExerciseGroupNode.build(exerciseSummary, documents: exerciseBooks, title: exerciseScopeTitle,
                                           noChapter: L("No Chapter"))
        return SidebarOrder.apply(rows, order: exerciseOrder, id: \.scope.key)
    }

    /// 侧栏拖完：存下顶层各行的新顺序。侧栏靠 `objectWillChange` 重建；平板抽屉经 `.exercisesDidChange` 重发分组
    /// （不加 `exerciseRevision`：题目没变，开着的习题标签不用重读）。
    func setExerciseOrder(_ keys: [String]) {
        setMetaJSON(Self.exerciseOrderKey, keys)
        objectWillChange.send()
        NotificationCenter.default.post(name: .exercisesDidChange, object: self)
    }

    // MARK: Markdown 笔记

    /// 笔记的手动顺序：源 id → 目录（源内相对路径，根 = ""）→ 笔记的源内相对路径。
    var noteOrder: [String: [String: [String]]] { metaJSON(Self.noteOrderKey, as: [String: [String: [String]]].self) ?? [:] }

    /// 侧栏拖完：存下这一个目录里笔记的新顺序，重建笔记树。
    func setNoteOrder(source: String, folder: String, relPaths: [String]) {
        var all = noteOrder
        all[source, default: [:]][folder] = relPaths
        setMetaJSON(Self.noteOrderKey, all)
        refreshNotes()
    }
}

extension NoteFolder {
    /// 按侧栏拖出来的顺序排笔记（`order` = 目录相对路径 → 笔记相对路径）。存过的按存的，没存过的在最前、仍按名字；
    /// 子目录不动（照旧按名字、在笔记前面）。
    func applyNoteOrder(_ order: [String: [String]]) {
        if let o = order[path], !o.isEmpty { reorderNotes { SidebarOrder.apply($0, order: o, id: \.ref.relPath) } }
        for f in folders { f.applyNoteOrder(order) }
    }
}
