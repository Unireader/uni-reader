<script lang="ts">
  // 顶栏：连接绿点 / 延迟读数（点击展开统计）/ 文档下拉 / 缩放与页码标签 / 翻页·夜间·显隐·锁缩放·全屏按钮。
  import { S } from "./lib/hud.svelte.js";
  import { actions } from "./lib/actions.js";
</script>

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
  <span id="pageLabel">{S.pageLabel}</span>
  <button id="prev" onclick={() => actions.turn("prev")}>‹</button>
  <button id="next" onclick={() => actions.turn("next")}>›</button>
  <button id="night" title="夜间模式" onclick={() => actions.toggleNight()}>{S.night ? "☀️" : "🌙"}</button>
  <button id="eye" title="显示/隐藏页面" onclick={() => actions.toggleEye()}>{S.showPage ? "👁" : "🚫"}</button>
  <button id="lock" title="锁定缩放" onclick={() => actions.toggleLock()}>{S.zoomLocked ? "🔒" : "🔓"}</button>
  <button id="full" onclick={() => actions.toggleFull()}>⛶</button>
</div>
