// 图片本体走离线镜像（IMAGE-NOTE-PLAN.md §7）测试。运行：
//   cp spike/image-mirror-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/imt && /tmp/imt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 验五件事：① 建镜像带上 Images/ 里有行的文件（到期的待删除不带）；② 干跑算出对面缺的（缺行 **或** 缺文件）；
// ③ 应用后行 + 文件双向补齐，`orphaned_at` **原样带过去**；④ 合并后两侧各自对账（笔记没了 → 待删除）；
// ⑤ 图片不挡「源→副本自动推送」的门槛，但算「有东西可推」。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("image_mirror_\(UInt64.random(in: 0..<1_000_000))")
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

func resolver(_ ws: URL) -> (LibLocation) -> String? {
    { loc in (loc.inWorkspace || loc.isRelative) ? ws.appendingPathComponent(loc.path).path : loc.path }
}
func solid(_ w: Int, _ h: Int, gray: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}
/// 存一张图（文件 + 行）进某个工作区，返回 sha。
@discardableResult
func putImage(_ ws: URL, _ store: LibraryStore, gray: CGFloat, orphanedAt: Date? = nil) -> String {
    let p = ImageAssets.prepare(solid(20, 10, gray: gray))!
    try! ImageAssets.write(p, in: ws)
    try! store.insertImageIfAbsent(LibImage(sha256: p.sha256, ext: p.ext, width: p.width, height: p.height,
                                            bytes: p.data.count, createdAt: .now, orphanedAt: orphanedAt))
    return p.sha256
}
func imageNote(_ id: String, doc: String, sha: String, at: Date = .now) -> LibNote {
    LibNote(id: id, documentId: doc, kind: LibraryStore.imageNoteKind, page: 1,
            anchor: CGRect(x: 0.1, y: 0.1, width: 0, height: 0),
            payload: Data("{\"image\":\"\(sha)\",\"caption\":\"\",\"source\":{\"kind\":\"file\",\"name\":\"x.png\"}}".utf8),
            createdAt: at, updatedAt: at)
}
func planOf(_ mirror: LibraryStore, _ source: LibraryStore) -> MirrorDiff.Plan {
    MirrorDiff.compute(base: try! mirror.syncBase(),
                       mine: try! mirror.mirrorSnapshot(), theirs: try! source.mirrorSnapshot(),
                       mineOCR: try! mirror.mirrorOCRKeys(), theirsOCR: try! source.mirrorOCRKeys(),
                       mineImages: try! mirror.mirrorImageKeys(), theirsImages: try! source.mirrorImageKeys())
}

// —— 源工作区：一本书 + 三张图（A/B 有笔记引用；C 已待删除且到期）——
let src = root.appendingPathComponent("源.unrd")
try! fm.createDirectory(at: src.appendingPathComponent("PDFs"), withIntermediateDirectories: true)
let store = try! LibraryStore(workspaceFolder: src)
try! store.setWorkspaceName("图")
try! Data(repeating: 0x41, count: 256).write(to: src.appendingPathComponent("PDFs/a.pdf"))
let (doc, v) = try! store.findOrCreate(hash: "h1", title: "书", pageCount: 9, path: "PDFs/a.pdf")
_ = try! store.addLocation(variantId: v.id, path: "PDFs/a.pdf", inWorkspace: true)
let t0 = ISO.date("2026-08-01T00:00:00.000Z")!
let shaA = putImage(src, store, gray: 0.1)
let shaB = putImage(src, store, gray: 0.2)
let shaC = putImage(src, store, gray: 0.3, orphanedAt: t0.addingTimeInterval(-40 * 86_400))   // 到期 10 天了
try! store.upsertNote(imageNote("nA", doc: doc.id, sha: shaA, at: t0))
try! store.upsertNote(imageNote("nB", doc: doc.id, sha: shaB, at: t0))

print("— ① 建镜像 —")
let dst = root.appendingPathComponent("镜像.unrd")
let built = try! MirrorBuilder.create(source: src, store: store, destination: dst,
                                      plan: .init(documentsWithPDF: [doc.id]), resolve: resolver(src))
check(built.copiedImages == 2, "带过去 2 张（A、B），到期的 C 不带")
check(ImageAssets.exists(in: dst, sha256: shaA, ext: "png") && ImageAssets.exists(in: dst, sha256: shaB, ext: "png"),
      "镜像 Images/ 里有 A、B 文件")
check(!ImageAssets.exists(in: dst, sha256: shaC, ext: "png"), "镜像里没有 C 的文件")
let mirror = try! LibraryStore(workspaceFolder: dst)
check(try! mirror.images().count == 3, "image 表随 VACUUM 整份过去（3 行，含 C）")
let est = MirrorBuilder.estimate(source: src, store: store, plan: .init(documentsWithPDF: [doc.id]), resolve: resolver(src))
check(est.files == 3, "估算里计入 2 张图（1 个 PDF + 2 张图 = 3 个文件）")

print("— ② 干跑 —")
var plan = planOf(mirror, store)
check(plan.imagesToSource.isEmpty && plan.imagesToMirror.isEmpty, "刚建完两侧一致：图片零补")
check(try! mirror.mirrorImageKeys() == [shaA, shaB], "mirrorImageKeys = 有行且文件在且没到期的（A、B）")
check(try! store.mirrorImageKeys() == [shaA, shaB], "源盘同口径（C 到期不算）")

// 镜像上导入一张新图 D + 笔记；源盘上删掉 B 的笔记并对账；镜像上 A 的文件丢了（行还在）
let shaD = putImage(dst, mirror, gray: 0.4)
try! mirror.upsertNote(imageNote("nD", doc: doc.id, sha: shaD, at: t0.addingTimeInterval(3600)))
try! store.deleteNote(id: "nB")
let tDel = Date().addingTimeInterval(-3600)      // 一小时前删的（必须是「近 30 天内」，否则 B 就算到期不搬了）
try! store.reconcileImageOrphans(now: tDel)
ImageAssets.remove(in: dst, sha256: shaA, ext: "png")
plan = planOf(mirror, store)
check(plan.imagesToSource == [shaD], "干跑：D 要写入硬盘（源盘没有）")
check(plan.imagesToMirror == [shaA], "干跑：A 要拉回本机（镜像有行但文件丢了）")
check(plan.changes.contains { $0.table == "note" && $0.rowId == "nD" && $0.side == .source }, "笔记 nD 走三方合并推给源盘")
check(plan.changes.contains { $0.table == "note" && $0.rowId == "nB" && $0.side == .mirror && $0.op == .delete }, "笔记 nB 的删除推给镜像")
check(!plan.isEmpty, "plan 非空")

print("— ③ 应用 —")
let r = try! MirrorApply.apply(plan: plan, mirrorFolder: dst, mirrorStore: mirror,
                               sourceFolder: src, sourceStore: store,
                               resolveMirror: resolver(dst), resolveSource: resolver(src))
check(r.imagesFilledToSource == 1 && r.imagesFilledToMirror == 1, "补齐计数：→硬盘 1、→本机 1")
check(ImageAssets.exists(in: src, sha256: shaD, ext: "png"), "源盘有了 D 的文件")
check(try! store.image(sha256: shaD) != nil, "源盘有了 D 的行")
check(ImageAssets.exists(in: dst, sha256: shaA, ext: "png"), "镜像 A 的文件补回来了")
check((try! Data(contentsOf: ImageAssets.url(in: dst, sha256: shaA, ext: "png"))) ==
      (try! Data(contentsOf: ImageAssets.url(in: src, sha256: shaA, ext: "png"))), "补回来的 A 字节一致")

print("— ④ 合并后各自对账 —")
check(try! mirror.notes(documentId: doc.id, kind: 6).map(\.id).sorted() == ["nA", "nD"], "镜像上 nB 没了、nD 在")
check(try! store.notes(documentId: doc.id, kind: 6).map(\.id).sorted() == ["nA", "nD"], "源盘上 nD 到了")
check(try! mirror.image(sha256: shaB)!.orphanedAt != nil, "镜像上 B 失去引用 → 待删除")
check(try! store.image(sha256: shaB)!.orphanedAt.map { abs($0.timeIntervalSince(tDel)) < 0.01 } == true,
      "源盘上 B 的 orphaned_at 仍是当初删笔记那一刻（对账不重置）")
check(try! store.image(sha256: shaD)!.orphanedAt == nil && (try! mirror.image(sha256: shaD)!.orphanedAt) == nil, "D 两侧都有引用")

plan = planOf(mirror, store)
check(plan.imagesToSource.isEmpty && plan.imagesToMirror.isEmpty && plan.changes.isEmpty, "再干跑：两侧一致")

print("— ③′ orphaned_at 原样带过去 —")
// 源盘上一张已待删除但没到期的图 E（无笔记），镜像没有 → 补到镜像时时间戳必须一样
let tE = Date().addingTimeInterval(-5 * 86_400)
let shaE = putImage(src, store, gray: 0.5, orphanedAt: tE)
plan = planOf(mirror, store)
check(plan.imagesToMirror == [shaE], "E 要拉回本机（待删除但没到期，仍搬）")
_ = try! MirrorApply.apply(plan: plan, mirrorFolder: dst, mirrorStore: mirror,
                           sourceFolder: src, sourceStore: store,
                           resolveMirror: resolver(dst), resolveSource: resolver(src))
let eMirror = try! mirror.image(sha256: shaE)!
check(eMirror.orphanedAt.map { abs($0.timeIntervalSince(tE)) < 0.01 } == true, "镜像上 E 的 orphaned_at == 源盘那份（没被重置成 now）")
check(ImageAssets.exists(in: dst, sha256: shaE, ext: "png"), "E 的文件也到了")

print("— ⑤ 自动推送门槛 —")
// 源盘再加一张有笔记引用的图 F：只有图片 + 一条推给副本的笔记 → 干净推送
let shaF = putImage(src, store, gray: 0.6)
try! store.upsertNote(imageNote("nF", doc: doc.id, sha: shaF, at: Date()))
plan = planOf(mirror, store)
check(plan.isCleanPushToMirror, "源→副本：图片 + 笔记都是推给副本的 → 可自动静默推")
// 镜像上只多一张图（无笔记）：与 OCR 同口径——additive 通道**不挡**自动推送（只增不删、不进基线），
// 自动那一趟会顺手把它拷到硬盘上；三方合并那部分仍全是推给副本的，所以还是「干净推送」
let shaG = putImage(dst, mirror, gray: 0.7)
plan = planOf(mirror, store)
check(plan.imagesToSource == [shaG] && !plan.isEmpty, "镜像多一张图 → plan 非空、要写入硬盘")
check(plan.isCleanPushToMirror, "图片通道不挡自动推送（同 OCR）")
// 镜像上多一条**笔记**才是要人工确认的
try! mirror.upsertNote(imageNote("nG", doc: doc.id, sha: shaG, at: Date()))
plan = planOf(mirror, store)
check(!plan.isCleanPushToMirror && plan.pendingToSource == 1, "镜像上多一条笔记 → 不能自动推，待人工确认 1 条")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
