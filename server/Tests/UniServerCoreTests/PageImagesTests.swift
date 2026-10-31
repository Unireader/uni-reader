import Foundation
import XCTest
@testable import UniServerCore

/// 服务器出图的编排（`PageImages`，方案 `WEB-READER-PLAN.md §11`）。真的 MuPDF 在 NAS 上验（`unireader-server render`），
/// 这里用两个假的 `mutool` / `cjpeg` 脚本：记下每次被叫、照参数写出文件。
final class PageImagesTests: XCTestCase {
    private var dir: URL!
    private var bin: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("page-images-\(UUID().uuidString)")
        bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try script("mutool", """
        #!/bin/sh
        echo "$*" >> "$(dirname "$0")/calls.log"
        if [ "$1" = run ]; then
          echo 'warning: ICC support is not available' >&2
          echo '{"pages":[[600,800,0],[600,3000,0],[600,800,1100]],"outline":[{"title":"第一章","page":1,"y":120.5,"children":[]}]}'
          exit 0
        fi
        out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
        sleep 0.2
        printf 'P5\\n1 1\\n255\\n0' > "$out"
        """)
        try script("cjpeg", """
        #!/bin/sh
        out=""; prev=""; last=""; for a in "$@"; do [ "$prev" = "-outfile" ] && out="$a"; prev="$a"; last="$a"; done
        cp "$last" "$out"
        """)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func script(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private var draws: Int {
        ((try? String(contentsOf: bin.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.hasPrefix("draw") }.count
    }

    private func images(limit: Int64 = 1 << 30) -> PageImages {
        PageImages(root: dir.appendingPathComponent("cache"), limitBytes: limit, searchPath: [bin.path])
    }

    func testBucketsAndTallPages() {
        XCTAssertEqual(PageImages.bucket(1), 480)
        XCTAssertEqual(PageImages.bucket(1000), 1280)
        XCTAssertEqual(PageImages.bucket(1280), 1280)
        XCTAssertEqual(PageImages.bucket(9999), 3200)
        XCTAssertEqual(PageImages.renderWidth(bucket: 1280, w: 600, h: 800), 1280)
        XCTAssertEqual(PageImages.renderWidth(bucket: 3200, w: 600, h: 3000), 1549, "细长页按 1200 万像素压窄")
        XCTAssertEqual(PageImages.renderWidth(bucket: 3200, w: 600, h: 800, native: 1423), 1423, "扫描页不比扫描图宽")
        XCTAssertEqual(PageImages.renderWidth(bucket: 960, w: 600, h: 800, native: 1423), 960)
        XCTAssertEqual(PageImages.renderWidth(bucket: 3200, w: 600, h: 3000, native: 2000), 1549)
    }

    func testInfoAndPagesAreCachedAndRenderedOnce() throws {
        let img = images()
        XCTAssertTrue(img.available)
        let pdf = dir.appendingPathComponent("book.pdf")
        let info = try JSONSerialization.jsonObject(with: try img.info(hash: "h1", pdf: pdf)) as? [String: Any]
        XCTAssertEqual((info?["pages"] as? [Any])?.count, 3)
        XCTAssertEqual(((info?["outline"] as? [[String: Any]])?.first?["title"]) as? String, "第一章")

        let a = try img.page(hash: "h1", pdf: pdf, index: 0, width: 1000)
        XCTAssertEqual(a.lastPathComponent, "p0-w1280.jpg")
        XCTAssertEqual(try img.page(hash: "h1", pdf: pdf, index: 0, width: 1100), a, "同一档：用缓存")
        XCTAssertEqual(draws, 1)
        XCTAssertEqual(try img.page(hash: "h1", pdf: pdf, index: 1, width: 4000).lastPathComponent, "p1-w1549.jpg")
        // 扫描页（扫描图 1100 像素宽）：网页要得再宽也只画 1100；要得窄就按档
        XCTAssertEqual(try img.page(hash: "h1", pdf: pdf, index: 2, width: 3200).lastPathComponent, "p2-w1100.jpg")
        XCTAssertEqual(try img.page(hash: "h1", pdf: pdf, index: 2, width: 1600).lastPathComponent, "p2-w1100.jpg")
        XCTAssertEqual(try img.page(hash: "h1", pdf: pdf, index: 2, width: 700).lastPathComponent, "p2-w720.jpg")
        XCTAssertEqual(draws, 4)
        XCTAssertThrowsError(try img.page(hash: "h1", pdf: pdf, index: 3, width: 800)) {
            XCTAssertEqual($0 as? ServerError, .badRequest("没有第 4 页"))
        }
        // 临时文件不留下
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("cache/h1").path)
        XCTAssertEqual(Set(left), ["info-2.json", "p0-w1280.jpg", "p1-w1549.jpg", "p2-w1100.jpg", "p2-w720.jpg"])
    }

    func testSameImageRequestedTogetherIsRenderedOnce() throws {
        let img = images()
        let pdf = dir.appendingPathComponent("book.pdf")
        _ = try img.info(hash: "h1", pdf: pdf)
        let failures = LockedCache<Int, Bool>()
        DispatchQueue.concurrentPerform(iterations: 6) { i in
            if (try? img.page(hash: "h1", pdf: pdf, index: 0, width: 720)) == nil { failures.set(i, true) }
        }
        XCTAssertNil((0..<6).first { failures.get($0) == true }, "都拿到了图")
        XCTAssertEqual(draws, 1)
    }

    func testPruneDropsLeastRecentlyUsed() throws {
        let img = images(limit: 30)
        let pdf = dir.appendingPathComponent("book.pdf")
        let old = try img.page(hash: "h1", pdf: pdf, index: 0, width: 480)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let new = try img.page(hash: "h1", pdf: pdf, index: 1, width: 480)
        img.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "最久没用的先删")
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
    }

    func testUnavailableWithoutTools() {
        let img = PageImages(root: dir.appendingPathComponent("cache"), limitBytes: 1 << 20, searchPath: [dir.path])
        XCTAssertFalse(img.available)
        XCTAssertThrowsError(try img.info(hash: "h", pdf: dir)) { XCTAssertEqual($0 as? ServerError, .renderUnavailable) }
    }
}
