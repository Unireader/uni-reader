// Mac 端注入的运行时配置（见 index.html 的内联脚本：占位符由 CapturePage.swift 运行时替换，
// vite dev 时由 devPlaceholders 插件换成开发值）。
const c = window.__CAPTURE_CONFIG__ || {};

export const PORT = c.port;
export const TOKEN = c.token || "";
export const PENS = Array.isArray(c.pens) && c.pens.length
  ? c.pens
  : [{ color: "rgba(24,90,210,0.95)", w: 8, t: "ballpoint" }];
