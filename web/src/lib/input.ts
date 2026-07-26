// 输入模块：笔/手指指针事件（画/擦/平移/双指缩放/防误触）、滚轮平移、松手惯性、
// 批点 rAF 合批、悬停上报、键盘侧键。逐行移植自原 capture.html IIFE 的对应段落。
import { G, BAR, GAP, MINZ, MAXZ, PALM, DEAD, clamp, pw, contentLeft, curMode, curPen } from "./shared.js";
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
  function beginPinch(): void {
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
    if (e.pointerType === "touch") {
      if (G.activeId !== null) { e.preventDefault(); return; }   // 笔在写 → 忽略手掌
      if (e.width > PALM || e.height > PALM) { e.preventDefault(); return; }   // 大面积接触（手掌）忽略
      G.touches[e.pointerId] = { x: e.clientX, y: e.clientY };
      if (G.touchOrder.indexOf(e.pointerId) < 0) G.touchOrder.push(e.pointerId);
      if (G.touchOrder.length >= 2) beginPinch();
      else {
        G.panId = e.pointerId; G.lastPanX = e.clientX; G.lastPanY = e.clientY;
        G.panDownX = e.clientX; G.panDownY = e.clientY; G.panStarted = false;
        G.vx = 0; G.vy = 0; G.lastMoveT = performance.now();
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
      G.cur = { page: loc.page, pen: { color: pen.color, w: pen.w, t: pen.t }, pts: [[loc.nx, loc.ny, e.pressure]] };
      G.drawLive();
      G.send({ type: "ink", phase: "begin", page: loc.page, pen: G.cur.pen, pts: [[loc.nx, loc.ny, e.pressure]] });
    } else if (m === "erase") {
      G.eraseHit(e.clientX, e.clientY); G.batch.push([loc.nx, loc.ny, loc.page]);
      G.probing = true; G.probePage = loc.page;
      G.send({ type: "probe", phase: "begin", page: loc.page, pts: [[loc.nx, loc.ny]] });
    }
    e.preventDefault();
  }, { passive: false });

  ink.addEventListener("pointermove", function (e: PointerEvent) {
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
        if (!G.panStarted) {
          if (Math.hypot(e.clientX - G.panDownX, e.clientY - G.panDownY) < DEAD) { e.preventDefault(); return; }
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
        if (hl) reportHover(hl.page, hl.nx, hl.ny);
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
    let evs = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
    if (!evs.length) evs = [e];
    let grew = false;
    for (let i = 0; i < evs.length; i++) {
      const ev = evs[i], loc = G.locate(ev.clientX, ev.clientY);
      if (G.penMode === "note") {
        const nx = loc ? loc.nx : clamp((ev.clientX - contentLeft()) / pw(), 0, 1);
        const ny = loc && loc.page === G.drawPage ? loc.ny
               : clamp((ev.clientY - BAR + G.scrollY - G.offY[G.drawPage]) / Math.max(1, G.dispH[G.drawPage]), 0, 1);
        // 环形盘激活后本地不再画（笔移是在选笔），但位置照发让 Mac 驱动高亮
        if (!G.radialActive && G.cur) { G.cur.pts.push([nx, ny, ev.pressure]); grew = true; }
        G.batch.push([nx, ny, ev.pressure]);
      } else if (G.penMode === "erase") {
        if (!G.radialActive) {   // 环形盘开着：停擦除，只发探针驱动选笔
          G.eraseHit(ev.clientX, ev.clientY);
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
      G.panId = null; G.panStarted = false;
    } else if (G.touchOrder.length >= 2) {
      beginPinch();
    }
  }
  function endPen(e: PointerEvent): void {
    if (e.pointerId !== G.activeId) return;
    // 不本地落 strokes（Mac 才是真源，稍后回传）；正常这一笔的 cur 先留着（本地即时可见），等 Mac 回传 strokes 再清。
    if (G.penMode === "note") { if (G.radialActive) { G.cur = null; G.drawLive(); } flushBatch("ink"); G.send({ type: "ink", phase: "end" }); }
    else if (G.penMode === "erase") { if (G.radialActive) G.batch = []; else flushBatch("erase"); G.send({ type: "erase", phase: "end" }); }
    else if (G.penMode === "page") { if (!G.radialActive) startMomentum(); }   // 笔翻页拖动松手 → 惯性（环形盘选择不甩动）
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
  function onUp(e: PointerEvent): void { if (e.pointerType === "touch") endTouch(e.pointerId); else endPen(e); }
  ink.addEventListener("pointerup", onUp);
  ink.addEventListener("pointercancel", onUp);
  ink.addEventListener("pointerleave", function (e: PointerEvent) { if (e.pointerType !== "touch") endHover(); });

  // 鼠标滚轮 / 触控板滚动（桌面浏览器测试用）：等同单指平移，复用同一条
  // panBy→emitScroll 链路，方便无平板时在另一台电脑上测滚动同步/跟随。
  ink.addEventListener("wheel", function (e: WheelEvent) {
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
  function endHover(): void { if (!G.hoverOn) return; G.hoverOn = false; G.clearHover(); G.send({ type: "hover", phase: "end" }); }

  // ---- 键盘侧键（PageUp 切模式 / PageDown 切笔）----
  window.addEventListener("keydown", function (e: KeyboardEvent) {
    if (e.repeat) return;
    if (e.key === "PageUp") { e.preventDefault(); G.cycleMode(); }
    else if (e.key === "PageDown") { e.preventDefault(); G.cyclePen(); }
  });

  window.addEventListener("contextmenu", function (e: Event) { e.preventDefault(); });

  // 跨模块调用面
  Object.assign(G, {
    panBy, cancelMomentum, startMomentum, emitScroll, topVisiblePage, endHover,
  });
}
