<script lang="ts">
  // 草稿纸的工具条与列表（入口按钮在顶栏，见 TopBar.svelte）：
  //  · 开着纸时 = 一条工具条（纸名 / 回中 / 适应内容 / minimap / 关闭），压在草稿纸画布之上；
  //  · 列表弹层 = 切换已有的纸 + 新建（顶栏按钮和工具条最左的图标都能开）。
  // 开/关/新建都只是发请求，Mac 是「哪张纸开着」的唯一真源（见 PROTOCOL.md §4.4）。
  //
  // ⚠️ 样式一律写在 web/src/app.css，**不要在这里加 <style> 块**：本组件曾是全项目唯一自带
  // scoped style 的组件，而 Svelte 5 对带 `class:` 指令的元素会漏掉作用域类
  // （生成 `#id.svelte-xxxx{...}` 规则，元素上却没有那个类）→ 样式整块失效、按钮退回
  // position:static 被 z-index 1~7 的 canvas 盖死，界面上彻底看不见。别再走一遍。
  import { S } from "./lib/hud.svelte.js";
  import { actions } from "./lib/actions.js";
  import Icon from "./Icon.svelte";

  const name = (p: { title: string; index: number }) => p.title || "草稿纸 " + (p.index + 1);

  // 纸样备选（与 Mac 端 ScratchPattern / ScratchPad.paperPalette 同一组，改一边要同步另一边）。
  const PATTERNS = [
    { key: "plain", label: "纯色" },
    { key: "dots", label: "点阵" },
    { key: "grid", label: "小格" },
  ];
  const PAPERS = [
    { key: "white", css: "rgba(255,255,255,1.0)" },
    { key: "cream", css: "rgba(252,247,235,1.0)" },
    { key: "gray",  css: "rgba(241,242,245,1.0)" },
    { key: "kraft", css: "rgba(246,236,214,1.0)" },
    { key: "green", css: "rgba(233,243,234,1.0)" },
    { key: "blue",  css: "rgba(234,241,250,1.0)" },
  ];
  /// 线上颜色串的写法可能有细微差异（"1" vs "1.0"），比对时按数值归一。
  const sameColor = (a: string, b: string) => {
    const n = (c: string) => (/rgba?\(([^)]+)\)/.exec(c || "")?.[1] || "")
      .split(",").map((v) => Math.round(parseFloat(v) * 1000) / 1000).join(",");
    return n(a) === n(b);
  };
</script>

{#if S.padOpen >= 0 && S.pads[S.padOpen]}
  <div id="padbar">
    <button title="草稿纸列表" onclick={() => actions.togglePadList()}><Icon name="scratch" /></button>
    <span id="padName">{name(S.pads[S.padOpen])}</span>
    <button title="回中" onclick={() => actions.padRecenter()}><Icon name="scope" /></button>
    <button title="适应内容" onclick={() => actions.padFit()}><Icon name="fit" /></button>
    <button class:on={S.padMini} title="缩略图" onclick={() => actions.togglePadMini()}><Icon name="map" /></button>
    <button class:on={S.padPaper} title="纸样" onclick={() => actions.togglePadPaper()}><Icon name="palette" /></button>
    <button title="关闭草稿纸（Esc）" onclick={() => actions.closePad()}><Icon name="x" /></button>
  </div>
{/if}

{#if S.padPaper && S.padOpen >= 0}
  <button id="padPaperMask" aria-label="关闭纸样" onclick={() => actions.togglePadPaper()}></button>
  <div id="padpaper">
    <div class="phead">底纹</div>
    <div class="prow2">
      {#each PATTERNS as pt (pt.key)}
        <button class="pswatch" class:cur={S.padPattern === pt.key}
          onclick={() => actions.setPadPaper(null, pt.key)}>
          <span class="pv {pt.key}" style="background:{S.padBg || '#fff'}"></span>
          <span class="pl">{pt.label}</span>
        </button>
      {/each}
    </div>
    <div class="phead">纸色</div>
    <div class="prow2">
      {#each PAPERS as c (c.key)}
        <button class="pcolor" class:cur={sameColor(S.padBg, c.css)}
          style="background:{c.css}" aria-label={c.key}
          onclick={() => actions.setPadPaper(c.css, null)}></button>
      {/each}
    </div>
  </div>
{/if}

{#if S.padList}
  <button id="padListMask" aria-label="关闭草稿纸列表" onclick={() => actions.togglePadList()}></button>
  <div id="padlist">
    <div class="phead">草稿纸</div>
    {#if !S.pads.length}
      <div class="pempty">还没有草稿纸</div>
    {/if}
    {#each S.pads as p (p.id)}
      <button class="prow" class:cur={p.index === S.padOpen} onclick={() => actions.openPad(p.index)}>
        <span class="pt">{name(p)}</span>
        <span class="pp">第 {p.page + 1} 页</span>
      </button>
    {/each}
    <button class="prow padd" onclick={() => actions.addPad()}>
      <Icon name="plus" /><span class="pt">在当前位置新建</span>
    </button>
  </div>
{/if}
