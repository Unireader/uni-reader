<script lang="ts">
  // 采集端外壳：5 层 canvas + 选笔盘毛玻璃底盘（命令式绘制，归 lib/render.ts），
  // 顶栏/统计面板/笔状态胶囊是 Svelte 组件（响应式回显，归 lib/hud.svelte.ts 的 S）。
  import { onMount } from "svelte";
  import TopBar from "./TopBar.svelte";
  import Drawer from "./Drawer.svelte";
  import StatsPanel from "./StatsPanel.svelte";
  import PenStat from "./PenStat.svelte";
  import LayerStat from "./LayerStat.svelte";
  import TextNoteEditor from "./TextNoteEditor.svelte";
  import PadBar from "./PadBar.svelte";
  import { startCapture } from "./lib/capture.js";
  import { PORT, TOKEN, PENS } from "./lib/config.js";

  let bg: HTMLCanvasElement;
  let ink: HTMLCanvasElement;
  let live: HTMLCanvasElement;
  let hover: HTMLCanvasElement;
  let radial: HTMLCanvasElement;
  let radialGlass: HTMLDivElement;
  let scratch: HTMLCanvasElement;

  onMount(() => {
    startCapture({ bg, ink, live, hover, radial, radialGlass, scratch }, { port: PORT, token: TOKEN, pens: PENS });
  });
</script>

<canvas id="bg" bind:this={bg}></canvas>
<canvas id="ink" bind:this={ink}></canvas>
<canvas id="live" bind:this={live}></canvas>
<canvas id="hover" bind:this={hover}></canvas>
<div id="radialGlass" bind:this={radialGlass}></div>
<canvas id="radial" bind:this={radial}></canvas>
<canvas id="scratch" bind:this={scratch}></canvas>
<TopBar />
<Drawer />
<StatsPanel />
<PenStat />
<LayerStat />
<TextNoteEditor />
<PadBar />
