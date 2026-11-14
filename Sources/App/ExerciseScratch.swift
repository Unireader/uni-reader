import Combine
import Foundation

/// 题目草稿纸（`EXERCISE-PLAN.md §29`，用户 2026-11-14 定）：**一道题一张草稿纸**，随时能写、交卷后也能接着写，只跟着这道题。
///
/// - 存法：就是一篇画板（`board_note` + `board_item`），`id` = 题目 id、`group_name` = `LibraryStore.exerciseScratchGroup`；
///   画板列表 / 侧栏 / 统计都不算它（`LibraryStore.boards()` 按 `group_name` 滤掉）。离线镜像 / 服务器同步按画板两张表原样走。
/// - 运行时：一个**不进标签栏、不登记给平板跟随**的 `DocSession`，样子与画板标签一样（`board` = 这张、`scratchPads = [它]`、
///   `openPadID` = 它）。草稿纸那条链路（`ScratchPadNSView`、笔架、`AppModel+Scratch` 的落笔 / 擦除 / 框选 / 撤销、
///   平板 `scratchpads` / `scratchStrokes` / `ink` / `erase`）原样复用。
/// - 同一道题在 App 里只有一个会话（`acquire` 按「工作区 + 题目 id」共用、用完 `release`）：Mac 练习页和平板模式2
///   写的是同一份，两边实时看得见对方（平板开着习题页时，`AppModel.padScratchSession` 就是平板那道题的这个会话）。
/// - 第一笔落下才建 `board_note` 那一行（没写过的题不留空行）。以前手写小画板存在作答里的 `ink`（v21）：这道题还没有草稿纸时，
///   取最近一次带手写的作答换算成笔迹放上来（第一次写进库），作答里那份原样留着。
@MainActor
final class ExerciseScratchHost {
    let exerciseId: String
    let session = DocSession()
    private weak var workspace: WorkspaceManager?
    private weak var app: AppModel?
    private var uses = 1
    /// `board_note` 那一行已经在库里了（读出来的，或第一笔时建的）。
    private var rowSaved: Bool
    private var bag = Set<AnyCancellable>()

    var padID: UUID { session.board?.id ?? UUID() }
    var hasContent: Bool { !session.scratchStrokes.isEmpty || !session.boardImages.isEmpty }

    private static var live: [String: ExerciseScratchHost] = [:]
    private static func key(_ ws: WorkspaceManager, _ id: String) -> String {
        (ws.folder?.standardizedFileURL.path ?? "") + "|" + id.uppercased()
    }

    /// 取这道题的草稿纸会话（已经有人开着就共用那一个）。题目 id 不是 UUID → nil。用完必须 `release()`。
    static func acquire(exerciseId: String, workspace ws: WorkspaceManager, app: AppModel) -> ExerciseScratchHost? {
        guard ws.store != nil, let uuid = UUID(uuidString: exerciseId) else { return nil }
        let k = key(ws, exerciseId)
        if let h = live[k] { h.uses += 1; return h }
        let h = ExerciseScratchHost(exerciseId: exerciseId, uuid: uuid, workspace: ws, app: app)
        live[k] = h
        return h
    }

    /// 某个工作区里正开着的题目草稿纸（关工作区前结清用）。
    static func open(in ws: WorkspaceManager) -> [ExerciseScratchHost] {
        live.values.filter { $0.workspace === ws }
    }

    func release() {
        uses -= 1
        guard uses <= 0, let ws = workspace else { return }
        flush()
        ExerciseScratchHost.live[ExerciseScratchHost.key(ws, exerciseId)] = nil
        bag.removeAll()
    }

    private init(exerciseId: String, uuid: UUID, workspace ws: WorkspaceManager, app: AppModel) {
        self.exerciseId = exerciseId
        self.workspace = ws
        self.app = app
        let s = session
        s.store = ws.store
        s.workspaceFolder = ws.folder
        let saved = ws.board(id: uuid)
        rowSaved = saved != nil
        var b = saved ?? BoardNote(id: uuid, title: "", pattern: .grid,
                                   groupName: LibraryStore.exerciseScratchGroup, createdAt: .now, updatedAt: .now)
        b.groupName = LibraryStore.exerciseScratchGroup
        var (strokes, images) = saved == nil ? ([], []) : ws.boardContents(id: uuid)
        var seeded: [InkStroke] = []
        if saved == nil, let ink = Self.earlierInk(exerciseId, ws) {
            seeded = Self.strokes(from: ink, pad: uuid)
            strokes = seeded
        }
        // 对账快照先于数组赋值（同 `DocTabModel.loadBoard` 的纪律）
        s.persistedBoard = b
        s.persistedScratchPads = [b.id: b.asPad]
        s.persistedScratchStrokes = Dictionary(uniqueKeysWithValues: strokes.filter { st in !seeded.contains { $0.id == st.id } }
            .map { ($0.id, $0) })
        s.persistedBoardImages = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        s.board = b
        s.title = b.displayName
        s.scratchPads = [b.asPad]
        s.scratchStrokes = strokes
        s.boardImages = images
        s.openPadID = b.id
        bind()
        if !seeded.isEmpty { persist() }
    }

    private func on<P: Publisher>(_ pub: P, _ action: @escaping (ExerciseScratchHost) -> Void)
    where P.Output: Equatable, P.Failure == Never {
        // 同 `DocTabModel.on`：去重 → 丢首值 → 跳一拍（`@Published` 在 willSet 发，同步读到的是旧值）
        pub.removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { if let self { action(self) } } }
            .store(in: &bag)
    }

    private func bind() {
        on(session.$scratchPads) { h in
            h.persist()
            h.app?.broadcastScratchPads()
        }
        on(session.$scratchStrokes) { h in
            h.persist()
            h.app?.scratchStrokesChanged(in: h.session)
        }
        on(session.$boardImages) { h in
            h.persist()
            h.app?.broadcastBoardImages()
        }
    }

    /// 增量对账落库。第一次有内容时先建 `board_note` 那一行（`board_item` 外键要它）。
    func persist() {
        guard let ws = workspace, ws.store != nil else { return }
        if !rowSaved {
            guard hasContent, var b = session.board else { return }
            if let pad = session.scratchPads.first { b.absorb(pad) }
            b.updatedAt = .now
            ws.saveBoard(b)
            session.board = b
            session.persistedBoard = b
            rowSaved = true
        } else {
            session.persistBoardRow(ws)
        }
        session.persistBoardStrokes(ws)
        session.persistBoardImages(ws)
    }

    /// 关之前同步结清（正在写的那一笔不算）。
    func flush() { persist() }

    // MARK: - 出图（Agent 批改 / MCP `render_exercise_answer`）

    /// 这道题的草稿纸有没有写过东西（开着的按眼前的，否则看库）。
    static func hasContent(exerciseId: String, workspace ws: WorkspaceManager) -> Bool {
        if let h = live[key(ws, exerciseId)] { return h.hasContent }
        return ((try? ws.store?.boardItemCounts()) ?? [:])[exerciseId.uppercased()].map { $0 > 0 } ?? false
    }

    /// 这道题的草稿纸出 PNG（白纸黑字按纸色画，取写过的那一块加边）。开着的先落库。没写过 → nil。
    static func png(exerciseId: String, workspace ws: WorkspaceManager, pixelWidth: Int) -> (data: Data, width: Int, height: Int)? {
        guard let uuid = UUID(uuidString: exerciseId) else { return nil }
        live[key(ws, exerciseId)]?.flush()
        guard let b = ws.board(id: uuid) else { return nil }
        let (strokes, images) = ws.boardContents(id: uuid)
        guard let box = ScratchBounds.contentBounds(strokes, images: images) else { return nil }
        let widest = strokes.map { CGFloat($0.width) }.max() ?? 0
        let input = MCPBoardRender.Input(paper: b.bg, area: box.insetBy(dx: -(24 + widest), dy: -(24 + widest)), template: nil,
                                         strokes: strokes,
                                         images: images.map { ($0.rect, ws.imageInfo(sha256: $0.image)?.url) })
        return MCPBoardRender.render(input, pixelWidth: pixelWidth, format: .png)
    }

    // MARK: - 以前的手写（v21 `exercise_attempt.ink`）

    private static func earlierInk(_ id: String, _ ws: WorkspaceManager) -> ExerciseInk? {
        let rows = (try? ws.store?.exerciseAttempts(exerciseId: id)) ?? []
        return rows.sorted { $0.createdAt > $1.createdAt }.lazy.compactMap { ExerciseInk.decode($0.ink) }.first
    }

    /// 小画板的逻辑坐标（宽 600）原样当画布坐标：深色圆珠笔，宽度照旧。
    static func strokes(from ink: ExerciseInk, pad: UUID) -> [InkStroke] {
        let color = InkColor(r: 28, g: 28, b: 30, a: 1)
        return ink.strokes.compactMap { s in
            let pts = s.points.compactMap { p -> InkPoint? in
                guard p.count >= 2 else { return nil }
                return InkPoint(p[0], p[1], p.count >= 3 ? p[2] : 0.5)
            }
            guard !pts.isEmpty else { return nil }
            return InkStroke(page: 0, color: color, width: s.width, type: .ballpoint, points: pts, padId: pad)
        }
    }
}
