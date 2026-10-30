<script lang="ts">
  import { onMount } from "svelte";
  import { documents, message, workspaces, type DocumentInfo } from "./lib/api";
  import { go } from "./lib/nav";
  import { t } from "./lib/i18n";
  import Icon from "./Icon.svelte";

  let { ws }: { ws: string } = $props();

  let name = $state("");
  let docs = $state<DocumentInfo[] | null>(null);
  let error = $state("");
  let filter = $state("");

  /** 按分组排（分组按第一次出现的先后，组内保持服务器给的顺序，即 App 书目的顺序）；没分组的在最前。 */
  const groups = $derived.by(() => {
    const q = filter.trim().toLowerCase();
    const out: { name: string; docs: DocumentInfo[] }[] = [];
    for (const d of docs ?? []) {
      if (q && !d.title.toLowerCase().includes(q) && !d.group.toLowerCase().includes(q)) continue;
      let g = out.find((x) => x.name === d.group);
      if (!g) {
        g = { name: d.group, docs: [] };
        if (d.group === "") out.unshift(g);
        else out.push(g);
      }
      g.docs.push(d);
    }
    return out;
  });

  async function load() {
    error = "";
    try {
      const [list, all] = await Promise.all([documents(ws), workspaces()]);
      docs = list;
      name = all.find((w) => w.id === ws)?.name ?? "";
    } catch (e) {
      error = message(e);
    }
  }

  onMount(load);
</script>

<div class="page">
  <header class="bar">
    <button class="icon" onclick={() => go()} title={t("Back")} aria-label={t("Back")}><Icon name="back" /></button>
    <div class="title">{name}</div>
  </header>
  <main class="list-page">
    {#if error}
      <p class="error">{error}</p>
      <button onclick={load}>{t("Retry")}</button>
    {:else if docs === null}
      <p class="hint">{t("Loading…")}</p>
    {:else if docs.length === 0}
      <p class="hint">{t("No books in this workspace.")}</p>
    {:else}
      <input class="filter" type="search" placeholder={t("Filter")} bind:value={filter} />
      {#if groups.length === 0}
        <p class="hint">{t("No matching books.")}</p>
      {/if}
      {#each groups as g (g.name)}
        {#if groups.length > 1 || g.name !== ""}
          <h3>{g.name || t("Ungrouped")}</h3>
        {/if}
        <ul class="rows">
          {#each g.docs as d (d.id)}
            <li>
              <button class="row" disabled={!d.contentHash} onclick={() => go("w", ws, "d", d.id)}>
                <span class="name">{d.title}</span>
                <span class="meta">{d.contentHash ? t("{0} pages", d.pageCount) : t("PDF not on the server")}</span>
              </button>
            </li>
          {/each}
        </ul>
      {/each}
    {/if}
  </main>
</div>
