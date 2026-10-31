<script lang="ts">
  import { message, pair } from "./lib/api";
  import { t } from "./lib/i18n";

  let { notice = "", onpaired }: { notice?: string; onpaired: () => void } = $props();

  let code = $state("");
  let name = $state(defaultName());
  let busy = $state(false);
  let error = $state("");

  /** 设备名的默认值：「网页 · Android · Chrome」这样，服务器的 `devices` 列表里认得出是哪个浏览器。 */
  function defaultName(): string {
    const ua = navigator.userAgent;
    const device = /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? "iPad"
      : /iPhone/.test(ua) ? "iPhone" : /Android/.test(ua) ? "Android"
      : /Macintosh/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Linux/.test(ua) ? "Linux" : "";
    const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox"
      : /Chrome\/|CriOS\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "";
    return [t("Web"), device, browser].filter(Boolean).join(" · ");
  }

  async function submit(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = "";
    try {
      await pair(code, name);
      onpaired();
    } catch (err) {
      error = message(err);
    } finally {
      busy = false;
    }
  }
</script>

<main class="pair-screen">
  <form class="pair-card" onsubmit={submit}>
    <img class="pair-logo" src="/favicon.svg" alt="" width="48" height="48" />
    <h1><span class="mk on">UniReader</span></h1>
    <p class="hint">{t("Connect this browser to the UniReader server. Run `unireader-server pairing-code` on the server to see the code (it is the same code the Mac and Android apps use).")}</p>
    {#if notice}<p class="error">{notice}</p>{/if}
    <label>
      <span>{t("Pairing Code")}</span>
      <input bind:value={code} required maxlength="16" autocomplete="off" autocapitalize="characters" spellcheck="false" class="code" />
    </label>
    <label>
      <span>{t("Device Name")}</span>
      <input bind:value={name} required maxlength="60" autocomplete="off" />
    </label>
    {#if error}<p class="error">{error}</p>{/if}
    <button type="submit" class="primary wide" disabled={busy || !code.trim() || !name.trim()}>
      {busy ? t("Pairing…") : t("Pair")}
    </button>
  </form>
</main>
