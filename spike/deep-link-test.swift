// `unireader://open?…` 链接的解析与生成（`Sources/App/DeepLink.swift`，只依赖 Foundation）。运行：
//   cp spike/deep-link-test.swift /tmp/main.swift && swiftc Sources/App/DeepLink.swift /tmp/main.swift -o /tmp/dlt && /tmp/dlt
// 覆盖：scheme/host 判定、七个参数各自的解析、`ws` 三种写法归一、页码/位置/笔记 id 的坏值、
//       未知参数忽略、生成时的严格编码（空格/括号/中文/井号）、生成 → 解析往返一致、frac 格式。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func parse(_ s: String) -> DeepLink? { URL(string: s).flatMap { try? DeepLink.parse($0) } }
func parseError(_ s: String) -> DeepLink.ParseError? {
    guard let u = URL(string: s) else { return nil }
    do { _ = try DeepLink.parse(u); return nil } catch { return error as? DeepLink.ParseError }
}

print("scheme / host")
check(DeepLink.isDeepLink(URL(string: "unireader://open")!), "unireader:// 认")
check(DeepLink.isDeepLink(URL(string: "UNIREADER://open")!), "scheme 大小写不敏感")
check(!DeepLink.isDeepLink(URL(fileURLWithPath: "/tmp/a.unrd")), "file:// 不认")
check(parseError("file:///tmp/a.unrd") == .notDeepLink, "别的 scheme → notDeepLink")
check(parseError("unireader://goto?page=1") == .unknownHost("goto"), "主机不是 open → unknownHost")
check(parse("unireader://OPEN")?.isEmpty == true, "host 大小写不敏感；光杆 = isEmpty")
check(parse("unireader://open?")?.isEmpty == true, "空查询 = isEmpty")

print("参数")
let full = parse("unireader://open?ws=%2FVolumes%2FT7%2F%E8%AF%BB%E4%B9%A6.unrd&wsid=W1&doc=D1&hash=ABCDEF&page=12&frac=0.43&note=6BA7B810-9DAD-11D1-80B4-00C04FD430C8")
check(full?.workspacePath == "/Volumes/T7/读书.unrd", "ws 百分号解码（含中文）")
check(full?.workspaceId == "W1" && full?.documentId == "D1", "wsid / doc")
check(full?.contentHash == "abcdef", "hash 转小写")
check(full?.page == 12, "page 对外 1 起原样保留")
check(full?.frac == 0.43, "frac")
check(full?.noteId == UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"), "note → UUID")
check(parse("unireader://open?note=6ba7b810-9dad-11d1-80b4-00c04fd430c8")?.noteId?.uuidString == "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "note 小写也认")

// Markdown 笔记（v15，`MARKDOWN-NOTES-PLAN.md §4.4`）
let md = parse("unireader://open?ws=%2FVolumes%2FT7%2F%E8%AF%BB%E4%B9%A6.unrd&md=M1")
check(md?.markdownId == "M1", "md → 笔记 id")
check(md?.documentId == nil, "只给 md 时没有 doc")
check(md?.isEmpty == false, "只有 md 也算有定位参数")
check(parse("unireader://open")?.markdownId == nil, "光杆链接没有 md")
var mdLink = DeepLink()
mdLink.workspacePath = "/Volumes/T7/读书.unrd"
mdLink.markdownId = "M1"
check((try? DeepLink.parse(mdLink.url)) == mdLink, "md 链接 生成 → 解析 往返一致")
check(mdLink.absoluteString.contains("&md=M1"), "生成的链接里带 md 参数")
check(parse("unireader://open?PAGE=3&Doc=x")?.page == 3 && parse("unireader://open?PAGE=3&Doc=x")?.documentId == "x", "参数名大小写不敏感")
check(parse("unireader://open?doc=x&foo=bar&page=2")?.page == 2, "未知参数忽略")
check(parse("unireader://open?doc=&page=")?.isEmpty == true, "空值当没给")
check(parse("unireader://open?doc=%20x%20")?.documentId == "x", "值两端空白剪掉")

print("ws 写法归一")
check(parse("unireader://open?ws=file%3A%2F%2F%2FVolumes%2FT7%2Fa.unrd")?.workspacePath == "/Volumes/T7/a.unrd", "file:// 形式 → 路径")
check(parse("unireader://open?ws=file:///Volumes/T7/a%20b.unrd")?.workspacePath == "/Volumes/T7/a b.unrd", "file:// 未编码冒号也认、%20 解成空格")
let home = NSHomeDirectory()
check(parse("unireader://open?ws=~%2FDocs%2Fa.unrd")?.workspacePath == home + "/Docs/a.unrd", "~ 展开")
check(parse("unireader://open?ws=/Volumes/T7/a.unrd")?.workspacePath == "/Volumes/T7/a.unrd", "裸路径（未编码斜杠）也认")

print("坏值")
check(parseError("unireader://open?page=0") == .badPage("0"), "page=0 → badPage")
check(parseError("unireader://open?page=abc") == .badPage("abc"), "page 非数字 → badPage")
check(parseError("unireader://open?page=-3") == .badPage("-3"), "page 负数 → badPage")
check(parseError("unireader://open?frac=x") == .badFrac("x"), "frac 非数字 → badFrac")
check(parse("unireader://open?frac=1.7")?.frac == 1 && parse("unireader://open?frac=-2")?.frac == 0, "frac 越界钳到 0…1（不报错）")
check(parseError("unireader://open?note=abc") == .badNote("abc"), "note 不是 UUID → badNote")

print("生成")
var l = DeepLink()
l.workspacePath = "/Volumes/T7/读书 (2026).unrd"
l.documentId = "D1"
l.page = 12
l.frac = 0.43
let s = l.absoluteString
check(s == "unireader://open?ws=%2FVolumes%2FT7%2F%E8%AF%BB%E4%B9%A6%20%282026%29.unrd&doc=D1&page=12&frac=0.43", "斜杠/空格/括号/中文全部编码：\(s)")
check(!s.contains(" ") && !s.contains("(") && !s.contains(")") && !s.contains("#"), "贴进 Markdown 不会断")
check(DeepLink().absoluteString == "unireader://open", "光杆链接不带问号")
var h = DeepLink(); h.workspacePath = "/a#b.unrd"; h.contentHash = "AB"
check(h.absoluteString == "unireader://open?ws=%2Fa%23b.unrd&hash=AB", "# 编码；hash 原样（解析时才转小写）")
check(DeepLink.formatFrac(0) == "0" && DeepLink.formatFrac(1) == "1" && DeepLink.formatFrac(0.5) == "0.5"
      && DeepLink.formatFrac(0.4321) == "0.432" && DeepLink.formatFrac(0.1) == "0.1", "frac 最多三位小数、去尾零")

print("往返")
var r = DeepLink()
r.workspacePath = "/Volumes/My Disk/读书.unrd"
r.workspaceId = "8A0F-…"
r.documentId = "doc-1"
r.contentHash = "0123abcd"
r.page = 7
r.frac = 0.25
r.noteId = UUID()
if let back = try? DeepLink.parse(r.url) { check(back == r, "生成 → 解析 得到同一个值") }
else { check(false, "生成的链接应能解析") }

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
