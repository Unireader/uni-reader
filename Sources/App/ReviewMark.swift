import CoreGraphics
import Foundation

/// **回顾点**（`TOC-REVIEW-PLAN.md §3`）：PDF 某页某处 + 标签 + 备注 + 期号。不设日期。
///
/// - 同一个标签下可以有好几个回顾点（不同位置、各自备注），按标签筛出来一起看；
/// - 期号 n 表示「第 n 期回顾时再看它」：按期号筛出这一期要看的；看完点「后推」，期号加上步长 k（k 自己设），
///   `reviews` 记一共看过几次、`lastReviewedAt` 记最后一次。
///
/// 落 `note` 表 `kind=8`（挂逻辑文档），payload `{tag, remark, period, reviews, last}`；同书签，表结构不变。
struct ReviewMark: Identifiable, Equatable {
    var id: UUID = UUID()
    /// 所属文档（读库时从 note 行带出来；整个工作区一起列时要用）。
    var documentId: String = ""
    var page: Int
    var frac: Double
    var tag: String
    var remark: String = ""
    /// 期号，≥ 1。
    var period: Int = 1
    /// 已经回顾过几次。
    var reviews: Int = 0
    var lastReviewedAt: Date?
    var createdAt: Date = .now
    var updatedAt: Date = .now

    static let noteKind = 8

    /// 列表口径：期号 → 页 → 页内位置 → 建立时刻（同一文档内；跨文档时调用方先按文档分）。
    static func before(_ a: ReviewMark, _ b: ReviewMark) -> Bool {
        if a.period != b.period { return a.period < b.period }
        if a.page != b.page { return a.page < b.page }
        if a.frac != b.frac { return a.frac < b.frac }
        return a.createdAt < b.createdAt
    }

    static func cleanTag(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 看完一次：期号往后推 `step` 期。
    mutating func advance(by step: Int) {
        period = max(1, period + max(1, step))
        reviews += 1
        lastReviewedAt = .now
        updatedAt = .now
    }
}

private struct ReviewPayload: Codable {
    var tag: String
    var remark: String
    var period: Int
    var reviews: Int?
    var last: String?
}

extension ReviewMark {
    func toNote(documentId: String) -> LibNote? {
        let p = ReviewPayload(tag: tag, remark: remark, period: period, reviews: reviews,
                              last: lastReviewedAt.map { ISO.string($0) })
        guard let data = try? JSONEncoder().encode(p) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind, page: page,
                       anchor: CGRect(x: 0, y: frac, width: 0, height: 0),
                       payload: data, createdAt: createdAt, updatedAt: updatedAt)
    }

    init?(note: LibNote) {
        guard note.kind == Self.noteKind, let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(ReviewPayload.self, from: note.payload) else { return nil }
        self.init(id: uuid, documentId: note.documentId, page: note.page, frac: min(max(0, note.anchor.minY), 1),
                  tag: p.tag, remark: p.remark, period: max(1, p.period), reviews: max(0, p.reviews ?? 0),
                  lastReviewedAt: p.last.flatMap { ISO.date($0) },
                  createdAt: note.createdAt, updatedAt: note.updatedAt)
    }
}

/// 回顾列表的筛选（Inspector 笔记页「回顾」分区）。只在内存，全 App 共用一份。
struct ReviewFilter: Equatable {
    /// true = 整个工作区；false = 当前文档。
    var wholeWorkspace = false
    /// nil = 全部标签。
    var tag: String?
    /// nil = 全部期。
    var period: Int?

    func matches(_ m: ReviewMark) -> Bool {
        (tag == nil || m.tag == tag) && (period == nil || m.period == period)
    }
}

extension ReviewMark {
    /// 「看完后推」的步长 k（设置在 UserDefaults，Inspector 回顾分区里改）。
    static var advanceStep: Int {
        get { max(1, UserDefaults.standard.object(forKey: "reviewAdvanceStep") as? Int ?? 1) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: "reviewAdvanceStep") }
    }
    /// 上一次新建用的标签 / 期号（连着给同一个标签加好几个点时不用重填）。
    static var lastTag: String {
        get { UserDefaults.standard.string(forKey: "reviewLastTag") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "reviewLastTag") }
    }
    static var lastPeriod: Int {
        get { max(1, UserDefaults.standard.object(forKey: "reviewLastPeriod") as? Int ?? 1) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: "reviewLastPeriod") }
    }
}
