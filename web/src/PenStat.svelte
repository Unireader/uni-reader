<script lang="ts">
  // 笔的用途状态胶囊：笔记模式显示当前笔（色块/类型/粗细），其余模式显示模式名。
  // 点击弹层面板：调每支笔的宽度（2...40，防抖上行 penset）与橡皮设置——整笔/局部模式、
  // 直径（页宽 %）、尺寸圆环开关（防抖上行 eraser，与 Mac 端 PenRack 橡皮 popover 双向同步）。
  import { S, updateHud } from "./lib/hud.svelte.js";
  import { BRUSH_LABELS, G } from "./lib/shared.js";
  import type { Pen } from "./lib/shared.js";

  let open = $state(false);
  let pens = $state<Pen[]>([]);
  let eraserPct = $state(4);   // 橡皮直径占页宽 %（= 归一化半径 × 200）
  let eraserMode = $state(1);  // 0=整笔 1=局部
  let eraserRing = $state(true);

  function toggle(): void {
    if (open) { open = false; return; }
    // 打开瞬间快照：PENS 会被 Mac 的 pens 广播整体替换，面板编辑期间用本地副本，提交时读 G 最新值
    pens = G.PENS.map((p) => ({ color: p.color, w: p.w, t: p.t }));
    eraserPct = Math.round(G.eraserSize * 2000) / 10;
    eraserMode = G.eraserMode;
    eraserRing = G.eraserRing;
    open = true;
  }

  let penTimer: ReturnType<typeof setTimeout> | null = null;
  function penChanged(): void {
    // 本地即时生效（画/live 反馈读的笔宽就是 G.PENS），HUD 胶囊同步刷新
    for (let i = 0; i < pens.length && i < G.PENS.length; i++) G.PENS[i].w = pens[i].w;
    updateHud();
    if (penTimer) clearTimeout(penTimer);
    penTimer = setTimeout(() => {
      penTimer = null;
      // Mac 收到后按下标对齐写回 app.pens 并 broadcastPens 回声（协议 PROTOCOL.md §4.1 penset）
      G.send({ type: "penset", list: G.PENS.map((p) => ({ color: p.color, w: p.w, t: p.t })), active: G.penIdx });
    }, 300);
  }

  // 橡皮三项（尺寸/模式/圆环）共用一条 eraser 消息上行：任何一项改动都防抖重发全量
  let eraserTimer: ReturnType<typeof setTimeout> | null = null;
  function scheduleEraser(): void {
    if (eraserTimer) clearTimeout(eraserTimer);
    eraserTimer = setTimeout(() => {
      eraserTimer = null;
      G.send({ type: "eraser", size: G.eraserSize, mode: G.eraserMode, ring: G.eraserRing ? 1 : 0 });
    }, 300);
  }
  function eraserChanged(): void {
    G.eraserSize = eraserPct / 200;   // % = 直径；归一化半径 = 直径/2
    scheduleEraser();
  }
  function modeChanged(m: number): void {
    eraserMode = m; G.eraserMode = m;
    scheduleEraser();
  }
  function ringChanged(): void {
    G.eraserRing = eraserRing;
    if (!eraserRing) { G.eraserRingAt = null; G.drawNotes(); }   // 关掉立即撤环
    scheduleEraser();
  }
</script>

<div id="penStat" role="button" tabindex="0" onclick={toggle} onkeydown={(e) => { if (e.key === "Enter") toggle(); }}>
  {#if S.modeKey === "note"}
    {#if S.pen}
      <span class="sw" style:background={S.pen.color}></span>{BRUSH_LABELS[S.pen.t] || "圆珠笔"} · {Math.round(S.pen.w * 100) / 100}pt
    {:else}
      笔记
    {/if}
  {:else if S.modeKey === "erase"}
    橡皮擦
  {:else}
    翻页 · 拖动平移
  {/if}
</div>

{#if open}
  <button id="penPanelMask" aria-label="关闭" onclick={() => (open = false)}></button>
  <div id="penPanel">
    <div class="ptitle">笔宽</div>
    {#each pens as p, i}
      <div class="prow">
        <span class="sw" style:background={p.color}></span>
        <span class="pname">{BRUSH_LABELS[p.t] || "圆珠笔"}</span>
        <input type="range" min="2" max="40" step="1" bind:value={pens[i].w} oninput={penChanged} />
        <span class="pval">{Math.round(p.w)}</span>
      </div>
    {/each}
    <div class="ptitle">橡皮</div>
    <div class="prow">
      <span class="seg">
        <button class:on={eraserMode === 0} onclick={() => modeChanged(0)}>整笔</button><button class:on={eraserMode === 1} onclick={() => modeChanged(1)}>局部</button>
      </span>
      <label class="ringchk"><input type="checkbox" bind:checked={eraserRing} onchange={ringChanged} />圆环</label>
    </div>
    <div class="prow">
      <span class="pname">直径</span>
      <input type="range" min="1" max="12" step="0.5" bind:value={eraserPct} oninput={eraserChanged} />
      <span class="pval">{eraserPct}%</span>
    </div>
  </div>
{/if}
