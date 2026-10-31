// 习题（`EXERCISE-PLAN.md`）回归测试：导入校验 / 规整、去重、库读写、错题本规则、作答统计、
// 删文档级联、回收站归档与恢复、「关联为同一文档」带走习题。运行：
//   cp spike/exercise-test.swift /tmp/main.swift && \
//     swiftc Sources/Store/*.swift Sources/App/Exercise.swift /tmp/main.swift -o /tmp/ex && /tmp/ex
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）

import Foundation

setvbuf(stdout, nil, _IONBF, 0)
var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ex_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)

func doc(_ title: String, _ hash: String) -> LibDocument {
    try! store.findOrCreate(hash: hash, title: title, pageCount: 20, path: "PDFs/\(hash).pdf", isRelative: false).document
}
func input(_ stem: String?, _ opts: [(String?, String?)] = [("A", "甲"), ("B", "乙"), ("C", "丙"), ("D", "丁")],
           type: String? = nil, answer: String? = nil, src: String? = nil, number: String? = nil,
           section: String? = nil, page: Int? = 0, region: [Double]? = nil, figure: Bool? = nil) -> ExerciseInput {
    ExerciseInput(page: page, type: type, number: number, section: section, stem: stem,
                  options: opts.map { (key: $0.0, text: $0.1) }, answer: answer, answerSource: src,
                  explanation: nil, region: region, figure: figure)
}
func ok(_ i: ExerciseInput, seq: Int = 0) -> ExerciseDraft? {
    if case .success(let d) = ExerciseImport.validate(i, seq: seq) { return d }
    return nil
}
func reason(_ i: ExerciseInput) -> String? {
    if case .failure(let r) = ExerciseImport.validate(i, seq: 0) { return r.reason }
    return nil
}
func row(_ d: ExerciseDraft, doc: String, id: String = UUID().uuidString) -> LibExercise {
    LibExercise(id: id, documentId: doc, page: d.page, seq: d.seq, kind: d.kind.rawValue, number: d.number,
                section: d.section, payload: d.payload.data(), starred: false, wrong: false, source: "test",
                createdAt: .now, updatedAt: .now)
}

print("— 建表")
check(LibraryStore.schemaVersion == 22, "schema 版本 22（v21 = 填空 / 主观题，作答多三列；v22 = 题目笔记）")
check((try? store.exercises()) != nil, "exercise 表可查")

print("— 校验与规整")
let good = ok(input("设 $f(x)=x^2$，则 $f'(1)=$", answer: "c", src: "book", number: " 5 "))
check(good != nil, "合格单选题通过")
check(good?.kind == .single, "没写题型、答案 1 个 → 单选")
check(good?.payload.answer == ["C"], "答案小写规整成大写")
check(good?.payload.answerSource == "book", "答案来源保留")
check(good?.number == "5", "题号去首尾空白")
check(ok(input("多选", answer: "A, C", src: "agent"))?.kind == .multiple, "没写题型、答案 2 个 → 多选")
check(ok(input("多选", answer: "C、A", src: "agent"))?.payload.answer == ["A", "C"], "「C、A」→ [A, C]（排序）")
check(ok(input("键", [("(a)", "x"), ("B.", "y")]))?.payload.options.map(\.key) == ["A", "B"], "「(a)」「B.」规整成 A / B")
check(reason(input("   ")) == "stem is empty", "空题干退回")
check(reason(input("x", [("A", "1")]))?.contains("at least 2") == true, "只有 1 个选项退回")
check(reason(input("x", (0..<9).map { _ in ("A", "1") }))?.contains("at most 8") == true, "9 个选项退回")
check(reason(input("x", [("A", "1"), ("AB", "2")]))?.contains("invalid key") == true, "选项键不是单字母退回")
check(reason(input("x", [("A", "1"), ("a", "2")]))?.contains("duplicate") == true, "重复选项键退回")
check(reason(input("x", [("A", "1"), ("B", " ")]))?.contains("figure") == true, "选项没文字且没标 figure 退回")
check(ok(input("x", [("A", ""), ("B", "")], figure: true)) != nil, "选项是图（figure）时文字可以空")
check(reason(input("x", answer: "E", src: "book"))?.contains("not one of the options") == true, "答案不在选项里退回")
check(reason(input("x", answer: "1", src: "book"))?.contains("option letters") == true, "答案不是字母退回")
check(reason(input("x", type: "single", answer: "AB", src: "book"))?.contains("exactly one") == true, "单选给两个答案退回")
check(reason(input("x", answer: "A"))?.contains("answer_source") == true, "有答案没写来源退回")
check(reason(input("x", answer: "A", src: "guess"))?.contains("answer_source") == true, "答案来源写错退回")
check(ok(input("x")) != nil && ok(input("x"))?.payload.answer == [], "没有答案也能导入")
check(reason(input("x", type: "judge"))?.contains("type") == true, "不认识的题型退回")
check(reason(input("x", region: [0.1, 0.2, 0, 0.3]))?.contains("region") == true, "region 宽为 0 退回")
check(reason(input("x", region: [0.1, 0.2, 0.3]))?.contains("region") == true, "region 不是 4 个数退回")
check(reason(input("x", region: [0.1, 1.2, 0.3, 0.3]))?.contains("region") == true, "region 越出 0~1 退回")
check(ok(input("x", region: [0.1, 0.2, 0.8, 0.1]))?.payload.region == [0.1, 0.2, 0.8, 0.1], "合格 region 保留")

print("— payload 编解码")
let p = ExercisePayload(stem: "s", options: [ExerciseOption(key: "A", text: "a"), ExerciseOption(key: "B", text: "b")],
                        answer: ["B"], answerSource: "book", explanation: "因为", region: [0, 0, 1, 0.5], figure: true)
check((try? JSONDecoder().decode(ExercisePayload.self, from: p.data())) == p, "编解码回环一致")
let json = String(data: p.data(), encoding: .utf8) ?? ""
check(json.contains("\"answer_source\""), "键是 snake_case")
let old = try! JSONDecoder().decode(ExercisePayload.self, from: Data(#"{"stem":"s","options":[{"key":"A","text":"a"}]}"#.utf8))
check(old.answer == [] && old.figure == false && old.region == nil, "缺键的老 payload 按默认值读出")
check(!String(data: ExercisePayload(stem: "s", options: []).data(), encoding: .utf8)!.contains("figure"),
      "figure=false 不写进 JSON（省字节）")

print("— 判题")
var ex = Exercise(row: row(good!, doc: "x"))!
check(ex.judge(["C"]) == true, "选对 → 对")
check(ex.judge(["A"]) == false, "选错 → 错")
check(ex.judge(["A", "C"]) == false, "多选了 → 错")
ex.payload.answer = ["A", "C"]
check(ex.judge(["A"]) == false, "多选题少选 → 错")
check(ex.judge(["C", "A"]) == true, "多选题全对（顺序无关）→ 对")
ex.payload.answer = []
check(ex.judge(["A"]) == nil, "没有答案 → 没法判（nil）")
check(Exercise.answerString(["C", "A"]) == "AC", "作答串按字母序")
check(Exercise(row: LibExercise(id: "z", documentId: nil, page: nil, seq: 0, kind: 9, number: "", section: "",
                                payload: p.data(), starred: false, wrong: false, source: "", createdAt: .now,
                                updatedAt: .now)) == nil, "不认识的题型（以后的新题型）解码为 nil，跳过")

print("— 库读写与去重")
let d1 = doc("线代习题", "h1")
let a = ok(input("第一题", answer: "A", src: "book", number: "1", section: "第一章"), seq: 0)!
let b = ok(input("第二题", number: "2", section: "第一章"), seq: 1)!
let ra = row(a, doc: d1.id), rb = row(b, doc: d1.id)
try store.upsertExercises([ra, rb])
check(try store.exercises(documentId: d1.id).map(\.id) == [ra.id, rb.id], "按页内先后读回")
check(try store.exercises(documentId: d1.id, page: 0).count == 2, "按页取")
check(try store.exercises(documentId: d1.id, page: nil).isEmpty, "page IS NULL 那一组是空的")
// 同题号同章节再导一次 → 命中
let again = ok(input("第二题（改）", answer: "B", src: "book", number: "2", section: "第一章"), seq: 1)!
check(ExerciseImport.match(again, in: try store.exercises(documentId: d1.id, page: 0))?.id == rb.id, "题号 + 章节相同 → 认作同一道")
let other = ok(input("第二题", number: "2", section: "第二章"))!
check(ExerciseImport.match(other, in: try store.exercises(documentId: d1.id, page: 0)) == nil, "章节不同的同号题不算同一道")
// 没题号：按规整后的题干认
let n1 = ok(input("无题号 的 题"))!
let rn = row(n1, doc: d1.id)
try store.upsertExercise(rn)
check(ExerciseImport.match(ok(input("无题号的题"))!, in: try store.exercises(documentId: d1.id, page: 0))?.id == rn.id,
      "没题号 → 题干去空白后相同即同一道")
check(ExerciseImport.match(ok(input("无题号的另一题"))!, in: try store.exercises(documentId: d1.id, page: 0)) == nil,
      "题干不同不算")

print("— 收藏 / 错题本不被重导冲掉")
try store.setExerciseStarred(id: rb.id, true)
try store.setExerciseWrong(id: rb.id, true)
var rb2 = row(again, doc: d1.id, id: rb.id)
rb2.starred = false; rb2.wrong = false        // 重导时带的是默认值
try store.upsertExercise(rb2)
let back = try store.exercise(id: rb.id)!
check(back.starred && back.wrong, "upsert 只覆盖内容列，收藏与错题本保持")
check(Exercise(row: back)?.payload.stem == "第二题（改）", "内容确实更新了")

print("— 错题本规则（答错进，只能手动出）")
try store.setExerciseWrong(id: ra.id, false)
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: ra.id, answer: "A",
                                                   correct: true, elapsedMs: 1200, createdAt: .now))
check(try store.exercise(id: ra.id)?.wrong == false, "答对不进错题本")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: ra.id, answer: "B",
                                                   correct: false, elapsedMs: 800,
                                                   createdAt: Date(timeIntervalSinceNow: 1)))
check(try store.exercise(id: ra.id)?.wrong == true, "答错 → 进错题本")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: ra.id, answer: "A",
                                                   correct: true, elapsedMs: 500,
                                                   createdAt: Date(timeIntervalSinceNow: 2)))
check(try store.exercise(id: ra.id)?.wrong == true, "之后答对也不自动出")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: rn.id, answer: "C",
                                                   correct: nil, elapsedMs: 0, createdAt: .now))
check(try store.exercise(id: rn.id)?.wrong == false, "没答案的题（correct=nil）不进错题本")
try store.setExerciseWrong(id: ra.id, false)
check(try store.exercise(id: ra.id)?.wrong == false, "手动移出")
let attempts = try store.exerciseAttempts(exerciseId: ra.id)
check(attempts.count == 3 && attempts.map(\.answer) == ["A", "B", "A"], "作答记录按时间读回")
check(attempts[1].correct == false && attempts[1].elapsedMs == 800, "作答的对错与用时存对")
check(try store.exerciseAttempts(exerciseId: rn.id).first?.correct == nil, "correct=nil 存成 NULL 读回 nil")

print("— 统计")
let st = try store.exerciseAttemptStats()
let sa = st[ra.id]
check(sa?.attempts == 3 && sa?.correct == 2 && sa?.wrong == 1 && sa?.lastCorrect == true, "做过的题：次数 / 对 / 错 / 最近一次")
check(sa?.lastAnswer == "A" && sa?.lastAt != nil && sa?.markedAnswer == nil, "最近一次在 App 里的作答：选了什么、什么时候")
check(st[rn.id]?.attempts == 1 && st[rn.id]?.lastCorrect == nil, "最近一次没法判 → lastCorrect nil")
check(st[rb.id] == nil, "没做过的题不在统计里")
let c = try store.exerciseCounts()
check(c.total == 3 && c.wrong == 1 && c.starred == 1 && c.byDocument[d1.id] == 3, "侧栏的数：总 3 / 错 1 / 藏 1 / 本篇 3")

print("— 标签范围")
check(ExerciseScope(key: "all") == .all && ExerciseScope(key: "wrong") == .wrong, "范围键回环")
check(ExerciseScope(rowID: ExerciseScope.document("ABC").rowID) == .document("ABC"), "文档范围 rowID 回环")
check(ExerciseScope(key: "doc:") == nil && ExerciseScope(key: "x") == nil, "坏键 → nil")
check(ExerciseScope.wrong.includes(Exercise(row: try store.exercise(id: rb.id)!)!), "错题本范围含错题")
check(!ExerciseScope.starred.includes(Exercise(row: try store.exercise(id: ra.id)!)!), "收藏范围不含没收藏的")

print("— 回收站：删几道题")
let snap1 = tmp.appendingPathComponent("trash1.sqlite").path
let arc = try store.archiveExercises(ids: [ra.id, rb.id], to: snap1)
check(arc.counts.exercise == 2 && arc.counts.total == 2, "归档数到 2 道")
try store.deleteExercises(ids: [ra.id, rb.id])
check(try store.exercises(documentId: d1.id).count == 1, "删掉 2 道，剩 1 道")
check(try store.exerciseAttempts(exerciseId: ra.id).isEmpty, "作答记录随题级联删掉")
let n = try store.restoreTrash(snapshot: snap1, remapDocumentId: nil)
check(n == 5, "恢复 5 行（2 道题 + 3 次作答），实际 \(n)")
check(try store.exerciseAttempts(exerciseId: ra.id).count == 3, "作答记录一起回来")
check(try store.exercise(id: rb.id)?.starred == true, "收藏状态一起回来")
_ = try store.restoreTrash(snapshot: snap1, remapDocumentId: nil)
check(try store.exercises(documentId: d1.id).count == 3 && (try store.exerciseAttempts(exerciseId: ra.id).count) == 3,
      "重复恢复幂等（OR IGNORE 不把作答记录冲掉）")

print("— 回收站：删整篇文档")
let snap2 = tmp.appendingPathComponent("trash2.sqlite").path
let arc2 = try store.archiveDocument(id: d1.id, to: snap2)
check(arc2.counts.exercise == 3, "文档快照里带着 3 道题")
try store.deleteDocument(id: d1.id)
check(try store.exercises().isEmpty, "删文档 → 题级联删掉")
check(try store.exerciseAttemptStats().isEmpty, "作答记录也没了")
_ = try store.restoreTrash(snapshot: snap2, remapDocumentId: nil)
check(try store.exercises(documentId: d1.id).count == 3, "恢复文档 → 题回来")
check(try store.exerciseAttemptStats()[ra.id]?.attempts == 3, "作答记录回来")
// 重新导入过 → 并入现有那篇
let snap3 = tmp.appendingPathComponent("trash3.sqlite").path
_ = try store.archiveDocument(id: d1.id, to: snap3)
try store.deleteDocument(id: d1.id)
let d1b = doc("线代习题（重导）", "h1")
check(try store.trashMergeTarget(snapshot: snap3) == d1b.id, "认出同一份 PDF 已重新导入")
_ = try store.restoreTrash(snapshot: snap3, remapDocumentId: d1b.id)
check(try store.exercises(documentId: d1b.id).count == 3, "题并入现有那篇（document_id 改写）")

print("— 关联为同一文档")
let d2 = doc("另一版", "h2")
let r2 = row(ok(input("第二版里的题"))!, doc: d2.id)
try store.upsertExercise(r2)
check(try store.mergeDocument(sourceId: d2.id, intoTargetId: d1b.id), "合并成功")
check(try store.exercise(id: r2.id)?.documentId == d1b.id, "题跟着挪到目标文档（没被级联删掉）")

// MARK: - 2026-10-11：章节 / 书上的作答 / 重判 / 筛选

print("— 章节：目录查页")
let toc = [
    ExerciseChapterNode(label: "前言", page: 0),
    ExerciseChapterNode(label: " 第一章 函数 ", page: 2, children: [
        ExerciseChapterNode(label: "1.1 映射", page: 3),
        ExerciseChapterNode(label: "1.2 极限", page: 8),
    ]),
    ExerciseChapterNode(label: "第二章 导数", page: nil, children: [   // 自己没落点：按第一个子项算
        ExerciseChapterNode(label: "2.1 定义", page: 15),
        ExerciseChapterNode(label: "2.2 法则", page: 20, children: [ExerciseChapterNode(label: "习题 2.2", page: 24)]),
    ]),
]
check(ExerciseChapter.path(page: 1, in: toc) == ["前言"], "第 2 页在「前言」")
check(ExerciseChapter.path(page: 2, in: toc) == ["第一章 函数"], "章开头、第一小节之前 → 停在章这一级（标题去空白）")
check(ExerciseChapter.path(page: 9, in: toc) == ["第一章 函数", "1.2 极限"], "落在 1.2")
check(ExerciseChapter.path(page: 16, in: toc) == ["第二章 导数", "2.1 定义"], "没落点的章按第一个子项起算")
check(ExerciseChapter.path(page: 30, in: toc) == ["第二章 导数", "2.2 法则", "习题 2.2"], "一直走到最深一级")
check(ExerciseChapter.path(page: 5, in: []) == [], "没目录 → 空")
check(ExerciseChapter.flatten(toc).count == 8 && ExerciseChapter.flatten(toc)[2] == ["第一章 函数", "1.1 映射"],
      "目录摊平：每项是完整路径、先序")
check(ExerciseChapter.clean([" a ", "", "  "]) == ["a"], "路径规整：去空白、丢空段")
check(LibraryStore.chapterPath(LibraryStore.chapterText(["第二章 导数", "2.3 \"引号\""])) == ["第二章 导数", "2.3 \"引号\""],
      "章节列 JSON 回环（含引号）")
check(LibraryStore.chapterText([]) == "" && LibraryStore.chapterPath("") == [], "空路径存空串")

print("— 章节：库读写 / 范围 / 树")
let d3 = doc("高数", "h3")
var c1 = row(ok(input("c1", number: "1"), seq: 0)!, doc: d3.id); c1.chapter = ["第一章 函数", "1.1 映射"]
var c2 = row(ok(input("c2", number: "2"), seq: 1)!, doc: d3.id); c2.chapter = ["第一章 函数", "1.2 极限"]; c2.page = 8
var c3 = row(ok(input("c3", number: "3"), seq: 2)!, doc: d3.id); c3.chapter = ["第一章 函数"]
var c4 = row(ok(input("c4", number: "4"), seq: 3)!, doc: d3.id); c4.page = 40
try store.upsertExercises([c1, c2, c3, c4])
check(try store.exercise(id: c1.id)?.chapter == ["第一章 函数", "1.1 映射"], "章节读回")
let cc = try store.exerciseChapterCounts().filter { $0.documentId == d3.id }
check(cc.count == 4 && cc.first { $0.chapter.isEmpty }?.count == 1, "按章节分组计数（含未分章节）")
check(cc.first { $0.chapter == ["第一章 函数", "1.2 极限"] }?.firstPage == 8, "每组带最早页码")
var stats3: [[String]: ExerciseChapterStat] = [:]
for r in cc { stats3[r.chapter] = ExerciseChapterStat(count: r.count, firstPage: r.firstPage) }
let sum3 = ExerciseSummary(total: 4, byDocument: [d3.id: 4], chapters: [d3.id: stats3])
check(sum3.count(.chapter(d3.id, ["第一章 函数"])) == 3, "章的数 = 它自己 + 各小节")
check(sum3.count(.chapter(d3.id, [])) == 1, "空路径范围只数没设章节的")
let tree = ExerciseChapterTree.build(stats3)
check(tree.count == 1 && tree[0].count == 3 && tree[0].children.map(\.label) == ["1.1 映射", "1.2 极限"],
      "建树：一级「第一章」3 道，下面两个小节按页排")
let e1 = Exercise(row: try store.exercise(id: c1.id)!)!, e3 = Exercise(row: try store.exercise(id: c3.id)!)!
let e4 = Exercise(row: try store.exercise(id: c4.id)!)!
check(ExerciseScope.chapter(d3.id, ["第一章 函数"]).includes(e1), "章范围含其下小节的题")
check(!ExerciseScope.chapter(d3.id, ["第一章 函数", "1.2 极限"]).includes(e1), "小节范围不含兄弟小节")
check(ExerciseScope.chapter(d3.id, []).includes(e4) && !ExerciseScope.chapter(d3.id, []).includes(e3), "未分章节范围")
check(!ExerciseScope.chapter("other", ["第一章 函数"]).includes(e1), "别的书的同名章不算")
let sc = ExerciseScope.chapter(d3.id, ["第一章 函数", "1.1: 冒号"])
check(ExerciseScope(rowID: sc.rowID) == sc, "章节范围键回环（名字里有冒号也行）")
check(ExerciseScope(rowID: ExerciseScope.chapter(d3.id, []).rowID) == .chapter(d3.id, []), "未分章节范围键回环")
try store.setExerciseChapter(ids: [c4.id], ["第三章"])
check(try store.exercise(id: c4.id)?.chapter == ["第三章"], "手动设章节")

print("— 错题本按书 / 按章展开")
try store.setExerciseWrong(id: c1.id, true)
try store.setExerciseWrong(id: c4.id, true)
let cw = try store.exerciseChapterCounts().filter { $0.documentId == d3.id }
check(cw.first { $0.chapter == ["第一章 函数", "1.1 映射"] }?.wrong == 1 && cw.first { $0.chapter == ["第一章 函数", "1.2 极限"] }?.wrong == 0,
      "章节计数带错题数")
var statsW: [[String]: ExerciseChapterStat] = [:]
for r in cw { statsW[r.chapter] = ExerciseChapterStat(count: r.count, firstPage: r.firstPage, wrong: r.wrong) }
let sumW = ExerciseSummary(total: 4, wrong: 2, byDocument: [d3.id: 4], chapters: [d3.id: statsW])
check(sumW.count(.wrongDocument(d3.id)) == 2, "一本书的错题数")
check(sumW.count(.wrongChapter(d3.id, ["第一章 函数"])) == 1 && sumW.count(.chapter(d3.id, ["第一章 函数"])) == 3,
      "一章的错题数（含小节），全部题数不受影响")
let mc = sumW.mistakeChapters(d3.id)
check(Set(mc.keys) == [["第一章 函数", "1.1 映射"], ["第三章"]] && mc.values.allSatisfy { $0.count == 1 },
      "错题本的章节分布：只留有错题的章节，数是错题数")
let wtree = ExerciseChapterTree.build(mc)
check(wtree.map(\.label) == ["第一章 函数", "第三章"] && wtree[0].count == 1 && wtree[0].children.map(\.label) == ["1.1 映射"],
      "错题本底下的章节树（按页排）")
let ew1 = Exercise(row: try store.exercise(id: c1.id)!)!, ew2 = Exercise(row: try store.exercise(id: c2.id)!)!
check(ExerciseScope.wrongChapter(d3.id, ["第一章 函数"]).includes(ew1) && !ExerciseScope.wrongChapter(d3.id, ["第一章 函数"]).includes(ew2),
      "错题本按章：只含这一章里在错题本的")
check(ExerciseScope.wrongDocument(d3.id).includes(ew1) && !ExerciseScope.wrongDocument("other").includes(ew1), "错题本按书")
for sc in [ExerciseScope.wrongDocument(d3.id), .wrongChapter(d3.id, ["第一章 函数", "1.1: 冒号"]), .wrongChapter(d3.id, [])] {
    check(ExerciseScope(rowID: sc.rowID) == sc, "错题范围键回环：\(sc.key)")
}
check(ExerciseScope(key: "wrong:all") == nil && ExerciseScope(key: "wrong:wrong") == nil && ExerciseScope(key: "wrong") == .wrong,
      "错题前缀只接书 / 章，「wrong」本身仍是错题本")
check(ExerciseScope.wrong.isMistakes && ExerciseScope.wrongChapter(d3.id, []).isMistakes && !ExerciseScope.chapter(d3.id, []).isMistakes
      && !ExerciseScope.all.isMistakes, "错题那一支（公用错题标签管的）")
check(ExerciseScope.wrongChapter(d3.id, ["x"]).documentId == d3.id, "错题范围也认得是哪本书（删书时标签跟着退）")

print("— 收藏按书 / 按章展开（同错题本）")
try store.setExerciseStarred(id: c2.id, true)
try store.setExerciseStarred(id: c4.id, true)
let cs = try store.exerciseChapterCounts().filter { $0.documentId == d3.id }
check(cs.first { $0.chapter == ["第一章 函数", "1.2 极限"] }?.starred == 1 && cs.first { $0.chapter == ["第一章 函数", "1.1 映射"] }?.starred == 0,
      "章节计数带收藏数")
var statsS: [[String]: ExerciseChapterStat] = [:]
for r in cs { statsS[r.chapter] = ExerciseChapterStat(count: r.count, firstPage: r.firstPage, wrong: r.wrong, starred: r.starred) }
let sumS = ExerciseSummary(total: 4, wrong: 2, starred: 2, byDocument: [d3.id: 4], chapters: [d3.id: statsS])
check(sumS.count(.starredDocument(d3.id)) == 2 && sumS.count(.starredChapter(d3.id, ["第一章 函数"])) == 1
      && sumS.count(.wrongChapter(d3.id, ["第一章 函数"])) == 1, "一本书 / 一章的收藏数（错题数不受影响）")
let sch = sumS.starredChapters(d3.id)
check(Set(sch.keys) == [["第一章 函数", "1.2 极限"], ["第三章"]] && sch.values.allSatisfy { $0.count == 1 },
      "收藏的章节分布：只留有收藏的章节，数是收藏数")
let es2 = Exercise(row: try store.exercise(id: c2.id)!)!, es1 = Exercise(row: try store.exercise(id: c1.id)!)!
check(ExerciseScope.starredChapter(d3.id, ["第一章 函数"]).includes(es2) && !ExerciseScope.starredChapter(d3.id, ["第一章 函数"]).includes(es1),
      "收藏按章：只含这一章里收藏了的")
check(ExerciseScope.starredDocument(d3.id).includes(es2) && !ExerciseScope.starredDocument("other").includes(es2), "收藏按书")
for sc in [ExerciseScope.starredDocument(d3.id), .starredChapter(d3.id, ["第一章 函数", "1.1: 冒号"]), .starredChapter(d3.id, [])] {
    check(ExerciseScope(rowID: sc.rowID) == sc, "收藏范围键回环：\(sc.key)")
}
check(ExerciseScope(key: "starred:all") == nil && ExerciseScope(key: "starred") == .starred
      && ExerciseScope(key: "starred:doc:" + d3.id) == .starredDocument(d3.id), "收藏前缀只接书 / 章，「starred」本身仍是收藏")
check(!ExerciseScope.starredChapter(d3.id, []).isMistakes && ExerciseScope.starredChapter(d3.id, ["x"]).documentId == d3.id,
      "收藏那一支在公用标签里换、认得是哪本书")

print("— 侧栏 / 平板抽屉的分组（ExerciseGroupNode，安卓模式1 逐条照抄）")
let gdocs: [(id: String, title: String)] = [("nodoc", "没题的书"), (d3.id, "书三")]
let groups = ExerciseGroupNode.build(sumS, documents: gdocs, title: { $0.key }, noChapter: "未分章节")
check(groups.map(\.scope) == [.all, .wrong, .starred, .document(d3.id)], "全部 / 错题本 / 收藏恒在，之后只列有题的书")
check(groups.map(\.count) == [4, 2, 2, 4] && groups[0].title == "all" && groups[3].title == "书三", "各行的数与名字")
check(groups[1].children.map(\.scope) == [.wrongDocument(d3.id)]
      && groups[1].children[0].children.map(\.title) == wtree.map(\.label), "错题本底下：有错题的书 → 错题章节树")
check(groups[1].children[0].children[0].children.map(\.scope) == [.wrongChapter(d3.id, ["第一章 函数", "1.1 映射"])],
      "错题本底下的章节是错题范围")
check(groups[2].children.map(\.scope) == [.starredDocument(d3.id)] && groups[2].children[0].count == 2
      && groups[2].children[0].children.map(\.title) == ["第一章 函数", "第三章"]
      && groups[2].children[0].children[0].children.map(\.scope) == [.starredChapter(d3.id, ["第一章 函数", "1.2 极限"])],
      "收藏底下：有收藏的书 → 收藏章节树，章节是收藏范围")
check(ExerciseGroupNode.build(sumW, documents: gdocs, title: { $0.key }, noChapter: "x")[2].children.isEmpty,
      "没有收藏 → 收藏那一行不展开")
try store.setExerciseStarred(id: c2.id, false)
try store.setExerciseStarred(id: c4.id, false)
let gnone = statsW[[]].map { $0.count > 0 } ?? false
check(groups[3].children.map(\.title) == ExerciseChapterTree.build(statsW).map(\.label) + (gnone ? ["未分章节"] : []),
      "书底下的章节树（有没设章节的题时末尾一行「未分章节」）")
let flat = ExerciseGroupNode.flatten(groups)
func countNodes(_ ns: [ExerciseGroupNode]) -> Int { ns.reduce(0) { $0 + 1 + countNodes($1.children) } }
check(flat.count == countNodes(groups) && flat[0].depth == 0 && flat[1].scope == .wrong && flat[2].depth == 1
      && flat[2].scope == .wrongDocument(d3.id) && flat[3].depth == 2, "摊平：先父后子、depth 是缩进层级")
check(ExerciseGroupNode.build(ExerciseSummary(), documents: gdocs, title: { $0.key }, noChapter: "x").isEmpty,
      "没有题 → 整段不出现")

print("— 书上的作答（source = mark）")
let m = ok(input("m", answer: "B", src: "book", number: "9"))!
let rm = row(m, doc: d3.id)
try store.upsertExercise(rm)
func mark(_ id: String, _ ans: String, _ c: Bool?) -> LibExerciseAttempt {
    LibExerciseAttempt(id: UUID().uuidString, exerciseId: id, answer: ans, correct: c, elapsedMs: 0, createdAt: .now,
                       source: LibExerciseAttempt.markSource)
}
try store.recordMarkedAttempts([mark(rm.id, "C", false)])
check(try store.exercise(id: rm.id)?.wrong == true, "书上答错 → 进错题本")
try store.recordMarkedAttempts([mark(rm.id, "B", true)])
let ma = try store.exerciseAttempts(exerciseId: rm.id)
check(ma.count == 1 && ma[0].answer == "B" && ma[0].source == "mark", "每道题书上的作答只留一条（重写替换）")
check(try store.exercise(id: rm.id)?.wrong == true, "书上改成对的也不自动出错题本")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: rm.id, answer: "A", correct: false,
                                                   elapsedMs: 100, createdAt: .now))
let ms = try store.exerciseAttemptStats()[rm.id]
check(ms?.attempts == 2 && ms?.markedAnswer == "B" && ms?.markedCorrect == true, "统计：总次数含书上那条，单独给出书上的作答")
check(ms?.lastAnswer == "A", "最近一次只算 App 里练的")
var laterMark = mark(rm.id, "D", false); laterMark.createdAt = Date(timeIntervalSinceNow: 5)
try store.recordMarkedAttempts([laterMark])
check(try store.exerciseAttemptStats()[rm.id]?.lastAnswer == "A", "书上的作答后来重导，也不盖过 App 里的练习")
try store.deleteMarkedAttempt(exerciseId: rm.id)
check(try store.exerciseAttempts(exerciseId: rm.id).map(\.source) == [""], "撤掉书上的作答，App 里的练习记录不动")

print("— 答案后补：重判")
let q = ok(input("q", number: "10"))!          // 先没有答案
let rq = row(q, doc: d3.id)
try store.upsertExercise(rq)
try store.recordMarkedAttempts([mark(rq.id, "A", nil)])
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: rq.id, answer: "C", correct: nil,
                                                   elapsedMs: 0, createdAt: Date(timeIntervalSinceNow: 1)))
check(try store.exercise(id: rq.id)?.wrong == false, "没答案时作答都没法判，不进错题本")
var withAns = Exercise(row: try store.exercise(id: rq.id)!)!
withAns.payload.answer = ["C"]
let changed = try store.rejudgeExerciseAttempts(exerciseId: rq.id) { withAns.judge(Set($0.map { String($0) })) }
let rj = try store.exerciseAttempts(exerciseId: rq.id)
check(changed == 2 && rj.first { $0.answer == "A" }?.correct == false && rj.first { $0.answer == "C" }?.correct == true,
      "补上答案 C：书上的 A 判错、练习的 C 判对")
check(try store.exercise(id: rq.id)?.wrong == true, "重判出错 → 进错题本")
withAns.payload.answer = ["A"]
_ = try store.rejudgeExerciseAttempts(exerciseId: rq.id) { withAns.judge(Set($0.map { String($0) })) }
check(try store.exercise(id: rq.id)?.wrong == true, "答案改成 A 后 A 变对，错题本不自动出（只能手动）")
check(try store.rejudgeExerciseAttempts(exerciseId: rq.id) { withAns.judge(Set($0.map { String($0) })) } == 0,
      "答案没变再重判：一条不改")

print("— 校验：user_answer / chapter")
check(ok(input("u", answer: "B", src: "book")).map { $0.userAnswer } == .some(nil), "没给 user_answer → nil")
var ui = input("u"); ui.userAnswer = "c, a"
check(ok(ui)?.userAnswer == ["A", "C"], "user_answer 规整排序")
ui.userAnswer = " "
check(ok(ui)?.userAnswer == [], "user_answer 空串 = 撤掉")
ui.userAnswer = "E"
check(reason(ui)?.contains("user_answer key E") == true, "user_answer 不在选项里退回")
var ci = input("c"); ci.chapter = [" 第一章 ", ""]
check(ok(ci)?.chapter == ["第一章"], "chapter 规整")
check(ok(input("c"))?.chapter == nil, "没给 chapter → nil（让 App 按目录自动定）")

print("— 筛选")
let fe = Exercise(row: try store.exercise(id: rq.id)!)!
check(ExerciseFilter.unanswered.includes(fe, stats: nil)
      && !ExerciseFilter.unanswered.includes(fe, stats: ExerciseAttemptStats(attempts: 1)), "没做过")
check(ExerciseFilter.all.includes(fe, stats: ExerciseAttemptStats(attempts: 2))
      && ExerciseFilter.allCases == [.all, .unanswered, .lastWrong]
      && ExerciseFilter(rawValue: 2) == nil && ExerciseFilter(rawValue: 3) == nil && ExerciseFilter(rawValue: 4) == .lastWrong,
      "全部 / 只看没做过 / 重做上次做错的 = 0 / 1 / 4（老平板发来的 2 错题 / 3 收藏不认）")

print("— 做过的题显示以前的作答")
var pe = Exercise(row: try store.exercise(id: rm.id)!)!      // 答案 B
let peStats = try store.exerciseAttemptStats()[rm.id]
let pa = pe.earlierAnswer(peStats)
check(pa?.chosen == ["A"] && pa?.correct == false, "App 里练过：显示最近一次（A，错）")
if case .practiced(let at)? = pa?.from { check(at != nil, "带那次的时间") } else { check(false, "来源应是 App 里练的") }
let bookOnly = ExerciseAttemptStats(attempts: 1, markedAnswer: "B", markedCorrect: true)
check(pe.earlierAnswer(bookOnly).map { $0.chosen == ["B"] && $0.correct == true && $0.from == .book } == true,
      "App 里没练过：拿书上的作答")
check(pe.earlierAnswer(nil) == nil, "没做过 → nil（等着作答）")
check(pe.earlierAnswer(ExerciseAttemptStats(attempts: 1, markedAnswer: "?", lastAnswer: "")) == nil, "作答串认不出 → 当没做过")
pe.payload.answer = ["A"]
check(pe.earlierAnswer(peStats)?.correct == true, "答案后来改了：按现在的答案判")
pe.payload.answer = []
check(pe.earlierAnswer(peStats).map { $0.correct == nil } == true, "题目没答案：显示作答、不判对错")
check(pe.earlierAnswer(ExerciseAttemptStats(attempts: 1, lastAnswer: "AC"))?.chosen == ["A", "C"], "多选的作答串拆回几个键")

print("— 补列迁移（开发包里已建过 v20 表的库）")
let oldWS = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ex_old_\(UInt64.random(in: 0..<1_000_000))")
try! FileManager.default.createDirectory(at: oldWS.appendingPathComponent("UniReader"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: oldWS) }
do {
    let raw = try SQLiteDB(path: oldWS.appendingPathComponent("UniReader/library.sqlite").path)
    try raw.exec("""
    CREATE TABLE exercise (id TEXT PRIMARY KEY, document_id TEXT, page INTEGER, seq INTEGER NOT NULL DEFAULT 0,
      kind INTEGER NOT NULL DEFAULT 0, number TEXT NOT NULL DEFAULT '', section TEXT NOT NULL DEFAULT '',
      payload BLOB NOT NULL, starred INTEGER NOT NULL DEFAULT 0, wrong INTEGER NOT NULL DEFAULT 0,
      source TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE exercise_attempt (id TEXT PRIMARY KEY, exercise_id TEXT NOT NULL, answer TEXT NOT NULL,
      correct INTEGER, elapsed_ms INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
    """)
    raw.close()
}
let oldStore = try LibraryStore(workspaceFolder: oldWS)
let od = try! oldStore.findOrCreate(hash: "o1", title: "旧", pageCount: 5, path: "PDFs/o1.pdf", isRelative: false).document
var orow = row(ok(input("o"))!, doc: od.id); orow.chapter = ["补列后"]
try oldStore.upsertExercise(orow)
check(try oldStore.exercise(id: orow.id)?.chapter == ["补列后"], "exercise.chapter 补上了、能写能读")
try oldStore.recordMarkedAttempts([mark(orow.id, "A", nil)])
check(try oldStore.exerciseAttempts(exerciseId: orow.id).first?.source == "mark", "exercise_attempt.source 补上了")
var oa = mark(orow.id, "A", nil); oa.source = ""; oa.ink = Data("{}".utf8); oa.judgedBy = "self"; oa.feedback = "f"
try oldStore.recordExerciseAttempt(oa)
let oaBack = try oldStore.exerciseAttempt(id: oa.id)
check(oaBack?.ink == Data("{}".utf8) && oaBack?.judgedBy == "self" && oaBack?.feedback == "f",
      "v21 三列（ink / judged_by / feedback）在老库上补上了、能写能读")
try oldStore.setExerciseNote(id: orow.id, "老库补列")
check(try oldStore.exercise(id: orow.id)?.note == "老库补列", "v22 exercise.note 在老库上补上了、能写能读")
oldStore.close()

// MARK: - v21 填空 / 主观题（`EXERCISE-PLAN.md §11`）

func freeInput(_ stem: String, type: String?, answer: String? = nil, src: String? = nil,
               blanks: [(answer: String?, accept: [String])]? = nil, userAnswer: String? = nil,
               userBlanks: [String]? = nil, opts: [(String?, String?)] = [], number: String? = nil) -> ExerciseInput {
    var i = input(stem, opts, type: type, answer: answer, src: src, number: number)
    i.blanks = blanks; i.userAnswer = userAnswer; i.userBlanks = userBlanks
    return i
}

print("— v21 题型")
check(ExerciseKind(wire: "fill") == .fill && ExerciseKind(wire: " Subjective ") == .subjective, "fill / subjective 认得")
check(ExerciseKind.fill.rawValue == 3 && ExerciseKind.subjective.rawValue == 4, "库里 3 填空 / 4 主观题（2 留给判断题）")
check(!ExerciseKind.fill.isChoice && ExerciseKind.multiple.isChoice, "isChoice")
var k2 = row(ok(input("x"))!, doc: od.id); k2.kind = 2
check(Exercise(row: k2) == nil, "不认识的题型（2）照旧跳过")

print("— v21 填空校验")
let fillD = ok(freeInput("$f'(1)=$____，$f'(2)=$____", type: "fill", src: "book",
                         blanks: [(answer: "2", accept: ["2.0", " 2 "]), (answer: "4", accept: [])]))
check(fillD?.kind == .fill, "填空题通过")
check(fillD?.payload.blanks == 2 && fillD?.payload.answer == ["2", "4"], "空数 + 每空参考答案")
check(fillD?.payload.accept == [["2.0"], []], "另外认可的写法：去空白、去掉与参考答案相同的")
check(fillD?.payload.options.isEmpty == true, "填空没有选项")
check(ok(freeInput("x", type: nil, blanks: [(answer: nil, accept: [])]))?.kind == .fill, "没写题型、给了 blanks → 填空")
let fillNo = ok(freeInput("x", type: "fill", blanks: [(answer: nil, accept: []), (answer: "", accept: [])]))
check(fillNo?.payload.blanks == 2 && fillNo?.payload.answer == [] && fillNo?.payload.answerSource == nil,
      "填空没答案：只记空数")
check(reason(freeInput("x", type: "fill"))?.contains("needs blanks") == true, "填空没给 blanks 退回")
check(reason(freeInput("x", type: "fill", blanks: [(answer: "1", accept: [])], opts: [("A", "1"), ("B", "2")]))?
        .contains("no options") == true, "填空带选项退回")
check(reason(freeInput("x", type: "fill", src: "book", blanks: [(answer: "1", accept: []), (answer: nil, accept: [])]))?
        .contains("every blank or for none") == true, "只给了一部分空的答案退回")
check(reason(freeInput("x", type: "fill", answer: "1", src: "book", blanks: [(answer: nil, accept: [])]))?
        .contains("blanks[].answer") == true, "填空把答案写在 answer 里退回")
check(reason(freeInput("x", type: "fill", blanks: [(answer: "1", accept: [])]))?.contains("answer_source") == true,
      "填空有答案没写来源退回")
check(reason(freeInput("x", type: "fill", blanks: [(answer: nil, accept: ["1"])]))?.contains("accept needs") == true,
      "只给 accept 不给答案退回")
check(reason(freeInput("x", type: "fill", blanks: Array(repeating: (answer: nil, accept: []), count: 21)))?
        .contains("at most 20") == true, "21 个空退回")
check(reason(freeInput("x", type: "single", blanks: [(answer: nil, accept: [])], opts: [("A", "1"), ("B", "2")]))?
        .contains("only for fill") == true, "选择题带 blanks 退回")
let fillU = ok(freeInput("x", type: "fill", blanks: [(answer: nil, accept: []), (answer: nil, accept: [])],
                         userBlanks: [" 3 ", ""]))
check(fillU?.userResponse == ExerciseResponse(blanks: ["3", ""]) && fillU?.userMark == fillU?.userResponse,
      "user_blanks → 书上的作答（去空白，空的空留空串）")
check(ok(freeInput("x", type: "fill", blanks: [(answer: nil, accept: [])], userBlanks: [" "]))?.userResponse
        .map { $0.isEmpty(.fill) } == true, "user_blanks 全空 = 撤掉")
check(reason(freeInput("x", type: "fill", blanks: [(answer: nil, accept: [])], userBlanks: ["1", "2"]))?
        .contains("user_blanks has 2") == true, "user_blanks 个数不对退回")
check(reason(freeInput("x", type: "fill", blanks: [(answer: nil, accept: [])], userAnswer: "1"))?
        .contains("user_blanks") == true, "填空把书上作答写在 user_answer 里退回")

print("— v21 主观题校验")
let subD = ok(freeInput("证明 $\\sqrt2$ 是无理数。", type: "subjective", answer: " 反证法：设 $\\sqrt2=p/q$… ", src: "book",
                        userAnswer: " 设它是有理数 "))
check(subD?.kind == .subjective && subD?.payload.answer == ["反证法：设 $\\sqrt2=p/q$…"], "主观题：参考答案去首尾空白")
check(subD?.userResponse == ExerciseResponse(text: "设它是有理数"), "主观题书上的作答 = 文字")
check(ok(freeInput("论述", type: "subjective"))?.payload.answer == [], "主观题可以没有参考答案")
check(reason(freeInput("论述", type: "subjective", opts: [("A", "1"), ("B", "2")]))?.contains("no options") == true,
      "主观题带选项退回")
check(reason(freeInput("论述", type: "subjective", answer: "x"))?.contains("answer_source") == true, "参考答案没写来源退回")
check(reason(freeInput("论述", type: "subjective", blanks: [(answer: nil, accept: [])]))?.contains("only for fill") == true,
      "主观题带 blanks 退回")
check(ok(freeInput("论述", type: "subjective", userAnswer: " "))?.userResponse.map { $0.isEmpty(.subjective) } == true,
      "主观题 user_answer 空串 = 撤掉")

print("— v21 payload 编码不影响老题")
let choiceJSON = String(data: good!.payload.data(), encoding: .utf8) ?? ""
check(!choiceJSON.contains("blanks") && !choiceJSON.contains("accept"), "选择题 payload 不多出新键")
let fillJSON = String(data: fillD!.payload.data(), encoding: .utf8) ?? ""
check(fillJSON.contains("\"blanks\":2") && fillJSON.contains("\"accept\""), "填空 payload 带空数与 accept")
check(fillNo.map { String(data: $0.payload.data(), encoding: .utf8)?.contains("accept") == false } == true,
      "accept 全空不写这个键")
let fillBack = try JSONDecoder().decode(ExercisePayload.self, from: fillD!.payload.data())
check(fillBack == fillD!.payload, "填空 payload 编解码回环")

print("— v21 填空规整与判题")
check(Exercise.normalizeBlank(" １／２ ") == "1/2", "全角转半角、去空白")
check(Exercise.normalizeBlank("$\\dfrac{1}{2}$") == Exercise.normalizeBlank("\\frac {1}{2}"), "\\dfrac = \\frac，去 $ 与空白")
check(Exercise.normalizeBlank("\\left( x \\right)。") == "(x)", "去 \\left \\right 与句末标点")
check(Exercise.normalizeBlank("x") != Exercise.normalizeBlank("X"), "大小写不并（宁可交给人判）")
let fillE = Exercise(row: row(fillD!, doc: od.id))!
check(fillE.blankCount == 2 && fillE.hasAnswer, "空数 / 有答案")
check(fillE.autoJudge(ExerciseResponse(blanks: ["2", "4"])) == true, "每空都对 → 判对")
check(fillE.autoJudge(ExerciseResponse(blanks: ["2.0", " 4 "])) == true, "accept 里的写法、多了空白 → 判对")
check(fillE.autoJudge(ExerciseResponse(blanks: ["2", "5"])) == nil, "有一空对不上 → 交给人判（nil，不判错）")
check(fillE.blankMatches(["2", "5"]) == [true, false], "逐空对不对得上")
check(fillE.blankMatches(["2"]) == [true, false], "少填的空 = 对不上")
check(fillE.autoJudge(ExerciseResponse(ink: ExerciseInk(strokes: [.init(width: 2, points: [[1, 2, 0.5]])]))) == nil,
      "只写在画板上 → 交给人判")
check(fillE.judge(["A"]) == nil, "选择题的 judge 不管填空")
let fillNoE = Exercise(row: row(fillNo!, doc: od.id))!
check(fillNoE.blankCount == 2 && !fillNoE.hasAnswer && fillNoE.autoJudge(ExerciseResponse(blanks: ["1", "2"])) == nil,
      "填空没答案：空数照旧、判不了")
let subE = Exercise(row: row(subD!, doc: od.id))!
check(subE.referenceText == "反证法：设 $\\sqrt2=p/q$…" && subE.autoJudge(ExerciseResponse(text: "反证法")) == nil,
      "主观题：参考答案，程序不判")
check(ex.autoJudge(ExerciseResponse(keys: ["C"])) == ex.judge(["C"]), "选择题 autoJudge = judge")

print("— v21 作答编解码")
let rf = ExerciseResponse(blanks: ["2", "a/b \"q\""])
check(ExerciseResponse.decode(.fill, answer: rf.answerString(.fill)) == rf, "填空作答 JSON 回环（含引号、斜杠）")
check(rf.answerString(.fill).contains("a/b"), "斜杠不转义")
check(ExerciseResponse.decode(.fill, answer: "7").blanks == ["7"], "认不出的填空串当成一空")
check(ExerciseResponse.decode(.subjective, answer: "多行\n正文").text == "多行\n正文", "主观题原文")
check(ExerciseResponse.decode(.multiple, answer: "AC").keys == ["A", "C"], "选择题照旧")
check(ExerciseResponse(blanks: ["", " "]).isEmpty(.fill) && !ExerciseResponse(blanks: ["", "1"]).isEmpty(.fill), "填空空不空")
let inkOne = ExerciseInk(height: 400, strokes: [.init(width: 2.4, points: [[10, 20, 0.5], [11.5, 21, 0.6]])])
check(ExerciseResponse(ink: inkOne).isEmpty(.subjective) == false && ExerciseResponse().isEmpty(.subjective), "只有手写也算作答")
check(ExerciseInk.decode(inkOne.data()) == inkOne, "手写 JSON 回环")
check(ExerciseInk.decode(Data("{}".utf8)) == nil && ExerciseInk.decode(nil) == nil
        && ExerciseInk.decode(ExerciseInk().data()) == nil, "坏数据 / 没笔画 → nil")
check(rf.summary(.fill) == "2 / a/b \"q\"" && ExerciseResponse(blanks: ["", "1"]).summary(.fill) == "— / 1", "填空摘要")
check(ExerciseResponse(text: "a\n  b").summary(.subjective) == "a b" && ExerciseResponse(ink: inkOne).summary(.subjective) == "",
      "主观题摘要并成一行；只有手写 = 空串")

print("— v21 库：作答 / 自己判 / Agent 判 / 重判")
let dv = doc("v21 习题", "hv21")
let fillRow = row(fillD!, doc: dv.id); try store.upsertExercise(fillRow)
let subRow = row(subD!, doc: dv.id); try store.upsertExercise(subRow)
func attempt(_ ex: String, _ answer: String, _ c: Bool?, ink: Data? = nil, at: Date = .now) -> LibExerciseAttempt {
    LibExerciseAttempt(id: UUID().uuidString, exerciseId: ex, answer: answer, correct: c, elapsedMs: 10, createdAt: at, ink: ink)
}
let fa1 = attempt(fillRow.id, ExerciseResponse(blanks: ["2", "4"]).answerString(.fill), true, at: Date(timeIntervalSinceNow: -30))
let fa2 = attempt(fillRow.id, ExerciseResponse(blanks: ["2", "5"]).answerString(.fill), nil, at: Date(timeIntervalSinceNow: -20))
try store.recordExerciseAttempt(fa1); try store.recordExerciseAttempt(fa2)
check(try store.exercise(id: fillRow.id)?.wrong == false, "待判的作答不进错题本")
let sa1 = attempt(subRow.id, "设它是有理数", nil, ink: inkOne.data())
try store.recordExerciseAttempt(sa1)
check(ExerciseInk.decode(try store.exerciseAttempt(id: sa1.id)?.ink) == inkOne, "手写落库读回")
var fst = try store.exerciseAttemptStats()
check(fst[subRow.id]?.ungraded == 1 && fst[fillRow.id]?.ungraded == 1, "还没判的次数")
check(fst[fillRow.id]?.lastId == fa2.id && fst[fillRow.id]?.lastPracticedCorrect == nil
        && fst[fillRow.id]?.lastJudgedBy == "", "最近一次的 id / 库里的对错 / 谁判的")

check(try store.judgeExerciseAttempt(id: fa2.id, correct: false, by: ExerciseJudge.bySelf) == fillRow.id, "自己判 → 返回所属的题")
var fa2b = try store.exerciseAttempt(id: fa2.id)
check(fa2b?.correct == false && fa2b?.judgedBy == "self", "自己判错：对错 + 谁判的")
check(try store.exercise(id: fillRow.id)?.wrong == true, "判错 → 进错题本")
try store.judgeExerciseAttempt(id: fa2.id, correct: true, by: ExerciseJudge.byAgent, feedback: "**等价**写法，算对")
fa2b = try store.exerciseAttempt(id: fa2.id)
check(fa2b?.correct == true && fa2b?.judgedBy == "agent" && fa2b?.feedback == "**等价**写法，算对", "Agent 后判覆盖自己判，带评语")
check(try store.exercise(id: fillRow.id)?.wrong == true, "判对不移出错题本（拍板 ③）")
try store.judgeExerciseAttempt(id: fa2.id, correct: false, by: ExerciseJudge.bySelf)
fa2b = try store.exerciseAttempt(id: fa2.id)
check(fa2b?.judgedBy == "self" && fa2b?.feedback == "**等价**写法，算对", "再改判：评语不动")
check(try store.judgeExerciseAttempt(id: "nope", correct: true, by: "self") == nil, "没有这一条 → nil")

// 答案改了：程序判的那条重判，人判过的不动
var fillE2 = Exercise(row: try store.exercise(id: fillRow.id)!)!
fillE2.payload.answer = ["2", "5"]; fillE2.payload.accept = nil
let rjFill = try store.rejudgeExerciseAttempts(exerciseId: fillRow.id) {
    fillE2.autoJudge(ExerciseResponse.decode(.fill, answer: $0))
}
check(rjFill == 1, "只重判程序判的那条")
check(try store.exerciseAttempt(id: fa1.id)?.correct == nil, "原来全对、答案改了对不上 → 待判")
check(try store.exerciseAttempt(id: fa2.id)?.correct == false, "自己判过的不重判（仍是错）")

fst = try store.exerciseAttemptStats()
check(fst[fillRow.id]?.lastPracticedCorrect == false && fst[fillRow.id]?.lastJudgedBy == "self", "统计跟着判定变")
let fillEx = Exercise(row: try store.exercise(id: fillRow.id)!)!
let er = fillEx.earlierResponse(fst[fillRow.id])
check(er?.attemptId == fa2.id && er?.response.blanks == ["2", "5"] && er?.correct == false && er?.judgedBy == "self",
      "以前的作答：App 里练的最近一次，对错用库里的")
check(fillEx.earlierAnswer(fst[fillRow.id]) == nil, "填空不走选择题那条")
check(ex.earlierResponse(st[ra.id]) == nil, "选择题不走这条")

try store.recordMarkedAttempts([LibExerciseAttempt(id: UUID().uuidString, exerciseId: subRow.id, answer: "书上写的",
                                                   correct: nil, elapsedMs: 0, createdAt: .now, source: "mark")])
let subEx = Exercise(row: subRow)!
var sst = try store.exerciseAttemptStats()[subRow.id]
check(sst?.markedId != nil && sst?.markedAnswer == "书上写的", "书上的作答 id")
check(subEx.earlierResponse(sst)?.from == .practiced(sa1.createdAt) || subEx.earlierResponse(sst)?.attemptId == sa1.id,
      "主观题：App 里练过 → 显示练的那次")
sst?.lastId = nil; sst?.lastAnswer = nil
check(subEx.earlierResponse(sst).map { $0.from == .book && $0.response.text == "书上写的" } == true, "没练过 → 书上的作答")

print("— v21 作答一览（MCP list_exercise_attempts）")
let pageAll = try store.exerciseAttemptPage(documentId: dv.id)
check(pageAll.total >= 4 && pageAll.rows.first.map { $0.createdAt >= pageAll.rows.last!.createdAt } == true, "新的在前")
let pageOpen = try store.exerciseAttemptPage(documentId: dv.id, ungradedOnly: true)
check(Set(pageOpen.rows.map(\.exerciseId)) == [fillRow.id, subRow.id] && pageOpen.rows.allSatisfy { $0.correct == nil },
      "只要还没判的填空 / 主观题（选择题没答案的不列）")
check(try store.exerciseAttemptPage(exerciseIds: [subRow.id]).total == 2, "按题列")
check(try store.exerciseAttemptPage(exerciseIds: []).total == 0, "空的 id 表 → 空")
check(try store.exerciseAttemptPage(prefix: String(sa1.id.prefix(8)).lowercased()).rows.map(\.id) == [sa1.id], "按 8 位前缀认（不分大小写）")
check(try store.exerciseAttemptPage(documentId: dv.id, limit: 1).rows.count == 1, "分页")

print("— v21 update 的起点还原")
let backF = ExerciseImport.input(from: fillE)
check(backF.blanks?.count == 2 && backF.blanks?[0].answer == "2" && backF.blanks?[0].accept == ["2.0"] && backF.answer == nil,
      "填空还原成 blanks（参考答案 + accept），answer 留空")
if case .success(let d) = ExerciseImport.validate(backF, seq: 0) { check(d.payload == fillE.payload, "还原后再校验 = 原样") }
else { check(false, "还原后再校验 = 原样") }
let backS = ExerciseImport.input(from: subE)
check(backS.answer == subE.referenceText && backS.blanks == nil, "主观题还原：answer = 参考答案")

// MARK: - v22 题目笔记 + 重做上次做错的（`EXERCISE-PLAN.md §12`）

print("— v22 题目笔记")
let dn = doc("笔记书", "n1")
var nrow = row(ok(input("笔记题", answer: "B", src: "book", number: "8"))!, doc: dn.id)
check(Exercise(row: nrow)?.note == "", "没写笔记 = 空串")
nrow.note = "新建时带的笔记"
try store.upsertExercise(nrow)
check(try store.exercise(id: nrow.id)?.note == "新建时带的笔记", "新建一道题时 note 写得进去")
var nrow2 = nrow; nrow2.note = "重导不该冲掉"; nrow2.section = "改了题组"
try store.upsertExercise(nrow2)
check(try store.exercise(id: nrow.id).map { $0.note == "新建时带的笔记" && $0.section == "改了题组" } == true,
      "已有的题重导：内容更新、笔记不动（同收藏 / 错题是用户状态）")
let nBefore = try store.exercise(id: nrow.id)!.updatedAt
try store.setExerciseNote(id: nrow.id, "**易错**：$f'(x)=2x$", at: nBefore.addingTimeInterval(5))
let nBack = try store.exercise(id: nrow.id)!
check(nBack.note == "**易错**：$f'(x)=2x$" && nBack.updatedAt > nBefore, "setExerciseNote 写笔记并改 updated_at（离线镜像按它取新）")
let ne = Exercise(row: nBack)!
check(ne.note == nBack.note && ne.toRow().note == nBack.note, "Exercise ↔ 库行带着笔记")
try store.setExerciseNote(id: nrow.id, "")
check(try store.exercise(id: nrow.id)?.note == "", "空串 = 删掉笔记")

print("— v22 上一次的结果是错的（重做上次做错的）")
let lw = Exercise(row: nBack)!     // 单选，答案 B
check(!lw.lastResultWrong(nil), "没做过 → 不算")
check(lw.lastResultWrong(ExerciseAttemptStats(attempts: 1, wrong: 1, lastAnswer: "A")), "最近一次选 A（错）→ 算")
check(!lw.lastResultWrong(ExerciseAttemptStats(attempts: 2, correct: 1, wrong: 1, lastAnswer: "B")),
      "错过、最近一次答对 → 不算（做对一次就不用再做）")
check(lw.lastResultWrong(ExerciseAttemptStats(attempts: 2, correct: 1, wrong: 1, lastAnswer: "C")),
      "答对过、最近一次又错 → 算（用户 2026-10-27 选的「最近一次是错的」）")
check(lw.lastResultWrong(ExerciseAttemptStats(attempts: 1, markedAnswer: "A", markedCorrect: false)), "只有书上的作答、错 → 算")
check(!lw.lastResultWrong(ExerciseAttemptStats(attempts: 2, markedAnswer: "A", markedCorrect: false, lastAnswer: "B")),
      "书上错、App 里练对了 → 不算（同练习页：App 里最近一次优先）")
var lwNo = lw; lwNo.payload.answer = []
check(!lwNo.lastResultWrong(ExerciseAttemptStats(attempts: 1, lastAnswer: "A")), "题目没答案（没法判）→ 不算")
var lwNow = lw; lwNow.payload.answer = ["A"]
check(!lwNow.lastResultWrong(ExerciseAttemptStats(attempts: 1, wrong: 1, lastAnswer: "A")), "答案后来改了：按现在的答案判（同练习页）")
let subLW = Exercise(row: row(ok(ExerciseInput(page: 0, type: "subjective", number: nil, section: nil, stem: "证明 $\\sqrt2$ 无理",
                                                options: [], answer: "反证", answerSource: "book", explanation: nil,
                                                region: nil, figure: nil))!, doc: dn.id))!
check(subLW.lastResultWrong(ExerciseAttemptStats(attempts: 1, wrong: 1, lastAnswer: "x", lastId: "a1", lastPracticedCorrect: false)),
      "主观题判了错 → 算")
check(!subLW.lastResultWrong(ExerciseAttemptStats(attempts: 1, lastAnswer: "x", lastId: "a1", lastPracticedCorrect: nil)),
      "主观题还没判 → 不算错")
check(!subLW.lastResultWrong(ExerciseAttemptStats(attempts: 2, lastAnswer: "x", lastId: "a2", lastPracticedCorrect: true)),
      "主观题最近一次判了对 → 不算")
check(subLW.lastResultWrong(ExerciseAttemptStats(attempts: 1, markedAnswer: "y", markedCorrect: false, markedId: "m1")),
      "主观题只有书上的作答、判了错 → 算")
check(ExerciseFilter.lastWrong.includes(lw, stats: ExerciseAttemptStats(attempts: 1, wrong: 1, lastAnswer: "A"))
      && !ExerciseFilter.lastWrong.includes(lw, stats: nil)
      && !ExerciseFilter.lastWrong.includes(lw, stats: ExerciseAttemptStats(attempts: 1, correct: 1, lastAnswer: "B")),
      "筛选 lastWrong = 上一次的结果是错的")
// 库里真记几次作答再取统计：错 → 对 → 错，最近一次错
let lwRow = try store.exercise(id: nrow.id)!
for (k, ans) in ["A", "B", "D"].enumerated() {
    try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: lwRow.id, answer: ans,
                                                       correct: ans == "B", elapsedMs: 0,
                                                       createdAt: Date().addingTimeInterval(Double(k)), source: ""))
}
check(lw.lastResultWrong(try store.exerciseAttemptStats()[lwRow.id]), "库里 错 → 对 → 错：最近一次错 → 算")
try store.recordExerciseAttempt(LibExerciseAttempt(id: UUID().uuidString, exerciseId: lwRow.id, answer: "B", correct: true,
                                                   elapsedMs: 0, createdAt: Date().addingTimeInterval(10), source: ""))
check(!lw.lastResultWrong(try store.exerciseAttemptStats()[lwRow.id]), "再答对一次 → 不算了（下次重做就不在里面）")

print("— 打开一组题停在第几道（接着上次做的往下，§13）")
let rsQ = (1...6).map { i -> Exercise in var e = lw; e.id = "rsQ\(i)"; return e }
let rsT0 = Date(timeIntervalSince1970: 1_800_000_000)
func rsDone(_ sec: Double) -> ExerciseAttemptStats {
    ExerciseAttemptStats(attempts: 1, correct: 1, lastAnswer: "B", lastAt: rsT0.addingTimeInterval(sec))
}
let rsBook = ExerciseAttemptStats(attempts: 1, markedAnswer: "A", markedCorrect: false)
check(Exercise.resumeIndex([], stats: [:]) == 0, "一道题都没有 → 0")
check(Exercise.resumeIndex(rsQ, stats: [:]) == 0, "一道都没做过 → 第 1 题")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ1": rsDone(1), "rsQ2": rsDone(2), "rsQ3": rsDone(3)]) == 3,
      "按顺序做完前 3 道 → 第 4 题")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ1": rsDone(1), "rsQ2": rsDone(2), "rsQ4": rsDone(4)]) == 4,
      "跳过第 3 题、最近做的是第 4 题 → 第 5 题（不回头找跳过的）")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ4": rsDone(9), "rsQ5": rsDone(1), "rsQ6": rsDone(2)]) == 0,
      "最近做的那道后面都做过了 → 从头找第一道没做过的")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ1": rsDone(1), "rsQ5": rsDone(5), "rsQ6": rsDone(6),
                                       "rsQ4": rsDone(3)]) == 1,
      "最近做的是最后一道 → 从头找（第 2 题）")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ2": rsDone(5), "rsQ3": rsBook]) == 3,
      "书上已有作答的算做过（同「只看没做过」）→ 跳过第 3 题，停第 4 题")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ1": rsBook, "rsQ2": rsBook]) == 2,
      "只有书上的作答、App 里没练过 → 从头找第一道没做过的")
check(Exercise.resumeIndex(rsQ, stats: Dictionary(uniqueKeysWithValues: rsQ.enumerated().map { ($1.id, rsDone(Double($0))) })) == 0,
      "全都做过 → 第 1 题")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ2": rsDone(7), "rsQ4": rsDone(7)]) == 4,
      "两道时间一样 → 取排在后面的那道（停第 5 题）")
check(Exercise.resumeIndex(rsQ, stats: ["rsQ3": rsDone(2), "rsQ5": rsDone(8), "rsQ6": rsDone(1)]) == 0,
      "最近做的是第 5 题、第 6 题也做过 → 从头找（第 1 题）")

// MARK: - 2026-10-31：不分章节的书（`EXERCISE-PLAN.md §14`）

print("— 不分章节的书：导入时要不要按目录自动分")
// 用上面那份 `toc`：第 1 页（0 起 0）起就在「前言」里；目录管不到的页只有拿空目录模拟
let lateToc = [ExerciseChapterNode(label: "第一章", page: 10)]   // 第 10 页（0 起）之前的页目录管不到
typealias Ex = (page: Int?, chapter: [String])
let flatBook: [Ex] = [(5, []), (9, [])]
check(ExerciseChapter.bookIsFlat(flatBook, toc: toc), "有题、都没章节、目录本来能分 → 不分章节的书")
check(!ExerciseChapter.bookIsFlat([], toc: toc), "一道题都没有 → 不算（新书）")
check(!ExerciseChapter.bookIsFlat([(5, []), (9, ["第一章 函数", "1.2 极限"])], toc: toc), "有一道带章节 → 不算")
check(!ExerciseChapter.bookIsFlat(flatBook, toc: []), "没目录 → 不算（反正分不出来）")
check(!ExerciseChapter.bookIsFlat([(2, []), (4, [])], toc: lateToc), "题都在目录管不到的页上 → 不算（不是用户选的不分）")
check(ExerciseChapter.bookIsFlat([(2, []), (12, [])], toc: lateToc), "有一道落在目录里 → 算")
check(!ExerciseChapter.bookIsFlat([(nil, [])], toc: toc), "不知道在哪页的题 → 不算")
check(ExerciseChapter.usesTOC(.toc, existing: flatBook, toc: toc), "明说 toc → 按目录（不分章节的书也一样）")
check(!ExerciseChapter.usesTOC(.flat, existing: [], toc: toc), "明说 none → 不按目录（新书也一样）")
check(!ExerciseChapter.usesTOC(nil, existing: flatBook, toc: toc), "没说、不分章节的书 → 保持不分")
check(ExerciseChapter.usesTOC(nil, existing: [], toc: toc), "没说、新书 → 照旧按目录")
check(ExerciseChapter.usesTOC(nil, existing: [(5, ["前言"])], toc: toc), "没说、分了章节的书 → 照旧按目录")
check(ExerciseChapterMode(rawValue: "none") == .flat && ExerciseChapterMode(rawValue: "toc") == .toc
      && ExerciseChapterMode(rawValue: "flat") == nil, "线上写法 toc / none")
// 移除分级 = 整本书的章节清空（`WorkspaceManager.clearExerciseChapters` 走的就是这条）；题目、收藏、错题、笔记不动
let d9 = doc("练习册", "h9")
var f1 = row(ok(input("f1", answer: "A", src: "book", number: "1"), seq: 0)!, doc: d9.id)
f1.chapter = ["第一章 函数", "1.1 映射"]; f1.page = 3; f1.starred = true; f1.wrong = true
var f2 = row(ok(input("f2", number: "2"), seq: 1)!, doc: d9.id); f2.chapter = ["第一章 函数"]; f2.page = 2
try store.upsertExercises([f1, f2])
try store.setExerciseNote(id: f1.id, "笔记", at: .now)
let f1Before = try store.exercise(id: f1.id)!
try store.setExerciseChapter(ids: [f1.id, f2.id], [], at: f1Before.updatedAt.addingTimeInterval(5))
let f1After = try store.exercise(id: f1.id)!
let f2After = try store.exercise(id: f2.id)
check(f1After.chapter.isEmpty && f2After?.chapter.isEmpty == true, "整本书的章节清空")
check(f1After.payload == f1Before.payload && f1After.number == "1" && f1After.starred && f1After.wrong
      && f1After.note == "笔记", "题目内容、收藏、错题、笔记都没动")
check(f1After.updatedAt > f1Before.updatedAt, "改了 updated_at（同步按它取新）")
let d9rows = try store.exercises(documentId: d9.id).map { (page: $0.page, chapter: $0.chapter) }
check(ExerciseChapter.bookIsFlat(d9rows, toc: toc), "清空之后这本书算不分章节 → 再导题不按目录分")
let d9groups = try store.exerciseChapterCounts().filter { $0.documentId == d9.id }
check(d9groups.count == 1 && d9groups[0].chapter.isEmpty && d9groups[0].count == 2,
      "侧栏的章节分组只剩「没章节」一组（书那一行不再展开）")

// MARK: - 2026-10-31：Agent 收藏 / 取消收藏（`EXERCISE-PLAN.md §15`）
// `update_exercises` 的 `starred` 走 `WorkspaceManager.saveExercise`：先 `upsertExercise` 存内容，再 `setExerciseStarred`。
print("— Agent 收藏：存内容不冲掉收藏、收藏改 updated_at")
var s1 = row(ok(input("s1", number: "1"), seq: 0)!, doc: d9.id); s1.page = 6
try store.upsertExercises([s1])
let s1t = try store.exercise(id: s1.id)!.updatedAt
try store.setExerciseStarred(id: s1.id, true, at: s1t.addingTimeInterval(3))
let s1Starred = try store.exercise(id: s1.id)!
check(s1Starred.starred && s1Starred.updatedAt > s1t, "收藏写上、updated_at 跟着变（同步按它取新）")
var s1Again = s1; s1Again.starred = false; s1Again.updatedAt = s1t.addingTimeInterval(6)
try store.upsertExercise(s1Again)
check(try store.exercise(id: s1.id)!.starred, "再存题目内容（行里 starred 是假）不会把收藏冲掉")
try store.setExerciseStarred(id: s1.id, false, at: s1t.addingTimeInterval(9))
check(!(try store.exercise(id: s1.id)!.starred), "取消收藏")

// MARK: - 2026-10-31：侧栏「已做 / 共」（`EXERCISE-PLAN.md §16`）

print("— 侧栏已做几道")
let dd = doc("进度", "h10")
var g1 = row(ok(input("g1", number: "1"), seq: 0)!, doc: dd.id); g1.chapter = ["第一章", "1.1"]; g1.page = 1
var g2 = row(ok(input("g2", number: "2"), seq: 1)!, doc: dd.id); g2.chapter = ["第一章", "1.2"]; g2.page = 2; g2.starred = true
var g3 = row(ok(input("g3", number: "3"), seq: 2)!, doc: dd.id); g3.chapter = ["第二章"]; g3.page = 5; g3.starred = true
var g4 = row(ok(input("g4", number: "4"), seq: 3)!, doc: dd.id); g4.page = 9
try store.upsertExercises([g1, g2, g3, g4])
func attempt(_ id: String, _ src: String = "") -> LibExerciseAttempt {
    LibExerciseAttempt(id: UUID().uuidString, exerciseId: id, answer: "A", correct: true, elapsedMs: 0, createdAt: .now, source: src)
}
try store.recordExerciseAttempt(attempt(g1.id))
try store.recordExerciseAttempt(attempt(g1.id))          // 同一道做两次只算一道
try store.recordMarkedAttempts([attempt(g2.id, LibExerciseAttempt.markSource)])   // 书上的作答也算做过
var dsum = ExerciseDoneSummary()
for r in try store.exerciseDoneCounts() where r.documentId == dd.id {
    dsum.chapters[r.documentId, default: [:]][r.chapter] = ExerciseDoneStat(done: r.done, starred: r.starred)
}
check(dsum.done(.document(dd.id)) == 2, "整本书做过 2 道（一道做两次只算一次、书上的作答算）")
check(dsum.done(.chapter(dd.id, ["第一章"])) == 2 && dsum.done(.chapter(dd.id, ["第一章", "1.1"])) == 1,
      "章 = 自己 + 各小节")
check(dsum.done(.chapter(dd.id, ["第二章"])) == 0 && dsum.done(.chapter(dd.id, [])) == 0, "没做的章 / 未分章节是 0")
check(dsum.done(.starredDocument(dd.id)) == 1 && dsum.done(.starredChapter(dd.id, ["第二章"])) == 0,
      "收藏那一支数的是收藏里做过的")
check(dsum.done(.wrong) == nil && dsum.done(.wrongDocument(dd.id)) == nil, "错题本那一支不给（全都做过）")
check(dsum.done(.all) == 2, "全部 = 各书相加")
let gs = ExerciseSummary(total: 4, starred: 2, byDocument: [dd.id: 4],
                         chapters: [dd.id: [["第一章", "1.1"]: ExerciseChapterStat(count: 1, firstPage: 1),
                                            ["第一章", "1.2"]: ExerciseChapterStat(count: 1, firstPage: 2, starred: 1),
                                            ["第二章"]: ExerciseChapterStat(count: 1, firstPage: 5, starred: 1),
                                            []: ExerciseChapterStat(count: 1, firstPage: 9)]])
let gtree = ExerciseGroupNode.build(gs, documents: [(dd.id, "进度")], title: { $0.key }, noChapter: "未分章节")
    .map { $0.withDone(dsum) }
let book = gtree.first { $0.scope == .document(dd.id) }
check(book?.done == 2 && book?.count == 4, "书那一行：2/4")
check(book?.children.first?.done == 2 && book?.children.first?.children.first?.done == 1, "整棵树都填上了")
check(gtree[1].done == nil && gtree[0].done == 2 && gtree[2].done == 1, "全部 / 错题本（不显示）/ 收藏")

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
