import Foundation

/// 注入网页的 `window.unireader`（`docs/WEB-DOC-PLAN.md §5`）：让课件把「学到哪了 / 做题记录」存进工作区、随同步走。
///
/// 两种打开方式只差「怎么把一次读写送到 App」：
/// - 内嵌（`WebDocView`）：`window.webkit.messageHandlers.unireader.postMessage`（带回复）；
/// - 本机浏览器（`WebDocLocalServer`）：`fetch` 到同一份网页下的 `__unireader__/api`。
/// App 这边两条路最后都进 `WorkspaceManager.webKV`，读写的是同一份数据。
///
/// 页面里这样用（全部返回 Promise；值是任何能 `JSON.stringify` 的东西）：
/// ```js
/// await unireader.set('progress', { chapter: 3, done: [1, 2] })
/// const p = await unireader.get('progress', { chapter: 1, done: [] })   // 第二个参数 = 没存过时的默认值
/// await unireader.remove('progress'); await unireader.keys(); await unireader.getAll(); await unireader.clear()
/// window.addEventListener('unireader:change', () => { /* 别的设备同步过来改了，重读一遍 */ })
/// ```
enum WebBridgeScript {

    static let apiPath = "__unireader__/api"

    enum Transport {
        case webkit
        /// [api] = 绝对路径（`/<token>/<id>/__unireader__/api`）。
        case fetch(api: String)
    }

    static func source(webId: String, title: String, transport: Transport) -> String {
        let info = (try? JSONSerialization.data(withJSONObject: ["id": webId, "title": title]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let call: String
        switch transport {
        case .webkit:
            call = "function (m) { return window.webkit.messageHandlers.unireader.postMessage(m); }"
        case .fetch(let api):
            let url = (try? JSONSerialization.data(withJSONObject: api, options: .fragmentsAllowed))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            call = """
            function (m) {
                return fetch(\(url), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(m) })
                  .then(function (r) { return r.text().then(function (t) { if (!r.ok) throw new Error(t); return t; }); });
              }
            """
        }
        return """
        (function () {
          if (window.unireader) return;
          var call = \(call);
          function req(op, key, value) {
            var m = { op: op };
            if (key !== undefined) m.key = String(key);
            if (value !== undefined) m.value = value;
            return Promise.resolve(call(m)).then(function (t) { return JSON.parse(t); });
          }
          var api = {
            version: 1,
            page: \(info),
            get: function (key, fallback) {
              return req('get', key).then(function (v) { return (v === null && fallback !== undefined) ? fallback : v; });
            },
            set: function (key, value) {
              if (value === undefined) return api.remove(key);
              var s = JSON.stringify(value);
              if (s === undefined) return Promise.reject(new Error('unireader.set: the value cannot be stored as JSON'));
              return req('set', key, s).then(function () {});
            },
            remove: function (key) { return req('remove', key).then(function () {}); },
            keys: function () { return req('keys'); },
            getAll: function () { return req('getAll'); },
            clear: function () { return req('clear').then(function () {}); }
          };
          Object.freeze(api);
          Object.defineProperty(window, 'unireader', { value: api, enumerable: true });
          try { window.dispatchEvent(new CustomEvent('unireader:ready')); } catch (e) {}
        })();
        """
    }

    /// 别处改了数据之后在页面里执行的一句。
    static let changeEvent = "try { window.dispatchEvent(new CustomEvent('unireader:change')); } catch (e) {}"

    // MARK: - 记住滚动位置

    /// 记住「上次看到这一页的哪里」、重新打开时滚回去（`docs/WEB-DOC-PLAN.md §3.1`；安卓 `WebBridge.scrollSource` 是同一段）。只在主框架跑。
    ///
    /// - 页面本身的滚动 `x` / `y`，外加「主滚动区」：有的课件整页不动、内容在一个铺满的 `overflow: auto` 容器里滚，
    ///   这种容器（高 ≥ 视口一半，挡掉代码块、表格这类小滚动框）记成选择器 `s` + `sx` / `sy`。
    /// - 停手 0.3 秒报一次 `{ p: location.pathname, x, y, s?, sx?, sy? }`（`post`）。
    /// - 页面加载好后问一次 App 要不要滚回去（`ask`，返回上面那样的对象或 null）：只有 App 刚打开 / 重新载入这份网页时才给，
    ///   `p` 对得上才滚；图片、公式晚到会把内容撑高，所以反复滚到位，到位且页面加载完稳定 0.5 秒、或 6 秒、或用户自己动了就停。
    ///   滚回去之前不记（免得把还没滚到位的中间位置存下来）。
    ///
    /// [post] / [ask] = 两个 JS 函数表达式：`post(o)` 送一次位置；`ask()` 返回位置对象、null 或它们的 Promise。
    static func scrollSource(post: String, ask: String) -> String {
        """
        (function () {
          if (window.top !== window || window.__unireaderScroll) return;
          try { Object.defineProperty(window, '__unireaderScroll', { value: true }); } catch (e) { return; }
          var post = \(post), ask = \(ask);
          var busy = true, timer = 0, main = '';
          var EV = ['wheel', 'touchstart', 'pointerdown', 'keydown'];
          function sel(el) {
            var parts = [];
            while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement) {
              if (el.id) {
                parts.unshift('#' + (window.CSS && CSS.escape ? CSS.escape(el.id) : el.id));
                return parts.join('>');
              }
              var i = 1, s = el;
              while ((s = s.previousElementSibling)) i++;
              parts.unshift(el.tagName.toLowerCase() + ':nth-child(' + i + ')');
              el = el.parentElement;
            }
            parts.unshift('body');
            return parts.join('>');
          }
          function find(s) { try { return s ? document.querySelector(s) : null; } catch (e) { return null; } }
          function flush() {
            timer = 0;
            if (busy) return;
            var o = { p: location.pathname, x: Math.round(window.scrollX), y: Math.round(window.scrollY) };
            var el = find(main);
            if (el) { o.s = main; o.sx = Math.round(el.scrollLeft); o.sy = Math.round(el.scrollTop); }
            try { post(o); } catch (e) {}
          }
          document.addEventListener('scroll', function (e) {
            if (busy) return;
            var t = e.target;
            if (t && t.nodeType === 1 && t.clientHeight >= window.innerHeight * 0.5) main = sel(t);
            if (!timer) timer = setTimeout(flush, 300);
          }, { capture: true, passive: true });
          window.addEventListener('pagehide', function () { if (timer) { clearTimeout(timer); flush(); } });
          function near(a, b) { return Math.abs(a - (b || 0)) < 2; }
          function at(t) {
            var ok = true;
            if (!near(window.scrollX, t.x) || !near(window.scrollY, t.y)) { window.scrollTo(t.x || 0, t.y || 0); ok = false; }
            if (t.s) {
              var el = find(t.s);
              if (!el) return false;
              main = t.s;
              if (!near(el.scrollLeft, t.sx) || !near(el.scrollTop, t.sy)) { el.scrollLeft = t.sx || 0; el.scrollTop = t.sy || 0; ok = false; }
            }
            return ok;
          }
          function done() {
            busy = false;
            EV.forEach(function (n) { window.removeEventListener(n, done, true); });
          }
          function restore(t) {
            if (!t || typeof t !== 'object' || t.p !== location.pathname || !(t.x || t.y || t.sx || t.sy)) { done(); return; }
            EV.forEach(function (n) { window.addEventListener(n, done, true); });
            var end = Date.now() + 6000, calm = 0;
            (function step() {
              if (!busy) return;
              if (at(t) && document.readyState === 'complete') calm++; else calm = 0;
              if (calm >= 5 || Date.now() > end) { done(); return; }
              setTimeout(step, 100);
            })();
          }
          function start() {
            var p;
            try { p = Promise.resolve(ask()); } catch (e) { p = Promise.resolve(null); }
            p.then(restore, done);
          }
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
          else start();
        })();
        """
    }

    /// 页面报上来的位置 → 能存的样子（只留认识的键、数字夹在合理范围；`p` 不对就不要）。
    static func sanitizeScroll(_ b: [String: Any]) -> [String: Any]? {
        guard let p = b["p"] as? String, !p.isEmpty, p.utf8.count <= 4096 else { return nil }
        var out: [String: Any] = ["p": p]
        for k in ["x", "y", "sx", "sy"] {
            if let n = (b[k] as? NSNumber)?.doubleValue, n.isFinite { out[k] = min(max(n.rounded(), 0), 10_000_000) }
        }
        if let s = b["s"] as? String, !s.isEmpty, s.utf8.count <= 1024 { out["s"] = s }
        return out
    }

    /// 把脚本塞进一份 HTML（浏览器那条路：服务端改写 html 响应）。放在 `<head>` 开头，没有 head 就放最前面。
    static func inject(_ script: String, into html: Data) -> Data {
        let tag = Data("<script>\(script)</script>".utf8)
        // 只在前 64KB 里找 `<head`（不区分大小写），找不到就放最前面（`<!doctype>` 前面也能跑，浏览器照样认）
        let window = html.prefix(64 * 1024)
        let lower = Data(String(decoding: window, as: UTF8.self).lowercased().utf8)
        if lower.count == window.count, let r = lower.range(of: Data("<head".utf8)),
           let gt = lower[r.upperBound...].firstIndex(of: UInt8(ascii: ">")) {
            let at = html.startIndex + (gt - lower.startIndex) + 1
            var out = Data(html[html.startIndex..<at])
            out.append(tag)
            out.append(html[at...])
            return out
        }
        var out = tag
        out.append(html)
        return out
    }
}
