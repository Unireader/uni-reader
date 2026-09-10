import Foundation
import CoreGraphics

/// 一张**草稿纸**：盖在 PDF 之上的无限白板，不改 PDF 原文、也不属于任何一页。
/// 挂逻辑文档（`scratch_pad` 表，schema v8），由 (页, 页内归一化点) 锚定「当初在哪儿建的」
/// —— 那个点在页面上留一枚图钉，打开草稿纸时视口回到画布原点，即「从该处显示」。
///
/// ## 画布坐标系（三端契约，别改）
///
/// 单位 = **逻辑点**（macOS pt / CSS px / Android dp），原点 = 创建那一刻的视口中心，
/// x 向右、y 向下，**无界且可负**。草稿纸上的 `InkStroke.points` 直接存这个坐标
/// （不再是页内 0~1 归一化），`InkStroke.width` 与页内笔迹**同语义**（zoom=1 时的屏幕宽度）。
///
/// 这么定的唯一理由是**三端现成的笔迹渲染器可以原样复用**：页内笔迹是「点 × 页宽」，
/// 草稿纸是「(点 − 视口原点) × zoom」，两者的线宽都只乘一个 `inkScale`。若改用「相对某个
/// 参考页宽归一化」，线宽就得跟着页宽走，三端四种笔型的观感全部要重新对一遍。
///
/// 视口（原点/缩放）**不落库、不上线**：每一端各自维护自己那份，打开一律回到画布原点
/// （用户要的「从该处显示」），要找已经写过的内容走「适应内容」或 minimap。
///
/// ## 纸样
/// 底色（`bg`，自由 CSS rgba）× 底纹（`pattern`，见 `ScratchPattern`）两个维度，各端可改、跨端同步。

/// 草稿纸的底纹（**三端契约**，线上是 u8：`0=plain 1=dots 2=grid`，同 brush/mode 的编码惯例）。
/// 底纹只是「参照物」，画在纸色之上、笔迹之下；墨色由纸色明度推出来（浅纸配深纹，反之亦然）。
enum ScratchPattern: String, CaseIterable, Codable {
    case plain   // 纯色，无参照物
    case dots    // 点阵
    case grid    // 小格

    var label: String {
        switch self {
        case .plain: return L("Plain")
        case .dots: return L("Dots")
        case .grid: return L("Grid")
        }
    }
    /// SF Symbol（Mac 的纸样选择器用）。
    var icon: String {
        switch self {
        case .plain: return "square"
        case .dots: return "circle.grid.3x3"
        case .grid: return "grid"
        }
    }
}

/// 一张草稿纸（文件头的坐标系/纸样契约说明适用于本类型）。
struct ScratchPad: Identifiable, Equatable {
    var id: UUID = UUID()
    /// 标题（空 = 界面按创建序显示「草稿纸 N」）。
    var title: String = ""
    /// 锚点：创建时所在页 + 页内归一化坐标（0~1，左上原点）。图钉画在这儿。
    var anchorPage: Int
    var anchorX: Double
    var anchorY: Double
    /// 画布底色，默认纯白（用户指定；夜间模式下不反色——草稿纸是「一张纸」，不是 PDF 内容）。
    var bg: InkColor = .paper
    /// 底纹（无 / 点阵 / 小格）。默认点阵：无限画布不给参照物的话，平移时看不出自己在动。
    var pattern: ScratchPattern = .dots
    /// 把这张纸**锚定的那一页**垫在纸下面当参照（v10，几何见 `pageRect`）。
    /// 默认 true：在页面某处新建的纸，那一页就该在眼前；v9 迁移过来的老纸补列即 false（不惊扰）。
    var showPage: Bool = true
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// 列表/标题栏显示名：没起名就按「草稿纸 N」兜底（N 由调用方给，通常是创建序 + 1）。
    func displayName(index: Int) -> String {
        title.isEmpty ? String(format: L("Scratchpad %d"), index + 1) : title
    }

    /// 橡皮半径的画布换算基准（**三端契约**）。`AppModel.eraserRadius` 是「页宽归一化」的
    /// （0.02 = 页宽的 2%），而草稿纸没有「页宽」这回事，故统一按这个参考宽度折成画布点：
    /// `画布半径 = eraserRadius × eraserRefWidth`。数值取一个常见的 fit-width 页宽量级，
    /// 于是默认橡皮在草稿纸上的手感与在页面上大致相当（0.02 × 800 = 16pt 半径）。
    /// 三端必须用同一个数，否则同一次擦除在两端擦掉的笔迹不一样多。
    static let eraserRefWidth: Double = 800

    /// 页面底图的宽度（画布点，**三端契约**，见 `PROTOCOL.md §4.4`）。画布没有「页宽」这回事，
    /// 页图就按这个固定宽度落在画布上；高由页面显示纵横比推。三端对不上的表现是「同一张纸，
    /// Mac 上写在公式旁边、平板上写到了页边空白处」。
    static let pageRefWidth: Double = 800

    /// 页面底图在画布上的矩形。`aspect` = 页高 / 页宽（**显示尺寸**口径：CropBox 优先、含 rotation，
    /// 与页内笔迹用的是同一个页面尺寸）。位置由契约定死：**锚点落在画布原点**，
    /// 于是「打开纸 = 回画布原点」正好把当初创建它的那一处摆在视口正中。
    func pageRect(aspect: Double) -> CGRect {
        let w = Self.pageRefWidth
        let h = w * (aspect > 0 ? aspect : 1.4142)   // 拿不到页面尺寸时按 A4 兜底
        return CGRect(x: -anchorX * w, y: -anchorY * h, width: w, height: h)
    }
}

extension InkColor {
    /// 草稿纸默认底色：纯白不透明。
    static let paper = InkColor(r: 255, g: 255, b: 255, a: 1)
}

extension ScratchPad {
    /// 可选纸色（**只是 UI 备选项，不是契约**——`bg` 在库里/线上都是自由的 CSS rgba 串，
    /// 将来加减颜色不影响任何一端的解码）。取常见纸张观感：白 / 米白 / 浅灰 / 牛皮 /
    /// 护眼绿 / 淡蓝，都压得很淡，保证任何笔色压上去都读得出来。
    static let paperPalette: [(key: String, name: String, color: InkColor)] = [
        ("white",  "Paper White", InkColor(r: 255, g: 255, b: 255, a: 1)),
        ("cream",  "Cream",       InkColor(r: 252, g: 247, b: 235, a: 1)),
        ("gray",   "Light Gray",  InkColor(r: 241, g: 242, b: 245, a: 1)),
        ("kraft",  "Kraft",       InkColor(r: 246, g: 236, b: 214, a: 1)),
        ("green",  "Eye Green",   InkColor(r: 233, g: 243, b: 234, a: 1)),
        ("blue",   "Cool Blue",   InkColor(r: 234, g: 241, b: 250, a: 1)),
    ]

    /// 底纹/提示文字的墨色是深还是浅：由**纸色明度**定，浅纸配深纹、深纸配浅纹。
    /// **不能跟系统深浅外观走**——纸色是这张纸自己的属性，深色外观 + 白纸时跟外观走就整个消失了。
    var inkIsDark: Bool { (0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b) / 255 > 0.5 }
}

// MARK: - 无限画布的视口

/// 一个端上的草稿纸视口：`origin` = 视口左上角对应的**画布坐标**，`zoom` = 画布→屏幕的倍率。
/// 换算只有两条：`screen = (canvas − origin) × zoom`、`canvas = origin + screen / zoom`。
struct ScratchViewport: Equatable {
    var origin: CGPoint = .zero
    var zoom: CGFloat = 1

    static let zoomMin: CGFloat = 0.2
    static let zoomMax: CGFloat = 8
    /// 「回中」「新建」时画布原点在视口里的落位：正中。
    static func centeredOnOrigin(viewport size: CGSize, zoom z: CGFloat = 1) -> ScratchViewport {
        ScratchViewport(origin: CGPoint(x: -size.width / (2 * z), y: -size.height / (2 * z)), zoom: z)
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * zoom, y: (p.y - origin.y) * zoom)
    }
    func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + p.x / zoom, y: origin.y + p.y / zoom)
    }
    /// 当前可见的画布矩形。
    func visibleRect(viewport size: CGSize) -> CGRect {
        CGRect(x: origin.x, y: origin.y, width: size.width / zoom, height: size.height / zoom)
    }

    /// 以某个**屏幕点**为锚缩放（捏合/⌥滚轮）：该点下的画布内容不动。
    func zoomed(by factor: CGFloat, anchorScreen p: CGPoint) -> ScratchViewport {
        let z = min(max(zoom * factor, Self.zoomMin), Self.zoomMax)
        guard z != zoom else { return self }
        let anchorCanvas = toCanvas(p)
        return ScratchViewport(origin: CGPoint(x: anchorCanvas.x - p.x / z,
                                               y: anchorCanvas.y - p.y / z), zoom: z)
    }
}

/// 无限画布的**软边界**：真无限会让人一路滚进空无一物的远方再也找不回来（用户明确要求避免）。
/// 规则只有一条——可见区必须与「内容包围盒外扩 `slackScreens` 个视口」相交；越界即拉回。
/// 内容为空时退化为「围着原点的一块」，于是新草稿纸只能在原点附近小范围移动。
enum ScratchBounds {
    static let slackScreens: CGFloat = 1.5

    /// 允许 `viewport.origin` 落在的矩形（左上角坐标的可行域）。
    static func allowedOriginRect(content: CGRect?, viewport size: CGSize, zoom: CGFloat) -> CGRect {
        let visW = size.width / max(zoom, 0.0001), visH = size.height / max(zoom, 0.0001)
        let base = (content?.isEmpty == false ? content! : CGRect(x: 0, y: 0, width: 0, height: 0))
        let slackX = visW * slackScreens, slackY = visH * slackScreens
        // 视口左上角可到达的范围：从「视口右下角刚碰到外扩区左上角」到「视口左上角刚碰到外扩区右下角」。
        let minX = base.minX - slackX - visW, maxX = base.maxX + slackX
        let minY = base.minY - slackY - visH, maxY = base.maxY + slackY
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    static func clamp(_ v: ScratchViewport, content: CGRect?, viewport size: CGSize) -> ScratchViewport {
        let r = allowedOriginRect(content: content, viewport: size, zoom: v.zoom)
        var out = v
        out.origin.x = min(max(v.origin.x, r.minX), r.maxX)
        out.origin.y = min(max(v.origin.y, r.minY), r.maxY)
        return out
    }

    /// 笔迹集合（可选并上页面底图矩形）的画布包围盒（空 → nil）。minimap、软边界与「适应内容」共用。
    /// `page` 非空 = 这张纸开着页面底图：它也算「内容」，否则软边界只认笔迹，空白纸上垫了页也走不到页边。
    static func contentBounds(_ strokes: [InkStroke], page: CGRect? = nil) -> CGRect? {
        guard let ink = inkBounds(strokes) else { return page }
        guard let page else { return ink }
        return ink.union(page)
    }

    /// 纯笔迹包围盒（不含页面底图）。
    private static func inkBounds(_ strokes: [InkStroke]) -> CGRect? {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var any = false
        for st in strokes {
            for p in st.points {
                any = true
                minX = Swift.min(minX, p.dx); maxX = Swift.max(maxX, p.dx)
                minY = Swift.min(minY, p.dy); maxY = Swift.max(maxY, p.dy)
            }
        }
        guard any else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 「适应内容」：把包围盒（含 `padding` 边距）装进视口；内容为空则回原点居中。
    static func fit(content: CGRect?, viewport size: CGSize, padding: CGFloat = 40) -> ScratchViewport {
        guard let c = content, size.width > 1, size.height > 1 else {
            return .centeredOnOrigin(viewport: size)
        }
        let w = max(c.width, 1), h = max(c.height, 1)
        let z = min(max(min((size.width - padding * 2) / w, (size.height - padding * 2) / h),
                        ScratchViewport.zoomMin), ScratchViewport.zoomMax)
        return ScratchViewport(origin: CGPoint(x: c.midX - size.width / (2 * z),
                                               y: c.midY - size.height / (2 * z)), zoom: z)
    }
}

// MARK: - 持久化（scratch_pad 表，v8）

extension ScratchPad {
    init(row: LibScratchPad) {
        self.init(id: UUID(uuidString: row.id) ?? UUID(), title: row.title,
                  anchorPage: row.anchorPage, anchorX: row.anchorX, anchorY: row.anchorY,
                  bg: InkColor.parse(row.bg),
                  pattern: ScratchPattern(rawValue: row.pattern) ?? .dots,   // 未知/老行兜底点阵
                  showPage: row.showPage,   // v9 老行补列即 false（新建的纸才默认 true）
                  createdAt: row.createdAt, updatedAt: row.updatedAt)
    }

    func toRow(documentId: String) -> LibScratchPad {
        LibScratchPad(id: id.uuidString, documentId: documentId, title: title,
                      anchorPage: anchorPage, anchorX: anchorX, anchorY: anchorY,
                      bg: bg.cssRGBA, pattern: pattern.rawValue, showPage: showPage,
                      createdAt: createdAt, updatedAt: updatedAt)
    }
}
