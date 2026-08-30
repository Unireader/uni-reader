<script lang="ts">
  // 参考窗：浮在采集页之上的**只读** PDF 小窗（方案 `../../REF-WINDOW-PLAN.md`）。
  // 没有笔迹、没有批注、没有选笔盘——就是「另开一本书摆在旁边对照」。
  //
  // 与 Mac 端同一套规格：打开定位到那本书在库里的阅读进度；折叠→展开保持滚动位置，
  // 关闭→重开回到进度；位置/尺寸/看的哪本都是**本端私有**（localStorage），不上线不落库。
  //
  // 页图直接走既有的 `/page.png`（加了 `d=` 参数取别的文档），元信息走 `/docmeta?d=`。
  // 🔴 样式一律写在 app.css：Svelte 5 对带 `class:` 指令的元素会漏掉作用域类，
  // 组件内 <style> 曾让 PadBar 整块样式失效（2026-08-07）。
  import { tick } from "svelte";
  import { S } from "./lib/hud.svelte.js";
  import Icon from "./Icon.svelte";

  const GAP = 8;
  // 与 Mac `LANServer.pageWidthSteps` / 安卓 `PageWidths.kt` 同一张阶梯，缓存才互相命中。
  const WIDTH_STEPS = [480, 720, 1080, 1440, 2160, 2880];
  const MIN_W = 240, MIN_H = 200, EDGE = 10;
  const LS = "refwin.box";

  let box = $state(loadBox());
  let zoom = $state(1);
  let scroller: HTMLDivElement | undefined = $state(undefined);
  let scrollTop = $state(0);
  let clientW = $state(0), clientH = $state(0);
  let picker = $state(false);
  /// 已按第几版 seedRev 定位过。折叠→展开时组件会重建，但这个值活在模块级不了——
  /// 所以位置记忆放在 S 里（见 refViewPage/refViewFrac），这里只记「本次挂载定位过没有」。
  let seededRev = $state(-1);
  let restored = $state(false);
  /// 取图宽度只在停手后才换档：捏合中途换 `src` 会让每张图重新加载、白一下。
  let settledW = $state(0);
  let settleTimer: ReturnType<typeof setTimeout> | null = null;

  function loadBox() {
    try {
      const v = JSON.parse(localStorage.getItem(LS) || "");
      if (v && v.w >= MIN_W && v.h >= MIN_H) return v as { w: number; h: number; x: number; y: number };
    } catch { /* 没存过或坏了都走默认 */ }
    return { w: Math.round(Math.min(420, innerWidth * 0.42)), h: Math.round(innerHeight * 0.55), x: 0, y: 0 };
  }
  function saveBox() { try { localStorage.setItem(LS, JSON.stringify(box)); } catch { /* 隐私模式等：存不了就算了 */ } }

  // ---- 几何：全部由「内容区宽 × zoom」推出，(page, frac) 是位置真源 ----
  const pageW = $derived(Math.max(1, clientW * zoom));
  const dispH = $derived(S.refPages.map(([w, h]) => (w > 0 ? (pageW * h) / w : pageW * 1.414)));
  const offY = $derived.by(() => {
    const out: number[] = []; let y = 0;
    for (const h of dispH) { out.push(y); y += h + GAP; }
    return out;
  });
  const totalH = $derived(dispH.length ? offY[offY.length - 1] + dispH[dispH.length - 1] : 0);
  const visible = $derived.by(() => {
    const out: number[] = [];
    if (!dispH.length || clientH <= 0) return out;
    const top = scrollTop - clientH, bot = scrollTop + clientH * 2;   // 可见 ±1 屏
    for (let i = 0; i < dispH.length; i++) if (offY[i] + dispH[i] >= top && offY[i] <= bot) out.push(i);
    return out;
  });

  function snapW(px: number) {
    const w = Math.max(1, Math.round(px));
    return WIDTH_STEPS.find((s) => s >= w) ?? WIDTH_STEPS[WIDTH_STEPS.length - 1];
  }
  function src(i: number) {
    const w = settledW || snapW(pageW * (devicePixelRatio || 1));
    return `/page.png?d=${encodeURIComponent(S.refDocId)}&i=${i}&w=${w}`;
  }
  function scheduleSettle() {
    if (settleTimer) clearTimeout(settleTimer);
    settleTimer = setTimeout(() => { settledW = snapW(pageW * (devicePixelRatio || 1)); }, 180);
  }

  /// 视口顶端落在哪一页的哪个比例。**位置真源用 (page, frac) 而不是像素**：
  /// 页宽一变像素就全变，而 (page, frac) 天然守恒——缩放/改尺寸都不用补偿计算。
  function posAt(y: number) {
    if (!dispH.length) return { page: 0, frac: 0 };
    for (let i = 0; i < dispH.length; i++) {
      if (y < offY[i] + dispH[i] || i === dispH.length - 1) {
        return { page: i, frac: Math.min(1, Math.max(0, (y - offY[i]) / Math.max(1, dispH[i]))) };
      }
    }
    return { page: 0, frac: 0 };
  }
  function yOf(page: number, frac: number) {
    const i = Math.min(Math.max(0, page), Math.max(0, dispH.length - 1));
    return (offY[i] ?? 0) + frac * (dispH[i] ?? 0);
  }
  function clampTop(y: number) { return Math.min(Math.max(0, y), Math.max(0, totalH - clientH)); }

  function onScroll() {
    if (!scroller) return;
    scrollTop = scroller.scrollTop;
    const p = posAt(scrollTop);
    S.refViewPage = p.page; S.refViewFrac = p.frac;   // 折叠→展开靠它复位
    S.refCurPage = posAt(scrollTop + clientH * 0.3).page;
  }

  /// 定位：打开/换书/「回到进度」→ 进度；折叠→展开 → 上次看到的地方。
  async function reposition() {
    if (!scroller || !dispH.length || clientH <= 0) return;
    let page: number, frac: number;
    if (seededRev !== S.refSeedRev) {
      seededRev = S.refSeedRev; restored = true;
      page = S.refSeedPage; frac = S.refSeedFrac;
    } else if (!restored) {
      restored = true;
      page = S.refViewPage; frac = S.refViewFrac;
    } else return;
    await tick();
    scroller.scrollTop = clampTop(yOf(page, frac));
    scrollTop = scroller.scrollTop;
  }
  // 几何一就绪（或换了一版 seed）就定位。两条路谁先到谁负责。
  $effect(() => { void S.refSeedRev; void dispH.length; void clientH; reposition(); });
  $effect(() => { void pageW; scheduleSettle(); });

  // ---- 换书 ----
  async function pick(id: string) {
    picker = false;
    if (!id) return;
    try {
      const r = await fetch(`/docmeta?d=${encodeURIComponent(id)}`);
      if (!r.ok) return;
      const m = await r.json();
      S.refDocId = id;
      S.refTitle = m.title || "";
      S.refPages = (m.pages || []) as [number, number][];
      S.refPageCount = m.pageCount || 0;
      S.refSeedPage = m.readPage || 0;
      S.refSeedFrac = m.readFrac || 0;
      S.refViewPage = S.refSeedPage; S.refViewFrac = S.refSeedFrac;
      S.refSeedRev++;
      zoom = 1; settledW = 0;
      try { localStorage.setItem("refwin.doc", id); } catch { /* 存不了就算了 */ }
    } catch { /* 取不到就保持原样，不清空已经在看的那本 */ }
  }
  function rewind() {
    S.refViewPage = S.refSeedPage; S.refViewFrac = S.refSeedFrac;
    S.refSeedRev++;
  }
  // 首次打开：沿用上次那本，没有就用 Mac 当前跟随的那本。
  $effect(() => {
    if (!S.ref || S.refDocId) return;
    const last = (() => { try { return localStorage.getItem("refwin.doc") || ""; } catch { return ""; } })();
    const fallback = S.library.find((d) => d.open)?.id || S.library[0]?.id || "";
    const want = S.library.some((d) => d.id === last) ? last : fallback;
    if (want) pick(want);
  });

  // ---- 摆位 / 改尺寸（指针拖拽） ----
  //
  // 🔴 **标题栏整条都能拖，而且不妨碍里面的按钮**：按下不抢、不 `preventDefault`，
  // 移动超过阈值才算拖动，拖过就抑制随后的 click。原先在按钮上 `stopPropagation`，
  // 结果只有按钮之间那点空隙能拖（安卓端同款毛病，用户 2026-08-30 实测报的第三条）。
  //
  // 监听挂 window 而不是 setPointerCapture：捕获会打乱子按钮的 click 判定，而 window
  // 监听既保证拖出小窗也不断，又完全不碰按钮。
  const SLOP = 4;
  let drag: { mode: "move" | "w" | "h" | "wh"; x: number; y: number; b: typeof box } | null = null;
  let dragged = false;
  let suppressClick = false;

  function down(mode: "move" | "w" | "h" | "wh", e: PointerEvent) {
    if (mode !== "move") { e.stopPropagation(); e.preventDefault(); }   // 尺寸手柄直接接管
    drag = { mode, x: e.clientX, y: e.clientY, b: { ...box } };
    dragged = false;
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up, { once: true });
    window.addEventListener("pointercancel", up, { once: true });
  }
  function move(e: PointerEvent) {
    if (!drag) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!dragged && Math.hypot(dx, dy) < SLOP) return;   // 还没过阈值：可能只是想点按钮
    dragged = true;
    if (drag.mode === "move") {
      box.x = Math.min(0, Math.max(drag.b.x + dx, -(innerWidth - box.w - 16)));
      box.y = Math.min(0, Math.max(drag.b.y + dy, -(innerHeight - box.h - 16)));
    } else {
      // 往左上拖 = 变大（右下角固定不动，同 Mac 端）
      if (drag.mode !== "h") box.w = Math.min(Math.max(drag.b.w - dx, MIN_W), innerWidth - 24);
      if (drag.mode !== "w") box.h = Math.min(Math.max(drag.b.h - dy, MIN_H), innerHeight - 24);
    }
  }
  function up() {
    window.removeEventListener("pointermove", move);
    if (!drag) return;
    const moved = dragged;
    drag = null; dragged = false;
    if (moved) {
      saveBox();
      suppressClick = true;                       // 拖完那一下别再当成点击
      setTimeout(() => (suppressClick = false), 0);
    }
  }

  // ---- 双指捏合缩放（锚在两指中点） ----
  let pinch: { d: number; z: number; midY: number; page: number; frac: number } | null = null;
  function dist(t: TouchList) {
    const dx = t[0].clientX - t[1].clientX, dy = t[0].clientY - t[1].clientY;
    return Math.hypot(dx, dy);
  }
  function touchStart(e: TouchEvent) {
    if (e.touches.length !== 2 || !scroller) return;
    const rect = scroller.getBoundingClientRect();
    const midY = (e.touches[0].clientY + e.touches[1].clientY) / 2 - rect.top;
    const p = posAt(scrollTop + midY);
    pinch = { d: dist(e.touches), z: zoom, midY, page: p.page, frac: p.frac };
  }
  async function touchMove(e: TouchEvent) {
    if (!pinch || e.touches.length !== 2 || !scroller) return;
    e.preventDefault();
    const nz = Math.min(6, Math.max(1, (pinch.z * dist(e.touches)) / Math.max(1, pinch.d)));
    if (Math.abs(nz - zoom) < 0.002) return;
    zoom = nz;
    await tick();   // 等新页宽落到 DOM 上，再按守恒的 (page, frac) 把中点摆回原处
    scroller.scrollTop = clampTop(yOf(pinch.page, pinch.frac) - pinch.midY);
    scrollTop = scroller.scrollTop;
  }
  function touchEnd(e: TouchEvent) { if (e.touches.length < 2) pinch = null; }

  // 改尺寸后页宽跟着变 → 按守恒的 (page, frac) 把视口对回去。
  $effect(() => {
    void box.w;
    if (!scroller || !restored) return;
    const page = S.refViewPage, frac = S.refViewFrac;
    tick().then(() => {
      if (!scroller) return;
      scroller.scrollTop = clampTop(yOf(page, frac));
      scrollTop = scroller.scrollTop;
    });
  });
</script>

{#if S.ref}
  {#if S.refCollapsed}
    <button class="refBubble" style="right:{16 - box.x}px; bottom:{16 - box.y}px"
      title="参考窗" onclick={() => (S.refCollapsed = false)}><Icon name="book" /></button>
  {:else}
    <div class="refWin" style="width:{box.w}px; height:{box.h}px; right:{14 - box.x}px; bottom:{14 - box.y}px">
      <!-- 尺寸手柄：左 / 上 / 左上角三条透明热区（同 Mac 端，不画图标） -->
      <div class="refEdge refEdgeW" role="presentation" onpointerdown={(e) => down("w", e)}></div>
      <div class="refEdge refEdgeH" role="presentation" onpointerdown={(e) => down("h", e)}></div>
      <div class="refEdge refEdgeWH" role="presentation" onpointerdown={(e) => down("wh", e)}></div>

      <div class="refBar" role="presentation" onpointerdown={(e) => down("move", e)}>
        <button class="refPick" onclick={() => { if (!suppressClick) picker = !picker; }}>
          <Icon name="book" /><span class="refTitle">{S.refTitle || "参考"}</span>
        </button>
        {#if box.w >= 300 && S.refPageCount}
          <span class="refPage">{S.refCurPage + 1} / {S.refPageCount}</span>
        {/if}
        <button class="refBtn" title="回到进度"
          onclick={() => { if (!suppressClick) rewind(); }}><Icon name="scope" /></button>
        <button class="refBtn" title="收起"
          onclick={() => { if (!suppressClick) S.refCollapsed = true; }}><Icon name="chevron-down" /></button>
        <button class="refBtn" title="关闭"
          onclick={() => { if (!suppressClick) S.ref = false; }}><Icon name="x" /></button>
      </div>

      {#if picker}
        <div class="refPicker">
          {#each S.library as d (d.id)}
            <button class="refPickItem" class:on={d.id === S.refDocId} onclick={() => pick(d.id)}>{d.title}</button>
          {/each}
          {#if !S.library.length}<p class="refEmpty">工作区里没有别的文档</p>{/if}
        </div>
      {/if}

      <div class="refBody" class:night={S.night} role="group" aria-label="参考文档" bind:this={scroller}
        bind:clientWidth={clientW} bind:clientHeight={clientH}
        onscroll={onScroll} ontouchstart={touchStart} ontouchmove={touchMove}
        ontouchend={touchEnd} ontouchcancel={touchEnd}>
        <div class="refContent" style="height:{totalH}px">
          {#each visible as i (i)}
            <img class="refImg" alt="" src={src(i)}
              style="top:{offY[i]}px; left:{(Math.max(pageW, clientW) - pageW) / 2}px; width:{pageW}px; height:{dispH[i]}px" />
          {/each}
        </div>
      </div>
    </div>
  {/if}
{/if}
