import { defineConfig, type Plugin } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { cpSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

// 服务器自带的网页阅读器（docs/WEB-READER-PLAN.md）。
// 构建产物 dist/ 由服务器的构建插件 EmbedWebAssets 编进服务器程序（server/Plugins/EmbedWebAssets）。

const root = fileURLToPath(new URL(".", import.meta.url));

// pdf.js 运行时按需取的文件（中日韩字形表、标准字体、色彩配置、解 JPEG 2000 / JBIG2 等扫描图的 wasm）原样拷到 dist/pdfjs/。
// 开发时直接从 /node_modules/pdfjs-dist/ 取（src/lib/pdf.ts）。
function pdfjsExtras(): Plugin {
  return {
    name: "pdfjs-extras",
    apply: "build",
    closeBundle() {
      for (const d of ["cmaps", "standard_fonts", "iccs", "wasm"]) {
        const src = `${root}node_modules/pdfjs-dist/${d}`;
        if (existsSync(src)) cpSync(src, `${root}dist/pdfjs/${d}`, { recursive: true });
      }
    },
  };
}

// KaTeX 的样式表每种字体列了 woff2 / woff / ttf 三种格式，构建时会把三种都打包（1.1MB）；
// 现在的浏览器都认 woff2，只留它（约 300KB，服务器程序里也少带 800KB）。
function katexWoff2Only(): Plugin {
  return {
    name: "katex-woff2-only",
    enforce: "pre",
    transform(code, id) {
      if (!/katex(\.min)?\.css$/.test(id.split("?")[0])) return null;
      return code.replace(/,\s*url\([^)]*\.(?:woff|ttf)\)\s*format\("(?:woff|truetype)"\)/g, "");
    },
  };
}

export default defineConfig({
  plugins: [svelte(), pdfjsExtras(), katexWoff2Only()],
  build: {
    target: "es2022",
    assetsInlineLimit: 0,          // 不把文件内联成 data: 地址（内容安全策略不许 data: 脚本）
    chunkSizeWarningLimit: 2000,   // pdf.js 本身就有几百 KB
  },
  optimizeDeps: { esbuildOptions: { target: "es2022" } },
  // 开发：npm run dev，接口转发到本机的服务器（unireader-server serve，默认端口 8790）
  server: { proxy: { "/v1": "http://127.0.0.1:8790" } },
});
