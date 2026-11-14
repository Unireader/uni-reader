import Foundation

/// 工作区统计（MCP `workspace_stats`，`MCP-PLAN.md §38`）：各种数量一律在 SQL 里 COUNT / SUM / GROUP BY 出来，
/// **不读正文、不读 payload、不把整张表搬进内存**——原先 Agent 为了数个数，得把整份清单读一遍
/// （`list_exercises`、`list_annotations`、`read_conversation`…）。
///
/// 定位同 `TrashStore`：静态函数拿 `SQLiteDB`，入口只有 `LibraryStore.stats(_:)` 一个（连接不出那个类）。
/// 🔴 本文件经符号链接也编进 Linux 服务器（`server/Sources/UniServerCore/Store`）：只许 Foundation，不碰 App 层类型。
///
/// 时间口径：库里的时间戳是 ISO 8601（多半是 UTC 的 `…Z`，别端写的可能不带毫秒）；「哪一天」一律按调用方给的时区
/// 换成本地日历日。做法：先在 Swift 里算出每个本地日在 UTC 下的起止秒（夏令时那天不是 24 小时也对），
/// 再在 SQL 里把 `strftime('%s', 时间戳)` 落进对应区间——不靠字符串比较，不同写法的时间戳也不会归错天。
/// 日程的 `day` 列本来就是本地日历日（'YYYY-MM-DD'），直接比字符串。
enum StatsStore {

    /// 统计分几块；`markdown` 由 App 层数（正文在磁盘上，清单在 `WorkspaceManager`），这里不管。
    enum Section: String, CaseIterable {
        case library, annotations, markdown, boards, exercises, practice, agent, schedule
    }

    struct Query {
        var sections: Set<Section> = Set(Section.allCases)
        /// 只数这一篇文档（书库 / 批注 / 习题 / 练习四块）；nil = 整个工作区。
        var documentId: String? = nil
        /// 按天细分的范围（本地日历日 'YYYY-MM-DD'，两头都含）。
        var from: String
        var to: String
        /// 今天（本地日历日），日程的「逾期 / 今天」按它算。
        var today: String
        var timeZone: TimeZone = .current
        /// 每张细分清单（按文档 / 章节 / 标签 / 计划）最多几行。
        var limit: Int = 20
    }

    // MARK: - 结果

    struct Report {
        var library: Library?
        var annotations: Annotations?
        var boards: Boards?
        var exercises: Exercises?
        var practice: Practice?
        var agent: Agent?
        var schedule: Schedule?
    }

    struct Library: Equatable {
        var documents = 0
        var pages = 0
        var started = 0
        var finished = 0
        var byDocument: [DocProgress] = []
        var byDocumentOmitted = 0
        var notStarted: Int { documents - started }
    }

    /// 一篇文档的阅读进度。`readPage` 0 起 = 上次视口顶部所在页，`readFrac` = 页内比例（`document.read_page / read_frac`）。
    struct DocProgress: Equatable {
        var id: String
        var title: String
        var pageCount: Int
        var readPage: Int
        var readFrac: Double
        var lastOpenedAt: String
        /// 读过 = 进度离开了第一页顶端。🔴 与 `library()` 里的 SQL 同一口径。
        var started: Bool { readPage > 0 || readFrac > 0 }
        /// 读完 = 读过且视口顶部到了最后一页。
        var finished: Bool { pageCount > 0 && started && readPage >= pageCount - 1 }
        /// 读到第几页占全书的百分比（当前页算读到；没读过 = 0）。
        var progress: Int {
            guard pageCount > 0, started else { return 0 }
            return min(100, Int((Double(readPage + 1) / Double(pageCount) * 100).rounded()))
        }
    }

    /// `note` 表按 kind 数（与 `TrashStore.Counts` 同一套 kind：0 文字笔记 / 1 AI 会话 / 2 页内笔迹 / 3 高亮 /
    /// 4 草稿纸笔迹 / 5 书签 / 6 图片笔记）。
    struct KindCounts: Equatable {
        var text = 0
        var aiThreads = 0
        var ink = 0
        var highlights = 0
        var scratchInk = 0
        var bookmarks = 0
        var images = 0

        mutating func add(kind: Int, _ n: Int) {
            switch kind {
            case 0: text += n
            case 1: aiThreads += n
            case 2: ink += n
            case 3: highlights += n
            case 4: scratchInk += n
            case 5: bookmarks += n
            case 6: images += n
            default: break
            }
        }
        /// 一条一条的批注（不含笔迹：笔迹是一笔一行，动辄上千，混在一起没意义）。
        var annotations: Int { text + aiThreads + highlights + bookmarks + images }
    }

    struct Annotations: Equatable {
        var counts = KindCounts()
        /// 有页内笔迹的页数（各文档加起来）。
        var pagesWithInk = 0
        var scratchPads = 0
        var byDocument: [DocAnnotations] = []
        var byDocumentOmitted = 0
    }

    struct DocAnnotations: Equatable {
        var id: String
        var title: String
        var counts = KindCounts()
        var pagesWithInk = 0
    }

    struct Boards: Equatable {
        var boards = 0
        /// 分页模式的画板（有 `board_page` 行的）。
        var pagedBoards = 0
        var pages = 0
        var inkItems = 0
        var imageItems = 0
    }

    struct Exercises: Equatable {
        var total = 0
        var single = 0, multiple = 0, fill = 0, subjective = 0, otherKinds = 0
        var starred = 0
        var inMistakes = 0
        var withNote = 0
        var untagged = 0
        /// 做过（至少一次作答，含书上的作答）= `exerciseDoneCounts` 的口径。
        var answered = 0
        /// 最近一次作答的结论：对 / 错 / 还没判。
        var lastCorrect = 0, lastWrong = 0, lastUngraded = 0
        var attempts = 0
        /// 等着判的作答：填空 / 主观题里 `correct IS NULL` 的（= `list_exercise_attempts ungraded_only` 的口径）。
        var awaitingGrading = 0
        var byDocument: [ExerciseGroup] = []
        var byDocumentOmitted = 0
        var byChapter: [ExerciseGroup] = []
        var byChapterOmitted = 0
        var byTag: [ExerciseGroup] = []
        var byTagOmitted = 0
        var neverAnswered: Int { total - answered }
    }

    /// 一组题（按文档 / 章节 / 标签）。用不上的字段留空。
    struct ExerciseGroup: Equatable {
        var documentId = ""
        var title = ""
        var chapter: [String] = []
        var tag = ""
        var total = 0
        var answered = 0
        var inMistakes = 0
        var starred = 0
    }

    struct Practice: Equatable {
        var attempts = 0, correct = 0, wrong = 0, ungraded = 0
        /// 练过的题（去重）。
        var exercises = 0
        var elapsedMs = 0
        /// 有作答的那些天（没作答的天不列）。
        var byDay: [PracticeDay] = []
    }

    struct PracticeDay: Equatable {
        var day: String
        var attempts = 0, correct = 0, wrong = 0, ungraded = 0
        var exercises = 0
        var elapsedMs = 0
    }

    struct Agent: Equatable {
        var memories = 0, contexts = 0, conversations = 0, turns = 0
    }

    struct Schedule: Equatable {
        var plans = 0
        var items = 0, done = 0, open = 0
        /// 没做完、日期早于今天的。
        var overdue = 0
        /// 没做完、还没排日期的。
        var undated = 0
        var todayItems = 0, todayDone = 0
        var byPlan: [PlanCount] = []
        var byPlanOmitted = 0
        /// 范围内有事的那些天：排在那天的几件、其中做完几件、那天做完了几件（按 `done_at` 的本地日）。
        var byDay: [ScheduleDay] = []
    }

    struct PlanCount: Equatable {
        var id: String
        var title: String
        var items = 0, done = 0, overdue = 0
    }

    struct ScheduleDay: Equatable {
        var day: String
        var items = 0, done = 0, completed = 0
    }

    // MARK: - 入口

    static func collect(_ db: SQLiteDB, _ q: Query) throws -> Report {
        var r = Report()
        let limit = max(1, q.limit)
        let doc = q.documentId.flatMap { $0.isEmpty ? nil : $0 }
        let needDays = q.sections.contains(.practice) || q.sections.contains(.schedule)
        let range = needDays ? (days(from: q.from, to: q.to, in: q.timeZone) ?? []) : []
        if q.sections.contains(.library) { r.library = try library(db, doc: doc, limit: limit) }
        if q.sections.contains(.annotations) { r.annotations = try annotations(db, doc: doc, limit: limit) }
        if q.sections.contains(.boards) { r.boards = try boards(db) }
        if q.sections.contains(.exercises) { r.exercises = try exercises(db, doc: doc, limit: limit) }
        if q.sections.contains(.practice) { r.practice = try practice(db, doc: doc, days: range) }
        if q.sections.contains(.agent) { r.agent = try agent(db) }
        if q.sections.contains(.schedule) { r.schedule = try schedule(db, today: q.today, days: range, limit: limit) }
        return r
    }

    // MARK: - 本地日

    /// 一个本地日在 UTC 下的起止（秒，左闭右开）。
    struct Day: Equatable {
        var day: String
        var lo: Int64
        var hi: Int64
    }

    /// 按天细分最多跨多少天。
    static let maxRangeDays = 366

    private static func calendar(_ tz: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal
    }

    /// 某一刻在 [tz] 里是哪一天（'YYYY-MM-DD'）。
    static func dayString(_ date: Date, in tz: TimeZone) -> String {
        let c = calendar(tz).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 'YYYY-MM-DD' 那天的正午（拿正午做锚：凌晨换夏令时的时区里 00:00 可能不存在）。写法不对 / 日期不存在 → nil。
    static func noon(_ day: String, in tz: TimeZone) -> Date? {
        let b = Array(day.utf8)
        guard b.count == 10, b[4] == 0x2D, b[7] == 0x2D else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                let c = Int(b[i]) - 48
                guard c >= 0, c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(0..<4), let m = num(5..<7), let d = num(8..<10), (1...12).contains(m), (1...31).contains(d),
              let date = calendar(tz).date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              dayString(date, in: tz) == day     // 2 月 30 日这类会被日历顺延，对不上就是不存在
        else { return nil }
        return date
    }

    /// [day] 前后挪 [n] 天。
    static func shift(_ day: String, by n: Int, in tz: TimeZone) -> String? {
        guard let d = noon(day, in: tz), let s = calendar(tz).date(byAdding: .day, value: n, to: d) else { return nil }
        return dayString(s, in: tz)
    }

    /// [from]…[to] 每一天（两头都含）。写法不对、from 晚于 to、超过 `maxRangeDays` 天 → nil。
    static func days(from: String, to: String, in tz: TimeZone) -> [Day]? {
        let cal = calendar(tz)
        guard var cur = noon(from, in: tz), let end = noon(to, in: tz), cur <= end else { return nil }
        var out: [Day] = []
        while cur <= end {
            guard out.count < maxRangeDays, let next = cal.date(byAdding: .day, value: 1, to: cur) else { return nil }
            out.append(Day(day: dayString(cur, in: tz),
                           lo: Int64(cal.startOfDay(for: cur).timeIntervalSince1970.rounded(.down)),
                           hi: Int64(cal.startOfDay(for: next).timeIntervalSince1970.rounded(.down))))
            cur = next
        }
        return out
    }

    /// `WITH days(day, lo, hi) AS (VALUES …)` 和它的参数。
    private static func daysCTE(_ days: [Day]) -> (sql: String, args: [SQLiteDB.Value]) {
        let values = Array(repeating: "(?,?,?)", count: days.count).joined(separator: ",")
        return ("days(day, lo, hi) AS (VALUES \(values))",
                days.flatMap { [SQLiteDB.Value.text($0.day), .int($0.lo), .int($0.hi)] })
    }

    /// 时间戳列 → UTC 秒（解析不了 = NULL，落不进任何一天）。
    private static func seconds(_ column: String) -> String { "CAST(strftime('%s', \(column)) AS INTEGER)" }

    // MARK: - 小工具

    /// 一行 [n] 个整数（SUM 在零行上是 NULL，读出来是 0）。
    private static func ints(_ db: SQLiteDB, _ sql: String, _ args: [SQLiteDB.Value] = [], _ n: Int32) throws -> [Int] {
        try db.query(sql, args) { row in (0..<n).map { Int(row.int64($0)) } }.first
            ?? Array(repeating: 0, count: Int(n))
    }

    private static func docArgs(_ doc: String?) -> [SQLiteDB.Value] { doc.map { [.text($0)] } ?? [] }

    // MARK: - 书库

    private static func library(_ db: SQLiteDB, doc: String?, limit: Int) throws -> Library {
        let w = doc == nil ? "" : " WHERE id=?"
        let started = "(read_page > 0 OR read_frac > 0)"
        let t = try ints(db, """
        SELECT COUNT(*), SUM(page_count), SUM(\(started)),
               SUM(page_count > 0 AND \(started) AND read_page >= page_count - 1)
        FROM document\(w)
        """, docArgs(doc), 4)
        let rows = try db.query("""
        SELECT id, title, page_count, read_page, read_frac, last_opened_at FROM document\(w)
        ORDER BY last_opened_at DESC, title LIMIT ?
        """, docArgs(doc) + [.int(Int64(limit))]) { r in
            DocProgress(id: r.text(0), title: r.text(1), pageCount: Int(r.int64(2)), readPage: Int(r.int64(3)),
                        readFrac: r.double(4), lastOpenedAt: r.text(5))
        }
        return Library(documents: t[0], pages: t[1], started: t[2], finished: t[3],
                       byDocument: rows, byDocumentOmitted: max(0, t[0] - rows.count))
    }

    // MARK: - 批注

    private static func annotations(_ db: SQLiteDB, doc: String?, limit: Int) throws -> Annotations {
        let w = doc == nil ? "" : " WHERE n.document_id=?"
        var out = Annotations()
        var perDoc: [String: DocAnnotations] = [:]
        // 按 (文档, kind) 一条 GROUP BY：行数 ≤ 文档数 × 7
        for (id, title, kind, n) in try db.query("""
        SELECT n.document_id, COALESCE(d.title, ''), n.kind, COUNT(*) FROM note n
        LEFT JOIN document d ON d.id = n.document_id\(w) GROUP BY n.document_id, n.kind
        """, docArgs(doc), row: { r in (r.text(0), r.text(1), Int(r.int64(2)), Int(r.int64(3))) }) {
            out.counts.add(kind: kind, n)
            perDoc[id, default: DocAnnotations(id: id, title: title)].counts.add(kind: kind, n)
        }
        let inkW = doc == nil ? "" : " AND document_id=?"
        for (id, pages) in try db.query("""
        SELECT document_id, COUNT(DISTINCT page) FROM note WHERE kind = 2\(inkW) GROUP BY document_id
        """, docArgs(doc), row: { r in (r.text(0), Int(r.int64(1))) }) {
            out.pagesWithInk += pages
            perDoc[id]?.pagesWithInk = pages
        }
        out.scratchPads = try ints(db, "SELECT COUNT(*) FROM scratch_pad" + (doc == nil ? "" : " WHERE document_id=?"),
                                   docArgs(doc), 1)[0]
        // 一条一条的批注多的在前，再按笔迹
        let sorted = perDoc.values.sorted {
            ($0.counts.annotations, $0.counts.ink + $0.counts.scratchInk, $1.title)
                > ($1.counts.annotations, $1.counts.ink + $1.counts.scratchInk, $0.title)
        }
        out.byDocument = Array(sorted.prefix(limit))
        out.byDocumentOmitted = sorted.count - out.byDocument.count
        return out
    }

    // MARK: - 画板

    private static func boards(_ db: SQLiteDB) throws -> Boards {
        let t = try ints(db, """
        SELECT (SELECT COUNT(*) FROM board_note WHERE group_name <> ?1), (SELECT COUNT(DISTINCT board_id) FROM board_page),
               (SELECT COUNT(*) FROM board_page),
               (SELECT COUNT(*) FROM board_item WHERE kind = 1 AND board_id NOT IN (SELECT id FROM board_note WHERE group_name = ?1)),
               (SELECT COUNT(*) FROM board_item WHERE kind = 2 AND board_id NOT IN (SELECT id FROM board_note WHERE group_name = ?1))
        """, [.text(LibraryStore.exerciseScratchGroup)], 5)
        return Boards(boards: t[0], pagedBoards: t[1], pages: t[2], inkItems: t[3], imageItems: t[4])
    }

    // MARK: - 习题

    /// 「这道题做过」：至少一条作答（含书上的作答）。
    private static let answered = "EXISTS (SELECT 1 FROM exercise_attempt a WHERE a.exercise_id = e.id)"

    private static func exercises(_ db: SQLiteDB, doc: String?, limit: Int) throws -> Exercises {
        var out = Exercises()
        let w = doc == nil ? "" : " WHERE e.document_id=?"
        let a = docArgs(doc)
        // 按题型：总数 / 收藏 / 错题本 / 有笔记 / 没标签（空串、`[]`、不是合法 JSON 的都算没标签，同下面按标签那条）
        for (kind, n, s, wr, note, untagged) in try db.query("""
        SELECT e.kind, COUNT(*), SUM(e.starred), SUM(e.wrong), SUM(e.note <> ''),
               SUM((CASE WHEN json_valid(e.tags) THEN json_array_length(e.tags) ELSE 0 END) = 0)
        FROM exercise e\(w) GROUP BY e.kind
        """, a, row: { r in (Int(r.int64(0)), Int(r.int64(1)), Int(r.int64(2)), Int(r.int64(3)), Int(r.int64(4)),
                              Int(r.int64(5))) }) {
            out.total += n; out.starred += s; out.inMistakes += wr; out.withNote += note; out.untagged += untagged
            switch kind {
            case 0: out.single += n
            case 1: out.multiple += n
            case 3: out.fill += n
            case 4: out.subjective += n
            default: out.otherKinds += n
            }
        }
        // 每道题最近一次作答（按时间戳解析后的先后，同一刻按 id）：行数 = 做过的题数
        let last = try ints(db, """
        SELECT COUNT(*), SUM(l.correct = 1), SUM(l.correct = 0), SUM(l.correct IS NULL) FROM (
          SELECT a.correct, ROW_NUMBER() OVER (PARTITION BY a.exercise_id
                                               ORDER BY julianday(a.created_at) DESC, a.id DESC) AS rn
          FROM exercise_attempt a JOIN exercise e ON e.id = a.exercise_id\(w)
        ) l WHERE l.rn = 1
        """, a, 4)
        out.answered = last[0]; out.lastCorrect = last[1]; out.lastWrong = last[2]; out.lastUngraded = last[3]
        let att = try ints(db, """
        SELECT COUNT(*), SUM(a.correct IS NULL AND e.kind IN (3,4))
        FROM exercise_attempt a JOIN exercise e ON e.id = a.exercise_id\(w)
        """, a, 2)
        out.attempts = att[0]; out.awaitingGrading = att[1]

        // 按文档（题多的在前）
        let docW = doc == nil ? " WHERE e.document_id IS NOT NULL" : w
        out.byDocument = try db.query("""
        SELECT e.document_id, COALESCE(d.title, ''), COUNT(*), SUM(\(answered)), SUM(e.wrong), SUM(e.starred)
        FROM exercise e LEFT JOIN document d ON d.id = e.document_id\(docW)
        GROUP BY e.document_id ORDER BY COUNT(*) DESC, COALESCE(d.title, '') LIMIT ?
        """, a + [.int(Int64(limit))]) { r in
            ExerciseGroup(documentId: r.text(0), title: r.text(1), total: Int(r.int64(2)), answered: Int(r.int64(3)),
                          inMistakes: Int(r.int64(4)), starred: Int(r.int64(5)))
        }
        let docGroups = try ints(db, "SELECT COUNT(DISTINCT e.document_id) FROM exercise e\(docW)", a, 1)[0]
        out.byDocumentOmitted = max(0, docGroups - out.byDocument.count)

        // 按章节（同侧栏章节树：文档 → 章节 = 最深那一级路径；按书名、再按最早那页排）
        out.byChapter = try db.query("""
        SELECT e.document_id, COALESCE(d.title, ''), e.chapter, COUNT(*), SUM(\(answered)), SUM(e.wrong), SUM(e.starred)
        FROM exercise e LEFT JOIN document d ON d.id = e.document_id\(docW)
        GROUP BY e.document_id, e.chapter
        ORDER BY COALESCE(d.title, ''), e.document_id, MIN(e.page) IS NULL, MIN(e.page), e.chapter LIMIT ?
        """, a + [.int(Int64(limit))]) { r in
            ExerciseGroup(documentId: r.text(0), title: r.text(1), chapter: LibraryStore.chapterPath(r.text(2)),
                          total: Int(r.int64(3)), answered: Int(r.int64(4)), inMistakes: Int(r.int64(5)),
                          starred: Int(r.int64(6)))
        }
        let chapterGroups = try ints(db, """
        SELECT COUNT(*) FROM (SELECT 1 FROM exercise e\(docW) GROUP BY e.document_id, e.chapter)
        """, a, 1)[0]
        out.byChapterOmitted = max(0, chapterGroups - out.byChapter.count)

        // 按标签：tags 是 JSON 字符串数组，json_each 摊开后按不分大小写分组（同 `ExerciseTag` 的去重口径）。
        // 不是合法数组的行当没标签（json_each 遇到坏 JSON 会让整条查询报错）。
        let tagW = (doc == nil ? " WHERE" : w + " AND") + " e.tags <> ''"
        let tagged = """
        FROM exercise e, json_each(CASE WHEN json_valid(e.tags)
                                        THEN CASE WHEN json_type(e.tags) = 'array' THEN e.tags ELSE '[]' END
                                        ELSE '[]' END) j\(tagW)
        """
        out.byTag = try db.query("""
        SELECT MIN(j.value), COUNT(DISTINCT e.id), SUM(\(answered)), SUM(e.wrong), SUM(e.starred) \(tagged)
        GROUP BY lower(j.value) ORDER BY COUNT(DISTINCT e.id) DESC, MIN(j.value) LIMIT ?
        """, a + [.int(Int64(limit))]) { r in
            ExerciseGroup(tag: r.text(0), total: Int(r.int64(1)), answered: Int(r.int64(2)), inMistakes: Int(r.int64(3)),
                          starred: Int(r.int64(4)))
        }
        let tagGroups = try ints(db, "SELECT COUNT(DISTINCT lower(j.value)) \(tagged)", a, 1)[0]
        out.byTagOmitted = max(0, tagGroups - out.byTag.count)
        return out
    }

    // MARK: - 练习（按天）

    /// 只数在 App 里练的作答：书上的作答（`source = mark`）是 Agent 导入时认出来的，时间是导入那一刻，不算练习。
    private static func practice(_ db: SQLiteDB, doc: String?, days: [Day]) throws -> Practice {
        guard let first = days.first, let last = days.last else { return Practice() }
        let join = doc == nil ? "" : " JOIN exercise e ON e.id = a.exercise_id AND e.document_id = ?"
        let t = seconds("a.created_at")
        // MATERIALIZED：先把范围内的作答连同解析好的秒数算一遍存起来，后面按天对区间时不再逐行重算 strftime
        let x = """
        x AS MATERIALIZED (
          SELECT \(t) AS t, a.correct AS c, a.elapsed_ms AS ms, a.exercise_id AS ex
          FROM exercise_attempt a\(join) WHERE a.source <> ? AND \(t) >= ? AND \(t) < ?
        )
        """
        let xArgs = docArgs(doc) + [.text(LibExerciseAttempt.markSource), .int(first.lo), .int(last.hi)]
        var out = Practice()
        let tot = try ints(db, """
        WITH \(x) SELECT COUNT(*), SUM(c = 1), SUM(c = 0), SUM(c IS NULL), COUNT(DISTINCT ex), SUM(ms) FROM x
        """, xArgs, 6)
        out.attempts = tot[0]; out.correct = tot[1]; out.wrong = tot[2]; out.ungraded = tot[3]
        out.exercises = tot[4]; out.elapsedMs = tot[5]
        guard out.attempts > 0 else { return out }
        let cte = daysCTE(days)
        out.byDay = try db.query("""
        WITH \(cte.sql), \(x)
        SELECT d.day, COUNT(*), SUM(x.c = 1), SUM(x.c = 0), SUM(x.c IS NULL), COUNT(DISTINCT x.ex), SUM(x.ms)
        FROM x JOIN days d ON x.t >= d.lo AND x.t < d.hi GROUP BY d.day ORDER BY d.day
        """, cte.args + xArgs) { r in
            PracticeDay(day: r.text(0), attempts: Int(r.int64(1)), correct: Int(r.int64(2)), wrong: Int(r.int64(3)),
                        ungraded: Int(r.int64(4)), exercises: Int(r.int64(5)), elapsedMs: Int(r.int64(6)))
        }
        return out
    }

    // MARK: - Agent

    private static func agent(_ db: SQLiteDB) throws -> Agent {
        let t = try ints(db, """
        SELECT (SELECT COUNT(*) FROM agent_memory), (SELECT COUNT(*) FROM agent_context),
               (SELECT COUNT(DISTINCT conversation_id) FROM agent_turn), (SELECT COUNT(*) FROM agent_turn)
        """, [], 4)
        return Agent(memories: t[0], contexts: t[1], conversations: t[2], turns: t[3])
    }

    // MARK: - 日程

    private static func schedule(_ db: SQLiteDB, today: String, days: [Day], limit: Int) throws -> Schedule {
        var out = Schedule()
        let day = SQLiteDB.Value.text(today)
        let overdue = "day <> '' AND day < ? AND done_at = ''"     // 同 `LibraryStore` 列逾期事项的条件
        let t = try ints(db, """
        SELECT COUNT(*), SUM(done_at <> ''), SUM(done_at = ''), SUM(\(overdue)), SUM(day = '' AND done_at = ''),
               SUM(day = ?), SUM(day = ? AND done_at <> '')
        FROM schedule_item
        """, [day, day, day], 7)
        out.items = t[0]; out.done = t[1]; out.open = t[2]; out.overdue = t[3]; out.undated = t[4]
        out.todayItems = t[5]; out.todayDone = t[6]
        out.plans = try ints(db, "SELECT COUNT(*) FROM schedule_plan", [], 1)[0]
        out.byPlan = try db.query("""
        SELECT p.id, p.title, COUNT(i.id), SUM(i.done_at <> ''), SUM(i.day <> '' AND i.day < ? AND i.done_at = '')
        FROM schedule_plan p LEFT JOIN schedule_item i ON i.plan_id = p.id
        GROUP BY p.id ORDER BY p.created_at DESC, p.id LIMIT ?
        """, [day, .int(Int64(limit))]) { r in
            PlanCount(id: r.text(0), title: r.text(1), items: Int(r.int64(2)), done: Int(r.int64(3)),
                      overdue: Int(r.int64(4)))
        }
        out.byPlanOmitted = max(0, out.plans - out.byPlan.count)

        guard let first = days.first, let last = days.last else { return out }
        var byDay: [String: ScheduleDay] = [:]
        // 排在那天的（day 列就是本地日）
        for (d, n, done) in try db.query("""
        SELECT day, COUNT(*), SUM(done_at <> '') FROM schedule_item WHERE day <> '' AND day >= ? AND day <= ? GROUP BY day
        """, [.text(first.day), .text(last.day)], row: { r in (r.text(0), Int(r.int64(1)), Int(r.int64(2))) }) {
            byDay[d, default: ScheduleDay(day: d)].items = n
            byDay[d, default: ScheduleDay(day: d)].done = done
        }
        // 那天做完的（done_at 换成本地日）
        let cte = daysCTE(days)
        let t2 = seconds("done_at")
        for (d, n) in try db.query("""
        WITH \(cte.sql), x AS MATERIALIZED (
          SELECT \(t2) AS t FROM schedule_item WHERE done_at <> '' AND \(t2) >= ? AND \(t2) < ?
        )
        SELECT d.day, COUNT(*) FROM x JOIN days d ON x.t >= d.lo AND x.t < d.hi GROUP BY d.day
        """, cte.args + [.int(first.lo), .int(last.hi)], row: { r in (r.text(0), Int(r.int64(1))) }) {
            byDay[d, default: ScheduleDay(day: d)].completed = n
        }
        out.byDay = byDay.values.sorted { $0.day < $1.day }
        return out
    }
}
