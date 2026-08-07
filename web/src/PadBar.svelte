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
</script>

{#if S.padOpen >= 0 && S.pads[S.padOpen]}
  <div id="padbar">
    <button title="草稿纸列表" onclick={() => actions.togglePadList()}><Icon name="scratch" /></button>
    <span id="padName">{name(S.pads[S.padOpen])}</span>
    <button title="回中" onclick={() => actions.padRecenter()}><Icon name="scope" /></button>
    <button title="适应内容" onclick={() => actions.padFit()}><Icon name="fit" /></button>
    <button class:on={S.padMini} title="缩略图" onclick={() => actions.togglePadMini()}><Icon name="map" /></button>
    <button title="关闭草稿纸（Esc）" onclick={() => actions.closePad()}><Icon name="x" /></button>
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
