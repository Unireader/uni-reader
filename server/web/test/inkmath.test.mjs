// 笔迹公式 / 点集解码 / 扫描页对齐：对 Mac 代码生成的跨端向量逐项比（`pnpm test`）。
// 向量：spike/web-ink-vectors.txt（spike/web-ink-vectors.swift 生成）、spike/ink-blob-vectors.txt（Mac / 安卓共用）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { strokeWidth, fountainTaper, jitter, decodePoints, base64Bytes } from "../.test-build/inkmath.js";
import { toAligned, toRaw, parseAlign, canvasTransform } from "../.test-build/align.js";

const spike = (name) => readFileSync(fileURLToPath(new URL(`../../../spike/${name}`, import.meta.url)), "utf8");
const lines = (name) => spike(name).split("\n").filter((l) => l && !l.startsWith("#"));
const vectors = lines("web-ink-vectors.txt").map((l) => l.split("|"));
const nums = (s) => s.split(",").map(Number);
// 同一套式子在 Swift Double 与 JS number 里都是 IEEE 双精度，只有 sin / cos / pow 的实现可能差最后一位
const close = (a, b, msg) => assert.ok(Math.abs(a - b) <= 1e-12 * Math.max(1, Math.abs(b)), `${msg}: ${a} ≠ ${b}`);

test("笔宽与 Mac 一致", () => {
  const rows = vectors.filter((v) => v[0] === "width");
  assert.equal(rows.length, 60);
  for (const [, type, p, w, want] of rows) close(strokeWidth(type, +p, +w), +want, `${type} p=${p} w=${w}`);
});

test("钢笔锥度与 Mac 一致", () => {
  const rows = vectors.filter((v) => v[0] === "taper");
  assert.ok(rows.length > 10);
  for (const [, type, i, n, want] of rows) close(fountainTaper(type, +i, +n), +want, `${type} ${i}/${n}`);
});

test("铅笔抖动与 Mac 一致", () => {
  const rows = vectors.filter((v) => v[0] === "jitter");
  assert.equal(rows.length, 5);
  // sin 的大参数（×43758）把末位误差放大，比到 1e-6 足够（只决定纹理的细微摆动）
  for (const [, x, y, want] of rows) assert.ok(Math.abs(jitter(+x, +y) - +want) < 1e-6, `jitter(${x}, ${y})`);
});

test("扫描页对齐的正逆变换与 Mac 一致", () => {
  const rows = vectors.filter((v) => v[0] === "align");
  assert.equal(rows.length, 12);
  for (const [, params, p, q, r] of rows) {
    const [rot, dx, dy, sw, sh, w] = nums(params);
    const pa = { rot, dx, dy, sw, sh, w };
    const [x, y] = nums(p), [qx, qy] = nums(q), [rx, ry] = nums(r);
    const [ax, ay] = toAligned(pa, x, y);
    close(ax, qx, `toAligned x ${params}`);
    close(ay, qy, `toAligned y ${params}`);
    const [bx, by] = toRaw(pa, ax, ay);
    close(bx, rx, `toRaw x ${params}`);
    close(by, ry, `toRaw y ${params}`);
    // 画页用的 canvas 矩阵（k = 2 像素 / pt）≡ 正变换
    const [a, b, c, d, e, f] = canvasTransform(pa, 2);
    close(a * x * 2 + c * y * 2 + e, ax * 2, "canvas x");
    close(b * x * 2 + d * y * 2 + f, ay * 2, "canvas y");
  }
});

test("对齐参数的解析：版本 / 页数 / 数值不对就当没开", () => {
  const ok = '{"v":1,"w":497.5,"pages":[[0.01,-2,0,500,700],[0,0,0,480,690]]}';
  const t = parseAlign(ok, 2);
  assert.equal(t?.width, 497.5);
  assert.deepEqual(t?.pages[1], { rot: 0, dx: 0, dy: 0, sw: 480, sh: 690, w: 497.5 });
  assert.equal(parseAlign(ok, 3), null, "页数对不上");
  assert.equal(parseAlign(ok.replace('"v":1', '"v":2'), 2), null, "版本不认识");
  assert.equal(parseAlign(ok.replace("500,700", "0,700"), 2), null, "页宽为 0");
  assert.equal(parseAlign("坏了", 2), null);
  assert.equal(parseAlign(undefined, 2), null);
});

test("点集二进制解码与跨端向量一致", () => {
  const rows = lines("ink-blob-vectors.txt");
  assert.ok(rows.length >= 4);
  for (const row of rows) {
    const [pts, hex] = row.split("|");
    const bytes = Uint8Array.from(hex.match(/../g).map((h) => parseInt(h, 16)));
    const got = decodePoints(bytes);
    const want = pts ? pts.split(";").flatMap((p) => nums(p)) : [];
    assert.deepEqual(Array.from(got), Array.from(Float32Array.from(want)), row);
  }
  assert.equal(decodePoints(Uint8Array.of(2)), null, "版本不认识");
  assert.equal(decodePoints(Uint8Array.of(1, 0, 0)), null, "长度不对");
  assert.deepEqual(Array.from(base64Bytes("AQID")), [1, 2, 3]);
});

test("点集编码与跨端向量逐字节一致", async () => {
  const { encodePoints } = await import("../.test-build/inkmath.js");
  for (const row of lines("ink-blob-vectors.txt")) {
    const [pts, hex] = row.split("|");
    const want = pts ? pts.split(";").flatMap((p) => nums(p)) : [];
    const got = Buffer.from(encodePoints(Float32Array.from(want))).toString("hex");
    assert.equal(got, hex, row);
  }
});
