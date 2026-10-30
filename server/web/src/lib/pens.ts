// 笔与工具（方案 §1 第 4、5 条）。四支笔同 Mac 的默认笔（`PenPresets.defaults`）；选哪支、用什么工具记在本浏览器。

import type { Color } from "./marks";
import type { PenType } from "./inkmath";

export interface Pen { name: string; color: Color; width: number; type: PenType }

export const PENS: readonly Pen[] = [
  { name: "Blue", color: { r: 24, g: 90, b: 210, a: 0.95 }, width: 8, type: "ballpoint" },
  { name: "Red", color: { r: 220, g: 40, b: 40, a: 0.95 }, width: 9, type: "fountain" },
  { name: "Black", color: { r: 20, g: 20, b: 20, a: 0.95 }, width: 10, type: "pencil" },
  { name: "Highlighter", color: { r: 255, g: 214, b: 40, a: 0.4 }, width: 22, type: "marker" },
];

/** none = 只看（拖动是滚动）；pen = 写；eraser = 整笔擦；note = 点一下新建文字笔记。 */
export type Tool = "none" | "pen" | "eraser" | "note";

/** 橡皮半径：页宽的比例（Mac `AppModel.eraserRadius` 的默认值）。 */
export const ERASER_RADIUS = 0.02;

const KEY = "unireader.tool";

export function loadTool(): { tool: Tool; pen: number } {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? "null") as { tool?: unknown; pen?: unknown } | null;
    const tool = v?.tool === "pen" || v?.tool === "eraser" || v?.tool === "note" ? v.tool : "none";
    const pen = typeof v?.pen === "number" && v.pen >= 0 && v.pen < PENS.length ? v.pen : 0;
    return { tool, pen };
  } catch {
    return { tool: "none", pen: 0 };
  }
}

export function saveTool(tool: Tool, pen: number) {
  try { localStorage.setItem(KEY, JSON.stringify({ tool, pen })); } catch { /* 无痕模式等 */ }
}
