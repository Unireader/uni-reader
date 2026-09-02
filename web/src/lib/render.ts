// 渲染模块：画布尺寸/DPR、文档几何布局、坐标映射、页面/笔迹/悬停绘制、环形选笔盘 + 长按进度环。
// 逐行移植自原 capture.html IIFE 的对应段落（原文件已被本工程取代）。
// 注意：原版有一个定义了却从未调用的 drawHover()（本地悬停圆环），移植时按死代码丢弃——
// 悬停光标由 Mac 端画，平板只上报位置（见 input.ts reportHover）。
import { G, BAR, GAP, RD, PR, BRUSH_LABELS, clamp, pw, contentLeft, canvasLeft, contentW, cmargin,
         inkXMin, inkXMax, canvasMarginFor, curMode, strokeWidthFor, opacityMultFor, scaledColor } from "./shared.js";
import type { CaptureRefs, LassoSelection, RadialItem, RadialState, Stroke, TextNote, WireMsg } from "./shared.js";
import { updateHud, updateLassoStat } from "./hud.svelte.js";

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
    G.maxScrollX = Math.max(0, contentW() - G.vw);   // 画板模式下 fit 也有横向可滚（页两侧的页边）
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
  function loadImg(i: number): HTMLImageElement | null {
    if (G.imgs[i]) return G.imgs[i];
    if (i < 0 || i >= G.pageCount) return null;
    const im = new Image();
    im.onload = function () {
      drawBg();
      // 草稿纸的页面底图也可能在等这张图（它取的是**锚定页**，未必是可视页）——
      // 不在这儿补一刀，纸上那页就要等到下一次平移/缩放才冒出来。
      if (G.padActive && G.padActive()) G.drawScratch();
    };
    im.src = "/page.png?i=" + i + "&v=" + encodeURIComponent(G.docV);
    G.imgs[i] = im;
    return im;
  }

  // ---- 坐标映射（跨页 + 缩放）----
  /// `wide` = 画板模式下把 nx 放宽到页边（落墨/擦除/框选走这条）；默认页内，同 Mac
  /// `containerPointToPageNorm` 的 `xRange`（文字笔记等按页内 clamp 的路径不受影响）。
  function locate(x: number, vy: number, wide = false): { page: number; nx: number; ny: number } | null {
    const cl = contentLeft(), p = pw();
    const lo = wide ? inkXMin() : 0, hi = wide ? inkXMax() : 1;
    const docY = vy - BAR + G.scrollY;
    for (let i = 0; i < G.pageCount; i++) {
      if (docY >= G.offY[i] && docY <= G.offY[i] + G.dispH[i]) {
        return { page: i, nx: clamp((x - cl) / p, lo, hi), ny: clamp((docY - G.offY[i]) / G.dispH[i], 0, 1) };
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

  /// 框选移动专用：与 `locate` 不同，**不要求**命中某一页——超出锚定页的上/下边缘时 clamp 到
  /// 该页边缘（0/1），横向仍按当前内容宽折算。镜像 Mac 端 `finishLassoSelect` 对拖出页外终点的
  /// 处理（"跨页拖拽的终点 clamp 到该页边缘"），故框选/移动手势允许指针滑出锚定页而不中断。
  function pageLocClamped(x: number, y: number, page: number, wide = false): { nx: number; ny: number } {
    const cl = contentLeft(), p = pw();
    const nx = clamp((x - cl) / p, wide ? inkXMin() : 0, wide ? inkXMax() : 1);
    const docY = y - BAR + G.scrollY;
    const ny = docY < G.offY[page] ? 0
      : docY > G.offY[page] + G.dispH[page] ? 1
      : clamp((docY - G.offY[page]) / Math.max(1, G.dispH[page]), 0, 1);
    return { nx, ny };
  }

  /// 点在不规则多边形内（射线法，**与 Mac `InkEdit.pointInPolygon` 同一算法两份实现**，
  /// 改一边必须同步另一边）：poly 是扁平数组 [x0,y0,x1,y1,…]，首尾自动闭合；<3 点恒 false；边界算内。
  function pointInPolygon(px: number, py: number, poly: number[]): boolean {
    const n = poly.length / 2;
    if (n < 3) return false;
    let inside = false;
    let j = n - 1;
    for (let i = 0; i < n; i++) {
      const ax = poly[i * 2], ay = poly[i * 2 + 1], bx = poly[j * 2], by = poly[j * 2 + 1];
      const cross = (px - ax) * (by - ay) - (py - ay) * (bx - ax);
      if (Math.abs(cross) < 1e-9 &&
          px >= Math.min(ax, bx) - 1e-9 && px <= Math.max(ax, bx) + 1e-9 &&
          py >= Math.min(ay, by) - 1e-9 && py <= Math.max(ay, by) + 1e-9) return true;
      if ((ay > py) !== (by > py)) {
        const xInt = ax + (py - ay) / (by - ay) * (bx - ax);
        if (px < xInt) inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  /// 框选命中判定（本地复刻 Mac 端 `finishLassoSelect` 的算法：笔迹任一点落多边形内=命中，
  /// 注解锚点落多边形内=命中）：只用于渲染高亮预览，真正的判定在 Mac（见 PROTOCOL.md `lassoMove`）。
  function lassoHitTest(page: number, poly: number[]): LassoSelection | null {
    if (poly.length < 6) return null;
    // 🔴 包围盒初值取 ±Infinity 而不是页角 1/0：画板模式下笔迹/框选路径可以整个落在页外
    //（x 恒 > 1 或恒 < 0），按页角起算的话 `Math.min(1, 1.2)` 还是 1 —— 选中框的那条边就永远
    // 钉在页边上，框比笔迹大出一整片页边（用户 2026-08-30 在平板上报，安卓那份复刻同病同改）。
    let bx0 = Infinity, by0 = Infinity, bx1 = -Infinity, by1 = -Infinity;
    for (let i = 0; i + 1 < poly.length; i += 2) {
      bx0 = Math.min(bx0, poly[i]); bx1 = Math.max(bx1, poly[i]);
      by0 = Math.min(by0, poly[i + 1]); by1 = Math.max(by1, poly[i + 1]);
    }
    const strokeIdx: number[] = [], noteIdx: number[] = [];
    let lox = Infinity, loy = Infinity, hix = -Infinity, hiy = -Infinity;   // 同上，别按页角起算
    for (let i = 0; i < G.strokes.length; i++) {
      const s = G.strokes[i];
      if (s.page !== page) continue;
      let hit = false;
      for (let j = 0; j < s.pts.length; j++) {
        if (pointInPolygon(s.pts[j][0], s.pts[j][1], poly)) { hit = true; break; }
      }
      if (!hit) continue;
      strokeIdx.push(i);
      for (let j = 0; j < s.pts.length; j++) {
        const p = s.pts[j];
        lox = Math.min(lox, p[0]); loy = Math.min(loy, p[1]);
        hix = Math.max(hix, p[0]); hiy = Math.max(hiy, p[1]);
      }
    }
    for (let i = 0; i < G.notes.length; i++) {
      const n = G.notes[i];
      if (n.page !== page) continue;
      if (!pointInPolygon(n.nx, n.ny, poly)) continue;
      noteIdx.push(i);
      lox = Math.min(lox, n.nx); loy = Math.min(loy, n.ny);
      hix = Math.max(hix, n.nx); hiy = Math.max(hiy, n.ny);
    }
    if (!strokeIdx.length && !noteIdx.length) return null;
    return { page, box: [bx0, by0, bx1, by1], poly: poly.slice(), strokeIdx, noteIdx,
             bounds: [lox, loy, hix - lox, hiy - loy] };
  }

  /// 当前选中集的屏显框（视口 px，外扩 6 + 最小 16，**不含 ghost**）：drawLasso 渲染与 input.ts
  /// 手柄命中判定共用这一份，别各算各的（同 Mac `lassoDisplayBox` 的「一份真源」惯例）。
  function lassoViewBox(): { x: number; y: number; w: number; h: number } | null {
    const sel = G.lassoSelection;
    if (!sel) return null;
    const b = sel.bounds;
    const p0 = pageToView(sel.page, b[0], b[1]);
    const p1 = pageToView(sel.page, b[0] + b[2], b[1] + b[3]);
    const pad = 6;
    const x = Math.min(p0.x, p1.x) - pad, y = Math.min(p0.y, p1.y) - pad;
    const w = Math.max(Math.abs(p1.x - p0.x) + pad * 2, 16), h = Math.max(Math.abs(p1.y - p0.y) + pad * 2, 16);
    return { x, y, w, h };
  }

  /// 清掉框选的全部瞬态状态（切走工具/Esc/两条镜像都回传时调用）。
  function clearLasso(): void {
    if (G.lassoPendingTimer) { clearTimeout(G.lassoPendingTimer); G.lassoPendingTimer = null; }
    G.lassoSelection = null; G.lassoDragMode = null; G.lassoMoved = false;
    updateLassoStat();   // 顶栏剪切/复制按钮跟着灰掉
    G.lassoPath = null; G.lassoAnchor = null; G.lassoCommitted = false;
    G.lassoSyncStrokes = false; G.lassoSyncNotes = false;
    G.lassoHandle = null; G.lassoScale = null;
    G.lassoTranslate = { dx: 0, dy: 0 };
    drawInk(); drawNotes();
  }

  // ---- 绘制 ----
  /// 滚动/缩放每帧都走这里：四个全屏 canvas 全部 clear + 重绘。分层计时见 G.drawBgMs 的注释。
  function drawAll(): void {
    const t0 = performance.now();
    drawBg();
    const t1 = performance.now();
    drawInk();
    const t2 = performance.now();
    drawLive(); drawNotes();
    G.drawN++; G.drawBgMs += t1 - t0; G.drawInkMs += t2 - t1; G.drawRestMs += performance.now() - t2;
  }
  function drawBg(): void {
    bctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    const cl = contentLeft(), p = pw();
    // 画板模式：白纸连同两侧页边一起铺（同 Mac `PageCellView.wide`——页边是「同一页的横向延伸」，
    // 不是另一块灰底）。页图仍只占中间那 p 宽。
    const wl = canvasLeft(), ww = contentW();
    for (let i = 0; i < G.pageCount; i++) {
      const vy = BAR + G.offY[i] - G.scrollY;
      if (vy + G.dispH[i] < BAR || vy > window.innerHeight) continue;
      bctx.fillStyle = "#fff"; bctx.fillRect(wl, vy, ww, G.dispH[i]);
      if (!G.showPage) continue;   // 手写板模式：仅白底，不取图
      const im = G.imgs[i];
      if (im && im.complete && im.naturalWidth) bctx.drawImage(im, cl, vy, p, G.dispH[i]);
      else { bctx.fillStyle = "#e9edf2"; bctx.fillRect(cl, vy, p, G.dispH[i]); loadImg(i); }
    }
  }
  /// 一条笔迹已构建好的几何。路径建在**页局部坐标**（原点＝该页左上角，单位 CSS px，随缩放变），
  /// 画的时候只 `translate` 到该页当前位置——于是滚动不改变任何几何，Path2D 原样复用。
  interface InkSeg { w: number; path: Path2D; fill?: boolean }
  interface InkGeom { pw: number; color: string; multiply: boolean; segs: InkSeg[] }

  /// 内容 → 几何。用 WeakMap：Mac 每次回传 strokes 都是新解码的对象，旧条目自动被 GC 收走，
  /// 不必自己管失效；滚动期间对象不变，所以命中率是 100%。
  const geomCache = new WeakMap<Stroke, InkGeom>();

  /// 构建几何（页局部坐标）。**不碰 canvas**，纯算——这样它既能进缓存，也能给活体层每帧现算。
  function buildGeom(s: Stroke): InkGeom {
    const p = pw(), ph = G.dispH[s.page] || 0;
    // x 放宽到页边（画板模式）：几何仍是页局部坐标，负值/超 1 的点自然落到页外那片空白上。
    // **不能靠 clamp 收边**——那会把页外的笔迹压成页边一条竖线；画不画得出来由 `clipContent` 裁。
    return buildGeomWith(s,
      (i) => clamp(s.pts[i][0], inkXMin(), inkXMax()) * p,
      (i) => clamp(s.pts[i][1], 0, 1) * ph,
      1, p);
  }

  /// 画板模式变更。`on` 变了 = Mac 那边切了开关 → **把页面摆回视口正中**（同 Mac `canvasModeChanged`
  /// 的 recenter）；只有 `margin` 变 = 软边界跳了一档 → **零位移补偿**（内容宽增量的一半，页面在
  /// 屏幕上纹丝不动，否则写字时页面在笔下平移）。两种口径与 Mac 端一一对应。
  function setCanvas(on: boolean, margin: number): void {
    const changedOn = G.canvasOn !== on;
    const oldW = contentW();
    G.canvasOn = on;
    G.canvasMargin = Math.max(0, margin);
    recompute();
    G.scrollX = changedOn ? clamp(cmargin() * pw() + (pw() - G.vw) / 2, 0, G.maxScrollX)
                          : clamp(G.scrollX + (contentW() - oldW) / 2, 0, G.maxScrollX);
    G.scrollY = clamp(G.scrollY, 0, G.maxScrollY);
    ensureImages(); drawAll(); updateHud();
  }

  /// 落笔中的乐观跳档（档位公式与 Mac `CanvasMargin` 同一组常数）：写到离页边不足 slack
  /// 就本地先放宽一档，不然要等一个 RTT 才有地方下笔。**只增不减**，Mac 的下发值一到即以它为准。
  function growCanvas(nx: number): void {
    if (!G.canvasOn) return;
    const over = nx < 0 ? -nx : (nx > 1 ? nx - 1 : 0);
    const want = canvasMarginFor(over);
    if (want > G.canvasMargin) setCanvas(true, want);
  }

  /// 真源回推的笔迹越出了当前页边 → 本地先放宽一档（**只增不减**，Mac 随后下发的值仍是权威）。
  /// 少了这一步就是「框选把笔迹移到页边深处，平板上看到笔迹挤成一条」——**本端渲染是按当前页边
  /// clamp 的**（`drawStroke` 里的 `inkXMin()/inkXMax()`），数据对了、档位没跟上照样画成一条竖线。
  /// Mac 的 `canvas` 是另一条独立广播，到达有先后，中间那一拍屏幕上就是错的（同安卓 `growCanvasFor`）。
  function growCanvasForStrokes(): void {
    if (!G.canvasOn) return;
    let over = 0;
    for (const s of G.strokes) {
      for (const p of s.pts) {
        const o = p[0] < 0 ? -p[0] : (p[0] > 1 ? p[0] - 1 : 0);
        if (o > over) over = o;
      }
    }
    const want = canvasMarginFor(over);
    if (want > G.canvasMargin) setCanvas(true, want);
  }

  /// 把一层墨迹裁到「内容宽」（页 + 两侧页边）。画板一关，页外的笔迹就该看不见——数据还在，
  /// 只是没地方画了（同 Mac：`PageCellView` 的墨迹 Canvas 只有页宽，越界部分被裁）。
  /// 整层裁一次，不是每笔裁一次。
  function clipContent(cx: CanvasRenderingContext2D): void {
    cx.beginPath();
    cx.rect(canvasLeft(), 0, contentW(), window.innerHeight);
    cx.clip();
  }

  /// 同上，但**坐标映射与线宽倍率由调用方给**。草稿纸走这条：它的点是画布坐标（逻辑 px，可负无界），
  /// 映射 = `点 × zoom`、`wScale = zoom`（无限画布上放大就该连笔迹一起放大）。
  /// 拆出来的唯一目的是让四种笔型的几何**一份实现两处用**，别再抄一遍（抄一遍就会分叉）。
  /// `key` 存进 `InkGeom.pw` 作缓存失效键（页笔迹用页宽，草稿纸用 zoom）。
  function buildGeomWith(s: Stroke, px: (i: number) => number, py: (i: number) => number,
                         wScale: number, key: number): InkGeom {
    const pts = s.pts;
    const t = s.pen.t || "ballpoint";
    const color = scaledColor(s.pen.color, opacityMultFor(t));
    const p = key;
    const segs: InkSeg[] = [];

    if (pts.length === 1) {   // 单点 = 一个圆点（同 Mac 端单点分支）
      const path = new Path2D();
      path.arc(px(0), py(0), strokeWidthFor(t, pts[0][2], s.pen.w) * wScale / 2, 0, Math.PI * 2);
      segs.push({ w: 0, path, fill: true });
      return { pw: p, color, multiply: false, segs };
    }

    let lx = px(0), ly = py(0);
    if (t === "marker") {
      // marker 必须**整条一次成 path**（平头 + multiply）：逐段 stroke 会让相邻段的线帽互相重叠，
      // 不透明笔看不出来，半透明的荧光笔就叠成一串圆斑。
      const path = new Path2D();
      path.moveTo(lx, ly);
      for (let i = 1; i < pts.length; i++) {
        const qx = px(i), qy = py(i);
        path.quadraticCurveTo(lx, ly, (lx + qx) / 2, (ly + qy) / 2);
        lx = qx; ly = qy;
      }
      path.lineTo(lx, ly);   // 补末段（同下方分支：中点平滑链止于倒数两点的中点）
      segs.push({ w: s.pen.w * wScale, path });
      return { pw: p, color, multiply: true, segs };
    }

    // ballpoint / fountain / pencil：线宽随压感变，没法像 marker 那样整条一次 stroke。
    // 但**相邻的、宽度差不多的段可以攒进同一条 Path2D**：它们本就首尾相接（都经过中点），
    // 攒起来不改变形状，一条 50 点的笔迹于是从 50 次 stroke 降到个位数。
    // 合并顺带修掉一个观感 bug：逐段各自半透明合成会让相邻段共享的圆头越叠越黑（Mac 端记的
    // 「黑点瑕疵」根因，那边已改成整条一次 fill），攒进同一条路径后不再重复合成。
    // 断开用**迟滞**而不是绝对分桶：压感几乎每点都在抖，按固定档位会断得比不合并还碎。
    const dot = new Path2D();
    dot.arc(lx, ly, strokeWidthFor(t, pts[0][2], s.pen.w) * wScale / 2, 0, Math.PI * 2);
    segs.push({ w: 0, path: dot, fill: true });   // 起笔圆点

    let lastMidX = lx, lastMidY = ly, curW = -1;
    let cur: Path2D | null = null;
    const openAt = (w: number): void => {
      cur = new Path2D();
      cur.moveTo(lastMidX, lastMidY);
      curW = w;
      segs.push({ w, path: cur });
    };
    const needsBreak = (w: number): boolean => cur === null || Math.abs(w - curW) > Math.max(0.35, curW * 0.08);
    for (let i = 1; i < pts.length; i++) {
      const qx = px(i), qy = py(i);
      const w = strokeWidthFor(t, pts[i][2], s.pen.w) * wScale;
      if (needsBreak(w)) openAt(w);
      const mx = (lx + qx) / 2, my = (ly + qy) / 2;
      cur!.quadraticCurveTo(lx, ly, mx, my);
      lastMidX = mx; lastMidY = my; lx = qx; ly = qy;
    }
    // 补末段：上面每步只画到「相邻两点的中点」，末点从来没被连上——长笔画差这半段看不出来，
    // 两点直线（尺子）就是整整少画一半（线尾追不上笔尖）。补一段 lastMid → 末点才落到笔尖。
    const lastW = strokeWidthFor(t, pts[pts.length - 1][2], s.pen.w) * wScale;
    if (needsBreak(lastW)) openAt(lastW);
    cur!.lineTo(lx, ly);
    return { pw: p, color, multiply: false, segs };
  }

  /// 把几何画到指定 context：只 translate 到该页当前位置，不重算任何坐标。
  function paintGeom(cx: CanvasRenderingContext2D, s: Stroke, g: InkGeom): void {
    paintGeomAt(cx, g, contentLeft(), BAR + G.offY[s.page] - G.scrollY);
  }

  /// 把几何画到指定 context 的指定平移处（页笔迹平移到页左上角，草稿纸平移到 `−视口原点×zoom`）。
  function paintGeomAt(cx: CanvasRenderingContext2D, g: InkGeom, tx: number, ty: number): void {
    cx.save();
    cx.translate(tx, ty);
    if (g.multiply) { cx.globalCompositeOperation = "multiply"; cx.lineCap = "square"; }
    cx.strokeStyle = g.color; cx.fillStyle = g.color;
    for (let i = 0; i < g.segs.length; i++) {
      const seg = g.segs[i];
      if (seg.fill) { cx.fill(seg.path); } else { cx.lineWidth = seg.w; cx.stroke(seg.path); }
    }
    cx.restore();
  }

  /// 静态层用：走几何缓存（滚动时零重建、零临时对象）。缩放会改页尺寸，故 pw 变了要重建。
  function drawStroke(cx: CanvasRenderingContext2D, s: Stroke): void {
    if (!s.pts.length || s.page < 0 || s.page >= G.pageCount) return;
    let g = geomCache.get(s);
    if (!g || g.pw !== pw()) { g = buildGeom(s); geomCache.set(s, g); }
    paintGeom(cx, s, g);
  }

  /// 活体层 / 框选预览用：几何每帧都在变，进缓存只会让 WeakMap 一直堆新条目，所以现算不存。
  /// 走的是与静态层同一个 [buildGeom]，两者观感因此一致。
  function drawStrokeLive(cx: CanvasRenderingContext2D, s: Stroke): void {
    if (!s.pts.length || s.page < 0 || s.page >= G.pageCount) return;
    paintGeom(cx, s, buildGeom(s));
  }

  /// 这一页有没有落在视口里。`G.strokes`/`G.notes` 都是**全文档**的，不裁页就是每帧把全书重画一遍。
  function pageVisible(page: number): boolean {
    if (page < 0 || page >= G.pageCount) return false;
    const y = BAR + G.offY[page] - G.scrollY;
    return y + G.dispH[page] >= BAR && y <= window.innerHeight;
  }
  /// 静态层：已成形的笔迹（Mac 回传的唯一真源）。
  /// 框选移动/缩放已提交（`lassoCommitted`）、等 Mac 回传新 strokes 期间：被选中的笔迹按提交量乐观渲染，
  /// 避免「松手瞬间弹回原位、新 strokes 到达才跳到新位置」的闪烁——数据本身不动，只是画的时候偏一下。
  /// strokes 镜像一到（`lassoSyncStrokes`）即改画真源（乐观只作用于还没到的层，两条镜像分开记账）。
  function drawInk(): void {
    ictx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    ictx.save(); clipContent(ictx);
    drawInkClipped();
    ictx.restore();
  }
  function drawInkClipped(): void {
    const sel = (G.lassoCommitted && !G.lassoSyncStrokes) ? G.lassoSelection : null;
    const xf = sel ? lassoXform(false) : null;
    const wScale = sel && G.lassoScale ? Math.sqrt(G.lassoScale.sx * G.lassoScale.sy) : 1;   // 线宽同步（同 Mac InkEdit.scaled）
    for (let i = 0; i < G.strokes.length; i++) {
      const s = G.strokes[i];
      if (!pageVisible(s.page)) continue;   // 全文档笔迹，裁到可见页（见 pageVisible）
      if (sel && xf && sel.page === s.page && sel.strokeIdx.indexOf(i) >= 0) {
        // 变换**逐点 clamp 到页内**（同 Mac `InkEdit.translated/scaled`）——所以不能拿 translate 顶替，
        // 几何是真的变了；走不进缓存的 live 版，反正框选拖动是低频且短暂的。
        drawStrokeLive(ictx, { page: s.page, pen: { color: s.pen.color, w: s.pen.w * wScale, t: s.pen.t },
                               pts: s.pts.map((p) => { const q = xf(p[0], p[1]); return [q[0], q[1], p[2]]; }) });
      } else {
        drawStroke(ictx, s);
      }
    }
  }
  /// 活体层：正在写的这一笔，**每次落点整条重画**（不往已有像素上增量叠加，否则半透明笔会累积出圆斑）。
  /// 与 Mac 端 `InkLiveLayer` 同构；单独一层，故重画一笔不牵动整页笔迹。
  function drawLive(): void {
    lctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    if (!G.cur) return;
    lctx.save(); clipContent(lctx);
    drawStrokeLive(lctx, G.cur);
    lctx.restore();
  }

  /// 擦除分派（与 Mac 端 `eraseNear` 两模式一一对应，命中判定都在页内归一化坐标做、同页过滤、
  /// loc 为空不擦——两端乐观/真源语义保持一致）：
  /// - 整笔（G.eraserMode === 0）：任一点命中即删整条（对应 Mac 的 removeAll 分支）；
  /// - 局部（=== 1）：与 Mac 端 `InkEdit.splitStroke` 是**同一算法两份实现**，改一边必须同步另一边。
  /// 半径 G.eraserSize 是页宽比，x 向折算 = eraserSize × 当前页显示宽 CSS px。
  function eraseHit(x: number, y: number): void {
    const loc = locate(x, y, true);   // 页边的笔迹也要能擦到（画板模式）
    if (!loc) return;
    const r2 = G.eraserSize * G.eraserSize;
    if (G.eraserMode === 0) {   // 整笔
      let changed = false;
      for (let i = G.strokes.length - 1; i >= 0; i--) {
        const s = G.strokes[i];
        if (s.page !== loc.page) continue;
        for (let j = 0; j < s.pts.length; j++) {
          const dx = s.pts[j][0] - loc.nx, dy = s.pts[j][1] - loc.ny;
          if (dx * dx + dy * dy <= r2) { G.strokes.splice(i, 1); changed = true; break; }
        }
      }
      if (changed) drawInk();
      return;
    }
    // 局部：剔除命中点，连续未命中段各成新笔迹（空 = 整笔消除）
    let changed = false;
    const out: Stroke[] = [];
    for (let i = 0; i < G.strokes.length; i++) {
      const s = G.strokes[i];
      if (s.page !== loc.page) { out.push(s); continue; }
      let anyHit = false;
      let seg: [number, number, number][] = [];
      const flush = function (): void { if (seg.length) { out.push({ page: s.page, pen: s.pen, pts: seg }); seg = []; } };
      for (let j = 0; j < s.pts.length; j++) {
        const pt = s.pts[j], dx = pt[0] - loc.nx, dy = pt[1] - loc.ny;
        if (dx * dx + dy * dy <= r2) { anyHit = true; flush(); }
        else seg.push(pt);
      }
      if (anyHit) { flush(); changed = true; }   // 命中过：原笔迹被切段结果替换（可能为空 = 整笔消除）
      else out.push(s);                          // 零命中：原样保留（对应 Swift 的 anyHit ? out : [s]）
    }
    if (changed) { G.strokes = out; drawInk(); }
  }

  // ---- 悬停 + 文字笔记标记 + 橡皮尺寸圆环（共用 hover canvas 层）----
  // 本地悬停圆环已在移植时按死代码丢弃（光标本体由 Mac 画），hover 层现在承载笔记标记 + 橡皮尺寸圆环；
  // clearHover 仍由悬停收尾链路调用，故改为重画整层而不是直接清空（否则悬停结束会抹掉标记）。
  function clearHover(): void { drawNotes(); }

  /// 文字笔记标记：圆形底片 + 首字符（形制呼应环形盘图标），位置 pageToView 映射，半径随页宽夹取。
  /// 配色日间/夜间通用（夜间只反转 bg canvas，蓝底白边在深浅页面上都可读，与环形盘图标同理）。
  function drawNotes(): void {
    hctx.clearRect(0, 0, window.innerWidth, window.innerHeight);
    const r = noteMarkerRadius();
    hctx.save();
    hctx.textAlign = "center"; hctx.textBaseline = "middle";
    hctx.font = "600 " + Math.round(r * 0.9) + "px -apple-system,'PingFang SC',system-ui,sans-serif";
    for (let i = 0; i < G.notes.length; i++) {
      const n = G.notes[i];
      const v = noteViewPos(i);
      if (v.y < BAR - r || v.y > window.innerHeight + r || v.x < -r || v.x > window.innerWidth + r) continue;
      hctx.save();
      hctx.shadowColor = "rgba(0,0,0,0.3)"; hctx.shadowBlur = 3; hctx.shadowOffsetY = 1;
      hctx.beginPath(); hctx.arc(v.x, v.y, r, 0, Math.PI * 2);
      hctx.fillStyle = "rgba(31,111,235,0.92)"; hctx.fill();
      hctx.restore();
      hctx.beginPath(); hctx.arc(v.x, v.y, r, 0, Math.PI * 2);
      hctx.strokeStyle = "rgba(255,255,255,0.85)"; hctx.lineWidth = 1.5; hctx.stroke();
      hctx.fillStyle = "#fff";
      hctx.fillText((n.text || "T").charAt(0), v.x, v.y);
    }
    hctx.restore();
    drawNoteBubbles();
    drawPadPins();
    // 橡皮尺寸圆环（擦除模式 + 开关开 + 有笔尖位置）：直径 = 2×G.eraserSize×当前页显示宽。
    // 双描边（外暗内亮）保证在白页/夜间反转页上都可读；位置由 input.ts 在 hover/擦除拖动时维护。
    if (G.eraserRing && G.eraserRingAt && curMode() === "erase") {
      const rr = G.eraserSize * pw();
      hctx.beginPath(); hctx.arc(G.eraserRingAt.x, G.eraserRingAt.y, rr, 0, Math.PI * 2);
      hctx.strokeStyle = "rgba(0,0,0,0.5)"; hctx.lineWidth = 3; hctx.stroke();
      hctx.strokeStyle = "rgba(255,255,255,0.9)"; hctx.lineWidth = 1.5; hctx.stroke();
    }
    drawLasso();
  }

  /// 笔记标记半径（视口 px）：随页宽走但夹取，缩得再小也点得着（同草稿纸图钉的口径）。
  function noteMarkerRadius(): number { return clamp(pw() * 0.02, 12, 22); }

  /// 一条笔记标记此刻的视口坐标：**框选提交后等回传期间**要跟着乐观变换走（同笔迹层的口径），
  /// 标记绘制 / 气泡布局 / 命中判定三处共用这一份，别各算各的（画到哪儿就该点到哪儿）。
  function noteViewPos(i: number): { x: number; y: number } {
    const n = G.notes[i];
    const sel = (G.lassoCommitted && !G.lassoSyncNotes) ? G.lassoSelection : null;
    const xf = sel ? lassoXform(false) : null;
    let nnx = n.nx, nny = n.ny;
    if (sel && xf && sel.page === n.page && sel.noteIdx.indexOf(i) >= 0) {
      const q = xf(nnx, nny); nnx = q[0]; nny = q[1];
    }
    return pageToView(n.page, nnx, nny);
  }

  // ---- 文字笔记展开气泡（每条笔记自己的 display：0=点击 1=悬浮 2=始终）----
  // 🔴 尺寸全部是**页宽的比例**（用户拍板「跟页缩放」），这套比例常数与 Mac `NoteBubble`、
  // 安卓 `PadOverlays` 各存一份，改一处必须同步另外两处。折行各端用各自的排版引擎，允许细微差异。
  const BUB = { w: 0.30, fs: 0.022, lh: 1.35, pad: 0.55, radius: 0.5, gap: 0.25, edit: 1.7,
                icon: 0.78, maxLines: 10 };

  /// 这条笔记此刻要不要展开：空正文永不展开（没有可看的东西）。
  /// `hover` 模式在触摸端没有笔悬停时**降级为点击展开**（手指点一下也进 noteExpanded）。
  function noteBubbleOn(n: TextNote): boolean {
    if (!n.text) return false;
    if (n.display === 2) return true;
    if (n.display === 1) return G.noteHover === n.id || G.noteExpanded.indexOf(n.id) >= 0;
    return G.noteExpanded.indexOf(n.id) >= 0;
  }

  /// 常驻气泡（点开的 / 始终展示的）才画铅笔：笔悬停的那只是只读预览，鼠标一离开图钉就收了，
  /// 那颗按钮够不着（与 Mac `NoteBubbleView.onEdit == nil` 同一条判据）。
  function noteBubbleSticky(n: TextNote): boolean {
    return n.display === 2 || G.noteExpanded.indexOf(n.id) >= 0;
  }

  /// 正文折行：canvas 不会自动折行，逐字符塞（中英混排一律按字符宽度累加，够用）。
  /// 超过 maxLines 就在末行加省略号——一条笔记不该糊住半页，全文去编辑器里看。
  function wrapNoteText(text: string, maxW: number): string[] {
    const out: string[] = [];
    const paras = text.split("\n");
    let truncated = false;
    for (let p = 0; p < paras.length && !truncated; p++) {
      let line = "";
      const s = paras[p];
      for (let i = 0; i < s.length; i++) {
        const t = line + s[i];
        if (line && hctx.measureText(t).width > maxW) {
          out.push(line); line = s[i];
          if (out.length >= BUB.maxLines) { truncated = true; break; }
        } else line = t;
      }
      if (truncated) break;         // 段落没排完就满了
      out.push(line);
      if (out.length >= BUB.maxLines && p < paras.length - 1) truncated = true;
    }
    if (truncated && out.length) {
      const last = out[out.length - 1];
      out[out.length - 1] = last.slice(0, Math.max(0, last.length - 1)) + "…";
    }
    return out;
  }

  /// 气泡布局（视口 px）：图钉右侧优先、放不下翻左侧，再整体钳进**该页**的显示矩形内
  /// （位置规则与 Mac `NoteBubbleView.origin` 一致）。返回 null = 这条此刻不画。
  function noteBubbleBox(i: number): {
    x: number; y: number; w: number; h: number; fs: number; pad: number;
    edit: number; lines: string[]; sticky: boolean;
  } | null {
    const n = G.notes[i];
    if (!noteBubbleOn(n) || !pageVisible(n.page)) return null;
    const W = pw();
    const fs = W * BUB.fs, w = W * BUB.w, pad = fs * BUB.pad;
    const sticky = noteBubbleSticky(n);
    const edit = sticky ? fs * BUB.edit : 0;
    hctx.save();
    hctx.font = Math.round(fs) + "px -apple-system,'PingFang SC',system-ui,sans-serif";
    const lines = wrapNoteText(n.text, Math.max(fs, w - pad * 2 - edit));
    hctx.restore();
    const h = pad * 2 + lines.length * fs * BUB.lh;
    const v = noteViewPos(i), r = noteMarkerRadius(), gap = fs * BUB.gap;
    const p0 = pageToView(n.page, 0, 0), p1 = pageToView(n.page, 1, 1);
    let x = v.x + r + gap;
    if (x + w > p1.x) x = v.x - r - gap - w;
    const y = v.y - r;
    return {
      x: clamp(x, p0.x, Math.max(p0.x, p1.x - w)),
      y: clamp(y, p0.y, Math.max(p0.y, p1.y - h)),
      w: w, h: h, fs: fs, pad: pad, edit: edit, lines: lines, sticky: sticky,
    };
  }

  /// 画全部展开着的气泡（在标记之上、草稿纸图钉之下）。纸白底 + 发丝描边 + 深灰字，
  /// **无投影无渐变**（红线：不做拟物），夜间只反转页图那一层故气泡照旧可读。
  function drawNoteBubbles(): void {
    if (!G.notes.length) return;
    for (let i = 0; i < G.notes.length; i++) {
      const b = noteBubbleBox(i);
      if (!b) continue;
      const rad = Math.min(b.fs * BUB.radius, b.w / 2, b.h / 2);
      hctx.save();
      roundRectPath(hctx, b.x, b.y, b.w, b.h, rad);
      hctx.fillStyle = "rgba(255,253,242,0.97)"; hctx.fill();
      hctx.strokeStyle = "rgba(0,0,0,0.18)"; hctx.lineWidth = 1; hctx.stroke();
      hctx.textAlign = "left"; hctx.textBaseline = "top";
      hctx.font = Math.round(b.fs) + "px -apple-system,'PingFang SC',system-ui,sans-serif";
      hctx.fillStyle = "#1f1f21";
      for (let k = 0; k < b.lines.length; k++) {
        hctx.fillText(b.lines[k], b.x + b.pad, b.y + b.pad + k * b.fs * BUB.lh + b.fs * 0.15);
      }
      if (b.sticky) {   // 右上角铅笔（热区 = 这块方形，见 noteEditHit）
        const s = b.edit * BUB.icon;
        drawEditIcon(hctx, b.x + b.w - b.edit / 2 - b.pad * 0.4 - s / 2,
                     b.y + b.edit / 2 + b.pad * 0.4 - s / 2, s, "rgba(0,0,0,0.55)");
      }
      hctx.restore();
    }
  }

  /// 笔记标记命中 → 那条笔记（没命中 null）。热区比画出来的略大，同草稿纸图钉。
  function noteMarkerHit(x: number, y: number): TextNote | null {
    const r = noteMarkerRadius(), hot = Math.max(r + 6, 22);
    for (let i = G.notes.length - 1; i >= 0; i--) {
      const n = G.notes[i];
      if (!pageVisible(n.page)) continue;
      const v = noteViewPos(i);
      if (Math.abs(x - v.x) <= hot && Math.abs(y - v.y) <= hot) return n;
    }
    return null;
  }

  /// 「编辑」图标（**画出来的，不用字符**）：`✎` 这种字形随系统字体走，各机器长得都不一样、基线还飘。
  /// 形状照 macOS 的 SF Symbol `square.and.pencil`：**右上角开口的圆角方框 + 斜插出去的铅笔**——
  /// 裸铅笔在这个尺寸下读起来就是一道斜杠（2026-08-27 用户报「有点丑」）。
  /// 坐标是 24 网格 ÷ 24；安卓 `PadOverlays.drawEditIcon` 是同一组数，**改一边必须同步另一边**。
  // 24 网格坐标（内容 4.5~21，与 SF 的视觉大小对齐）：方框圆角 3、描边 2；铅笔沿 45° 斜插出右上角缺口。
  const EDIT_SHAFT = [[19.08, 3.08], [20.92, 4.92], [14.92, 10.92], [13.08, 9.08]];
  const EDIT_TIP = [[13.08, 9.08], [14.92, 10.92], [12.44, 11.56]];

  function drawEditIcon(cx: CanvasRenderingContext2D, x: number, y: number,
                        s: number, color: string): void {
    const u = s / 24;
    const P = (a: number, b: number): [number, number] => [x + a * u, y + b * u];
    const r = 3;
    cx.save();
    cx.strokeStyle = color;
    cx.fillStyle = color;
    cx.lineWidth = Math.max(1, 2 * u);
    cx.lineJoin = "round"; cx.lineCap = "round";
    // 方框：右上角开口（缺口留给铅笔），另三角圆角
    cx.beginPath();
    cx.moveTo(...P(14, 4.5));
    cx.lineTo(...P(4.5 + r, 4.5));
    cx.quadraticCurveTo(...P(4.5, 4.5), ...P(4.5, 4.5 + r));
    cx.lineTo(...P(4.5, 19.5 - r));
    cx.quadraticCurveTo(...P(4.5, 19.5), ...P(4.5 + r, 19.5));
    cx.lineTo(...P(19.5 - r, 19.5));
    cx.quadraticCurveTo(...P(19.5, 19.5), ...P(19.5, 19.5 - r));
    cx.lineTo(...P(19.5, 10));
    cx.stroke();
    // 铅笔：笔杆 + 笔尖（填充，小尺寸下比描边清楚）
    for (const poly of [EDIT_SHAFT, EDIT_TIP]) {
      cx.beginPath();
      cx.moveTo(...P(poly[0][0], poly[0][1]));
      for (let i = 1; i < poly.length; i++) cx.lineTo(...P(poly[i][0], poly[i][1]));
      cx.closePath();
      cx.fill();
    }
    cx.restore();
  }

  /// 气泡右上角铅笔命中 → 那条笔记（没命中 null）：点它进编辑器。
  function noteEditHit(x: number, y: number): TextNote | null {
    for (let i = G.notes.length - 1; i >= 0; i--) {
      const b = noteBubbleBox(i);
      if (!b || !b.sticky) continue;
      const ex = b.x + b.w - b.edit - b.pad * 0.4, ey = b.y + b.pad * 0.4;
      if (x >= ex && x <= ex + b.edit && y >= ey && y <= ey + b.edit) return G.notes[i];
    }
    return null;
  }

  /// 草稿纸图钉：标记「这张纸是在页面的哪儿建的」，手指单击即打开那张纸（见 input.ts endTouch）。
  /// 与文字笔记标记同层（hover canvas）同套路，只是换个形状与配色以便一眼分得清：
  /// 笔记是圆形蓝底 + 首字，草稿纸是**圆角方片 + 折角**（呼应「一张纸」）。
  /// 图钉当前显示位置：拖动中 / 松手后等 `scratchpads` 回推期间用乐观位置（pinGhost），
  /// 其余时间用 Mac 下发的真源坐标。绘制与命中判定共用，保证点到的就是看到的。
  function padPinPos(i: number): { nx: number; ny: number } {
    const gh = G.pinGhost;
    if (gh && gh.index === i) return gh;
    return G.pads[i];
  }

  function drawPadPins(): void {
    if (!G.pads.length) return;
    const r = padPinRadius();
    hctx.save();
    for (let i = 0; i < G.pads.length; i++) {
      const p = G.pads[i];
      if (!pageVisible(p.page)) continue;
      const pos = padPinPos(i);
      const v = pageToView(p.page, pos.nx, pos.ny);
      if (v.y < BAR - r || v.y > window.innerHeight + r || v.x < -r || v.x > window.innerWidth + r) continue;
      const on = i === G.padOpen;
      hctx.save();
      hctx.shadowColor = "rgba(0,0,0,0.3)"; hctx.shadowBlur = 3; hctx.shadowOffsetY = 1;
      roundRectPath(hctx, v.x - r, v.y - r, r * 2, r * 2, r * 0.34);
      hctx.fillStyle = on ? "rgba(31,111,235,0.95)" : "rgba(246,248,252,0.96)";
      hctx.fill();
      hctx.restore();
      roundRectPath(hctx, v.x - r, v.y - r, r * 2, r * 2, r * 0.34);
      hctx.strokeStyle = on ? "rgba(255,255,255,0.9)" : "rgba(31,111,235,0.85)";
      hctx.lineWidth = 1.5; hctx.stroke();
      // 纸上的两道「字迹」——比放个字母更像草稿纸，也不必care字体度量
      hctx.strokeStyle = on ? "rgba(255,255,255,0.95)" : "rgba(31,111,235,0.9)";
      hctx.lineWidth = Math.max(1.2, r * 0.14);
      hctx.beginPath();
      hctx.moveTo(v.x - r * 0.45, v.y - r * 0.18); hctx.lineTo(v.x + r * 0.45, v.y - r * 0.18);
      hctx.moveTo(v.x - r * 0.45, v.y + r * 0.28); hctx.lineTo(v.x + r * 0.1, v.y + r * 0.28);
      hctx.stroke();
    }
    hctx.restore();
  }

  /// 图钉半径（视口 px）：随页宽走但夹取，缩得再小也点得着。
  function padPinRadius(): number { return clamp(pw() * 0.016, 11, 18); }

  /// 图钉命中判定 → 草稿纸下标；没命中 -1。热区比画出来的略大（触摸目标不小于 ~44px 见方）。
  function padPinHit(x: number, y: number): number {
    if (!G.pads.length) return -1;
    const r = padPinRadius(), hot = Math.max(r + 6, 22);
    for (let i = G.pads.length - 1; i >= 0; i--) {   // 后建的压在上面，命中也先算它
      const p = G.pads[i];
      if (!pageVisible(p.page)) continue;
      const pos = padPinPos(i);
      const v = pageToView(p.page, pos.nx, pos.ny);
      if (Math.abs(x - v.x) <= hot && Math.abs(y - v.y) <= hot) return i;
    }
    return -1;
  }

  /// 选中集点变换（页内归一化，clamp 0...1）：move = 平移、scale = 绕锚点按轴缩放（镜像 Mac
  /// `lassoGhostPoint` 语义——数据不动，画的时候偏）。`includeDrag`=true 时拖动中的 ghost 也算
  /// （halo/框/手柄用）；=false 只在已提交（等回传）时给（笔迹/笔记的乐观渲染，同旧 lassoCommitted 语义）。
  function lassoXform(includeDrag: boolean): ((nx: number, ny: number) => [number, number]) | null {
    if (!G.lassoSelection) return null;
    if (!G.lassoCommitted && !(includeDrag && (G.lassoDragMode === "move" || G.lassoDragMode === "scale"))) return null;
    if (G.lassoScale) {
      const { ax, ay, sx, sy } = G.lassoScale;
      if (sx === 1 && sy === 1) return null;
      return (nx, ny) => [clamp(ax + (nx - ax) * sx, inkXMin(), inkXMax()), clamp(ay + (ny - ay) * sy, 0, 1)];
    }
    const { dx, dy } = G.lassoTranslate;
    if (dx === 0 && dy === 0) return null;
    // x 放宽到页边区间：夹回页内的话，往页边拖的预览会被摁在页边上（画板关着时就是 0…1，行为不变）
    return (nx, ny) => [clamp(nx + dx, inkXMin(), inkXMax()), clamp(ny + dy, 0, 1)];
  }

  /// 8 个缩放手柄的屏显位置（四角 tl/tr/bl/br + 四边中点 t/b/l/r，**不含 ghost**）：
  /// drawLasso 渲染与 input.ts 手柄命中/锚点计算共用（同 Mac `LassoHandle.point(in:)`）。
  const LASSO_HANDLES = ["tl", "tr", "bl", "br", "t", "b", "l", "r"];
  function lassoHandlePts(): { h: string; x: number; y: number }[] {
    const b = lassoViewBox();
    if (!b) return [];
    return LASSO_HANDLES.map(function (h) {
      const x = h.indexOf("l") >= 0 ? b.x : h.indexOf("r") >= 0 ? b.x + b.w : b.x + b.w / 2;
      const y = h.indexOf("t") >= 0 ? b.y : h.indexOf("b") >= 0 ? b.y + b.h : b.y + b.h / 2;
      return { h, x, y };
    });
  }

  /// 框选叠层（同 hover 层，画在最后不受笔记/橡皮圆环遮挡）：
  /// · 进行中的自由框选虚线路径（`lassoDragMode==="select"`）；
  /// · 选中笔迹的 accent 光晕（所见即所选，同 Mac `lassoStrokeHalo`）；
  /// · 选中集高亮框 + 8 缩放手柄（move/scale ghost 期间随变换预览，提交待回传期间 = 乐观位置）。
  function drawLasso(): void {
    if (G.lassoDragMode === "select" && G.lassoAnchor && G.lassoPath && G.lassoPath.length >= 2) {
      const a = G.lassoAnchor;
      hctx.save();
      hctx.setLineDash([5, 4]); hctx.lineWidth = 1;
      hctx.fillStyle = "rgba(31,111,235,0.06)"; hctx.strokeStyle = "rgba(31,111,235,0.9)";
      hctx.beginPath();
      for (let i = 0; i < G.lassoPath.length; i++) {
        const v = pageToView(a.page, G.lassoPath[i].nx, G.lassoPath[i].ny);
        if (i === 0) hctx.moveTo(v.x, v.y); else hctx.lineTo(v.x, v.y);
      }
      hctx.closePath(); hctx.fill(); hctx.stroke();
      hctx.restore();
    }
    const sel = G.lassoSelection;
    if (!sel) return;
    const box = lassoViewBox();
    if (!box) return;
    const xf = lassoXform(true);
    // —— 选中笔迹光晕（accent 半透明包边；线宽 = 笔宽 + 5，与笔迹渲染同一页局部 px 尺度）——
    // strokes 镜像已到（lassoSyncStrokes）则跳过：那层已改画真源，halo 的命中下标随回传作废。
    if (!G.lassoSyncStrokes) {
    hctx.save();
    hctx.lineCap = "round"; hctx.lineJoin = "round";
    hctx.strokeStyle = "rgba(31,111,235,0.35)"; hctx.fillStyle = "rgba(31,111,235,0.35)";
    for (let i = 0; i < sel.strokeIdx.length; i++) {
      const s = G.strokes[sel.strokeIdx[i]];
      if (!s || s.page !== sel.page || !pageVisible(s.page)) continue;
      const hw = s.pen.w + 5;
      if (s.pts.length === 1) {   // 单点笔划：圆点光晕
        let nx = s.pts[0][0], ny = s.pts[0][1];
        if (xf) { const q = xf(nx, ny); nx = q[0]; ny = q[1]; }
        const v = pageToView(sel.page, nx, ny);
        hctx.beginPath(); hctx.arc(v.x, v.y, hw / 2, 0, Math.PI * 2); hctx.fill();
        continue;
      }
      hctx.lineWidth = hw;
      hctx.beginPath();
      for (let j = 0; j < s.pts.length; j++) {
        let nx = s.pts[j][0], ny = s.pts[j][1];
        if (xf) { const q = xf(nx, ny); nx = q[0]; ny = q[1]; }
        const v = pageToView(sel.page, nx, ny);
        if (j === 0) hctx.moveTo(v.x, v.y); else hctx.lineTo(v.x, v.y);
      }
      hctx.stroke();
    }
    hctx.restore();
    }
    // —— 高亮框 + 手柄（ghost：scale 绕锚点缩放 / move 平移；屏显坐标系直接变换）——
    let ghostPt = function (x: number, y: number): { x: number; y: number } { return { x, y }; };
    if (xf && G.lassoScale) {
      const a = pageToView(sel.page, G.lassoScale.ax, G.lassoScale.ay);
      const { sx, sy } = G.lassoScale;
      ghostPt = function (x, y) { return { x: a.x + (x - a.x) * sx, y: a.y + (y - a.y) * sy }; };
    } else if (xf) {
      const dxPx = G.lassoTranslate.dx * pw(), dyPx = G.lassoTranslate.dy * G.dispH[sel.page];
      ghostPt = function (x, y) { return { x: x + dxPx, y: y + dyPx }; };
    }
    const corners = [ghostPt(box.x, box.y), ghostPt(box.x + box.w, box.y),
                     ghostPt(box.x, box.y + box.h), ghostPt(box.x + box.w, box.y + box.h)];
    let lo = corners[0], hi = corners[0];
    for (let i = 1; i < 4; i++) {
      lo = { x: Math.min(lo.x, corners[i].x), y: Math.min(lo.y, corners[i].y) };
      hi = { x: Math.max(hi.x, corners[i].x), y: Math.max(hi.y, corners[i].y) };
    }
    hctx.save();
    hctx.setLineDash([6, 4]); hctx.lineWidth = 1.5;
    hctx.fillStyle = "rgba(31,111,235,0.08)"; hctx.strokeStyle = "rgba(31,111,235,0.9)";
    roundRectPath(hctx, lo.x, lo.y, hi.x - lo.x, hi.y - lo.y, 4); hctx.fill(); hctx.stroke();
    hctx.restore();
    // 手柄：accent 半透明圆点（同 Mac 样式；屏显坐标经同一 ghost 变换）
    const hd = lassoHandlePts();
    hctx.save();
    hctx.fillStyle = "rgba(31,111,235,0.25)"; hctx.strokeStyle = "rgba(31,111,235,0.95)"; hctx.lineWidth = 1.5;
    for (let i = 0; i < hd.length; i++) {
      const p = ghostPt(hd[i].x, hd[i].y);
      hctx.beginPath(); hctx.arc(p.x, p.y, 4.5, 0, Math.PI * 2); hctx.fill(); hctx.stroke();
    }
    hctx.restore();
  }

  /// 通用圆角矩形描边路径（`roundRect` 是 radial canvas 专用的模块内闭包版本，这里给 hover 层单独一份）。
  function roundRectPath(cx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
    cx.beginPath(); cx.moveTo(x + r, y);
    cx.arcTo(x + w, y, x + w, y + h, r); cx.arcTo(x + w, y + h, x, y + h, r);
    cx.arcTo(x, y + h, x, y, r); cx.arcTo(x, y, x + w, y, r);
    cx.closePath();
  }

  // ---- 环形选笔盘（Surface Dial 形制）----
  // 长按检测、扇区判定、选中提交**全在 Mac**；这里只画 Mac 下发的 `radial` 状态，不做任何判定。
  // 半径/角度常量必须与 Mac 端 `RadialLayout` 逐个对齐（shared.ts 的 RD）。
  const TOOL_LABEL: Record<string, string> = { erase: "橡皮", page: "翻页", scratchAdd: "新建草稿纸", textNote: "新建文字笔记" };

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
    // 与 Mac `RadialMenuView.tint` 同色：scratchAdd 紫 / textNote 蓝
    if (item.kind === "scratchAdd") return "rgba(153,115,230,0.92)";
    if (item.kind === "textNote") return "rgba(77,153,242,0.92)";
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
    } else if (item.kind === "page") {    // 翻页：举起的手（掌 + 四指），对应 Mac 的 hand.raised.fill
      rctx.scale(r / 17, r / 17);
      roundRect(-6.5, -1, 13, 9.5, 3); rctx.fill();
      for (let f = 0; f < 4; f++) { roundRect(-6 + f * 3.2, -8.5, 2.4, 8.5, 1.2); rctx.fill(); }
    } else {                            // scratchAdd / textNote：一页纸 + 右下角加号徽章
                                        //（对应 Mac 的 doc.badge.plus / note.text.badge.plus）
      const tint = tintOf(item);
      rctx.scale(r / 17, r / 17);
      roundRect(-8, -8.5, 12.5, 15.5, 2); rctx.fill();              // 纸（白）
      if (item.kind === "textNote") {                               // 纸上的两行字
        rctx.strokeStyle = tint; rctx.lineWidth = 1.6; rctx.lineCap = "round";
        rctx.beginPath();
        rctx.moveTo(-5.2, -3.4); rctx.lineTo(1.4, -3.4);
        rctx.moveTo(-5.2, 0.6); rctx.lineTo(1.4, 0.6);
        rctx.stroke();
      }
      // 加号徽章：扇区色圆片 + 白十字
      rctx.beginPath(); rctx.arc(4.4, 5.4, 4.6, 0, Math.PI * 2);
      rctx.fillStyle = tint; rctx.fill();
      rctx.strokeStyle = "#fff"; rctx.lineWidth = 1.5; rctx.lineCap = "round";
      rctx.beginPath();
      rctx.moveTo(2, 5.4); rctx.lineTo(6.8, 5.4);
      rctx.moveTo(4.4, 3); rctx.lineTo(4.4, 7.8);
      rctx.stroke();
    }
    rctx.restore();
  }

  // 跨模块调用面（input / ws / capture 经 G 调用）
  Object.assign(G, {
    relayout, recompute, locate, pageToView, inContent, setCanvas, growCanvas, growCanvasForStrokes,
    drawAll, drawBg, drawInk, drawLive, eraseHit, ensureImages, loadPageImage: loadImg,
    clearHover, drawNotes, setRadial, setPressRing,
    pageLocClamped, lassoHitTest, lassoViewBox, lassoHandlePts, clearLasso,
    buildGeomWith, paintInkGeom: paintGeomAt, padPinHit,
    noteMarkerHit, noteEditHit,
  });
}
