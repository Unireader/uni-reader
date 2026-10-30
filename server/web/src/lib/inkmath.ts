// 笔迹的数据与公式（不碰页面，node 测试直接跑：test/inkmath.test.ts）。
//
// 🔴 公式逐式照 Mac：`Sources/App/PenPreset.swift`（PenBrushType / InkRender）。改那边要同步这里，
//    跨端向量 `spike/web-ink-vectors.txt` 由 Mac 代码生成（`spike/web-ink-vectors.swift`）。

export type PenType = "ballpoint" | "fountain" | "marker" | "pencil";

export function penType(raw: unknown): PenType {
  return raw === "fountain" || raw === "marker" || raw === "pencil" ? raw : "ballpoint";
}

/** 笔宽：`p` = 压感 0~1，`w` = 笔的粗细（Mac `PenBrushType.strokeWidth`）。 */
export function strokeWidth(type: PenType, p: number, w: number): number {
  switch (type) {
    case "ballpoint": return 0.6 + p * w;
    case "fountain": return 0.3 + Math.pow(p, 1.6) * w * 1.3;
    case "marker": return w;
    case "pencil": return 0.5 + p * w * 0.85;
  }
}

/** 钢笔起收笔锥度（Mac `PenBrushType.fountainTaper`）：两端渐细、中段为 1；非钢笔、两点以下恒 1。 */
export function fountainTaper(type: PenType, i: number, n: number): number {
  if (type !== "fountain" || n <= 2) return 1;
  const t = i / (n - 1), edge = 0.16;
  const a = Math.min(t, 1 - t) / edge;
  return a >= 1 ? 1 : a * a * (3 - 2 * a) * 0.82 + 0.18;
}

/** 铅笔多道叠加：每道（垂向波幅 × 线宽、该道透明度、线宽比例、相位）（Mac `PenBrushType.pencilPasses`）。 */
export const PENCIL_PASSES: readonly { amp: number; alpha: number; wScale: number; phase: number }[] = [
  { amp: 0.0, alpha: 0.34, wScale: 0.55, phase: 0.0 },
  { amp: 0.34, alpha: 0.16, wScale: 0.45, phase: 2.3 },
  { amp: 0.34, alpha: 0.16, wScale: 0.45, phase: 4.6 },
];
export const PENCIL_WOBBLE_REF_WIDTH = 9.0;
export const PENCIL_WOBBLE_FREQ = 0.025;

/** [-1, 1] 的伪随机（Mac `InkRender.jitter`），种子用归一化坐标，缩放不影响。 */
export function jitter(x: number, y: number): number {
  const v = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
  return (v - Math.floor(v)) * 2 - 1;
}

/** 点 i 处路径的单位垂线（用前后邻点估切线，Mac `InkRender.perp`）。`xs` / `ys` 是同长的坐标数组。 */
export function perp(xs: ArrayLike<number>, ys: ArrayLike<number>, i: number): [number, number] {
  const a = Math.max(0, i - 1), b = Math.min(xs.length - 1, i + 1);
  const dx = xs[b] - xs[a], dy = ys[b] - ys[a];
  const len = Math.max(0.0001, Math.sqrt(dx * dx + dy * dy));
  return [-dy / len, dx / len];
}

/**
 * 笔迹点集的二进制（`BINARY-INK-PLAN.md §2`）：`u8 版本 = 1` + n ×（f32 x、f32 y、f32 z），小端。
 * 返回 x, y, z 依次排开的数组（长度 3n）；版本不认识 / 长度不对 → null。
 */
export function decodePoints(bytes: Uint8Array): Float32Array | null {
  if (bytes.length < 1 || (bytes.length - 1) % 12 !== 0 || bytes[0] !== 1) return null;
  const n = (bytes.length - 1) / 12;
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out = new Float32Array(n * 3);
  for (let k = 0; k < n * 3; k++) out[k] = dv.getFloat32(1 + k * 4, true);
  return out;
}

export function base64Bytes(b64: string): Uint8Array {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/**
 * ⇧ 画直线的吸附（Mac `InkEdit.rulerSnap`）：起点 → 当前点的角度离最近的 45° 倍数不超过 7° 就贴过去（长度不变）。
 * 坐标是页内归一化的，[aspect] = 页高 / 页宽，先把 y 折成与 x 同尺度再量角，吸附的是「看上去」的角度。
 */
export function rulerSnap(sx: number, sy: number, cx: number, cy: number, aspect = 1, thresholdDeg = 7): [number, number] {
  const a = aspect > 0 ? aspect : 1;
  const dx = cx - sx, dy = (cy - sy) * a;
  const len = Math.sqrt(dx * dx + dy * dy);
  if (!(len > 0)) return [cx, cy];
  const step = Math.PI / 4;
  const ang = Math.atan2(dy, dx);
  const snapped = Math.round(ang / step) * step;
  if (Math.abs(ang - snapped) > (thresholdDeg * Math.PI) / 180) return [cx, cy];
  return [sx + len * Math.cos(snapped), sy + (len * Math.sin(snapped)) / a];
}

/** 页内笔迹的包围盒（归一化），写库时当 `note.anchor`（Mac `InkStroke.normalizedBounds`）。 */
export function pointsBounds(pts: Float32Array): [number, number, number, number] {
  if (pts.length < 3) return [0, 0, 0, 0];
  let x0 = pts[0], x1 = pts[0], y0 = pts[1], y1 = pts[1];
  for (let i = 3; i < pts.length; i += 3) {
    x0 = Math.min(x0, pts[i]); x1 = Math.max(x1, pts[i]);
    y0 = Math.min(y0, pts[i + 1]); y1 = Math.max(y1, pts[i + 1]);
  }
  return [x0, y0, x1 - x0, y1 - y0];
}

/** 点集 → 二进制（`decodePoints` 的反向）。 */
export function encodePoints(pts: Float32Array): Uint8Array {
  const out = new Uint8Array(1 + pts.length * 4);
  out[0] = 1;
  const dv = new DataView(out.buffer);
  for (let k = 0; k < pts.length; k++) dv.setFloat32(1 + k * 4, pts[k], true);
  return out;
}

export function bytesBase64(b: Uint8Array): string {
  let s = "";
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return btoa(s);
}
