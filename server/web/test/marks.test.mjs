// 标记行的解析、图层的显示与顺序、笔记配色：规则照 Mac（`pnpm test`）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseMarks, visibleStrokes, noteMarkColor, pinColor, parseNoteTypes, MARK_COLORS, DEFAULT_LAYER } from "../.test-build/marks.js";

// 两个点：(0.25, 0.5, 1) 与 (0.75, 0.125, 0.5)
const pts = Buffer.from(Uint8Array.from([1, ...new Uint8Array(Float32Array.of(0.25, 0.5, 1, 0.75, 0.125, 0.5).buffer)])).toString("base64");

test("三种标记的解析与缺省值", () => {
  const m = parseMarks([
    { id: "S1", kind: 2, page: 3, anchor: [0, 0, 0, 0], points: pts,
      payload: '{"color":{"r":1,"g":2,"b":3,"a":0.5},"width":8,"points":[]}' },
    { id: "H1", kind: 3, page: 3, anchor: [0, 0, 0, 0],
      payload: '{"quote":"字","rects":[[0.1,0.2,0.3,0.04]],"color":{"r":255,"g":214,"b":40,"a":1},"style":"box"}' },
    { id: "N1", kind: 0, page: 4, anchor: [0.1, 0.2, 0, 0], payload: '{"quote":"","text":"看这里","rects":[],"type_id":"abc"}' },
    { id: "X1", kind: 2, page: 4, anchor: [0, 0, 0, 0], payload: "坏了" },
    { id: "X2", kind: 2, page: 4, anchor: [0, 0, 0, 0], payload: '{"color":{"r":1,"g":2,"b":3,"a":1},"width":8}' },
  ]);
  const p3 = m.get(3), p4 = m.get(4);
  assert.equal(p3.strokes.length, 1);
  const s = p3.strokes[0];
  assert.equal(s.type, "ballpoint", "没有 type = 圆珠笔");
  assert.equal(s.layerId, DEFAULT_LAYER, "没有 layerId = 默认层");
  assert.deepEqual(Array.from(s.pts), [0.25, 0.5, 1, 0.75, 0.125, 0.5]);
  assert.deepEqual(p3.highlights[0].rects, [[0.1, 0.2, 0.3, 0.04]]);
  assert.equal(p3.highlights[0].style, "box");
  const n = p4.notes[0];
  assert.equal(n.display, "tap", "没有 display = 点按展开");
  assert.equal(n.style, "fill");
  assert.equal(n.typeId, "ABC", "id 一律按大写比");
  assert.equal(n.color, null);
  assert.equal(p4.strokes.length, 0, "坏行、没有点的笔迹跳过");
  assert.notEqual(p3.sig, p4.sig);
});

const stroke = (id, layerId) => ({ id, layerId, color: { r: 0, g: 0, b: 0, a: 1 }, width: 1, type: "ballpoint", pts: new Float32Array(3) });

test("图层：隐藏的不画；按图层顺序、同层保持原顺序；不存在的图层当可见、排在最后", () => {
  const layers = [
    { id: "b", name: "二", colorKey: "", sortOrder: 0, visible: true },
    { id: "a", name: "一", colorKey: "", sortOrder: 1, visible: true },
    { id: "h", name: "藏", colorKey: "", sortOrder: 2, visible: false },
  ];
  const got = visibleStrokes([stroke(1, "A"), stroke(2, "H"), stroke(3, "B"), stroke(4, "Z"), stroke(5, "A"), stroke(6, "Y")], layers);
  assert.deepEqual(got.map((s) => s.id), [3, 1, 5, 6, 4]);
  // 一层都没有（老文档）：全部可见、原顺序
  assert.deepEqual(visibleStrokes([stroke(1, DEFAULT_LAYER), stroke(2, "Q")], []).map((s) => s.id), [1, 2]);
});

test("笔记的底色与图钉色", () => {
  const types = parseNoteTypes('[{"id":"t1","name":"疑问","color_key":"blue","icon_name":"flag"}]');
  const note = (o) => ({ id: "n", anchor: [0, 0, 0, 0], rects: [], quote: "", text: "", color: null, style: "fill", typeId: null, display: "tap", ...o });
  assert.deepEqual(noteMarkColor(note({}), types), MARK_COLORS.noteBase, "没类型 = 暖黄");
  assert.deepEqual(noteMarkColor(note({ typeId: "T1" }), types), { r: 0, g: 122, b: 255, a: 1 }, "类型色");
  assert.deepEqual(noteMarkColor(note({ typeId: "NOPE" }), types), { r: 142, g: 142, b: 147, a: 1 }, "类型找不到 = 通用的灰");
  const own = { r: 1, g: 2, b: 3, a: 1 };
  assert.deepEqual(noteMarkColor(note({ typeId: "T1", color: own }), types), own, "自己选的色优先");
  assert.deepEqual(pinColor(note({ color: own }), types), MARK_COLORS.noteMarker, "图钉不看自选色");
  assert.deepEqual(parseNoteTypes("坏了"), []);
});
