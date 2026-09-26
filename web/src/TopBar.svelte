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
  <button id="drawerBtn" class:on={S.drawer} title="目录 / 书库"
    onclick={() => actions.toggleDrawer()}><Icon name="list" /></button>
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
  <button id="refWin" class:on={S.ref} title="参考窗（另开一本书对照）"
    onclick={() => { S.ref = !S.ref; if (S.ref) S.refCollapsed = false; }}><Icon name="doc" /></button>
  <button id="ruler" class:on={S.rulerOn} title="尺子（45° 吸附直线）" onclick={() => actions.toggleRuler()}><Icon name="ruler" /></button>
  <!-- 撤销/重做：栈在 Mac，这里只是两个按钮（PROTOCOL.md `undo`）。常亮——平板不知道 Mac 那边
       还有没有得撤，为此再加一条 S→C 广播不值当，点了没得撤就是个空操作。 -->
  <button id="undo" title="撤销" onclick={() => actions.undo(false)}><Icon name="undo" /></button>
  <button id="redo" title="重做" onclick={() => actions.undo(true)}><Icon name="redo" /></button>
  <!-- 剪贴板三件：只在框选模式下出现（对象就是选中集）。剪切/复制没选中就灰掉；
       粘贴常亮（同上：Mac 剪贴板里有没有东西平板不知道）。 -->
  {#if S.modeKey === "lasso"}
    <button id="clipCut" title="剪切选中笔迹" disabled={!S.hasSel}
      onclick={() => actions.clipCopy(true)}><Icon name="scissors" /></button>
    <button id="clipCopy" title="复制选中笔迹" disabled={!S.hasSel}
      onclick={() => actions.clipCopy(false)}><Icon name="copy" /></button>
    <button id="clipPaste" title="粘贴到视口中央" onclick={() => actions.clipPaste()}><Icon name="paste" /></button>
  {/if}
  {#if S.boardKind !== 2}
    <button id="padBtn" class:on={S.padOpen >= 0 || S.padList} title="草稿纸" onclick={() => actions.togglePadList()}><Icon name="scratch" /></button>
  {/if}
  <!-- 画板笔记（v16）：列出 / 打开 / 新建都请 Mac 开标签，任何时候都能用 -->
  <button id="boardBtn" class:on={S.boardKind === 2 || S.boardList} title="画板笔记"
    onclick={() => actions.toggleBoardList()}><Icon name="board" /></button>
  <button id="canvasBtn" class:on={S.canvasOn} title="画板模式（页面两侧的空白也能写）"
    onclick={() => actions.toggleCanvas()}><Icon name="canvas" /></button>
  <button id="eye" title="显示/隐藏页面" onclick={() => actions.toggleEye()}><Icon name={S.showPage ? "eye" : "eye-off"} /></button>
  <button id="lock" title="锁定缩放" onclick={() => actions.toggleLock()}><Icon name={S.zoomLocked ? "lock" : "lock-open"} /></button>
  <button id="twoFinger" class:on={S.twoFinger} title="双指滚动（防误触）：单指划动不再平移"
    onclick={() => actions.toggleTwoFinger()}><Icon name="two-finger" /></button>
  <button id="hLock" class:on={S.hLocked} title="锁定水平滚动：拖动/惯性只走纵向（缩放重锚不受影响）"
    onclick={() => actions.toggleHLock()}><Icon name="h-lock" /></button>
  <button id="full" title="全屏" onclick={() => actions.toggleFull()}><Icon name="maximize" /></button>
  <button id="hideBar" title="隐藏顶栏" onclick={() => (hidden = true)}><Icon name="chevron-up" /></button>
</div>
{/if}
