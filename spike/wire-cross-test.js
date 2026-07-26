// 二进制线格式 跨语言一致性测试（node）。
// 前置：先跑 Swift 端生成向量：
//   swiftc spike/wire-codec-test.swift Sources/Server/WireCodec.swift -o /tmp/wct && /tmp/wct
// 再跑（项目根目录）：
//   node spike/wire-cross-test.js
// 做两件事：
//   1) JS 自身 round-trip 字节稳定：encode(x) === encode(decode(encode(x)))。
//   2) 与 Swift 导出的 spike/wire-vectors-swift.txt 逐条逐字节比对，证明两端编码结果**字节级一致**。
"use strict";
const fs = require("fs");
const path = require("path");
const Wire = require(path.join(__dirname, "../Sources/Resources/wire.js"));

function hex(u8) { return Buffer.from(u8).toString("hex"); }

// —— canonical 消息集（顺序/数值必须与 wire-codec-test.swift 完全一致）——
const canonical = [
  { type: "auth", token: "abc123" },
  { type: "authOK", session: 0, udpPort: 0 },
  { type: "authOK", session: 305419896, udpPort: 8772 },   // 0x12345678
  { type: "authFail" },
  { type: "ping", t: 1700000000000 },
  { type: "pong", t: 1700000000000 },
  { type: "latency", ms: 42 },
  { type: "selectDoc", id: "1A2B" },
  { type: "pageTurn", dir: "next" },
  { type: "mode", mode: "erase" },
  { type: "pen", index: 3 },
  { type: "page", v: 5, index: 2, count: 100, w: 612, h: 792 },
  { type: "layout", docId: "H", v: "H", count: 2, pages: [[612, 792], [595, 842]] },
  { type: "viewport", page: 3, frac: 0.5, seq: 7 },
  { type: "viewport", page: 3, frac: 0.25, force: true },
  { type: "docs", list: [{ id: "a", title: "T1" }, { id: "b", title: "标题" }], selected: "a", following: false },
  { type: "pens", list: [{ color: "rgba(24,90,210,0.5)", w: 8, t: "ballpoint" },
                          { color: "rgba(255,214,40,0.25)", w: 22, t: "marker" }], active: 1 },
  { type: "inkCancel" },
  { type: "strokes", list: [{ page: 1, pen: { color: "rgba(20,20,20,1)", w: 10, t: "pencil" },
                              pts: [[0.5, 0.25, 0.5], [0.75, 0.125, 1]] }] },
  { type: "scroll", page: 2, frac: 0.5, t: 123456 },
  { type: "hover", page: 1, nx: 0.5, ny: 0.25 },
  { type: "hover", phase: "end" },
  { type: "ink", phase: "begin", page: 0, pen: { color: "rgba(24,90,210,0.5)", w: 8, t: "ballpoint" }, pts: [[0.5, 0.5, 0.5]] },
  { type: "ink", phase: "move", pts: [[0.25, 0.75, 0.5], [0.5, 0.5, 1]] },
  { type: "ink", phase: "end" },
  { type: "erase", phase: "move", page: 1, pts: [[0.5, 0.5], [0.25, 0.25]] },
  { type: "erase", phase: "end" },
  { type: "probe", phase: "begin", page: 2, pts: [[0.5, 0.5]] },
  { type: "probe", phase: "move", pts: [[0.25, 0.25]] },
  { type: "probe", phase: "end" },
  { type: "nack", seqs: [1, 2, 3000000000] },
  // —— 新消息一律**追加在末尾**（安卓 WireCodecTest.kt 按行号索引这张表，往中间插会错位）——
  { type: "radial", open: false },
  { type: "radial", open: true, page: 4, cx: 0.5, cy: 0.25, highlight: 2,
    items: [{ kind: "pen", color: "rgba(24,90,210,0.5)", w: 8, t: "ballpoint" },
            { kind: "erase", color: "rgba(0,0,0,1)", w: 0, t: "ballpoint" },
            { kind: "page", color: "rgba(0,0,0,1)", w: 0, t: "ballpoint" }] },
  { type: "radial", open: true, page: 0, cx: 0.25, cy: 0.75, highlight: -1, items: [] },
  { type: "padGeom", pageW: 1024 },
  { type: "pressRing", on: false },
  { type: "pressRing", on: true, page: 3, nx: 0.5, ny: 0.25 },
  { type: "textNote", id: "n1", op: "upsert", page: 2, nx: 0.5, ny: 0.25, text: "批注" },
  { type: "textNote", id: "n1", op: "delete", page: 2, nx: 0.5, ny: 0.25, text: "" },
  { type: "notes", list: [{ id: "n1", page: 0, nx: 0.5, ny: 0.5, text: "hello" },
                          { id: "n2", page: 3, nx: 0.25, ny: 0.75, text: "笔记" }] },
];

let pass = 0, fail = 0;

// JS 自身 round-trip 字节稳定
const jsHex = canonical.map(function (msg, i) {
  const e1 = Wire.encode(msg);
  if (!e1) { console.log("✗ [" + i + "] " + msg.type + ": encode 返回 null"); fail++; return ""; }
  const h1 = hex(e1);
  const y = Wire.decode(e1.buffer.slice(e1.byteOffset, e1.byteOffset + e1.byteLength));
  if (!y) { console.log("✗ [" + i + "] " + msg.type + ": decode 返回 null"); fail++; return h1; }
  const h2 = hex(Wire.encode(y));
  if (h1 !== h2) { console.log("✗ [" + i + "] " + msg.type + ": JS 字节不稳定\n   E1=" + h1 + "\n   E2=" + h2); fail++; }
  else pass++;
  return h1;
});

// 与 Swift 向量比对
const vpath = path.join(__dirname, "wire-vectors-swift.txt");
if (!fs.existsSync(vpath)) {
  console.log("⚠ 缺 " + vpath);
  console.log("  请先跑：swiftc spike/wire-codec-test.swift Sources/Server/WireCodec.swift -o /tmp/wct && /tmp/wct");
  process.exit(1);
}
const swiftHex = fs.readFileSync(vpath, "utf8").replace(/\n$/, "").split("\n");
if (swiftHex.length !== canonical.length) {
  console.log("✗ 向量条数不符：swift=" + swiftHex.length + " js=" + canonical.length); fail++;
}
for (let i = 0; i < canonical.length; i++) {
  if (jsHex[i] === swiftHex[i]) pass++;
  else {
    console.log("✗ [" + i + "] " + canonical[i].type + ": Swift↔JS 字节不一致\n   swift=" + swiftHex[i] + "\n   js   =" + jsHex[i]);
    fail++;
  }
}

console.log("—");
console.log("JS round-trip + 跨语言比对: " + pass + " 通过, " + fail + " 失败");
process.exit(fail === 0 ? 0 : 1);
