import CoreGraphics
import PDFKit

/// 页坐标几何：PDFKit 原生页空间（mediaBox 局部，**左下原点，未旋转**）与显示归一化坐标
/// （0~1，**左上原点**，含 rotation 的显示朝向，与 `PageLayout`/`InkStroke` 同约定）之间的双向换算。
/// 文字搜索高亮（`TextSearch`）和文字选择（`PageStreamView`）都复用同一套变换，保证同一套坐标真相。
///
/// ⚠️ 假设 `characterBounds`/`PDFSelection.bounds(for:)`/`selectionFromPoint:toPoint:` 均按**未旋转**
/// 局部坐标进出——rotation=0（绝大多数文档）按恒等变换必然正确；90/180/270 分支四角/点映射手推验证，
/// 待真实旋转 PDF 实测（见 TODO.md「已知待办」）。
enum PageGeometry {
    /// 原生页矩形（mediaBox 局部，左下原点，未旋转）→ 显示归一化矩形（0~1，左上原点）。
    static func normalizedRect(_ r: CGRect, mediaBox b: CGRect, rotation: Int) -> CGRect {
        let lx = r.minX - b.minX, ly = r.minY - b.minY
        let bw = b.width, bh = b.height
        let rot = ((rotation % 360) + 360) % 360
        let dispW: CGFloat, dispH: CGFloat, dx: CGFloat, dy: CGFloat, dw: CGFloat, dh: CGFloat
        switch rot {
        case 90:
            dispW = bh; dispH = bw
            dx = ly; dy = bw - (lx + r.width); dw = r.height; dh = r.width
        case 180:
            dispW = bw; dispH = bh
            dx = bw - (lx + r.width); dy = bh - (ly + r.height); dw = r.width; dh = r.height
        case 270:
            dispW = bh; dispH = bw
            dx = bh - (ly + r.height); dy = lx; dw = r.height; dh = r.width
        default:
            dispW = bw; dispH = bh
            dx = lx; dy = ly; dw = r.width; dh = r.height
        }
        guard dispW > 0, dispH > 0 else { return .zero }
        let nx = dx / dispW
        let ny = 1 - (dy + dh) / dispH
        return CGRect(x: nx, y: ny, width: dw / dispW, height: dh / dispH)
    }

    /// 显示归一化点（0~1，左上原点，含 rotation 的显示朝向）→ 原生页空间点（左下原点，mediaBox 坐标，未旋转）。
    /// `normalizedRect` 的**点级逆变换**（宽高取 0，逐 rotation 分支代数求逆，四分支手推验证）；
    /// 用于把阅读区里的拖选/点击坐标喂回 PDFKit 的 `selection(from:at:to:at:)`（它只吃页空间点）。
    static func pageSpacePoint(normX nx: CGFloat, normY ny: CGFloat, mediaBox b: CGRect, rotation: Int) -> CGPoint {
        let bw = b.width, bh = b.height
        let rot = ((rotation % 360) + 360) % 360
        let lx: CGFloat, ly: CGFloat   // mediaBox 原点局部坐标（左下原点）
        switch rot {
        case 90:
            lx = ny * bw; ly = nx * bh
        case 180:
            lx = (1 - nx) * bw; ly = ny * bh
        case 270:
            lx = (1 - ny) * bw; ly = (1 - nx) * bh
        default:
            lx = nx * bw; ly = (1 - ny) * bh
        }
        return CGPoint(x: lx + b.minX, y: ly + b.minY)
    }

    /// 一处 `PDFSelection` → 逐页的显示归一化行框（`selectionsByLine` 按行拆，各行框 rotation-aware 归一化）。
    /// 文字选择高亮与搜索命中高亮共用同款画法（`PageCellView.fillNorm`）。
    static func normalizedLineRects(of selection: PDFSelection, in pdf: PDFDocument) -> [Int: [CGRect]] {
        let lines = selection.selectionsByLine()
        var out: [Int: [CGRect]] = [:]
        for page in selection.pages {
            let idx = pdf.index(for: page)
            guard idx != NSNotFound else { continue }
            let mediaBox = page.bounds(for: .mediaBox)
            guard mediaBox.width > 0, mediaBox.height > 0 else { continue }
            var rects: [CGRect] = []
            for line in lines where line.pages.contains(page) {
                let b = line.bounds(for: page)
                guard b.width > 0, b.height > 0 else { continue }
                rects.append(normalizedRect(b, mediaBox: mediaBox, rotation: page.rotation))
            }
            if !rects.isEmpty { out[idx] = rects }
        }
        return out
    }
}
