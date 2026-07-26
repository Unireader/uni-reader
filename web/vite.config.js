import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { viteSingleFile } from "vite-plugin-singlefile";

// dev 专用：把 index.html 里的 Mac 端占位符换成本地开发值。
// build 时**不**替换——产物里的 __WS_PORT__/__TOKEN__/__PENS__ 由 Mac 端 CapturePage.swift 运行时替换。
const DEV_PENS = JSON.stringify([{ name: "蓝", color: "rgba(24,90,210,0.95)", w: 8, t: "ballpoint" }]);
function devPlaceholders() {
  return {
    name: "capture-dev-placeholders",
    apply: "serve",
    transformIndexHtml(html) {
      return html
        .replaceAll("__WS_PORT__", "8765")
        .replaceAll("__TOKEN__", "dev-token")
        .replaceAll("__PENS__", DEV_PENS);
    },
  };
}

export default defineConfig({
  plugins: [devPlaceholders(), svelte(), viteSingleFile()],
  server: {
    // lib/wire.js 直接 import ../../../Sources/Resources/wire.js（协议单一真源，在 web/ 之外）
    fs: { allow: [".."] },
  },
});
