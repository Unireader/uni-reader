// 本机 OCR 服务（github.com/xVanTuring/ocr-services）接入的端到端测试。运行（仓库根目录）：
//   python3 spike/ocr-stub-server.py 8790 &            # 假服务：验异步 job 语义
//   cp spike/ocr-local-test.swift /tmp/main.swift && swiftc Sources/App/PageText.swift \
//     Sources/App/OCRTextSelect.swift Sources/Support/Keychain.swift Sources/App/PaddleOCR.swift \
//     Sources/App/LocalOCR.swift Sources/App/OCRBackend.swift /tmp/main.swift -o /tmp/ocrlocal && /tmp/ocrlocal
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 四组的依赖各不相同，连不上的组自动跳过：
//  · 地址归一化 / 配置与引擎选择 / 健康检查 —— 离线可跑（健康检查连不上只记 skip）。
//  · 异步 job 语义 —— 要假服务（`spike/ocr-stub-server.py`）：提交即返回、要轮过 pending/running
//    才拿得到结果、排队满 503 按 Retry-After 重投、识别出错走 failed+errorMsg、不跟服务端回的绝对
//    jsonUrl。这几条光靠真服务测不准（真机一页几百毫秒，未必赶得上排队），所以拿假服务钉住。
//  · 真实识别一页 —— 要真服务在跑（`./ocr-service.sh start`），守的是与 `docs/API.md` 的字段契约：
//    哪天提交/查询/结果三步的格式变了，这里先红。
import AppKit
import CoreGraphics
import Foundation

var pass = 0, fail = 0, skipped = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }
func skip(_ m: String) { skipped += 1; print("  ⏭️  \(m)") }

let d = UserDefaults.standard
d.removeObject(forKey: LocalOCR.addressKey)
d.removeObject(forKey: PaddleOCR.engineKey)

print("地址归一化")
check(LocalOCR.normalizedAddress("") == LocalOCR.defaultAddress, "空 = 用默认 \(LocalOCR.defaultAddress)")
check(LocalOCR.normalizedAddress("   ") == LocalOCR.defaultAddress, "全空白 = 用默认")
check(LocalOCR.normalizedAddress("127.0.0.1:9000") == "http://127.0.0.1:9000", "没写 scheme 补 http://")
check(LocalOCR.normalizedAddress("http://localhost:8766/") == "http://localhost:8766", "去掉末尾斜杠")
check(LocalOCR.normalizedAddress(" https://192.168.1.5:8766 ") == "https://192.168.1.5:8766", "去首尾空白、保留 https")

print("配置与引擎选择")
d.set("http://127.0.0.1:8766", forKey: LocalOCR.addressKey)
d.set(OCRBackend.local.rawValue, forKey: PaddleOCR.engineKey)
check(OCRBackend.current == .local, "ocrEngine=local → OCRBackend.current = .local")
check(OCRBackend.current.config?.providerID == LocalOCR.providerID, "config 带上本机的缓存标识")
check(OCRBackend.current.config?.apiKey == "", "本机服务不带 API key")
check(OCRBackend.current.isReady, "本机服务免配置即可用（地址合法）")
check(LocalOCR.providerID != PaddleOCR.providerID, "缓存标识与云端分开（\(LocalOCR.providerID) ≠ \(PaddleOCR.providerID)）")
d.set("off", forKey: PaddleOCR.engineKey)
check(!OCRBackend.current.isReady, "ocrEngine=off → 不就绪")
check(OCRBackend.current.providerID == PaddleOCR.providerID, "「关闭」按云端标识读缓存（库里旧结果仍可用）")
d.set(OCRBackend.local.rawValue, forKey: PaddleOCR.engineKey)
d.set("ftp://127.0.0.1:8766", forKey: LocalOCR.addressKey)
check(LocalOCR.baseURL == nil && OCRBackend.current.config == nil, "非 http(s) 的地址算没配好")
d.set("no such host", forKey: LocalOCR.addressKey)
check(LocalOCR.baseURL == nil, "没有 host 的地址算没配好")
d.set(LocalOCR.defaultAddress, forKey: LocalOCR.addressKey)

print("健康检查")
let h = await LocalOCR.checkHealth()
switch h {
case .badAddress: check(false, "地址合法却报 badAddress")
case .offline:    skip("服务没在跑（healthz 无响应），跳过在线断言与真实识别")
case .online(let loaded):
    check(true, "healthz 在线（loaded=\(loaded)）")
    check(!OCRBackend.local.isReady || OCRBackend.local.config != nil, "选中本机服务时 config 可用")
}

print("异步 job 语义（对着假服务验：提交即返回、要轮询到 done）")
// 起假服务：python3 spike/ocr-stub-server.py 8790
let stub = "http://127.0.0.1:8790"
if await reachable(stub + "/healthz"), let img = testPage() {
    d.set(stub, forKey: LocalOCR.addressKey)
    if let sconfig = LocalOCR.config() {
        check(sconfig.pollInterval == 0.5 && sconfig.pollBudget == 300,
              "本机节奏：间隔 \(sconfig.pollInterval)s、总预算 \(Int(sconfig.pollBudget))s")
        // 假服务回的 jsonUrl 故意指着 127.0.0.1:1（取不到），所以下面能成 = 客户端按固定路径拼、没跟它。
        let t0 = Date()
        do {
            let runs = try await PaddleOCR.recognize(image: img, config: sconfig)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            check(!runs.isEmpty, "走 pending → running → done，解析出 \(runs.count) 行")
            check(ms >= 900, "确实等了约两轮轮询（\(ms)ms），不是查一次就当完了")
            check(ms < 5000, "到了 done 就收手，没白等（\(ms)ms）")
        } catch {
            check(false, "异步流程抛错：\(error.localizedDescription)")
        }
        // 排队满：提交先吃一个 503 + Retry-After: 1，客户端照头退避后重投。
        await postControl(stub + "/control/503-once")
        let t1 = Date()
        do {
            let runs = try await PaddleOCR.recognize(image: img, config: sconfig)
            let ms = Int(Date().timeIntervalSince(t1) * 1000)
            check(!runs.isEmpty && ms >= 1900, "503 按 Retry-After 重投后成功（\(ms)ms = 1s 退避 + 轮询）")
        } catch {
            check(false, "503 重投失败：\(error.localizedDescription)")
        }
        // 识别出错不再让提交失败，而是任务状态变 failed（errorMsg 里带原因）。
        await postControl(stub + "/control/fail-next")
        do {
            _ = try await PaddleOCR.recognize(image: img, config: sconfig)
            check(false, "任务 failed 却没报错（不该）")
        } catch {
            check(error.localizedDescription.contains("model load failed"),
                  "failed 的 errorMsg 透传出来：\(error.localizedDescription)")
        }
    } else {
        check(false, "假服务地址没被接受")
    }
    d.set(LocalOCR.defaultAddress, forKey: LocalOCR.addressKey)
} else {
    skip("假服务没起（python3 spike/ocr-stub-server.py 8790），跳过异步语义")
}

print("真实识别一页（走 LocalOCR 的参数 + PaddleOCR 那套客户端）")
if h == .offline {
    skip("服务没在跑，跳过在线断言与真实识别")
} else if let config = LocalOCR.config(), let img = testPage() {
    let t0 = Date()
    do {
        let runs = try await PaddleOCR.recognize(image: img, config: config)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        check(!runs.isEmpty, "识别到 \(runs.count) 行（\(ms)ms）")
        let all = runs.map(\.text).joined(separator: " ")
        check(all.contains("12345"), "数字行认出来了：\(all.prefix(60))")
        check(runs.allSatisfy { $0.w > 0 && $0.h > 0 && $0.x >= 0 && $0.y >= 0
                                 && $0.x + $0.w <= 1.001 && $0.y + $0.h <= 1.001 }, "行框归一化在 [0,1]")
        check(runs.contains { $0.chars != nil && $0.chars!.count == $0.text.count + 1 },
              "returnWordBox 生效：有行带单字框（chars = 字数+1）")
        check(zip(runs, runs.dropFirst()).allSatisfy { $0.y <= $1.y }, "按阅读顺序排好")
        // 服务没起来时的文案（127.0.0.1:1 必被拒），就是设置页/面板上用户会看到的那句。
        var down = config
        down.endpoint = URL(string: "http://127.0.0.1:1/api/v2/ocr/jobs")!
        do {
            _ = try await PaddleOCR.recognize(image: img, config: down)
            check(false, "端口不通却成功了（不该）")
        } catch {
            let m = error.localizedDescription
            check(m.contains("连不上") && m.contains(LocalOCR.repoLabel),
                  "连不上的文案带解决办法：\(m.prefix(70))…")
        }
    } catch {
        check(false, "识别抛错：\(error.localizedDescription)")
    }
} else {
    check(false, "config 或测试图没出来，无法跑真实识别")
}

/// 一个地址现在能不能连通（真服务/假服务没起时用来跳过在线断言）。
func reachable(_ url: String) async -> Bool {
    guard let u = URL(string: url) else { return false }
    var req = URLRequest(url: u)
    req.timeoutInterval = 3
    return (try? await URLSession.shared.data(for: req)) != nil
}

func postControl(_ url: String) async {
    guard let u = URL(string: url) else { return }
    var req = URLRequest(url: u)
    req.httpMethod = "POST"
    req.timeoutInterval = 5
    _ = try? await URLSession.shared.data(for: req)
}

/// 一页中英混合文字（和阅读区一样是 top-origin 位图）。
func testPage() -> CGImage? {
    let px = 1600, py = 500
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: px, height: py)).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56),
                                                .foregroundColor: NSColor.black]
    ("本地 OCR 接入 12345" as NSString).draw(at: NSPoint(x: 60, y: 300), withAttributes: attrs)
    ("The quick brown fox" as NSString).draw(at: NSPoint(x: 60, y: 120), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage
}

print("\n通过 \(pass)，失败 \(fail)，跳过 \(skipped)")
exit(fail == 0 ? 0 : 1)
