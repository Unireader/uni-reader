<script lang="ts">
  // 延迟统计面板（点顶栏延迟读数开合）；文本由 hud 的 1s 统计区间预排好（white-space:pre 保留换行）。
  import { S } from "./lib/hud.svelte.js";
</script>

<div id="stats" class:on={S.statsOn}>{S.statsText}</div>
