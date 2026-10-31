<script lang="ts">
  import { onMount } from "svelte";
  import { message, serverName, signOut, workspaces, type Workspace } from "./lib/api";
  import { go, lastWorkspace } from "./lib/nav";
  import { t } from "./lib/i18n";
  import { narrow, setRail } from "./lib/ui.svelte";
  import Icon from "./Icon.svelte";

  let { current, onsignout }: { current: string | null; onsignout: () => void } = $props();

  let list = $state<Workspace[] | null>(null);
  let error = $state("");

  async function load() {
    error = "";
    try {
      list = (await workspaces()).sort((a, b) => a.name.localeCompare(b.name));
      // 打开网页时（`#/`）直接进上次的工作区；没有就进第一个
      if (!current && list.length) {
        const last = lastWorkspace();
        go("w", list.some((w) => w.id === last) ? last! : list[0].id);
      }
    } catch (e) {
      error = message(e);
    }
  }

  function pick(id: string) {
    go("w", id);
    if (narrow()) setRail(false);
  }

  function leave() {
    if (!confirm(t("Sign out of this server in this browser? You will need the pairing code to connect again."))) return;
    signOut();
    onsignout();
  }

  onMount(load);
</script>

<aside class="rail" aria-label={t("Workspaces")}>
  <div class="rail-head">
    <img class="rail-logo" src="/favicon.svg" alt="" width="28" height="28" />
    <div class="rail-id">
      <div class="rail-app">UniReader</div>
      <div class="rail-server">{serverName() || t("Server")}</div>
    </div>
    <button class="icon rail-close" onclick={() => setRail(false)} title={t("Hide Sidebar")} aria-label={t("Hide Sidebar")}>
      <Icon name="sidebar" />
    </button>
  </div>
  <div class="rail-label">{t("Workspaces")}</div>
  <nav class="rail-list">
    {#if error}
      <p class="rail-note error">{error}</p>
      <button class="rail-retry" onclick={load}>{t("Retry")}</button>
    {:else if list === null}
      <p class="rail-note">{t("Loading…")}</p>
    {:else if list.length === 0}
      <p class="rail-note">{t("No workspaces on the server yet. Upload one from UniReader on the Mac.")}</p>
    {:else}
      {#each list as w (w.id)}
        <button class="rail-item" class:current={w.id === current} aria-current={w.id === current ? "page" : undefined}
                onclick={() => pick(w.id)}>
          <span class="mk" class:on={w.id === current}>{w.name}</span>
        </button>
      {/each}
    {/if}
  </nav>
  <div class="rail-foot">
    <button class="rail-item quiet" onclick={leave}><Icon name="logout" /><span>{t("Sign Out")}</span></button>
  </div>
</aside>
