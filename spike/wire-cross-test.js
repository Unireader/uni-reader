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
  { type: "penset", list: [{ color: "rgba(24,90,210,0.5)", w: 8, t: "ballpoint" },
                            { color: "rgba(255,214,40,0.25)", w: 22, t: "marker" }], active: 1 },
  { type: "eraser", size: 0.02, mode: 1, ring: 1 },
  { type: "eraser", size: 0.5, mode: 0, ring: 0 },
  // ink begin 的尾部 flags：bit0=line（直线/尺子笔）。上面 #23 那条是 line 缺省(=0) 的同款。
  { type: "ink", phase: "begin", page: 0, pen: { color: "rgba(24,90,210,0.5)", w: 8, t: "ballpoint" },
    pts: [[0.5, 0.5, 0.5]], line: true },
  // 多层笔迹（0x3A）：图层表按 sortOrder 排、按下标对齐，active = 当前作画图层下标。
  { type: "layers", active: 1, list: [{ r: 255, g: 149, b: 0, visible: true, name: "老师批注" },
                                       { r: 0, g: 122, b: 255, visible: false, name: "My Notes" }] },
  // 平板发起的图层请求（0x26/0x27/0x28）：Mac 执行后照旧广播 layers 回权威状态。
  { type: "layerSelect", index: 1 },
  { type: "layerVisible", index: 0, visible: false },
  { type: "layerAdd" },
  // 平板发起的框选移动提交（0x47）：框选矩形（提交时用于 Mac 复判命中）+ 位移，均页内归一化。
  { type: "mode", mode: "lasso" },
  { type: "lassoMove", page: 2, x0: 0.2, y0: 0.3, x1: 0.6, y1: 0.5, dx: 0.1, dy: -0.05 },
  { type: "gotoPage", page: 42 },
  // strokes 的 ackRel（0x36 首字段，PROTOCOL.md §4.2）：Mac 已连续处理到的该客户端 REL seq。
  // 上面 #19 那条是 ackRel 缺省(=0) 的同款——浏览器不走 UDP，线上收到的恒是那个样子。
  { type: "strokes", ackRel: 305419896, list: [{ page: 1, pen: { color: "rgba(20,20,20,1)", w: 10, t: "pencil" },
                                                 pts: [[0.5, 0.25, 0.5], [0.75, 0.125, 1.0]] }] },
  // 平板打开工作区里尚未打开的文档（0x2A）：库文档 id（不是 docs 的窗口会话 id）。
  { type: "openDoc", id: "D1E2F3" },
  // 工作区书库全量镜像（0x3B）：id=库文档 id，open=是否已在某窗口打开。
  { type: "library", ws: "阅读", list: [{ id: "A1", title: "深入理解计算机系统", open: true },
                                        { id: "B2", title: "SICP", open: false }] },
  // PDF 目录（0x3C）：先序拍平 + depth；page=-1 是坏书签（线上 hasPage=0）。
  { type: "toc", docId: "abc123", list: [{ depth: 0, page: 0, frac: 0.0, label: "第一章" },
                                         { depth: 1, page: 4, frac: 0.25, label: "1.1 引言" },
                                         { depth: 0, page: -1, frac: 0.0, label: "坏书签" }] },
  // 目录跳转（0x29 带尾部可选 frac）：与上面那条「只跳页」的老形态各测一遍。
  { type: "gotoPage", page: 7, frac: 0.5 },
  // —— 草稿纸（v8，0x2B/0x2C/0x3D/0x3E）——
  // 列表 + 当前打开第几张（-1 = 没开，线上 0xFFFF）。bg 是 CSS 串，线上拆 r/g/b/a。
  // showPage（v10 尾部 u8）：P1 显式 true、P2 **整个键缺失**（两端都要兜底成 0，别各兜各的）。
  { type: "scratchpads", open: 1,
    list: [{ id: "P1", title: "推导", page: 3, nx: 0.25, ny: 0.5,
             bg: "rgba(255,255,255,1.0)", pattern: "dots", showPage: true },
           { id: "P2", title: "", page: 0, nx: 0.5, ny: 0.125,
             bg: "rgba(250,248,240,1.0)", pattern: "grid" }] },
  { type: "scratchpads", open: -1, list: [] },
  // 纸上笔迹：**无 page 字段**，点集是画布坐标（逻辑点，可负无界）。
  { type: "scratchStrokes", ackRel: 7,
    list: [{ pen: { color: "rgba(20,20,20,1.0)", w: 10.0, t: "pencil" },
             pts: [[-120.5, 64.25, 0.5], [512.0, -8.125, 1.0]] }] },
  { type: "scratchOpen", index: 2 },
  { type: "scratchOpen", index: -1 },
  { type: "scratchAdd", page: 5, nx: 0.75, ny: 0.25 },
  // 改纸样（0x2D）：底色 + 底纹。plain 也要走一遍（编码 0，最容易被 `?? 1` 兜底吃掉）。
  { type: "scratchPaper", index: 1, bg: "rgba(246,236,214,1.0)", pattern: "grid" },
  { type: "scratchPaper", index: 0, bg: "rgba(255,255,255,1.0)", pattern: "plain" },
  // —— 环形盘新扇区（radial kind 尾部追加 3=scratchAdd 4=textNote）+ 图钉拖动/新建笔记 ——
  // kind≠0 的项 pen 字段为占位 0（定长惯例），与 #33 的 erase/page 同款。
  { type: "radial", open: true, page: 2, cx: 0.5, cy: 0.5, highlight: 3,
    items: [{ kind: "pen", color: "rgba(24,90,210,0.5)", w: 8, t: "ballpoint" },
            { kind: "scratchAdd", color: "rgba(0,0,0,1)", w: 0, t: "ballpoint" },
            { kind: "textNote", color: "rgba(0,0,0,1)", w: 0, t: "ballpoint" }] },
  // 图钉页内拖动（0x2E，C→S）：u16 index · f32 nx · f32 ny。index 大值 + nx/ny 边界值。
  { type: "scratchMove", index: 0, nx: 0, ny: 1 },
  { type: "scratchMove", index: 65535, nx: 1, ny: 0 },
  // 新建文字笔记下发（0x3F，S→C）：u32 page · f32 nx · f32 ny。
  { type: "noteNew", page: 0, nx: 0, ny: 1 },
  { type: "noteNew", page: 305419896, nx: 1, ny: 0 },
  // —— 草稿纸 v10：页面底图开关 + 客户端删除/改名（0x2F / 0x48 / 0x49，均 C→S）——
  { type: "scratchPageShow", index: 0, show: true },
  { type: "scratchPageShow", index: 65535, show: false },
  { type: "scratchDelete", index: 0 },
  { type: "scratchDelete", index: 65535 },
  // 改名：非 ASCII 标题 + 空串（空串 = 清掉自定义名，回到「草稿纸 N」兜底显示）。
  { type: "scratchRename", index: 3, title: "第三张·推导" },
  { type: "scratchRename", index: 0, title: "" },
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
