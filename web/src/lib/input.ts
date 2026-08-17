// 输入模块：笔/手指指针事件（画/擦/平移/双指缩放/防误触）、滚轮平移、松手惯性、
// 批点 rAF 合批、悬停上报、键盘侧键。逐行移植自原 capture.html IIFE 的对应段落。
import { G, BAR, GAP, MINZ, MAXZ, PALM, DEAD, clamp, pw, contentLeft, curMode, curPen, rulerSnap } from "./shared.js";
import type { CaptureRefs, TextNote } from "./shared.js";
import { S, updatePageLabel, updateHud } from "./hud.svelte.js";

export function initInput(refs: CaptureRefs): void {
  const { ink } = refs;

  // ---- 平移 / 缩放 / 纵向锚点 ----
  function panBy(dx: number, dy: number): void {
    G.scrollX = clamp(G.scrollX + dx, 0, G.maxScrollX);
    G.scrollY = clamp(G.scrollY + dy, 0, G.maxScrollY);
    G.ensureImages(); G.drawAll(); updatePageLabel(); emitScroll();
  }
  function cancelMomentum(): void { if (G.momentumRAF) { cancelAnimationFrame(G.momentumRAF); G.momentumRAF = null; } }
  // 松手惯性：按松手速度继续滚，指数衰减；碰边界该轴停；期间持续上报让 Mac 平滑跟随。
  function startMomentum(): void {
    cancelMomentum();
    if (Math.hypot(G.vx, G.vy) < 0.05) return;   // 太慢不惯性
    let last = performance.now();
    function step(): void {
      const now = performance.now(), dt = Math.min(50, now - last); last = now;
      G.scrollX = clamp(G.scrollX + G.vx * dt, 0, G.maxScrollX);
      G.scrollY = clamp(G.scrollY + G.vy * dt, 0, G.maxScrollY);
      const decay = Math.pow(0.94, dt / 16);
      G.vx *= decay; G.vy *= decay;
      if (G.scrollX <= 0 || G.scrollX >= G.maxScrollX) G.vx = 0;
      if (G.scrollY <= 0 || G.scrollY >= G.maxScrollY) G.vy = 0;
      G.ensureImages(); G.drawAll(); updatePageLabel(); emitScroll();
      G.momentumRAF = Math.hypot(G.vx, G.vy) > 0.02 ? requestAnimationFrame(step) : null;
    }
    G.momentumRAF = requestAnimationFrame(step);
  }
  function emitScroll(): void {
    if (G.reportPending) return; G.reportPending = true;
    requestAnimationFrame(function () {
      G.reportPending = false;
      const docY = G.scrollY;
      for (let i = 0; i < G.pageCount; i++) {
        if (docY < G.offY[i] + G.dispH[i] + GAP) {   // 严格 <，与 topVisiblePage 同一边界
          G.send({ type: "scroll", page: i, frac: clamp((docY - G.offY[i]) / Math.max(1, G.dispH[i]), 0, 1), t: performance.now() });
          return;
        }
      }
    });
  }
  function topVisiblePage(): number {
    // 严格 <：翻到某页正顶部时（offY[i] == 上页底+GAP）必须算本页，
    // 否则「下一页」按了原地不动、「上一页」连跳两页。
    for (let i = 0; i < G.pageCount; i++) if (G.scrollY < G.offY[i] + G.dispH[i] + GAP) return i;
    return Math.max(0, G.pageCount - 1);
  }

  // ---- 指针：笔=画/平移，手指=平移/双指缩放 ----
  /// 图钉拖动作废（第二指落下变捏合 / 草稿纸列表被 Mac 回推换掉）：清手势瞬态与乐观预览。
  function cancelPinDrag(): void {
    if (G.pinDragIndex < 0 && !G.pinGhost) return;
    G.pinDragIndex = -1; G.pinDragMoved = false;
    if (G.pinGhost) { G.pinGhost = null; G.drawNotes(); }
  }
  function beginPinch(): void {
    cancelPinDrag();   // 双指 = 捏合，按住图钉的那次拖动作废
    const a = G.touches[G.touchOrder[0]], b = G.touches[G.touchOrder[1]];
    const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, p = pw();
    G.pinch = {
      d0: Math.max(40, Math.hypot(a.x - b.x, a.y - b.y)),   // 初始间距下限，避免起手两指过近灵敏度爆炸
      z0: G.zoom,
      fx: p > 0 ? (mx - contentLeft()) / p : 0.5,            // 捏合中点抓住的内容比例（固定锚点）
      fy: G.totalH > 0 ? (my - BAR + G.scrollY) / G.totalH : 0
    };
    G.panId = null; G.panStarted = false;
  }

  ink.addEventListener("pointerdown", function (e: PointerEvent) {
    cancelMomentum();
    // 草稿纸盖着时整段让给它（笔迹只能落在草稿纸上；平移/缩放也归它自己的无限画布视口）。
    if (G.padActive()) { if (G.padPointerDown(e)) { e.preventDefault(); return; } }
    if (e.pointerType === "touch") {
      if (G.activeId !== null) { e.preventDefault(); return; }   // 笔在写 → 忽略手掌
      if (e.width > PALM || e.height > PALM) { e.preventDefault(); return; }   // 大面积接触（手掌）忽略
      if (!G.touchOrder.length) G.gestureBlocked = false;   // 一次新手势的第一根手指
      G.touches[e.pointerId] = { x: e.clientX, y: e.clientY };
      if (G.touchOrder.indexOf(e.pointerId) < 0) G.touchOrder.push(e.pointerId);
      if (G.touchOrder.length >= 2) beginPinch();
      else {
        G.panId = e.pointerId; G.lastPanX = e.clientX; G.lastPanY = e.clientY;
        G.panDownX = e.clientX; G.panDownY = e.clientY; G.panStarted = false;
        G.vx = 0; G.vy = 0; G.lastMoveT = performance.now();
        // 落在图钉热区内 → 可能是图钉拖动（越过死区才判定；没越过就是原来的单击开纸）。
        // 只认手指，与 endTouch 的单击判定同一条纪律。
        G.pinDragIndex = G.padPinHit(e.clientX, e.clientY); G.pinDragMoved = false;
      }
      e.preventDefault(); return;
    }
    // 笔
    // 文字笔记模式最优先：点空白开新笔记编辑器、点已有标记开编辑/删除。
    // 该分支绝不发 probe/ink/hover（probe 会让 Mac 呼出环形选笔盘），直接 return。
    if (G.noteMode) {
      const loc = G.locate(e.clientX, e.clientY);
      if (loc) {
        // 命中检测：同页、归一化距离小于阈值（页宽归一化，不管页面纵横比）
        let hit: TextNote | null = null;
        for (let i = 0; i < G.notes.length; i++) {
          const n = G.notes[i];
          if (n.page === loc.page && Math.hypot(n.nx - loc.nx, n.ny - loc.ny) < 0.03) { hit = n; break; }
        }
        S.noteEditor = hit
          ? { id: hit.id, page: hit.page, nx: hit.nx, ny: hit.ny, x: e.clientX, y: e.clientY, text: hit.text, isNew: false }
          : { id: crypto.randomUUID(), page: loc.page, nx: loc.nx, ny: loc.ny, x: e.clientX, y: e.clientY, text: "", isNew: true };
      }
      e.preventDefault(); return;
    }
    const m = curMode();
    if (m === "page") {   // 翻页模式：笔拖动平移画面（同时起探针流，供 Mac 检测长按呼出选笔盘）
      G.activeId = e.pointerId; G.penMode = "page";
      try { ink.setPointerCapture(e.pointerId); } catch (x) {}
      G.penX = e.clientX; G.penY = e.clientY; G.vx = 0; G.vy = 0; G.lastMoveT = performance.now();
      const ploc = G.locate(e.clientX, e.clientY);
      if (ploc) { G.probing = true; G.probePage = ploc.page; G.send({ type: "probe", phase: "begin", page: ploc.page, pts: [[ploc.nx, ploc.ny]] }); }
      endHover(); e.preventDefault(); return;
    }
    const loc = G.locate(e.clientX, e.clientY);
    if (!loc) return;
    G.activeId = e.pointerId; G.penMode = m;
    try { ink.setPointerCapture(e.pointerId); } catch (x) {}
    endHover();
    if (m === "note") {
      G.drawPage = loc.page; G.radialActive = false;
      // 本地即时回显笔迹（反馈）；长按检测/环形盘/选中在 Mac，触发时 Mac 回发 inkCancel 让本地撤掉这半笔。
      const pen = curPen();
      // 尺子开关按**落笔那一刻**锁进这一笔（中途改开关不影响正在写的这笔），并随 begin 上报 Mac：
      // Mac 据此把后续 move 当「替换终点」而不是追加点，两端才都是同一条两点直线。
      G.lineStroke = G.rulerOn;
      G.cur = { page: loc.page, pen: { color: pen.color, w: pen.w, t: pen.t }, pts: [[loc.nx, loc.ny, e.pressure]] };
      G.drawLive();
      G.send({ type: "ink", phase: "begin", page: loc.page, pen: G.cur.pen,
               pts: [[loc.nx, loc.ny, e.pressure]], line: G.lineStroke });
    } else if (m === "erase") {
      G.eraseHit(e.clientX, e.clientY); G.batch.push([loc.nx, loc.ny, loc.page]);
      if (G.eraserRing) { G.eraserRingAt = { x: e.clientX, y: e.clientY }; G.drawNotes(); }
      G.probing = true; G.probePage = loc.page;
      G.send({ type: "probe", phase: "begin", page: loc.page, pts: [[loc.nx, loc.ny]] });
    } else if (m === "lasso") {
      // 落笔点记下来即可：拖动模式（框选/移动）在 pointermove 越过死区那一刻才判定
      // （镜像 Mac 端 `DragGesture(minimumDistance: 2)` 起点一次性判定，纯点击不触发任何手势）。
      G.lassoAnchor = { page: loc.page, nx: loc.nx, ny: loc.ny };
      G.lassoDownX = e.clientX; G.lassoDownY = e.clientY;
      G.lassoMoved = false; G.lassoDragMode = null;
    }
    e.preventDefault();
  }, { passive: false });

  ink.addEventListener("pointermove", function (e: PointerEvent) {
    if (G.padActive()) { if (G.padPointerMove(e)) { e.preventDefault(); return; } }
    if (e.pointerType === "touch") {
      if (!(e.pointerId in G.touches)) return;
      G.touches[e.pointerId] = { x: e.clientX, y: e.clientY };
      if (G.pinch && G.touchOrder.length >= 2) {
        const a = G.touches[G.touchOrder[0]], b = G.touches[G.touchOrder[1]];
        const d = Math.hypot(a.x - b.x, a.y - b.y);
        const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
        if (!G.zoomLocked) G.zoom = clamp(G.pinch.z0 * d / G.pinch.d0, MINZ, MAXZ);
        G.recompute();
        // 固定锚点比例始终跟随当前中点 → 缩放与双指整体移动都跟手、不漂移
        G.scrollY = clamp(G.pinch.fy * G.totalH - (my - BAR), 0, G.maxScrollY);
        G.scrollX = pw() > G.vw ? clamp(G.pinch.fx * pw() - mx, 0, G.maxScrollX) : 0;
        G.ensureImages(); G.drawAll(); updateHud();   // 缩放/双指为本地查看，不上报位置，避免回环
        G.emitGeom();   // 页宽变了要告诉 Mac（选笔盘的像素判定基准），与位置无关、不构成回环
      } else if (e.pointerId === G.panId) {
        // 图钉拖动：起点在图钉热区内、越过死区后不再平移页面，改为实时拖动图钉。
        // 只动乐观预览（pinGhost），位置 clamp 在锚点页内，松手才提交 scratchMove。
        if (G.pinDragIndex >= 0) {
          if (!G.pinDragMoved) {
            if (Math.hypot(e.clientX - G.panDownX, e.clientY - G.panDownY) < DEAD) { e.preventDefault(); return; }
            G.pinDragMoved = true;
          }
          const pad = G.pads[G.pinDragIndex];
          if (pad) {
            const pl = G.pageLocClamped(e.clientX, e.clientY, pad.page);
            G.pinGhost = { index: G.pinDragIndex, nx: pl.nx, ny: pl.ny };
            G.drawNotes();
          }
          e.preventDefault(); return;
        }
        if (!G.panStarted) {
          if (Math.hypot(e.clientX - G.panDownX, e.clientY - G.panDownY) < DEAD) { e.preventDefault(); return; }
          // 双指滚动模式：单指划动到此为止——不平移、不记速度、松手也不甩惯性。
          // （图钉拖动在上面已经 return 掉了：那是按住一个图钉的刻意动作，不算误触。）
          if (G.twoFinger) { G.gestureBlocked = true; e.preventDefault(); return; }
          G.panStarted = true; G.lastPanX = e.clientX; G.lastPanY = e.clientY; G.lastMoveT = performance.now();   // 越过死区才开始
        }
        const dx = G.lastPanX - e.clientX, dy = G.lastPanY - e.clientY;
        const now = performance.now(), dt = now - G.lastMoveT; G.lastMoveT = now;
        if (dt > 0 && dt < 100) { G.vx = 0.7 * G.vx + 0.3 * (dx / dt); G.vy = 0.7 * G.vy + 0.3 * (dy / dt); }
        panBy(dx, dy);
        G.lastPanX = e.clientX; G.lastPanY = e.clientY;
      }
      e.preventDefault(); return;
    }
    // 笔
    if (e.pointerId !== G.activeId) {
      if (e.buttons === 0 && curMode() !== "page" && G.inContent(e.clientX, e.clientY)) {
        const hl = G.locate(e.clientX, e.clientY);   // 纯输入板：不画本地环，只上报位置给 Mac 显示光标
        if (hl) {
          reportHover(hl.page, hl.nx, hl.ny);
          // 擦除模式：悬停时也显示橡皮尺寸圆环（圆环本体画在 hover 层，见 render.ts drawNotes）
          if (curMode() === "erase" && G.eraserRing) { G.eraserRingAt = { x: e.clientX, y: e.clientY }; G.drawNotes(); }
        }
      } else if (e.buttons === 0) endHover();
      return;
    }
    if (G.penMode === "page") {   // 笔拖动平移（记录速度供松手惯性）；环形盘开着时只发探针不平移
      if (G.probing) {
        const pll = G.locate(e.clientX, e.clientY);
        const pnx = pll ? pll.nx : clamp((e.clientX - contentLeft()) / pw(), 0, 1);
        const pny = pll && pll.page === G.probePage ? pll.ny
                : clamp((e.clientY - BAR + G.scrollY - G.offY[G.probePage]) / Math.max(1, G.dispH[G.probePage]), 0, 1);
        G.pbatch.push([pnx, pny]);
      }
      if (G.radialActive) { e.preventDefault(); return; }
      const dxp = G.penX - e.clientX, dyp = G.penY - e.clientY;
      const nowp = performance.now(), dtp = nowp - G.lastMoveT; G.lastMoveT = nowp;
      if (dtp > 0 && dtp < 100) { G.vx = 0.7 * G.vx + 0.3 * (dxp / dtp); G.vy = 0.7 * G.vy + 0.3 * (dyp / dtp); }
      panBy(dxp, dyp);
      G.penX = e.clientX; G.penY = e.clientY; e.preventDefault(); return;
    }
    if (G.penMode === "lasso") { handleLassoMove(e); e.preventDefault(); return; }
    let evs = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
    if (!evs.length) evs = [e];
    let grew = false, ringUpd = false;
    for (let i = 0; i < evs.length; i++) {
      const ev = evs[i], loc = G.locate(ev.clientX, ev.clientY);
      if (G.penMode === "note") {
        const nx = loc ? loc.nx : clamp((ev.clientX - contentLeft()) / pw(), 0, 1);
        const ny = loc && loc.page === G.drawPage ? loc.ny
               : clamp((ev.clientY - BAR + G.scrollY - G.offY[G.drawPage]) / Math.max(1, G.dispH[G.drawPage]), 0, 1);
        if (G.lineStroke && !G.radialActive && G.cur && G.cur.pts.length) {
          // 尺子模式：以首点为锚做 45°（**视觉**角度，故传页纵横比）吸附，本地笔迹替换为
          // [首点, 吸附终点]（压感取当前点）。上行也只发这个终点——批里**只留最新一个**，
          // 否则 Mac 收到的是一串移动中的终点、追加成一条歪笔迹（begin 的 line 标记让 Mac 改为替换终点）。
          const a = G.cur.pts[0];
          const asp = G.dispH[G.drawPage] / Math.max(1, pw());
          const sn = rulerSnap(a[0], a[1], nx, ny, asp);
          G.cur.pts = [a, [sn[0], sn[1], ev.pressure]];
          G.batch = [[sn[0], sn[1], ev.pressure]];
          grew = true;
        } else {
          // 环形盘激活后本地不再画（笔移是在选笔），但位置照发让 Mac 驱动高亮
          if (!G.radialActive && G.cur) { G.cur.pts.push([nx, ny, ev.pressure]); grew = true; }
          G.batch.push([nx, ny, ev.pressure]);
        }
      } else if (G.penMode === "erase") {
        if (!G.radialActive) {   // 环形盘开着：停擦除，只发探针驱动选笔
          G.eraseHit(ev.clientX, ev.clientY);
          if (G.eraserRing) { G.eraserRingAt = { x: ev.clientX, y: ev.clientY }; ringUpd = true; }
          if (loc) G.batch.push([loc.nx, loc.ny, loc.page]);
        }
        if (G.probing) {
          const enx = loc ? loc.nx : clamp((ev.clientX - contentLeft()) / pw(), 0, 1);
          const eny = loc && loc.page === G.probePage ? loc.ny
                  : clamp((ev.clientY - BAR + G.scrollY - G.offY[G.probePage]) / Math.max(1, G.dispH[G.probePage]), 0, 1);
          G.pbatch.push([enx, eny]);
        }
      }
    }
    if (grew) G.drawLive();   // 一次 pointermove 的所有合并点收完再重画一次，别逐点重画
    if (ringUpd) G.drawNotes();   // 橡皮圆环同理：合并点收完重画一次 hover 层
    e.preventDefault();
  }, { passive: false });

  function endTouch(id: number): void {
    if (!(id in G.touches)) return;
    delete G.touches[id];
    const k = G.touchOrder.indexOf(id); if (k >= 0) G.touchOrder.splice(k, 1);
    G.pinch = null;
    if (G.touchOrder.length === 1) {   // 回到单指平移（重新死区判定，避免松指跳动）
      G.panId = G.touchOrder[0];
      const t = G.touches[G.panId];
      G.lastPanX = t.x; G.lastPanY = t.y; G.panDownX = t.x; G.panDownY = t.y; G.panStarted = false;
    } else if (G.touchOrder.length === 0) {
      if (G.panStarted) startMomentum();   // 松手甩动 → 惯性
      else if (G.pinDragMoved && G.pinGhost) {
        // 图钉拖动松手：提交 scratchMove（Mac 钳位/判定后经 scratchpads 全量回推）。
        // pinGhost 不清——留着当乐观预览，等回推在 applyScratchPads 里对齐（同 scratchPaper 惯例）。
        G.send({ type: "scratchMove", index: G.pinGhost.index, nx: G.pinGhost.nx, ny: G.pinGhost.ny });
      } else if (!G.gestureBlocked) {
        // 单指**单击**（全程没越过死区）：命中草稿纸图钉就打开那张纸。
        // 只认手指、不认笔——平板上笔是用来写字的，让笔点图钉必然会在图钉上落笔时误触发。
        // 双指滚动模式下划过一道再抬手的（gestureBlocked）不算单击，否则误触又从这条路进来了。
        const i = G.padPinHit(G.panDownX, G.panDownY);
        if (i >= 0) G.padOpenIndex(i);
      }
      G.pinDragIndex = -1; G.pinDragMoved = false;
      G.panId = null; G.panStarted = false;
    } else if (G.touchOrder.length >= 2) {
      beginPinch();
    }
  }
  // ---- 框选（lasso 模式：拖空白=自由框选 / 拖选中高亮框内=移动 / 拖手柄=缩放，起点一次性判定拖动形态）----

  /// 对侧手柄（缩放锚点）：角的对角 / 边的对边中点（同 Mac `LassoHandle.opposite`）。
  const LASSO_HANDLE_OPP: Record<string, string> =
    { tl: "br", tr: "bl", bl: "tr", br: "tl", t: "b", b: "t", l: "r", r: "l" };

  /// 越过死区（2px，同 Mac `DragGesture(minimumDistance: 2)`）后判一次形态：落笔点命中手柄（10px）→ 缩放；
  /// 落在当前选中高亮框内（含 8px 抓手余量）→ 移动；否则重新自由框选（并放弃旧选中，同 Mac 逻辑）。
  function handleLassoMove(e: PointerEvent): void {
    const a = G.lassoAnchor; if (!a) return;
    if (!G.lassoMoved) {
      if (Math.hypot(e.clientX - G.lassoDownX, e.clientY - G.lassoDownY) < 2) return;
      G.lassoMoved = true;
      let mode: "select" | "move" | "scale" = "select";
      if (G.lassoSelection && G.lassoSelection.page === a.page) {
        const hd = G.lassoHandlePts();
        for (let i = 0; i < hd.length; i++) {
          if (Math.hypot(G.lassoDownX - hd[i].x, G.lassoDownY - hd[i].y) <= 10) {
            mode = "scale"; G.lassoHandle = hd[i].h; break;
          }
        }
        if (mode === "select") {
          const box = G.lassoViewBox();
          if (box && G.lassoDownX >= box.x - 8 && G.lassoDownX <= box.x + box.w + 8 &&
              G.lassoDownY >= box.y - 8 && G.lassoDownY <= box.y + box.h + 8) mode = "move";
        }
      }
      G.lassoDragMode = mode;
      if (mode === "select") {
        G.lassoSelection = null;
        G.lassoPath = [{ nx: a.nx, ny: a.ny }];
      } else if (mode === "scale") {
        // 缩放锚点 = 对侧手柄（页内归一化）：屏显 → norm 折算一次，整个拖动期间不变
        const sel = G.lassoSelection!;
        const opp = LASSO_HANDLE_OPP[G.lassoHandle!];
        const pts = G.lassoHandlePts();
        for (let i = 0; i < pts.length; i++) {
          if (pts[i].h === opp) {
            const an = G.pageLocClamped(pts[i].x, pts[i].y, sel.page);
            G.lassoScale = { ax: an.nx, ay: an.ny, sx: 1, sy: 1 };
            break;
          }
        }
      }
    }
    if (G.lassoDragMode === "select") {
      // 自由路径：≥3px 抽稀（更密的点对多边形命中无增益，白耗 O(点数×边数)）
      const path = G.lassoPath!;
      const lastV = G.pageToView(a.page, path[path.length - 1].nx, path[path.length - 1].ny);
      if (Math.hypot(e.clientX - lastV.x, e.clientY - lastV.y) >= 3) {
        path.push(G.pageLocClamped(e.clientX, e.clientY, a.page));
      }
    } else if (G.lassoDragMode === "move") {
      const cur = G.pageLocClamped(e.clientX, e.clientY, a.page);
      G.lassoTranslate = { dx: cur.nx - a.nx, dy: cur.ny - a.ny };
    } else if (G.lassoDragMode === "scale") {
      const sel = G.lassoSelection, h = G.lassoHandle;
      if (sel && h && G.lassoScale) {
        // 屏显空间算缩放比（按轴线性变换，与归一化坐标严格等价，同 Mac updateLassoScaleGhost）：
        // 角手柄 = 等比（取变化幅度更大的一轴）、边中点手柄 = 单轴（另一轴恒 1）。
        const aV = G.pageToView(sel.page, G.lassoScale.ax, G.lassoScale.ay);
        const pts = G.lassoHandlePts();
        let startV: { x: number; y: number } | null = null;
        for (let i = 0; i < pts.length; i++) if (pts[i].h === h) startV = { x: pts[i].x, y: pts[i].y };
        if (startV) {
          const denomX = startV.x - aV.x, denomY = startV.y - aV.y;
          let sx = 1, sy = 1;
          if (h === "t" || h === "b") {
            if (Math.abs(denomY) > 1) sy = (e.clientY - aV.y) / denomY;
          } else if (h === "l" || h === "r") {
            if (Math.abs(denomX) > 1) sx = (e.clientX - aV.x) / denomX;
          } else if (Math.abs(denomX) > 1 && Math.abs(denomY) > 1) {
            sx = (e.clientX - aV.x) / denomX; sy = (e.clientY - aV.y) / denomY;
            const s = Math.abs(sx - 1) >= Math.abs(sy - 1) ? sx : sy;
            sx = s; sy = s;
          }
          G.lassoScale.sx = clamp(sx, 0.05, 20); G.lassoScale.sy = clamp(sy, 0.05, 20);
        }
      }
    }
    G.drawNotes();
  }

  /// 提交后的共同收尾：标 committed + 乐观重绘 + 1s 兜底超时（Mac 判定为零命中/零变化时不会回传
  /// strokes/notes，靠超时兜底清掉乐观预览，避免永久错位显示）。
  function commitLassoPending(): void {
    G.lassoCommitted = true;
    if (G.lassoPendingTimer) clearTimeout(G.lassoPendingTimer);
    G.lassoPendingTimer = setTimeout(function () { G.lassoPendingTimer = null; if (G.lassoCommitted) G.clearLasso(); }, 1000);
    G.drawInk(); G.drawNotes();
  }

  /// 松手收尾：纯点击（未越过死区）→ 清除选中（同 Mac `.onTapGesture` 无条件清，与是否命中无关）；
  /// select → 本地判定命中集（渲染高亮，不上行）；move → 提交位移；scale → 提交缩放
  /// （后两者 Mac 用真源复判 + 持久化，协议见 PROTOCOL.md `lassoMove`/`lassoScale`）。
  function finishLasso(): void {
    const a = G.lassoAnchor, mode = G.lassoDragMode;
    if (!G.lassoMoved || !mode) {
      if (G.lassoSelection) { G.lassoSelection = null; G.drawNotes(); }
    } else if (mode === "select" && a && G.lassoPath && G.lassoPath.length >= 3) {
      const poly: number[] = [];
      for (let i = 0; i < G.lassoPath.length; i++) poly.push(G.lassoPath[i].nx, G.lassoPath[i].ny);
      G.lassoSelection = G.lassoHitTest(a.page, poly);
      G.drawNotes();
    } else if (mode === "move" && G.lassoSelection) {
      const { dx, dy } = G.lassoTranslate;
      if (dx !== 0 || dy !== 0) {
        const sel = G.lassoSelection;
        G.send({ type: "lassoMove", page: sel.page, x0: sel.box[0], y0: sel.box[1], x1: sel.box[2], y1: sel.box[3],
                 dx: dx, dy: dy, poly: sel.poly });
        commitLassoPending();
      }
    } else if (mode === "scale" && G.lassoSelection && G.lassoScale) {
      const sel = G.lassoSelection, sc = G.lassoScale;
      if (sc.sx !== 1 || sc.sy !== 1) {
        G.send({ type: "lassoScale", page: sel.page, x0: sel.box[0], y0: sel.box[1], x1: sel.box[2], y1: sel.box[3],
                 ax: sc.ax, ay: sc.ay, sx: sc.sx, sy: sc.sy, poly: sel.poly });
        commitLassoPending();
      }
    }
    G.lassoDragMode = null; G.lassoMoved = false; G.lassoPath = null; G.lassoAnchor = null; G.lassoHandle = null;
    if (!G.lassoCommitted) { G.lassoTranslate = { dx: 0, dy: 0 }; G.lassoScale = null; }
  }

  function endPen(e: PointerEvent): void {
    if (e.pointerId !== G.activeId) return;
    // 不本地落 strokes（Mac 才是真源，稍后回传）；正常这一笔的 cur 先留着（本地即时可见），等 Mac 回传 strokes 再清。
    if (G.penMode === "note") { if (G.radialActive) { G.cur = null; G.drawLive(); } flushBatch("ink"); G.send({ type: "ink", phase: "end" }); }
    else if (G.penMode === "erase") { if (G.radialActive) G.batch = []; else flushBatch("erase"); G.send({ type: "erase", phase: "end" }); }
    else if (G.penMode === "page") { if (!G.radialActive) startMomentum(); }   // 笔翻页拖动松手 → 惯性（环形盘选择不甩动）
    else if (G.penMode === "lasso") { finishLasso(); }
    if (G.probing) {   // 收尾探针流，Mac 据此提交/取消环形盘
      if (G.pbatch.length) { G.send({ type: "probe", phase: "move", pts: G.pbatch }); G.pbatch = []; }
      G.send({ type: "probe", phase: "end" }); G.probing = false;
    }
    G.radialActive = false;
    // 抬笔必然收盘/撤环：不等 Mac 的 off 消息，丢帧也不会残留一个盘/环挡视线
    if (G.radialState) G.setRadial(null);
    if (G.pressRing) G.setPressRing(null);
    G.activeId = null; G.penMode = "";
  }
  function onUp(e: PointerEvent): void {
    if (G.padActive()) { if (G.padPointerUp(e)) return; }
    if (e.pointerType === "touch") endTouch(e.pointerId); else endPen(e);
  }
  ink.addEventListener("pointerup", onUp);
  ink.addEventListener("pointercancel", onUp);
  ink.addEventListener("pointerleave", function (e: PointerEvent) { if (e.pointerType !== "touch") endHover(); });

  // 鼠标滚轮 / 触控板滚动（桌面浏览器测试用）：等同单指平移，复用同一条
  // panBy→emitScroll 链路，方便无平板时在另一台电脑上测滚动同步/跟随。
  ink.addEventListener("wheel", function (e: WheelEvent) {
    if (G.padActive()) { e.preventDefault(); return; }   // 草稿纸开着：滚轮归它（它自己那层已监听）
    cancelMomentum();
    const unit = e.deltaMode === 1 ? 16 : (e.deltaMode === 2 ? G.availH : 1);  // 行/页 → 像素
    let dx = e.deltaX * unit, dy = e.deltaY * unit;
    if (e.shiftKey && !dx) { dx = dy; dy = 0; }   // Shift+滚轮 → 横向（放大后用）
    panBy(dx, dy);
    e.preventDefault();
  }, { passive: false });

  function flushBatch(kind: "ink" | "erase"): void {
    if (!G.batch.length) return;
    if (kind === "erase") {
      // 擦除点带页号（第 3 元素）：按页分组发送，Mac 端据此只删对应页的笔迹
      const byPage: Record<number, [number, number][]> = {};
      for (let i = 0; i < G.batch.length; i++) {
        const b = G.batch[i];
        (byPage[b[2]] = byPage[b[2]] || []).push([b[0], b[1]]);
      }
      for (const pg in byPage) G.send({ type: "erase", phase: "move", page: +pg, pts: byPage[pg] });
    } else {
      G.send({ type: kind, phase: "move", pts: G.batch });
    }
    G.batch = [];
  }
  function tick(): void {
    G.frames++;
    if (G.padActive()) {
      // 草稿纸的批点是画布坐标，必须走 padFlush（flushBatch 会按页内语义分组，坐标系不对）。
      if (G.activeId !== null && G.batch.length) G.padFlush(G.penMode === "paderase" ? "erase" : "ink");
      requestAnimationFrame(tick);
      return;
    }
    if (G.activeId !== null) {
      if (G.batch.length) flushBatch(G.penMode === "erase" ? "erase" : "ink");
      if (G.pbatch.length) { G.send({ type: "probe", phase: "move", pts: G.pbatch }); G.pbatch = []; }
    }
    requestAnimationFrame(tick);
  }
  requestAnimationFrame(tick);

  // ---- 悬停上报 Mac（rAF 节流，页内归一化坐标）；endHover 清本地圆环并通知 Mac 隐藏 ----
  function reportHover(page: number, nx: number, ny: number): void {
    G.hoverOn = true; G.hoverMsg = { type: "hover", page: page, nx: nx, ny: ny };
    if (G.hoverPending) return; G.hoverPending = true;
    requestAnimationFrame(function () { G.hoverPending = false; if (G.hoverMsg) { G.send(G.hoverMsg); G.hoverMsg = null; } });
  }
  function endHover(): void {
    if (!G.hoverOn && !G.eraserRingAt) return;
    G.hoverOn = false; G.eraserRingAt = null; G.clearHover(); G.send({ type: "hover", phase: "end" });
  }

  // ---- 键盘侧键（PageUp 切模式 / PageDown 切笔）----
  window.addEventListener("keydown", function (e: KeyboardEvent) {
    if (e.repeat) return;
    if (e.key === "PageUp") { e.preventDefault(); G.cycleMode(); }
    else if (e.key === "PageDown") { e.preventDefault(); G.cyclePen(); }
    // 框选移动的 Esc 清选中（同 Mac 端 NSEvent 本地监视器同款行为）。
    else if (e.key === "Escape" && G.padActive()) { e.preventDefault(); G.padClose(); }
    else if (e.key === "Escape" && G.lassoSelection) { G.clearLasso(); }
  });

  window.addEventListener("contextmenu", function (e: Event) { e.preventDefault(); });

  // 跨模块调用面
  Object.assign(G, {
    panBy, cancelMomentum, startMomentum, emitScroll, topVisiblePage, endHover,
  });
}
