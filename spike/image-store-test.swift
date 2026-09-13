// 图片本体（`image` 表 v13 + `Images/` 文件层）回归测试。方案 IMAGE-NOTE-PLAN.md §2~3。运行：
//   cp spike/image-store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift /tmp/main.swift -o /tmp/ist && /tmp/ist
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 验四件事：① 归一化（png/jpg 原样、tiff 转 png、超长边缩到 4096）；② 落盘幂等 + 按 sha 寻址；
// ③ 引用计数是**数出来的**（note kind=6 的 payload `image` 键）；④ 待删除对账 / 30 天清理 / 恢复引用即脱离待删除。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let fm = FileManager.default
let ws = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("img_test_\(UInt64.random(in: 0..<1_000_000)).unrd")
try! fm.createDirectory(at: ws, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: ws) }

/// 造一张 w×h 的纯色图。
func solid(_ w: Int, _ h: Int, gray: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(gray: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}
func encode(_ img: CGImage, _ type: UTType) -> Data {
    let out = NSMutableData()
    let d = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    precondition(CGImageDestinationFinalize(d))
    return out as Data
}

print("— 归一化 —")
let pngData = encode(solid(40, 30, gray: 0.2), .png)
let p1 = ImageAssets.prepare(pngData)!
check(p1.ext == "png" && p1.width == 40 && p1.height == 30, "png 原样：ext/尺寸对")
check(p1.data == pngData && p1.sha256 == ImageAssets.sha256(pngData), "png 原样：字节与 hash 都是原文件的")
check(p1.sha256.count == 64 && p1.sha256 == p1.sha256.lowercased(), "sha256 是 64 位小写十六进制")

let jpgData = encode(solid(50, 20, gray: 0.5), .jpeg)
let p2 = ImageAssets.prepare(jpgData)!
check(p2.ext == "jpg" && p2.data == jpgData, "jpg 原样存")

let tiffData = encode(solid(33, 44, gray: 0.7), .tiff)
let p3 = ImageAssets.prepare(tiffData)!
check(p3.ext == "png" && p3.width == 33 && p3.height == 44, "tiff → 转成 png，尺寸不变")
check(p3.data != tiffData, "tiff 转码后字节已不是原文件")

let big = ImageAssets.prepare(encode(solid(6000, 3000, gray: 0.9), .png))!
check(big.ext == "png" && big.width == 4096 && big.height == 2048, "长边 6000 → 缩到 4096（等比）")

check(ImageAssets.prepare(Data("not an image".utf8)) == nil, "非图片字节 → nil")
let fromCG = ImageAssets.prepare(solid(10, 10, gray: 0))!
check(fromCG.ext == "png" && fromCG.width == 10, "CGImage 直接编 PNG（PDF 节选那条路）")

print("— 落盘 —")
let u1 = try! ImageAssets.write(p1, in: ws)
check(u1.path == ws.appendingPathComponent("Images/\(p1.sha256).png").path, "路径 = Images/<sha>.<ext>")
check(fm.fileExists(atPath: u1.path) && (try! Data(contentsOf: u1)) == pngData, "文件内容 = 原字节")
let u1b = try! ImageAssets.write(p1, in: ws)
check(u1b == u1, "重复写幂等（同 sha 不重写）")
check(ImageAssets.exists(in: ws, sha256: p1.sha256, ext: "png"), "exists 认得出")
check(!fm.fileExists(atPath: ws.appendingPathComponent("Images/.\(p1.sha256).png.part").path), "没有残留 .part")
let loaded = ImageAssets.load(u1)!
check(loaded.width == 40 && loaded.height == 30, "load 原分辨率")
let thumb = ImageAssets.load(u1, maxPixel: 20)!
check(max(thumb.width, thumb.height) == 20, "load(maxPixel:) 出缩略图")

print("— 库：登记 + 引用计数 —")
let store = try! LibraryStore(workspaceFolder: ws)
check(store.meta("schema_version") == "13", "schema v13")
let (doc, _) = try! store.findOrCreate(hash: "h1", title: "书", pageCount: 10, path: "/tmp/a.pdf")
let now = Date()
func lib(_ p: ImageAssets.Prepared) -> LibImage {
    LibImage(sha256: p.sha256, ext: p.ext, width: p.width, height: p.height, bytes: p.data.count, createdAt: now, orphanedAt: nil)
}
try! store.insertImageIfAbsent(lib(p1))
try! store.insertImageIfAbsent(lib(p2))
try! store.insertImageIfAbsent(lib(p1))   // 重复登记
check(try! store.images().count == 2, "insertImageIfAbsent 幂等：两张图两行")
let row = try! store.image(sha256: p1.sha256)!
check(row.ext == "png" && row.width == 40 && row.bytes == pngData.count && row.orphanedAt == nil, "读回一行各列正确")

/// 造一条图片笔记（payload 只放契约要的键）。
func imageNote(_ id: String, sha: String) -> LibNote {
    LibNote(id: id, documentId: doc.id, kind: LibraryStore.imageNoteKind, page: 3,
            anchor: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2),
            payload: Data("{\"image\":\"\(sha)\",\"caption\":\"图\",\"display\":\"tap\",\"source\":{\"kind\":\"file\",\"name\":\"a.png\"}}".utf8),
            createdAt: now, updatedAt: now)
}
try! store.upsertNote(imageNote("n1", sha: p1.sha256))
try! store.upsertNote(imageNote("n2", sha: p1.sha256))
try! store.upsertNote(imageNote("n3", sha: p2.sha256))
// 混一条别的 kind 且 payload 恰好也有 image 键：不许被数进去
try! store.upsertNote(LibNote(id: "t1", documentId: doc.id, kind: 0, page: 1, anchor: .zero,
                              payload: Data("{\"image\":\"\(p1.sha256)\",\"quote\":\"\",\"text\":\"x\",\"rects\":[]}".utf8),
                              createdAt: now, updatedAt: now))
let refs = try! store.imageRefCounts()
check(refs[p1.sha256] == 2 && refs[p2.sha256] == 1, "引用计数按 kind=6 数：p1=2 p2=1（kind=0 的不算）")
check(try! store.imageRefCount(sha256: p1.sha256) == 2, "单张 imageRefCount")
check(try! store.imageRefCount(sha256: "nope") == 0, "没引用的 = 0")

print("— 待删除 / 清理 —")
var changed = try! store.reconcileImageOrphans(now: now)
check(changed.isEmpty, "都有引用 → 对账无变化")
try! store.deleteNote(id: "n3")
changed = try! store.reconcileImageOrphans(now: now)
check(changed == [p2.sha256], "删掉 p2 唯一引用 → 对账把 p2 标为待删除")
check(try! store.image(sha256: p2.sha256)!.orphanedAt.map { abs($0.timeIntervalSince(now)) < 0.01 } == true, "orphaned_at = now")
let later = now.addingTimeInterval(5 * 86_400)
changed = try! store.reconcileImageOrphans(now: later)
check(changed.isEmpty, "已是待删除的**不重置** orphaned_at（再对账无变化）")
check(try! store.image(sha256: p2.sha256)!.orphanedAt.map { abs($0.timeIntervalSince(now)) < 0.01 } == true, "orphaned_at 仍是最初那一刻")
let stats = store.imageStats()
check(stats.total == 2 && stats.orphaned == 1 && stats.bytes == Int64(pngData.count + jpgData.count), "imageStats：2 张 / 1 待删 / 字节和")

// 调用方的口径：before = 「此刻 − 30 天」。第 5 天时 = now − 25d，orphaned_at(=now) 不早于它 → 不可清
check(try! store.purgeableImages(before: later.addingTimeInterval(-LibraryStore.imagePurgeAfter)).isEmpty, "不到 30 天不可清")
let day31 = now.addingTimeInterval(31 * 86_400)
let due = try! store.purgeableImages(before: day31.addingTimeInterval(-LibraryStore.imagePurgeAfter))
check(due.map(\.sha256) == [p2.sha256], "过 30 天 → p2 可清；p1 有引用不在列")
check(try! store.purgeableImages(before: .distantFuture).count == 1, "以「现在」为界立即清理 = 同一份列表")

// 恢复引用（撤销删除）→ 脱离待删除
try! store.upsertNote(imageNote("n3", sha: p2.sha256))
changed = try! store.reconcileImageOrphans(now: later)
check(changed == [p2.sha256] && (try! store.image(sha256: p2.sha256)!.orphanedAt) == nil, "引用回来 → orphaned_at 清空")

// only 参数：只对账指定那几张
try! store.deleteNote(id: "n3")
changed = try! store.reconcileImageOrphans(now: later, only: [p1.sha256])
check(changed.isEmpty && (try! store.image(sha256: p2.sha256)!.orphanedAt) == nil, "only=[p1] 时不碰 p2")
changed = try! store.reconcileImageOrphans(now: later, only: [p2.sha256])
check(changed == [p2.sha256], "only=[p2] 才把 p2 标上")

// 真删：文件 + 行（顺序：调用方先删文件再删行）
_ = try! ImageAssets.write(p2, in: ws)
for im in try! store.purgeableImages(before: .distantFuture) {
    ImageAssets.remove(in: ws, sha256: im.sha256, ext: im.ext)
    try! store.deleteImage(sha256: im.sha256)
}
check(try! store.images().count == 1 && !ImageAssets.exists(in: ws, sha256: p2.sha256, ext: "jpg"), "清理后 p2 行与文件都没了，p1 还在")
ImageAssets.remove(in: ws, sha256: "not-there", ext: "png")
check(true, "删不存在的文件不抛（幂等）")

// 复制（镜像补齐那条路）
let other = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("img_test_other_\(UInt64.random(in: 0..<1_000_000)).unrd")
try! fm.createDirectory(at: other, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: other) }
try! ImageAssets.copy(from: u1, to: other, sha256: p1.sha256, ext: "png")
check((try! Data(contentsOf: ImageAssets.url(in: other, sha256: p1.sha256, ext: "png"))) == pngData, "copy 到另一工作区，字节一致")
try! ImageAssets.copy(from: u1, to: other, sha256: p1.sha256, ext: "png")
check(true, "copy 幂等")

// 库里 orphaned_at 带值登记（镜像补行时要**原样带过去**，不能被重置）
let stamp = ISO.date("2026-08-01T00:00:00.000Z")!
try! store.insertImageIfAbsent(LibImage(sha256: "deadbeef", ext: "png", width: 1, height: 1, bytes: 1, createdAt: now, orphanedAt: stamp))
check(try! store.image(sha256: "deadbeef")!.orphanedAt == stamp, "insertImageIfAbsent 保留传入的 orphaned_at")

print("\n\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
