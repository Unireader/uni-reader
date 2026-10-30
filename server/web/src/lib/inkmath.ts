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
