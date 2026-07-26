// 渲染模块：画布尺寸/DPR、文档几何布局、坐标映射、页面/笔迹/悬停绘制、环形选笔盘 + 长按进度环。
// 逐行移植自原 capture.html IIFE 的对应段落（原文件已被本工程取代）。
// 注意：原版有一个定义了却从未调用的 drawHover()（本地悬停圆环），移植时按死代码丢弃——
// 悬停光标由 Mac 端画，平板只上报位置（见 input.ts reportHover）。
import { G, BAR, GAP, RD, PR, BRUSH_LABELS, clamp, pw, contentLeft, strokeWidthFor, opacityMultFor, scaledColor } from "./shared.js";
import type { CaptureRefs, RadialItem, RadialState, Stroke, WireMsg } from "./shared.js";
import { updateHud } from "./hud.svelte.js";

export function initRender(refs: CaptureRefs): void {
  const { bg, ink, live, hover, radial: radialCv, radialGlass } = refs;
  const bctx = bg.getContext("2d")!, ictx = ink.getContext("2d")!, hctx = hover.getContext("2d")!;
  const lctx = live.getContext("2d")!, rctx = radialCv.getContext("2d")!;

  function sizeCanvas(c: HTMLCanvasElement, cx: CanvasRenderingContext2D): void {
    c.width = Math.round(window.innerWidth * G.DPR);
    c.height = Math.round(window.innerHeight * G.DPR);
    c.style.width = window.innerWidth + "px";
    c.style.height = window.innerHeight + "px";
    cx.setTransform(G.DPR, 0, 0, G.DPR, 0, 0);
    cx.lineCap = "round"; cx.lineJoin = "round";
  }

  // 只重算几何（不动 canvas 尺寸），供缩放时保持锚点用。
  function recompute(): void {
    G.vw = window.innerWidth;
    G.availH = window.innerHeight - BAR;
    const p = pw();
    let y = 0;
    G.dispH = []; G.offY = [];
    for (let i = 0; i < G.pageCount; i++) {
      const w = (G.pagesWH[i] && G.pagesWH[i][0]) || 1, h = (G.pagesWH[i] && G.pagesWH[i][1]) || 1.4142;
      const dh = w > 0 ? p * h / w : p;
      G.offY[i] = y; G.dispH[i] = dh; y += dh + GAP;
    }
    G.totalH = Math.max(0, y - GAP);
    G.maxScrollY = Math.max(0, G.totalH - G.availH);
    G.maxScrollX = Math.max(0, p - G.vw);
  }
  function relayout(): void {
    G.DPR = Math.max(1, window.devicePixelRatio || 1);
    sizeCanvas(bg, bctx); sizeCanvas(ink, ictx); sizeCanvas(live, lctx);
    sizeCanvas(hover, hctx); sizeCanvas(radialCv, rctx);
    recompute();
    G.scrollX = clamp(G.scrollX, 0, G.maxScrollX); G.scrollY = clamp(G.scrollY, 0, G.maxScrollY);
    ensureImages(); drawAll(); drawRadial(); updateHud(); G.emitGeom();
  }
  window.addEventListener("resize", relayout);

  // ---- 按需取图（可见 + 上下各一屏预取）----
  function ensureImages(): void {
    if (!G.pageCount || !G.showPage) return;
    const top = G.scrollY - G.availH, bot = G.scrollY + G.availH * 2;
    for (let i = 0; i < G.pageCount; i++) {
      if (G.offY[i] + G.dispH[i] >= top && G.offY[i] <= bot) loadImg(i);
    }
  }
  function loadImg(i: number): void {
    if (G.imgs[i]) return;
    const im = new Image();
    im.onload = function () { drawBg(); };
    im.src = "/page.png?i=" + i + "&v=" + encodeURIComponent(G.docV);
    G.imgs[i] = im;
  }

  // ---- 坐标映射（跨页 + 缩放）----
  function locate(x: number, vy: number): { page: number; nx: number; ny: number } | null {
    const cl = contentLeft(), p = pw();
    const docY = vy - BAR + G.scrollY;
    for (let i = 0; i < G.pageCount; i++) {
      if (docY >= G.offY[i] && docY <= G.offY[i] + G.dispH[i]) {
        return { page: i, nx: clamp((x - cl) / p, 0, 1), ny: clamp((docY - G.offY[i]) / G.dispH[i], 0, 1) };
      }
    }
    return null;
  }
  function pageToView(page: number, nx: number, ny: number): { x: number; y: number } {
    if (page < 0 || page >= G.pageCount) return { x: 0, y: -1e6 };
    const docY = G.offY[page] + ny * G.dispH[page];
    return { x: contentLeft() + nx * pw(), y: BAR + docY - G.scrollY };
  }
  function inContent(x: number, y: number): boolean { return y >= BAR && locate(x, y) !== null; }

  // ---- 绘制 ----
  function drawAll(): void { drawBg(); drawInk(); drawLive(); }
  function drawBg(): void {
    bctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    const cl = contentLeft(), p = pw();
    for (let i = 0; i < G.pageCount; i++) {
      const vy = BAR + G.offY[i] - G.scrollY;
      if (vy + G.dispH[i] < BAR || vy > window.innerHeight) continue;
      bctx.fillStyle = "#fff"; bctx.fillRect(cl, vy, p, G.dispH[i]);
      if (!G.showPage) continue;   // 手写板模式：仅白底，不取图
      const im = G.imgs[i];
      if (im && im.complete && im.naturalWidth) bctx.drawImage(im, cl, vy, p, G.dispH[i]);
      else { bctx.fillStyle = "#e9edf2"; bctx.fillRect(cl, vy, p, G.dispH[i]); loadImg(i); }
    }
  }
  /// 画一整条笔画到指定 context（静态层与活体层共用，保证两者观感一致）。
  /// **marker 必须整条一次成 path**（平头 + multiply），与 Mac 端 `inkDrawStroke` 的 marker 分支同理：
  /// 逐段 stroke 会让相邻段的线帽互相重叠，不透明笔看不出来，半透明笔（荧光笔）就叠成一串圆斑。
  function drawStroke(cx: CanvasRenderingContext2D, s: Stroke): void {
    const pts = s.pts; if (!pts.length) return;
    const t = s.pen.t || "ballpoint", color = scaledColor(s.pen.color, opacityMultFor(t));
    const p0 = pageToView(s.page, pts[0][0], pts[0][1]);
    if (pts.length === 1) {   // 单点 = 一个圆点（同 Mac 端单点分支）
      cx.fillStyle = color;
      cx.beginPath(); cx.arc(p0.x, p0.y, strokeWidthFor(t, pts[0][2], s.pen.w) / 2, 0, Math.PI * 2); cx.fill();
      return;
    }
    let lp = p0, i: number;
    if (t === "marker") {
      cx.save();
      cx.globalCompositeOperation = "multiply";
      cx.lineCap = "square"; cx.lineJoin = "round";   // 平头：圆头会在起收笔处鼓出来
      cx.strokeStyle = color; cx.lineWidth = s.pen.w;
      cx.beginPath(); cx.moveTo(p0.x, p0.y);
      for (i = 1; i < pts.length; i++) {
        const q = pageToView(s.page, pts[i][0], pts[i][1]);
        cx.quadraticCurveTo(lp.x, lp.y, (lp.x + q.x) / 2, (lp.y + q.y) / 2);
        lp = q;
      }
      cx.stroke();
      cx.restore();
      return;
    }
    // ballpoint / fountain / pencil：线宽随压感变，只能逐段画（与 Mac 端 default 分支同款）
    cx.fillStyle = color;
    cx.beginPath(); cx.arc(p0.x, p0.y, strokeWidthFor(t, pts[0][2], s.pen.w) / 2, 0, Math.PI * 2); cx.fill();
    let lastMid = p0;
    for (i = 1; i < pts.length; i++) {
      const pv = pageToView(s.page, pts[i][0], pts[i][1]), pr = pts[i][2];
      const mx = (lp.x + pv.x) / 2, my = (lp.y + pv.y) / 2;
      cx.strokeStyle = color; cx.lineWidth = strokeWidthFor(t, pr, s.pen.w);
      cx.beginPath(); cx.moveTo(lastMid.x, lastMid.y); cx.quadraticCurveTo(lp.x, lp.y, mx, my); cx.stroke();
      lastMid = { x: mx, y: my }; lp = pv;
    }
  }
  /// 静态层：已成形的笔迹（Mac 回传的唯一真源）。
  function drawInk(): void {
    ictx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    for (let i = 0; i < G.strokes.length; i++) drawStroke(ictx, G.strokes[i]);
  }
  /// 活体层：正在写的这一笔，**每次落点整条重画**（不往已有像素上增量叠加，否则半透明笔会累积出圆斑）。
  /// 与 Mac 端 `InkLiveLayer` 同构；单独一层，故重画一笔不牵动整页笔迹。
  function drawLive(): void {
    lctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    if (G.cur) drawStroke(lctx, G.cur);
  }

  function eraseHit(x: number, y: number): void {
    const r = 18;
    let changed = false;
    for (let i = G.strokes.length - 1; i >= 0; i--) {
      const pts = G.strokes[i].pts;
      for (let j = 0; j < pts.length; j++) {
        const pv = pageToView(G.strokes[i].page, pts[j][0], pts[j][1]);
        if ((pv.x - x) * (pv.x - x) + (pv.y - y) * (pv.y - y) <= r * r) { G.strokes.splice(i, 1); changed = true; break; }
      }
    }
    if (changed) drawInk();
  }

  // ---- 悬停（本地只清环；光标本体由 Mac 画，上报见 input.ts）----
  function clearHover(): void { hctx.clearRect(0, 0, window.innerWidth, window.innerHeight); }

  // ---- 环形选笔盘（Surface Dial 形制）----
  // 长按检测、扇区判定、选中提交**全在 Mac**；这里只画 Mac 下发的 `radial` 状态，不做任何判定。
  // 半径/角度常量必须与 Mac 端 `RadialLayout` 逐个对齐（shared.ts 的 RD）。
  const TOOL_LABEL: Record<string, string> = { erase: "橡皮", page: "翻页" };

  function setRadial(o: WireMsg | null): void { G.radialState = (o && o.open) ? o as unknown as RadialState : null; drawRadial(); }

  // 长按进度环（环形盘的前置动画）：规格与 Mac 端 `PageCellView` 的 pressRing 一致。
  // 判定同样在 Mac，这里只画。平板收到 on 用本机时钟起计（局域网 RTT 的几毫秒偏差不可察觉，故协议不带时间戳）。
  function setPressRing(o: WireMsg | null): void {
    if (o && o.on) {
      G.pressRing = { page: o.page, nx: o.nx, ny: o.ny, t0: performance.now() };
      if (!G.pressRAF) G.pressRAF = requestAnimationFrame(pressTick);
      return;
    }
    G.pressRing = null;
    if (G.pressRAF) { cancelAnimationFrame(G.pressRAF); G.pressRAF = null; }
    drawRadial();
  }
  function pressTick(): void {
    G.pressRAF = G.pressRing ? requestAnimationFrame(pressTick) : null;
    drawRadial();
  }
  function drawPressRing(): void {
    const pr = G.pressRing; if (!pr) return;
    const p = clamp((performance.now() - pr.t0 - PR.delayMs) / PR.fillMs, 0, 1);
    if (p <= 0.001) return;   // 300ms 前不显示：轻点/快速书写不该闪一下环
    const v = pageToView(pr.page, pr.nx, pr.ny), r = PR.d / 2;
    rctx.save();
    rctx.lineWidth = PR.lw; rctx.lineCap = "round";
    rctx.strokeStyle = "rgba(255,255,255,0.25)";   // 轨道
    rctx.beginPath(); rctx.arc(v.x, v.y, r, 0, Math.PI * 2); rctx.stroke();
    rctx.strokeStyle = "#58a6ff";                  // 进度（从正上方顺时针）
    rctx.beginPath(); rctx.arc(v.x, v.y, r, -Math.PI / 2, -Math.PI / 2 + p * Math.PI * 2); rctx.stroke();
    rctx.restore();
  }

  function rgbaParts(css: string): [number, number, number, number] {
    const m = /rgba?\(([^)]+)\)/.exec(css || "");
    if (!m) return [0, 0, 0, 1];
    const p = m[1].split(",").map((s) => parseFloat(s));
    return [p[0] || 0, p[1] || 0, p[2] || 0, p.length > 3 ? p[3] : 1];
  }
  function contrastOn(css: string): string {
    const c = rgbaParts(css);
    return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255 > 0.62 ? "#000" : "#fff";
  }
  /// 选中扇区的填充色：笔用自身颜色但**丢掉透明度**（荧光笔 alpha 很低，照抄会看不见高亮）。
  function tintOf(item: RadialItem): string {
    if (item.kind === "erase") return "rgba(245,140,51,0.92)";
    if (item.kind === "page") return "rgba(64,184,179,0.92)";
    const c = rgbaParts(item.color || "");
    return "rgba(" + (c[0] | 0) + "," + (c[1] | 0) + "," + (c[2] | 0) + ",0.92)";
  }
  function roundRect(x: number, y: number, w: number, h: number, r: number): void {
    rctx.beginPath(); rctx.moveTo(x + r, y);
    rctx.arcTo(x + w, y, x + w, y + h, r); rctx.arcTo(x + w, y + h, x, y + h, r);
    rctx.arcTo(x, y + h, x, y, r); rctx.arcTo(x, y, x + w, y, r);
    rctx.closePath();
  }

  function drawRadial(): void {
    rctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    const st = G.radialState, glass = radialGlass;
    const items = (st && st.items) || [];
    if (!st || !items.length) {
      glass.style.display = "none";
      drawPressRing();   // 盘没开时才画进度环（环展开成盘，两者互斥）
      return;
    }
    const c = pageToView(st.page, st.cx, st.cy), cx = c.x, cy = c.y;
    const n = items.length, step = 360 / n, gap = Math.min(RD.gap, step / 4);

    // 盘底 = 毛玻璃 div（含细亮边 + 投影），跟着盘心走；扇区/图标/hub 才画在 canvas 上。
    glass.style.left = (cx - RD.outer) + "px"; glass.style.top = (cy - RD.outer) + "px";
    glass.style.width = glass.style.height = (RD.outer * 2) + "px";
    glass.style.display = "block";

    // 扇区：整圆均分，第 0 项中心在正上方（12 点）顺时针；选中整块亮起。
    for (let i = 0; i < n; i++) {
      const on = st.highlight === i;
      const a0 = (i * step - step / 2 + gap - 90) * Math.PI / 180;
      const a1 = (i * step + step / 2 - gap - 90) * Math.PI / 180;
      rctx.beginPath();
      rctx.arc(cx, cy, RD.outer, a0, a1, false);
      rctx.arc(cx, cy, RD.inner, a1, a0, true);
      rctx.closePath();
      rctx.fillStyle = on ? tintOf(items[i]) : "rgba(0,0,0," + RD.wedgeDim + ")";
      rctx.fill();
      if (on) { rctx.strokeStyle = "rgba(255,255,255,0.65)"; rctx.lineWidth = 1.5; rctx.stroke(); }
      const ang = (i * step - 90) * Math.PI / 180, ir = (RD.inner + RD.outer) / 2;
      drawRadialIcon(cx + ir * Math.cos(ang), cy + ir * Math.sin(ang), items[i], on);
    }
    drawRadialHub(cx, cy, items[st.highlight]);
  }

  /// 中心 hub：既是取消区，也回显当前指向项（下发的 items 没有笔名，故显示笔型 + 粗细）。
  function drawRadialHub(cx: number, cy: number, sel: RadialItem | undefined): void {
    rctx.beginPath(); rctx.arc(cx, cy, RD.hub, 0, Math.PI * 2);
    rctx.fillStyle = "rgba(0,0,0," + (sel ? RD.hubDim : RD.hubDim + 0.06) + ")"; rctx.fill();
    rctx.strokeStyle = sel ? "rgba(255,255,255,0.2)" : "rgba(255,255,255,0.55)";
    rctx.lineWidth = sel ? 1 : 2; rctx.stroke();
    const title = sel ? (sel.kind === "pen" ? (BRUSH_LABELS[sel.t || ""] || "圆珠笔") : (TOOL_LABEL[sel.kind] || "")) : "取消";
    const sub = (sel && sel.kind === "pen") ? (Math.round((sel.w || 0) * 100) / 100) + "pt" : "";
    rctx.save();
    rctx.textAlign = "center"; rctx.textBaseline = "middle";
    rctx.shadowColor = "rgba(0,0,0,0.55)"; rctx.shadowBlur = 3; rctx.shadowOffsetY = 1;   // hub 底很淡，文字靠阴影保可读
    rctx.fillStyle = sel ? "#fff" : "rgba(255,255,255,0.85)";
    rctx.font = "600 13px -apple-system,'PingFang SC',system-ui,sans-serif";
    rctx.fillText(title, cx, sub ? cy - 7 : cy);
    if (sub) {
      rctx.fillStyle = "rgba(255,255,255,0.7)";
      rctx.font = "500 10px -apple-system,'PingFang SC',system-ui,sans-serif";
      rctx.fillText(sub, cx, cy + 8);
    }
    rctx.restore();
  }

  /// 扇区图标统一形制：一枚彩色圆片 + 符号（跟 Mac 端 `disc` 对齐）。
  /// 盘底透着页面内容，裸符号会被白页吞掉，所以每个图标都自带底片。
  function drawRadialIcon(x: number, y: number, item: RadialItem, on: boolean): void {
    const r = on ? 17 : 14;
    const isPen = item.kind === "pen";
    const fill = isPen ? (item.color || "#000") : tintOf(item);
    rctx.save();
    rctx.shadowColor = "rgba(0,0,0,0.3)"; rctx.shadowBlur = on ? 5 : 3; rctx.shadowOffsetY = 1;
    rctx.beginPath(); rctx.arc(x, y, r, 0, Math.PI * 2);
    rctx.fillStyle = fill; rctx.fill();
    rctx.restore();
    rctx.beginPath(); rctx.arc(x, y, r, 0, Math.PI * 2);
    rctx.strokeStyle = "rgba(255,255,255," + (on ? 0.9 : 0.55) + ")";
    rctx.lineWidth = on ? 2 : 1; rctx.stroke();

    rctx.save(); rctx.translate(x, y);
    rctx.fillStyle = isPen ? contrastOn(item.color || "") : "#fff";
    if (isPen) {                      // 笔尖剪影（笔杆 + 右端尖角），斜 45°
      rctx.rotate(-Math.PI / 4);
      const s = r * 0.62, w = r * 0.26;
      rctx.beginPath();
      rctx.moveTo(-s, -w); rctx.lineTo(s * 0.25, -w); rctx.lineTo(s, 0);
      rctx.lineTo(s * 0.25, w); rctx.lineTo(-s, w);
      rctx.closePath(); rctx.fill();
    } else if (item.kind === "erase") {
      rctx.rotate(-Math.PI / 5); rctx.scale(r / 17, r / 17);
      roundRect(-9, -5.5, 18, 11, 2.5); rctx.fill();
      rctx.strokeStyle = "rgba(0,0,0,0.3)"; rctx.lineWidth = 1.2;
      rctx.beginPath(); rctx.moveTo(-2, -5.5); rctx.lineTo(-2, 5.5); rctx.stroke();
    } else {                          // page：举起的手（掌 + 四指），对应 Mac 的 hand.raised.fill
      rctx.scale(r / 17, r / 17);
      roundRect(-6.5, -1, 13, 9.5, 3); rctx.fill();
      for (let f = 0; f < 4; f++) { roundRect(-6 + f * 3.2, -8.5, 2.4, 8.5, 1.2); rctx.fill(); }
    }
    rctx.restore();
  }

  // 跨模块调用面（input / ws / capture 经 G 调用）
  Object.assign(G, {
    relayout, recompute, locate, pageToView, inContent,
    drawAll, drawBg, drawInk, drawLive, eraseHit, ensureImages,
    clearHover, setRadial, setPressRing,
  });
}
