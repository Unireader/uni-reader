<script lang="ts">
  // 顶栏：连接绿点 / 延迟读数（点击展开统计）/ 文档下拉 / 缩放与页码标签 / 翻页·夜间·显隐·锁缩放·全屏·收起按钮。
  // 收起后右上角浮一个小按钮，点它重新展开（纯本地 UI 状态，不与 Mac 同步）。
  // 页码标签点击可输入数字直接跳页。
  import { S } from "./lib/hud.svelte.js";
  import { actions } from "./lib/actions.js";
  import Icon from "./Icon.svelte";
  let hidden = $state(false);
  let editingPage = $state(false);
  let inputEl: HTMLInputElement | undefined = $state(undefined);
  let pageInput = $state("");

  function startEdit() {
    pageInput = "";
    editingPage = true;
  }
  function commitPage() {
    editingPage = false;
    const n = parseInt(pageInput, 10);
    if (!isNaN(n) && n >= 1) actions.gotoPage(n);
  }
  function onInputKey(e: KeyboardEvent) {
    if (e.key === "Enter") commitPage();
    if (e.key === "Escape") editingPage = false;
  }
</script>

{#if hidden}
  <button id="showBar" title="显示顶栏" onclick={() => (hidden = false)}><Icon name="chevron-down" /></button>
{:else}
<div id="topbar">
  <span id="dot" class:on={S.connected}></span>
  <span id="lat" role="button" tabindex="0" onclick={() => actions.toggleStats()}>{S.latText}</span>
  <select id="docs" value={S.docValue} onchange={(e) => actions.selectDoc(e.currentTarget.value)}>
    <option value="">⟳ 跟随 Mac</option>
    {#each S.docs as d (d.id)}
      <option value={d.id}>{d.title}</option>
    {/each}
  </select>
  <span id="zoomLabel">{S.zoomLabel}</span>
  {#if editingPage}
    <input
      id="pageInput"
      type="number"
      min="1"
      bind:value={pageInput}
      bind:this={inputEl}
      onkeydown={onInputKey}
      onblur={commitPage}
      placeholder="页号"
    />
  {:else}
    <span id="pageLabel" role="button" tabindex="0" title="点击输入页码跳转" onclick={startEdit}>{S.pageLabel}</span>
  {/if}
  <button id="prev" onclick={() => actions.turn("prev")}>‹</button>
  <button id="next" onclick={() => actions.turn("next")}>›</button>
  <button id="night" title="夜间模式" onclick={() => actions.toggleNight()}><Icon name={S.night ? "sun" : "moon"} /></button>
  <button id="textNote" class:on={S.noteMode} title="文字笔记" onclick={() => actions.toggleTextNote()}><Icon name="type" /></button>
  <button id="ruler" class:on={S.rulerOn} title="尺子（45° 吸附直线）" onclick={() => actions.toggleRuler()}><Icon name="ruler" /></button>
  <button id="eye" title="显示/隐藏页面" onclick={() => actions.toggleEye()}><Icon name={S.showPage ? "eye" : "eye-off"} /></button>
  <button id="lock" title="锁定缩放" onclick={() => actions.toggleLock()}><Icon name={S.zoomLocked ? "lock" : "lock-open"} /></button>
  <button id="full" title="全屏" onclick={() => actions.toggleFull()}><Icon name="maximize" /></button>
  <button id="hideBar" title="隐藏顶栏" onclick={() => (hidden = true)}><Icon name="chevron-up" /></button>
</div>
{/if}
