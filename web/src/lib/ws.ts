// WebSocket 模块：二进制线格式收发、自动重连（1.5s 起步翻倍封顶 10s）、心跳看门狗、
// Mac 下行消息分发（布局/视口/文档/笔/模式/环形盘/笔迹）。逐行移植自原 capture.html IIFE。
import { G, BAR, MODES, clamp, pw, curMode } from "./shared.js";
import type { Layer, Pen, WireMsg } from "./shared.js";
import { S, updateHud, updatePageLabel, recordRtt } from "./hud.svelte.js";
import type { BookmarkEntry, LibEntry, TocEntry } from "./hud.svelte.js";
import { Wire } from "./wire.js";

export function initWs(): void {
  function send(o: WireMsg): void { if (G.ws && G.ws.readyState === 1) { const b = Wire.encode(o); if (b) { G.ws.send(b); G.upCount++; } } }

  function connect(): void {
    if (G.ws && (G.ws.readyState === 0 || G.ws.readyState === 1)) return;   // 已有活连接/正在连，不重复建
    if (G.retryTimer) { clearTimeout(G.retryTimer); G.retryTimer = null; }
    G.ws = new WebSocket("ws://" + location.hostname + ":" + G.PORT + "/");
    G.ws.binaryType = "arraybuffer";
    G.ws.onopen = function () { G.ws!.send(Wire.encode({ type: "auth", token: G.TOKEN })!); };
    G.ws.onmessage = function (e: MessageEvent) { const o = Wire.decode(e.data) as WireMsg | null; if (o) { try { onMsg(o); } catch (x) {} } };
    G.ws.onerror = function () { try { G.ws!.close(); } catch (x) {} };   // 出错统一走 onclose → 重连
    G.ws.onclose = function (this: WebSocket) {
      if (this !== G.ws) return;   // 旧实例的迟到事件，别清掉新连接的状态
      S.connected = false;
      G.radialActive = false; G.setRadial(null); G.setPressRing(null);   // 断线时盘/环正开着 → 收掉（Mac 不会补发瞬态状态）
      if (G.pingTimer) { clearInterval(G.pingTimer); G.pingTimer = null; }
      scheduleRetry();
    };
  }
  // 自动重连：1.5s 起步、翻倍退避封顶 10s；authOK 后重置。重连后 Mac 会补发全量状态（文档/页面/笔迹）。
  function scheduleRetry(): void {
    if (G.retryTimer) return;
    G.retryTimer = setTimeout(function () { G.retryTimer = null; connect(); }, G.retryDelay);
    G.retryDelay = Math.min(G.retryDelay * 2, 10000);
  }
  function startPing(): void {
    if (G.pingTimer) return;
    G.lastPong = Date.now(); G.retryDelay = 1500;
    G.pingTimer = setInterval(function () {
      // 看门狗：半开连接（锁屏/切网/Mac 睡眠后 onclose 迟迟不触发）5s 无 pong 即杀掉重连
      if (Date.now() - G.lastPong > 5000) { try { G.ws!.close(); } catch (x) {} scheduleRetry(); return; }
      send({ type: "ping", t: Date.now() });
    }, 1000);
    send({ type: "ping", t: Date.now() });
  }

  function onMsg(o: WireMsg): void {
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
    // 工作区书库（含 Mac 尚未打开的文档）：抽屉「书库」页据此列出，点未打开的发 openDoc。
    else if (o.type === "library") { S.libraryWs = o.ws || ""; S.library = (o.list || []) as LibEntry[]; }
    // PDF 目录：**带 docId（内容哈希）**，渲染前必须与当前 layout 的 docV 核对——切档瞬间
    // 两条广播的先后没有保证，不核对就会把上一本的目录挂到新书上。
    else if (o.type === "toc") { S.tocDocId = o.docId || ""; S.toc = (o.list || []) as TocEntry[]; }
    // 书签全量镜像（Mac 唯一真源）：同 toc 的核对口径。列表线上已按「页 → 页内位置 →
    // 建立时刻」有序，**这里不排也不改**——本端只显示与发请求。
    else if (o.type === "bookmarks") {
      S.bookmarksDocId = o.docId || "";
      S.bookmarks = (o.list || []) as BookmarkEntry[];
      S.bmRenaming = "";   // 回推到了 = 上一轮改名/删除已落定，收掉输入态
      S.bmAdding = false;
    }
    // 收藏笔列表整体同步（画布悬浮工具条实时增删改后，Mac 推下来）：替换本地 PENS + 当前下标。
    else if (o.type === "pens") {
      G.PENS = ((o.list || []) as Pen[]).map(function (p) { return { color: p.color, w: p.w, t: p.t }; });
      if (!G.PENS.length) G.PENS = [{ color: "rgba(24,90,210,0.95)", w: 8, t: "ballpoint" }];
      G.penIdx = clamp(o.active || 0, 0, G.PENS.length - 1);
      updateHud();
    }
    else if (o.type === "pen") {
      const i = o.index || 0;
      if (i >= 0 && i < G.PENS.length) { G.penIdx = i; updateHud(); }
    }
    // 多层笔迹图层表整体同步（Mac 执行 layerSelect/layerVisible/layerAdd 或本机 PenRack 编辑后推下来）：
    // 替换本地 LAYERS + 当前作画图层下标，权威状态永远以这条广播为准。
    else if (o.type === "layers") {
      G.LAYERS = ((o.list || []) as Layer[]).map(function (l) {
        return { r: l.r, g: l.g, b: l.b, visible: !!l.visible, name: l.name };
      });
      G.layerIdx = clamp(o.active || 0, 0, Math.max(0, G.LAYERS.length - 1));
      updateHud();
    }
    // Mac 侧切模式（悬浮工具条/环形盘选笔后回 note）：同步本地模式（顺带撤掉橡皮圆环，避免残留）
    else if (o.type === "mode") {
      for (let mi = 0; mi < MODES.length; mi++) {
        if (MODES[mi].key === o.mode && mi !== G.modeIdx) {
          if (curMode() === "lasso") G.clearLasso();   // 被 Mac 切走框选工具：同本地切模式，放弃选中
          G.modeIdx = mi; G.eraserRingAt = null; G.drawNotes(); updateHud(); break;
        }
      }
    }
    // Mac 侧调橡皮设置（或新连接补发）：更新本地命中半径/模式/圆环开关（PenStat 弹层打开时读它们做初值）
    else if (o.type === "eraser") {
      const v = +o.size; if (v > 0) G.eraserSize = v;
      G.eraserMode = o.mode === 0 ? 0 : 1;
      G.eraserRing = o.ring !== 0;
    }
    // Mac 检测到长按 → 把当前这半笔转成环形选笔盘：本地撤掉半笔、后续笔移不再画（只发位置驱动选笔）。
    else if (o.type === "inkCancel") { G.radialActive = true; G.cur = null; G.drawLive(); }
    // 环形选笔盘状态镜像（Mac 是唯一判定方）：照着画即可，open=false 收盘。
    else if (o.type === "radial") { G.setRadial(o); }
    // 长按进度环（盘的前置动画）：同样是 Mac 判定，on=false 撤环。
    else if (o.type === "pressRing") { G.setPressRing(o); }
    // 画板模式（Mac 是页边宽度的唯一真源，逐文档）：改内容宽 → 重算几何 → 整屏重画。
    // 本端落笔中的乐观跳档也会被这条覆盖回权威值（正常情况两者相等）。
    else if (o.type === "canvas") { G.setCanvas(!!o.on, +o.margin || 0); S.canvasOn = !!o.on; }
    // Mac 回传的全部笔迹（唯一真源）：平板据此显示 + 刷新/重连/切档后恢复。正在写的这一笔(cur)不清，避免闪断。
    // 框选提交后等回传：两条镜像（strokes/notes）**分开记账**——这条到了笔迹层改画真源（该层命中
    // 下标作废），notes 层继续乐观预览直到它的镜像也到；两条都到齐才 clearLasso（否则先到的那条
    // 把乐观变换全清掉，另一层跳回原位再跳回来 = 闪烁，2026-08-18 用户报）。
    // 追加帧（strokesAppend, 0x4C）：Mac 只在纯追加（收笔）时发，payload 与 strokes 逐字节相同。
    // 全量镜像每收一笔就重发整篇是 O(n²)，写久了 e2e 一路爬、还会把后面的控制帧压在 WS 队列里
    // （PROTOCOL.md §4.2）。这边只要把这几条接在末尾——擦除/框选/图层/切档 Mac 仍发全量。
    else if (o.type === "strokesAppend") {
      for (const s of o.list || []) G.strokes.push(s);
      G.drawInk();
    }
    else if (o.type === "strokes") {
      G.strokes = o.list || [];
      G.growCanvasForStrokes();   // 页外笔迹越出当前档位 → 本地先放宽，不然画出来是页边一条竖线
      if (G.activeId === null) { G.cur = null; G.drawLive(); }
      if (G.lassoCommitted) {
        G.lassoSyncStrokes = true;
        if (G.lassoSelection) G.lassoSelection.strokeIdx = [];   // 下标按旧数组算的，新数组上已失效
        if (G.lassoSyncNotes) G.clearLasso(); else { G.drawInk(); G.drawNotes(); }
      } else G.drawInk();
    }
    // 文字笔记全量镜像（Mac 是唯一真源）：收到即整体替换本地列表并重画标记。
    // layout 切文档后 Mac 会重发 notes，故 setLayout 不像 strokes 那样清空 notes（等重发即可，避免闪空）。
    // 框选提交后的分开记账同上（notes 层到了改画真源，strokes 层继续乐观直到其镜像到达）。
    else if (o.type === "notes") {
      G.notes = o.list || [];
      if (G.lassoCommitted) {
        G.lassoSyncNotes = true;
        if (G.lassoSelection) G.lassoSelection.noteIdx = [];
        if (G.lassoSyncStrokes) G.clearLasso(); else G.drawNotes();
      } else G.drawNotes();
    }
    // 草稿纸列表 + 开着第几张（Mac 是「哪张纸开着」的唯一真源；本地只发 scratchOpen/scratchAdd 请求）。
    else if (o.type === "scratchpads") { G.applyScratchPads(o); }
    // Mac 在环形盘提交「新建文字笔记」→ 在指定页内锚点打开编辑器（新建态，保存走 textNote 上行闭环）。
    else if (o.type === "noteNew") { openNoteAt(o); }
    // 当前那张纸上的全量笔迹（画布坐标，与页内笔迹不是一套坐标系，见 PROTOCOL.md §4.4）。
    else if (o.type === "scratchStrokes") { G.applyScratchStrokes(o); }
    // 旧 `page` 消息在方案 B 下忽略（布局改由 layout 驱动）。
  }

  function setLayout(o: WireMsg): void {
    const v = (o.v || o.docId || "");
    const changed = v !== G.docV;
    G.docV = v; S.docV = v; G.pageCount = o.count || 0; G.pagesWH = o.pages || [];
    if (changed) { G.strokes = []; G.cur = null; G.imgs = {}; G.scrollX = 0; G.scrollY = 0; G.zoom = 1; G.vpSeq = 0; }
    G.relayout();
    // 页尺寸表刚到位 → 草稿纸的页面底图矩形（高按页纵横比算）要跟着重画一次：
    // `scratchpads` 与 `layout` 两条广播的先后没有保证，先收到纸的那一次页会画成 A4 兜底的形状，
    // 不在这儿补一刀就要等用户平移/缩放才纠正过来。
    if (G.padActive()) G.drawScratch();
  }
  function setDocs(o: WireMsg): void {
    S.docs = o.list || [];
    S.docValue = o.following ? "" : (o.selected || "");
  }

  /// Mac 下发的 noteNew（环形盘「新建文字笔记」扇区）：在该页内锚点打开 TextNoteEditor 新建态。
  /// 复用「文字笔记模式点页面开编辑器」的同一入口（S.noteEditor），保存仍走 textNote 上行闭环。
  /// 盘本就开在平板当前可见页，锚点正常必然可见；万一不可见（页已滚走）就先程序化翻到该处
  /// 再开——本地滚动 + emitScroll 让 Mac 跟随（同翻页按钮惯例），不发 gotoPage（不抢 Mac 的视口）。
  function openNoteAt(o: WireMsg): void {
    const pg = o.page || 0;
    if (pg < 0 || pg >= G.pageCount) return;   // 越界丢弃
    const nx = o.nx || 0, ny = o.ny || 0;
    const v0 = G.pageToView(pg, nx, ny);
    if (v0.y < BAR || v0.y > window.innerHeight) {
      G.cancelMomentum();
      G.scrollY = clamp(G.offY[pg] + ny * G.dispH[pg] - G.availH / 2, 0, G.maxScrollY);
      G.ensureImages(); G.drawAll(); updatePageLabel(); G.emitScroll();
    }
    const v = G.pageToView(pg, nx, ny);
    S.noteEditor = { id: crypto.randomUUID(), page: pg, nx: nx, ny: ny, x: v.x, y: v.y,
                     text: "", display: 0, isNew: true };
  }

  // 收到 Mac 视口 → 程序化滚到该(页,纵向比例)，不回发。
  // force=1（新连接/切文档后的初始进度同步）绕过 seq 去重——该锚点的 seq 可能早就用过。
  function applyViewport(o: WireMsg): void {
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
  function emitGeom(): void {
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
