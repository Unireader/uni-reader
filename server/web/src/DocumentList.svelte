<script lang="ts">
  import { onMount } from "svelte";
  import { documents, message, workspaces, type DocumentInfo } from "./lib/api";
  import { go } from "./lib/nav";
  import { t } from "./lib/i18n";
  import { positionsIn, type Position } from "./lib/position";
  import { setRail, ui } from "./lib/ui.svelte";
  import Icon from "./Icon.svelte";

  let { ws }: { ws: string } = $props();

  let name = $state("");
  let docs = $state<DocumentInfo[] | null>(null);
  let error = $state("");
  let filter = $state("");
  const local = $derived(positionsIn(ws));

  /** 读到哪儿：本浏览器读过的用本浏览器的，否则用服务器上的阅读进度（各设备同步的那份）。 */
  function progress(d: DocumentInfo): { page: number; ratio: number; started: boolean } {
    const p: Position | undefined = local.get(d.id);
    const page = p ? p.page : d.readPage, frac = p ? p.frac : d.readFrac;
    const ratio = d.pageCount > 0 ? Math.min(1, (page + frac) / d.pageCount) : 0;
    return { page: page + 1, ratio, started: page > 0 || frac > 0 };
  }

  /** 继续阅读：本浏览器最近读过的几本（还在服务器上、有 PDF 的）。 */
  const recent = $derived.by(() => {
    const byId = new Map((docs ?? []).map((d) => [d.id, d]));
    return [...local.entries()]
      .filter(([id]) => byId.get(id)?.contentHash)
      .sort((a, b) => (b[1].at ?? 0) - (a[1].at ?? 0))
      .slice(0, 4)
      .map(([id]) => byId.get(id)!);
  });

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

<div class="lib">
  <header class="lib-head">
    {#if !ui.rail}
      <button class="icon" onclick={() => setRail(true)} title={t("Show Sidebar")} aria-label={t("Show Sidebar")}><Icon name="sidebar" /></button>
    {/if}
    <div class="lib-title">
      <h1>{name}</h1>
      {#if docs}<p class="hint">{t("{0} books", docs.length)}</p>{/if}
    </div>
    {#if docs?.length}
      <label class="search">
        <Icon name="search" />
        <input type="search" placeholder={t("Filter books")} bind:value={filter} aria-label={t("Filter books")} />
      </label>
    {/if}
  </header>

  {#if error}
    <div class="lib-empty">
      <p class="error">{error}</p>
      <button onclick={load}>{t("Retry")}</button>
    </div>
  {:else if docs === null}
    <div class="lib-empty"><p class="hint">{t("Loading…")}</p></div>
  {:else if docs.length === 0}
    <div class="lib-empty"><p class="hint">{t("No books in this workspace.")}</p></div>
  {:else}
    {#if recent.length && !filter.trim()}
      <section class="lib-section">
        <h2 class="sec">{t("Continue Reading")}</h2>
        <div class="recent">
          {#each recent as d (d.id)}
            {@const p = progress(d)}
            <button class="recent-card" onclick={() => go("w", ws, "d", d.id)}>
              <span class="recent-title">{d.title}</span>
              <span class="recent-meta">{t("Page {0} of {1}", Math.min(p.page, d.pageCount), d.pageCount)}</span>
              <span class="meter"><i style:width="{p.ratio * 100}%"></i></span>
            </button>
          {/each}
        </div>
      </section>
    {/if}

    {#if groups.length === 0}
      <div class="lib-empty"><p class="hint">{t("No matching books.")}</p></div>
    {/if}
    {#each groups as g (g.name)}
      <section class="lib-section">
        {#if groups.length > 1 || g.name !== ""}
          <h2 class="sec">{g.name || t("Ungrouped")}<span class="count">{g.docs.length}</span></h2>
        {/if}
        <ul class="books">
          {#each g.docs as d (d.id)}
            {@const p = progress(d)}
            <li>
              <button class="book" disabled={!d.contentHash} onclick={() => go("w", ws, "d", d.id)}>
                <span class="book-title">{d.title}</span>
                {#if !d.contentHash}
                  <span class="book-meta">{t("PDF not on the server")}</span>
                {:else if p.started}
                  <span class="book-meta">
                    <span class="meter"><i style:width="{p.ratio * 100}%"></i></span>
                    <span class="num">{Math.min(p.page, d.pageCount)} / {d.pageCount}</span>
                  </span>
                {:else}
                  <span class="book-meta"><span class="num">{t("{0} pages", d.pageCount)}</span></span>
                {/if}
              </button>
            </li>
          {/each}
        </ul>
      </section>
    {/each}
  {/if}
</div>
