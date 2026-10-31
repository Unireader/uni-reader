<script lang="ts">
  import { onMount } from "svelte";
  import { onUnauthorized, token } from "./lib/api";
  import { parseHash, rememberWorkspace } from "./lib/nav";
  import { t } from "./lib/i18n";
  import { routeChanged, setRail, ui } from "./lib/ui.svelte";
  import Pair from "./Pair.svelte";
  import Sidebar from "./Sidebar.svelte";
  import DocumentList from "./DocumentList.svelte";
  import Reader from "./Reader.svelte";

  let parts = $state(parseHash());
  let paired = $state(token() !== null);
  let notice = $state("");

  // 明文 HTTP 且不是本机：配对码、令牌、笔记都在网上明着走
  const insecure = location.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);

  const ws = $derived(parts[0] === "w" && parts[1] ? parts[1] : null);
  const reading = $derived(!!ws && parts[2] === "d" && !!parts[3]);

  onUnauthorized(() => {
    paired = false;
    notice = t("This browser's pairing is no longer valid (the device may have been revoked). Pair again.");
  });

  onMount(() => {
    routeChanged(reading);
    const f = () => {
      parts = parseHash();
      routeChanged(reading);
    };
    addEventListener("hashchange", f);
    return () => removeEventListener("hashchange", f);
  });

  $effect(() => {
    if (ws) rememberWorkspace(ws);
  });
</script>

{#if !paired}
  <Pair {notice} onpaired={() => { paired = true; notice = ""; }} />
{:else}
  <div class="shell" class:rail-open={ui.rail}>
    <Sidebar current={ws} onsignout={() => (paired = false)} />
    {#if ui.rail}<button class="scrim" onclick={() => setRail(false)} aria-label={t("Hide Sidebar")}></button>{/if}
    <main class="main">
      {#if insecure && !reading}
        <div class="warning">{t("This page is open over plain HTTP: the pairing code, the token and your notes can be seen by others on the same network. Use HTTPS when connecting from outside your home network.")}</div>
      {/if}
      {#if reading}
        {#key parts[1] + "/" + parts[3]}
          <Reader ws={parts[1]} doc={parts[3]} />
        {/key}
      {:else if ws}
        {#key ws}
          <DocumentList {ws} />
        {/key}
      {:else}
        <div class="empty-state">
          <p>{t("Pick a workspace on the left.")}</p>
        </div>
      {/if}
    </main>
  </div>
{/if}
