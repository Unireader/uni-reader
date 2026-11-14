import Foundation

// 套件第三批（2026-11-14，`ANIM-BLOCK-PLAN.md §13`）：组成原理「定点数的乘除运算」。
// `mul`：原码一位乘 / 补码一位乘（Booth）；`div`：原码恢复余数法 / 原码加减交替法（不恢复余数）/ 补码加减交替法。
// 画法照教材的运算表格：竖式 `sheet` 一行一个寄存器状态，「+」行是加数、下面一条横线、再下一行是和，移位单独一行，行尾注明做了什么。
// 数值全部用整数（按 2ⁿ 缩放）算，位串由它格式化出来。规矩同 `AnimKits.swift`；生成的文字与安卓 `AnimKits3.kt` 逐字相同（跨端向量）。

extension AnimKits {
    static let names3 = ["mul", "div"]

    static func generate3(_ name: String, _ a: inout Args, _ L: Words) throws -> Kit? {
        switch name {
        case "mul": return try mulKit(&a, L)
        case "div": return try divKit(&a, L)
        default: return nil
        }
    }

    // MARK: - 公用

    /// 定点小数 `-0.1101` / `0.1011` / `.101`（也认 `+`、`−`）；`allowInt` 时也认定点整数 `-1101`。返回符号、数值位、是不是整数。
    static func fraction(_ a: inout Args, _ k: String, usage: String, allowInt: Bool) throws -> (neg: Bool, bits: String, isInt: Bool) {
        guard var s = a.string(k) else { throw AnimParseError(usage) }
        var neg = false
        if s.hasPrefix("-") || s.hasPrefix("−") { neg = true; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        var isInt = false
        if s.hasPrefix("0.") { s.removeFirst(2) } else if s.hasPrefix(".") { s.removeFirst() } else if allowInt && !s.contains(".") { isInt = true } else { s = "" }
        guard s.count >= 1, s.count <= 8, s.allSatisfy({ $0 == "0" || $0 == "1" }) else {
            throw AnimParseError(allowInt ? "\(k)= is a binary fraction like -0.1101 or a binary integer like -1101 (1 to 8 bits)"
                                          : "\(k)= is a binary fraction like -0.1101 (1 to 8 bits after the point)")
        }
        return (neg, s, isInt)
    }

    /// 无符号位串，左补 0 到 width 位。
    static func binary(_ u: Int, _ width: Int) -> String {
        let s = String(u, radix: 2)
        return String(repeating: "0", count: max(width - s.count, 0)) + s
    }

    /// 定点位串：小数点前 intBits 位（补码的符号位，或原码乘法的进位位）、后 n 位；v 按 2ⁿ 缩放，负数取补码。
    /// 定点整数时 sep 传 `,`（教材写法 `11,0011`：逗号前是符号位，后面是数值位）。
    static func fixed(_ v: Int, _ intBits: Int, _ n: Int, _ sep: String = ".") -> String {
        let m = 1 << (intBits + n)
        let s = binary(((v % m) + m) % m, intBits + n)
        return String(s.prefix(intBits)) + sep + String(s.suffix(n))
    }

    /// 真值：-0.1101；定点整数（sep = `,`）是 -1101。
    static func trueValue(_ v: Int, _ n: Int, _ sep: String = ".") -> String {
        (v < 0 ? "-" : "") + (sep == "," ? binary(abs(v), n) : fixed(abs(v), 1, n))
    }

    static func superscriptMinus(_ n: Int) -> String { "⁻" + String(String(n).map { superscript[$0]! }) }

    private static func s3(_ caption: String, _ actions: [String]) -> [String] {
        ["step " + caption.replacingOccurrences(of: "#", with: "＃")] + actions.map { "  " + $0 }
    }

    /// 商位串：第一位后面加小数点（0、0.1、0.10 …）。
    private static func quotientText(_ bits: [Int]) -> String {
        let s = bits.map(String.init).joined()
        return bits.count > 1 ? String(s.prefix(1)) + "." + String(s.dropFirst()) : s
    }

    // MARK: - 乘法

    private static func mulKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let usage = "usage: kit mul method=orig|booth x=-0.1101 y=0.1011"
        let method = try choice(&a, "method", ["orig", "booth"], default: "orig")
        let x = try fraction(&a, "x", usage: usage, allowInt: true), y = try fraction(&a, "y", usage: usage, allowInt: true)
        try a.checkUnused(["method", "x", "y", "lang"])
        guard x.isInt == y.isInt else { throw AnimParseError("x= and y= must both be fractions (0.1101) or both integers (1101)") }
        let n = max(x.bits.count, y.bits.count)
        // 小数在右边补 0、整数在左边补 0，数值都不变
        func pad(_ b: String) -> String { x.isInt ? String(repeating: "0", count: n - b.count) + b : b + String(repeating: "0", count: n - b.count) }
        let xm = Int(pad(x.bits), radix: 2)!, ym = Int(pad(y.bits), radix: 2)!
        let sep = x.isInt ? "," : "."
        let S = L.t("竖式", "work")
        let xText = (x.neg ? "-" : "") + trueValue(xm, n, sep), yText = (y.neg ? "-" : "") + trueValue(ym, n, sep)
        if method == "orig" {
            return Kit(title: L.t("原码一位乘法：x = \(xText)，y = \(yText)", "Sign-magnitude multiplication: x = \(xText), y = \(yText)"),
                       lines: origMul(x.neg, xm, y.neg, ym, n, sep, S, L))
        }
        return Kit(title: L.t("补码一位乘法（Booth）：x = \(xText)，y = \(yText)", "Booth multiplication: x = \(xText), y = \(yText)"),
                   lines: boothMul(x.neg ? -xm : xm, y.neg ? -ym : ym, n, sep, S, L))
    }

    /// 原码一位乘：部分积 n+1 位（小数点前一位放进位），从乘数最低位起，1 加 |x|、0 加 0，然后部分积与乘数一起逻辑右移，共 n 次。
    private static func origMul(_ xNeg: Bool, _ xm: Int, _ yNeg: Bool, _ ym: Int, _ n: Int, _ sep: String, _ S: String, _ L: Words) -> [String] {
        func fx(_ v: Int, _ i: Int, _ m: Int) -> String { fixed(v, i, m, sep) }
        let xs = xNeg ? 1 : 0, ys = yNeg ? 1 : 0, sign = xs ^ ys
        let wA = n + 2
        let h1 = L.t("部分积", "A"), h2 = L.t("乘数", "Q")
        let c1 = 1, c2 = c1 + max(wA, h1.count) + 2
        var lines = [
            "text " + q(L.t("|x| = \(fx(xm, 1, n))　|y| = \(fx(ym, 1, n))　乘积的符号 = xs ⊕ ys = \(xs) ⊕ \(ys) = \(sign)",
                            "|x| = \(fx(xm, 1, n))   |y| = \(fx(ym, 1, n))   sign of the product = xs ⊕ ys = \(xs) ⊕ \(ys) = \(sign)")),
            "text " + q(L.t("符号位单独算，数值部分用绝对值：看乘数最低位，1 加 |x|、0 加 0，然后部分积和乘数一起右移一位，共 \(n) 次",
                            "A: partial product, Q: multiplier. The sign is handled separately; work with magnitudes: look at the lowest multiplier bit, add |x| for 1 or 0 for 0, then shift product and multiplier right together; \(n) rounds")),
            "sheet \(S)",
            "write \(S)[0,\(c1)] \(q(h1))", "write \(S)[0,\(c2)] \(q(h2))",
            "write \(S)[1,\(c1)] \(q(fx(0, 1, n)))", "write \(S)[1,\(c2)] \(q(binary(ym, n)))",
            "label \(S)[1] \(q(L.t("初始：部分积 0，乘数 |y|", "start: product 0, multiplier |y|")))",
        ]
        var A = 0, Q = ym, row = 1
        for i in 0..<n {
            let bit = Q & 1
            let yi = "y" + subscriptDigits(n - i)
            let add = bit == 1 ? xm : 0
            A += add
            lines += s3(L.t("第 \(i + 1) 次：乘数最低位 \(yi) = \(bit)，部分积加 \(bit == 1 ? "|x|" : "0")，得 \(fx(A, 1, n))",
                            "round \(i + 1): the lowest multiplier bit \(yi) = \(bit), so add \(bit == 1 ? "|x|" : "0") to the product: \(fx(A, 1, n))")
                        + (A >> n == 1 ? (sep == "," ? L.t("（逗号前的 1 是进位）", " (the 1 before the comma is a carry)") : L.t("（小数点前的 1 是进位）", " (the 1 before the point is a carry)")) : ""),
                        ["mark \(S)[\(row),\(c2 + n - 1)] active",
                         "write \(S)[\(row + 1),0] \"+\"", "write \(S)[\(row + 1),\(c1)] \(q(fx(add, 1, n)))",
                         "label \(S)[\(row + 1)] \(q(bit == 1 ? "+|x|" : "+0"))",
                         "rule \(S)[\(row + 1),\(c1)..\(c1 + wA - 1)]",
                         "write \(S)[\(row + 2),\(c1)] \(q(fx(A, 1, n)))"])
            let low = A & 1
            Q = (Q >> 1) | (low << (n - 1))
            A >>= 1
            lines += s3(L.t("部分积和乘数一起右移一位：部分积最低位 \(low) 移进乘数最高位，乘数最低位 \(yi) 用过了、移出去",
                            "shift product and multiplier right together: the product's lowest bit \(low) moves into the multiplier's top, the used bit \(yi) drops out"),
                        ["unmark \(S)[\(row),\(c2 + n - 1)]",
                         "write \(S)[\(row + 3),\(c1)] \(q(fx(A, 1, n)))", "write \(S)[\(row + 3),\(c2)] \(q(binary(Q, n)))",
                         "label \(S)[\(row + 3)] \(q(L.t("右移一位", "shift right")))"])
            row += 3
        }
        let P = (A << n) | Q
        let value = sign == 1 ? -P : P
        lines += s3(L.t("\(n) 次做完：部分积接上乘数寄存器就是 |x|·|y| = \(fx(P, 1, 2 * n))；配上符号位 \(sign)，[x·y]原 = \(sign)\(sep)\(binary(P, 2 * n))，x·y = \(trueValue(value, 2 * n, sep))",
                        "after \(n) rounds the product followed by the multiplier register is |x|·|y| = \(fx(P, 1, 2 * n)); with sign \(sign): [x·y] sign-magnitude = \(sign)\(sep)\(binary(P, 2 * n)), x·y = \(trueValue(value, 2 * n, sep))"),
                    ["mark \(S)[\(row),\(c1 + 2)..\(c1 + wA - 1)] done", "mark \(S)[\(row),\(c2)..\(c2 + n - 1)] done",
                     "label \(S)[\(row)] \(q(L.t("← 乘积的数值部分", "← the product's magnitude")))"])
        return lines
    }

    /// Booth：部分积双符号位，乘数 n+1 位补码 + 附加位 yₙ₊₁ = 0；看 yᵢyᵢ₊₁：00 / 11 不加，01 加 [x]补，10 加 [−x]补；
    /// 部分积、乘数、附加位一起算术右移；共加 n+1 次、移 n 次（最后一次只加不移）。
    private static func boothMul(_ X: Int, _ Y: Int, _ n: Int, _ sep: String, _ S: String, _ L: Words) -> [String] {
        func fx(_ v: Int, _ i: Int, _ m: Int) -> String { fixed(v, i, m, sep) }
        let wA = n + 3
        let h1 = L.t("部分积", "A"), h2 = L.t("乘数", "Q"), h3 = L.t("附加位", "E")
        let c1 = 1, c2 = c1 + max(wA, h1.count) + 2
        let cE = c2 + max(n + 1, h2.count) + 1
        let m = 1 << (n + 1)
        var Q = ((Y % m) + m) % m, E = 0, A = 0, row = 1
        var lines = [
            "text " + q(L.t("[x]补 = \(fx(X, 2, n))　[−x]补 = \(fx(-X, 2, n))　[y]补 = \(fx(Y, 1, n))",
                            "[x]₂c = \(fx(X, 2, n))   [−x]₂c = \(fx(-X, 2, n))   [y]₂c = \(fx(Y, 1, n))")),
            "text " + q(L.t("看乘数最低位 yᵢ 和附加位 yᵢ₊₁：00 / 11 不加，01 加 [x]补，10 加 [−x]补；部分积双符号位、算术右移；共加 \(n + 1) 次、移 \(n) 次，最后一次只加不移",
                            "A: partial product, Q: multiplier, E: extra bit. Look at the lowest multiplier bit yᵢ and the extra bit yᵢ₊₁: 00 / 11 add nothing, 01 adds [x], 10 adds [−x]; the product has two sign bits and shifts arithmetically; \(n + 1) additions, \(n) shifts, the last addition is not shifted")),
            "sheet \(S)",
            "write \(S)[0,\(c1)] \(q(h1))", "write \(S)[0,\(c2)] \(q(h2))", "write \(S)[0,\(cE)] \(q(h3))",
            "write \(S)[1,\(c1)] \(q(fx(0, 2, n)))", "write \(S)[1,\(c2)] \(q(binary(Q, n + 1)))", "write \(S)[1,\(cE)] \"0\"",
            "label \(S)[1] \(q(L.t("初始：部分积 0，乘数 [y]补，附加位 0", "start: product 0, multiplier [y], extra bit 0")))",
        ]
        let xTC = L.t("[x]补", "[x]"), negTC = L.t("[−x]补", "[−x]")
        var marked: [String] = []
        func unmarkAll() -> [String] { let u = marked.map { "unmark " + $0 }; marked = []; return u }
        for k in 0...n {
            let pair = "\(Q & 1)\(E)"
            let pairName = "y" + subscriptDigits(n - k) + "y" + subscriptDigits(n - k + 1)
            let addV = pair == "01" ? X : (pair == "10" ? -X : 0)
            let adds = pair == "01" || pair == "10"
            var acts = unmarkAll()
            acts += ["mark \(S)[\(row),\(c2 + n)] active", "mark \(S)[\(row),\(cE)] active"]
            marked += ["\(S)[\(row),\(c2 + n)]", "\(S)[\(row),\(cE)]"]
            var cap = L.t("第 \(k + 1) 次：\(pairName) = \(pair)，", "round \(k + 1): \(pairName) = \(pair): ")
            if adds {
                A += addV
                acts += ["write \(S)[\(row + 1),0] \"+\"", "write \(S)[\(row + 1),\(c1)] \(q(fx(addV, 2, n)))",
                         "label \(S)[\(row + 1)] \(q("+" + (pair == "01" ? xTC : negTC)))",
                         "rule \(S)[\(row + 1),\(c1)..\(c1 + wA - 1)]",
                         "write \(S)[\(row + 2),\(c1)] \(q(fx(A, 2, n)))"]
                cap += L.t("加 \(pair == "01" ? xTC : negTC) = \(fx(addV, 2, n))，得 \(fx(A, 2, n))",
                           "add \(pair == "01" ? xTC : negTC) = \(fx(addV, 2, n)), giving \(fx(A, 2, n))")
                row += 2
            } else {
                cap += L.t("两位相同，不加", "the bits are equal: add nothing")
            }
            if k == n {
                lines += s3(cap + L.t("；这是第 \(n + 1) 次，只加不移", "; this is addition \(n + 1): no shift after it"), acts)
                break
            }
            let low = A & 1, top = A < 0 ? 1 : 0
            E = Q & 1
            Q = (Q >> 1) | (low << n)
            A >>= 1
            let shiftActs = ["write \(S)[\(row + 1),\(c1)] \(q(fx(A, 2, n)))", "write \(S)[\(row + 1),\(c2)] \(q(binary(Q, n + 1)))",
                             "write \(S)[\(row + 1),\(cE)] \(q(String(E)))", "label \(S)[\(row + 1)] \(q(L.t("算术右移一位", "arithmetic shift right")))"]
            let shiftCap = L.t("部分积、乘数、附加位一起算术右移一位（最高位补符号 \(top)）：部分积最低位 \(low) 移进乘数最高位，乘数最低位移进附加位",
                               "arithmetic shift right (the top is refilled with the sign \(top)): the product's lowest bit \(low) moves into the multiplier, the multiplier's lowest bit into the extra bit")
            if adds {
                lines += s3(cap, acts)
                lines += s3(shiftCap, unmarkAll() + shiftActs)
            } else {
                lines += s3(cap + L.sep + shiftCap, acts + shiftActs)
            }
            row += 1
        }
        let P = A * (1 << n) + (Q >> 1)
        lines += s3(L.t("部分积（去掉一位符号）接上乘数寄存器的前 \(n) 位就是 [x·y]补 = \(fx(P, 1, 2 * n))（乘数最后一位是 y 的符号位，舍去），x·y = \(trueValue(P, 2 * n, sep))",
                        "the product (dropping one sign bit) followed by the first \(n) multiplier bits is [x·y]₂c = \(fx(P, 1, 2 * n)) (the last multiplier bit is y's sign, dropped); x·y = \(trueValue(P, 2 * n, sep))"),
                    unmarkAll() + ["write \(S)[\(row),\(c2)] \(q(binary(Q >> 1, n)))",
                                   "mark \(S)[\(row),\(c1 + 1)..\(c1 + wA - 1)] done", "mark \(S)[\(row),\(c2)..\(c2 + n - 1)] done",
                                   "label \(S)[\(row)] \(q(L.t("← [x·y]补", "← [x·y]₂c")))"])
        return lines
    }

    // MARK: - 除法

    private static func divKit(_ a: inout Args, _ L: Words) throws -> Kit {
        let usage = "usage: kit div method=restore|nonrestore|comp x=0.1011 y=0.1101"
        let method = try choice(&a, "method", ["restore", "nonrestore", "comp"], default: "nonrestore")
        let x = try fraction(&a, "x", usage: usage, allowInt: false), y = try fraction(&a, "y", usage: usage, allowInt: false)
        try a.checkUnused(["method", "x", "y", "lang"])
        let n = max(x.bits.count, y.bits.count)
        if method == "restore" && n > 6 { throw AnimParseError("method=restore: at most 6 bits after the point") }
        let xm = Int(x.bits + String(repeating: "0", count: n - x.bits.count), radix: 2)!
        let ym = Int(y.bits + String(repeating: "0", count: n - y.bits.count), radix: 2)!
        guard ym > 0 else { throw AnimParseError("y must not be 0") }
        guard xm < ym else { throw AnimParseError("fixed-point fraction division needs |x| < |y| (otherwise the quotient overflows)") }
        let S = L.t("竖式", "work")
        let xText = (x.neg ? "-" : "") + fixed(xm, 1, n), yText = (y.neg ? "-" : "") + fixed(ym, 1, n)
        let name: String
        switch method {
        case "restore": name = L.t("原码恢复余数法", "Restoring division")
        case "nonrestore": name = L.t("原码加减交替法（不恢复余数）", "Non-restoring division (sign-magnitude)")
        default: name = L.t("补码加减交替法", "Two's-complement non-restoring division")
        }
        let lines = method == "comp" ? compDiv(x.neg ? -xm : xm, y.neg ? -ym : ym, n, S, L)
                                     : origDiv(method == "restore", x.neg, xm, y.neg, ym, n, S, L)
        return Kit(title: name + L.t("：x = \(xText)，y = \(yText)", ": x = \(xText), y = \(yText)"), lines: lines)
    }

    /// 除法表格的公共部分：余数（双符号位）一列、商一列。
    private static func divHeader(_ n: Int, _ S: String, _ L: Words) -> (lines: [String], c1: Int, c2: Int, wA: Int) {
        let wA = n + 3
        let h1 = L.t("余数", "A"), h2 = L.t("商", "Q")
        let c1 = 1, c2 = c1 + max(wA, h1.count) + 2
        return (["sheet \(S)", "write \(S)[0,\(c1)] \(q(h1))", "write \(S)[0,\(c2)] \(q(h2))"], c1, c2, wA)
    }

    /// 原码除法：符号单独算（xs ⊕ ys），数值部分 |x| ÷ |y|；余数用双符号位，左移后也不会看错正负。
    /// 恢复余数法：每次减 |y|，负了上商 0 并加回 |y|；加减交替法：正上商 1、左移减 |y|，负上商 0、左移加 |y|，最后余数为负再加一次 |y|。
    private static func origDiv(_ restore: Bool, _ xNeg: Bool, _ xm: Int, _ yNeg: Bool, _ ym: Int, _ n: Int, _ S: String, _ L: Words) -> [String] {
        let xs = xNeg ? 1 : 0, ys = yNeg ? 1 : 0, sign = xs ^ ys
        let (head, c1, c2, wA) = divHeader(n, S, L)
        let subName = L.t("+[−|y|]补", "+[−|y|]"), addName = "+|y|"
        var lines = [
            "text " + q(L.t("|x| = \(fixed(xm, 1, n))　|y| = \(fixed(ym, 1, n))　[−|y|]补 = \(fixed(-ym, 2, n))　商的符号 = xs ⊕ ys = \(xs) ⊕ \(ys) = \(sign)",
                            "|x| = \(fixed(xm, 1, n))   |y| = \(fixed(ym, 1, n))   [−|y|] = \(fixed(-ym, 2, n))   sign of the quotient = xs ⊕ ys = \(xs) ⊕ \(ys) = \(sign)")),
            "text " + q(restore
                ? L.t("恢复余数法：每次减 |y|（加 [−|y|]补）；余数为正上商 1，为负上商 0 并加回 |y| 恢复；然后左移一位，共上商 \(n + 1) 位",
                      "A: remainder, Q: quotient. Restoring: subtract |y| each time; a positive remainder gives quotient bit 1, a negative one gives 0 and |y| is added back; then shift left; \(n + 1) quotient bits")
                : L.t("加减交替法：余数为正上商 1、左移一位减 |y|；为负上商 0、左移一位加 |y|；共加 \(n + 1) 次、移 \(n) 次，最后余数为负再加 |y|",
                      "A: remainder, Q: quotient. Non-restoring: a positive remainder gives 1, shift left and subtract |y|; a negative one gives 0, shift left and add |y|; \(n + 1) additions, \(n) shifts, fix a negative final remainder by adding |y|")),
        ] + head + [
            "write \(S)[1,\(c1)] \(q(fixed(xm, 2, n)))",
            "label \(S)[1] \(q(L.t("被除数 |x|", "dividend |x|")))",
        ]
        var R = xm, row = 1, sub = true
        var qbits: [Int] = []
        var marked: [String] = []
        func unmarkAll() -> [String] { let u = marked.map { "unmark " + $0 }; marked = []; return u }
        for i in 0...n {
            let addV = sub ? -ym : ym
            R += addV
            let qb = R >= 0 ? 1 : 0
            qbits.append(qb)
            let signCells = "\(S)[\(row + 2),\(c1)..\(c1 + 1)]"
            var acts = unmarkAll()
            acts += ["write \(S)[\(row + 1),0] \"+\"", "write \(S)[\(row + 1),\(c1)] \(q(fixed(addV, 2, n)))",
                     "label \(S)[\(row + 1)] \(q(sub ? subName : addName))",
                     "rule \(S)[\(row + 1),\(c1)..\(c1 + wA - 1)]",
                     "write \(S)[\(row + 2),\(c1)] \(q(fixed(R, 2, n)))",
                     "mark \(signCells) active",
                     "write \(S)[\(row + 2),\(c2)] \(q(quotientText(qbits)))",
                     "label \(S)[\(row + 2)] \(q(qb == 1 ? L.t("正，上商 1", "≥ 0: bit 1") : L.t("负，上商 0", "< 0: bit 0")))"]
            marked.append(signCells)
            let did = sub ? L.t("减 |y|（加 [−|y|]补）", "subtract |y| (add [−|y|])") : L.t("加 |y|", "add |y|")
            var cap = L.t("第 \(i + 1) 次：\(did)，余数 \(fixed(R, 2, n))，符号位 \(R < 0 ? 1 : 0)，", "round \(i + 1): \(did): remainder \(fixed(R, 2, n)), sign \(R < 0 ? 1 : 0), ")
                + (qb == 1 ? L.t("为正，上商 1", "positive: quotient bit 1") : L.t("为负，上商 0", "negative: quotient bit 0"))
            if i == 0 { cap += L.t("（第一位商是 0，说明 |x| < |y|，不溢出）", " (the first bit is 0: |x| < |y|, no overflow)") }
            lines += s3(cap, acts)
            row += 2
            if restore && qb == 0 {
                R += ym
                lines += s3(L.t("余数为负，减多了：加回 |y|，恢复成 \(fixed(R, 2, n))", "the remainder is negative, so add |y| back: restored to \(fixed(R, 2, n))"),
                            unmarkAll() + ["write \(S)[\(row + 1),0] \"+\"", "write \(S)[\(row + 1),\(c1)] \(q(fixed(ym, 2, n)))",
                                           "label \(S)[\(row + 1)] \(q(L.t("+|y| 恢复", "+|y| restore")))",
                                           "rule \(S)[\(row + 1),\(c1)..\(c1 + wA - 1)]",
                                           "write \(S)[\(row + 2),\(c1)] \(q(fixed(R, 2, n)))"])
                row += 2
            }
            if i == n { break }
            R *= 2
            let next = restore ? L.t("下一次再减 |y|", "next: subtract |y| again")
                               : (qb == 1 ? L.t("商 1，下一次减 |y|", "bit 1: next subtract |y|") : L.t("商 0，下一次加 |y|", "bit 0: next add |y|"))
            lines += s3(L.t("余数左移一位：\(fixed(R, 2, n))；", "shift the remainder left: \(fixed(R, 2, n)); ") + next,
                        unmarkAll() + ["write \(S)[\(row + 1),\(c1)] \(q(fixed(R, 2, n)))", "label \(S)[\(row + 1)] \(q(L.t("左移一位", "shift left")))"])
            row += 1
            sub = restore || qb == 1
        }
        if !restore && R < 0 {
            R += ym
            lines += s3(L.t("最后的余数为负，加 |y| 恢复成正余数 \(fixed(R, 2, n))（商不变）", "the final remainder is negative: add |y| to make it \(fixed(R, 2, n)) (the quotient stays)"),
                        unmarkAll() + ["write \(S)[\(row + 1),0] \"+\"", "write \(S)[\(row + 1),\(c1)] \(q(fixed(ym, 2, n)))",
                                       "label \(S)[\(row + 1)] \(q(L.t("+|y| 恢复余数", "+|y| fix remainder")))",
                                       "rule \(S)[\(row + 1),\(c1)..\(c1 + wA - 1)]",
                                       "write \(S)[\(row + 2),\(c1)] \(q(fixed(R, 2, n)))"])
            row += 2
        }
        let qm = qbits.reduce(0) { $0 * 2 + $1 }
        let qv = sign == 1 ? -qm : qm, rv = xs == 1 ? -R : R
        let qFrac = binary(qm, n)
        lines += s3(L.t("商的第一位 0 换成符号位 \(sign)：[x÷y]原 = \(sign).\(qFrac)，x ÷ y = \(trueValue(qv, n))；余数与被除数同号：\(trueValue(rv, n)) × 2\(superscriptMinus(n))",
                        "replace the first quotient bit 0 by the sign \(sign): [x÷y] sign-magnitude = \(sign).\(qFrac), x ÷ y = \(trueValue(qv, n)); the remainder takes the dividend's sign: \(trueValue(rv, n)) × 2\(superscriptMinus(n))"),
                    unmarkAll() + ["write \(S)[\(row),\(c2)] \(q(quotientText(qbits)))",
                                   "mark \(S)[\(row),\(c2 + 2)..\(c2 + n + 1)] done", "mark \(S)[\(row),\(c1 + 3)..\(c1 + wA - 1)] done",
                                   "label \(S)[\(row)] \(q(L.t("← 余数 × 2\(superscriptMinus(n))、商", "← remainder × 2\(superscriptMinus(n)), quotient")))"])
        return lines
    }

    /// 补码加减交替：符号位参与运算；第一次 x、y 同号减、异号加；之后余数与 y 同号上商 1、左移减 y，异号上商 0、左移加 y；
    /// 上 n 位商、加 n+1 次、移 n 次，商的末位恒置 1。
    private static func compDiv(_ X: Int, _ Y: Int, _ n: Int, _ S: String, _ L: Words) -> [String] {
        let (head, c1, c2, wA) = divHeader(n, S, L)
        func same(_ a: Int, _ b: Int) -> Bool { (a < 0) == (b < 0) }
        let yTC = L.t("[y]补", "[y]"), negTC = L.t("[−y]补", "[−y]")
        var lines = [
            "text " + q(L.t("[x]补 = \(fixed(X, 2, n))　[y]补 = \(fixed(Y, 2, n))　[−y]补 = \(fixed(-Y, 2, n))",
                            "[x]₂c = \(fixed(X, 2, n))   [y]₂c = \(fixed(Y, 2, n))   [−y]₂c = \(fixed(-Y, 2, n))")),
            "text " + q(L.t("符号位参与运算。第一次：x、y 同号减 y、异号加 y；之后余数与 y 同号上商 1、左移减 y，异号上商 0、左移加 y；上 \(n) 位商后末位恒置 1",
                            "A: remainder, Q: quotient. Sign bits take part. First: subtract y if x and y have the same sign, else add y; then a remainder with y's sign gives 1, shift left and subtract y, otherwise 0, shift left and add y; after \(n) bits the last bit is set to 1")),
        ] + head + [
            "write \(S)[1,\(c1)] \(q(fixed(X, 2, n)))",
            "label \(S)[1] \(q(L.t("被除数 [x]补", "dividend [x]")))",
        ]
        var R = X, row = 1
        var sub = same(X, Y)
        var qbits: [Int] = []
        var marked: [String] = []
        func unmarkAll() -> [String] { let u = marked.map { "unmark " + $0 }; marked = []; return u }
        for i in 0...n {
            let addV = sub ? -Y : Y
            R += addV
            var acts = unmarkAll()
            acts += ["write \(S)[\(row + 1),0] \"+\"", "write \(S)[\(row + 1),\(c1)] \(q(fixed(addV, 2, n)))",
                     "label \(S)[\(row + 1)] \(q("+" + (sub ? negTC : yTC)))",
                     "rule \(S)[\(row + 1),\(c1)..\(c1 + wA - 1)]",
                     "write \(S)[\(row + 2),\(c1)] \(q(fixed(R, 2, n)))"]
            let did = sub ? L.t("减 y（加 [−y]补）", "subtract y (add [−y])") : L.t("加 y（加 [y]补）", "add y (add [y])")
            var cap = i == 0
                ? L.t("x 与 y \(same(X, Y) ? "同号" : "异号")，先\(did)，余数 \(fixed(R, 2, n))", "x and y have \(same(X, Y) ? "the same sign" : "different signs"): \(did) first: \(fixed(R, 2, n))")
                : L.t("第 \(i + 1) 次：\(did)，余数 \(fixed(R, 2, n))", "round \(i + 1): \(did): \(fixed(R, 2, n))")
            if i < n {
                let qb = same(R, Y) ? 1 : 0
                qbits.append(qb)
                let signCells = "\(S)[\(row + 2),\(c1)..\(c1 + 1)]"
                acts += ["mark \(signCells) active", "write \(S)[\(row + 2),\(c2)] \(q(quotientText(qbits)))",
                         "label \(S)[\(row + 2)] \(q(qb == 1 ? L.t("与 y 同号，上商 1", "same sign as y: 1") : L.t("与 y 异号，上商 0", "sign differs from y: 0")))"]
                marked.append(signCells)
                cap += L.t("，与 y \(qb == 1 ? "同号，上商 1" : "异号，上商 0")", qb == 1 ? ", same sign as y: quotient bit 1" : ", sign differs from y: quotient bit 0")
                lines += s3(cap, acts)
                row += 2
                R *= 2
                sub = qb == 1
                lines += s3(L.t("余数左移一位：\(fixed(R, 2, n))；", "shift the remainder left: \(fixed(R, 2, n)); ")
                            + (qb == 1 ? L.t("商 1，下一次减 y", "bit 1: next subtract y") : L.t("商 0，下一次加 y", "bit 0: next add y")),
                            unmarkAll() + ["write \(S)[\(row + 1),\(c1)] \(q(fixed(R, 2, n)))", "label \(S)[\(row + 1)] \(q(L.t("左移一位", "shift left")))"])
                row += 1
            } else {
                lines += s3(cap + L.t("；已经上了 \(n) 位商，这次的结果就是余数", "; \(n) quotient bits are done, this is the remainder"), acts)
                row += 2
            }
        }
        qbits.append(1)
        let u = qbits.reduce(0) { $0 * 2 + $1 }
        let qv = u >= (1 << n) ? u - (1 << (n + 1)) : u
        let qText = quotientText(qbits)
        lines += s3(L.t("商的末位恒置 1：[x÷y]补 = \(qText)，x ÷ y = \(trueValue(qv, n))；余数 [r]补 = \(fixed(R, 1, n)) × 2\(superscriptMinus(n))，即 \(trueValue(R, n)) × 2\(superscriptMinus(n))",
                        "set the last quotient bit to 1: [x÷y]₂c = \(qText), x ÷ y = \(trueValue(qv, n)); remainder [r]₂c = \(fixed(R, 1, n)) × 2\(superscriptMinus(n)), that is \(trueValue(R, n)) × 2\(superscriptMinus(n))"),
                    ["write \(S)[\(row),\(c2)] \(q(qText))", "mark \(S)[\(row),\(c2)..\(c2 + n + 1)] done", "mark \(S)[\(row),\(c1 + 1)..\(c1 + wA - 1)] done",
                     "label \(S)[\(row)] \(q(L.t("← 余数 × 2\(superscriptMinus(n))、商（末位恒置 1）", "← remainder × 2\(superscriptMinus(n)), quotient (last bit 1)")))"])
        return lines
    }
}
