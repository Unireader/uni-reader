// ⌘P 快速打开的匹配（`Sources/App/QuickOpenMatch.swift`，只依赖 Foundation）。运行：
//   cp spike/quick-open-match-test.swift /tmp/main.swift && swiftc Sources/App/QuickOpenMatch.swift /tmp/main.swift -o /tmp/qom && /tmp/qom
// 覆盖：多段都要中、字 ↔ 数字拆块、数字边界、拼音全拼 / 首字母、模糊、章节序号别名、空输入只列可浏览的。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

struct It { var id: String; var f: QuickOpenMatch.Fields; var browse = true }
func doc(_ name: String, _ detail: String = "PDF") -> It {
    It(id: name, f: .init(name: name, detail: detail, pinyin: true))
}
func ex(_ id: String, number: String, section: String = "", stem: String, book: String, chapter: [String]) -> It {
    let label = [section, number].filter { !$0.isEmpty }.joined(separator: " ")
    var keys = [stem, chapter.joined(separator: " "), number + section]
    keys += QuickOpenMatch.exerciseAliases(number: number, chapter: chapter)
    return It(id: id, f: .init(name: label + "  " + stem, detail: (["习题", book] + chapter).joined(separator: " · "),
                               keys: keys, fuzzy: false), browse: false)
}
func toc(_ label: String, book: String) -> It {
    It(id: "toc:" + label, f: .init(name: label, detail: "目录 · " + book), browse: false)
}
func rank(_ items: [It], _ q: String) -> [String] {
    QuickOpenMatch.rank(items, fields: items.map(\.f), query: q, limit: 60, browse: \.browse).map(\.id)
}

let items: [It] = [
    doc("1000题"),
    doc("高等数学同济第七版"),
    doc("Linear Algebra"),
    It(id: "g:1000基础", f: .init(name: "1000题 · 基础篇", detail: "习题 · 30 道题", pinyin: true)),
    ex("e1", number: "2.7", stem: "设函数 f(x) 在 x=0 处连续", book: "1000题", chapter: ["基础篇", "第二章 一元函数微分学"]),
    ex("e2", number: "12.7", stem: "求极限", book: "1000题", chapter: ["基础篇", "第十二章"]),
    ex("e3", number: "2.71", stem: "求导数", book: "1000题", chapter: ["基础篇", "第二章"]),
    ex("e4", number: "2.7", stem: "计算二重积分", book: "1000题", chapter: ["强化篇", "第二章"]),
    ex("e5", number: "例2.7", stem: "证明不等式", book: "高等数学同济第七版", chapter: ["第二章 导数与微分"]),
    ex("e6", number: "7", section: "例题", stem: "判断级数敛散性", book: "660题", chapter: ["基础", "第2章 级数"]),
    toc("第二章 导数与微分", book: "高等数学同济第七版"),
    toc("2.7 隐函数的导数", book: "高等数学同济第七版"),
]

print("拆块与数字边界")
check(QuickOpenMatch.split("基础2.7") == ["基础", "2.7"], "「基础2.7」→ 基础 / 2.7")
check(QuickOpenMatch.split("例2.7") == ["例", "2.7"], "「例2.7」→ 例 / 2.7")
check(QuickOpenMatch.split("1000题") == ["1000", "题"], "「1000题」→ 1000 / 题")
check(QuickOpenMatch.split("v2.") == ["v", "2", "."], "末尾的点不算数字")
check(QuickOpenMatch.find("2.7", in: "2.7 隐函数") == 0, "开头的 2.7")
check(QuickOpenMatch.find("2.7", in: "12.7") == nil, "2.7 不中 12.7")
check(QuickOpenMatch.find("2.7", in: "2.71") == nil, "2.7 不中 2.71")
check(QuickOpenMatch.find("2.7", in: "1.2.7") == nil, "2.7 不中 1.2.7")
check(QuickOpenMatch.find("2.7", in: "12.7 与 例2.7") == 8, "跳过不合格的、找到后面合格的")
check(QuickOpenMatch.find("100", in: "1000题") == nil, "100 不中 1000")
check(QuickOpenMatch.find("ab", in: "xabx") == 1, "不是数字照常找")

print("章节序号别名")
check(QuickOpenMatch.ordinal(of: "第二章 一元函数微分学") == "2", "第二章 → 2")
check(QuickOpenMatch.ordinal(of: "第12章") == "12", "第12章 → 12")
check(QuickOpenMatch.ordinal(of: "第十二章") == "12", "第十二章 → 12")
check(QuickOpenMatch.ordinal(of: "2.3 导数") == "2.3", "2.3 导数 → 2.3")
check(QuickOpenMatch.ordinal(of: "Chapter 4 Limits") == "4", "Chapter 4 → 4")
check(QuickOpenMatch.ordinal(of: "基础篇") == nil, "没有序号")
check(QuickOpenMatch.exerciseAliases(number: "7", chapter: ["基础", "第2章 级数"]) == ["2.7"], "第2章第 7 题 → 2.7")
check(QuickOpenMatch.exerciseAliases(number: "2.7", chapter: ["第2章"]).isEmpty, "题号不是纯数字不加别名")

print("用户的例子")
let r1 = rank(items, "1000题 基础2.7")
check(r1 == ["e1"], "「1000题 基础2.7」只中基础篇的 2.7（不中 12.7 / 2.71 / 强化篇）：\(r1)")
let r2 = rank(items, "例2.7")
check(r2.first == "e5", "「例2.7」第一个是题号「例2.7」：\(r2)")
check(r2.contains("e6"), "「例2.7」也中「例题 7」（第2章，别名 2.7）")
check(!r2.contains("e2") && !r2.contains("e3"), "「例2.7」不中 12.7 / 2.71")
let r3 = rank(items, "2.7")
check(Set(r3.prefix(3)) == ["e1", "e4", "toc:2.7 隐函数的导数"], "「2.7」：题号 / 目录名开头的排前面：\(r3)")
check(rank(items, "隐函数").first == "toc:2.7 隐函数的导数", "目录项按名字搜")
check(rank(items, "同济 导数").first == "toc:第二章 导数与微分", "目录项：书名 + 章节名两段")
check(rank(items, "二重积分") == ["e4"], "题干里的字能搜到")

print("拼音与模糊")
check(rank(items, "gdsx").first == "高等数学同济第七版", "拼音首字母 gdsx")
check(rank(items, "gaodeng").first == "高等数学同济第七版", "全拼开头 gaodeng")
check(rank(items, "tongji").first == "高等数学同济第七版", "全拼中间 tongji")
check(rank(items, "LINEAR").first == "Linear Algebra", "不分大小写")
check(rank(items, "lnalg").first == "Linear Algebra", "模糊：按顺序出现各字")
check(rank(items, "高数").first == "高等数学同济第七版", "模糊：中文跳字")
check(rank(items, "导求").isEmpty, "单道题不模糊：「导求」不中「求导数」")
check(rank(items, "zzz").isEmpty, "都不中 = 空")

print("空输入")
check(rank(items, "") == ["1000题", "高等数学同济第七版", "Linear Algebra", "g:1000基础"], "空输入只列可浏览的、原顺序")
check(rank(items, "   ") == rank(items, ""), "只有空白 = 空输入")

print("\n\(pass) 过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
