<script lang="ts">
  import Self from "./Outline.svelte";
  import Icon from "./Icon.svelte";
  import type { OutlineNode } from "./lib/pdf";

  let { nodes, onpick, depth = 0 }: { nodes: OutlineNode[]; onpick: (n: OutlineNode) => void; depth?: number } = $props();

  let open = $state<Record<number, boolean>>({});
</script>

<ul class="toc">
  {#each nodes as n, i}
    <li>
      <div class="toc-row" style:padding-left="{4 + depth * 16}px">
        {#if n.children.length}
          <button class="disclosure" class:open={open[i]} onclick={() => (open[i] = !open[i])} aria-expanded={!!open[i]} aria-label={n.title}>
            <Icon name="chevron" />
          </button>
        {:else}
          <span class="disclosure"></span>
        {/if}
        <button class="toc-item" onclick={() => onpick(n)}>{n.title}</button>
      </div>
      {#if n.children.length && open[i]}
        <Self nodes={n.children} {onpick} depth={depth + 1} />
      {/if}
    </li>
  {/each}
</ul>
