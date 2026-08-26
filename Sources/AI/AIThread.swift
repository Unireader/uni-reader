import CoreGraphics
import Foundation

/// 往一次 AI 对话里发过的一样东西（截图区域 / 整页 / 引文）。按发送时间顺序记在 `AIThread.contexts`。
/// **第一条决定这次绑定钉在哪一页哪一处**（用户定的规则：多张图用第一张）。
struct AIContext: Equatable {
    enum Kind: String {
        case region     // 框选区域截图
        case page       // 整页
        case quote      // 选中的原文
    }

    var kind: Kind
    var page: Int
    /// 页内归一化矩形 [x, y, w, h]（左上原点）；整页/纯引文可为 nil。
    var rect: CGRect?
    /// 引文原文（kind == .quote 时有值）。
    var text: String?
    var sentAt: Date = .now
}

/// 一次「AI 会话绑定」：把某平台上的**一次网页对话**钉到本文档的某一页/某个区域。
///
/// 各平台每次对话都有唯一链接（DeepSeek 是 `https://chat.deepseek.com/a/chat/s/<uuid>`），
/// 这条链接就是绑定的核心——我们**不存对话正文**（扒 DOM 站点一改就废，见 `AI-PLAN.md §9` 红线），
/// 只存 URL、标题，外加「往这个对话里发过哪些东西」的顺序记录 `contexts`。
///
/// 落 `note` 表 **kind=1**（`REQUIREMENTS.md §1.2` 早就预留的「会话笔记」槽位）。复用 note 表
/// 而非新建表 = **零 schema 迁移**，且级联删除 / `mergeDocument` 文档合并迁移 / 跨端 `SELECT`
/// 全部原样继承——与草稿纸笔迹复用 kind=4 是同一个先例。
///
/// `page` / `anchor` 走 note 的列，取 **`contexts` 第一条**；contexts 为空（还没发过东西、
/// 纯文字提问）时 = 发起绑定时所在的页，anchor 为空矩形。
struct AIThread: Identifiable, Equatable {
    /// 会话可用性。打开后落地 URL 不再匹配平台的会话正则（被重定向回首页/登录页）= 会话已删或掉登录。
    /// **不静默**：标出来让用户看得见。
    enum State: Int {
        case ok = 0
        case suspect = 1
    }

    var id: UUID = UUID()
    var page: Int
    var anchor: CGRect = .zero      // 归一化 0~1（页局部，左上原点）；.zero = 未指向具体区域
    var provider: String            // AIProvider.id
    var url: String                 // 会话唯一链接（绑定的核心）
    var title: String = ""          // 取 webPage.title
    var state: State = .ok
    var contexts: [AIContext] = []
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var lastOpenedAt: Date?

    /// 列表里显示的标题：平台给的标题优先，没有就退回「未命名对话」（UI 层本地化）。
    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 追加一条上下文。**第一条同时决定 page/anchor**（用户定的「多张图用第一张」规则）。
    mutating func addContext(_ c: AIContext) {
        let wasEmpty = contexts.isEmpty
        contexts.append(c)
        if wasEmpty {
            page = c.page
            anchor = c.rect ?? .zero
        }
        updatedAt = .now
    }
}

// MARK: - 持久化（note 表，kind=1）

/// 落 `note.payload` 的 JSON 形态（页/锚点走 note 列，这里只存其余字段）。
/// 时间用 ISO-8601 文本、矩形用显式 `[x,y,w,h]` 数组——都是为了 Windows/Android 端易读
/// （与 `TextNotePayload` 同约定）。
private struct AIThreadPayload: Codable {
    var provider: String
    var url: String
    var title: String
    var state: Int
    var contexts: [Ctx]
    var lastOpenedAt: String?

    struct Ctx: Codable {
        var kind: String
        var page: Int
        var rect: [Double]?
        var text: String?
        var sentAt: String

        enum CodingKeys: String, CodingKey {
            case kind, page, rect, text
            case sentAt = "sent_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case provider, url, title, state, contexts
        case lastOpenedAt = "last_opened_at"
    }
}

extension AIThread {
    /// 会话笔记的 kind（对齐 `LibNote.kind`：0 text / **1 chat** / 2 ink / 3 highlight / 4 scratch ink）。
    static let noteKind = 1

    /// 序列化为一条 chat 笔记（挂逻辑文档，全版本共用）。
    func toNote(documentId: String) -> LibNote? {
        let payload = AIThreadPayload(
            provider: provider, url: url, title: title, state: state.rawValue,
            contexts: contexts.map { c in
                AIThreadPayload.Ctx(kind: c.kind.rawValue, page: c.page,
                                    rect: c.rect.map { [$0.minX, $0.minY, $0.width, $0.height] },
                                    text: c.text, sentAt: ISO.string(c.sentAt))
            },
            lastOpenedAt: lastOpenedAt.map { ISO.string($0) })
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return LibNote(id: id.uuidString, documentId: documentId, kind: Self.noteKind,
                       page: page, anchor: anchor, payload: data,
                       createdAt: createdAt, updatedAt: updatedAt)
    }

    /// 从一条 chat 笔记复原（id/page/anchor 取 note 列，其余取 payload）。类型不符或损坏返回 nil。
    init?(note: LibNote) {
        guard note.kind == AIThread.noteKind,
              let uuid = UUID(uuidString: note.id),
              let p = try? JSONDecoder().decode(AIThreadPayload.self, from: note.payload)
        else { return nil }
        let ctxs: [AIContext] = p.contexts.compactMap { c in
            guard let kind = AIContext.Kind(rawValue: c.kind) else { return nil }   // 未知 kind（新版写的）跳过
            let rect: CGRect? = c.rect.flatMap { a in
                a.count >= 4 ? CGRect(x: a[0], y: a[1], width: a[2], height: a[3]) : nil
            }
            return AIContext(kind: kind, page: c.page, rect: rect, text: c.text,
                             sentAt: ISO.date(c.sentAt) ?? note.createdAt)
        }
        self.init(id: uuid, page: note.page, anchor: note.anchor,
                  provider: p.provider, url: p.url, title: p.title,
                  state: State(rawValue: p.state) ?? .ok, contexts: ctxs,
                  createdAt: note.createdAt, updatedAt: note.updatedAt,
                  lastOpenedAt: ISO.date(p.lastOpenedAt))
    }
}
