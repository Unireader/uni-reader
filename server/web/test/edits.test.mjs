// 网页自己的改动：叠在服务器数据上显示、存上后什么时候撤、同一行合并、核对用的更新时间、撤销（`pnpm test`）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { MarkStore } from "../.test-build/markstore.js";
import { EditSession } from "../.test-build/edits.js";
import { decodePoints, base64Bytes, rulerSnap } from "../.test-build/inkmath.js";
import { uuid } from "../.test-build/uuid.js";

const tick = () => new Promise((r) => setTimeout(r, 0));
const ptsB64 = Buffer.from(Uint8Array.from([1, ...new Uint8Array(Float32Array.of(0.1, 0.2, 0.5).buffer)])).toString("base64");
const row = (id, updatedAt, page = 0) => ({
  id, kind: 2, page, anchor: [0, 0, 0, 0], points: ptsB64, createdAt: "c-" + id, updatedAt,
  payload: '{"color":{"r":0,"g":0,"b":0,"a":1},"width":8,"points":[]}',
});
const stroke = (id) => ({
  id, color: { r: 0, g: 0, b: 0, a: 1 }, width: 8, type: "ballpoint", layerId: "L",
  pts: Float32Array.of(0.25, 0.5, 0.5, 0.75, 0.25, 0.5), createdAt: "", updatedAt: "",
});

/** 一个可以手动回应的「服务器」。 */
function fakeServer() {
  const fetches = [], posts = [];
  return {
    fetches, posts,
    fetchRows: (ws, doc, from, to) => new Promise((res) => fetches.push({ from, to, res })),
    post: (ws, doc, upserts, deletes) => new Promise((res, rej) => posts.push({ upserts, deletes, res, rej })),
  };
}

async function loaded(rows) {
  const srv = fakeServer();
  const changed = [];
  const store = new MarkStore("w", "d", 20, (p) => changed.push(...p), srv.fetchRows);
  store.want(0, 3);
  srv.fetches.shift().res(rows);
  await tick();
  changed.length = 0;
  return { srv, store, changed };
}

const ids = (store, page = 0) => store.page(page).strokes.map((s) => s.id);

test("自己写的一笔：存上之前发出的拉取里没有它，照样显示；之后的拉取有了它，不重画", async () => {
  const { srv, store, changed } = await loaded([row("S1", "u1")]);
  assert.deepEqual(ids(store), ["S1"]);
  assert.equal(store.serverStamp.get("S1"), "u1");

  const op = { id: "S2", page: 0, kind: "stroke", item: stroke("S2"), ackedAt: 0 };
  store.local(op);
  assert.deepEqual(ids(store), ["S1", "S2"]);

  store.refresh();                         // 这次拉取在存上之前发出
  store.acked(op, "u2");
  assert.equal(op.item.updatedAt, "u2");
  assert.equal(op.item.createdAt, "u2", "新建的行创建时间 = 那次写入的时间");
  srv.fetches.shift().res([row("S1", "u1")]);   // 里面还没有 S2
  await tick();
  assert.deepEqual(ids(store), ["S1", "S2"], "没闪没");
  assert.deepEqual(changed, [], "内容没变，不重画");

  store.refresh();
  srv.fetches.shift().res([row("S1", "u1"), row("S2", "u2")]);
  await tick();
  assert.deepEqual(ids(store), ["S1", "S2"]);
  assert.deepEqual(changed, [], "服务器回来的就是自己写的那份，不重画");

  // 这之后改动已经撤掉：别的设备删了 S2，网页跟着没了
  store.refresh();
  srv.fetches.shift().res([row("S1", "u1")]);
  await tick();
  assert.deepEqual(ids(store), ["S1"]);
  assert.deepEqual(changed, [0]);
});

test("没写上的改动撤掉，那一页回到服务器的样子", async () => {
  const { store, changed } = await loaded([row("S1", "u1")]);
  const op = { id: "S1", page: 0, kind: "stroke", item: null, ackedAt: 0 };
  store.local(op);
  assert.deepEqual(ids(store), []);
  store.dropped(op);
  assert.deepEqual(ids(store), ["S1"]);
  assert.deepEqual(changed, [0]);
});

test("按顺序一批批发：发着的时候攒下的同一行合并；核对用的是存上后拿到的时间；撤销擦除按原创建时间补回", async () => {
  const { srv, store } = await loaded([row("S1", "u1")]);
  const problems = [];
  const s = new EditSession("w", "d", store, () => {}, () => {}, (p) => problems.push(p), srv.post);
  const s2 = stroke("S2");
  s.addStroke(0, s2);
  assert.equal(srv.posts.length, 1);
  const first = srv.posts[0];
  assert.equal(first.upserts[0].id, "S2");
  assert.equal(first.upserts[0].kind, 2);
  assert.equal(first.upserts[0].baseUpdatedAt, undefined, "新建不带核对时间");
  assert.deepEqual(Array.from(decodePoints(base64Bytes(first.upserts[0].points))), Array.from(s2.pts));
  assert.deepEqual(first.upserts[0].anchor, [0.25, 0.25, 0.5, 0.25], "包围盒");
  assert.equal(s.pending, 1);

  s.eraseStrokes(0, [s2]);                       // 发着的时候又擦了它
  const s1 = store.page(0).strokes.find((x) => x.id === "S1");
  s.eraseStrokes(0, [s1]);
  assert.equal(srv.posts.length, 1, "上一批回来之前不发");
  assert.deepEqual(ids(store), []);

  first.res({ head: 2, updatedAt: "u2", results: [{ id: "S2", outcome: "applied" }] });
  await tick();
  assert.equal(srv.posts.length, 2);
  assert.deepEqual(srv.posts[1].deletes, [{ id: "S2", baseUpdatedAt: "u2" }, { id: "S1", baseUpdatedAt: "u1" }]);
  srv.posts[1].res({ head: 3, updatedAt: "u3", results: [{ id: "S2", outcome: "applied" }, { id: "S1", outcome: "applied" }] });
  await tick();
  assert.equal(s.pending, 0);
  assert.equal(store.serverStamp.get("S1"), null, "删掉了");

  s.undo();                                      // 撤销擦 S1
  assert.deepEqual(ids(store), ["S1"]);
  const up = srv.posts[2].upserts[0];
  assert.equal(up.id, "S1");
  assert.equal(up.createdAt, "c-S1", "按原来的创建时间补回（叠放顺序不变）");
  assert.equal(up.baseUpdatedAt, undefined);
  assert.ok(s.canRedo);
  assert.deepEqual(problems, []);
});

test("服务器说别的设备改过了：撤掉、提示", async () => {
  const { srv, store } = await loaded([row("S1", "u1")]);
  const problems = [];
  const s = new EditSession("w", "d", store, () => {}, () => {}, (p) => problems.push(p), srv.post);
  s.eraseStrokes(0, [store.page(0).strokes[0]]);
  assert.deepEqual(ids(store), []);
  srv.posts[0].res({ head: 2, updatedAt: "u2", results: [{ id: "S1", outcome: "stale" }] });
  await tick();
  assert.deepEqual(ids(store), ["S1"]);
  assert.deepEqual(problems, ["stale"]);
});

test("文字笔记：改正文时原来 payload 里别的键原样留着", async () => {
  const note = {
    id: "N1", kind: 0, page: 1, anchor: [0.1, 0.2, 0, 0], createdAt: "c", updatedAt: "u1",
    payload: '{"quote":"","text":"旧","rects":[],"type_id":"T","card":{"dx":1,"dy":2},"source":{"kind":"ai"}}',
  };
  const { srv, store } = await loaded([note]);
  const s = new EditSession("w", "d", store, () => {}, () => {}, () => {}, srv.post);
  const before = store.page(1).notes[0];
  s.saveNote(1, before, { ...before, text: "新" });
  const up = srv.posts[0].upserts[0];
  assert.equal(up.kind, 0);
  assert.equal(up.baseUpdatedAt, "u1");
  assert.deepEqual(JSON.parse(up.payload), {
    quote: "", text: "新", rects: [], type_id: "T", card: { dx: 1, dy: 2 }, source: { kind: "ai" },
  });
  assert.equal(store.page(1).notes[0].text, "新");
  s.undo();
  assert.equal(store.page(1).notes[0].text, "旧");
});

test("擦除拖动：一次拖动里擦的几批，撤销时算一步", async () => {
  const { srv, store } = await loaded([row("S1", "u1"), row("S2", "u2")]);
  const s = new EditSession("w", "d", store, () => {}, () => {}, () => {}, srv.post);
  const [a, b] = store.page(0).strokes;
  s.beginGroup();
  s.eraseStrokes(0, [a]);
  s.eraseStrokes(0, [b]);
  s.endGroup();
  assert.deepEqual(ids(store), []);
  s.undo();
  assert.deepEqual(ids(store), ["S1", "S2"]);
  assert.ok(!s.canUndo);
});

test("⇧ 直线吸附与 id", () => {
  assert.deepEqual(rulerSnap(0, 0, 1, 0.05), [Math.hypot(1, 0.05), 0], "接近水平 → 水平，长度不变");
  const [x, y] = rulerSnap(0, 0, 0.5, 0.5 / 1.4 + 0.01, 1.4);
  assert.ok(Math.abs(x - y * 1.4) < 1e-12, "按看上去的 45° 吸附（y 折算页的长宽比）");
  assert.deepEqual(rulerSnap(0, 0, 1, 0.3), [1, 0.3], "离 45° 倍数太远不吸");
  const id = uuid();
  assert.match(id, /^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$/);
  assert.notEqual(uuid(), id);
});
