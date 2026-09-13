import Foundation

/// 一次可撤销编辑的**增量**：只存受影响的那几条，前后各一份。
///
/// 为什么是增量而不是整份快照：写满的文档动辄几千条笔迹、几十万个点，每压一步存整份
/// `[InkStroke]` 是几百 KB 起步（点集虽是 COW，但数组本身要复制、条数摆在那儿）。
/// 增量还有一半好处是**与落库对账天然同构**——`DocTabModel.persistInk` 也是按 id 比值快照，
/// 撤销把值改回去之后那边照常认得出「哪几条要 upsert、哪几条要 delete」，无需另开持久化路径。
struct InkPatch {

    /// 变更种类。合并（连续擦除并成一条）与菜单标题都看它。
    enum Kind: Equatable {
        case draw, erase, move, scale, paste, delete, note, other
    }

    /// 单条数据的前后值。`before == nil` = 新增；`after == nil` = 删除；两者都在 = 改。
    struct Change<T> {
        var before: T?
        var after: T?
        /// `before` 在原数组里的下标：撤销一次删除时按它**插回原位**（z 序不乱）。
        /// 新增项没有原位，填 `Int.max` = 落到末尾。
        var index: Int
    }

    /// 菜单里显示的动作名（`L()` 的 key，如 "Move"）。
    var label: String
    var kind: Kind
    /// 记账时刻（`CFAbsoluteTimeGetCurrent`）：连续擦除按它判要不要并进上一条。
    var at: CFAbsoluteTime
    var strokes: [UUID: Change<InkStroke>]
    var notes: [UUID: Change<TextNote>]
    /// 图片笔记（kind=6）。撤销一次删除把它加回来 = 引用回来，落库对账会把那张图从待删除里捞回。
    var images: [UUID: Change<ImageNote>] = [:]

    var isEmpty: Bool { strokes.isEmpty && notes.isEmpty && images.isEmpty }

    /// 把**更晚**的一次变更并进本条（连续擦除批次合成一步）：`before` 保留最早那份、
    /// `after` 换成最新那份 —— 复合之后这一条仍是「一步到位」的正确增量。
    mutating func merge(_ newer: InkPatch) {
        for (id, c) in newer.strokes {
            if var old = strokes[id] { old.after = c.after; strokes[id] = old } else { strokes[id] = c }
        }
        for (id, c) in newer.notes {
            if var old = notes[id] { old.after = c.after; notes[id] = old } else { notes[id] = c }
        }
        for (id, c) in newer.images {
            if var old = images[id] { old.after = c.after; images[id] = old } else { images[id] = c }
        }
        // 来回擦成原样的条目（before == after）留着只会让撤销白写一遍，清掉。
        strokes = strokes.filter { $0.value.before != $0.value.after }
        notes = notes.filter { $0.value.before != $0.value.after }
        images = images.filter { $0.value.before != $0.value.after }
        at = newer.at
    }
}

/// 值数组 ⇄ 增量的两个纯函数（`[InkStroke]` / `[TextNote]` 共用）。
///
/// 复杂度都是 O(条数)：`Array` 的 `==` 对**同一块 buffer** 有 O(1) 快路，而擦除/框选那些实现
/// 都是把没碰到的条目原样搬过去（点集 buffer 共享），所以逐条比值实际上只有被改动的那几条真比。
enum InkDelta {

    static func diff<T: Identifiable & Equatable>(_ before: [T], _ after: [T]) -> [UUID: InkPatch.Change<T>]
    where T.ID == UUID {
        var out: [UUID: InkPatch.Change<T>] = [:]
        var pos: [UUID: Int] = [:]
        pos.reserveCapacity(before.count)
        for (i, v) in before.enumerated() { pos[v.id] = i }
        var live = Set<UUID>()
        live.reserveCapacity(after.count)
        for v in after {
            live.insert(v.id)
            if let i = pos[v.id] {
                if before[i] != v { out[v.id] = .init(before: before[i], after: v, index: i) }
            } else {
                out[v.id] = .init(before: nil, after: v, index: Int.max)
            }
        }
        for (id, i) in pos where !live.contains(id) {
            out[id] = .init(before: before[i], after: nil, index: i)
        }
        return out
    }

    /// 把增量应用到数组：`undo == true` 走 `before` 那一侧，否则走 `after`。
    /// 三类各自处理——就地改值 / 删掉 / 插回原位（多条插入按原下标升序，落位才对）。
    static func apply<T: Identifiable & Equatable>(_ changes: [UUID: InkPatch.Change<T>],
                                                   to arr: inout [T], undo: Bool)
    where T.ID == UUID {
        guard !changes.isEmpty else { return }
        var pos: [UUID: Int] = [:]
        pos.reserveCapacity(arr.count)
        for (i, v) in arr.enumerated() { pos[v.id] = i }
        var gone = Set<UUID>()
        var inserts: [(index: Int, value: T)] = []
        for (id, c) in changes {
            let target = undo ? c.before : c.after
            if let i = pos[id] {
                if let target { arr[i] = target } else { gone.insert(id) }
            } else if let target {
                inserts.append((c.index, target))
            }
        }
        if !gone.isEmpty { arr.removeAll { gone.contains($0.id) } }
        for ins in inserts.sorted(by: { $0.index < $1.index }) {
            arr.insert(ins.value, at: min(max(0, ins.index), arr.count))
        }
    }
}

/// 一条编辑撤销栈（页内笔迹一份、草稿纸笔迹一份，见 `DocSession`）。**瞬态，不落库**：
/// 换文档/关标签即清空，与「文档里存了什么」无关。
///
/// 记账口径：所有会改 `strokes`/`textNotes`/`scratchStrokes` 的动作都从 `DocSession.inkEdit {}`
/// （或 `scratchEdit {}`）里走一遭，前后一比就是一条增量。唯独收笔那条最热的路径走
/// `recordAdded`（纯追加，免掉一次整表 diff）。
final class InkUndoStack {

    /// 栈深。够用即可——再深也只是让「很久以前那一步」可撤，代价是常驻内存。
    private let limit = 100
    /// 连续擦除并成一步的时间窗：同一次拖动里每 8ms 就来一批擦除点，一批一条撤销栈会当场爆。
    private let coalesceWindow: CFTimeInterval = 1.2

    private(set) var undos: [InkPatch] = []
    private(set) var redos: [InkPatch] = []
    /// 正在应用撤销/重做（防呆：此时若有人反手又调 record，那是逻辑错，直接忽略而不是记一笔脏账）。
    private var applying = false
    /// 已封口的合并组：抬笔时置，下一批擦除即另起一条（时间窗之外的兜底靠 `coalesceWindow`）。
    private var sealed = true

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }
    var undoLabel: String? { undos.last?.label }
    var redoLabel: String? { redos.last?.label }

    /// 两条栈里所有增量涉及的页（before/after 任一侧）。笔迹按页窗口装载后（`InkWindow`），
    /// 这些页**钉住不淘汰**：增量按下标插回原位，页不在内存里就无处可插。栈有上限，钉住的页有界。
    var referencedPages: Set<Int> {
        var out = Set<Int>()
        for patch in undos + redos {
            for c in patch.strokes.values {
                if let b = c.before { out.insert(b.page) }
                if let a = c.after { out.insert(a.page) }
            }
        }
        return out
    }

    func reset() {
        undos.removeAll(); redos.removeAll(); sealed = true
    }

    /// 一次拖动结束（抬笔/松手）：下一批同类变更不再并进上一条。
    func seal() { sealed = true }

    /// 记一次「前后两份值数组」的差。无差异 = 不记（调用方不必自己判断有没有改动）。
    func record(label: String, kind: InkPatch.Kind,
                strokesBefore: [InkStroke] = [], strokesAfter: [InkStroke] = [],
                notesBefore: [TextNote] = [], notesAfter: [TextNote] = [],
                imagesBefore: [ImageNote] = [], imagesAfter: [ImageNote] = []) {
        guard !applying else { return }
        let patch = InkPatch(label: label, kind: kind, at: CFAbsoluteTimeGetCurrent(),
                             strokes: InkDelta.diff(strokesBefore, strokesAfter),
                             notes: InkDelta.diff(notesBefore, notesAfter),
                             images: InkDelta.diff(imagesBefore, imagesAfter))
        push(patch)
    }

    /// 纯追加的快捷记账（收笔、粘贴）：省掉一次整表 diff。
    func recordAdded(label: String, kind: InkPatch.Kind, strokes: [InkStroke] = [], notes: [TextNote] = []) {
        guard !applying else { return }
        var patch = InkPatch(label: label, kind: kind, at: CFAbsoluteTimeGetCurrent(), strokes: [:], notes: [:])
        for st in strokes { patch.strokes[st.id] = .init(before: nil, after: st, index: Int.max) }
        for n in notes { patch.notes[n.id] = .init(before: nil, after: n, index: Int.max) }
        push(patch)
    }

    private func push(_ patch: InkPatch) {
        guard !patch.isEmpty else { return }
        // 连续擦除（同种类、没封口、在时间窗内）并进上一条：一次拖动 = 一步撤销。
        if patch.kind == .erase, !sealed, var last = undos.last, last.kind == .erase,
           patch.at - last.at <= coalesceWindow {
            last.merge(patch)
            if last.isEmpty { undos.removeLast() } else { undos[undos.count - 1] = last }
            redos.removeAll()
            return
        }
        undos.append(patch)
        sealed = patch.kind != .erase   // 擦除留着口子等后续批次并进来，其余动作各自成步
        if undos.count > limit { undos.removeFirst(undos.count - limit) }
        redos.removeAll()   // 新动作作废重做链（标准语义）
    }

    /// 取下一条待撤销/待重做的增量并移到对面栈。返回 nil = 无可撤销。
    /// 应用由调用方（`DocSession`）做——栈本身不认识数据放在哪儿。
    func pop(redo: Bool) -> InkPatch? {
        let patch = redo ? redos.popLast() : undos.popLast()
        guard let patch else { return nil }
        if redo { undos.append(patch) } else { redos.append(patch) }
        sealed = true
        return patch
    }

    /// 应用期间的记账屏蔽（`DocSession` 在应用增量时包住写数组那几行）。
    func whileApplying(_ body: () -> Void) {
        applying = true
        body()
        applying = false
    }
}
