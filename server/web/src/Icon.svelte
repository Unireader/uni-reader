<script lang="ts">
  // 线条图标（24×24，跟随文字颜色）。
  let { name }: { name: "back" | "list" | "minus" | "plus" | "chevron" | "pointer" | "eraser" | "note" | "undo" | "redo" | "sidebar" | "panel" | "search" | "logout" } = $props();
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
  {:else if name === "pointer"}
    <path d="M6 3l12 7.5-5.2 1.3L10.5 17z" /><path d="M12.8 11.8L17 18" />
  {:else if name === "eraser"}
    <path d="M15 4.5l4.5 4.5L10 18.5H5.5V14z" /><path d="M11 8.5l4.5 4.5M4 21h16" />
  {:else if name === "note"}
    <path d="M5 4h14v11H10l-5 4z" /><path d="M12 7v5M9.5 9.5h5" />
  {:else if name === "undo"}
    <path d="M9 5L4 10l5 5" /><path d="M4 10h10.5a5 5 0 0 1 0 10H12" />
  {:else if name === "redo"}
    <path d="M15 5l5 5-5 5" /><path d="M20 10H9.5a5 5 0 0 0 0 10H12" />
  {:else if name === "sidebar"}
    <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" /><path d="M9.5 4.5v15" />
  {:else if name === "panel"}
    <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" /><path d="M9 4.5v15M5.5 8.5h1.5M5.5 11.5h1.5" />
  {:else if name === "search"}
    <circle cx="11" cy="11" r="6" /><path d="M20 20l-4.5-4.5" />
  {:else if name === "logout"}
    <path d="M14 4.5H7a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h7" /><path d="M16 8l4 4-4 4M20 12H10" />
  {/if}
</svg>
