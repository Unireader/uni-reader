// 网页记住滚动位置（`docs/WEB-DOC-PLAN.md §3.1`，`WebBridgeScript.scrollSource`）：真 WKWebView 离屏跑，
// 页面经自定义协议读（同 App），脚本放隔离环境 `.defaultClient`（同 `WebDocView`）。运行：
//   cp spike/web-scroll-test.swift /tmp/main.swift && \
//     swiftc Sources/App/WebBridgeScript.swift /tmp/main.swift -o /tmp/ws && /tmp/ws
// 安卓 `WebBridge.scrollSource` 是同一段 JS，改了这边记得同步那边。

import AppKit
import WebKit

setvbuf(stdout, nil, _IONBF, 0)

var pass = 0, fail = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { pass += 1; print("  ✅ \(msg)") } else { fail += 1; print("  ❌ \(msg)") }
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

/// 长页：一开始只有 `start` 高，`grow` 毫秒后撑到 `full` 高（模拟图片 / 公式晚到）。
func longPage(start: Int, full: Int, grow: Int) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><style>body{margin:0}</style></head><body>
    <div id="box" style="height:\(start)px;background:linear-gradient(#fff,#888)"></div>
    <script>setTimeout(function(){ document.getElementById('box').style.height='\(full)px'; }, \(grow));</script>
    </body></html>
    """
}
/// 整页不动、内容在一个铺满的滚动容器里（不带 id → 选择器走 nth-child）；另有一个小滚动框（不该被当成主滚动区）。
let innerPage = """
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{height:100%;margin:0;overflow:hidden} header{height:40px}
.pane{height:calc(100% - 40px);overflow:auto} pre{height:40px;overflow:auto;margin:0}</style></head><body>
<header>标题</header><div class="pane"><pre id="code">\(String(repeating: "x\n", count: 50))</pre><div style="height:6000px"></div></div>
</body></html>
"""

var pages: [String: String] = [:]

final class Scheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let path = task.request.url?.path ?? "/"
        let body = Data((pages[path] ?? "<p>404</p>").utf8)
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: body.count, textEncodingName: "utf-8"))
        task.didReceive(body)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// 同 `WebDocView`：save 存下（`store` = 本机记忆）；`armed` 时 target 交出记忆一次；重新载入时重新置上 `armed`。
final class Host: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    var saved: [[String: Any]] = []
    var store: [String: Any]?
    var armed = false
    var asked = 0
    var finished = false
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let b = m.body as? [String: Any] else { replyHandler(nil, nil); return }
        if b["op"] as? String == "target" {
            asked += 1
            let t = armed ? store : nil
            armed = false
            replyHandler(t, nil)
        } else {
            if let pos = WebBridgeScript.sanitizeScroll(b) { saved.append(pos); store = pos }
            replyHandler(nil, nil)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if a.navigationType == .reload, a.targetFrame?.isMainFrame ?? false { armed = true }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

func makeView(_ host: Host) -> WKWebView {
    let cfg = WKWebViewConfiguration()
    cfg.setURLSchemeHandler(Scheme(), forURLScheme: "unireader-web")
    cfg.userContentController.addUserScript(WKUserScript(source: WebBridgeScript.scrollSource(
        post: "function (o) { o.op = 'save'; window.webkit.messageHandlers.unireaderScroll.postMessage(o); }",
        ask: "function () { return window.webkit.messageHandlers.unireaderScroll.postMessage({ op: 'target' }); }"),
        injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    cfg.userContentController.addScriptMessageHandler(host, contentWorld: .defaultClient, name: "unireaderScroll")
    let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
    v.navigationDelegate = host
    return v
}

func open(_ v: WKWebView, _ host: Host, _ path: String) {
    host.finished = false
    v.load(URLRequest(url: URL(string: "unireader-web://test" + path)!))
    let end = Date().addingTimeInterval(10)
    while !host.finished && Date() < end { spin(0.05) }
}

/// 在页面自己的环境里求值，取一个数。
func num(_ v: WKWebView, _ js: String) -> Double {
    var out: Double = -1, done = false
    v.evaluateJavaScript(js) { r, _ in out = (r as? NSNumber)?.doubleValue ?? -1; done = true }
    let end = Date().addingTimeInterval(5)
    while !done && Date() < end { spin(0.02) }
    return out
}

func run(_ js: String, _ v: WKWebView) { _ = num(v, js + "; 0") }

_ = NSApplication.shared
pages["/a/long.html"] = longPage(start: 5000, full: 5000, grow: 0)
pages["/a/late.html"] = longPage(start: 900, full: 5000, grow: 700)
pages["/inner.html"] = innerPage

print("① 记下页面的滚动位置")
do {
    let h = Host(), v = makeView(h)
    open(v, h, "/a/long.html")
    spin(0.3)
    check(h.asked == 1, "页面加载好后问了一次要不要滚回去（\(h.asked)）")
    run("window.scrollTo(0, 1500)", v)
    spin(0.8)
    let last = h.saved.last
    check(last?["p"] as? String == "/a/long.html", "路径 = location.pathname（\(last?["p"] ?? "nil")）")
    check((last?["y"] as? Double) == 1500, "y = 1500（\(last?["y"] ?? "nil")）")
    check(last?["s"] == nil, "没有主滚动区")
    check(h.saved.count <= 2, "停手才报，不是每个滚动事件都报（\(h.saved.count) 次）")
}

print("② 重新打开滚回去（内容晚到撑高也能到位）")
do {
    let h = Host(), v = makeView(h)
    h.store = ["p": "/a/late.html", "x": 0.0, "y": 3000.0]; h.armed = true
    open(v, h, "/a/late.html")
    // 离屏视图算「隐藏页面」：WebKit 约 1 秒后把定时器降到快 1 秒一次，稳定 5 步要多等（显示着的页面没有这回事）
    spin(4.0)
    check(num(v, "window.scrollY") == 3000, "scrollY = 3000（\(num(v, "window.scrollY"))）")
    check(h.saved.isEmpty, "滚回去途中不记中间位置（\(h.saved.count) 次）")
    // 滚回去那一段还没收尾时的滚动不记（降频时收尾时刻会抖），所以反复滚、等它记上
    let until = Date().addingTimeInterval(8)
    while h.saved.isEmpty && Date() < until { run("window.scrollTo(0, 3200)", v); spin(0.5) }
    check((h.saved.last?["y"] as? Double) == 3200, "滚完之后照常记（\(h.saved.last?["y"] ?? "nil")）")
}

print("③ 记的不是这一页：不滚")
do {
    let h = Host(), v = makeView(h)
    h.store = ["p": "/a/other.html", "y": 1500.0]; h.armed = true
    open(v, h, "/a/long.html")
    spin(1.0)
    check(num(v, "window.scrollY") == 0, "scrollY = 0（\(num(v, "window.scrollY"))）")
}

print("④ 用户自己动了就不再往回拽")
do {
    let h = Host(), v = makeView(h)
    h.store = ["p": "/a/late.html", "y": 3000.0]; h.armed = true
    open(v, h, "/a/late.html")
    run("window.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown' }))", v)
    spin(1.5)
    let y = num(v, "window.scrollY")
    check(y < 3000, "内容撑高后没有再被拽到 3000（\(y)）")
}

print("⑤ 内容在铺满的滚动容器里")
do {
    let h = Host(), v = makeView(h)
    open(v, h, "/inner.html")
    spin(0.3)
    run("document.querySelector('.pane').scrollTop = 2000", v)
    spin(0.8)
    run("document.getElementById('code').scrollTop = 30", v)   // 小滚动框：不换主滚动区
    spin(0.8)
    let last = h.saved.last
    check(last?["s"] as? String == "body>div:nth-child(2)", "主滚动区选择器（\(last?["s"] ?? "nil")）")
    check((last?["sy"] as? Double) == 2000, "sy = 2000（\(last?["sy"] ?? "nil")）")
    check((last?["y"] as? Double) == 0, "页面本身没动（\(last?["y"] ?? "nil")）")

    let h2 = Host(), v2 = makeView(h2)
    h2.store = last; h2.armed = true
    open(v2, h2, "/inner.html")
    spin(1.5)
    check(num(v2, "document.querySelector('.pane').scrollTop") == 2000, "重新打开容器滚回 2000（\(num(v2, "document.querySelector('.pane').scrollTop"))）")
}

print("⑥ 连着重新载入不往上跑（WebKit 自己恢复时内容还没撑高会被截短、滚动容器不恢复）")
func reloadWait(_ v: WKWebView, _ h: Host, _ settle: Double) {
    h.finished = false
    v.reload()
    let end = Date().addingTimeInterval(10)
    while !h.finished && Date() < end { spin(0.05) }
    spin(settle)
}
for (path, js, read, key) in [("/a/late.html", "window.scrollTo(0, 3000)", "window.scrollY", "y"),
                              ("/inner.html", "document.querySelector('.pane').scrollTop = 3000", "document.querySelector('.pane').scrollTop", "sy")] {
    let h = Host(), v = makeView(h)
    open(v, h, path); spin(1.0)   // late.html 0.7 秒后才撑高，等它撑高再滚
    run(js, v); spin(0.8)
    check(Int(num(v, read)) == 3000, "\(path) 起点 3000")
    var ys: [Int] = []
    for _ in 0..<3 { reloadWait(v, h, 4.0); ys.append(Int(num(v, read))) }
    check(ys.allSatisfy { $0 == 3000 }, "\(path) 刷新三次：\(ys.map(String.init).joined(separator: " → "))")
    check(h.store?[key] as? Double == 3000, "记忆没被截短的位置覆盖（\(key) = \(h.store?[key] ?? "nil")）")
}
do {   // 刚滚完 0.3 秒内就刷新：旧页面卸下时补报，新页面滚到的是最新那个位置
    let h = Host(), v = makeView(h)
    open(v, h, "/a/long.html"); spin(0.3)
    run("window.scrollTo(0, 1000)", v); spin(0.8)
    run("window.scrollTo(0, 2500)", v)
    reloadWait(v, h, 4.0)
    check(num(v, "window.scrollY") == 2500, "刚滚完马上刷新停在最新位置（\(num(v, "window.scrollY"))）")
}

print("⑦ 存之前清洗")
check(WebBridgeScript.sanitizeScroll(["y": 3.0]) == nil, "没有路径不要")
let s = WebBridgeScript.sanitizeScroll(["p": "/x", "y": -5.0, "x": Double.infinity, "zz": 1, "s": ""]) ?? [:]
check(s["y"] as? Double == 0 && s["x"] == nil && s["zz"] == nil && s["s"] == nil, "负数夹到 0、非有限数 / 不认识的键 / 空选择器丢掉")

print("\n\(pass) 通过，\(fail) 失败")
exit(fail == 0 ? 0 : 1)
