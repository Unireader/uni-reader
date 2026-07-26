// 共享常量 / 全局状态袋 / 与 Mac 端对齐的数学公式。
// ⚠️ 公式与常量改动必须同步 Mac 端：strokeWidthFor/opacityMultFor ↔ Sources/App/PenPreset.swift，
// RD ↔ Sources/Views/RadialMenuView.swift（+ Sources/App/DocSession.swift 的 RadialLayout），
// PR ↔ Sources/Views/PageCellView.swift 的 pressRing。

export const BAR = 46, GAP = 8, MINZ = 0.5, MAXZ = 5;

export const MODES = [{ key: "note", label: "笔记" }, { key: "erase", label: "擦除" }, { key: "page", label: "翻页" }];
export const BRUSH_LABELS = { ballpoint: "圆珠笔", fountain: "钢笔", marker: "马克笔", pencil: "铅笔" };

// 环形选笔盘几何/压暗常量：两端画的是同一个盘，Mac 的「中心取消区」判定用的就是 RD.hub
// 这个像素半径（配合 padGeom 上报的页宽换算）。wedgeDim/hubDim 越小越透。
export const RD = { hub: 46, inner: 54, outer: 134, gap: 1.5, wedgeDim: 0.16, hubDim: 0.22 };
// 长按进度环（环形盘的前置动画）：300ms 起显示、700ms 填满、直径 30 线宽 3、从正上方顺时针。
export const PR = { d: 30, lw: 3, delayMs: 300, fillMs: 700 };
// 手掌接触阈值(px)、单指平移死区(px)
export const PALM = 60, DEAD = 8;

/// 全局可变状态袋：原 capture.html IIFE 的模块级 var 的平移（避免各模块 own 一半状态的耦合地狱）。
/// 全部字段的初始化在 capture.js 的 startCapture()；跨模块读写一律走 G。
export const G = {};

export function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }

export function curMode() { return MODES[G.modeIdx].key; }
export function curPen() { return G.PENS[G.penIdx]; }

export function pw() { return G.vw * G.zoom; }                                    // 页(内容)宽
export function contentLeft() { const p = pw(); return p <= G.vw ? (G.vw - p) / 2 : -G.scrollX; }   // 内容左缘视口 x

// ---- 笔触类型：跟 Mac 端 PenBrushType.strokeWidth/opacityMultiplier 同一套公式 ----
export function strokeWidthFor(t, p, w) {
  if (t === "fountain") return 0.3 + Math.pow(p, 1.6) * w * 1.15;
  if (t === "marker") return w;
  if (t === "pencil") return 0.5 + p * w * 0.85;
  return 0.6 + p * w;   // ballpoint / 未知类型兜底
}
export function opacityMultFor(t) { return t === "pencil" ? 0.85 : 1; }
export function scaledColor(css, mult) {
  if (mult === 1) return css;
  const m = /rgba?\(([^)]+)\)/.exec(css);
  if (!m) return css;
  const parts = m[1].split(",").map((s) => parseFloat(s));
  const a = parts.length > 3 ? parts[3] : 1;
  return "rgba(" + parts[0] + "," + parts[1] + "," + parts[2] + "," + (a * mult) + ")";
}
