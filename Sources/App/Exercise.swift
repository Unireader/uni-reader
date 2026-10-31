import Foundation

/// 习题的纯逻辑（`EXERCISE-PLAN.md`）：payload 编解码、导入校验与规整、去重、判题、标签范围。
/// **只依赖 Foundation**——`spike/exercise-test.swift` 把它和 `Sources/Store/*` 一起直接编。

/// 题型（`exercise.kind`）。2 留给以后的判断题；3 填空 / 4 主观题 2026-10-13 加（`EXERCISE-PLAN.md §11`）。
/// 不认识的值（以后的新题型）各端都跳过那一行，所以只许往后加。
enum ExerciseKind: Int, CaseIterable {
    case single = 0
    case multiple = 1
    case fill = 3
    case subjective = 4

    /// MCP 里的写法（对模型最不容易写错的英文词）。
    var wireName: String {
        switch self {
        case .single: return "single"
        case .multiple: return "multiple"
        case .fill: return "fill"
        case .subjective: return "subjective"
        }
    }
    init?(wire: String) {
        switch wire.trimmingCharacters(in: .whitespaces).lowercased() {
        case "single": self = .single
        case "multiple": self = .multiple
        case "fill": self = .fill
        case "subjective": self = .subjective
        default: return nil
        }
    }

    /// 选择题（单选 / 多选）：点选项作答、程序判对错。
    var isChoice: Bool { self == .single || self == .multiple }
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
    /// 答案（空 = 还没有）：选择题 = 正确选项的键；填空题 = 每空一个参考答案（按空的先后）；
    /// 主观题 = 恰一个元素，参考答案正文（Markdown + 公式）。
    var answer: [String]
    /// `book` / `agent`；没有答案时为 nil。
    var answerSource: String?
    var explanation: String?
    /// 题目在页上的框 `[x, y, w, h]`（归一化 0~1、左上原点）。
    var region: [Double]?
    /// 带图 / 表：练习时默认显示原题截图。
    var figure: Bool
    /// 填空题有几个空（只有填空题有；没答案时靠它知道摆几个输入框）。
    var blanks: Int?
    /// 填空题每空**另外**认可的写法（与 `answer` 等长；没有就不写这个键）。判题时参考答案和这些都算对。
    var accept: [[String]]?

    init(stem: String, options: [ExerciseOption], answer: [String] = [], answerSource: String? = nil,
         explanation: String? = nil, region: [Double]? = nil, figure: Bool = false,
         blanks: Int? = nil, accept: [[String]]? = nil) {
        self.stem = stem; self.options = options; self.answer = answer; self.answerSource = answerSource
        self.explanation = explanation; self.region = region; self.figure = figure
        self.blanks = blanks; self.accept = accept
    }

    enum CodingKeys: String, CodingKey {
        case stem, options, answer, explanation, region, figure, blanks, accept
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
        blanks = try c.decodeIfPresent(Int.self, forKey: .blanks)
        accept = try c.decodeIfPresent([[String]].self, forKey: .accept)
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
        try c.encodeIfPresent(blanks, forKey: .blanks)
        if let accept, accept.contains(where: { !$0.isEmpty }) { try c.encode(accept, forKey: .accept) }
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
    /// 用户给这道题写的笔记（Markdown + `$…$`），空 = 没写（v22，`EXERCISE-PLAN.md §12`）。
    var note: String

    /// 库行解码。payload 坏了 / 题型不认识（以后的新题型）→ nil，调用方跳过这一行。
    init?(row: LibExercise) {
        guard let kind = ExerciseKind(rawValue: row.kind),
              let p = try? JSONDecoder().decode(ExercisePayload.self, from: row.payload) else { return nil }
        id = row.id; documentId = row.documentId; page = row.page; seq = row.seq
        self.kind = kind; number = row.number; section = row.section; payload = p
        starred = row.starred; wrong = row.wrong; source = row.source
        createdAt = row.createdAt; updatedAt = row.updatedAt
        chapter = row.chapter; note = row.note
    }

    func toRow() -> LibExercise {
        LibExercise(id: id, documentId: documentId, page: page, seq: seq, kind: kind.rawValue,
                    number: number, section: section, payload: payload.data(),
                    starred: starred, wrong: wrong, source: source, createdAt: createdAt, updatedAt: updatedAt,
                    chapter: chapter, note: note)
    }

    var hasAnswer: Bool { payload.answer.contains { !$0.isEmpty } }
    var answerFromAgent: Bool { hasAnswer && payload.answerSource == ExerciseAnswerSource.agent.rawValue }

    /// 判题：选中的键与答案**完全相同**才算对（多选少选、多选都算错）。没有答案 → nil（没法判）。
    /// 只管选择题；填空 / 主观题走 `autoJudge`。
    func judge(_ chosen: Set<String>) -> Bool? {
        guard kind.isChoice, hasAnswer else { return nil }
        return chosen == Set(payload.answer)
    }

    /// 作答记录里存的那串：选中的键按字母序拼起来。
    static func answerString(_ keys: Set<String>) -> String { keys.sorted().joined() }

    // MARK: 填空 / 主观题（`EXERCISE-PLAN.md §11`）

    /// 填空题有几个空（别的题型 0）。
    var blankCount: Int { kind == .fill ? max(payload.blanks ?? 0, payload.answer.count) : 0 }

    /// 主观题的参考答案（没有 → nil）。
    var referenceText: String? {
        guard kind == .subjective, let t = payload.answer.first, !t.isEmpty else { return nil }
        return t
    }

    /// 第 `i` 空认可的写法：参考答案 + `accept` 里的（原样，没规整）。
    func acceptedForms(blank i: Int) -> [String] {
        var out: [String] = []
        if payload.answer.indices.contains(i) { out.append(payload.answer[i]) }
        if let a = payload.accept, a.indices.contains(i) { out += a[i] }
        return out.filter { !$0.isEmpty }
    }

    /// 填空每一空对不对得上参考答案（规整后一字不差，`normalizeBlank`）。没有答案的空 = false。
    func blankMatches(_ blanks: [String]) -> [Bool] {
        (0..<blankCount).map { i in
            let mine = blanks.indices.contains(i) ? Self.normalizeBlank(blanks[i]) : ""
            return !mine.isEmpty && acceptedForms(blank: i).contains { Self.normalizeBlank($0) == mine }
        }
    }

    /// 程序判题（用户 2026-10-13 定）：选择题同 `judge`；填空题**每空都对得上才判对**，有对不上的（或写在画板上的）
    /// 交给人判——`1/2` 和 `0.5` 这类等价写法程序认不出，所以不直接判错；主观题一律 nil（自己判 / Agent 判）。
    func autoJudge(_ r: ExerciseResponse) -> Bool? {
        switch kind {
        case .single, .multiple: return judge(r.keys)
        case .fill:
            guard hasAnswer, blankCount > 0 else { return nil }
            return blankMatches(r.blanks).allSatisfy { $0 } ? true : nil
        case .subjective: return nil
        }
    }

    /// 填空比对前的规整：全角转半角（NFKC）、去掉 `$` 和全部空白、几个只管排版的 LaTeX 写法、句末标点。
    /// 只做「肯定等价」的变换——宁可没认出来交给人判，也不能把错的判成对。
    static func normalizeBlank(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
        for (a, b) in [("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"), ("\\left", ""), ("\\right", ""),
                       ("\\,", ""), ("\\;", ""), ("\\!", ""), ("\\ ", ""), ("$", "")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.filter { !$0.isWhitespace }
        while let last = t.last, "。.，,；;".contains(last) { t.removeLast() }
        return t
    }

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
        guard kind.isChoice else { return nil }
        func keys(_ raw: String?) -> Set<String>? {
            guard let raw, let k = ExerciseImport.parseAnswer(raw), !k.isEmpty else { return nil }
            return Set(k)
        }
        if let k = keys(s?.lastAnswer) { return (k, judge(k), .practiced(s?.lastAt)) }
        if let k = keys(s?.markedAnswer) { return (k, judge(k), .book) }
        return nil
    }

    /// 填空 / 主观题以前做过的那次（规则同 `earlierAnswer`：App 里练的最近一次优先，没有再拿书上的作答）。
    /// 对错**用库里记的**——自己判 / Agent 判的没法现算；程序判的那部分答案一改库里已重判（`rejudgeAttempts`）。
    /// 手写不在这里（统计里不带笔迹），显示时按 `attemptId` 另取。
    func earlierResponse(_ s: ExerciseAttemptStats?)
        -> (response: ExerciseResponse, correct: Bool?, judgedBy: String, attemptId: String, from: Earlier)? {
        guard !kind.isChoice, let s else { return nil }
        if let id = s.lastId, let raw = s.lastAnswer {
            return (ExerciseResponse.decode(kind, answer: raw), s.lastPracticedCorrect, s.lastJudgedBy, id, .practiced(s.lastAt))
        }
        if let id = s.markedId, let raw = s.markedAnswer {
            return (ExerciseResponse.decode(kind, answer: raw), s.markedCorrect, s.markedJudgedBy, id, .book)
        }
        return nil
    }

    /// 上一次的结果是错的（「重做上次做错的」挑的就是这些，用户 2026-10-27 定）：看的是练习页上显示的那次——
    /// App 里练的最近一次，没练过才看书上的作答（`earlierAnswer` / `earlierResponse`）。答对过、后来又做错的也算；
    /// 还没判的（等自己判 / Agent 判、题目没答案）不算错。
    func lastResultWrong(_ s: ExerciseAttemptStats?) -> Bool {
        if kind.isChoice { return earlierAnswer(s)?.correct == false }
        return earlierResponse(s)?.correct == false
    }

    /// 打开一组题时停在第几道（用户 2026-10-31 定「接着上次做的往下」，`EXERCISE-PLAN.md §13`）：
    /// 先找这一组里**在 App 里最近练过**的那道（`lastAt` 最大；书上的作答不算，它的时间是导入那一刻），
    /// 从它后面找第一道没做过的；后面都做过了，从头找第一道没做过的；全做过（或一道都没练过、也没有没做过的）→ 第 1 题。
    /// 「没做过」同顶栏「只看没做过」（`ExerciseFilter.unanswered`：一次作答都没有，书上的作答也算做过）。
    /// 两道题时间一样时取排在后面的那道。安卓 `Exercise.resumeIndex` 逐条照抄（两端同一个库得出同一道）。
    static func resumeIndex(_ items: [Exercise], stats: [String: ExerciseAttemptStats]) -> Int {
        func undone(_ i: Int) -> Bool { (stats[items[i].id]?.attempts ?? 0) == 0 }
        var last = -1
        var lastAt: Date?
        for (i, e) in items.enumerated() {
            guard let t = stats[e.id]?.lastAt else { continue }
            if lastAt.map({ t >= $0 }) ?? true { last = i; lastAt = t }
        }
        let start = last + 1
        if let i = (start..<items.count).first(where: undone) { return i }
        return (0..<start).first(where: undone) ?? 0
    }

    /// 列表里一行显示的题干：去掉换行、并掉连续空白（公式源码原样留着）。
    var plainStem: String { Self.collapse(payload.stem) }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - 一次作答的内容（`EXERCISE-PLAN.md §11.2`）

/// 一次作答写了什么。库里：`exercise_attempt.answer` 存文字那部分（`answerString`），手写另存 `ink` 列。
struct ExerciseResponse: Equatable {
    /// 选择题：选中的键。
    var keys: Set<String> = []
    /// 填空题：每空一格（没填的是空串），按空的先后。
    var blanks: [String] = []
    /// 主观题：写的文字（Markdown + `$…$`）。
    var text: String = ""
    /// 手写（填空 / 主观题都能用）。
    var ink: ExerciseInk? = nil

    /// `answer` 列里的串：选择题 = 键按字母序拼起来（同以前）；填空 = JSON 字符串数组；主观题 = 原文。
    func answerString(_ kind: ExerciseKind) -> String {
        switch kind {
        case .single, .multiple: return Exercise.answerString(keys)
        case .fill:
            let e = JSONEncoder()
            e.outputFormatting = [.withoutEscapingSlashes]
            return (try? e.encode(blanks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        case .subjective: return text
        }
    }

    /// 从库里还原。认不出的填空串（不是 JSON 数组）当成只填了一空。
    static func decode(_ kind: ExerciseKind, answer: String, ink: Data? = nil) -> ExerciseResponse {
        var r = ExerciseResponse(ink: ExerciseInk.decode(ink))
        switch kind {
        case .single, .multiple: r.keys = Set(ExerciseImport.parseAnswer(answer) ?? [])
        case .fill:
            if let list = try? JSONDecoder().decode([String].self, from: Data(answer.utf8)) { r.blanks = list }
            else if !answer.isEmpty { r.blanks = [answer] }
        case .subjective: r.text = answer
        }
        return r
    }

    /// 什么都没写（这样的不收）。
    func isEmpty(_ kind: ExerciseKind) -> Bool {
        let noInk = ink?.isEmpty ?? true
        switch kind {
        case .single, .multiple: return keys.isEmpty
        case .fill: return noInk && blanks.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .subjective: return noInk && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 一行摘要（列表「我的答案」、MCP 的文字说明）：选择题 `AC`；填空 `2 / 1/2`；主观题并成一行的正文。
    /// 只有手写、没写字时是空串，调用方另标「手写」。
    func summary(_ kind: ExerciseKind) -> String {
        switch kind {
        case .single, .multiple: return Exercise.answerString(keys)
        case .fill:
            return blanks.contains(where: { !$0.isEmpty })
                ? blanks.map { $0.isEmpty ? "—" : Exercise.collapse($0) }.joined(separator: " / ") : ""
        case .subjective: return Exercise.collapse(text)
        }
    }
}

/// 谁判的对错（`exercise_attempt.judged_by`）：空串 = 程序判（或还没判）；`self` 自己判；`agent` Agent 判。
/// 同一次作答只留一个结论，后判的为准（用户 2026-10-13 定）。
enum ExerciseJudge {
    static let byProgram = ""
    static let bySelf = "self"
    static let byAgent = "agent"
}

/// 手写作答（内置小画板，`exercise_attempt.ink`）。JSON、点是显式数组（红线 6：跨平台 payload 用显式 JSON 数组）。
/// 坐标 = 画板的逻辑坐标（点，左上原点）：宽恒为 `canvasWidth`，界面按实际宽度等比缩放；高随「加高」变。
struct ExerciseInk: Codable, Equatable {
    var width: Double
    var height: Double
    var strokes: [Stroke]

    struct Stroke: Codable, Equatable {
        /// 笔宽（逻辑点）。
        var width: Double
        /// 每点 `[x, y, 压感 0~1]`。
        var points: [[Float]]
    }

    static let canvasWidth: Double = 600
    static let defaultHeight: Double = 280
    static let maxHeight: Double = 1800

    init(width: Double = ExerciseInk.canvasWidth, height: Double = ExerciseInk.defaultHeight, strokes: [Stroke] = []) {
        self.width = width; self.height = height; self.strokes = strokes
    }

    var isEmpty: Bool { strokes.isEmpty }

    func data() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }

    /// 空 / 坏数据 / 没有笔画 → nil。
    static func decode(_ d: Data?) -> ExerciseInk? {
        guard let d, !d.isEmpty, let ink = try? JSONDecoder().decode(ExerciseInk.self, from: d),
              ink.width > 0, ink.height > 0, !ink.strokes.isEmpty else { return nil }
        return ink
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
    /// 用户在文档上的作答（高亮 / 手写认出来的选项键，排好序）。nil = 没给；空 = 撤掉原来那条。只管选择题。
    var userAnswer: [String]? = nil
    /// 填空 / 主观题书上的作答（Agent 转写的文字）。nil = 没给；`isEmpty` = 撤掉原来那条。
    var userResponse: ExerciseResponse? = nil

    /// 书上的作答，统一成一份（nil = 没给；空 = 撤掉）。
    var userMark: ExerciseResponse? {
        if kind.isChoice { return userAnswer.map { ExerciseResponse(keys: Set($0)) } }
        return userResponse
    }
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
    /// 填空题的空：每空一个参考答案（可空）+ 另外认可的写法。nil = 没给。
    var blanks: [(answer: String?, accept: [String])]? = nil
    /// 填空题书上的作答（每空一格）。nil = 没给；全空 = 撤掉。
    var userBlanks: [String]? = nil
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

    /// 填空题最多几个空。
    static let maxBlanks = 20

    /// 校验并规整一道题。
    static func validate(_ i: ExerciseInput, seq: Int) -> Result<ExerciseDraft, Rejected> {
        let stem = (i.stem ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty else { return .failure("stem is empty") }
        let figure = i.figure ?? false
        // 题型：写了按写的；没写时给了空 → 填空，否则按选择题（由答案几个字母推单选 / 多选）
        var declared: ExerciseKind?
        if let t = i.type, !t.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let k = ExerciseKind(wire: t) else {
                return .failure("type must be \"single\", \"multiple\", \"fill\" or \"subjective\"")
            }
            declared = k
        } else if i.blanks != nil {
            declared = .fill
        }
        if let k = declared, !k.isChoice { return validateFree(i, kind: k, stem: stem, figure: figure, seq: seq) }
        if i.blanks != nil { return .failure("blanks are only for fill questions") }
        if i.userBlanks != nil { return .failure("user_blanks is only for fill questions") }
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
        let kind = declared ?? (answer.count > 1 ? .multiple : .single)
        if kind == .single && answer.count > 1 {
            return .failure("a single-choice question has exactly one answer; got \(answer.joined())")
        }
        let source: String?
        switch answerSource(i, hasAnswer: !answer.isEmpty) {
        case .failure(let why): return .failure(why)
        case .success(let s): source = s
        }
        let region: [Double]?
        switch validRegion(i.region) {
        case .failure(let why): return .failure(why)
        case .success(let r): region = r
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
        let payload = ExercisePayload(stem: stem, options: options, answer: answer, answerSource: source,
                                      explanation: cleanExplanation(i.explanation), region: region, figure: figure)
        return .success(ExerciseDraft(page: i.page, seq: seq, kind: kind,
                                      number: (i.number ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                      section: (i.section ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                      payload: payload, chapter: i.chapter.map(ExerciseChapter.clean),
                                      userAnswer: userAnswer))
    }

    /// 填空 / 主观题（`EXERCISE-PLAN.md §11.1`）：没有选项。填空的参考答案在 `blanks[].answer`（要么每空都给、要么都不给），
    /// 主观题的参考答案在 `answer`（正文）。书上的作答：填空 `user_blanks`、主观题 `user_answer`（Agent 转写的文字）。
    private static func validateFree(_ i: ExerciseInput, kind: ExerciseKind, stem: String, figure: Bool,
                                     seq: Int) -> Result<ExerciseDraft, Rejected> {
        guard i.options.isEmpty else {
            return .failure("a \(kind.wireName) question has no options; leave options out")
        }
        func trim(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var answer: [String] = []
        var blanks: Int?
        var accept: [[String]]?
        var user: ExerciseResponse?
        if kind == .fill {
            guard let list = i.blanks, !list.isEmpty else {
                return .failure("a fill question needs blanks: one entry per blank in order, e.g. [{\"answer\": \"2\"}, {\"answer\": \"$\\\\frac{1}{2}$\"}]; leave answer out if unknown")
            }
            guard list.count <= maxBlanks else { return .failure("at most \(maxBlanks) blanks") }
            guard trim(i.answer).isEmpty else {
                return .failure("for a fill question put each blank's answer in blanks[].answer, not in answer")
            }
            guard trim(i.userAnswer).isEmpty else {
                return .failure("for a fill question put what the user wrote in user_blanks (one string per blank)")
            }
            let given = list.map { trim($0.answer) }
            let known = given.filter { !$0.isEmpty }.count
            guard known == 0 || known == list.count else {
                return .failure("give an answer for every blank or for none (\(known) of \(list.count) given)")
            }
            blanks = list.count
            if known > 0 {
                answer = given
                let extra = zip(list, given).map { b, a in
                    b.accept.map { trim($0) }.filter { !$0.isEmpty && $0 != a }
                }
                accept = extra.contains { !$0.isEmpty } ? extra : nil
            } else if list.contains(where: { !$0.accept.isEmpty }) {
                return .failure("blanks[].accept needs blanks[].answer")
            }
            if let ub = i.userBlanks {
                let t = ub.map { trim($0) }
                if t.allSatisfy(\.isEmpty) {
                    user = ExerciseResponse()          // 全空 = 撤掉
                } else {
                    guard t.count == list.count else {
                        return .failure("user_blanks has \(t.count) entries but the question has \(list.count) blanks")
                    }
                    user = ExerciseResponse(blanks: t)
                }
            }
        } else {
            if i.blanks != nil { return .failure("blanks are only for fill questions") }
            if i.userBlanks != nil { return .failure("user_blanks is only for fill questions; use user_answer") }
            let a = trim(i.answer)
            if !a.isEmpty { answer = [a] }
            if let raw = i.userAnswer { user = ExerciseResponse(text: trim(raw)) }   // 空 = 撤掉
        }
        let source: String?
        switch answerSource(i, hasAnswer: !answer.isEmpty) {
        case .failure(let why): return .failure(why)
        case .success(let s): source = s
        }
        let region: [Double]?
        switch validRegion(i.region) {
        case .failure(let why): return .failure(why)
        case .success(let r): region = r
        }
        let payload = ExercisePayload(stem: stem, options: [], answer: answer, answerSource: source,
                                      explanation: cleanExplanation(i.explanation), region: region, figure: figure,
                                      blanks: blanks, accept: accept)
        return .success(ExerciseDraft(page: i.page, seq: seq, kind: kind, number: trim(i.number), section: trim(i.section),
                                      payload: payload, chapter: i.chapter.map(ExerciseChapter.clean),
                                      userResponse: user))
    }

    private static func answerSource(_ i: ExerciseInput, hasAnswer: Bool) -> Result<String?, Rejected> {
        guard hasAnswer else { return .success(nil) }
        guard let s = i.answerSource, let src = ExerciseAnswerSource(rawValue: s.lowercased()) else {
            return .failure("answer_source is required with answer: \"book\" if the answer is printed in the document, \"agent\" if you worked it out")
        }
        return .success(src.rawValue)
    }

    private static func validRegion(_ r: [Double]?) -> Result<[Double]?, Rejected> {
        guard let r else { return .success(nil) }
        guard r.count == 4, r.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), r[2] > 0, r[3] > 0 else {
            return .failure("region must be [x, y, w, h] with values 0–1 (top-left origin) and w, h > 0")
        }
        return .success(r)
    }

    private static func cleanExplanation(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return t?.isEmpty == false ? t : nil
    }

    /// `update_exercises` 的起点：把已有的一道题还原成输入，覆盖给出的字段后再整题走一遍 `validate`。
    static func input(from e: Exercise) -> ExerciseInput {
        var i = ExerciseInput(page: e.page, type: e.kind.wireName, number: e.number, section: e.section,
                              stem: e.payload.stem, options: e.payload.options.map { (key: $0.key, text: $0.text) },
                              answer: e.kind.isChoice ? e.payload.answer.joined() : e.referenceText,
                              answerSource: e.payload.answerSource,
                              explanation: e.payload.explanation, region: e.payload.region, figure: e.payload.figure,
                              chapter: e.chapter)
        if e.kind == .fill { i.blanks = blankInputs(of: e) }
        return i
    }

    /// 一道填空题现有的空，还原成输入的形状（参考答案 + 另外认可的写法）。
    static func blankInputs(of e: Exercise) -> [(answer: String?, accept: [String])] {
        (0..<e.blankCount).map { k in
            (answer: e.payload.answer.indices.contains(k) ? e.payload.answer[k] : nil,
             accept: e.payload.accept.flatMap { $0.indices.contains(k) ? $0[k] : nil } ?? [])
        }
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
/// 每组题做过几道（`LibraryStore.exerciseDoneCounts`，侧栏行尾「已做 / 共」，`EXERCISE-PLAN.md §16`）。
/// 「做过」= 至少一次作答（含书上的作答），同「只看没做过」。
struct ExerciseDoneSummary: Equatable {
    /// 文档 id → 章节路径（恰好挂在这一级）→ 做过的题数 + 其中收藏了的几道。
    var chapters: [String: [[String]: ExerciseDoneStat]] = [:]

    /// 这一组做过几道。错题本那一支返回 nil：里面的题都是答错进来的、全都做过，行尾只显示题数。
    func done(_ scope: ExerciseScope) -> Int? {
        func sum(_ id: String?, _ path: [String]?, _ n: KeyPath<ExerciseDoneStat, Int>) -> Int {
            let books = id.map { [chapters[$0] ?? [:]] } ?? Array(chapters.values)
            var total = 0
            for book in books {
                for (chapter, stat) in book where path.map({ ExerciseScope.chapterContains($0, chapter) }) ?? true {
                    total += stat[keyPath: n]
                }
            }
            return total
        }
        switch scope {
        case .all: return sum(nil, nil, \.done)
        case .starred: return sum(nil, nil, \.starred)
        case .document(let id): return sum(id, nil, \.done)
        case .chapter(let id, let p): return sum(id, p, \.done)
        case .starredDocument(let id): return sum(id, nil, \.starred)
        case .starredChapter(let id, let p): return sum(id, p, \.starred)
        case .wrong, .wrongDocument, .wrongChapter: return nil
        }
    }
}
struct ExerciseDoneStat: Equatable {
    var done: Int
    var starred: Int = 0
}

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

/// 导入时新题的章节怎么定（`import_exercises` 的 `chapters`，`EXERCISE-PLAN.md §14`）。
/// Agent 第一次往一本书里导题时问过用户、按用户选的传；以后不传，按这本书现在的样子（`ExerciseChapter.usesTOC`）。
enum ExerciseChapterMode: String {
    /// 按页码从 PDF 自带目录里定（原来的做法）。
    case toc
    /// 不分章节：没明确给 `chapter` 的题一律不设（线上写 `"none"`；Swift 里别叫 `none`，会和 `Optional.none` 混）。
    case flat = "none"
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

    /// 这本书是不是「不分章节」的（`EXERCISE-PLAN.md §14`）：已经有题、一道都没设章节，而且其中至少有一道
    /// 按目录本来能分进某一章——也就是用户移除过分级 / 导入时选了不分，而不是题恰好都落在目录管不到的页上。
    /// 没目录的书恒为假（反正也分不出来）。不另存标记：看库里这本书的题现在是什么样就够了。
    static func bookIsFlat(_ existing: [(page: Int?, chapter: [String])], toc: [ExerciseChapterNode]) -> Bool {
        guard !toc.isEmpty, !existing.isEmpty, existing.allSatisfy({ $0.chapter.isEmpty }) else { return false }
        return existing.contains { e in e.page.map { !path(page: $0, in: toc).isEmpty } ?? false }
    }

    /// 导入的这一批里没明确给章节的题，要不要按目录自动定（`import_exercises` 的 `chapters`）：
    /// 说了就听说的；没说就看这本书现在的样子——不分章节的书（`bookIsFlat`）保持不分，其余照旧按目录。
    static func usesTOC(_ mode: ExerciseChapterMode?, existing: [(page: Int?, chapter: [String])],
                        toc: [ExerciseChapterNode]) -> Bool {
        switch mode {
        case .toc?: return true
        case .flat?: return false
        case nil: return !bookIsFlat(existing, toc: toc)
        }
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
    /// 做过几道（侧栏行尾「已做 / 共」，§16）；nil = 不显示（错题本那一支，或调用方没给做题进度）。
    var done: Int? = nil

    /// 整棵树填上「做过几道」。
    func withDone(_ d: ExerciseDoneSummary) -> ExerciseGroupNode {
        var n = self
        n.done = d.done(scope)
        n.children = children.map { $0.withDone(d) }
        return n
    }

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

/// 习题标签顶上的筛选：「只看没做过」「重做上次做错的」两个开关，至多开一个（用户 2026-10-11 / 10-27 定）。
/// 侧栏管「哪一组题」（全部 / 错题本 / 收藏 / 书 / 章，错题本和收藏都能按书 → 章展开），顶栏只管做题进度；
/// 原先的「错题 / 收藏」两项和侧栏重复（同一组题两条路能到）、在错题本里又毫无意义，已去掉。
/// 值即线上 `exDeck.filter`；`2` / `3` 是去掉的那两项，不再用、不许再分配（`PROTOCOL.md §4.9`）。
enum ExerciseFilter: Int, CaseIterable {
    case all = 0
    case unanswered = 1
    /// 重做上次做错的（2026-10-27，`EXERCISE-PLAN.md §12.2`）：只留上一次结果是错的题，这一轮都当没答过。
    case lastWrong = 4

    /// `s` = 这道题的作答统计（nil = 没做过；做过几次含书上的作答）。
    func includes(_ e: Exercise, stats s: ExerciseAttemptStats?) -> Bool {
        switch self {
        case .all: return true
        case .unanswered: return (s?.attempts ?? 0) == 0
        case .lastWrong: return e.lastResultWrong(s)
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

    /// 这一组在侧栏 / ⌘P 快速打开里的图标（SF Symbols 名）。
    var symbolName: String {
        switch self {
        case .all: return "checklist"
        case .wrong: return "xmark.circle"
        case .starred: return "star"
        case .document, .wrongDocument, .starredDocument: return "doc.questionmark"
        case .chapter(_, let path), .wrongChapter(_, let path), .starredChapter(_, let path):
            return path.isEmpty ? "questionmark.folder" : "list.bullet.indent"
        }
    }
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
