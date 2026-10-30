// 页面上的标记：服务器 `GET …/documents/:doc/marks` 给的行 → 网页用的对象（方案 §3 / §4）。
// payload 的键与缺省值照 Mac：笔迹 `InkModel.swift`（InkStrokePayload）、高亮 `HighlightModel.swift`、
// 文字笔记 `TextNoteModel.swift`（TextNotePayload）、图层 `InkLayerModel.swift`、笔记类型 `NoteTypeModel.swift`。

import { base64Bytes, decodePoints, penType, type PenType } from "./inkmath";

export interface Color { r: number; g: number; b: number; a: number }

export type MarkStyle = "fill" | "underline" | "box";
export type NoteDisplay = "tap" | "hover" | "always";

export interface Stroke {
  id: string;
  color: Color;
  width: number;
  type: PenType;
  layerId: string;
  /** x, y, 压感依次排开（页内归一化）。 */
  pts: Float32Array;
}

export interface Highlight { id: string; rects: number[][]; color: Color; style: MarkStyle }

export interface TextNote {
  id: string;
  /** 归一化包围盒 [x, y, w, h]。 */
  anchor: number[];
  rects: number[][];
  quote: string;
  text: string;
  color: Color | null;
  style: MarkStyle;
  typeId: string | null;
  display: NoteDisplay;
}

export interface PageMarks {
  strokes: Stroke[];
  highlights: Highlight[];
  notes: TextNote[];
  /** 这一页的原始数据拼起来，比较「变没变」用（轮询刷新时没变的页不重画）。 */
  sig: string;
}

export interface MarkRow { id: string; kind: number; page: number; anchor: number[]; payload: string; points?: string }

export interface InkLayer { id: string; name: string; colorKey: string; sortOrder: number; visible: boolean }

export interface NoteType { id: string; name: string; colorKey: string }

/** 旧笔迹没有 `layerId` 时归属的图层（Mac `InkLayer.defaultID`）。 */
export const DEFAULT_LAYER = "00000000-0000-0000-0000-000000000001";

/** 笔记类型的固定色板（Mac `NoteType.palette`）；未知的 key 回落灰色。 */
const PALETTE: Record<string, [number, number, number]> = {
  red: [255, 59, 48], orange: [255, 149, 0], yellow: [255, 204, 0], green: [52, 199, 89],
  blue: [0, 122, 255], purple: [175, 82, 222], pink: [255, 45, 85], gray: [142, 142, 147],
};

export function paletteColor(key: string): Color {
  const [r, g, b] = PALETTE[key] ?? PALETTE.gray;
  return { r, g, b, a: 1 };
}

/** 页面标记的配色（Mac `ReaderMarkColors` / `Highlight`）。 */
export const MARK_COLORS = {
  noteBase: { r: 255, g: 0.82 * 255, b: 0.15 * 255, a: 1 } as Color,
  noteFillOpacity: 0.32,
  noteMarker: { r: 255, g: 0.8 * 255, b: 0.15 * 255, a: 1 } as Color,
  highlightFillOpacity: 0.38,
  strokeOpacity: 0.9,
};

export const css = (c: Color, a = c.a) => `rgba(${c.r},${c.g},${c.b},${a})`;

const upper = (s: unknown) => (typeof s === "string" ? s.toUpperCase() : "");

function color(v: unknown): Color | null {
  const o = v as Partial<Color> | null;
  if (!o || typeof o !== "object") return null;
  const n = (x: unknown, d: number) => (typeof x === "number" && Number.isFinite(x) ? x : d);
  return { r: n(o.r, 0), g: n(o.g, 0), b: n(o.b, 0), a: n(o.a, 1) };
}

function rects(v: unknown): number[][] {
  if (!Array.isArray(v)) return [];
  return v.map((a) => {
    const r = Array.isArray(a) ? a : [];
    return [0, 1, 2, 3].map((k) => (typeof r[k] === "number" ? r[k] : 0));
  });
}

const style = (v: unknown): MarkStyle => (v === "underline" || v === "box" ? v : "fill");

/** 一段页的行 → 每页的标记。认不出的行跳过（同 App：坏行不显示）。 */
export function parseMarks(rows: MarkRow[]): Map<number, PageMarks> {
  const out = new Map<number, PageMarks>();
  const sig = new Map<number, string[]>();
  for (const row of rows) {
    let p: Record<string, unknown>;
    try { p = JSON.parse(row.payload); } catch { continue; }
    if (!p || typeof p !== "object") continue;
    let page = out.get(row.page);
    if (!page) {
      page = { strokes: [], highlights: [], notes: [], sig: "" };
      out.set(row.page, page);
      sig.set(row.page, []);
    }
    sig.get(row.page)!.push(row.id, row.payload, row.points ?? "", row.anchor.join(","));
    if (row.kind === 2) {
      const c = color(p.color);
      const pts = row.points ? decodePoints(base64Bytes(row.points)) : null;
      if (!c || typeof p.width !== "number" || !pts) continue;
      page.strokes.push({
        id: row.id, color: c, width: p.width, type: penType(p.type),
        layerId: upper(p.layerId) || DEFAULT_LAYER, pts,
      });
    } else if (row.kind === 3) {
      const c = color(p.color);
      if (!c) continue;
      page.highlights.push({ id: row.id, rects: rects(p.rects), color: c, style: style(p.style) });
    } else if (row.kind === 0) {
      const d = p.display;
      page.notes.push({
        id: row.id, anchor: row.anchor, rects: rects(p.rects),
        quote: typeof p.quote === "string" ? p.quote : "", text: typeof p.text === "string" ? p.text : "",
        color: color(p.color), style: style(p.style), typeId: upper(p.type_id) || null,
        display: d === "hover" || d === "always" ? d : "tap",
      });
    }
  }
  for (const [i, page] of out) page.sig = sig.get(i)!.join("\u0001");
  return out;
}

/** 工作区的笔记类型（`meta.note_types`，JSON 数组）。 */
export function parseNoteTypes(json: string | undefined): NoteType[] {
  if (!json) return [];
  try {
    const arr = JSON.parse(json) as { id?: unknown; name?: unknown; color_key?: unknown }[];
    return Array.isArray(arr)
      ? arr.map((t) => ({ id: upper(t.id), name: typeof t.name === "string" ? t.name : "", colorKey: typeof t.color_key === "string" ? t.color_key : "gray" }))
      : [];
  } catch {
    return [];
  }
}

const GENERAL_TYPE = "00000000-0000-0000-0000-000000000000";

/**
 * 一条文字笔记在页面上的底色（Mac `ReaderView.refreshMarks`）：自己选过的色 > 没类型的暖黄 > 类型色（类型找不到 = 通用的灰）。
 * 图钉的颜色另算（[pinColor]）。
 */
export function noteMarkColor(n: TextNote, types: NoteType[]): Color {
  if (n.color) return n.color;
  if (!n.typeId) return MARK_COLORS.noteBase;
  return typeColor(n.typeId, types);
}

export function pinColor(n: TextNote, types: NoteType[]): Color {
  return n.typeId ? typeColor(n.typeId, types) : MARK_COLORS.noteMarker;
}

function typeColor(id: string, types: NoteType[]): Color {
  const t = id === GENERAL_TYPE ? undefined : types.find((x) => x.id === id);
  return paletteColor(t?.colorKey ?? "gray");
}

/**
 * 某页要画的笔迹（Mac `DocSession.visibleStrokesByPage`）：只要可见图层的，按图层顺序排、同层保持原顺序。
 * 笔迹指向的图层不存在时 Mac 打开文档会补建（可见、排在最后、按 id 排），这里照那个结果算。
 */
export function visibleStrokes(strokes: Stroke[], layers: InkLayer[]): Stroke[] {
  if (!strokes.length) return strokes;
  const order = new Map<string, number>();
  const hidden = new Set<string>();
  layers.forEach((l, k) => {
    order.set(upper(l.id), k);
    if (!l.visible) hidden.add(upper(l.id));
  });
  const missing = new Set(strokes.map((s) => s.layerId).filter((id) => !order.has(id)));
  if (!layers.length) missing.add(DEFAULT_LAYER);   // 一层都没有：Mac 补建默认层
  [...missing].sort().forEach((id, k) => order.set(id, layers.length + k));
  return strokes
    .map((s, seq) => ({ s, seq }))
    .filter(({ s }) => !hidden.has(s.layerId))
    .sort((a, b) => order.get(a.s.layerId)! - order.get(b.s.layerId)! || a.seq - b.seq)
    .map(({ s }) => s);
}
