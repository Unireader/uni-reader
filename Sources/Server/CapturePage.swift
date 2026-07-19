import Foundation

/// 平板采集端网页 v6（方案 B：连续多页 + 双向锚点同步 + 双指缩放）：
/// - 收 `layout`（每页原始宽高）→ 本地组 **连续页面列**；`zoom` 控制页宽（fit-width 为 zoom=1），
///   放大可横向拖动、缩小页面居中；页图按需 `/page.png?i=N&v=` 取并缓存。
/// - 手指：**单指拖动平移**（含横向），**双指捏合缩放**（以捏合中点为锚点）。
/// - 笔：笔记=落墨，擦除=抹除，**翻页模式=笔拖动平移画面**（不再左右滑切页）。
/// - 纵向滚动 → 上报 `scroll`（页+页内比例）→ Mac 跟随；收 `viewport` → 程序化滚到同位置。
///   横向平移/缩放是平板本地查看，不上报（Mac 只同步纵向文档位置）。
/// - 手写用**跨页归一化页面坐标**（页内 0~1 + page）；PageUp 切模式、PageDown 切笔；右上角全屏。
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
          #docs { max-width:24vw; padding:6px 8px; border:1px solid #30363d; border-radius:8px;
            background:#21262d; color:#e6edf3; font-size:14px; }
          #zoomLabel { color:#8b949e; font-variant-numeric:tabular-nums; font-size:13px; white-space:nowrap; }
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
          <span id="zoomLabel">100%</span>
          <span id="pageLabel">— / —</span>
          <button id="prev">‹</button>
          <button id="next">›</button>
          <button id="lock" title="锁定缩放">🔓</button>
          <button id="full">⛶</button>
        </div>
        <script>
        (function () {
          var PORT = \(wsPort), TOKEN = "\(token)";
          var BAR = 46, GAP = 8, MINZ = 0.5, MAXZ = 5;
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
          function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

          // ---- 文档布局（连续页面列 + 缩放）----
          var docV = "", pageCount = 0, pagesWH = [];   // pagesWH: [[w,h],...] 原始点尺寸
          var vw = 1, availH = 1, dispH = [], offY = [], totalH = 0;
          var zoom = 1, scrollX = 0, scrollY = 0, maxScrollX = 0, maxScrollY = 0;
          var imgs = {};        // i -> Image（按需加载 + 缓存）
          var vpSeq = 0;        // 已应用的 Mac viewport 序号

          function pw() { return vw * zoom; }                                   // 页(内容)宽
          function contentLeft() { var p = pw(); return p <= vw ? (vw - p) / 2 : -scrollX; }  // 内容左缘视口 x

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

          // 只重算几何（不动 canvas 尺寸），供缩放时保持锚点用。
          function recompute() {
            vw = window.innerWidth;
            availH = window.innerHeight - BAR;
            var p = pw(), y = 0; dispH = []; offY = [];
            for (var i = 0; i < pageCount; i++) {
              var w = (pagesWH[i] && pagesWH[i][0]) || 1, h = (pagesWH[i] && pagesWH[i][1]) || 1.4142;
              var dh = w > 0 ? p * h / w : p;
              offY[i] = y; dispH[i] = dh; y += dh + GAP;
            }
            totalH = Math.max(0, y - GAP);
            maxScrollY = Math.max(0, totalH - availH);
            maxScrollX = Math.max(0, p - vw);
          }
          function relayout() {
            DPR = Math.max(1, window.devicePixelRatio || 1);
            sizeCanvas(bg, bctx); sizeCanvas(ink, ictx); sizeCanvas(hover, hctx);
            recompute();
            scrollX = clamp(scrollX, 0, maxScrollX); scrollY = clamp(scrollY, 0, maxScrollY);
            ensureImages(); drawAll(); updateHud();
          }
          window.addEventListener("resize", relayout);

          // ---- 按需取图（可见 + 上下各一屏预取）----
          function ensureImages() {
            if (!pageCount) return;
            var top = scrollY - availH, bot = scrollY + availH * 2;
            for (var i = 0; i < pageCount; i++) {
              if (offY[i] + dispH[i] >= top && offY[i] <= bot) loadImg(i);
            }
          }
          function loadImg(i) {
            if (imgs[i]) return;
            var im = new Image();
            im.onload = function () { drawBg(); };
            im.src = "/page.png?i=" + i + "&v=" + encodeURIComponent(docV);
            imgs[i] = im;
          }

          // ---- 坐标映射（跨页 + 缩放）----
          function locate(x, vy) {
            var cl = contentLeft(), p = pw();
            var docY = vy - BAR + scrollY;
            for (var i = 0; i < pageCount; i++) {
              if (docY >= offY[i] && docY <= offY[i] + dispH[i]) {
                return { page: i, nx: clamp((x - cl) / p, 0, 1), ny: clamp((docY - offY[i]) / dispH[i], 0, 1) };
              }
            }
            return null;
          }
          function pageToView(page, nx, ny) {
            if (page < 0 || page >= pageCount) return { x: 0, y: -1e6 };
            var docY = offY[page] + ny * dispH[page];
            return { x: contentLeft() + nx * pw(), y: BAR + docY - scrollY };
          }
          function inContent(x, y) { return y >= BAR && locate(x, y) !== null; }

          // ---- 绘制 ----
          function drawAll() { drawBg(); drawInk(); }
          function drawBg() {
            bctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
            var cl = contentLeft(), p = pw();
            for (var i = 0; i < pageCount; i++) {
              var vy = BAR + offY[i] - scrollY;
              if (vy + dispH[i] < BAR || vy > window.innerHeight) continue;
              bctx.fillStyle = "#fff"; bctx.fillRect(cl, vy, p, dispH[i]);
              var im = imgs[i];
              if (im && im.complete && im.naturalWidth) bctx.drawImage(im, cl, vy, p, dispH[i]);
              else { bctx.fillStyle = "#e9edf2"; bctx.fillRect(cl, vy, p, dispH[i]); loadImg(i); }
            }
          }
          function drawStroke(s) {
            var pts = s.pts; if (!pts.length) return;
            var p0 = pageToView(s.page, pts[0][0], pts[0][1]);
            ictx.fillStyle = s.pen.color;
            ictx.beginPath(); ictx.arc(p0.x, p0.y, (0.6 + pts[0][2] * s.pen.w) / 2, 0, Math.PI * 2); ictx.fill();
            var lastMid = p0, lastPt = p0;
            for (var i = 1; i < pts.length; i++) {
              var pv = pageToView(s.page, pts[i][0], pts[i][1]), pr = pts[i][2];
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

          // 实时增量落墨（视口坐标；一笔期间不缩放/不被程序滚动，故与存储一致）
          var strokes = [], cur = null;
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
                var pv = pageToView(strokes[i].page, pts[j][0], pts[j][1]);
                if ((pv.x - x) * (pv.x - x) + (pv.y - y) * (pv.y - y) <= r * r) { strokes.splice(i, 1); changed = true; break; }
              }
            }
            if (changed) drawInk();
          }

          // ---- 平移 / 缩放 / 纵向锚点 ----
          function panBy(dx, dy) {
            scrollX = clamp(scrollX + dx, 0, maxScrollX);
            scrollY = clamp(scrollY + dy, 0, maxScrollY);
            ensureImages(); drawAll(); updatePageLabel(); emitScroll();
          }
          var reportPending = false;
          function emitScroll() {
            if (reportPending) return; reportPending = true;
            requestAnimationFrame(function () {
              reportPending = false;
              var docY = scrollY;
              for (var i = 0; i < pageCount; i++) {
                if (docY <= offY[i] + dispH[i] + GAP) {
                  send({ type: "scroll", page: i, frac: clamp((docY - offY[i]) / Math.max(1, dispH[i]), 0, 1) });
                  return;
                }
              }
            });
          }
          function topVisiblePage() {
            for (var i = 0; i < pageCount; i++) if (scrollY <= offY[i] + dispH[i] + GAP) return i;
            return Math.max(0, pageCount - 1);
          }
          function updatePageLabel() {
            el("pageLabel").textContent = pageCount ? (topVisiblePage() + 1) + " / " + pageCount : "— / —";
          }
          function updateHud() {
            var m = MODES[modeIdx];
            el("mode").textContent = m.label + (m.key === "note" ? " · " + curPen().name : "");
            el("swatch").style.background = m.key === "note" ? curPen().color : "transparent";
            el("swatch").style.borderColor = m.key === "note" ? curPen().color : "#484f58";
            el("zoomLabel").textContent = Math.round(zoom * 100) + "%";
            updatePageLabel();
          }
          // 收到 Mac 视口 → 程序化滚到该(页,纵向比例)，不回发。
          function applyViewport(o) {
            if (activeId !== null) return;              // 正在写，忽略
            if ((o.seq || 0) <= vpSeq) return; vpSeq = o.seq || 0;
            var p = o.page || 0, f = o.frac || 0;
            if (p >= pageCount) return;
            scrollY = clamp(offY[p] + f * dispH[p], 0, maxScrollY);
            ensureImages(); drawAll(); updatePageLabel();
          }

          // ---- 指针：笔=画/平移，手指=平移/双指缩放 ----
          var activeId = null, penMode = "", penX = 0, penY = 0, batch = [], drawPage = 0;
          var touches = {}, touchOrder = [], panId = null, lastPanX = 0, lastPanY = 0, pinch = null;
          var zoomLocked = false;
          var panDownX = 0, panDownY = 0, panStarted = false;   // 单指平移死区
          var PALM = 60, DEAD = 8;                                // 手掌接触阈值(px)、平移死区(px)

          function beginPinch() {
            var a = touches[touchOrder[0]], b = touches[touchOrder[1]];
            var mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, p = pw();
            pinch = {
              d0: Math.max(40, Math.hypot(a.x - b.x, a.y - b.y)),   // 初始间距下限，避免起手两指过近灵敏度爆炸
              z0: zoom,
              fx: p > 0 ? (mx - contentLeft()) / p : 0.5,            // 捏合中点抓住的内容比例（固定锚点）
              fy: totalH > 0 ? (my - BAR + scrollY) / totalH : 0
            };
            panId = null; panStarted = false;
          }

          ink.addEventListener("pointerdown", function (e) {
            if (e.pointerType === "touch") {
              if (activeId !== null) { e.preventDefault(); return; }   // 笔在写 → 忽略手掌
              if (e.width > PALM || e.height > PALM) { e.preventDefault(); return; }   // 大面积接触（手掌）忽略
              touches[e.pointerId] = { x: e.clientX, y: e.clientY };
              if (touchOrder.indexOf(e.pointerId) < 0) touchOrder.push(e.pointerId);
              if (touchOrder.length >= 2) beginPinch();
              else {
                panId = e.pointerId; lastPanX = e.clientX; lastPanY = e.clientY;
                panDownX = e.clientX; panDownY = e.clientY; panStarted = false;
              }
              e.preventDefault(); return;
            }
            // 笔
            var m = curMode();
            if (m === "page") {   // 翻页模式：笔拖动平移画面
              activeId = e.pointerId; penMode = "page";
              try { ink.setPointerCapture(e.pointerId); } catch (x) {}
              penX = e.clientX; penY = e.clientY; endHover(); e.preventDefault(); return;
            }
            var loc = locate(e.clientX, e.clientY);
            if (!loc) return;
            activeId = e.pointerId; penMode = m;
            try { ink.setPointerCapture(e.pointerId); } catch (x) {}
            endHover();
            if (m === "note") {
              drawPage = loc.page;
              cur = { page: loc.page, pen: { color: curPen().color, w: curPen().w }, pts: [[loc.nx, loc.ny, e.pressure]] };
              liveBegin(e.clientX, e.clientY, e.pressure, cur.pen);
              send({ type: "ink", phase: "begin", page: loc.page, pen: cur.pen, pts: [[loc.nx, loc.ny, e.pressure]] });
            } else if (m === "erase") {
              eraseHit(e.clientX, e.clientY); batch.push([loc.nx, loc.ny]);
            }
            e.preventDefault();
          }, { passive: false });

          ink.addEventListener("pointermove", function (e) {
            if (e.pointerType === "touch") {
              if (!(e.pointerId in touches)) return;
              touches[e.pointerId] = { x: e.clientX, y: e.clientY };
              if (pinch && touchOrder.length >= 2) {
                var a = touches[touchOrder[0]], b = touches[touchOrder[1]];
                var d = Math.hypot(a.x - b.x, a.y - b.y);
                var mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
                if (!zoomLocked) zoom = clamp(pinch.z0 * d / pinch.d0, MINZ, MAXZ);
                recompute();
                // 固定锚点比例始终跟随当前中点 → 缩放与双指整体移动都跟手、不漂移
                scrollY = clamp(pinch.fy * totalH - (my - BAR), 0, maxScrollY);
                scrollX = pw() > vw ? clamp(pinch.fx * pw() - mx, 0, maxScrollX) : 0;
                ensureImages(); drawAll(); updateHud(); emitScroll();
              } else if (e.pointerId === panId) {
                if (!panStarted) {
                  if (Math.hypot(e.clientX - panDownX, e.clientY - panDownY) < DEAD) { e.preventDefault(); return; }
                  panStarted = true; lastPanX = e.clientX; lastPanY = e.clientY;   // 越过死区才开始，避免"手放上去"微动触发
                }
                panBy(lastPanX - e.clientX, lastPanY - e.clientY);
                lastPanX = e.clientX; lastPanY = e.clientY;
              }
              e.preventDefault(); return;
            }
            // 笔
            if (e.pointerId !== activeId) {
              if (e.buttons === 0 && curMode() !== "page" && inContent(e.clientX, e.clientY)) {
                drawHover(e.clientX, e.clientY);
                var hl = locate(e.clientX, e.clientY);
                if (hl) reportHover(hl.page, hl.nx, hl.ny);
              } else if (e.buttons === 0) endHover();
              return;
            }
            if (penMode === "page") {   // 笔拖动平移
              panBy(penX - e.clientX, penY - e.clientY);
              penX = e.clientX; penY = e.clientY; e.preventDefault(); return;
            }
            var evs = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
            if (!evs.length) evs = [e];
            for (var i = 0; i < evs.length; i++) {
              var ev = evs[i], loc = locate(ev.clientX, ev.clientY);
              if (penMode === "note") {
                liveTo(ev.clientX, ev.clientY, ev.pressure, cur.pen);
                var nx = loc ? loc.nx : clamp((ev.clientX - contentLeft()) / pw(), 0, 1);
                var ny = loc && loc.page === drawPage ? loc.ny
                       : clamp((ev.clientY - BAR + scrollY - offY[drawPage]) / Math.max(1, dispH[drawPage]), 0, 1);
                cur.pts.push([nx, ny, ev.pressure]); batch.push([nx, ny, ev.pressure]);
              } else if (penMode === "erase") {
                eraseHit(ev.clientX, ev.clientY);
                if (loc) batch.push([loc.nx, loc.ny]);
              }
            }
            e.preventDefault();
          }, { passive: false });

          function endTouch(id) {
            if (!(id in touches)) return;
            delete touches[id];
            var k = touchOrder.indexOf(id); if (k >= 0) touchOrder.splice(k, 1);
            pinch = null;
            if (touchOrder.length === 1) {   // 回到单指平移（重新死区判定，避免松指跳动）
              panId = touchOrder[0]; var t = touches[panId];
              lastPanX = t.x; lastPanY = t.y; panDownX = t.x; panDownY = t.y; panStarted = false;
            } else if (touchOrder.length === 0) {
              panId = null;
            } else if (touchOrder.length >= 2) {
              beginPinch();
            }
          }
          function endPen(e) {
            if (e.pointerId !== activeId) return;
            if (penMode === "note") { if (cur) { strokes.push(cur); cur = null; } flushBatch("ink"); send({ type: "ink", phase: "end" }); }
            else if (penMode === "erase") { flushBatch("erase"); send({ type: "erase", phase: "end" }); }
            activeId = null; penMode = ""; lastPt = null; lastMid = null;
          }
          function onUp(e) { if (e.pointerType === "touch") endTouch(e.pointerId); else endPen(e); }
          ink.addEventListener("pointerup", onUp);
          ink.addEventListener("pointercancel", onUp);
          ink.addEventListener("pointerleave", function (e) { if (e.pointerType !== "touch") endHover(); });

          function flushBatch(kind) {
            if (!batch.length) return;
            send({ type: kind, phase: "move", pts: batch });
            batch = [];
          }
          function tick() { if (activeId !== null && batch.length) flushBatch(penMode === "erase" ? "erase" : "ink"); requestAnimationFrame(tick); }
          requestAnimationFrame(tick);

          // ---- 悬停 ----
          function drawHover(x, y) {
            var r = curMode() === "erase" ? 18 : 10;
            hctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
            hctx.beginPath(); hctx.arc(x, y, r, 0, Math.PI * 2);
            hctx.strokeStyle = curMode() === "erase" ? "#f0883e" : "#58a6ff"; hctx.lineWidth = 2; hctx.stroke();
          }
          function clearHover() { hctx.clearRect(0, 0, window.innerWidth, window.innerHeight); }
          // 悬停上报 Mac（rAF 节流）；endHover 清本地圆环并通知 Mac 隐藏。
          var hoverPending = false, hoverMsg = null, hoverOn = false;
          function reportHover(page, nx, ny) {
            hoverOn = true; hoverMsg = { type: "hover", page: page, nx: nx, ny: ny };
            if (hoverPending) return; hoverPending = true;
            requestAnimationFrame(function () { hoverPending = false; if (hoverMsg) { send(hoverMsg); hoverMsg = null; } });
          }
          function endHover() { if (!hoverOn) return; hoverOn = false; clearHover(); send({ type: "hover", phase: "end" }); }

          function cycleMode() { modeIdx = (modeIdx + 1) % MODES.length; activeId = null; penMode = ""; endHover(); updateHud(); send({ type: "mode", mode: curMode() }); }
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
            else if (o.type === "layout") { setLayout(o); }
            else if (o.type === "viewport") { applyViewport(o); }
            else if (o.type === "docs") { setDocs(o); }
            // 旧 `page` 消息在方案 B 下忽略（布局改由 layout 驱动）。
          }
          function setLayout(o) {
            var v = (o.v || o.docId || "");
            var changed = v !== docV;
            docV = v; pageCount = o.count || 0; pagesWH = o.pages || [];
            if (changed) { strokes = []; cur = null; imgs = {}; scrollX = 0; scrollY = 0; zoom = 1; vpSeq = 0; }
            relayout();
          }
          function setDocs(o) {
            var sel = el("docs"); sel.innerHTML = "";
            var f = document.createElement("option"); f.value = ""; f.textContent = "⟳ 跟随 Mac"; sel.appendChild(f);
            (o.list || []).forEach(function (d) {
              var op = document.createElement("option"); op.value = d.id; op.textContent = d.title; sel.appendChild(op);
            });
            sel.value = o.following ? "" : (o.selected || "");
          }
          // 翻页按钮：滚到相邻页顶部（并上报，Mac 跟随）。
          function turn(dir) {
            var i = clamp(topVisiblePage() + (dir === "prev" ? -1 : 1), 0, Math.max(0, pageCount - 1));
            scrollY = clamp(offY[i], 0, maxScrollY);
            ensureImages(); drawAll(); updatePageLabel(); emitScroll();
          }
          el("prev").onclick = function () { turn("prev"); };
          el("next").onclick = function () { turn("next"); };
          el("lock").onclick = function () { zoomLocked = !zoomLocked; el("lock").textContent = zoomLocked ? "🔒" : "🔓"; };
          el("docs").addEventListener("change", function () { send({ type: "selectDoc", id: el("docs").value }); });
          window.addEventListener("contextmenu", function (e) { e.preventDefault(); });

          updateHud(); relayout(); connect();
        })();
        </script>
        </body>
        </html>
        """
    }
}
