// WebSocket 模块：二进制线格式收发、自动重连（1.5s 起步翻倍封顶 10s）、心跳看门狗、
// Mac 下行消息分发（布局/视口/文档/笔/模式/环形盘/笔迹）。逐行移植自原 capture.html IIFE。
import { G, MODES, clamp, pw, curMode } from "./shared.js";
import { S, updateHud, updatePageLabel, recordRtt } from "./hud.svelte.js";
import { Wire } from "./wire.js";

export function initWs() {
  function send(o) { if (G.ws && G.ws.readyState === 1) { const b = Wire.encode(o); if (b) { G.ws.send(b); G.upCount++; } } }

  function connect() {
    if (G.ws && (G.ws.readyState === 0 || G.ws.readyState === 1)) return;   // 已有活连接/正在连，不重复建
    if (G.retryTimer) { clearTimeout(G.retryTimer); G.retryTimer = null; }
    G.ws = new WebSocket("ws://" + location.hostname + ":" + G.PORT + "/");
    G.ws.binaryType = "arraybuffer";
    G.ws.onopen = function () { G.ws.send(Wire.encode({ type: "auth", token: G.TOKEN })); };
    G.ws.onmessage = function (e) { const o = Wire.decode(e.data); if (o) { try { onMsg(o); } catch (x) {} } };
    G.ws.onerror = function () { try { G.ws.close(); } catch (x) {} };   // 出错统一走 onclose → 重连
    G.ws.onclose = function () {
      if (this !== G.ws) return;   // 旧实例的迟到事件，别清掉新连接的状态
      S.connected = false;
      G.radialActive = false; G.setRadial(null); G.setPressRing(null);   // 断线时盘/环正开着 → 收掉（Mac 不会补发瞬态状态）
      if (G.pingTimer) { clearInterval(G.pingTimer); G.pingTimer = null; }
      scheduleRetry();
    };
  }
  // 自动重连：1.5s 起步、翻倍退避封顶 10s；authOK 后重置。重连后 Mac 会补发全量状态（文档/页面/笔迹）。
  function scheduleRetry() {
    if (G.retryTimer) return;
    G.retryTimer = setTimeout(function () { G.retryTimer = null; connect(); }, G.retryDelay);
    G.retryDelay = Math.min(G.retryDelay * 2, 10000);
  }
  function startPing() {
    if (G.pingTimer) return;
    G.lastPong = Date.now(); G.retryDelay = 1500;
    G.pingTimer = setInterval(function () {
      // 看门狗：半开连接（锁屏/切网/Mac 睡眠后 onclose 迟迟不触发）5s 无 pong 即杀掉重连
      if (Date.now() - G.lastPong > 5000) { try { G.ws.close(); } catch (x) {} scheduleRetry(); return; }
      send({ type: "ping", t: Date.now() });
    }, 1000);
    send({ type: "ping", t: Date.now() });
  }

  function onMsg(o) {
    G.downCount++;
    if (o.type === "authOK") {
      S.connected = true; startPing();
      send({ type: "mode", mode: curMode() }); send({ type: "pen", index: G.penIdx });   // 连接即同步当前工具状态给 Mac
      G.lastGeomW = -1; emitGeom();   // 重连后 Mac 那边的页宽是空的，无条件补一发
    }
    else if (o.type === "pong") { G.lastPong = Date.now(); const rtt = Date.now() - (o.t || 0); recordRtt(rtt); send({ type: "latency", ms: rtt }); }
    else if (o.type === "layout") { setLayout(o); }
    else if (o.type === "viewport") { applyViewport(o); }
    else if (o.type === "docs") { setDocs(o); }
    // 收藏笔列表整体同步（画布悬浮工具条实时增删改后，Mac 推下来）：替换本地 PENS + 当前下标。
    else if (o.type === "pens") {
      G.PENS = (o.list || []).map(function (p) { return { color: p.color, w: p.w, t: p.t }; });
      if (!G.PENS.length) G.PENS = [{ color: "rgba(24,90,210,0.95)", w: 8, t: "ballpoint" }];
      G.penIdx = clamp(o.active || 0, 0, G.PENS.length - 1);
      updateHud();
    }
    else if (o.type === "pen") {
      const i = o.index || 0;
      if (i >= 0 && i < G.PENS.length) { G.penIdx = i; updateHud(); }
    }
    // Mac 侧切模式（悬浮工具条/环形盘选笔后回 note）：同步本地模式
    else if (o.type === "mode") {
      for (let mi = 0; mi < MODES.length; mi++) {
        if (MODES[mi].key === o.mode && mi !== G.modeIdx) { G.modeIdx = mi; updateHud(); break; }
      }
    }
    // Mac 检测到长按 → 把当前这半笔转成环形选笔盘：本地撤掉半笔、后续笔移不再画（只发位置驱动选笔）。
    else if (o.type === "inkCancel") { G.radialActive = true; G.cur = null; G.drawLive(); }
    // 环形选笔盘状态镜像（Mac 是唯一判定方）：照着画即可，open=false 收盘。
    else if (o.type === "radial") { G.setRadial(o); }
    // 长按进度环（盘的前置动画）：同样是 Mac 判定，on=false 撤环。
    else if (o.type === "pressRing") { G.setPressRing(o); }
    // Mac 回传的全部笔迹（唯一真源）：平板据此显示 + 刷新/重连/切档后恢复。正在写的这一笔(cur)不清，避免闪断。
    else if (o.type === "strokes") { G.strokes = o.list || []; if (G.activeId === null) { G.cur = null; G.drawLive(); } G.drawInk(); }
    // 旧 `page` 消息在方案 B 下忽略（布局改由 layout 驱动）。
  }

  function setLayout(o) {
    const v = (o.v || o.docId || "");
    const changed = v !== G.docV;
    G.docV = v; G.pageCount = o.count || 0; G.pagesWH = o.pages || [];
    if (changed) { G.strokes = []; G.cur = null; G.imgs = {}; G.scrollX = 0; G.scrollY = 0; G.zoom = 1; G.vpSeq = 0; }
    G.relayout();
  }
  function setDocs(o) {
    S.docs = o.list || [];
    S.docValue = o.following ? "" : (o.selected || "");
  }

  // 收到 Mac 视口 → 程序化滚到该(页,纵向比例)，不回发。
  // force=1（新连接/切文档后的初始进度同步）绕过 seq 去重——该锚点的 seq 可能早就用过。
  function applyViewport(o) {
    if (G.activeId !== null) return;              // 正在写，忽略
    G.cancelMomentum();                           // Mac 下发视口 → 停止本地惯性，避免抢位
    if (!o.force) {
      if ((o.seq || 0) <= G.vpSeq) return; G.vpSeq = o.seq || 0;
    }
    const p = o.page || 0, f = o.frac || 0;
    if (p >= G.pageCount) return;
    G.scrollY = clamp(G.offY[p] + f * G.dispH[p], 0, G.maxScrollY);
    G.ensureImages(); G.drawAll(); updatePageLabel();
  }

  // 平板页宽上报：Mac 侧的取消区半径/长按位移阈值都是**平板屏幕上的**尺度，得知道平板页宽才能换算。
  // 值变了才发（缩放/旋转/换文档），静止时零流量。
  function emitGeom() {
    const w = pw();
    if (Math.abs(w - G.lastGeomW) < 0.5) return;
    G.lastGeomW = w; send({ type: "padGeom", pageW: w });
  }

  // 回前台/网络恢复：立即检查连接，断了马上重连（不等退避计时器）；假活（5s 无 pong）杀掉重连。
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) return;
    if (!G.ws || G.ws.readyState > 1) connect();
    else if (G.ws.readyState === 1 && Date.now() - G.lastPong > 5000) { try { G.ws.close(); } catch (x) {} scheduleRetry(); }
  });
  window.addEventListener("online", function () { connect(); });

  // 跨模块调用面
  Object.assign(G, { send, connect, emitGeom, applyViewport });
}
