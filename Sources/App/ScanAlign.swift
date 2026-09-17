import Foundation
import CoreGraphics
import CryptoKit

/// 扫描页对齐（`SCAN-ALIGN-PLAN.md`）的纯逻辑：每页变换、参数表编解码、像素测量、定中心。
/// 不碰 PDFKit / AppKit，spike `scan-align-test.swift` 直接编译本文件。
///
/// 🔴 **§2 的变换公式与 §3 的 payload 格式是三端契约**（安卓模式1 自己出图，照同一组式子算）。
/// 改任何一个数、任何一处符号，安卓那边必须同步，否则同一条笔迹两端落在不同位置。

// MARK: - 每页变换

/// 一页的对齐参数 + 它所在文档的目标页宽。坐标一律「显示空间、左上原点、y 向下、pt」。
///
/// - 原始显示空间：尺寸 `(sw, sh)`（effective box 按 `/Rotate` 转正后的样子）。
/// - 对齐显示空间：尺寸 `(w, sh)`。开着对齐时，所有页内归一化坐标都相对它。
struct PageAlign: Equatable {
    /// 原图里文字行的斜率角（弧度，y 向下时「往右往下斜」为正）。
    var rot: Double
    var dx: Double
    var dy: Double
    var sw: Double
    var sh: Double
    /// 文档统一的目标页宽（`ScanAlignTable.width`）。
    var w: Double

    var alignedSize: CGSize { CGSize(width: w, height: sh) }
    var rawSize: CGSize { CGSize(width: sw, height: sh) }

    /// 原始 → 对齐（§2.2 正变换）。
    func toAligned(_ p: CGPoint) -> CGPoint {
        let c = cos(rot), s = sin(rot)
        let u = Double(p.x) - sw / 2, v = Double(p.y) - sh / 2
        return CGPoint(x: c * u + s * v + w / 2 + dx,
                       y: -s * u + c * v + sh / 2 + dy)
    }

    /// 对齐 → 原始（§2.2 逆变换）。
    func toRaw(_ q: CGPoint) -> CGPoint {
        let c = cos(rot), s = sin(rot)
        let u = Double(q.x) - w / 2 - dx, v = Double(q.y) - sh / 2 - dy
        return CGPoint(x: c * u - s * v + sw / 2,
                       y: s * u + c * v + sh / 2)
    }

    /// 矩形过正变换：四角的包围盒（旋转角很小，包围盒只比原框大一点点）。
    func toAligned(rect r: CGRect) -> CGRect { Self.bbox(corners(r).map(toAligned)) }
    func toRaw(rect r: CGRect) -> CGRect { Self.bbox(corners(r).map(toRaw)) }

    /// 原始显示归一化（0~1，相对 `sw×sh`）→ 对齐显示归一化（相对 `w×sh`）。
    func alignedNorm(fromRawNorm r: CGRect) -> CGRect {
        guard w > 0, sh > 0 else { return r }
        let pt = CGRect(x: r.minX * sw, y: r.minY * sh, width: r.width * sw, height: r.height * sh)
        let a = toAligned(rect: pt)
        return CGRect(x: a.minX / w, y: a.minY / sh, width: a.width / w, height: a.height / sh)
    }

    /// 对齐显示归一化点 → 原始显示归一化点。
    func rawNorm(fromAlignedNorm n: CGPoint) -> CGPoint {
        guard sw > 0, sh > 0 else { return n }
        let p = toRaw(CGPoint(x: Double(n.x) * w, y: Double(n.y) * sh))
        return CGPoint(x: Double(p.x) / sw, y: Double(p.y) / sh)
    }

    /// CoreGraphics（y 向上、左下原点）版正变换：原始页的 CG 坐标 → 对齐页的 CG 坐标。
    /// 出图时 `ctx.concatenate(cgTransform)` 之后再 `page.draw`。推导见方案 §2.2。
    var cgTransform: CGAffineTransform {
        let c = cos(rot), s = sin(rot)
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: -c * sw / 2 + s * sh / 2 + w / 2 + dx,
                                 ty: -s * sw / 2 - c * sh / 2 + sh / 2 - dy)
    }

    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private static func bbox(_ ps: [CGPoint]) -> CGRect {
        let xs = ps.map(\.x), ys = ps.map(\.y)
        let x0 = xs.min() ?? 0, y0 = ys.min() ?? 0
        return CGRect(x: x0, y: y0, width: (xs.max() ?? 0) - x0, height: (ys.max() ?? 0) - y0)
    }
}

// MARK: - 整篇参数表（`page_align.payload`）

/// 一份文件的对齐参数表。`payload` 是落库的原字节——`stamp` 按它算，**不重新编码**
/// （别的端写的 JSON 数字格式不一定与本端逐字相同，重编码会让同一份参数算出两个戳）。
struct ScanAlignTable: Equatable {
    static let formatVersion = 1

    /// 每页一组 `[rot, dx, dy, sw, sh]`。
    struct Page: Equatable {
        var rot: Double, dx: Double, dy: Double, sw: Double, sh: Double
    }

    let width: Double
    let pages: [Page]
    let payload: Data
    /// `SHA-256(payload)` 的前 8 个十六进制小写字符（方案 §3.1）。
    let stamp: String

    static func == (a: ScanAlignTable, b: ScanAlignTable) -> Bool { a.payload == b.payload }

    var pageCount: Int { pages.count }

    func page(_ i: Int) -> PageAlign? {
        guard pages.indices.contains(i) else { return nil }
        let p = pages[i]
        return PageAlign(rot: p.rot, dx: p.dx, dy: p.dy, sw: p.sw, sh: p.sh, w: width)
    }

    /// `PageLayout` 要的每页高（文档单位 = 参考宽 `refWidth` 下的 pt）：对齐后页宽统一是 `width`。
    func heights(refWidth: Double) -> [Double] {
        pages.map { width > 0 ? $0.sh / width * refWidth : refWidth * 1.4 }
    }

    /// 由参数建表（Mac 测量完用）。数字格式固定，便于人工比对。
    init(width: Double, pages: [Page]) {
        var s = "{\"v\":\(Self.formatVersion),\"w\":\(Self.num(width, 3)),\"pages\":["
        for (i, p) in pages.enumerated() {
            if i > 0 { s += "," }
            s += "[\(Self.num(p.rot, 7)),\(Self.num(p.dx, 3)),\(Self.num(p.dy, 3)),"
                + "\(Self.num(p.sw, 3)),\(Self.num(p.sh, 3))]"
        }
        s += "]}"
        let data = Data(s.utf8)
        // 表里的值取「写出去再读回来」的那一份：保证本机刚测完与下次从库里读到的逐位相同。
        let parsed = Self.parse(data)
        self.width = parsed?.width ?? width
        self.pages = parsed?.pages ?? pages
        self.payload = data
        self.stamp = Self.stamp(of: data)
    }

    private init(width: Double, pages: [Page], payload: Data) {
        self.width = width; self.pages = pages; self.payload = payload
        self.stamp = Self.stamp(of: payload)
    }

    /// 从库里的 payload 解出来。格式版本不认识、页数对不上、数值不合法 → nil（按没开对齐处理）。
    static func decode(_ data: Data, pageCount: Int) -> ScanAlignTable? {
        guard let p = parse(data), p.pages.count == pageCount else { return nil }
        return ScanAlignTable(width: p.width, pages: p.pages, payload: data)
    }

    private static func parse(_ data: Data) -> (width: Double, pages: [Page])? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["v"] as? NSNumber)?.intValue == formatVersion,
              let w = (obj["w"] as? NSNumber)?.doubleValue, w > 0, w.isFinite,
              let arr = obj["pages"] as? [[NSNumber]] else { return nil }
        var pages: [Page] = []
        pages.reserveCapacity(arr.count)
        for row in arr {
            guard row.count >= 5 else { return nil }
            let v = row.prefix(5).map(\.doubleValue)
            guard v.allSatisfy(\.isFinite), v[3] > 0, v[4] > 0 else { return nil }
            pages.append(Page(rot: v[0], dx: v[1], dy: v[2], sw: v[3], sh: v[4]))
        }
        return (w, pages)
    }

    static func stamp(of data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// 定宽小数、去掉多余的尾零（`-0` 归 `0`）。
    private static func num(_ v: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    /// 显示身份（缓存键，方案 §3.1）。
    static func displayKey(contentHash: String, table: ScanAlignTable?) -> String {
        guard let table, !contentHash.isEmpty else { return contentHash }
        return contentHash + "~a" + table.stamp
    }
}

// MARK: - 像素测量（一页）

/// 一页灰度图 → 歪斜角 + 正文栏左右边缘（方案 §6.1~§6.3）。
enum ScanAlignDetector {
    /// 测量分辨率（像素/pt）。
    static let pxPerPt: Double = 1.5

    struct Measure: Equatable {
        /// 歪斜角（弧度）。
        var rot: Double
        /// 转正后的正文栏左 / 右边缘（原始显示空间 pt，绕页中心转正后的坐标）；测不到为 nil。
        var left: Double?
        var right: Double?
        /// 共用该边缘的行数。
        var supportL: Int
        var supportR: Int
        /// 转正后切出的文字行数（任意宽度）。少于 3 行 → 歪斜角不可信。
        var textLines: Int
        var sw: Double
        var sh: Double

        static func blank(sw: Double, sh: Double) -> Measure {
            Measure(rot: 0, left: nil, right: nil, supportL: 0, supportR: 0, textLines: 0, sw: sw, sh: sh)
        }
    }

    /// - Parameters:
    ///   - gray: 8 位灰度，**第 0 行是页面顶部**，行宽 = `width`。
    ///   - pxPerPt: `gray` 的像素/pt。
    ///   - pageSize: 原始显示空间页尺寸（pt）。
    ///
    /// 🔴 **最内层循环一律走裸指针 + `while`**，别改回数组 / `for in`：Debug 包（-Onone）里数组下标、`append`、
    /// 区间迭代器都是真函数调用，整篇测量慢 22 倍（228 页 2.2s → 49s，实测；`@_optimize(speed)` 单加在函数上
    /// 只快到 46s——嵌套函数和标准库泛型调用它管不到）。指针下标在 -Onone 下也会内联。
    @_optimize(speed)
    static func measure(gray: UnsafeBufferPointer<UInt8>, width pw: Int, height ph: Int,
                        pxPerPt S: Double, pageSize: CGSize) -> Measure {
        let sw = Double(pageSize.width), sh = Double(pageSize.height)
        guard pw > 8, ph > 8, gray.count >= pw * ph, sw > 1, sh > 1, let src = gray.baseAddress
        else { return .blank(sw: sw, sh: sh) }
        // 尺寸口径：常数按 500pt 宽的书页调出来，别的开本按页宽等比放缩。
        let k = max(0.5, min(3, sw / 500))

        // ① 暗像素（pt 坐标），去掉 6pt 页边（扫描边缘的黑影）。先数再一次分配（逐个 append 在 Debug 包里极慢）
        let margin = Int(6 * k * S)
        guard margin * 2 < pw, margin * 2 < ph else { return .blank(sw: sw, sh: sh) }
        let x0 = margin, x1 = pw - margin, y0 = margin, y1 = ph - margin
        var n = 0
        var y = y0
        while y < y1 {
            var p = src + (y * pw + x0)
            var x = x0
            while x < x1 { if p.pointee < 140 { n += 1 }; p += 1; x += 1 }
            y += 1
        }
        guard n > 200 else { return .blank(sw: sw, sh: sh) }
        let xs = UnsafeMutablePointer<Float>.allocate(capacity: n), ys = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let rx = UnsafeMutablePointer<Float>.allocate(capacity: n), ry = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { xs.deallocate(); ys.deallocate(); rx.deallocate(); ry.deallocate() }
        let inv = Float(1 / S)
        var idx = 0
        y = y0
        while y < y1 {
            let fy = Float(y) * inv
            var p = src + (y * pw + x0)
            var x = x0
            while x < x1 {
                if p.pointee < 140 { xs[idx] = Float(x) * inv; ys[idx] = fy; idx += 1 }
                p += 1; x += 1
            }
            y += 1
        }
        let cx = Float(sw / 2), cy = Float(sh / 2)

        // ② 歪斜角：投影轮廓的锐度。线性分摊到相邻两格——整格计数会在 0° 附近产生取整假峰
        //（像素行恰好对齐格子，0° 永远最「锐」，spike 实测 21 页因此被判成 0°）。
        let binsPerPt: Float = 0.8
        let nb = Int(Float(sw + sh) * binsPerPt) + 16
        let off = Float(nb / 2)
        let hist = UnsafeMutablePointer<Float>.allocate(capacity: nb)
        defer { hist.deallocate() }
        func score(_ deg: Double) -> Double {
            let t = Float(tan(deg * .pi / 180))
            hist.initialize(repeating: 0, count: nb)
            var i = 0
            while i < n {
                let fr = ((ys[i] - cy) - (xs[i] - cx) * t) * binsPerPt + off
                var r = Int(fr)                       // 向零取整 → 负数再减一 = 向下取整
                if Float(r) > fr { r -= 1 }
                if r >= 0 && r + 1 < nb {
                    let f = fr - Float(r)
                    hist[r] += 1 - f
                    hist[r + 1] += f
                }
                i += 1
            }
            var s = 0.0
            var j = 1
            while j < nb { let d = Double(hist[j] - hist[j - 1]); s += d * d; j += 1 }
            return s
        }
        var bestDeg = 0.0, bestScore = -1.0
        for step in -30...30 {
            let a = Double(step) * 0.1
            let sc = score(a)
            if sc > bestScore { bestScore = sc; bestDeg = a }
        }
        let coarse = bestDeg
        for step in -10...10 where step != 0 {
            let a = coarse + Double(step) * 0.01
            let sc = score(a)
            if sc > bestScore { bestScore = sc; bestDeg = a }
        }
        let rot = bestDeg * .pi / 180

        // ③ 转正：绕页中心，与 `PageAlign.toAligned` 同一组式子（不含平移）
        let c = Float(cos(rot)), s = Float(sin(rot))
        var i = 0
        while i < n {
            let u = xs[i] - cx, v = ys[i] - cy
            rx[i] = c * u + s * v + cx
            ry[i] = -s * u + c * v + cy
            i += 1
        }

        // ④ 切行：0.5pt 一格，自适应阈值（扫描底噪 / 行间的零星墨点不该把两行连成一行）
        let rb: Float = 2
        let pad: Float = 20
        let rh = Int((Float(sh) + pad * 2) * rb)
        let rowCount = UnsafeMutablePointer<Int32>.allocate(capacity: rh)
        let bandOf = UnsafeMutablePointer<Int32>.allocate(capacity: rh)
        defer { rowCount.deallocate(); bandOf.deallocate() }
        rowCount.initialize(repeating: 0, count: rh)
        bandOf.initialize(repeating: -1, count: rh)
        i = 0
        while i < n {
            let r = Int((ry[i] + pad) * rb)
            if r >= 0 && r < rh { rowCount[r] += 1 }
            i += 1
        }
        var positive: [Int32] = []
        for r in 0..<rh where rowCount[r] > 0 { positive.append(rowCount[r]) }
        positive.sort()
        let p90 = positive.isEmpty ? 3 : positive[min(positive.count - 1, positive.count * 9 / 10)]
        let thr = max(Int32(3), p90 / 8)
        var bands: [(Int, Int)] = []
        y = 0
        while y < rh {
            if rowCount[y] >= thr {
                let a = y
                var z = y
                while z + 1 < rh, rowCount[z + 1] >= thr { z += 1 }
                // 1.5pt 以内的碎缝并进上一行（像素行与 0.5pt 的格子错位会在行中间留空格）
                if let last = bands.last, a - last.1 <= 3 { bands[bands.count - 1].1 = z } else { bands.append((a, z)) }
                y = z + 1
            } else {
                y += 1
            }
        }
        for (bi, b) in bands.enumerated() { for r in b.0...b.1 { bandOf[r] = Int32(bi) } }
        // 每行一段按 1pt 分格的列计数，平铺在一块缓冲里（第 bi 行 = cols[bi*cw ..< (bi+1)*cw]）
        let cw = Int(sw) + 2
        let nbands = bands.count
        let cols = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, nbands * cw))
        defer { cols.deallocate() }
        cols.initialize(repeating: 0, count: max(1, nbands * cw))
        var bandHasInk = [Bool](repeating: false, count: nbands)
        i = 0
        while i < n {
            let r = Int((ry[i] + pad) * rb)
            if r >= 0 && r < rh {
                let bi = Int(bandOf[r])
                if bi >= 0 {
                    let xi = Int(rx[i])
                    if xi >= 0 && xi < cw { cols[bi * cw + xi] += 1; bandHasInk[bi] = true }
                }
            }
            i += 1
        }

        // ⑤ 每行左右边缘（连续 8pt 里至少 3pt 有墨，防零星噪点），只收宽度 ≥ 半页的行
        var lefts: [Double] = [], rights: [Double] = []
        var textLines = 0
        let minH = 7 * k, maxH = 20 * k
        let win = max(4, Int(8 * k)), need = max(2, win * 3 / 8)
        for (bi, b) in bands.enumerated() {
            let lh = Double(b.1 - b.0 + 1) / Double(rb)
            guard lh >= minH, lh <= maxH, bandHasInk[bi] else { continue }
            let col = cols + bi * cw
            func occ(_ lo: Int, _ hi: Int) -> Int {
                var m = 0
                var q = max(0, lo)
                let e = min(cw, hi)
                while q < e { if col[q] > 0 { m += 1 }; q += 1 }
                return m
            }
            var l = -1
            var q = 0
            while q < cw { if col[q] > 0 && occ(q, q + win) >= need { l = q; break }; q += 1 }
            var r = -1
            q = cw - 1
            while q >= 0 { if col[q] > 0 && occ(q - win + 1, q + 1) >= need { r = q; break }; q -= 1 }
            guard l >= 0, r >= 0 else { continue }
            let span = Double(r - l)
            guard span >= 60 * k else { continue }
            textLines += 1
            guard span >= 0.5 * sw else { continue }
            lefts.append(Double(l)); rights.append(Double(r))
        }

        // ⑥ 边缘 = 至少 25% 的行（且 ≥3 行）共用的最左 / 最右位置
        func cluster(_ v: [Double], fromLow: Bool) -> (Double?, Int) {
            guard !v.isEmpty else { return (nil, 0) }
            let need = max(3, v.count / 4)
            let tol = 2.5 * k
            for cand in (fromLow ? v.sorted() : v.sorted(by: >)) {
                let sup = v.filter { abs($0 - cand) <= tol }.sorted()
                if sup.count >= need { return (sup[sup.count / 2], sup.count) }
            }
            return (nil, 0)
        }
        let (L, sl) = cluster(lefts, fromLow: true)
        let (R, sr) = cluster(rights, fromLow: false)
        return Measure(rot: textLines >= 3 ? rot : 0, left: L, right: R, supportL: sl, supportR: sr,
                       textLines: textLines, sw: sw, sh: sh)
    }
}

// MARK: - 整篇定中心

/// 各页测量 → 参数表（方案 §6.4）。
enum ScanAlignSolver {
    static func solve(_ ms: [ScanAlignDetector.Measure]) -> ScanAlignTable {
        guard !ms.isEmpty else { return ScanAlignTable(width: 1, pages: []) }
        let width = median(ms.map(\.sw)) ?? ms[0].sw
        let k = max(0.5, min(3, width / 500))

        // 栏宽：两边都有 ≥5 行支撑的页，先取中位数，再只留与它相差 3% 以内的重算一次
        let firm = ms.compactMap { m -> Double? in
            guard let l = m.left, let r = m.right, m.supportL >= 5, m.supportR >= 5 else { return nil }
            return r - l
        }
        var colW = median(firm)
        if let c = colW { colW = median(firm.filter { abs($0 - c) <= c * 0.03 }) ?? c }

        // 每页「正文栏中心相对页中心」的偏移（pt）
        var strong = [Double?](repeating: nil, count: ms.count)
        if let colW {
            for (i, m) in ms.enumerated() {
                guard let l = m.left, let r = m.right, m.supportL >= 3, m.supportR >= 3,
                      abs(r - l - colW) <= 4 * k else { continue }
                strong[i] = (l + r) / 2 - m.sw / 2
            }
        }

        var pages: [ScanAlignTable.Page] = []
        pages.reserveCapacity(ms.count)
        for (i, m) in ms.enumerated() {
            var cands: [Double] = []
            if let s = strong[i] { cands.append(s) }
            if let colW, let r = m.right, m.supportR >= 3 { cands.append(r - colW / 2 - m.sw / 2) }
            if let colW, let l = m.left, m.supportL >= 3 { cands.append(l + colW / 2 - m.sw / 2) }
            // 前后 8 页内同奇偶页（书页左右页版心位置不同）的可靠值
            let lo = max(0, i - 8), hi = min(ms.count - 1, i + 8)
            let near = stride(from: lo, through: hi, by: 1)
                .filter { $0 != i && ($0 - i) % 2 == 0 }
                .compactMap { strong[$0] }
            let prior = median(near)
            let offset: Double
            if let prior {
                offset = cands.first { abs($0 - prior) <= 8 * k } ?? prior
            } else {
                offset = cands.first ?? 0
            }
            pages.append(ScanAlignTable.Page(rot: m.rot, dx: -offset, dy: 0, sw: m.sw, sh: m.sh))
        }
        return ScanAlignTable(width: width, pages: pages)
    }

    static func median(_ a: [Double]) -> Double? {
        guard !a.isEmpty else { return nil }
        let s = a.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
