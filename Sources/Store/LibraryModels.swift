import Foundation
import CoreGraphics

/// 工作区数据模型（纯值类型，映射 `library.sqlite` 的表；跨平台可读）。
/// 与旧 SwiftData `@Model` 无关——工作区改用自有 schema 的 SQLite 单库。

/// 逻辑文档「一本书」。可含多个内容版本（variant），笔记全版本共用。
struct LibDocument: Identifiable, Equatable {
    var id: String              // UUID
    var title: String
    var pageCount: Int
    var addedAt: Date
    var lastOpenedAt: Date
    var sortOrder: Int
    var readPage: Int = 0       // 阅读进度：视口顶部所在页
    var readFrac: Double = 0    // 阅读进度：页内归一化比例（0 顶 1 底）
    var readZoom: Double = 1    // 上次缩放倍率（相对 fit-width，1=贴合宽度）
    var readHFrac: Double = 0   // 上次横向滚动比例（offsetX / pageW，缩放态才非 0）
    var group: String = ""      // 一级分组名（v11；空串 = 未分组）
    var canvasMode: Bool = false // 画板模式（v12）：页面两侧空白也可书写
}

/// 一个内容版本＝一个 content hash（加 TOC 等致 hash 变即新增一个 variant）。
struct LibVariant: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var contentHash: String     // SHA-256
    var pageCount: Int
    var addedAt: Date
}

/// 一个物理路径（移动/复制产生多条）。非沙盒 + 跨平台 → 不存 macOS security-scoped bookmark。
/// `inWorkspace=true` 时 `path` 为**工作区相对路径**（如 `PDFs/xxx.pdf`），随文件夹移动仍有效。
/// `isRelative=true` 时 `path` 也是**相对工作区文件夹**的路径（可含 `..`）——外部文件但与工作区
/// 同属一块可移动卷（移动硬盘等）时使用，换机器/换挂载点仍可解析；否则为绝对路径。
struct LibLocation: Identifiable, Equatable {
    var id: String              // UUID
    var variantId: String
    var path: String
    var isValid: Bool
    var lastValidatedAt: Date?
    var inWorkspace: Bool = false
    var isRelative: Bool = false
}

/// 笔记（挂逻辑文档，全版本共用）。payload 为 JSON（跨平台可读）。
struct LibNote: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var kind: Int               // 0 text / 1 chat / 2 ink
    var page: Int
    var anchor: CGRect          // PDF 页面坐标
    var payload: Data           // JSON
    var createdAt: Date
    var updatedAt: Date
}

/// 笔迹行的窄读法（`note` 表 kind=2 / 4）：只取 `InkStroke(row:)` 真正要用的四列，
/// 不读 anchor 与两个时间戳（`LibraryStore.inkRows`）。开文档读几千行时，整行 `LibNote`
/// 那条路每行多七列的装箱 + 两次时间戳解析，全是白做的。
struct LibInkRow {
    var id: String              // UUID
    var kind: Int               // 2 页内 / 4 草稿纸
    var page: Int
    var payload: Data           // JSON
}

/// 某页页内笔迹的汇总（`LibraryStore.inkPageSummaries`，一条 GROUP BY 出全篇）：
/// 笔迹按页窗口装载后（`INK-PAGING-PLAN.md §4.6`），检查器的「按页列表」不再能从内存数出来，
/// 改看这个——库里怎么算都不读 payload 里的点。
struct LibInkPageSummary {
    var page: Int
    var count: Int
    /// 该页笔迹包围盒的最小归一化 y（跳转落点用；`note.anchor_y` 列）。
    var minY: Double
    /// 该页出现过的笔色（去重），JSON 数组文本 `[{"r":..,"g":..,"b":..,"a":..}, …]`——
    /// 由 `json_group_array(DISTINCT json_extract(payload,'$.color'))` 直接给出，App 层解成 `InkColor`。
    var colorsJSON: String
}

/// 一个笔迹图层（`ink_layer` 表，v7）。挂逻辑文档；`colorKey` 复用 `NoteType.palette`。
struct LibInkLayer: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var name: String
    var colorKey: String
    var sortOrder: Int
    var visible: Bool
    var createdAt: Date
}

/// 一张草稿纸（`scratch_pad` 表，v8）。挂逻辑文档，全版本共用（同 note/ink_layer）。
/// 锚点＝创建时所在页 + 页内归一化点（图钉位置）；`bg` 为 CSS `rgba(...)` 串（跨平台易读）。
/// 草稿纸上的笔迹在 `note` 表 kind=4，payload 里带 `padId` 指回这里，坐标是**画布坐标**
/// （逻辑点，可负无界，见 `ScratchPad` 的坐标系契约）。
struct LibScratchPad: Identifiable, Equatable {
    var id: String              // UUID
    var documentId: String
    var title: String
    var anchorPage: Int
    var anchorX: Double
    var anchorY: Double
    var bg: String
    /// 底纹 `ScratchPattern.rawValue`（"plain"/"dots"/"grid"，v9）。老行为空 → 解码兜底 dots。
    var pattern: String
    /// 页面底图（v10）：要不要把这张纸锚定的那一页垫在纸下面（几何契约见 `ScratchPad.pageRefWidth`）。
    /// v9 迁移过来的老纸补列即 0（关），新建的纸默认开——见 `ScratchPad.showPage`。
    var showPage: Bool
    var createdAt: Date
    var updatedAt: Date
}

/// 一篇画板笔记（`board_note` 表，v16，`BOARD-NOTE-PLAN.md §2`）。独立于 PDF，挂在工作区。
/// 纸样 `bg` / `pattern` 与 `LibScratchPad` 同语义。`lastOpenedAt` 只给侧栏排序（打开不改 `updatedAt`）。
struct LibBoard: Identifiable, Equatable {
    var id: String              // UUID
    var title: String
    var bg: String
    var pattern: String
    var groupName: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedAt: Date?
}

/// 画板笔记上的一条东西（`board_item` 表，v16）：kind 1 = 笔迹、2 = 图片。
/// `rect` = 画布坐标包围盒（逻辑点，左上原点）；`payload` = JSON（笔迹同草稿纸 kind=4 的 payload，图片见方案 §2.3）。
struct LibBoardItem: Identifiable, Equatable {
    var id: String              // UUID
    var boardId: String
    var kind: Int
    var rect: CGRect
    var payload: Data
    var createdAt: Date
    var updatedAt: Date
}

/// 一张图片本体（`image` 表，v13）。**主键就是内容 SHA-256**：同一张图导两次只有一行一文件；
/// 两端各自导入同一张图在离线镜像合并时也天然合一。文件在 `<工作区>/Images/<sha256>.<ext>`。
/// 引用 = `note` 表 kind=6 的 payload 里 `image` 键指向这里，**不存计数列**（数出来的永远对，
/// 见 `IMAGE-NOTE-PLAN.md §2.2`）。`orphanedAt` 非 nil = 从那一刻起没有任何引用（待删除，30 天后清）。
struct LibImage: Identifiable, Equatable {
    var id: String { sha256 }
    var sha256: String
    var ext: String             // png / jpg / gif / webp
    var width: Int
    var height: Int
    var bytes: Int
    var createdAt: Date
    var orphanedAt: Date?
}

/// 一页的 OCR 缓存（`ocr_page` 表，v3）。按内容 hash（= variant 物理内容）+ 页 + 引擎缓存，
/// 随文件移动/换机复用。`payload` = JSON `OCRPagePayload`（归一化 0~1 文本框，见 `OCR.swift`）。
struct OCRPage: Equatable {
    var contentHash: String     // SHA-256（对应 variant.content_hash）
    var page: Int
    var provider: String        // OCR 引擎标识（"vision" / "paddle-http" / …）
    var payload: Data           // JSON
    var lang: String?
    var createdAt: Date
}

/// 一份文件的扫描页对齐参数（`page_align` 表，v14，`SCAN-ALIGN-PLAN.md §3`）。
struct PageAlignRow: Equatable {
    var contentHash: String
    var enabled: Bool
    var pageCount: Int
    var payload: Data           // JSON，解码走 `ScanAlignTable.decode`
    var createdAt: Date         // 测量时刻
    var updatedAt: Date         // 最近一次开 / 关（离线镜像按它取新）
    // 解码成 `ScanAlignTable` 在 `WorkspaceManager.scanAlign(contentHash:pageCount:)`：本文件被一堆只编 Store 层的
    // spike 直接编译，别让它依赖 App 层的类型。
}

/// ISO-8601（带小数秒）读写，供 SQLite TEXT 时间列使用；跨平台标准。
enum ISO {
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func string(_ d: Date) -> String { fmt.string(from: d) }

    /// 🔴 **规范形态走手写解析，别走 formatter**：`ISO8601DateFormatter.date(from:)` 一次约 30µs，
    /// 而 `note` 表每行有**两个**时间戳。2026-09-02 实测（一篇 3506 行的文档）：`notes(documentId:)`
    /// 单次 270ms 里，光这 7012 次解析就占 **209ms（77%）**——而笔迹那 99% 的行
    /// （`InkStroke(note:)` 只取 id/page/payload）根本不读这两个字段。
    /// 手写解析约 0.2µs，快两个数量级；不认识的形态照旧回落到 formatter，语义不变。
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fast(s) ?? fmt.date(from: s)
    }

    /// 只认 `string(_:)` 产出的那一种：`YYYY-MM-DDTHH:MM:SS.sssZ`（24 字符，UTC）。
    /// 任何一位对不上就返回 nil，交给 formatter 去认（别的端写进来的、老数据的其它写法）。
    private static func fast(_ s: String) -> Date? {
        if let r = s.utf8.withContiguousStorageIfAvailable({ parseCanonical($0) }) { return r }
        return Array(s.utf8).withUnsafeBufferPointer { parseCanonical($0) }
    }

    private static func parseCanonical(_ b: UnsafeBufferPointer<UInt8>) -> Date? {
        guard b.count == 24,
              b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54,      // '-' '-' 'T'
              b[13] == 0x3A, b[16] == 0x3A, b[19] == 0x2E,    // ':' ':' '.'
              b[23] == 0x5A                                    // 'Z'
        else { return nil }
        func num(_ i: Int, _ n: Int) -> Int? {
            var v = 0
            for k in i..<(i + n) {
                let c = Int(b[k]) &- 48
                guard c >= 0, c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2), let msec = num(20, 3),
              mo >= 1, mo <= 12, d >= 1, d <= 31, h <= 23, mi <= 59, se <= 59
        else { return nil }   // 秒上界取 59 而不是 60：闰秒 `…:60Z` 被 formatter 判为非法，两边要一致
        // days-from-civil（Howard Hinnant 的公历算法）：直接算 1970-01-01 起的天数，
        // 不碰 `Calendar`/`DateComponents`（那两位比 formatter 还慢）。
        let yy = y - (mo <= 2 ? 1 : 0)
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400                                        // [0, 399]
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1      // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                 // [0, 146096]
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970:
            Double(days * 86_400 + h * 3600 + mi * 60 + se) + Double(msec) / 1000)
    }
}

/// 工作区里的一篇 Markdown 笔记（v15，`MARKDOWN-NOTES-PLAN.md §2`）。
///
/// 🔴 **正文不在这里，也不在库里**——它就是 `<工作区>/<relPath>` 那个文件。这一行只是元数据；
/// 库与文件对不上时以文件系统为真源。
/// `id` 就是笔记正文里 `[[名字|<id>]]` 的那个 id，**一旦写进文件就不许换**。
struct LibMarkdownDoc: Identifiable, Equatable {
    var id: String              // UUID
    var title: String           // 显示名 = `[[…]]` 解析的名字（默认 = 文件名去扩展名）
    var relPath: String         // 工作区相对路径，如 `Notes/数学/极限.md`（库内唯一）
    var group: String = ""      // 一级分组名（与 LibDocument.group 同义；空串 = 未分组）
    var sortOrder: Int = 0
    var createdAt: Date
    var updatedAt: Date         // 正文最后修改（离线镜像 LWW 依据）
    var lastOpenedAt: Date
}
