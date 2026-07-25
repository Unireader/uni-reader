import Foundation

/// 二进制线格式编解码器（契约见 `PROTOCOL.md`；逐字节镜像 `Sources/Resources/wire.js`）。
///
/// 设计：**换序列化器、不换对象模型**。上层（`AppModel`/`handleInk`/各 `broadcast*`）仍在
/// `[String: Any]` 上工作，`WireCodec` 只是 `JSONSerialization` 的替身——
/// - `encode([String:Any]) -> Data?`：把 Mac→平板 的字典打成二进制帧。
/// - `decode(Data) -> [String:Any]?`：把平板→Mac 的二进制帧解成**与旧 JSON 同形**的字典
///   （数字→`NSNumber`、点集→`[[NSNumber]]`、`pen`→`[String:Any]`，故 `handleInk` 零改动）。
///
/// 全部小端。一帧 = `[u8 opcode][payload]`。仅依赖 Foundation（自带 CSS 颜色解析，
/// 不牵扯 `InkModel`），故 `spike/wire-codec-test.swift` 可单文件 `swiftc` 编译。
enum WireCodec {

    // MARK: opcode / 枚举映射

    enum Op {
        static let auth: UInt8 = 0x01, authOK: UInt8 = 0x02, authFail: UInt8 = 0x03
        static let ping: UInt8 = 0x10, pong: UInt8 = 0x11, latency: UInt8 = 0x12
        static let selectDoc: UInt8 = 0x20, pageTurn: UInt8 = 0x21, mode: UInt8 = 0x22, pen: UInt8 = 0x23
        static let page: UInt8 = 0x30, layout: UInt8 = 0x31, viewport: UInt8 = 0x32
        static let docs: UInt8 = 0x33, pens: UInt8 = 0x34, inkCancel: UInt8 = 0x35, strokes: UInt8 = 0x36
        static let scroll: UInt8 = 0x40, hover: UInt8 = 0x41, ink: UInt8 = 0x42, erase: UInt8 = 0x43, probe: UInt8 = 0x44
    }

    private static let brushes = ["ballpoint", "fountain", "marker", "pencil"]
    private static let modes = ["note", "erase", "page"]
    private static let phaseBegin: UInt8 = 0, phaseMove: UInt8 = 1, phaseEnd: UInt8 = 2

    static func brushCode(_ t: String) -> UInt8 { UInt8(brushes.firstIndex(of: t) ?? 0) }
    static func brushName(_ c: UInt8) -> String { Int(c) < brushes.count ? brushes[Int(c)] : "ballpoint" }
    static func modeCode(_ m: String) -> UInt8 { UInt8(modes.firstIndex(of: m) ?? 0) }
    static func modeName(_ c: UInt8) -> String { Int(c) < modes.count ? modes[Int(c)] : "note" }
    static func phaseCode(_ p: String) -> UInt8 { p == "begin" ? phaseBegin : (p == "end" ? phaseEnd : phaseMove) }
    static func phaseName(_ c: UInt8) -> String { c == phaseBegin ? "begin" : (c == phaseEnd ? "end" : "move") }

    /// `"rgba(24,90,210,0.95)"` → (r,g,b,a)；与 wire.js 的 `parseColor` 同规则。
    static func parseColor(_ css: String) -> (UInt8, UInt8, UInt8, Float) {
        guard let open = css.firstIndex(of: "("), let close = css.firstIndex(of: ")"), open < close else {
            return (0, 0, 0, 1)
        }
        let parts = css[css.index(after: open)..<close]
            .split(separator: ",")
            .map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        let r = UInt8(clamping: Int(parts.count > 0 ? parts[0] : 0))
        let g = UInt8(clamping: Int(parts.count > 1 ? parts[1] : 0))
        let b = UInt8(clamping: Int(parts.count > 2 ? parts[2] : 0))
        let a = Float(parts.count > 3 ? parts[3] : 1)
        return (r, g, b, a)
    }
    static func cssColor(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: Float) -> String {
        "rgba(\(r),\(g),\(b),\(a))"
    }

    // MARK: - 从 [String: Any] 取值（兼容 NSNumber / Int / Double / Bool）

    private static func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }
    private static func intOf(_ v: Any?) -> Int { Int(num(v)) }
    private static func boolOf(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }
    private static func strOf(_ v: Any?) -> String { v as? String ?? "" }
    /// 把任意点集（`[[Double]]`/`[[NSNumber]]`/`[[Any]]`）规整为 `[[Double]]`。
    private static func pairsOf(_ v: Any?) -> [[Double]] {
        if let a = v as? [[Double]] { return a }
        if let a = v as? [[NSNumber]] { return a.map { $0.map { $0.doubleValue } } }
        if let a = v as? [[Any]] { return a.map { $0.map { num($0) } } }
        return []
    }

    // MARK: - Writer

    private struct BW {
        var d = Data()
        mutating func u8(_ v: UInt8) { d.append(v) }
        mutating func putU32(_ x: UInt32) {
            d.append(UInt8(x & 0xff)); d.append(UInt8((x >> 8) & 0xff))
            d.append(UInt8((x >> 16) & 0xff)); d.append(UInt8((x >> 24) & 0xff))
        }
        mutating func u16(_ v: Int) {
            let x = UInt16(truncatingIfNeeded: v)
            d.append(UInt8(x & 0xff)); d.append(UInt8((x >> 8) & 0xff))
        }
        mutating func u32(_ v: Int) { putU32(UInt32(truncatingIfNeeded: v)) }
        mutating func f32(_ v: Double) { putU32(Float(v).bitPattern) }
        mutating func f64(_ v: Double) {
            let x = v.bitPattern
            for i in 0..<8 { d.append(UInt8((x >> (UInt64(i) * 8)) & 0xff)) }
        }
        mutating func str(_ s: String) {
            let b = Array(s.utf8.prefix(65535))
            u16(b.count); d.append(contentsOf: b)
        }
        mutating func pen(color: String, w: Double, t: String) {
            let (r, g, b, a) = WireCodec.parseColor(color)
            u8(r); u8(g); u8(b); f32(Double(a)); f32(w); u8(WireCodec.brushCode(t))
        }
        mutating func pts(_ arr: [[Double]], dim: Int) {
            u16(arr.count)
            for p in arr {
                f32(p.count > 0 ? p[0] : 0); f32(p.count > 1 ? p[1] : 0)
                if dim == 3 { f32(p.count > 2 ? p[2] : 0.5) }
            }
        }
    }

    private static func penDict(_ v: Any?) -> (String, Double, String) {
        let p = v as? [String: Any]
        return (strOf(p?["color"]), num(p?["w"]), strOf(p?["t"]))
    }

    /// 编码一条 Mac→平板（及测试用的平板→Mac）字典为二进制帧。未知 type 返回 nil。
    static func encode(_ o: [String: Any]) -> Data? {
        var w = BW()
        switch o["type"] as? String ?? "" {
        case "auth": w.u8(Op.auth); w.str(strOf(o["token"]))
        case "authOK": w.u8(Op.authOK)
        case "authFail": w.u8(Op.authFail)
        case "ping": w.u8(Op.ping); w.f64(num(o["t"]))
        case "pong": w.u8(Op.pong); w.f64(num(o["t"]))
        case "latency": w.u8(Op.latency); w.f32(num(o["ms"]))
        case "selectDoc": w.u8(Op.selectDoc); w.str(strOf(o["id"]))
        case "pageTurn": w.u8(Op.pageTurn); w.u8(strOf(o["dir"]) == "prev" ? 0 : 1)
        case "mode": w.u8(Op.mode); w.u8(modeCode(strOf(o["mode"])))
        case "pen": w.u8(Op.pen); w.u16(intOf(o["index"]))
        case "page":
            w.u8(Op.page); w.u32(intOf(o["v"])); w.u32(intOf(o["index"]))
            w.u32(intOf(o["count"])); w.f32(num(o["w"])); w.f32(num(o["h"]))
        case "layout":
            w.u8(Op.layout); w.str(strOf(o["docId"])); w.str(strOf(o["v"]))
            let pages = pairsOf(o["pages"]); let c = intOf(o["count"])
            w.u32(c != 0 ? c : pages.count)
            for p in pages { w.f32(p.count > 0 ? p[0] : 0); w.f32(p.count > 1 ? p[1] : 0) }
        case "viewport":
            w.u8(Op.viewport); w.u32(intOf(o["page"])); w.f32(num(o["frac"]))
            w.u32(intOf(o["seq"])); w.u8(boolOf(o["force"]) ? 1 : 0)
        case "docs":
            w.u8(Op.docs); w.u8(boolOf(o["following"]) ? 1 : 0); w.str(strOf(o["selected"]))
            let list = o["list"] as? [[String: Any]] ?? []
            w.u16(list.count)
            for d in list { w.str(strOf(d["id"])); w.str(strOf(d["title"])) }
        case "pens":
            w.u8(Op.pens); w.u16(intOf(o["active"]))
            let list = o["list"] as? [[String: Any]] ?? []
            w.u16(list.count)
            for p in list { w.pen(color: strOf(p["color"]), w: num(p["w"]), t: strOf(p["t"])) }
        case "inkCancel": w.u8(Op.inkCancel)
        case "strokes":
            w.u8(Op.strokes)
            let list = o["list"] as? [[String: Any]] ?? []
            w.u32(list.count)
            for s in list {
                w.u32(intOf(s["page"]))
                let (c, ww, t) = penDict(s["pen"])
                w.pen(color: c, w: ww, t: t)
                w.pts(pairsOf(s["pts"]), dim: 3)
            }
        case "scroll": w.u8(Op.scroll); w.u32(intOf(o["page"])); w.f32(num(o["frac"])); w.f64(num(o["t"]))
        case "hover":
            w.u8(Op.hover)
            if strOf(o["phase"]) == "end" { w.u8(phaseEnd) }
            else { w.u8(phaseMove); w.u32(intOf(o["page"])); w.f32(num(o["nx"])); w.f32(num(o["ny"])) }
        case "ink":
            w.u8(Op.ink); let ph = strOf(o["phase"]); w.u8(phaseCode(ph))
            if ph == "begin" {
                w.u32(intOf(o["page"]))
                let (c, ww, t) = penDict(o["pen"]); w.pen(color: c, w: ww, t: t)
                w.pts(pairsOf(o["pts"]), dim: 3)
            } else if ph == "move" { w.pts(pairsOf(o["pts"]), dim: 3) }
        case "erase":
            w.u8(Op.erase); let ph = strOf(o["phase"]); w.u8(phaseCode(ph))
            if ph == "move" { w.u32(intOf(o["page"])); w.pts(pairsOf(o["pts"]), dim: 2) }
        case "probe":
            w.u8(Op.probe); let ph = strOf(o["phase"]); w.u8(phaseCode(ph))
            if ph == "begin" { w.u32(intOf(o["page"])); w.pts(pairsOf(o["pts"]), dim: 2) }
            else if ph == "move" { w.pts(pairsOf(o["pts"]), dim: 2) }
        default: return nil
        }
        return w.d
    }

    // MARK: - Reader

    private struct BR {
        let d: [UInt8]; var n = 0; var ok = true
        init(_ data: Data) { d = [UInt8](data) }
        mutating func need(_ k: Int) -> Bool {
            if k < 0 || n + k > d.count { ok = false; return false }
            return true
        }
        mutating func u8() -> UInt8 { guard need(1) else { return 0 }; let v = d[n]; n += 1; return v }
        mutating func u16() -> Int { guard need(2) else { return 0 }; let v = Int(d[n]) | (Int(d[n + 1]) << 8); n += 2; return v }
        mutating func u32raw() -> UInt32 {
            guard need(4) else { return 0 }
            let v = UInt32(d[n]) | (UInt32(d[n + 1]) << 8) | (UInt32(d[n + 2]) << 16) | (UInt32(d[n + 3]) << 24)
            n += 4; return v
        }
        mutating func u32() -> Int { Int(u32raw()) }
        mutating func f32() -> Double { Double(Float(bitPattern: u32raw())) }
        mutating func f64() -> Double {
            guard need(8) else { return 0 }
            var x: UInt64 = 0
            for i in 0..<8 { x |= UInt64(d[n + i]) << (UInt64(i) * 8) }
            n += 8; return Double(bitPattern: x)
        }
        mutating func str() -> String {
            let L = u16(); guard need(L) else { return "" }
            let s = String(decoding: d[n..<n + L], as: UTF8.self); n += L; return s
        }
        mutating func pen() -> [String: Any] {
            let r = u8(), g = u8(), b = u8(); let a = f32(); let w = f32(); let t = u8()
            return ["color": WireCodec.cssColor(r, g, b, Float(a)), "w": NSNumber(value: w), "t": WireCodec.brushName(t)]
        }
        mutating func pts(_ dim: Int) -> [[NSNumber]] {
            let m = u16()
            guard need(m * dim * 4) else { return [] }
            var out = [[NSNumber]](); out.reserveCapacity(m)
            for _ in 0..<m {
                let x = f32(), y = f32()
                if dim == 3 { let p = f32(); out.append([NSNumber(value: x), NSNumber(value: y), NSNumber(value: p)]) }
                else { out.append([NSNumber(value: x), NSNumber(value: y)]) }
            }
            return out
        }
    }

    /// 解码一帧为字典（形状同旧 JSON）。空/越界/未知 opcode → nil。
    static func decode(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        var r = BR(data)
        let op = r.u8()
        var out: [String: Any]?
        switch op {
        case Op.auth: out = ["type": "auth", "token": r.str()]
        case Op.authOK: out = ["type": "authOK"]
        case Op.authFail: out = ["type": "authFail"]
        case Op.ping: out = ["type": "ping", "t": NSNumber(value: r.f64())]
        case Op.pong: out = ["type": "pong", "t": NSNumber(value: r.f64())]
        case Op.latency: out = ["type": "latency", "ms": NSNumber(value: r.f32())]
        case Op.selectDoc: out = ["type": "selectDoc", "id": r.str()]
        case Op.pageTurn: out = ["type": "pageTurn", "dir": r.u8() == 0 ? "prev" : "next"]
        case Op.mode: out = ["type": "mode", "mode": modeName(r.u8())]
        case Op.pen: out = ["type": "pen", "index": NSNumber(value: r.u16())]
        case Op.page:
            let v = r.u32(), idx = r.u32(), cnt = r.u32(), pw = r.f32(), ph = r.f32()
            out = ["type": "page", "v": NSNumber(value: v), "index": NSNumber(value: idx),
                   "count": NSNumber(value: cnt), "w": NSNumber(value: pw), "h": NSNumber(value: ph)]
        case Op.layout:
            let docId = r.str(), v = r.str(), count = r.u32()
            var pages = [[NSNumber]](); pages.reserveCapacity(max(0, count))
            if r.need(count * 8) {
                for _ in 0..<max(0, count) { pages.append([NSNumber(value: r.f32()), NSNumber(value: r.f32())]) }
            }
            out = ["type": "layout", "docId": docId, "v": v, "count": NSNumber(value: count), "pages": pages]
        case Op.viewport:
            let page = r.u32(), frac = r.f32(), seq = r.u32(), force = r.u8() == 1
            out = ["type": "viewport", "page": NSNumber(value: page), "frac": NSNumber(value: frac),
                   "seq": NSNumber(value: seq), "force": force]
        case Op.docs:
            let following = r.u8() == 1, selected = r.str(), n = r.u16()
            var list = [[String: Any]](); list.reserveCapacity(n)
            for _ in 0..<n { list.append(["id": r.str(), "title": r.str()]) }
            out = ["type": "docs", "list": list, "selected": selected, "following": following]
        case Op.pens:
            let active = r.u16(), n = r.u16()
            var list = [[String: Any]](); list.reserveCapacity(n)
            for _ in 0..<n { list.append(r.pen()) }
            out = ["type": "pens", "list": list, "active": NSNumber(value: active)]
        case Op.inkCancel: out = ["type": "inkCancel"]
        case Op.strokes:
            let n = r.u32()
            var list = [[String: Any]](); list.reserveCapacity(max(0, n))
            for _ in 0..<max(0, n) {
                let page = r.u32(); let pen = r.pen(); let pts = r.pts(3)
                list.append(["page": NSNumber(value: page), "pen": pen, "pts": pts])
            }
            out = ["type": "strokes", "list": list]
        case Op.scroll:
            let page = r.u32(), frac = r.f32(), t = r.f64()
            out = ["type": "scroll", "page": NSNumber(value: page), "frac": NSNumber(value: frac), "t": NSNumber(value: t)]
        case Op.hover:
            let ph = r.u8()
            if ph == phaseEnd { out = ["type": "hover", "phase": "end"] }
            else {
                let page = r.u32(), nx = r.f32(), ny = r.f32()
                out = ["type": "hover", "page": NSNumber(value: page), "nx": NSNumber(value: nx), "ny": NSNumber(value: ny)]
            }
        case Op.ink:
            let ph = r.u8()
            if ph == phaseBegin {
                let page = r.u32(); let pen = r.pen(); let pts = r.pts(3)
                out = ["type": "ink", "phase": "begin", "page": NSNumber(value: page), "pen": pen, "pts": pts]
            } else if ph == phaseMove {
                out = ["type": "ink", "phase": "move", "pts": r.pts(3)]
            } else { out = ["type": "ink", "phase": "end"] }
        case Op.erase:
            let ph = r.u8()
            if ph == phaseMove {
                let page = r.u32(); let pts = r.pts(2)
                out = ["type": "erase", "phase": "move", "page": NSNumber(value: page), "pts": pts]
            } else { out = ["type": "erase", "phase": "end"] }
        case Op.probe:
            let ph = r.u8()
            if ph == phaseBegin {
                let page = r.u32(); let pts = r.pts(2)
                out = ["type": "probe", "phase": "begin", "page": NSNumber(value: page), "pts": pts]
            } else if ph == phaseMove {
                out = ["type": "probe", "phase": "move", "pts": r.pts(2)]
            } else { out = ["type": "probe", "phase": "end"] }
        default: return nil   // 未知 opcode：丢弃
        }
        return r.ok ? out : nil
    }
}
