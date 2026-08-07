// 草稿纸模块（平板端）：盖在页图/笔迹之上的一张无限白纸，独立的滚动与缩放 + 回中 + minimap。
//
// 坐标系是**画布坐标**（逻辑 px，原点=创建点，可负无界，契约见 PROTOCOL.md §4.4）——
// 与页内 0~1 归一化完全不同的一套。换算只有两条：
//   view = (canvas − origin) × zoom      canvas = origin + view / zoom
//
// 分工同页内笔迹：Mac 是唯一真源（`scratchStrokes` 全量镜像），本地只即时回显正在写的这一笔。
// 「当前开着哪张纸」也由 Mac 定（`scratchpads.open`），本地只发 scratchOpen/scratchAdd 请求。
import { G, BAR, clamp, curMode, curPen, rulerSnap } from "./shared.js";
import type { CaptureRefs, Stroke } from "./shared.js";
import { S } from "./hud.svelte.js";

/// 橡皮半径的画布换算基准，**必须与 Mac 端 `ScratchPad.eraserRefWidth` 是同一个数**：
/// `eraserSize` 是页宽归一化的（0.02 = 页宽 2%），草稿纸没有「页宽」，统一按这个折成画布 px。
export const PAD_ERASER_REF_W = 800;

const MINZ = 0.2, MAXZ = 8;
const SLACK = 1.5;          // 软边界：可视区必须与「内容包围盒 ± SLACK 屏」相交
const MINI_W = 150, MINI_H = 108, MINI_PAD = 12;

export function initScratch(refs: CaptureRefs): void {
  const cv = refs.scratch;
  const cx = cv.getContext("2d")!;

  function sizeCanvas(): void {
    cv.width = Math.round(window.innerWidth * G.DPR);
    cv.height = Math.round(window.innerHeight * G.DPR);
    cv.style.width = window.innerWidth + "px";
    cv.style.height = window.innerHeight + "px";
    cx.setTransform(G.DPR, 0, 0, G.DPR, 0, 0);
    cx.lineCap = "round"; cx.lineJoin = "round";
  }

  // ---- 坐标换算 ----
  const vw = (): number => window.innerWidth;
  const vh = (): number => window.innerHeight - BAR;
  function toCanvas(x: number, y: number): [number, number] {
    return [G.padVp.ox + x / G.padVp.z, G.padVp.oy + (y - BAR) / G.padVp.z];
  }

  /// 全部笔迹的画布包围盒（含正在写的这一笔），空 → null。minimap 与「适应内容」共用。
  function contentBox(): [number, number, number, number] | null {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity, any = false;
    const all = G.padCur ? G.padStrokes.concat([G.padCur]) : G.padStrokes;
    for (let i = 0; i < all.length; i++) {
      const pts = all[i].pts;
      for (let j = 0; j < pts.length; j++) {
        any = true;
        if (pts[j][0] < x0) x0 = pts[j][0];
        if (pts[j][0] > x1) x1 = pts[j][0];
        if (pts[j][1] < y0) y0 = pts[j][1];
        if (pts[j][1] > y1) y1 = pts[j][1];
      }
    }
    return any ? [x0, y0, x1 - x0, y1 - y0] : null;
  }

  /// 软边界：真无限会让人一路滑进空无一物的远方再也找不回来（用户明确要求避免）。
  /// 规则一条——可视区必须与「内容包围盒 ± SLACK 屏」相交；越界即拉回。空纸就只能在原点附近晃。
  function padClamp(): void {
    const z = G.padVp.z, visW = vw() / z, visH = vh() / z;
    const b = contentBox() || [0, 0, 0, 0];
    const sx = visW * SLACK, sy = visH * SLACK;
    G.padVp.ox = clamp(G.padVp.ox, b[0] - sx - visW, b[0] + b[2] + sx);
    G.padVp.oy = clamp(G.padVp.oy, b[1] - sy - visH, b[1] + b[3] + sy);
  }

  /// 回中：画布原点（= 这张纸当初创建的位置）回到视口正中，缩放复位。
  function padRecenter(): void {
    G.padVp.z = 1;
    G.padVp.ox = -vw() / 2; G.padVp.oy = -vh() / 2;
    drawScratch();
  }

  /// 适应内容：把全部笔迹装进视口；空纸退化为回中。
  function padFit(): void {
    const b = contentBox();
    if (!b) { padRecenter(); return; }
    const z = clamp(Math.min((vw() - 80) / Math.max(b[2], 1), (vh() - 80) / Math.max(b[3], 1)), MINZ, MAXZ);
    G.padVp.z = z;
    G.padVp.ox = b[0] + b[2] / 2 - vw() / (2 * z);
    G.padVp.oy = b[1] + b[3] / 2 - vh() / (2 * z);
    drawScratch();
  }

  /// 以某个**视口点**为锚缩放（双指捏合 / 滚轮）：该点下的画布内容不动。
  function padZoomAt(factor: number, x: number, y: number): void {
    const z0 = G.padVp.z, z = clamp(z0 * factor, MINZ, MAXZ);
    if (z === z0) return;
    const [cxp, cyp] = toCanvas(x, y);
    G.padVp.z = z;
    G.padVp.ox = cxp - x / z;
    G.padVp.oy = cyp - (y - BAR) / z;
    padClamp(); drawScratch();
  }

  function padPanBy(dx: number, dy: number): void {
    G.padVp.ox += dx / G.padVp.z; G.padVp.oy += dy / G.padVp.z;
    padClamp(); drawScratch();
  }

  // ---- 绘制 ----

  /// 几何缓存：与页内笔迹同款 WeakMap（Mac 每次回传都是新解码对象，旧条目自动被 GC 收走）。
  /// 几何建在「画布坐标 × zoom」里 → **平移只是 translate，缓存不失效**，只有缩放才重建。
  const geomCache = new WeakMap<Stroke, { key: number; g: unknown }>();

  function paintStroke(s: Stroke, live: boolean): void {
    const z = G.padVp.z;
    const px = (i: number): number => s.pts[i][0] * z;
    const py = (i: number): number => s.pts[i][1] * z;
    let g: unknown;
    if (live) {
      g = G.buildGeomWith(s, px, py, z, z);   // 活体每帧都在变，进缓存只会堆新条目
    } else {
      const hit = geomCache.get(s);
      if (hit && hit.key === z) { g = hit.g; }
      else { g = G.buildGeomWith(s, px, py, z, z); geomCache.set(s, { key: z, g }); }
    }
    G.paintInkGeom(cx, g, -G.padVp.ox * z, BAR - G.padVp.oy * z);
  }

  function drawScratch(): void {
    if (!padActive()) { cx.clearRect(0, 0, window.innerWidth, window.innerHeight); return; }
    const W = window.innerWidth, H = window.innerHeight;
    cx.clearRect(0, 0, W, H);
    // 纸面（顶栏之下整块）。底色由 Mac 下发，默认纯白；夜间模式不反色——草稿纸是「一张纸」。
    cx.fillStyle = G.pads[G.padOpen] ? G.pads[G.padOpen].bg : "rgba(255,255,255,1)";
    cx.fillRect(0, BAR, W, H - BAR);
    // 视口外的笔迹裁掉（画布是全文档级的一大坨，不裁就是每帧把整张纸重画一遍）
    const z = G.padVp.z, x0 = G.padVp.ox, y0 = G.padVp.oy;
    const x1 = x0 + W / z, y1 = y0 + (H - BAR) / z;
    for (let i = 0; i < G.padStrokes.length; i++) {
      const s = G.padStrokes[i];
      if (!boxHits(s, x0, y0, x1, y1)) continue;
      paintStroke(s, false);
    }
    if (G.padCur) paintStroke(G.padCur, true);
    if (G.eraserRing && G.eraserRingAt && curMode() === "erase") {
      cx.save();
      cx.strokeStyle = "rgba(24,90,210,.9)"; cx.lineWidth = 1.5;
      cx.beginPath();
      cx.arc(G.eraserRingAt.x, G.eraserRingAt.y, G.eraserSize * PAD_ERASER_REF_W * z, 0, Math.PI * 2);
      cx.stroke(); cx.restore();
    }
    if (G.padMini) drawMinimap();
  }

  /// 这条笔迹的包围盒与可视矩形有没有交集（粗筛，逐点算一遍比重画便宜得多）。
  function boxHits(s: Stroke, x0: number, y0: number, x1: number, y1: number): boolean {
    let a0 = Infinity, b0 = Infinity, a1 = -Infinity, b1 = -Infinity;
    for (let j = 0; j < s.pts.length; j++) {
      const p = s.pts[j];
      if (p[0] < a0) a0 = p[0];
      if (p[0] > a1) a1 = p[0];
      if (p[1] < b0) b0 = p[1];
      if (p[1] > b1) b1 = p[1];
    }
    const m = s.pen.w + 4;   // 线宽余量，免得贴边的粗笔被切掉
    return a1 + m >= x0 && a0 - m <= x1 && b1 + m >= y0 && b0 - m <= y1;
  }

  /// 右下角缩略图：把「全部笔迹 ∪ 当前视口」等比装进小窗，画笔迹骨架 + 当前视口框。
  /// 点/拖窗内任意处 → 视口中心跳到对应画布位置（`padMiniJump`）。
  function miniFit(): { wx: number; wy: number; ww: number; wh: number; s: number; ox: number; oy: number } {
    const z = G.padVp.z;
    const vx = G.padVp.ox, vy = G.padVp.oy, vwc = vw() / z, vhc = vh() / z;
    const b = contentBox();
    let x0 = vx, y0 = vy, x1 = vx + vwc, y1 = vy + vhc;
    if (b) { x0 = Math.min(x0, b[0]); y0 = Math.min(y0, b[1]); x1 = Math.max(x1, b[0] + b[2]); y1 = Math.max(y1, b[1] + b[3]); }
    const padX = (x1 - x0) * 0.08, padY = (y1 - y0) * 0.08;
    x0 -= padX; x1 += padX; y0 -= padY; y1 += padY;
    const ww = Math.max(1, x1 - x0), wh = Math.max(1, y1 - y0);
    const s = Math.min(MINI_W / ww, MINI_H / wh);
    return { wx: x0, wy: y0, ww, wh, s, ox: (MINI_W - ww * s) / 2, oy: (MINI_H - wh * s) / 2 };
  }
  function miniRect(): [number, number] {
    return [window.innerWidth - MINI_W - MINI_PAD, window.innerHeight - MINI_H - MINI_PAD];
  }

  function drawMinimap(): void {
    const [mx, my] = miniRect(), f = miniFit();
    cx.save();
    cx.fillStyle = "rgba(20,23,28,.72)";
    cx.fillRect(mx, my, MINI_W, MINI_H);
    cx.strokeStyle = "rgba(255,255,255,.22)"; cx.lineWidth = 1;
    cx.strokeRect(mx + .5, my + .5, MINI_W - 1, MINI_H - 1);
    cx.beginPath(); cx.rect(mx, my, MINI_W, MINI_H); cx.clip();
    const MX = (x: number): number => mx + f.ox + (x - f.wx) * f.s;
    const MY = (y: number): number => my + f.oy + (y - f.wy) * f.s;
    // 骨架线即可（minimap 不必还原笔型/压感）
    cx.strokeStyle = "rgba(255,255,255,.7)"; cx.lineWidth = 1;
    const all = G.padCur ? G.padStrokes.concat([G.padCur]) : G.padStrokes;
    for (let i = 0; i < all.length; i++) {
      const pts = all[i].pts;
      if (pts.length < 2) continue;
      cx.beginPath(); cx.moveTo(MX(pts[0][0]), MY(pts[0][1]));
      for (let j = 1; j < pts.length; j++) cx.lineTo(MX(pts[j][0]), MY(pts[j][1]));
      cx.stroke();
    }
    // 当前视口框
    const z = G.padVp.z;
    cx.strokeStyle = "rgba(90,170,255,1)"; cx.lineWidth = 1.5;
    cx.strokeRect(MX(G.padVp.ox), MY(G.padVp.oy),
                  Math.max(3, (vw() / z) * f.s), Math.max(3, (vh() / z) * f.s));
    cx.restore();
  }

  function inMinimap(x: number, y: number): boolean {
    if (!G.padMini) return false;
    const [mx, my] = miniRect();
    return x >= mx && x <= mx + MINI_W && y >= my && y <= my + MINI_H;
  }
  /// minimap 上的点 → 把视口中心挪过去。
  function padMiniJump(x: number, y: number): void {
    const [mx, my] = miniRect(), f = miniFit();
    if (f.s <= 0) return;
    const cxx = f.wx + (x - mx - f.ox) / f.s, cyy = f.wy + (y - my - f.oy) / f.s;
    const z = G.padVp.z;
    G.padVp.ox = cxx - vw() / (2 * z); G.padVp.oy = cyy - vh() / (2 * z);
    padClamp(); drawScratch();
  }

  // ---- 输入（input.ts 在草稿纸打开时把指针事件整段让给这里）----

  function padActive(): boolean { return G.padOpen >= 0 && G.padOpen < G.pads.length; }

  /// 返回 true = 本次事件已被草稿纸消费，input.ts 不再按页内逻辑处理。
  function padPointerDown(e: PointerEvent): boolean {
    if (!padActive()) return false;
    if (e.pointerType !== "touch" && inMinimap(e.clientX, e.clientY)) {
      G.padMiniDrag = true; padMiniJump(e.clientX, e.clientY);
      G.activeId = e.pointerId; G.penMode = "padmini";
      return true;
    }
    if (e.pointerType === "touch") {
      // 手指：单指平移、双指捏合（与页内同款，只是作用在草稿纸视口上）
      if (G.activeId !== null) return true;
      G.touches[e.pointerId] = { x: e.clientX, y: e.clientY };
      if (G.touchOrder.indexOf(e.pointerId) < 0) G.touchOrder.push(e.pointerId);
      if (G.touchOrder.length >= 2) {
        const a = G.touches[G.touchOrder[0]], b = G.touches[G.touchOrder[1]];
        G.padPinch = { d0: Math.max(40, Math.hypot(a.x - b.x, a.y - b.y)), z0: G.padVp.z };
        G.panId = null;
      } else {
        if (inMinimap(e.clientX, e.clientY)) { G.padMiniDrag = true; padMiniJump(e.clientX, e.clientY); return true; }
        G.panId = e.pointerId; G.lastPanX = e.clientX; G.lastPanY = e.clientY;
      }
      return true;
    }
    // 笔：note 落墨 / erase 擦除；page、lasso 在草稿纸上退化为平移（画布没有「页」也没有页内框选）
    const m = curMode();
    G.activeId = e.pointerId; G.penMode = m === "erase" ? "paderase" : (m === "note" ? "padink" : "padpan");
    G.penX = e.clientX; G.penY = e.clientY;
    const [x, y] = toCanvas(e.clientX, e.clientY);
    if (G.penMode === "padink") {
      const pen = curPen();
      G.lineStroke = G.rulerOn;
      G.padCur = { page: 0, pen: { color: pen.color, w: pen.w, t: pen.t }, pts: [[x, y, e.pressure]] };
      drawScratch();
      // page 字段在草稿纸上作废（PROTOCOL.md §4.4），仍编码 0 保持定长。
      G.send({ type: "ink", phase: "begin", page: 0, pen: G.padCur.pen, pts: [[x, y, e.pressure]], line: G.lineStroke });
    } else if (G.penMode === "paderase") {
      G.batch.push([x, y, 0]);
      if (G.eraserRing) G.eraserRingAt = { x: e.clientX, y: e.clientY };
      padEraseLocal(x, y);
      drawScratch();
    }
    return true;
  }

  function padPointerMove(e: PointerEvent): boolean {
    if (!padActive()) return false;
    if (G.padMiniDrag) { padMiniJump(e.clientX, e.clientY); return true; }
    if (e.pointerType === "touch") {
      if (!(e.pointerId in G.touches)) return true;
      G.touches[e.pointerId] = { x: e.clientX, y: e.clientY };
      if (G.padPinch && G.touchOrder.length >= 2) {
        const a = G.touches[G.touchOrder[0]], b = G.touches[G.touchOrder[1]];
        const d = Math.hypot(a.x - b.x, a.y - b.y);
        if (!G.zoomLocked) {
          const target = clamp(G.padPinch.z0 * d / G.padPinch.d0, MINZ, MAXZ);
          padZoomAt(target / G.padVp.z, (a.x + b.x) / 2, (a.y + b.y) / 2);
        }
      } else if (e.pointerId === G.panId) {
        padPanBy(G.lastPanX - e.clientX, G.lastPanY - e.clientY);
        G.lastPanX = e.clientX; G.lastPanY = e.clientY;
      }
      return true;
    }
    if (e.pointerId !== G.activeId) return true;
    if (G.penMode === "padpan") {
      padPanBy(G.penX - e.clientX, G.penY - e.clientY);
      G.penX = e.clientX; G.penY = e.clientY;
      return true;
    }
    let evs = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
    if (!evs.length) evs = [e];
    for (let i = 0; i < evs.length; i++) {
      const ev = evs[i];
      const [x, y] = toCanvas(ev.clientX, ev.clientY);
      if (G.penMode === "padink" && G.padCur) {
        if (G.lineStroke && G.padCur.pts.length) {
          // 尺子：画布是等比坐标系 → aspect=1（页内那套要传页纵横比，因为两轴尺度不同）。
          const a = G.padCur.pts[0];
          const sn = rulerSnap(a[0], a[1], x, y, 1);
          G.padCur.pts = [a, [sn[0], sn[1], ev.pressure]];
          G.batch = [[sn[0], sn[1], ev.pressure]];   // 只留最新终点，同页内 lineStroke 分支
        } else {
          G.padCur.pts.push([x, y, ev.pressure]);
          G.batch.push([x, y, ev.pressure]);
        }
      } else if (G.penMode === "paderase") {
        G.batch.push([x, y, 0]);
        padEraseLocal(x, y);
        if (G.eraserRing) G.eraserRingAt = { x: ev.clientX, y: ev.clientY };
      }
    }
    drawScratch();
    return true;
  }

  function padPointerUp(e: PointerEvent): boolean {
    if (!padActive()) return false;
    if (G.padMiniDrag) { G.padMiniDrag = false; G.activeId = null; G.penMode = ""; return true; }
    if (e.pointerType === "touch") {
      delete G.touches[e.pointerId];
      const k = G.touchOrder.indexOf(e.pointerId); if (k >= 0) G.touchOrder.splice(k, 1);
      G.padPinch = null;
      if (G.touchOrder.length === 1) {
        G.panId = G.touchOrder[0];
        const t = G.touches[G.panId]; G.lastPanX = t.x; G.lastPanY = t.y;
      } else if (!G.touchOrder.length) { G.panId = null; }
      return true;
    }
    if (e.pointerId !== G.activeId) return true;
    if (G.penMode === "padink") { padFlush("ink"); G.send({ type: "ink", phase: "end" }); }
    else if (G.penMode === "paderase") { padFlush("erase"); G.send({ type: "erase", phase: "end" }); }
    G.activeId = null; G.penMode = "";
    return true;
  }

  /// 批点上行（rAF tick 与抬笔各调一次，同页内 flushBatch）。坐标已是画布坐标。
  function padFlush(kind: "ink" | "erase"): void {
    if (!G.batch.length) return;
    if (kind === "erase") {
      G.send({ type: "erase", phase: "move", page: 0, pts: G.batch.map((b) => [b[0], b[1]]) });
    } else {
      G.send({ type: "ink", phase: "move", pts: G.batch });
    }
    G.batch = [];
  }

  /// 本地乐观擦除（同页内 `eraseHit` 先例：只为即时反馈，真源在 Mac，回传即整体替换）。
  /// 半径换算与 Mac 端 `ScratchPad.eraserRefWidth` 必须同一个数，否则两端擦掉的不一样多。
  function padEraseLocal(x: number, y: number): void {
    const r = G.eraserSize * PAD_ERASER_REF_W, r2 = r * r;
    const out: Stroke[] = [];
    let changed = false;
    for (let i = 0; i < G.padStrokes.length; i++) {
      const s = G.padStrokes[i];
      if (G.eraserMode === 0) {
        let hit = false;
        for (let j = 0; j < s.pts.length && !hit; j++) {
          const dx = s.pts[j][0] - x, dy = s.pts[j][1] - y;
          if (dx * dx + dy * dy <= r2) hit = true;
        }
        if (hit) { changed = true; continue; }
        out.push(s);
      } else {
        // 局部擦除：剔除命中点，连续未命中段各成一条（与 Mac `InkEdit.splitStroke` 同算法）
        let seg: [number, number, number][] = [];
        let anyHit = false;
        const parts: Stroke[] = [];
        for (let j = 0; j < s.pts.length; j++) {
          const dx = s.pts[j][0] - x, dy = s.pts[j][1] - y;
          if (dx * dx + dy * dy <= r2) {
            anyHit = true;
            if (seg.length) { parts.push({ page: 0, pen: s.pen, pts: seg }); seg = []; }
          } else seg.push(s.pts[j]);
        }
        if (seg.length) parts.push({ page: 0, pen: s.pen, pts: seg });
        if (!anyHit) { out.push(s); continue; }
        changed = true;
        for (let k = 0; k < parts.length; k++) out.push(parts[k]);
      }
    }
    if (changed) G.padStrokes = out;
  }

  // ---- 开/关/新建（本地只发请求，Mac 判定后回推 scratchpads + scratchStrokes）----

  function padOpenIndex(i: number): void { G.send({ type: "scratchOpen", index: i }); }
  function padClose(): void { G.send({ type: "scratchOpen", index: -1 }); }
  /// 在当前视口中心所在的页面位置新建一张（锚点＝那一处，Mac 据此画图钉）。
  function padAdd(): void {
    const loc = G.locate(window.innerWidth / 2, BAR + (window.innerHeight - BAR) / 2);
    G.send({ type: "scratchAdd", page: loc ? loc.page : G.topVisiblePage(),
             nx: loc ? loc.nx : 0.5, ny: loc ? loc.ny : 0.5 });
  }

  /// Mac 下发的 `scratchpads`：列表 + 开着第几张。开/关/换纸都在这里落地。
  function applyScratchPads(o: { open?: number; list?: { id: string; title: string; page: number; nx: number; ny: number; bg: string }[] }): void {
    const wasOpen = G.padOpen, wasId = G.pads[wasOpen] ? G.pads[wasOpen].id : "";
    G.pads = o.list || [];
    G.padOpen = typeof o.open === "number" ? o.open : -1;
    if (G.padOpen >= G.pads.length) G.padOpen = -1;
    S.pads = G.pads.map((p, i) => ({ id: p.id, title: p.title, page: p.page, index: i }));
    S.padOpen = G.padOpen;
    const nowId = G.pads[G.padOpen] ? G.pads[G.padOpen].id : "";
    if (nowId !== wasId) {
      // 换了纸（含开/关）：丢掉上一张的本地状态并回到画布原点（与 Mac 端 `.id(pad.id)` 同语义）。
      // `cur` 也要清：从页面切进草稿纸时页内可能正写着半笔，不清就一直挂在 live 层上。
      G.padStrokes = []; G.padCur = null; G.cur = null; G.batch = [];
      G.drawLive();
      G.activeId = null; G.penMode = ""; G.padPinch = null; G.padMiniDrag = false;
      G.touches = {}; G.touchOrder = []; G.panId = null;
      if (nowId) padRecenter();
    }
    if (!nowId) { cv.style.display = "none"; G.drawAll(); }
    else { cv.style.display = "block"; drawScratch(); }
    // 列表本身变了（新建/删除/改名/换开着的那张）都要重画页面上的图钉——图钉画在 hover 层，
    // 而那层只有 drawNotes 会重画，不显式调一次的话新建的纸在页面上看不到图钉。
    G.drawNotes();
  }

  /// Mac 下发的 `scratchStrokes`：当前那张纸上的全量笔迹（唯一真源）。
  function applyScratchStrokes(o: { list?: Stroke[] }): void {
    G.padStrokes = (o.list || []).map((s) => ({ page: 0, pen: s.pen, pts: s.pts }));
    if (G.activeId === null) G.padCur = null;   // 已进真源，撤掉本地那一笔（同页内 strokes 分支）
    if (padActive()) drawScratch();
  }

  window.addEventListener("resize", function () { sizeCanvas(); if (padActive()) drawScratch(); });
  sizeCanvas();
  cv.style.display = "none";

  // 滚轮/触控板（桌面浏览器测试用）：等同平移，⌘/Ctrl + 滚轮 = 缩放。
  cv.addEventListener("wheel", function (e: WheelEvent) {
    if (!padActive()) return;
    const unit = e.deltaMode === 1 ? 16 : (e.deltaMode === 2 ? vh() : 1);
    if (e.ctrlKey || e.metaKey) {
      padZoomAt(Math.exp(-e.deltaY * unit * 0.008), e.clientX, e.clientY);
    } else {
      padPanBy(e.deltaX * unit, e.deltaY * unit);
    }
    e.preventDefault();
  }, { passive: false });

  Object.assign(G, {
    padActive, drawScratch, padRecenter, padFit, padClamp,
    padPointerDown, padPointerMove, padPointerUp, padFlush,
    padOpenIndex, padClose, padAdd, applyScratchPads, applyScratchStrokes,
  });
}

/// 供 PenStat 等处显示「草稿纸上的橡皮有多大」时换算用（与上面同一个基准）。
export function padEraserPx(sizeNorm: number, zoom: number): number {
  return sizeNorm * PAD_ERASER_REF_W * zoom;
}
