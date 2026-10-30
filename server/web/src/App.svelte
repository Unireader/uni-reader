<script lang="ts">
  import { onMount } from "svelte";
  import { onUnauthorized, token } from "./lib/api";
  import { parseHash } from "./lib/nav";
  import { t } from "./lib/i18n";
  import Pair from "./Pair.svelte";
  import WorkspaceList from "./WorkspaceList.svelte";
  import DocumentList from "./DocumentList.svelte";
  import Reader from "./Reader.svelte";

  let parts = $state(parseHash());
  let paired = $state(token() !== null);
  let notice = $state("");

  // 明文 HTTP 且不是本机：配对码、令牌、笔记都在网上明着走
  const insecure = location.protocol === "http:" && !["localhost", "127.0.0.1", "[::1]"].includes(location.hostname);

  onUnauthorized(() => {
    paired = false;
    notice = t("This browser's pairing is no longer valid (the device may have been revoked). Pair again.");
  });

  onMount(() => {
    const f = () => (parts = parseHash());
    addEventListener("hashchange", f);
    return () => removeEventListener("hashchange", f);
  });

  const reading = $derived(paired && parts[0] === "w" && !!parts[1] && parts[2] === "d" && !!parts[3]);
</script>

{#if insecure && !reading}
  <div class="warning">{t("This page is open over plain HTTP: the pairing code, the token and your notes can be seen by others on the same network. Use HTTPS when connecting from outside your home network.")}</div>
{/if}

{#if !paired}
  <Pair {notice} onpaired={() => { paired = true; notice = ""; }} />
{:else if reading}
  {#key parts[1] + "/" + parts[3]}
    <Reader ws={parts[1]} doc={parts[3]} />
  {/key}
{:else if parts[0] === "w" && parts[1]}
  {#key parts[1]}
    <DocumentList ws={parts[1]} />
  {/key}
{:else}
  <WorkspaceList onsignout={() => (paired = false)} />
{/if}
