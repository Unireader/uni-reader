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
