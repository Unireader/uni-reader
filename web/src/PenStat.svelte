<script lang="ts">
  // 笔的用途状态胶囊：笔记模式显示当前笔（色块/类型/粗细），其余模式显示模式名。
  import { S } from "./lib/hud.svelte.js";
  import { BRUSH_LABELS } from "./lib/shared.js";
</script>

<div id="penStat">
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
