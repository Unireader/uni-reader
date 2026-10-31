// 服务器出图的宽度分档（要与服务器 `PageImages.widths` 一致）、取消不当错误（`pnpm test`）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { widthBucket, requestWidth, scanLimit, isCancel } from "../.test-build/source.js";

test("宽度往上取一档，超过最宽的按最宽", () => {
  assert.equal(widthBucket(1), 480);
  assert.equal(widthBucket(960), 960);
  assert.equal(widthBucket(961), 1280);
  assert.equal(widthBucket(9999), 3200);
});

test("扫描页最多按扫描图本身的宽度要；放大缩小时地址不变", () => {
  assert.equal(requestWidth(3200, 1423), 1600);
  assert.equal(requestWidth(2000, 1423), 1600, "要得再宽，也是同一个地址");
  assert.equal(requestWidth(900, 1423), 960, "要得比扫描图窄就按档");
  assert.equal(requestWidth(1100, 1423), 1600, "1280 档离上限不到两成：直接按上限要（地址同放大时）");
  assert.equal(requestWidth(3200, 0), 3200, "不是扫描页：不限");
  assert.equal(requestWidth(9999, 4256), 2560, "高分辨率扫描最多要一半（2124 → 往上一档）");
  assert.equal(requestWidth(1500, 4256), 1600);
  assert.equal(requestWidth(2000, 4268), 2560, "2048 档离上限 2130 不到两成：和放大时同一个地址");
  assert.equal(requestWidth(2000, 2500), 2048, "差两成以上照档");
});

test("高分辨率扫描的上限与服务器那份一致", () => {
  const swift = readFileSync(fileURLToPath(new URL("../../Sources/UniServerCore/PageImages.swift", import.meta.url)), "utf8");
  const m = swift.match(/static let halveAbove = (\d+)/);
  assert.ok(m, "服务器的 halveAbove 没找到");
  const above = Number(m[1]);
  const near = swift.match(/static let nearLimit = ([\d.]+)/);
  assert.ok(near, "服务器的 nearLimit 没找到");
  assert.equal(requestWidth(1100, 1423), widthBucket(1423), `按 ${near[1]} 倍算，1280 档要直接按上限`);
  assert.equal(Number(near[1]), 1.2, "网页的 NEAR_LIMIT 也是 1.2，改了两边一起改");
  assert.equal(scanLimit(above), above, "正好等于不算");
  assert.equal(scanLimit(above + 1), Math.floor((above + 1) / 2) - 4);
  assert.equal(scanLimit(4268), 2130, "同服务器测试里的数");
  assert.equal(scanLimit(1423), 1423);
});

test("分档与服务器那份一致", () => {
  const swift = readFileSync(fileURLToPath(new URL("../../Sources/UniServerCore/PageImages.swift", import.meta.url)), "utf8");
  const m = swift.match(/static let widths = \[([\d, ]+)\]/);
  assert.ok(m, "服务器的分档没找到");
  const server = m[1].split(",").map((x) => Number(x.trim()));
  for (const w of server) assert.equal(widthBucket(w), w, `服务器有 ${w} 这一档`);
  assert.equal(widthBucket(server[server.length - 1] + 1), server[server.length - 1]);
});

test("取消（中止请求、pdf.js 取消画页）不当错误", () => {
  assert.ok(isCancel({ name: "AbortError" }));
  assert.ok(isCancel({ name: "RenderingCancelledException" }));
  assert.ok(!isCancel(new Error("网络断了")));
});
