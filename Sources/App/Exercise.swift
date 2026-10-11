import Foundation

/// 习题的纯逻辑（`EXERCISE-PLAN.md`）：payload 编解码、导入校验与规整、去重、判题、标签范围。
/// **只依赖 Foundation**——`spike/exercise-test.swift` 把它和 `Sources/Store/*` 一起直接编。

/// 题型（`exercise.kind`）。本轮只有选择题两种，以后的判断 / 填空 / 解答接着往后排。
enum ExerciseKind: Int, CaseIterable {
    case single = 0
    case multiple = 1

    /// MCP 里的写法（对模型最不容易写错的英文词）。
    var wireName: String {
        switch self {
        case .single: return "single"
        case .multiple: return "multiple"
        }
    }
    init?(wire: String) {
        switch wire.trimmingCharacters(in: .whitespaces).lowercased() {
        case "single": self = .single
        case "multiple": self = .multiple
        default: return nil
        }
    }
}

/// 答案从哪来：书上印的，还是 Agent 自己解的（后者练习时要明说「未经核对」）。
enum ExerciseAnswerSource: String {
    case book
    case agent
}

struct ExerciseOption: Codable, Equatable {
    var key: String
    var text: String
}

/// `exercise.payload` 的 JSON（键 snake_case；新键一律可选、`decodeIfPresent`，老行不迁移）。
struct ExercisePayload: Codable, Equatable {
    var stem: String
    var options: [ExerciseOption]
    /// 正确选项的键（空 = 还没有答案）。
    var answer: [String]
    /// `book` / `agent`；没有答案时为 nil。
    var answerSource: String?
    var explanation: String?
    /// 题目在页上的框 `[x, y, w, h]`（归一化 0~1、左上原点）。
    var region: [Double]?
    /// 带图 / 表：练习时默认显示原题截图。
    var figure: Bool

    init(stem: String, options: [ExerciseOption], answer: [String] = [], answerSource: String? = nil,
         explanation: String? = nil, region: [Double]? = nil, figure: Bool = false) {
        self.stem = stem; self.options = options; self.answer = answer; self.answerSource = answerSource
        self.explanation = explanation; self.region = region; self.figure = figure
    }

    enum CodingKeys: String, CodingKey {
        case stem, options, answer, explanation, region, figure
        case answerSource = "answer_source"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stem = try c.decodeIfPresent(String.self, forKey: .stem) ?? ""
        options = try c.decodeIfPresent([ExerciseOption].self, forKey: .options) ?? []
        answer = try c.decodeIfPresent([String].self, forKey: .answer) ?? []
        answerSource = try c.decodeIfPresent(String.self, forKey: .answerSource)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        region = try c.decodeIfPresent([Double].self, forKey: .region)
        figure = try c.decodeIfPresent(Bool.self, forKey: .figure) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stem, forKey: .stem)
        try c.encode(options, forKey: .options)
        try c.encode(answer, forKey: .answer)
        try c.encodeIfPresent(answerSource, forKey: .answerSource)
        try c.encodeIfPresent(explanation, forKey: .explanation)
        try c.encodeIfPresent(region, forKey: .region)
        if figure { try c.encode(true, forKey: .figure) }
    }

    func data() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }
}

/// 一道题（App 层）：库行 + 解码后的 payload。
struct Exercise: Identifiable, Equatable {
    var id: String
    var documentId: String?
    /// 0 起。
    var page: Int?
    var seq: Int
    var kind: ExerciseKind
    var number: String
    var section: String
    var payload: ExercisePayload
    var starred: Bool
    var wrong: Bool
    var source: String
    var createdAt: Date
    var updatedAt: Date
    /// 所属章节：目录里的路径（顶层 → 最深一级），空 = 没设（`EXERCISE-PLAN.md §2.3`）。
    var chapter: [String]

    /// 库行解码。payload 坏了 / 题型不认识（以后的新题型）→ nil，调用方跳过这一行。
    init?(row: LibExercise) {
        guard let kind = ExerciseKind(rawValue: row.kind),
              let p = try? JSONDecoder().decode(ExercisePayload.self, from: row.payload) else { return nil }
        id = row.id; documentId = row.documentId; page = row.page; seq = row.seq
        self.kind = kind; number = row.number; section = row.section; payload = p
        starred = row.starred; wrong = row.wrong; source = row.source
        createdAt = row.createdAt; updatedAt = row.updatedAt
        chapter = row.chapter
    }

    func toRow() -> LibExercise {
        LibExercise(id: id, documentId: documentId, page: page, seq: seq, kind: kind.rawValue,
                    number: number, section: section, payload: payload.data(),
                    starred: starred, wrong: wrong, source: source, createdAt: createdAt, updatedAt: updatedAt,
                    chapter: chapter)
    }

    var hasAnswer: Bool { !payload.answer.isEmpty }
    var answerFromAgent: Bool { hasAnswer && payload.answerSource == ExerciseAnswerSource.agent.rawValue }

    /// 判题：选中的键与答案**完全相同**才算对（多选少选、多选都算错）。没有答案 → nil（没法判）。
    func judge(_ chosen: Set<String>) -> Bool? {
        guard hasAnswer else { return nil }
        return chosen == Set(payload.answer)
    }

    /// 作答记录里存的那串：选中的键按字母序拼起来。
    static func answerString(_ keys: Set<String>) -> String { keys.sorted().joined() }

    /// 以前的作答从哪来。
    enum Earlier: Equatable {
        /// 在 App 里练的最近一次（带时间）。
        case practiced(Date?)
        /// 书上的作答（高亮 / 手写认出来的）。
        case book
    }

    /// 以前做过的那次（练习页翻到做过的题直接显示它，用户 2026-10-11 定）：App 里练的最近一次优先，
    /// 没练过再拿书上的作答。对错按**现在的**答案现判——答案后来补上 / 改过，库里也已重判，
    /// 这里现判只是保证和选项旁的 ✓ ✗ 对得上。没做过 → nil。
    func earlierAnswer(_ s: ExerciseAttemptStats?) -> (chosen: Set<String>, correct: Bool?, from: Earlier)? {
        func keys(_ raw: String?) -> Set<String>? {
            guard let raw, let k = ExerciseImport.parseAnswer(raw), !k.isEmpty else { return nil }
            return Set(k)
        }
        if let k = keys(s?.lastAnswer) { return (k, judge(k), .practiced(s?.lastAt)) }
        if let k = keys(s?.markedAnswer) { return (k, judge(k), .book) }
        return nil
    }

    /// 列表里一行显示的题干：去掉换行、并掉连续空白（公式源码原样留着）。
    var plainStem: String { Self.collapse(payload.stem) }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - 导入（MCP `import_exercises` / `update_exercises`）

/// 一道待写入的题（已校验、已规整）。`page` 0 起。
struct ExerciseDraft: Equatable {
    var page: Int?
    var seq: Int
    var kind: ExerciseKind
    var number: String
    var section: String
    var payload: ExercisePayload
    /// Agent 明确给的章节（nil = 没给：新题按目录自动定，已有的题沿用原来的）。
    var chapter: [String]? = nil
    /// 按页码从 PDF 目录查出来的章节（MCP 层填，`ExerciseChapter.path`）。
    var autoChapter: [String] = []
    /// 用户在文档上的作答（高亮 / 手写认出来的选项键，排好序）。nil = 没给；空 = 撤掉原来那条。
    var userAnswer: [String]? = nil
}

/// 导入的一道题的原始输入（MCP 那边从 JSON 里拆出来，什么都还没校验）。
struct ExerciseInput {
    var page: Int?              // 0 起（换算在 MCP 层做）
    var type: String?
    var number: String?
    var section: String?
    var stem: String?
    var options: [(key: String?, text: String?)]
    var answer: String?
    var answerSource: String?
    var explanation: String?
    var region: [Double]?
    var figure: Bool?
    var chapter: [String]? = nil
    var userAnswer: String? = nil
}

enum ExerciseImport {
    /// 选项键允许的范围（A~H，最多 8 个选项）。
    static let maxOptions = 8
    static let keyLetters = Array("ABCDEFGH").map(String.init)

    /// 把「A」「A.」「(A)」「a」这类写法规整成大写单字母；认不出 → nil。
    static func normalizeKey(_ raw: String) -> String? {
        let letters = raw.uppercased().filter { $0.isASCII && $0.isLetter }
        guard letters.count == 1, keyLetters.contains(String(letters)) else { return nil }
        return String(letters)
    }

    /// 「AC」「A,C」「A、C」「A C」→ ["A", "C"]（保序去重）。含选项键以外的字母 → nil。
    static func parseAnswer(_ raw: String) -> [String]? {
        var out: [String] = []
        for ch in raw.uppercased() {
            if ch.isWhitespace || ",，、;；/".contains(ch) { continue }
            guard ch.isASCII, ch.isLetter, keyLetters.contains(String(ch)) else { return nil }
            if !out.contains(String(ch)) { out.append(String(ch)) }
        }
        return out
    }

    /// 一道题被退回的原因（一句英文，给模型看、让它改了重发）。能直接写字符串字面量 / 插值。
    struct Rejected: Error, Equatable, ExpressibleByStringInterpolation {
        let reason: String
        init(stringLiteral value: String) { reason = value }
    }

    /// 校验并规整一道题。
    static func validate(_ i: ExerciseInput, seq: Int) -> Result<ExerciseDraft, Rejected> {
        let stem = (i.stem ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return .failure("stem is empty") }
        let figure = i.figure ?? false
        guard i.options.count >= 2 else { return .failure("a choice question needs at least 2 options") }
        guard i.options.count <= maxOptions else { return .failure("at most \(maxOptions) options (A–H)") }
        var options: [ExerciseOption] = []
        for (n, o) in i.options.enumerated() {
            guard let key = normalizeKey(o.key ?? "") else {
                return .failure("option \(n + 1) has an invalid key '\(o.key ?? "")'; use a single letter A–H")
            }
            guard !options.contains(where: { $0.key == key }) else { return .failure("duplicate option key \(key)") }
            let text = (o.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 选项本身是图（函数图像那种）时文字可以空，但题必须标 figure，练习时才会把原题截图摆出来
            guard !text.isEmpty || figure else {
                return .failure("option \(key) has no text; if the options are pictures, set figure to true")
            }
            options.append(ExerciseOption(key: key, text: text))
        }
        var answer: [String] = []
        if let raw = i.answer, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let a = parseAnswer(raw), !a.isEmpty else {
                return .failure("answer '\(raw)' must be option letters such as \"B\" or \"AC\"")
            }
            let keys = Set(options.map(\.key))
            if let bad = a.first(where: { !keys.contains($0) }) {
                return .failure("answer key \(bad) is not one of the options")
            }
            answer = a.sorted()
        }
        let kind: ExerciseKind
        if let t = i.type, !t.isEmpty {
            guard let k = ExerciseKind(wire: t) else { return .failure("type must be \"single\" or \"multiple\"") }
            kind = k
        } else {
            kind = answer.count > 1 ? .multiple : .single
        }
        if kind == .single && answer.count > 1 {
            return .failure("a single-choice question has exactly one answer; got \(answer.joined())")
        }
        var source: String?
        if !answer.isEmpty {
            guard let s = i.answerSource, let src = ExerciseAnswerSource(rawValue: s.lowercased()) else {
                return .failure("answer_source is required with answer: \"book\" if the answer is printed in the document, \"agent\" if you worked it out")
            }
            source = src.rawValue
        }
        var region: [Double]?
        if let r = i.region {
            guard r.count == 4, r.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), r[2] > 0, r[3] > 0 else {
                return .failure("region must be [x, y, w, h] with values 0–1 (top-left origin) and w, h > 0")
            }
            region = r
        }
        // 书上的作答：只认得选项字母；单选题圈了两个也照收（那就是用户当时的作答，判错）
        var userAnswer: [String]?
        if let raw = i.userAnswer {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                userAnswer = []
            } else {
                guard let a = parseAnswer(raw), !a.isEmpty else {
                    return .failure("user_answer '\(raw)' must be option letters such as \"B\" or \"AC\"")
                }
                let keys = Set(options.map(\.key))
                if let bad = a.first(where: { !keys.contains($0) }) {
                    return .failure("user_answer key \(bad) is not one of the options")
                }
                userAnswer = a.sorted()
            }
        }
        let explanation = i.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ExercisePayload(stem: stem, options: options, answer: answer, answerSource: source,
                                      explanation: explanation?.isEmpty == false ? explanation : nil,
                                      region: region, figure: figure)
        return .success(ExerciseDraft(page: i.page, seq: seq, kind: kind,
                                      number: (i.number ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                      section: (i.section ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                      payload: payload, chapter: i.chapter.map(ExerciseChapter.clean),
                                      userAnswer: userAnswer))
    }

    /// `update_exercises` 的起点：把已有的一道题还原成输入，覆盖给出的字段后再整题走一遍 `validate`。
    static func input(from e: Exercise) -> ExerciseInput {
        ExerciseInput(page: e.page, type: e.kind.wireName, number: e.number, section: e.section,
                      stem: e.payload.stem, options: e.payload.options.map { (key: $0.key, text: $0.text) },
                      answer: e.payload.answer.joined(), answerSource: e.payload.answerSource,
                      explanation: e.payload.explanation, region: e.payload.region, figure: e.payload.figure,
                      chapter: e.chapter)
    }

    /// 题干规整（去掉全部空白）：没有题号时拿它认「同一道题」。
    static func normalizedStem(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// 在同一篇同一页已有的题里找「同一道」（`EXERCISE-PLAN.md §2.1`）：
    /// 有题号 → 章节 + 题号相同；没题号 → 规整后的题干相同。
    static func match(_ d: ExerciseDraft, in existing: [LibExercise]) -> LibExercise? {
        if !d.number.isEmpty {
            return existing.first { $0.number == d.number && $0.section == d.section }
        }
        let key = normalizedStem(d.payload.stem)
        return existing.first { row in
            row.number.isEmpty
                && (try? JSONDecoder().decode(ExercisePayload.self, from: row.payload))
                    .map { normalizedStem($0.stem) == key } == true
        }
    }
}

// MARK: - 侧栏的数

/// 侧栏「习题」一段要的数（`WorkspaceManager.refreshExercises` 算，两条 GROUP BY）。
struct ExerciseSummary: Equatable {
    var total = 0
    var wrong = 0
    var starred = 0
    /// 每篇有题的文档几道（文档 id → 题数）。
    var byDocument: [String: Int] = [:]
    /// 每篇文档每个章节**恰好**挂在这一级的题（文档 id → 章节路径 → 题数 + 最早页；空路径 = 没设章节的）。
    /// 上一级的数由侧栏把下面各级加起来（`ExerciseChapterTree`）。
    var chapters: [String: [[String]: ExerciseChapterStat]] = [:]

    func count(_ scope: ExerciseScope) -> Int {
        switch scope {
        case .all: return total
        case .wrong: return wrong
        case .starred: return starred
        case .document(let id): return byDocument[id] ?? 0
        case .chapter(let id, let path):
            return (chapters[id] ?? [:]).reduce(0) { $0 + (ExerciseScope.chapterContains(path, $1.key) ? $1.value.count : 0) }
        case .wrongDocument(let id):
            return (chapters[id] ?? [:]).values.reduce(0) { $0 + $1.wrong }
        case .wrongChapter(let id, let path):
            return (chapters[id] ?? [:]).reduce(0) { $0 + (ExerciseScope.chapterContains(path, $1.key) ? $1.value.wrong : 0) }
        case .starredDocument(let id):
            return (chapters[id] ?? [:]).values.reduce(0) { $0 + $1.starred }
        case .starredChapter(let id, let path):
            return (chapters[id] ?? [:]).reduce(0) { $0 + (ExerciseScope.chapterContains(path, $1.key) ? $1.value.starred : 0) }
        }
    }

    /// 错题本里一本书的章节分布：只留有错题的章节，`count` 换成错题数（`ExerciseChapterTree.build` 直接拿去建树）。
    /// `firstPage` 仍是这一节所有题里最早的那页——排序按书里的先后，和书底下那棵树一致。
    func mistakeChapters(_ documentId: String) -> [[String]: ExerciseChapterStat] { marked(documentId, \.wrong) }

    /// 收藏里一本书的章节分布（同错题本那棵，数的是收藏）。
    func starredChapters(_ documentId: String) -> [[String]: ExerciseChapterStat] { marked(documentId, \.starred) }

    private func marked(_ documentId: String, _ n: KeyPath<ExerciseChapterStat, Int>) -> [[String]: ExerciseChapterStat] {
        (chapters[documentId] ?? [:]).compactMapValues {
            $0[keyPath: n] > 0
                ? ExerciseChapterStat(count: $0[keyPath: n], firstPage: $0.firstPage, wrong: $0.wrong, starred: $0.starred)
                : nil
        }
    }
}

/// 挂在某个章节路径上的题：几道、最早在第几页（0 起；全没页码 = `Int.max`）、其中几道在错题本里、几道收藏了。
struct ExerciseChapterStat: Equatable {
    var count: Int
    var firstPage: Int
    var wrong: Int = 0
    var starred: Int = 0
}

// MARK: - 章节（`EXERCISE-PLAN.md §2.3`）

/// 目录的一个节点（`TOCEntry` 的最小投影：只要名字、页、子节点）。纯数据，spike 可以直接造。
struct ExerciseChapterNode: Equatable {
    var label: String
    /// 0 起；nil = 目录项没有落点（只是个分组标题）。
    var page: Int?
    var children: [ExerciseChapterNode] = []
}

enum ExerciseChapter {
    /// 路径规整：每段去首尾空白、去掉空段。
    static func clean(_ path: [String]) -> [String] {
        path.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 侧栏 / 练习页上的写法：「第二章 导数 › 2.3 求导法则」。
    static func display(_ path: [String]) -> String { path.joined(separator: " › ") }

    /// 第 `page` 页（0 起）在目录里属于哪一节：从顶层往下，每一层取「起始页 ≤ page 的最后一个」，一直到最深。
    /// 落在一章开头、第一个小节之前的那几页就停在章这一级。目录项没有页时按它第一个有页的子孙算。
    static func path(page: Int, in toc: [ExerciseChapterNode]) -> [String] {
        var out: [String] = []
        var level = toc
        while let hit = level.last(where: { (startPage($0) ?? .max) <= page }) {
            let label = hit.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { out.append(label) }
            level = hit.children
        }
        return out
    }

    private static func startPage(_ n: ExerciseChapterNode) -> Int? {
        if let p = n.page { return p }
        for c in n.children { if let p = startPage(c) { return p } }
        return nil
    }

    /// 目录摊平成一列（「设置章节…」的下拉框用）：每项是到它为止的完整路径。
    static func flatten(_ toc: [ExerciseChapterNode], prefix: [String] = []) -> [[String]] {
        var out: [[String]] = []
        for n in toc {
            let label = n.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let p = label.isEmpty ? prefix : prefix + [label]
            if !label.isEmpty { out.append(p) }
            out += flatten(n.children, prefix: p)
        }
        return out
    }
}

/// 侧栏里一本书底下的章节树：由「每个路径恰好几道」累加出每一级的总数。
struct ExerciseChapterTree: Equatable {
    var label: String
    var path: [String]
    /// 这一级及以下的题数。
    var count: Int
    var children: [ExerciseChapterTree]

    /// 这一级及以下最早的一道题在第几页（排序用）。
    var firstPage: Int

    /// 建树。同级按「下面最早那道题的页码」排（就是书里的先后，侧栏手上没有目录也排得对），同页按名字。
    /// 没设章节的那些题（空路径）不进树，由调用方另列一行「未分章节」。
    static func build(_ stats: [[String]: ExerciseChapterStat]) -> [ExerciseChapterTree] {
        func level(_ prefix: [String]) -> [ExerciseChapterTree] {
            var labels: [String] = []
            for path in stats.keys where path.count > prefix.count && Array(path.prefix(prefix.count)) == prefix {
                let l = path[prefix.count]
                if !labels.contains(l) { labels.append(l) }
            }
            return labels.map { l -> ExerciseChapterTree in
                let p = prefix + [l]
                let under = stats.filter { ExerciseScope.chapterContains(p, $0.key) }.map(\.value)
                return ExerciseChapterTree(label: l, path: p, count: under.reduce(0) { $0 + $1.count },
                                           children: level(p), firstPage: under.map(\.firstPage).min() ?? .max)
            }.sorted { a, b in
                a.firstPage != b.firstPage ? a.firstPage < b.firstPage
                    : a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
        }
        return level([])
    }
}

// MARK: - 侧栏 / 平板抽屉的分组（`EXERCISE-PLAN.md §4.1 / §10.1`）

/// 「习题」一段里的一行：一个范围 + 显示名 + 数 + 底下的几行。Mac 侧栏和平板抽屉（经 `exGroups` 下发）
/// 用的是**同一份**规则，安卓模式1 的 `ExerciseGroups.build` 逐条照抄这里。
struct ExerciseGroupNode: Equatable {
    var scope: ExerciseScope
    var title: String
    var count: Int
    var children: [ExerciseGroupNode] = []

    /// 建整段。`documents` = 书库顺序的（id, 书名）；`title` 给全部 / 错题本 / 收藏三行起名；
    /// `noChapter` = 「未分章节」那一行的名字。没有题 → 空（这一段不出现）。
    /// 全部 / 错题本 / 收藏三行恒在；错题本、收藏底下各是有错题 / 有收藏的书 → 章节树（数的是错题 / 收藏）；
    /// 之后每本有题的书一行，底下章节树。
    static func build(_ s: ExerciseSummary, documents: [(id: String, title: String)],
                      title: (ExerciseScope) -> String, noChapter: String) -> [ExerciseGroupNode] {
        guard s.total > 0 else { return [] }
        var rows = [ExerciseScope.all, .wrong, .starred].map { ExerciseGroupNode(scope: $0, title: title($0), count: s.count($0)) }
        rows[1].children = documents.filter { s.count(.wrongDocument($0.id)) > 0 }.map { d in
            ExerciseGroupNode(scope: .wrongDocument(d.id), title: d.title, count: s.count(.wrongDocument(d.id)),
                              children: chapters(stats: s.mistakeChapters(d.id), noChapter: noChapter) { .wrongChapter(d.id, $0) })
        }
        // 收藏也按书 → 章展开（用户 2026-10-11 定，同错题本：标签顶上不再有「错题 / 收藏」筛选，组合都在侧栏里点）
        rows[2].children = documents.filter { s.count(.starredDocument($0.id)) > 0 }.map { d in
            ExerciseGroupNode(scope: .starredDocument(d.id), title: d.title, count: s.count(.starredDocument(d.id)),
                              children: chapters(stats: s.starredChapters(d.id), noChapter: noChapter) { .starredChapter(d.id, $0) })
        }
        rows += documents.filter { (s.byDocument[$0.id] ?? 0) > 0 }.map { d in
            ExerciseGroupNode(scope: .document(d.id), title: d.title, count: s.byDocument[d.id] ?? 0,
                              children: chapters(stats: s.chapters[d.id] ?? [:], noChapter: noChapter) { .chapter(d.id, $0) })
        }
        return rows
    }

    /// 一本书底下的章节树：一道题都没设章节 → 不展开（书那一行就够了）；有设有没设 → 末尾多一行「未分章节」。
    /// `scope` = 章节路径在这一支里是哪个范围（书底下 / 错题本底下 / 收藏底下）；错题本、收藏那两棵的 `stats`
    /// 已只剩有错题 / 有收藏的章节、数是错题数 / 收藏数（`ExerciseSummary.mistakeChapters` / `starredChapters`）。
    static func chapters(stats: [[String]: ExerciseChapterStat], noChapter: String,
                         scope: ([String]) -> ExerciseScope) -> [ExerciseGroupNode] {
        guard stats.keys.contains(where: { !$0.isEmpty }) else { return [] }
        func make(_ t: ExerciseChapterTree) -> ExerciseGroupNode {
            ExerciseGroupNode(scope: scope(t.path), title: t.label, count: t.count, children: t.children.map(make))
        }
        var out = ExerciseChapterTree.build(stats).map(make)
        if let none = stats[[]], none.count > 0 {
            out.append(ExerciseGroupNode(scope: scope([]), title: noChapter, count: none.count))
        }
        return out
    }

    /// 摊平成一列（先父后子），`depth` = 缩进层级（0 起）。平板抽屉就按这一列画（`exGroups`）。
    static func flatten(_ nodes: [ExerciseGroupNode], depth: Int = 0) -> [(scope: ExerciseScope, title: String, count: Int, depth: Int)] {
        var out: [(scope: ExerciseScope, title: String, count: Int, depth: Int)] = []
        for n in nodes {
            out.append((n.scope, n.title, n.count, depth))
            out += flatten(n.children, depth: depth + 1)
        }
        return out
    }
}

// MARK: - 标签页里的筛选

/// 习题标签顶上的筛选：只剩「只看没做过」一个开关（用户 2026-10-11 定）。
/// 侧栏管「哪一组题」（全部 / 错题本 / 收藏 / 书 / 章，错题本和收藏都能按书 → 章展开），顶栏只管做题进度；
/// 原先的「错题 / 收藏」两项和侧栏重复（同一组题两条路能到）、在错题本里又毫无意义，已去掉。
/// 值即线上 `exDeck.filter`；`2` / `3` 是去掉的那两项，不再用（`PROTOCOL.md §4.9`）。
enum ExerciseFilter: Int, CaseIterable {
    case all = 0
    case unanswered = 1

    /// `attempts` = 这道题一共做过几次（含书上的作答）。
    func includes(_ e: Exercise, attempts: Int) -> Bool {
        switch self {
        case .all: return true
        case .unanswered: return attempts == 0
        }
    }
}

// MARK: - 标签页范围

/// 一个习题标签练的是哪一组题（标签的身份，`EXERCISE-PLAN.md §4.1`）。
enum ExerciseScope: Hashable {
    case all
    case wrong
    case starred
    case document(String)
    /// 一本书的某一章（含它下面的各小节）。路径为空 = 这本书里没设章节的那些题。
    case chapter(String, [String])
    /// 错题本按书 / 按章展开的那几级（用户 2026-10-11 要的）：这本书 / 这一章里**在错题本里**的题。
    case wrongDocument(String)
    case wrongChapter(String, [String])
    /// 收藏按书 / 按章展开的那几级（同错题本）：这本书 / 这一章里收藏了的题。
    case starredDocument(String)
    case starredChapter(String, [String])

    /// 侧栏 / 标签页选中键的前缀（同 `BoardNote.rowPrefix` 的口径）。
    static let rowPrefix = "ex:"
    private static let wrongPrefix = "wrong:"
    private static let starredPrefix = "starred:"

    var key: String {
        switch self {
        case .all: return "all"
        case .wrong: return "wrong"
        case .starred: return "starred"
        case .document(let id): return "doc:" + id
        // 文档 id 是 UUID（不含冒号），之后整段是路径的 JSON
        case .chapter(let id, let path): return "chap:" + id + ":" + LibraryStore.chapterText(path)
        case .wrongDocument(let id): return Self.wrongPrefix + Self.document(id).key
        case .wrongChapter(let id, let path): return Self.wrongPrefix + Self.chapter(id, path).key
        case .starredDocument(let id): return Self.starredPrefix + Self.document(id).key
        case .starredChapter(let id, let path): return Self.starredPrefix + Self.chapter(id, path).key
        }
    }
    init?(key: String) {
        switch key {
        case "all": self = .all
        case "wrong": self = .wrong
        case "starred": self = .starred
        default:
            // 错题本 / 收藏底下的几级 = 前缀 + 书 / 章的键
            for (prefix, wrong) in [(Self.wrongPrefix, true), (Self.starredPrefix, false)] where key.hasPrefix(prefix) {
                switch ExerciseScope(key: String(key.dropFirst(prefix.count))) {
                case .document(let id)?: self = wrong ? .wrongDocument(id) : .starredDocument(id)
                case .chapter(let id, let path)?: self = wrong ? .wrongChapter(id, path) : .starredChapter(id, path)
                default: return nil
                }
                return
            }
            if key.hasPrefix("chap:") {
                let rest = key.dropFirst(5)
                guard let colon = rest.firstIndex(of: ":") else { return nil }
                let id = String(rest[..<colon])
                guard !id.isEmpty else { return nil }
                self = .chapter(id, LibraryStore.chapterPath(String(rest[rest.index(after: colon)...])))
                return
            }
            guard key.hasPrefix("doc:"), key.count > 4 else { return nil }
            self = .document(String(key.dropFirst(4)))
        }
    }
    var rowID: String { Self.rowPrefix + key }
    init?(rowID: String) {
        guard rowID.hasPrefix(Self.rowPrefix) else { return nil }
        self.init(key: String(rowID.dropFirst(Self.rowPrefix.count)))
    }

    /// 这个范围属于哪本书（全部 / 错题本 / 收藏不属于某一本）。
    var documentId: String? {
        switch self {
        case .document(let id), .chapter(let id, _), .wrongDocument(let id), .wrongChapter(let id, _),
             .starredDocument(let id), .starredChapter(let id, _):
            return id
        default: return nil
        }
    }

    /// 错题本这一支（错题本本身和它按书 / 按章展开的几级）：默认都在**一个错题标签**里换（`TabsModel.openExercises`）。
    var isMistakes: Bool {
        switch self {
        case .wrong, .wrongDocument, .wrongChapter: return true
        default: return false
        }
    }

    func includes(_ e: Exercise) -> Bool {
        switch self {
        case .all: return true
        case .wrong: return e.wrong
        case .starred: return e.starred
        case .document(let id): return e.documentId == id
        case .chapter(let id, let path): return e.documentId == id && Self.chapterContains(path, e.chapter)
        case .wrongDocument(let id): return e.wrong && e.documentId == id
        case .wrongChapter(let id, let path): return e.wrong && e.documentId == id && Self.chapterContains(path, e.chapter)
        case .starredDocument(let id): return e.starred && e.documentId == id
        case .starredChapter(let id, let path): return e.starred && e.documentId == id && Self.chapterContains(path, e.chapter)
        }
    }

    /// 章节 `scope` 管不管得着挂在 `chapter` 的题：空路径只管没设章节的；否则 = 它自己或它下面的小节。
    static func chapterContains(_ scope: [String], _ chapter: [String]) -> Bool {
        scope.isEmpty ? chapter.isEmpty : chapter.starts(with: scope)
    }
}
