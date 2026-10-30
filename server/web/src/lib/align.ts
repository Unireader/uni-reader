// 扫描页对齐（`SCAN-ALIGN-PLAN.md §2 / §3`）：每页旋转 + 平移，对齐后各页一样宽。
// 开着时笔迹 / 高亮 / 笔记的归一化坐标都相对对齐后的页（宽 W、高 sh）。
// 🔴 式子逐式照 Mac `Sources/App/ScanAlign.swift`（PageAlign / ScanAlignTable），不碰页面，node 测试直接跑。

export interface PageAlign { rot: number; dx: number; dy: number; sw: number; sh: number; w: number }

export interface AlignTable { width: number; pages: PageAlign[] }

/** 解 `page_align.payload`；格式版本不认识、页数对不上、数值不合法 → null（按没开对齐处理，同 Mac）。 */
export function parseAlign(json: string | undefined | null, pageCount: number): AlignTable | null {
  if (!json) return null;
  let obj: unknown;
  try { obj = JSON.parse(json); } catch { return null; }
  const o = obj as { v?: unknown; w?: unknown; pages?: unknown };
  if (o?.v !== 1 || typeof o.w !== "number" || !(o.w > 0) || !Number.isFinite(o.w) || !Array.isArray(o.pages)) return null;
  const w = o.w;
  const pages: PageAlign[] = [];
  for (const row of o.pages as unknown[]) {
    if (!Array.isArray(row) || row.length < 5) return null;
    const v = row.slice(0, 5);
    if (!v.every((x) => typeof x === "number" && Number.isFinite(x))) return null;
    const [rot, dx, dy, sw, sh] = v as number[];
    if (!(sw > 0) || !(sh > 0)) return null;
    pages.push({ rot, dx, dy, sw, sh, w });
  }
  return pages.length === pageCount ? { width: w, pages } : null;
}

/** 原始 → 对齐（y 向下，单位 pt）。 */
export function toAligned(p: PageAlign, x: number, y: number): [number, number] {
  const c = Math.cos(p.rot), s = Math.sin(p.rot);
  const u = x - p.sw / 2, v = y - p.sh / 2;
  return [c * u + s * v + p.w / 2 + p.dx, -s * u + c * v + p.sh / 2 + p.dy];
}

/** 对齐 → 原始。 */
export function toRaw(p: PageAlign, x: number, y: number): [number, number] {
  const c = Math.cos(p.rot), s = Math.sin(p.rot);
  const u = x - p.w / 2 - p.dx, v = y - p.sh / 2 - p.dy;
  return [c * u - s * v + p.sw / 2, s * u + c * v + p.sh / 2];
}

/**
 * 画页时套的变换（canvas 的 `[a, b, c, d, e, f]`：x' = a·x + c·y + e，y' = b·x + d·y + f），
 * 作用在「原始页按 [k] 像素 / pt 画出来」的像素上，得到对齐后的像素。即正变换的线性部分不变、平移乘 k。
 */
export function canvasTransform(p: PageAlign, k: number): [number, number, number, number, number, number] {
  const c = Math.cos(p.rot), s = Math.sin(p.rot);
  const e = -c * p.sw / 2 - s * p.sh / 2 + p.w / 2 + p.dx;
  const f = s * p.sw / 2 - c * p.sh / 2 + p.sh / 2 + p.dy;
  return [c, -s, s, c, e * k, f * k];
}
