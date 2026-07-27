<script lang="ts">
  // 多层笔迹状态胶囊：显示当前作画图层（色点+名称）。点击弹层面板：切换作画图层/显示隐藏某层/
  // 新建图层——三者都只是「请求」，图层的增删改全部由 Mac 判定，这里发完消息不本地抢改列表，
  // 等 Mac 执行后广播 layers 回权威状态（ws.ts 的 "layers" 分支落地进 S.layers/S.layerIdx）。
  import { S } from "./lib/hud.svelte.js";
  import { G } from "./lib/shared.js";
  import Icon from "./Icon.svelte";

  let open = $state(false);

  function toggle(): void { open = !open; }

  function selectLayer(i: number): void {
    G.send({ type: "layerSelect", index: i });
  }
  function toggleVisible(i: number, e: MouseEvent): void {
    e.stopPropagation();   // 别连带触发行上的 selectLayer
    const l = S.layers[i];
    if (!l) return;
    G.send({ type: "layerVisible", index: i, visible: !l.visible });
  }
  function addLayer(): void {
    G.send({ type: "layerAdd" });
  }
</script>

<div id="layerStat" role="button" tabindex="0" onclick={toggle} onkeydown={(e) => { if (e.key === "Enter") toggle(); }}>
  <Icon name="layers" />
  {#if S.layers[S.layerIdx]}
    <span class="sw" style:background={`rgb(${S.layers[S.layerIdx].r},${S.layers[S.layerIdx].g},${S.layers[S.layerIdx].b})`}></span>{S.layers[S.layerIdx].name}
  {:else}
    图层
  {/if}
</div>

{#if open}
  <button id="layerPanelMask" aria-label="关闭" onclick={() => (open = false)}></button>
  <div id="layerPanel">
    {#each S.layers as l, i}
      <div class="lrow" class:active={i === S.layerIdx} role="button" tabindex="0"
           onclick={() => selectLayer(i)} onkeydown={(e) => { if (e.key === "Enter") selectLayer(i); }}>
        <button class="eye" aria-label={l.visible ? "隐藏图层" : "显示图层"} onclick={(e) => toggleVisible(i, e)}>
          <Icon name={l.visible ? "eye" : "eye-off"} />
        </button>
        <span class="sw" style:background={`rgb(${l.r},${l.g},${l.b})`}></span>
        <span class="lname">{l.name}</span>
      </div>
    {/each}
    <button class="laddbtn" onclick={addLayer}><Icon name="plus" />新建图层</button>
  </div>
{/if}
