<script lang="ts">
  // 线条图标（24×24，跟随文字颜色）。
  let { name }: { name: "back" | "list" | "minus" | "plus" | "chevron" } = $props();
</script>

<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" fill="none" stroke="currentColor"
     stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  {#if name === "back"}
    <path d="M15 5l-7 7 7 7" />
  {:else if name === "list"}
    <path d="M9 6h11M9 12h11M9 18h11M4.5 6h.01M4.5 12h.01M4.5 18h.01" />
  {:else if name === "minus"}
    <path d="M5 12h14" />
  {:else if name === "plus"}
    <path d="M12 5v14M5 12h14" />
  {:else if name === "chevron"}
    <path d="M9 6l6 6-6 6" />
  {/if}
</svg>
