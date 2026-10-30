<script lang="ts">
  import { onMount } from "svelte";
  import { message, serverName, signOut, workspaces, type Workspace } from "./lib/api";
  import { go } from "./lib/nav";
  import { t } from "./lib/i18n";
  import Icon from "./Icon.svelte";

  let { onsignout }: { onsignout: () => void } = $props();

  let list = $state<Workspace[] | null>(null);
  let error = $state("");

  async function load() {
    error = "";
    try {
      list = (await workspaces()).sort((a, b) => a.name.localeCompare(b.name));
    } catch (e) {
      error = message(e);
    }
  }

  function leave() {
    if (!confirm(t("Sign out of this server in this browser? You will need the pairing code to connect again."))) return;
    signOut();
    onsignout();
  }

  onMount(load);
</script>

<div class="page">
  <header class="bar">
    <div class="title">{serverName() || "UniReader"}</div>
    <button class="text" onclick={leave}>{t("Sign Out")}</button>
  </header>
  <main class="list-page">
    <h2>{t("Workspaces")}</h2>
    {#if error}
      <p class="error">{error}</p>
      <button onclick={load}>{t("Retry")}</button>
    {:else if list === null}
      <p class="hint">{t("Loading…")}</p>
    {:else if list.length === 0}
      <p class="hint">{t("No workspaces on the server yet. Upload one from UniReader on the Mac.")}</p>
    {:else}
      <ul class="rows">
        {#each list as w (w.id)}
          <li>
            <button class="row" onclick={() => go("w", w.id)}>
              <span class="name">{w.name}</span>
              <Icon name="chevron" />
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </main>
</div>
