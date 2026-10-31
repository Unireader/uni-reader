import Foundation

/// 服务器出图（方案 `WEB-READER-PLAN.md §11`，2026-10-30 用户定）：用 MuPDF 的命令行把 PDF 的一页画成 JPEG，
/// 网页直接显示图片，不用在浏览器里加载 pdf.js（扫描书在 pdf.js 里打开时要把每一页的页面对象读一遍，§10.5）。
///
/// - 工具：`mutool`（mupdf-tools）画页、读页面尺寸与目录；`cjpeg`（libjpeg-turbo-progs）压 JPEG。
///   没装 = 不可用，网页退回浏览器加载。Debian：`apt-get install mupdf-tools libjpeg-turbo-progs`。
///   NAS 上是 1.17（2026-10-30 实测：134 页的书读尺寸 + 目录 0.14 秒；1280 宽画一页 0.5～0.6 秒 + 压缩 0.2 秒，每页约 200～290KB）。
/// - 缓存：`<数据目录>/cache/render/<内容哈希>/`：[infoFile]（各页尺寸 + 目录）、`p<页>-w<宽>.jpg`。
///   内容哈希定了图就不会变；超过上限按最近用过的时间删旧的（`prune`）。
/// - 宽度只出 [widths] 这几档（网页要多宽就往上取一档），特别细长的页按像素上限压窄。
/// - 扫描页不比扫描图本身画得更宽（2026-10-30 用户定：「扫描件本身是有分辨率上限的」）：再宽也不会更清楚，只是更慢、更大。
///   扫描图多宽是读尺寸时一起量的（[infoScript]）；NAS 上的扫描书大多 1000～1450 像素宽，Mac 的网页却要 2560～3200。
///   高分辨率扫描（超过 [halveAbove]）最多画到原图的一半（[scanLimit]）。
/// - 同时最多画 [renderers] 页（NAS 是 6 核的 ARM）；同一张图同时有人要，只画一次、其余的等它。
///   正在看的页先画（2026-10-31 用户定）：网页要的页后要的先轮到，提前画的后几页只在没有别的要画时才画（[RenderGate]）。
/// 阻塞调用（跑子进程、读写文件），HTTP 层经 `Blocking.run` 调。
public final class PageImages: @unchecked Sendable {
    public static let widths = [480, 720, 960, 1280, 1600, 2048, 2560, 3200]
    static let maxPixels = 12_000_000.0
    static let renderers = 2
    /// 扫描图超过这么宽（高分辨率扫描）就最多画到它的一半（2026-10-31 用户定）：画到原图一半以下时 MuPDF 只解开一半大小的原图，
    /// NAS 上快一倍（4268 宽的页画 2560 宽 2.7 秒、画 2130 宽 1.3 秒）；代价是放大看时不如原图细。
    public static let halveAbove = 4000
    /// 扫描页：网页要的那一档离上限（[scanLimit]）不到两成，就直接按上限画（2026-10-31 用户定）。
    /// 不然放大缩小各画一份几乎一样大的（上限 2130 的书，2048 档、2560 档各一份），白画一次、多等 1～2 秒。
    public static let nearLimit = 1.2
    /// 等着提前画的最多留几张（翻得快时，早先那几页的就不画了）。
    static let aheadLimit = 8
    static let timeout: TimeInterval = 90
    /// 各页尺寸 + 目录的缓存文件；内容格式变了就换个名字（旧的不再用，按最久没用的删掉）。
    static let infoFile = "info-2.json"

    public let root: URL
    public let mutool: URL?
    public let cjpeg: URL?
    public let limitBytes: Int64
    private let lock = NSLock()
    private var running: [String: DispatchGroup] = [:]
    private let gate = RenderGate(slots: renderers)
    private var ahead: [Ahead] = []
    private var aheadRunning = false
    private let sizes = LockedCache<String, [[Double]]>()
    private var rendersSincePrune = 0

    public var available: Bool { mutool != nil && cjpeg != nil }

    /// [searchPath] 不给就按 `PATH` 再加几个常见目录找工具（systemd 下 `PATH` 可能很短）。
    public init(root: URL, limitBytes: Int64, searchPath: [String]? = nil) {
        self.root = root
        self.limitBytes = limitBytes
        let dirs = searchPath ?? ((ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"])
        func find(_ name: String) -> URL? {
            dirs.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        mutool = find("mutool")
        cjpeg = find("cjpeg")
    }

    /// 启动信息里的一行。
    public var summary: String {
        guard let mutool, let cjpeg else {
            return "不可用：没找到 mutool / cjpeg（Debian：apt-get install mupdf-tools libjpeg-turbo-progs），网页只能用浏览器加载"
        }
        return "可用（\(mutool.path)、\(cjpeg.path)；缓存 \(root.path)，上限 \(limitBytes / 1_048_576)MB）"
    }

    /// 网页要 [width] 像素宽：往上取一档（超过最宽的一档按最宽的）。
    public static func bucket(_ width: Int) -> Int { widths.first { $0 >= width } ?? widths.last! }

    /// 扫描页最多画多宽（[native] = 扫描图本身多宽）。超过 [halveAbove] 的取一半再少 4 像素：
    /// MuPDF 要「画出来的宽 ≤ 原图宽 / 2 - 2」才按一半解（NAS 实测：4268 宽的页画 2130 宽 1.3 秒、2140 宽 2.1 秒）。
    public static func scanLimit(_ native: Int) -> Int {
        native > halveAbove ? native / 2 - 4 : native
    }

    /// 一页实际出多宽：按档；扫描页不超过 [scanLimit]，离上限不到两成的直接按上限（[nearLimit]，同样不超过最宽的一档）；
    /// [native] = 扫描图多宽，0 = 不是扫描页 / 量不出来；页太细长时按像素上限压窄（[w] × [h] = 页的尺寸，任何单位）。
    static func renderWidth(bucket: Int, w: Double, h: Double, native: Int = 0) -> Int {
        var want = bucket
        if native > 0 {
            let limit = scanLimit(native)
            if Double(bucket) * nearLimit >= Double(limit) { want = min(limit, widths.last!) }
        }
        guard w > 0, h > 0 else { return max(1, want) }
        let cap = Int((maxPixels * w / h).squareRoot())
        return max(1, min(want, cap))
    }

    // MARK: - 页面尺寸与目录

    /// 整本书各页的显示尺寸（pt，已按 `/Rotate` 转正，CropBox 优先）、扫描图多宽与目录，JSON：
    /// `{"pages":[[w,h,n],…],"outline":[{"title":…,"page":从 0 起,"y":页内纵坐标 pt 或 null,"children":[…]}]}`，
    /// `n` = 这一页按扫描图本身的分辨率有多少像素宽（0 = 不是扫描页 / 量不出来，不设上限）。
    public func info(hash: String, pdf: URL) throws -> Data {
        guard let mutool else { throw ServerError.renderUnavailable }
        let out = folder(hash).appendingPathComponent(Self.infoFile)
        try ensure(key: "\(hash)/info", out: out) {
            let script = root.appendingPathComponent("info.js")
            if !FileManager.default.fileExists(atPath: script.path) || (try? Data(contentsOf: script)) != Data(Self.infoScript.utf8) {
                try Data(Self.infoScript.utf8).write(to: script, options: .atomic)
            }
            let r = try Self.run(mutool, ["run", script.path, pdf.path])
            guard r.status == 0, let json = r.stdout.split(separator: UInt8(ascii: "\n")).last.map({ Data($0) }),
                  (try? JSONSerialization.jsonObject(with: json)) is [String: Any] else {
                throw ServerError.renderFailed("读页面尺寸失败（mutool run 状态 \(r.status)）：\(r.stderrText)")
            }
            try Self.place(json, at: out)
        }
        return try Data(contentsOf: out)
    }

    /// 各页尺寸与扫描图宽度（`[w, h, n]`，读 [infoFile]，记在内存里）。
    public func pageSizes(hash: String, pdf: URL) throws -> [[Double]] {
        if let s = sizes.get(hash) { return s }
        let obj = try JSONSerialization.jsonObject(with: try info(hash: hash, pdf: pdf)) as? [String: Any]
        let pages = (obj?["pages"] as? [[Any]] ?? []).map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
        sizes.set(hash, pages)
        return pages
    }

    // MARK: - 出图

    /// 第 [index] 页（从 0 起）大约 [width] 像素宽的 JPEG（扫描页最多按扫描图本身的宽度）。没画过就现画（同时有人要同一张只画一次）。
    /// [urgent] = 网页正等着看；false = 提前画的，空闲时才画。
    public func page(hash: String, pdf: URL, index: Int, width: Int, urgent: Bool = true) throws -> URL {
        guard let mutool, let cjpeg else { throw ServerError.renderUnavailable }
        let all = try pageSizes(hash: hash, pdf: pdf)
        guard all.indices.contains(index) else { throw ServerError.badRequest("没有第 \(index + 1) 页") }
        let size = all[index]
        let w = Self.renderWidth(bucket: Self.bucket(width), w: size.first ?? 0, h: size.count > 1 ? size[1] : 0,
                                 native: size.count > 2 ? Int(size[2]) : 0)
        let dir = folder(hash)
        let out = dir.appendingPathComponent("p\(index)-w\(w).jpg")
        try ensure(key: out.path, out: out, urgent: urgent) {
            let tag = UUID().uuidString
            let pnm = dir.appendingPathComponent(".\(tag).pnm"), jpg = dir.appendingPathComponent(".\(tag).jpg")
            defer {
                try? FileManager.default.removeItem(at: pnm)
                try? FileManager.default.removeItem(at: jpg)
            }
            let d = try Self.run(mutool, ["draw", "-q", "-w", String(w), "-o", pnm.path, pdf.path, String(index + 1)])
            guard d.status == 0, FileManager.default.fileExists(atPath: pnm.path) else {
                throw ServerError.renderFailed("画第 \(index + 1) 页失败（mutool draw 状态 \(d.status)）：\(d.stderrText)")
            }
            let c = try Self.run(cjpeg, ["-quality", "80", "-optimize", "-progressive", "-outfile", jpg.path, pnm.path])
            guard c.status == 0, FileManager.default.fileExists(atPath: jpg.path) else {
                throw ServerError.renderFailed("压第 \(index + 1) 页失败（cjpeg 状态 \(c.status)）：\(c.stderrText)")
            }
            try Self.place(contentsOf: jpg, at: out)
            self.noteRendered()
        }
        return out
    }

    private struct Ahead: Equatable { let hash: String; let pdf: URL; let index: Int; let width: Int }

    /// 空闲时先画好接下来几页（顺着往下读时不用等）。已经有的、正在画的不重复画。
    /// 一次只画一张；后加的先画（翻到哪儿就先画哪儿的后几页），最多留 [aheadLimit] 张，再早的不画了。
    public func prefetch(hash: String, pdf: URL, after index: Int, width: Int, count: Int = 2) {
        lock.lock()
        for i in stride(from: index + count, through: index + 1, by: -1) {
            let a = Ahead(hash: hash, pdf: pdf, index: i, width: width)
            ahead.removeAll { $0 == a }
            ahead.append(a)
        }
        if ahead.count > Self.aheadLimit { ahead.removeFirst(ahead.count - Self.aheadLimit) }
        let start = !aheadRunning
        aheadRunning = true
        lock.unlock()
        if start { DispatchQueue.global(qos: .utility).async { self.drainAhead() } }
    }

    private func drainAhead() {
        while true {
            lock.lock()
            guard let a = ahead.popLast() else {
                aheadRunning = false
                lock.unlock()
                return
            }
            lock.unlock()
            // 超出页数的（最后几页）在 page 里报错，不管
            _ = try? page(hash: a.hash, pdf: a.pdf, index: a.index, width: a.width, urgent: false)
        }
    }

    // MARK: - 缓存

    func folder(_ hash: String) -> URL { root.appendingPathComponent(hash, isDirectory: true) }

    /// 缓存超过上限：按最近用过的时间（修改时间，取用时会更新）从旧到新删，删到上限的九成。
    public func prune() {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, url.lastPathComponent != "info.js" else { continue }
            let size = Int64(v.fileSize ?? 0)
            total += size
            files.append((url, size, v.contentModificationDate ?? .distantPast))
        }
        guard total > limitBytes else { return }
        for f in files.sorted(by: { $0.date < $1.date }) where total > limitBytes / 10 * 9 {
            if (try? fm.removeItem(at: f.url)) != nil { total -= f.size }
        }
        sizes.clear()
    }

    private func noteRendered() {
        lock.lock()
        rendersSincePrune += 1
        let due = rendersSincePrune >= 100
        if due { rendersSincePrune = 0 }
        lock.unlock()
        if due { DispatchQueue.global(qos: .background).async { self.prune() } }
    }

    /// 有就直接用（顺手更新时间，删旧的时它算新的）；没有就做，同一个 [key] 同时只做一次，别的等它做完。
    /// 不急的（[urgent] = false，提前画的）先等到空闲、轮到了才登记：排着队的不会挡住网页随后要看的同一页（那页自己画，不等它）。
    private func ensure(key: String, out: URL, urgent: Bool = true, _ make: () throws -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: out.path)
            return
        }
        if !urgent { gate.enter(urgent: false) }
        var holding = !urgent
        defer { if holding { gate.leave() } }
        lock.lock()
        if let g = running[key] {
            lock.unlock()
            if !urgent { return }   // 别人正在画，提前画的不用管
            g.wait()
            if fm.fileExists(atPath: out.path) { return }
            throw ServerError.renderFailed("同时在画的那次没画成")
        }
        let g = DispatchGroup()
        g.enter()
        running[key] = g
        lock.unlock()
        defer {
            lock.lock()
            running[key] = nil
            lock.unlock()
            g.leave()
        }
        if !holding {
            gate.enter(urgent: true)
            holding = true
        }
        if fm.fileExists(atPath: out.path) { return }
        try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try make()
    }

    /// 先写到旁边再改名：别人永远看不到写了一半的文件。
    private static func place(_ data: Data, at out: URL) throws {
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try place(contentsOf: tmp, at: out)
    }

    private static func place(contentsOf tmp: URL, at out: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: out.path) { try? fm.removeItem(at: tmp); return }
        try fm.moveItem(at: tmp, to: out)
    }

    // MARK: - 子进程

    struct RunResult {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var stderrText: String {
            String(decoding: stderr, as: UTF8.self).split(separator: "\n")
                .filter { !$0.contains("ICC support is not available") }   // 1.17 每次都说这一句，没用
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
    }

    /// 跑一个命令（不经过 shell，参数原样传），超时就杀掉。
    static func run(_ exe: URL, _ args: [String]) throws -> RunResult {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // 两路输出同时读（只读一路的话，另一路写满管道子进程就卡住）；错误输出在另一个线程读，读完才用
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let errDone = DispatchGroup()
        errDone.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            errDone.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        killer.cancel()
        return RunResult(status: p.terminationStatus, stdout: outData, stderr: errBox.data)
    }

    /// `mutool run` 跑的脚本（MuPDF 自带的 JavaScript，1.17 的接口）：各页尺寸 + 扫描图宽度 + 目录，一行 JSON。
    /// 目录项 1.17 带 `page`（从 0 起）与 `uri`（`#页,x,y`，页从 1 起、坐标是页面上的点）；没有 `page` 时从 `uri` 解。
    ///
    /// 扫描图多宽（`native`）：只看页面资源里登记的图（含继承的、表单里两层以内），取像素最多的那张，不读图的内容，
    /// 一本 586 页的书多花 0.1～0.3 秒（NAS 实测）。图的长宽比和页面（MediaBox）差 15% 以内才当作铺满整页的扫描图，
    /// 按「每 pt 多少像素」换算成显示宽度上的像素；折算下来不到 72dpi 的不算（文字版 PDF 里页面形状的小插图，实测有 196 像素宽的）。
    /// 量不准的情形（图只占半页却恰好是页面形状）宁可不设上限：那一页按网页要的宽度画，只是慢一点，不会糊。
    static let infoScript = """
    var doc = new Document(scriptArgs[0]);
    var n = doc.countPages(), pages = [], isPDF = doc.isPDF(), memo = {};
    function ok(o) { return o !== undefined && o !== null && !o.isNull(); }
    function num(o) { return ok(o) ? +o : 0; }
    function inherited(p, key) {
      for (var d = 0; ok(p) && d < 32; d++, p = p.get("Parent")) { var v = p.get(key); if (ok(v)) return v; }
      return null;
    }
    function biggest(res, depth) {
      if (!ok(res)) return [0, 0];
      var id = res.isIndirect() ? res.asIndirect() : 0;
      if (id && memo[id]) return memo[id];
      var best = [0, 0], xo = res.get("XObject");
      if (ok(xo) && xo.isDictionary()) xo.forEach(function (key, o) {
        if (!ok(o) || !o.isDictionary()) return;
        var sub = String(o.get("Subtype")).replace(/^\\//, ""), img;
        if (sub === "Image") img = [num(o.get("Width")), num(o.get("Height"))];
        else if (sub === "Form" && depth < 2) img = biggest(o.get("Resources"), depth + 1);
        else return;
        if (img[0] * img[1] > best[0] * best[1]) best = img;
      });
      if (id) memo[id] = best;
      return best;
    }
    function native(i, bw) {
      if (!isPDF) return 0;
      var p = doc.findPage(i), img = biggest(inherited(p, "Resources"), 0), box = inherited(p, "MediaBox");
      if (!img[0] || !img[1] || !ok(box)) return 0;
      var mw = Math.abs(num(box.get(2)) - num(box.get(0))), mh = Math.abs(num(box.get(3)) - num(box.get(1)));
      if (!mw || !mh) return 0;
      var ia = img[0] / img[1], ma = mw / mh;
      if (Math.abs(ia / ma - 1) > 0.15 && Math.abs(ia * ma - 1) > 0.15) return 0;
      var perPt = Math.sqrt(img[0] * img[1] / (mw * mh));
      return perPt < 1 ? 0 : Math.round(bw * perPt);
    }
    for (var i = 0; i < n; i++) {
      var b = doc.loadPage(i).bound(), w = b[2] - b[0], k = 0;
      try { k = native(i, w); } catch (e) {}
      pages.push([w, b[3] - b[1], k]);
    }
    function conv(items) {
      var out = [];
      for (var i = 0; i < items.length; i++) {
        var it = items[i], page = typeof it.page === "number" ? it.page : -1, y = null;
        var m = /^#(\\d+)(?:,([-\\d.]+),([-\\d.]+))?/.exec(it.uri || "");
        if (m) { if (page < 0) page = parseInt(m[1], 10) - 1; if (m[3] !== undefined) y = parseFloat(m[3]); }
        out.push({ title: it.title || "", page: page, y: y, children: it.down ? conv(it.down) : [] });
      }
      return out;
    }
    var outline = null;
    try { outline = doc.loadOutline(); } catch (e) {}
    print(JSON.stringify({ pages: pages, outline: outline ? conv(outline) : [] }));
    """
}

/// 画图的位置：同时最多 [slots] 张。网页正等着看的（urgent）先画，其中后要的先轮到——翻得快时，停下来的那页不用排在一路翻过的页后面；
/// 提前画的只在没有别的在画、也没有人在等时才画。
final class RenderGate: @unchecked Sendable {
    private let cond = NSCondition()
    private let slots: Int
    private var busy = 0
    private var waiting: [Int] = []   // 等着的 urgent，按来的先后；最后一个先轮到
    private var ticket = 0

    init(slots: Int) { self.slots = slots }

    func enter(urgent: Bool) {
        cond.lock()
        defer { cond.unlock() }
        if urgent {
            ticket += 1
            let me = ticket
            waiting.append(me)
            while busy >= slots || waiting.last != me { cond.wait() }
            waiting.removeLast()
        } else {
            while busy > 0 || !waiting.isEmpty { cond.wait() }
        }
        busy += 1
        cond.broadcast()   // 还有空位的话，下一个等着的可以进
    }

    func leave() {
        cond.lock()
        busy -= 1
        cond.broadcast()
        cond.unlock()
    }
}
