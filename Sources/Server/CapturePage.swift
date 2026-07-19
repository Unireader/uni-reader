import Foundation

/// 平板采集端网页 v4（横屏铺满 + 滚动 + 全屏）：
/// - 页面按**宽度铺满**（fit-width）；页面比屏高时**手指拖动竖向滚动**（笔画画、手指滚），墨迹随滚动重绘。
/// - 笔身侧键：PageUp 切模式（笔记/擦除/翻页），PageDown 切笔。右上角**全屏**按钮。
/// - 归一化页面坐标回传 Mac；顶栏文档下拉、WS 延迟。
enum CapturePage {
    static func html(token: String, wsPort: UInt16) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-Hans">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <title>UniReader 采集端</title>
        <style>
          * { box-sizing:border-box; -webkit-user-select:none; user-select:none; -webkit-tap-highlight-color:transparent; }
          html,body { margin:0; height:100%; overflow:hidden; overscroll-behavior:none; background:#0d1117; color:#e6edf3;
            font-family:-apple-system,"PingFang SC",system-ui,sans-serif; }
          canvas { position:fixed; inset:0; }
          #bg { z-index:1; }
          #ink { z-index:2; touch-action:none; }
          #hover { z-index:3; pointer-events:none; }
          #topbar { position:fixed; left:0; right:0; top:0; height:46px; z-index:10;
            display:flex; align-items:center; gap:10px; padding:0 10px;
            background:rgba(22,27,34,.9); -webkit-backdrop-filter:blur(6px); backdrop-filter:blur(6px);
            border-bottom:1px solid #30363d; }
          #dot { width:10px; height:10px; border-radius:50%; background:#f85149; flex:none; }
          #dot.on { background:#3fb950; }
          #swatch { width:16px; height:16px; border-radius:50%; border:2px solid #58a6ff; background:#185ad2; flex:none; }
          #mode { font-weight:600; white-space:nowrap; }
          #lat { color:#8b949e; font-variant-numeric:tabular-nums; font-size:13px; white-space:nowrap; }
          #docs { max-width:28vw; padding:6px 8px; border:1px solid #30363d; border-radius:8px;
            background:#21262d; color:#e6edf3; font-size:14px; }
          #pageLabel { margin-left:auto; font-variant-numeric:tabular-nums; white-space:nowrap; }
          #topbar button { padding:8px 14px; font-size:16px; border:1px solid #30363d; border-radius:8px;
            background:#21262d; color:#e6edf3; }
          #topbar button:active { background:#30363d; }
        </style>
        </head>
        <body>
        <canvas id="bg"></canvas>
        <canvas id="ink"></canvas>
        <canvas id="hover"></canvas>
        <div id="topbar">
          <span id="dot"></span>
          <span id="swatch"></span>
          <span id="mode">笔记</span>
          <span id="lat">— ms</span>
          <select id="docs"></select>
          <span id="pageLabel">— / —</span>
          <button id="prev">‹</button>
          <button id="next">›</button>
          <button id="full">⛶</button>
        </div>
        <script>
        (function () {
          var PORT = \(wsPort), TOKEN = "\(token)";
          var BAR = 46;
          var PENS = [
            { name: "蓝", color: "rgba(24,90,210,0.95)", w: 8 },
            { name: "红", color: "rgba(220,40,40,0.95)", w: 9 },
            { name: "黑", color: "rgba(20,20,20,0.95)", w: 14 }
          ];
          var MODES = [{ key: "note", label: "笔记" }, { key: "erase", label: "擦除" }, { key: "page", label: "翻页" }];
          var modeIdx = 0, penIdx = 0;

          var el = function (id) { return document.getElementById(id); };
          var bg = el("bg"), ink = el("ink"), hover = el("hover");
          var bctx = bg.getContext("2d"), ictx = ink.getContext("2d"), hctx = hover.getContext("2d");
          var DPR = 1;
          var pageW = 1, pageH = 1.4142, pageIndex = 0, pageCount = 0;
          var dispW = 1, dispH = 1, scrollY = 0, maxScroll = 0;   // fit-width 布局
          var pageImg = new Image();
          pageImg.onload = function () { layout(); };

          function curMode() { return MODES[modeIdx].key; }
          function curPen() { return PENS[penIdx]; }

          function sizeCanvas(c, cx) {
            c.width = Math.round(window.innerWidth * DPR);
            c.height = Math.round(window.innerHeight * DPR);
            c.style.width = window.innerWidth + "px";
            c.style.height = window.innerHeight + "px";
            cx.setTransform(DPR, 0, 0, DPR, 0, 0);
            cx.lineCap = "round"; cx.lineJoin = "round";
          }
          function layout() {
            DPR = Math.max(1, window.devicePixelRatio || 1);
            sizeCanvas(bg, bctx); sizeCanvas(ink, ictx); sizeCanvas(hover, hctx);
            dispW = window.innerWidth;                 // 宽度铺满
            dispH = dispW * pageH / pageW;
            var availH = window.innerHeight - BAR;
            maxScroll = Math.max(0, dispH - availH);
            scrollY = Math.min(Math.max(0, scrollY), maxScroll);
            drawAll();
          }
          window.addEventListener("resize", layout);

          // ---- 坐标映射 ----
          function toView(nx, ny) { return { x: nx * dispW, y: BAR + ny * dispH - scrollY }; }
          function toNorm(x, y) {
            return [Math.min(1, Math.max(0, x / dispW)),
                    Math.min(1, Math.max(0, (y - BAR + scrollY) / dispH))];
          }
          function inPage(x, y) {
            var ny = (y - BAR + scrollY) / dispH;
            return y >= BAR && x >= 0 && x <= dispW && ny >= 0 && ny <= 1;
          }

          // ---- 墨迹存储 + 重绘 ----
          var strokes = [], cur = null;
          function drawAll() { drawBg(); drawInk(); }
          function drawBg() {
            bctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
            if (pageImg.complete && pageImg.naturalWidth) {
              bctx.fillStyle = "#fff"; bctx.fillRect(0, BAR - scrollY, dispW, dispH);
              bctx.drawImage(pageImg, 0, BAR - scrollY, dispW, dispH);
            }
          }
          function drawStroke(s) {
            var pts = s.pts; if (!pts.length) return;
            var p0 = toView(pts[0][0], pts[0][1]);
            ictx.fillStyle = s.pen.color;
            ictx.beginPath(); ictx.arc(p0.x, p0.y, (0.6 + pts[0][2] * s.pen.w) / 2, 0, Math.PI * 2); ictx.fill();
            var lastMid = p0, lastPt = p0;
            for (var i = 1; i < pts.length; i++) {
              var pv = toView(pts[i][0], pts[i][1]), pr = pts[i][2];
              var mx = (lastPt.x + pv.x) / 2, my = (lastPt.y + pv.y) / 2;
              ictx.strokeStyle = s.pen.color; ictx.lineWidth = 0.6 + pr * s.pen.w;
              ictx.beginPath(); ictx.moveTo(lastMid.x, lastMid.y); ictx.quadraticCurveTo(lastPt.x, lastPt.y, mx, my); ictx.stroke();
              lastMid = { x: mx, y: my }; lastPt = pv;
            }
          }
          function drawInk() {
            ictx.clearRect(0, 0, window.innerWidth, window.innerHeight);
            for (var i = 0; i < strokes.length; i++) drawStroke(strokes[i]);
            if (cur) drawStroke(cur);
          }

          // 实时增量落墨（视口坐标；一笔期间不滚动，故与存储一致）
          var lastPt = null, lastMid = null;
          function liveBegin(x, y, p, pen) {
            lastPt = { x: x, y: y }; lastMid = { x: x, y: y };
            ictx.beginPath(); ictx.fillStyle = pen.color; ictx.arc(x, y, (0.6 + p * pen.w) / 2, 0, Math.PI * 2); ictx.fill();
          }
          function liveTo(x, y, p, pen) {
            var mx = (lastPt.x + x) / 2, my = (lastPt.y + y) / 2;
            ictx.strokeStyle = pen.color; ictx.lineWidth = 0.6 + p * pen.w;
            ictx.beginPath(); ictx.moveTo(lastMid.x, lastMid.y); ictx.quadraticCurveTo(lastPt.x, lastPt.y, mx, my); ictx.stroke();
            lastMid = { x: mx, y: my }; lastPt = { x: x, y: y };
          }

          function eraseHit(x, y) {
            var r = 18, changed = false;
            for (var i = strokes.length - 1; i >= 0; i--) {
              var pts = strokes[i].pts;
              for (var j = 0; j < pts.length; j++) {
                var pv = toView(pts[j][0], pts[j][1]);
                if ((pv.x - x) * (pv.x - x) + (pv.y - y) * (pv.y - y) <= r * r) { strokes.splice(i, 1); changed = true; break; }
              }
            }
            if (changed) drawInk();
          }

          // ---- 指针：笔=画/翻页，手指=滚动 ----
          var activeId = null, touchId = null, lastTouchY = 0, penSeen = false, batch = [], pageDragX = 0;

          ink.addEventListener("pointerdown", function (e) {
            if (e.pointerType === "touch") {
              if (activeId !== null) { e.preventDefault(); return; }   // 笔在写 → 忽略手掌
              touchId = e.pointerId; lastTouchY = e.clientY; e.preventDefault(); return;
            }
            penSeen = true;
            var m = curMode();
            if (m === "page") {
              activeId = e.pointerId; try { ink.setPointerCapture(e.pointerId); } catch (x) {}
              pageDragX = e.clientX; clearHover(); e.preventDefault(); return;
            }
            if (!inPage(e.clientX, e.clientY)) return;
            activeId = e.pointerId; try { ink.setPointerCapture(e.pointerId); } catch (x) {}
            clearHover();
            var n = toNorm(e.clientX, e.clientY);
            if (m === "note") {
              cur = { pen: { color: curPen().color, w: curPen().w }, pts: [[n[0], n[1], e.pressure]] };
              liveBegin(e.clientX, e.clientY, e.pressure, cur.pen);
              send({ type: "ink", phase: "begin", page: pageIndex, pen: cur.pen, pts: [[n[0], n[1], e.pressure]] });
            } else if (m === "erase") {
              eraseHit(e.clientX, e.clientY); batch.push([n[0], n[1]]);
            }
            e.preventDefault();
          }, { passive: false });

          ink.addEventListener("pointermove", function (e) {
            if (e.pointerId === touchId) {
              scrollY = Math.min(Math.max(0, scrollY + (lastTouchY - e.clientY)), maxScroll);
              lastTouchY = e.clientY; drawAll(); e.preventDefault(); return;
            }
            if (e.pointerId !== activeId) {
              if (e.pointerType !== "touch" && e.buttons === 0 && curMode() !== "page" && inPage(e.clientX, e.clientY))
                drawHover(e.clientX, e.clientY);
              return;
            }
            var m = curMode();
            if (m === "page") { e.preventDefault(); return; }
            var evs = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
            if (!evs.length) evs = [e];
            for (var i = 0; i < evs.length; i++) {
              var ev = evs[i], n = toNorm(ev.clientX, ev.clientY);
              if (m === "note") { liveTo(ev.clientX, ev.clientY, ev.pressure, cur.pen); cur.pts.push([n[0], n[1], ev.pressure]); batch.push([n[0], n[1], ev.pressure]); }
              else if (m === "erase") { eraseHit(ev.clientX, ev.clientY); batch.push([n[0], n[1]]); }
            }
            e.preventDefault();
          }, { passive: false });

          function endPointer(e) {
            if (e.pointerId === touchId) { touchId = null; return; }
            if (e.pointerId !== activeId) return;
            var m = curMode();
            if (m === "page") {
              var dx = e.clientX - pageDragX;
              if (Math.abs(dx) > 60) turn(dx < 0 ? "next" : "prev");
              activeId = null; return;
            }
            if (m === "note") { if (cur) { strokes.push(cur); cur = null; } flushBatch("ink"); send({ type: "ink", phase: "end" }); }
            else if (m === "erase") { flushBatch("erase"); send({ type: "erase", phase: "end" }); }
            activeId = null; lastPt = null; lastMid = null;
          }
          ink.addEventListener("pointerup", endPointer);
          ink.addEventListener("pointercancel", endPointer);
          ink.addEventListener("pointerleave", function (e) { if (e.pointerType !== "touch") clearHover(); });

          function flushBatch(kind) {
            if (!batch.length) return;
            send({ type: kind, phase: "move", pts: batch });
            batch = [];
          }
          function tick() { if (activeId !== null && batch.length) flushBatch(curMode() === "erase" ? "erase" : "ink"); requestAnimationFrame(tick); }
          requestAnimationFrame(tick);

          // ---- 悬停 ----
          function drawHover(x, y) {
            var r = curMode() === "erase" ? 18 : 10;
            hctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
            hctx.beginPath(); hctx.arc(x, y, r, 0, Math.PI * 2);
            hctx.strokeStyle = curMode() === "erase" ? "#f0883e" : "#58a6ff"; hctx.lineWidth = 2; hctx.stroke();
          }
          function clearHover() { hctx.clearRect(0, 0, window.innerWidth, window.innerHeight); }

          function updateHud() {
            var m = MODES[modeIdx];
            el("mode").textContent = m.label + (m.key === "note" ? " · " + curPen().name : "");
            el("swatch").style.background = m.key === "note" ? curPen().color : "transparent";
            el("swatch").style.borderColor = m.key === "note" ? curPen().color : "#484f58";
          }
          function cycleMode() { modeIdx = (modeIdx + 1) % MODES.length; activeId = null; clearHover(); updateHud(); send({ type: "mode", mode: curMode() }); }
          function cyclePen() { penIdx = (penIdx + 1) % PENS.length; modeIdx = 0; updateHud(); }
          window.addEventListener("keydown", function (e) {
            if (e.repeat) return;
            if (e.key === "PageUp") { e.preventDefault(); cycleMode(); }
            else if (e.key === "PageDown") { e.preventDefault(); cyclePen(); }
          });

          // ---- 全屏 ----
          el("full").addEventListener("click", function () {
            if (!document.fullscreenElement) {
              var root = document.documentElement;
              var req = root.requestFullscreen || root.webkitRequestFullscreen;
              if (req) Promise.resolve(req.call(root)).then(function () {
                if (screen.orientation && screen.orientation.lock) screen.orientation.lock("landscape").catch(function () {});
              }).catch(function () {});
            } else {
              (document.exitFullscreen || document.webkitExitFullscreen).call(document);
            }
          });

          // ---- WebSocket ----
          var ws, pingTimer = null;
          function send(o) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); }
          function connect() {
            ws = new WebSocket("ws://" + location.hostname + ":" + PORT + "/");
            ws.onopen = function () { ws.send(JSON.stringify({ type: "auth", token: TOKEN })); };
            ws.onmessage = function (e) { try { onMsg(JSON.parse(e.data)); } catch (x) {} };
            ws.onclose = function () {
              el("dot").className = "";
              if (pingTimer) { clearInterval(pingTimer); pingTimer = null; }
              setTimeout(connect, 1500);
            };
          }
          function startPing() {
            if (pingTimer) return;
            pingTimer = setInterval(function () { send({ type: "ping", t: Date.now() }); }, 2000);
            send({ type: "ping", t: Date.now() });
          }
          function onMsg(o) {
            if (o.type === "authOK") { el("dot").className = "on"; startPing(); }
            else if (o.type === "pong") { var rtt = Date.now() - (o.t || 0); el("lat").textContent = rtt + " ms"; send({ type: "latency", ms: rtt }); }
            else if (o.type === "page") { setPage(o); }
            else if (o.type === "docs") { setDocs(o); }
          }
          function setPage(o) {
            pageIndex = o.index || 0; pageCount = o.count || 0;
            pageW = o.w || 1; pageH = o.h || 1.4142;
            el("pageLabel").textContent = pageCount ? (pageIndex + 1) + " / " + pageCount : "— / —";
            strokes = []; cur = null; scrollY = 0;
            if (o.count) pageImg.src = "/page.png?token=" + TOKEN + "&v=" + (o.v || 0);
            layout();
          }
          function setDocs(o) {
            var sel = el("docs"); sel.innerHTML = "";
            var f = document.createElement("option"); f.value = ""; f.textContent = "⟳ 跟随 Mac"; sel.appendChild(f);
            (o.list || []).forEach(function (d) {
              var op = document.createElement("option"); op.value = d.id; op.textContent = d.title; sel.appendChild(op);
            });
            sel.value = o.following ? "" : (o.selected || "");
          }
          function turn(dir) { send({ type: "pageTurn", dir: dir }); }
          el("prev").onclick = function () { turn("prev"); };
          el("next").onclick = function () { turn("next"); };
          el("docs").addEventListener("change", function () { send({ type: "selectDoc", id: el("docs").value }); });
          window.addEventListener("contextmenu", function (e) { e.preventDefault(); });

          updateHud(); layout(); connect();
        })();
        </script>
        </body>
        </html>
        """
    }
}
