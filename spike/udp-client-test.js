// UDP 端到端集成测试（node 模拟原生客户端）：WS auth 拿 session/udpPort → UDP 发 RT，
// 人为注入丢包/乱序，验证 Mac 侧帧序、NACK 重传补齐、flushStale 兜底、UNREL 最新胜。
// 运行（项目根目录，零依赖）：
//   node spike/udp-client-test.js
// （内部自动编译 spike/udp-harness.swift + 真 LANServer/WireCodec/UDPReorder/UDPTransport；
//   node < 22 无全局 WebSocket 时会自动带 --experimental-websocket 重启自身。）
"use strict";
const { spawnSync, spawn } = require("child_process");
const path = require("path");

// node 20 需要 flag 才有全局 WebSocket；缺则带 flag 重启自身
if (typeof WebSocket === "undefined") {
  const r = spawnSync(process.execPath, ["--experimental-websocket", __filename, ...process.argv.slice(2)], { stdio: "inherit" });
  process.exit(r.status === null ? 1 : r.status);
}

const dgram = require("dgram");
const Wire = require(path.join(__dirname, "../Sources/Resources/wire.js"));

const BIN = "/tmp/udp-harness";
const TOKEN = "testtoken";

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log("✓ " + name); }
  else { fail++; console.log("✗ " + name + (extra ? "  " + extra : "")); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- 编译并拉起 harness ----
function buildHarness() {
  const srcs = [
    "spike/udp-harness.swift", "spike/udp-harness-stubs.swift",
    "Sources/Server/LANServer.swift", "Sources/Server/WireCodec.swift",
    "Sources/Server/UDPReorder.swift", "Sources/Server/UDPTransport.swift",
  ];
  const r = spawnSync("swiftc", [...srcs, "-o", BIN], { stdio: "inherit" });
  if (r.status !== 0) { console.log("✗ harness 编译失败"); process.exit(1); }
}

// ---- UDP 传输头（PROTOCOL.md §6）----
function datagram(ptype, session, seq, body) {
  const head = Buffer.alloc(6 + (ptype <= 2 ? 4 : 0));
  head[0] = 0x01; head[1] = ptype;
  head.writeUInt32LE(session >>> 0, 2);
  if (ptype <= 2) head.writeUInt32LE(seq >>> 0, 6);
  return head.length && body ? Buffer.concat([head, Buffer.from(body)]) : head;
}

async function main() {
  buildHarness();
  const harness = spawn(BIN, [], { stdio: ["ignore", "pipe", "inherit"] });
  const evLines = [];                       // harness 应用帧的 EV 行（有序）
  let ready = null;
  let buf = "";
  harness.stdout.on("data", (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      if (line.startsWith("READY")) ready = line;
      else if (line.startsWith("EV")) { evLines.push(line); }
    }
  });
  const kill = () => { try { harness.kill("SIGKILL"); } catch (_) {} };
  process.on("exit", kill);

  // 等 READY
  for (let i = 0; i < 100 && !ready; i++) await sleep(50);
  if (!ready) { console.log("✗ harness 未就绪"); kill(); process.exit(1); }
  const wsPort = +/ws=(\d+)/.exec(ready)[1];
  const udpPort = +/udp=(\d+)/.exec(ready)[1];

  // ---- WS auth ----
  const ws = new WebSocket(`ws://127.0.0.1:${wsPort}`);
  ws.binaryType = "arraybuffer";
  let session = 0, gotUdpPort = 0;
  const nacks = [];                          // 收到的 nack seqs 汇总
  const ring = new Map();                    // REL 重传环形缓冲：seq → datagram
  let udp = null;
  ws.onmessage = (e) => {
    const msg = Wire.decode(e.data);
    if (!msg) return;
    if (msg.type === "authOK") { session = msg.session; gotUdpPort = msg.udpPort; }
    else if (msg.type === "nack") {
      nacks.push(...msg.seqs);
      for (const s of msg.seqs) {            // 真实客户端行为：从环形缓冲重发
        const dg = ring.get(s);
        if (dg && udp) udp.send(dg, udpPort, "127.0.0.1");
      }
    }
  };
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  ws.send(Wire.encode({ type: "auth", token: TOKEN }));
  for (let i = 0; i < 100 && !session; i++) await sleep(50);
  check("authOK 带 session/udpPort", session > 0 && gotUdpPort === udpPort,
    `session=${session} udpPort=${gotUdpPort}`);

  // ---- UDP：HELLO + 发送器（自管两个 seq 空间，同真客户端）----
  udp = dgram.createSocket("udp4");
  const send = (dg) => udp.send(dg, udpPort, "127.0.0.1");
  send(datagram(3, session));                // HELLO（一发，无保活）
  let seqRel = 0, seqUnrel = 0;
  const sendRel = (obj) => {
    const dg = datagram(2, session, ++seqRel, Wire.encode(obj));
    ring.set(seqRel, dg);
    send(dg);
    return seqRel;
  };
  const sendUnrel = (obj) => send(datagram(1, session, ++seqUnrel, Wire.encode(obj)));

  // T1：REL 顺序 ink begin/move
  sendRel({ type: "ink", phase: "begin", page: 0, pen: { color: "rgba(24,90,210,0.5)", w: 8, t: "ballpoint" }, pts: [[0.5, 0.5, 0.5]] });
  sendRel({ type: "ink", phase: "move", pts: [[0.25, 0.75, 0.5], [0.5, 0.5, 1]] });
  await sleep(300);

  // T2：REL 乱序——跳过 seq 3 直接发 seq 4（3 留在 ring 等 NACK 重发）
  const skipped = { type: "ink", phase: "move", pts: [[0.1, 0.1, 0.5], [0.2, 0.2, 0.5], [0.3, 0.3, 0.5]] };
  ring.set(++seqRel, datagram(2, session, seqRel, Wire.encode(skipped)));   // 组包入 ring 但不发（模拟丢失）
  sendRel({ type: "ink", phase: "move", pts: [[0.4, 0.4, 0.5], [0.5, 0.5, 0.5], [0.6, 0.6, 0.5], [0.7, 0.7, 0.5]] });
  await sleep(600);                          // 等 nack → 自动重发 → 补齐交付

  // T3：REL 缺口不补——flushStale 兜底（seq 5 永久丢失，ring 里也删掉）
  ring.set(++seqRel, datagram(2, session, seqRel, Wire.encode({ type: "ink", phase: "move", pts: [[0.9, 0.9, 0.5]] })));
  ring.delete(seqRel);                       // 客户端也已淘汰 → NACK 无人应答
  sendRel({ type: "ink", phase: "end" });    // seq 6
  await sleep(700);                          // stallMs=200 + 30ms tick，留足

  // T4：UNREL 最新胜——发 1、3、2（2 是旧包，应被丢弃）
  sendUnrel({ type: "scroll", page: 1, frac: 0.5, t: 1 });
  await sleep(120);
  sendUnrel({ type: "scroll", page: 3, frac: 0.5, t: 3 });
  await sleep(120);
  const stale = datagram(1, session, 2, Wire.encode({ type: "scroll", page: 2, frac: 0.5, t: 2 }));
  send(stale);                               // 不占用 seqUnrel（模拟乱序到达的旧包）
  await sleep(300);

  // T5：坏 session 注入——应被静默丢弃（不崩、不产生 EV）
  send(datagram(2, 0xDEADBEEF, 1, Wire.encode({ type: "ink", phase: "end" })));
  await sleep(300);

  // ---- 断言 ----
  const ev = evLines.join("\n");
  console.log("— harness EV —\n" + ev + "\n——");

  const expectSeq = [
    "EV ink begin page=0 pts=1",
    "EV ink move pts=2",
    "EV ink move pts=3",                     // T2 重传补齐，乱序后仍按序
    "EV ink move pts=4",
    "EV ink end",                            // T3 flushStale 兜底交付
    "EV scroll page=1",
    "EV scroll page=3",
  ];
  const got = evLines.map((l) => l.replace(/ frac=.*/, ""));
  check("应用帧序列与预期一致", JSON.stringify(got) === JSON.stringify(expectSeq),
    "\n  预期=" + JSON.stringify(expectSeq) + "\n  实际=" + JSON.stringify(got));
  check("T2 NACK 触发过 seq 3", nacks.includes(3), "nacks=" + JSON.stringify(nacks));
  check("T3 NACK 触发过 seq 5（无人应答，靠 flushStale）", nacks.includes(5));
  check("T4 旧包 page=2 未应用", !ev.includes("scroll page=2"));
  check("T5 坏 session 无帧应用", got.filter((l) => l.includes("ink end")).length === 1);

  console.log("—");
  console.log(`udp-client: ${pass} 通过, ${fail} 失败`);
  kill();
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => { console.log("✗ 异常: " + (e && e.stack || e)); process.exit(1); });
