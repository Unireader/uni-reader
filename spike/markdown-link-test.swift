// Markdown 笔记（`MARKDOWN-NOTES-PLAN.md`）回归测试：扫描 + 目录树 + 名字解析 + 文件层 + md_doc 库回环。
// 运行：
//   cp spike/markdown-link-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift \
//     Sources/App/MarkdownLink.swift Sources/App/MarkdownImport.swift Sources/App/NoteTree.swift Sources/App/KnowledgeLinks.swift Sources/App/DeepLink.swift \
//     Sources/App/NoteTypeModel.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift \
//     Sources/App/InkLayerModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift \
//     /tmp/main.swift -o /tmp/mdl && /tmp/mdl
// （须命名为 main.swift 编译：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 🔴 2026-09-20 用户定「**不要改 `[[]]`**」之后，原来那 12 组「链接重写」用例整段删除了——
// 现在这一层**只扫描不改写**，导入 = 整个目录原样复制。测的是：扫得对不对、树建得对不对、
// 名字解析得中不中、复制有没有动过内容。

import Foundation

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}
func eq(_ a: String, _ b: String, _ msg: String) {
    if a == b { pass += 1; print("  ✅ \(msg)") }
    else { fail += 1; print("  ❌ \(msg)\n      得到: \(a)\n      期望: \(b)") }
}

print("\n— 1) 保护区：代码块 / 行内代码 / frontmatter 里的 [[…]] 不算引用 —")
let guarded = """
---
title: 试
tags: [[极限的定义]]
---
正文 [[极限的定义]] 这条算。
`[[行内代码]]` 不算。
```
[[围栏里]] 不算
```
~~~md
[[波浪栏里]] 也不算
~~~
"""
let refs = MarkdownLink.wikiReferences(guarded)
check(refs == ["极限的定义"], "只扫出正文那一条（得到 \(refs)）")

print("\n— 2) 各种写法都能扫出目标名 —")
check(MarkdownLink.wikiReferences("[[极限的定义]]") == ["极限的定义"], "[[名字]]")
check(MarkdownLink.wikiReferences("[[数学/极限]]") == ["数学/极限"], "[[路径/名字]]")
check(MarkdownLink.wikiReferences("[[极限|那个定义]]") == ["极限"], "[[名字|别名]] → 只取目标段")
check(MarkdownLink.wikiReferences("[[极限#左极限]]") == ["极限"], "[[名字#锚点]] → 只取目标段")
check(MarkdownLink.wikiReferences("[[极限#^abc|块]]") == ["极限"], "[[名字#^块|别名]]")
check(MarkdownLink.wikiReferences("![[图.png]] [[极限]]") == ["极限"], "图片嵌入不算笔记引用")
check(MarkdownLink.wikiReferences("[[甲]] [[甲]] [[乙]]") == ["甲", "乙"], "去重、保序")

print("\n— 3) 图片引用扫描 —")
let imgs = MarkdownLink.imageReferences("![[a.png]] `![[b.png]]` ![](c/d.jpeg) ![[a.png]]")
check(imgs == ["a.png", "c/d.jpeg"], "去重 + 跳过行内代码（得到 \(imgs)）")

print("\n— 4) frontmatter 的 aliases —")
check(MarkdownLink.frontmatterAliases("---\naliases: [甲, \"乙\"]\n---\n正文") == ["甲", "乙"], "行内数组写法")
check(MarkdownLink.frontmatterAliases("---\naliases:\n  - 甲\n  - 乙\n---\n") == ["甲", "乙"], "列表写法")
check(MarkdownLink.frontmatterAliases("正文里的 aliases: 甲") == [], "没有 frontmatter 就没有别名")

print("\n— 5) NoteRef —")
let ref = NoteRef(sourceID: "ws", relPath: "数学/微积分/极限.md")
eq(ref.title, "极限", "标题 = 文件名去扩展名")
eq(ref.folder, "数学/微积分", "所在目录（多级）")
eq(ref.key, "ws:数学/微积分/极限.md", "key")
check(NoteRef(key: ref.key) == ref, "key 往返一致")
check(NoteRef(key: "没有冒号") == nil, "坏 key → nil")
check(NoteRef(sourceID: "ws", relPath: "顶层.md").folder == "", "顶层笔记没有目录")

print("\n— 6) 多级目录树 —")
let items = [
    NoteItem(ref: NoteRef(sourceID: "ws", relPath: "数学/微积分/极限.md")),
    NoteItem(ref: NoteRef(sourceID: "ws", relPath: "数学/微积分/导数.md")),
    NoteItem(ref: NoteRef(sourceID: "ws", relPath: "数学/线代/矩阵.md")),
    NoteItem(ref: NoteRef(sourceID: "ws", relPath: "读书.md")),
]
let tree = NoteFolder.build(items, rootName: "笔记")
check(tree.notes.map(\.title) == ["读书"], "顶层只有一篇")
check(tree.folders.map(\.name) == ["数学"], "顶层一个目录")
let math = tree.folders[0]
check(math.folders.map(\.name) == ["微积分", "线代"], "二级目录按名字排（得到 \(math.folders.map(\.name))）")
check(math.folders[0].notes.map(\.title) == ["导数", "极限"], "三级里的笔记按名字排")
check(tree.noteCount == 4, "连子目录一起数 = 4")
check(math.path == "数学" && math.folders[1].path == "数学/线代", "每层记着自己的相对路径")

// 🔴 空目录也要进树：只按笔记路径建树的话，还没放笔记的目录在侧栏上看不见，
//    用户没地方右键「在这里新建笔记」（2026-09-20 用户提）。
let withDirs = NoteFolder.build(items, dirs: ["马原", "数学", "数学/微积分", "数学/线代", "数学/概率/空的"],
                                rootName: "笔记")
check(withDirs.folders.map(\.name) == ["数学", "马原"], "空目录「马原」也列出来了（得到 \(withDirs.folders.map(\.name))）")
let math2 = withDirs.folders.first { $0.name == "数学" }!
check(math2.folders.map(\.name) == ["微积分", "概率", "线代"], "空的二级目录「概率」也在（得到 \(math2.folders.map(\.name))）")
check(math2.folders.first { $0.name == "概率" }?.folders.first?.name == "空的", "空目录的空子目录也建出来")
check(withDirs.noteCount == 4, "空目录不改变笔记总数")

print("\n— 7) 名字解析（🔴 按名字，不靠写进文件的 id）—")
var index = NoteIndex()
for i in items { index.add(note: i) }
check(index.note(for: "极限")?.relPath == "数学/微积分/极限.md", "按标题")
check(index.note(for: "数学/微积分/极限")?.relPath == "数学/微积分/极限.md", "按相对路径")
check(index.note(for: "极限.md")?.relPath == "数学/微积分/极限.md", "带扩展名的写法")
check(index.note(for: "别的/极限")?.relPath == "数学/微积分/极限.md", "路径对不上时退回末段文件名")
check(index.note(for: "还没写的") == nil, "解析不到 → nil（正文原样留着，画成断链）")
check(index.note(for: "  极限 ") != nil, "两头空白不影响")

// 🔴 引擎交给 resolve() 的是**没收拾过的原串**：它在第一个竖线处就切（不管有没有反斜杠转义），
//    而且不去锚点。表格里 Obsidian 把竖线写成 `\|`，于是名字尾巴上挂着一个反斜杠。
//    这几种以前全都解析不到（2026-09-20 用户的 vault 实测）。
check(index.note(for: "极限#左极限")?.relPath == "数学/微积分/极限.md", "带锚点 `名字#小节`")
check(index.note(for: "极限#^abc123")?.relPath == "数学/微积分/极限.md", "带块锚点 `名字#^块`")
check(index.note(for: "极限\\")?.relPath == "数学/微积分/极限.md", "表格里 `[[名字\\|别名]]` 留下的尾巴反斜杠")
check(index.note(for: "极限#左极限\\")?.relPath == "数学/微积分/极限.md", "锚点 + 转义竖线一起")
check(index.note(for: "数学/微积分/极限#左极限\\")?.relPath == "数学/微积分/极限.md", "带路径 + 锚点 + 转义竖线")

// 🔴 别名表：引擎把 `[[名字|别名]]` 竖线后面那段当**不透明 id** 递给 resolve()，真名它自己留着当
//    显示文本、不给我们。所以带别名的链接只能靠这张表才解析得到（不补就全是灰的、点不动）。
var ali = NoteIndex()
for i in items { ali.add(note: i) }
for p in MarkdownLink.wikiAliases("见 [[极限|那个定义]] 与 [[数学/线代/矩阵#性质\\|矩阵性质]]") {
    if let r = ali.note(for: p.target) { ali.addAlias(p.alias, r) }
}
check(ali.note(for: "那个定义")?.relPath == "数学/微积分/极限.md", "别名 → 笔记")
check(ali.note(for: "矩阵性质")?.relPath == "数学/线代/矩阵.md", "表格里带锚点的别名 → 笔记")
check(ali.note(for: "极限")?.relPath == "数学/微积分/极限.md", "真名照旧优先")
ali.addAlias("极限", NoteRef(sourceID: "ws", relPath: "读书.md"))
check(ali.note(for: "极限")?.relPath == "数学/微积分/极限.md", "别名不许盖掉同名的真名")

print("\n— 7c) wikiAliases：扫出 (目标, 别名) 对 —")
let pairs = MarkdownLink.wikiAliases("[[甲|别名一]] [[乙#锚点\\|别名二]] [[丙]] ![[图.png|300]] `[[丁|别名三]]`")
check(pairs.count == 2, "只取带别名的、跳过图片与行内代码（得到 \(pairs.count) 条）")
check(pairs.first?.target == "甲" && pairs.first?.alias == "别名一", "普通别名")
check(pairs.last?.target == "乙" && pairs.last?.alias == "别名二", "锚点 + 转义竖线的别名")

// 名字里本来就带 # 或 | 的笔记不该被收拾掉（先按原样查一次）
var odd = NoteIndex()
odd.add(note: NoteItem(ref: NoteRef(sourceID: "ws", relPath: "C#入门.md")))
check(odd.note(for: "C#入门")?.relPath == "C#入门.md", "名字里本来就带 # 的笔记，原样能查中")

print("\n— 7b) linkTarget：把写在文件里的那一串收拾成目标名 —")
eq(MarkdownLink.linkTarget("名字"), "名字", "纯名字")
eq(MarkdownLink.linkTarget("名字|别名"), "名字", "普通别名")
eq(MarkdownLink.linkTarget("名字\\|别名"), "名字", "表格里的转义竖线")
eq(MarkdownLink.linkTarget("名字#小节"), "名字", "锚点")
eq(MarkdownLink.linkTarget("名字#^块\\|别名"), "名字", "块锚点 + 转义竖线")
eq(MarkdownLink.linkTarget("名字\\"), "名字", "引擎切完留下的尾巴反斜杠")
eq(MarkdownLink.linkTarget("a\\|b"), "a", "转义竖线同样是分隔符（Obsidian 的口径）")

var dup = NoteIndex()
dup.add(note: NoteItem(ref: NoteRef(sourceID: "ws", relPath: "b/同名.md")))
dup.add(note: NoteItem(ref: NoteRef(sourceID: "ws", relPath: "a/同名.md")))
check(!dup.ambiguous.isEmpty, "重名被记下来了：\(dup.ambiguous)")
check(dup.note(for: "同名")?.relPath == "a/同名.md", "重名挑 key 字典序最小的那篇")

var nfd = NoteIndex()
nfd.add(note: NoteItem(ref: NoteRef(sourceID: "ws", relPath: "Café.md")))
check(nfd.note(for: "Cafe\u{0301}") != nil, "NFD 写法能查到 NFC 建的索引")
check(nfd.note(for: "CAFÉ") != nil, "忽略大小写兜底")

print("\n— 8) 附件按路径 / 文件名找（Obsidian 的规矩）—")
var fi = NoteIndex()
fi.addFile(relPath: "attachments/图.png", url: URL(fileURLWithPath: "/tmp/图.png"))
check(fi.file(for: "attachments/图.png")?.path == "/tmp/图.png", "按相对路径")
check(fi.file(for: "图.png")?.path == "/tmp/图.png", "只写文件名也能找到")
check(fi.file(for: "没有的.png") == nil, "找不到 → nil")

print("\n— 9) 源 —")
let wsRoot = NoteRoot.workspaceRoot(name: "笔记")
check(wsRoot.id == "ws" && wsRoot.kind == .workspace, "内建源身份固定")
check(wsRoot.rootURL(workspace: URL(fileURLWithPath: "/W/x.unrd"))?.path == "/W/x.unrd/Notes", "内建源根目录")
let ext = NoteRoot(id: "E1", kind: .reference, paths: ["/Users/me/vault"], name: "vault")
check(ext.rootURL(workspace: nil)?.path == "/Users/me/vault", "引用源根目录 = 绝对路径（本机不在时给第一条）")
let coded = try JSONDecoder().decode([NoteRoot].self, from: JSONEncoder().encode([ext]))
check(coded == [ext], "源列表 JSON 回环（存 meta.note_sources 用）")
// 多路径（2026-10-29）：同一个目录在几台电脑上各在各的位置，用本机存在的那条
let legacy = try JSONDecoder().decode([NoteRoot].self, from: Data(#"[{"id":"E1","kind":"reference","path":"/old/vault","name":"v"}]"#.utf8))
check(legacy.first?.paths == ["/old/vault"] && legacy.first?.path == "/old/vault", "老数据只有 path → 当作只有这一条")
let multi = NoteRoot(id: "E2", kind: .reference, paths: ["/Users/a/vault", "/Users/b/vault"], name: "v")
let json = String(data: try JSONEncoder().encode(multi), encoding: .utf8) ?? ""
check(json.contains(#""path":"\/Users\/a\/vault""#) && json.contains(#""paths""#),
      "写出来同时带 path（= 第一条，老版本认它）与 paths")
check(multi.localPath { $0 == "/Users/b/vault" } == "/Users/b/vault", "本机只有第二条 → 用第二条")
check(multi.localPath { _ in true } == "/Users/a/vault", "两条都在 → 用第一条")
check(multi.localPath { _ in false } == nil, "一条都不在 → nil")
let realDir = NSTemporaryDirectory()
let mixed = NoteRoot(id: "E3", kind: .reference, paths: ["/没有这个目录/vault", realDir], name: "v")
check(mixed.rootURL(workspace: nil)?.standardizedFileURL.path == URL(fileURLWithPath: realDir).standardizedFileURL.path,
      "rootURL 跳过本机不存在的那条")

// 服务器镜像（MARKDOWN-NOTES-PLAN §11）：本机没有这个目录、工作区里有 NotesMirror/<id>/ 才读镜像；本机有则一律读本机
do {
    let wsDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mdl-mirror-\(UUID().uuidString).unrd")
    let mirrorDir = wsDir.appendingPathComponent("NotesMirror/SRC1")
    try FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: wsDir) }
    let gone = NoteRoot(id: "SRC1", kind: .reference, paths: ["/Users/nobody/vault-\(UUID().uuidString)"], name: "vault")
    check(gone.mirrorURL(workspace: wsDir)?.path == mirrorDir.path, "本机没有这个目录 + 有镜像 → 读镜像")
    check(gone.rootURL(workspace: wsDir)?.path == mirrorDir.path, "rootURL 回落到镜像")
    let other = NoteRoot(id: "SRC2", kind: .reference, paths: ["/Users/nobody/x-\(UUID().uuidString)"], name: "x")
    check(other.mirrorURL(workspace: wsDir) == nil, "没有这个源的镜像 → nil（仍显示「不在这台电脑上」）")
    check(other.rootURL(workspace: wsDir)?.path == other.paths[0], "没有镜像 → 给第一条路径（老行为）")
    let here = NoteRoot(id: "SRC1", kind: .reference, paths: [NSTemporaryDirectory()], name: "vault")
    check(here.mirrorURL(workspace: wsDir) == nil, "本机有这个目录 → 不读镜像")
    check(wsRoot.mirrorURL(workspace: wsDir) == nil, "内建源没有镜像这回事")
    check(gone.mirrorURL(workspace: nil) == nil, "没有工作区 → nil")
}

print("\n— 10) 路径工具 —")
var used = Set<String>()
eq(MarkdownImport.availablePath("vault", used: &used), "vault", "第一次原样")
eq(MarkdownImport.availablePath("vault", used: &used), "vault-2", "第二次 -2")
eq(MarkdownImport.availablePath("VAULT", used: &used), "VAULT-3", "大小写也算撞（macOS 默认不区分）")
eq(MarkdownImport.normalizeRel("./a//../b.md"), "a/b.md", "去掉 . 与 ..，不许跳出源目录")
eq(MarkdownImport.safeFileName("a/b:c*?\"<>|#^[]"), "a-b-c" + String(repeating: "-", count: 10),
   "文件名里的 12 个禁用字符全换成 -")

print("\n— 11) 文件层：递归收集 / 原子写 / 整目录复制**一个字节不改** —")
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws_md_\(UInt64.random(in: 0..<1_000_000))")
let fm = FileManager.default
try? fm.removeItem(at: tmp)
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

let vault = tmp.appendingPathComponent("vault")
for d in ["数学/微积分", ".obsidian", "trash", "attachments"] {
    try! fm.createDirectory(at: vault.appendingPathComponent(d), withIntermediateDirectories: true)
}
// 🔴 这份正文里五种 [[…]] 写法齐全，复制之后必须逐字节相同
let source = "见 [[导数]]、[[数学/微积分/导数]]、[[导数|那一篇]]、[[导数#求导法则]] 与 ![[attachments/图.png]]"
try! source.write(to: vault.appendingPathComponent("数学/微积分/极限.md"), atomically: true, encoding: .utf8)
try! "见 [[极限]]".write(to: vault.appendingPathComponent("数学/微积分/导数.md"), atomically: true, encoding: .utf8)
try! "不该被收".write(to: vault.appendingPathComponent(".obsidian/app.md"), atomically: true, encoding: .utf8)
try! "也不该".write(to: vault.appendingPathComponent("trash/旧.md"), atomically: true, encoding: .utf8)
try! Data([0x89, 0x50, 0x4E, 0x47]).write(to: vault.appendingPathComponent("attachments/图.png"))

let walked = MarkdownImport.walk(vault).map { MarkdownImport.relativePath(of: $0, under: vault) }.sorted()
check(walked == ["attachments/图.png", "数学/微积分/导数.md", "数学/微积分/极限.md"],
      "跳过 .obsidian 与 trash（得到 \(walked)）")

let newFile = tmp.appendingPathComponent("新.md")
try! MarkdownImport.writeAtomically("第一版", to: newFile)
check(MarkdownImport.readText(newFile) == "第一版", "原子写：文件不存在时能建出来")
try! MarkdownImport.writeAtomically("第二版", to: newFile)
check(MarkdownImport.readText(newFile) == "第二版", "原子写：覆盖已有文件")
check(!fm.fileExists(atPath: newFile.appendingPathExtension("part").path), "不留 .part")

let notesRoot = tmp.appendingPathComponent("ws/Notes/vault")
let out = try MarkdownImport.copyTree(from: vault, to: notesRoot)
check(out.notes == 2 && out.files == 3 && out.failed.isEmpty,
      "复制：2 篇笔记 + 1 张附件（得到 \(out.notes)/\(out.files)）")
let copied = MarkdownImport.readText(notesRoot.appendingPathComponent("数学/微积分/极限.md")) ?? ""
eq(copied, source, "🔴 正文逐字相同——五种 [[…]] 写法一个都没改")
check(fm.fileExists(atPath: notesRoot.appendingPathComponent("attachments/图.png").path),
      "附件按原相对路径跟着进来（所以 ![[attachments/图.png]] 照样显示得出来）")
check(MarkdownImport.readText(vault.appendingPathComponent("数学/微积分/极限.md")) == source,
      "🔴 原目录没被动过")

print("\n— 12) 扫描 → 建树 → 解析，整条串起来 —")
var idx2 = NoteIndex()
var scanned: [NoteItem] = []
for url in MarkdownImport.walk(notesRoot) {
    let rel = MarkdownImport.relativePath(of: url, under: notesRoot)
    if MarkdownImport.isMarkdown(url) {
        let item = NoteItem(ref: NoteRef(sourceID: "ws", relPath: rel))
        scanned.append(item)
        idx2.add(note: item)
    } else {
        idx2.addFile(relPath: rel, url: url)
    }
}
check(scanned.count == 2, "扫出 2 篇")
let 极限文 = MarkdownImport.readText(notesRoot.appendingPathComponent("数学/微积分/极限.md")) ?? ""
let names = MarkdownLink.wikiReferences(极限文)
check(names == ["导数", "数学/微积分/导数"], "扫出两个不同写法的目标（得到 \(names)）")
check(names.allSatisfy { idx2.note(for: $0)?.relPath == "数学/微积分/导数.md" }, "两种写法都解析到同一篇")
check(idx2.file(for: "attachments/图.png") != nil, "附件解析得到")
let t2 = NoteFolder.build(scanned, rootName: "笔记")
check(t2.folders.first?.folders.first?.notes.count == 2, "树：数学 › 微积分 底下两篇")

print("\n— 13) md_doc 库回环（只当内建源的扫描缓存）—")
let wsDir = tmp.appendingPathComponent("libws")
try! fm.createDirectory(at: wsDir, withIntermediateDirectories: true)
let store = try LibraryStore(workspaceFolder: wsDir)
let sv = store.meta("schema_version") ?? "?"
// md_doc 是 v15 加的；之后库版本还会往上走（2026-11-12 已是 24），这里只看「至少 15」
check((Int(sv) ?? 0) >= 15, "schema ≥ v15（得到 \(sv)）")
_ = try store.addMarkdownDoc(id: "md-1", title: "极限", relPath: "vault/数学/微积分/极限.md")
let born = try store.markdownDoc(id: "md-1")!.createdAt
check(try store.allMarkdownDocs().count == 1, "插入一行")
check(try store.markdownDoc(relPath: "vault/数学/微积分/极限.md")?.id == "md-1", "按路径查得到（多级路径）")
try store.renameMarkdownDoc(id: "md-1", title: "极限的定义")
check(try store.markdownDoc(id: "md-1")?.title == "极限的定义", "改名生效")
check(try store.markdownDoc(id: "md-1")?.createdAt == born, "改名不动 created_at")
do {
    _ = try store.addMarkdownDoc(id: "md-2", title: "撞路径", relPath: "vault/数学/微积分/极限.md")
    check(false, "rel_path 应当唯一")
} catch { check(true, "rel_path 唯一约束生效") }
try store.deleteMarkdownDoc(id: "md-1")
check(try store.allMarkdownDocs().isEmpty, "删行")

print("— Agent 新建笔记的路径（MarkdownImport.newNotePath，MARKDOWN-NOTES-PLAN §14）")
func np(_ t: String, _ f: String = "") -> String? { if case .success(let r) = MarkdownImport.newNotePath(title: t, folder: f) { return r } else { return nil } }
func nr(_ t: String, _ f: String = "") -> String? { if case .failure(let w) = MarkdownImport.newNotePath(title: t, folder: f) { return w.reason } else { return nil } }
check(np("06. 法律建设") == "06. 法律建设.md", "标题 = 文件名，加 .md")
check(np("06. 法律建设.md") == "06. 法律建设.md" && np("a.MD") == "a.md", "多写的 .md 去掉（不分大小写）")
check(np("第一章", "101思想政治理论/思修") == "101思想政治理论/思修/第一章.md", "多级目录")
check(np("x", "/a//b/ ") == "a/b/x.md", "目录前后的 / 与空段去掉")
check(np("a/b: c?") == "a-b- c-.md", "文件名里的非法字符换成 -")
check(nr("  ")?.contains("empty") == true && nr(".md")?.contains("empty") == true, "空标题退回")
check(nr(".hidden")?.contains("dot") == true, "点开头的文件名退回（扫描看不见）")
check(nr("x", "a/../b")?.contains("not allowed") == true, "目录里有 .. 退回")
check(nr("x", ".obsidian")?.contains("not allowed") == true && nr("x", "a/Trash")?.contains("not allowed") == true, "点开头 / trash 目录退回")

print("— Agent 改名 / 挪目录的路径（MarkdownImport.movedNotePath，MARKDOWN-NOTES-PLAN §15）")
func mp(_ r: String, _ t: String?, _ f: String?) -> String? { if case .success(let x) = MarkdownImport.movedNotePath(from: r, title: t, folder: f) { return x } else { return nil } }
func mr(_ r: String, _ t: String?, _ f: String?) -> String? { if case .failure(let w) = MarkdownImport.movedNotePath(from: r, title: t, folder: f) { return w.reason } else { return nil } }
check(mp("数学/极限.md", "函数极限", nil) == "数学/函数极限.md", "只改名：留在原目录")
check(mp("数学/极限.md", nil, "数学/微积分") == "数学/微积分/极限.md", "只挪目录：名字不变")
check(mp("数学/极限.md", "极限的定义", "分析") == "分析/极限的定义.md", "改名 + 挪目录")
check(mp("数学/极限.md", nil, "/") == "极限.md", "\"/\" = 挪到源根")
check(mp("a#b.md", nil, "x") == "x/a#b.md", "只挪目录时文件名一个字不动（不洗非法字符）")
check(mp("a/old.markdown", "new", nil) == "a/new.markdown" && mp("a/old.md", "new.md", nil) == "a/new.md", "扩展名照留；多写的 .md 去掉")
check(mp("a/x.md", "p/q", nil) == "a/p-q.md", "新名字里的 / 换成 -（不当成目录）")
check(mr("a/x.md", " ", nil)?.contains("empty") == true && mr("a/x.md", ".h", nil)?.contains("dot") == true, "空名字 / 点开头退回")
check(mr("a/x.md", nil, "../b")?.contains("not allowed") == true && mr("a/x.md", nil, "a/.git")?.contains("not allowed") == true, "目录里有 .. / 点开头退回")
check(mp("a/x.md", "x", nil) == "a/x.md", "名字目录都没变 → 原路径（调用方当没改）")

print("— 改名后哪些 [[…]] 断了（NoteIndex.linksBroken）")
let oldR = NoteRef(sourceID: "ws", relPath: "数学/极限.md"), newR = NoteRef(sourceID: "ws", relPath: "数学/函数极限.md")
let moved = NoteRef(sourceID: "ws", relPath: "分析/极限.md")
let other = NoteRef(sourceID: "ws", relPath: "数学/导数.md")
var bi = NoteIndex(); bi.add(note: NoteItem(ref: oldR)); bi.add(note: NoteItem(ref: other))
var ai = NoteIndex(); ai.add(note: NoteItem(ref: newR)); ai.add(note: NoteItem(ref: other))
var mi = NoteIndex(); mi.add(note: NoteItem(ref: moved)); mi.add(note: NoteItem(ref: other))
let body = "见 [[极限]]、[[极限#左极限|左极限]]、[[数学/极限]]、[[导数]]、[[还没写的]]，`[[极限]]` 在代码里不算"
let br = NoteIndex.linksBroken(in: body, before: bi, after: ai, from: oldR, to: newR)
check(Set(br) == ["极限", "数学/极限"], "改名：指向它的名字 / 路径写法都算断（锚点那条与 [[极限]] 同名合并），别的链接不算（得到 \(br)）")
check(NoteIndex.linksBroken(in: "[[函数极限]]", before: bi, after: ai, from: oldR, to: newR).isEmpty, "已经写成新名字的不算断")
check(NoteIndex.linksBroken(in: body, before: bi, after: mi, from: oldR, to: moved).isEmpty, "只挪目录：按名字照样连得上，一条都不算断")

check(NoteIndex.linksBroken(in: body, before: bi, after: NoteIndex(), from: oldR, to: nil).sorted() == ["数学/极限", "极限"], "删除：指向它的全算断")
var other2 = NoteIndex(); other2.add(note: NoteItem(ref: NoteRef(sourceID: "ws", relPath: "别处/极限.md")))
check(NoteIndex.linksBroken(in: "[[极限]]", before: bi, after: other2, from: oldR, to: nil).isEmpty, "删除后同名的另一篇接上了：不算断")

print("— 目录挪动的路径（MarkdownImport.movedFolderPath，§16）")
func fp(_ f: String, _ n: String?, _ p: String?) -> String? { if case .success(let x) = MarkdownImport.movedFolderPath(from: f, name: n, parent: p) { return x } else { return nil } }
func fr(_ f: String, _ n: String?, _ p: String?) -> String? { if case .failure(let w) = MarkdownImport.movedFolderPath(from: f, name: n, parent: p) { return w.reason } else { return nil } }
check(fp("数学/微积分", "高数", nil) == "数学/高数", "只改名：留在原上级")
check(fp("数学/微积分", nil, "") == "微积分" && fp("数学/微积分", nil, "考研/数学一") == "考研/数学一/微积分", "只挪：到源根 / 到多级目录")
check(fr("数学", nil, "数学/子")?.contains("into itself") == true, "不许挪进它自己里面")
check(fp("数学", nil, "数学二") == "数学二/数学", "名字前缀相同的别的目录不算「自己里面」")
check(fr("", "x", nil)?.contains("root") == true && fr("a", ".git", nil)?.contains("dot") == true && fr("a", "Trash", nil) != nil, "源根 / 点开头 / trash 退回")
check(fp("Math", "math", nil) == "math", "只改大小写可以")

print("— 每一处 [[…]] 的行号（MarkdownLink.wikiOccurrences）")
let oc = MarkdownLink.wikiOccurrences("第一行 [[甲]]\n```\n[[代码里]]\n```\n[[乙|别名]] 和 [[甲#节]]\n![[图.png]] ![[丙]]")
check(oc.map(\.target) == ["甲", "乙", "甲", "丙"], "不去重、跳过代码块与图片（得到 \(oc.map(\.target))）")
check(oc.map(\.line) == [1, 5, 5, 6], "行号 1 起（得到 \(oc.map(\.line))）")
check(oc[1].raw == "[[乙|别名]]" && oc[3].raw == "![[丙]]", "原样写法")
let movedMap: [NoteRef: NoteRef?] = [oldR: moved, other: NoteRef(sourceID: "ws", relPath: "x/导数.md")]
var mi2 = NoteIndex(); mi2.add(note: NoteItem(ref: moved)); mi2.add(note: NoteItem(ref: NoteRef(sourceID: "ws", relPath: "x/导数.md")))
check(NoteIndex.linksBroken(in: "[[极限]] [[导数]] [[数学/导数]]", before: bi, after: mi2, moved: movedMap).isEmpty, "整个目录挪走：按名字 / 末段都连得上")

print("\n\(fail == 0 ? "✅ 全部通过" : "❌ 有失败")：\(pass) 过 / \(fail) 败")
exit(fail == 0 ? 0 : 1)
