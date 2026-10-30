# UniReader UDP 传输方案（二进制协议 v1 之上）

> **状态（2026-07-25）：Mac 端已落地**（步骤 1–4，测试全绿），线格式契约已并入 `PROTOCOL.md §6`；
> 本文留档设计理由与客户端（安卓模式2，步骤 5）实现指引。评审定案见 §13。
> 「整体优化」需求②。目标：把**实时流**从 WebSocket(TCP) 迁到 UDP，消除丢包时 TCP 队头阻塞带来的手写延迟抖动。

## 0. 一句话

原生客户端（安卓）把 RT 流（scroll/hover/ink/erase/probe）改走 **UDP**，自管序号；`scroll/hover` 不可靠·最新胜，`ink/erase/probe` 可靠·有序（重排 + 经 WS 发 NACK 轻量重传 + 缺口超时兜底）。控制握手与所有 Mac→端下发仍走 **WS**。**浏览器采集页不受影响**（用不了原生 UDP，永远走 WS，Mac 两条路都收）。

## 1. 约束与总体决策

| 项 | 决策 | 理由 |
|---|---|---|
| 谁能用 UDP | **仅原生客户端**（安卓模式2）。浏览器永远 WS。 | 浏览器无原生 UDP（WebSocket 只有 TCP；WebRTC DataChannel 太重，已否） |
| UDP 方向 | **仅 client→Mac 的 RT 上行**。Mac→client 一律 WS。 | RT 高频在上行；下行是低频状态/控制，可靠更重要。少一个方向 = 少一半复杂度 |
| NACK 方向 | Mac→client 的重传请求走 **WS**（可靠），不走 UDP | 免得再造一条 Mac→client 的 UDP 可靠通道；NACK 本身绝不能丢 |
| 帧本体 | **复用** `PROTOCOL.md §4` 的 `[opcode][payload]` + 现成 `WireCodec`/`wire.js` | UDP 只是在帧外包一层传输头，编解码器一行不改 |
| WS 是否保留 RT | **保留**。Mac 的 `handleInk`/`onScroll` 同时接受来自 WS 与 UDP 的 RT 帧 | 浏览器继续走 WS；原生客户端 UDP 不通时可降级回 WS（见 §7.4） |
| 可靠性 | 客户端**自管**：UNREL 最新胜丢弃；REL 重排+NACK 重传+超时跳过 | 用户既定方向「序号+丢弃/轻量重传」 |

### 1.1 为何可靠通道用 WS 而非裸 TCP（评审澄清）

常见误区：以为 WS 比裸 TCP 延迟大。实则 **WS 就是 TCP + 极薄分帧**（每帧头 2~6 字节，客户端→服务端多 4 字节掩码），同一条 TCP 连接、同 RTT、同拥塞控制——**换裸 TCP 延迟不降、可靠性不变**。

「WS 感觉慢」的延迟来自 **TCP 本身**，裸 TCP 同样中招：① 丢包时**队头阻塞**（后续包等重传）——这才是高频 ink 的痛点，**唯一解法是 UDP**，裸 TCP 换不掉；② **Nagle** 攒小包最多 ~40ms——WS/裸 TCP 都有，但都能用 `TCP_NODELAY` 关掉。

搬走高频流后，可靠通道只剩低频（auth/mode/pen/layout/docs/strokes 回传/viewport/nack），不在延迟热路径。此前提下 WS 明显更优：

| | WS | 裸 TCP |
|---|---|---|
| Mac 服务端 | **已有**（`NWProtocolWebSocket`，浏览器也必须用） | 要**再开** raw TCP listener + 自写分帧 |
| 分帧 | 系统自带（一帧=一消息） | TCP 是字节流，**须自加长度前缀**手写分帧 |
| 安卓客户端 | OkHttp 自带 WebSocket | 手写 socket+分帧+重连 |
| Mac 入站 | 浏览器/安卓**同一套** WS-binary，一条路 | 安卓另走一条，路径分叉 |
| 延迟 | = TCP | = TCP（无优势） |

裸 TCP 唯一省的是一次性 WS 握手（连接时一个 HTTP 101，稳态零影响），却换来多一个服务端 + 手写分帧 + 入站两条路。**不划算**。

**决策：安卓端保留 WS 做可靠通道 + UDP 做 RT 上行。** 低延迟由 UDP 那条负责；WS 只管低频可靠、不拖后腿。另给 Mac WS listener 与安卓 WS 客户端都开 **`TCP_NODELAY`（关 Nagle）**，免低频消息被攒 40ms——零成本正确设置。

## 2. 通道划分

| 消息 | 方向 | 通道 | 类别 |
|---|---|---|---|
| auth / authOK / authFail | 握手 | **WS** | — |
| ping / pong / latency | 心跳 | **WS** | — |
| selectDoc / pageTurn / mode / pen | 控制 | **WS** | — |
| page / layout / viewport / docs / pens / inkCancel / strokes | Mac→端 下发 | **WS** | — |
| **nack**（新增） | Mac→端 重传请求 | **WS** | — |
| **scroll** | 端→Mac | **UDP** | UNREL（最新胜）|
| **hover** | 端→Mac | **UDP** | UNREL（最新胜）|
| **ink**（begin/move/end） | 端→Mac | **UDP** | REL（有序）|
| **erase**（move/end） | 端→Mac | **UDP** | REL（有序）|
| **probe**（begin/move/end） | 端→Mac | **UDP** | REL（有序）|

> 为何 ink/erase/probe 必须可靠：平板本地即时画这一笔只是反馈，**Mac 才是笔迹唯一真源**（成形后 `broadcastStrokes` 全量回传）。UDP 丢了 move 点 → Mac 累积的笔迹缺段 → 回传的成品笔迹有豁口；丢了 begin（含笔属性）/end 更糟（笔起不来/不落库）。故这条子流要有序不丢。
> 为何 scroll/hover 走不可靠：语义是「当前位置」，天生幂等·最新胜；旧包重传毫无意义，丢了等下一包即可——这正是 UDP 的价值（无队头阻塞）。

## 3. 可靠性分级（两个独立 seq 空间）

客户端维护两个单调计数器：`seqUnrel`、`seqRel`，各自从 1 递增。每个 UDP 数据报头里带自己类别的 seq。Mac 按类别分别维护接收状态。**两类 seq 独立**，避免不可靠包在可靠序列里造成假缺口。

- **UNREL（scroll/hover）**：Mac 记 `lastUnrel`。收到 `seq`：`seq > lastUnrel` → 应用 + `lastUnrel=seq`；否则（旧/重复）丢弃。
- **REL（ink/erase/probe）**：Mac 记 `relExpected`（下一个待交付 seq，从 1）+ 重排缓冲 `relBuf[seq]=body`。收到 `seq`：
  - `seq < relExpected`：重复，丢。
  - `seq == relExpected`：交付，`relExpected++`，再把 `relBuf` 里连续的一路排空交付。
  - `seq > relExpected`：存入 `relBuf`；缺口 = `[relExpected, seq)` 中不在 `relBuf` 的那些 → 触发 NACK（节流）。
  - **兜底**：`relExpected` 卡住超过 `stallMs` 且 `relBuf` 非空 → 放弃丢失帧，`relExpected = min(relBuf.keys)`，排空交付（接受一小段豁口，记日志）。避免一个永久丢失的帧把整条 ink 流堵死。

## 4. 线格式：UDP 传输头 + 帧本体

一个 UDP 数据报 = `[传输头][帧本体]`，帧本体就是 `PROTOCOL.md §4` 的 `[u8 opcode][payload]`（原封不动）。全小端。

```
UDP 数据报：
[u8  ver = 0x01]          协议版本
[u8  ptype]               包类型：1=DATA_UNREL  2=DATA_REL  3=HELLO  4=BYE
[u32 session]             会话号（authOK 下发；鉴权/路由）
── ptype ∈ {DATA_UNREL, DATA_REL} 时： ──
[u32 seq]                 该类别内的单调序号（从 1）
[帧本体 = u8 opcode + payload]   见 PROTOCOL.md §4.3（scroll/hover/ink/erase/probe）
── ptype ∈ {HELLO, BYE} 时：无更多字节 ──
```

- `HELLO`：客户端拿到 session 后先发一发，让 Mac 学到其 UDP 源地址 + 校验 session 就绪；之后定时兜发做保活（见 §7.3）。
- `BYE`：客户端主动告知不再用 UDP（可选，纯优化）。
- 头部固定 10 字节（DATA）/ 6 字节（HELLO/BYE）。ink 每点仍是 12 字节（pt3），一条含 N 点的 move 数据报 ≈ 10 + 3 + 2 + N×12 字节。

**新增 WS 消息 `nack`（Mac→端，opcode `0x50`）**：请求重传若干 REL seq。
```
nack payload：[u16 n][n × u32 seq]
对象形状：{type:"nack", seqs:[...]}
```
（浏览器 decode 得到 `{type:"nack",...}` 但无 UDP、直接忽略；安卓客户端据此从环形缓冲重发。）

**`authOK` 扩展**（从空 payload 改为带会话信息）：
```
authOK payload：[u32 session][u16 udpPort]
对象形状：{type:"authOK", session, udpPort}
```
（浏览器忽略这两个字段，行为不变。）

> 三端编解码器（`WireCodec.swift` / `wire.js` / 安卓 Kotlin）需同步：`authOK` 加两字段、新增 `nack`。这属于线格式变更，要更新 `spike/wire-codec-test.swift` + `spike/wire-cross-test.js` 的 canonical 向量。

## 5. 会话建立与地址学习

```
1. 客户端 WS 连接 → 发 auth{token}
2. Mac 校验 token → 生成 session = 随机 u32，登记 session↔WS连接 映射
   → 回 authOK{session, udpPort=8772}（走 WS）
3. 客户端开 UDP socket，向 Mac udpPort 发 HELLO{session}
   → Mac 收到任意 UDP 数据报即从其源端点学到「该 session 的 UDP 回址」（其实 NACK 走 WS，回址仅用于日志/未来 Mac→端 UDP）
4. 客户端开始发 DATA_UNREL / DATA_REL
5. Mac 收 DATA：校验 session 已登记（否则丢弃，防注入）→ 按 §3 排序 → 就绪帧 body 交给现有 handleInk/onScroll
6. Mac 检测 REL 缺口 → 经该 session 的 WS 连接发 nack{seqs}
7. 客户端收 nack → 从环形缓冲重发对应 DATA_REL
8. WS 断开 → 注销 session（其后带该 session 的 UDP 一律丢弃）
```

Mac 上**收到的、已排序就绪的 UDP 帧 body**，`WireCodec.decode(body)` 后走**和 WS 完全相同**的路由（scroll→`onScroll`，hover/ink/erase/probe→`onMessage`→`handleInk`）。即 UDP 只是传输层，`handleInk` 零改动。

## 6. Mac 端接收算法（伪码）

把排序逻辑抽成**纯逻辑、可单测**的类型 `UDPReorder`（仅 Foundation），与网络 I/O 解耦：

```
struct UDPReorder {
  var relExpected: UInt32 = 1
  var relBuf: [UInt32: Data] = [:]
  var lastUnrel: UInt32 = 0
  var lastAdvance: Date

  // 返回 (要按序交付的 body 列表, 要 NACK 的 seq 列表)
  mutating func reliable(_ seq, _ body) -> (deliver: [Data], nack: [UInt32]) {
    if seq < relExpected { return ([], []) }            // 重复
    if relBuf[seq] == nil, seq != relExpected { relBuf[seq] = body }
    if seq == relExpected {
      var out = [body]; relExpected += 1; lastAdvance = now
      while let b = relBuf.removeValue(forKey: relExpected) { out.append(b); relExpected += 1 }
      return (out, [])
    }
    // seq > relExpected：缺口
    let missing = (relExpected..<seq).filter { relBuf[$0] == nil }
    return ([], missing)
  }

  mutating func unreliable(_ seq, _ body) -> Data? {      // nil = 旧包丢弃
    if seq <= lastUnrel { return nil }; lastUnrel = seq; return body
  }

  mutating func flushStale(now) -> [Data] {               // 定时器驱动：缺口超时放弃
    guard !relBuf.isEmpty, now - lastAdvance > stallMs else { return [] }
    relExpected = relBuf.keys.min()!
    var out = [Data]()
    while let b = relBuf.removeValue(forKey: relExpected) { out.append(b); relExpected += 1 }
    lastAdvance = now; return out
  }
}
```

网络层（`UDPTransport.swift` 或 `LANServer` 扩展）：
- `NWListener`(udp) on `udpPort`；每个远端 flow 一个 `NWConnection`，循环 `receiveMessage`（一报一帧）。
- 解传输头 → 校验 `ver`/`session` → 按 ptype 调 `UDPReorder.reliable/unreliable` → 就绪 body 主线程交 `routeInbound`。
- NACK 节流：每 session 每 ~30ms 汇总一次待 NACK 的 seq，经 WS 发 `nack`（去重）。
- 单个 `Timer`(~50ms) 扫所有 session 调 `flushStale`。
- session 登记表随 WS `addClient/dropClient` 增删。

## 7. 客户端发送端（安卓模式2 实现）

### 7.1 发送
- UNREL：`seq=++seqUnrel` → 组 `DATA_UNREL` → 发，不留存。
- REL：`seq=++seqRel` → 组 `DATA_REL` → **存入环形缓冲** `ring[seq]=datagram`（容量上限 N，满则淘汰最旧）→ 发。

### 7.2 重传
- 收 WS `nack{seqs}`：对每个 seq，`ring` 里有就重发那份数据报；没有（太旧被淘汰）就跳过（Mac 端 `flushStale` 会兜底跳过）。

### 7.3 保活与地址
- 拿到 session 后立即发一发 `HELLO`；之后每 ~1s 无 RT 上行时兜发 `HELLO`（LAN 无 NAT，主要为让 Mac 保持 session 活性/日志；也可省，用 WS 心跳兜底）。

### 7.4 降级（UDP 不通时）
- 客户端起 UDP 后，若 `stallMs`×k 内 Mac 从未确认收到（可用一个「首帧回执」或观察 nack/正常回传），判定 UDP 被墙 → **RT 改走 WS**（Mac 的 `handleInk`/`onScroll` 本就接受 WS RT）。保证极端网络下仍能用，只是退回 TCP 语义。

## 8. 参数与旋钮（真机再调）

| 参数 | 初值 | 含义 |
|---|---|---|
| `udpPort` | 8772 | Mac UDP 监听端口 |
| `stallMs` | 200ms | REL 缺口卡死多久后放弃跳过 |
| `nackThrottleMs` | 30ms | 每 session NACK 汇总节流 |
| `ringCap` | 512 帧 | 客户端 REL 重传环形缓冲容量（≈8s@60fps）|
| `helloIntervalMs` | 1000ms | 保活兜发间隔 |

## 9. 安全

- session 是经 token 鉴权的 WS 下发的随机 u32；UDP 数据报须带正确 session 才被处理，挡随手注入。
- 与现有威胁模型一致：LAN 明文，能嗅探 WS token 的攻击者同样能嗅到 session——这是既有前提（局域网、无账号），不在本方案扩展的范围。UDP 不因此比现状更弱。
- 无放大攻击面：Mac UDP 只收不主动回大包（NACK 走 WS 且短）。

## 10. 测试方案

1. **`spike/udp-reorder-test.swift`（确定性单测，核心）**：喂 `UDPReorder` 打乱/丢包/重复的 REL 序列 → 断言交付顺序连续、NACK 集合正确、`flushStale` 跳过行为符合预期；UNREL 断言最新胜。**无网络、可复现**（参考已有 `scroll-follow-sim` 风格）。
2. **`spike/udp-client-test.js`（node dgram 集成，端到端）**：node 用 `dgram` 当原生客户端——先 WS auth 拿 session/udpPort，再经 UDP 发 RT（**人为注入丢包/乱序**），对着一个精简 Swift harness（复用真 `WireCodec` + `UDPReorder` + `LANServer` 收发）验证 Mac 侧最终应用的帧序正确、NACK 能触发重传补齐。node 原生支持 UDP，是理想的测试客户端。
3. 线格式变更（authOK 扩展 + nack）纳入 `wire-codec-test.swift` / `wire-cross-test.js` 的字节向量比对。

## 11. 实施步骤（建议分 PR）

1. **协议层**：`PROTOCOL.md §4/§6` 补 authOK 扩展 + nack + UDP 传输头；三端 codec 同步（`WireCodec.swift` + `wire.js` + 向量测试）。
2. **排序算法**：`UDPReorder`（纯逻辑）+ `spike/udp-reorder-test.swift`。
3. **Mac 网络层**：`UDPTransport`（NWListener udp）接 `UDPReorder`，就绪帧接 `LANServer` 现有 `routeInbound`；`LANServer` 加 session 登记 + `authOK` 带 session/udpPort + NACK 经 WS 发；`flushStale` 定时器。
4. **集成测试**：`spike/udp-client-test.js`（node dgram）+ 精简 harness。
5. **客户端**：并入**安卓模式2**（Kotlin 实现发送端 + 环形缓冲 + nack 重传 + HELLO + WS 降级）。浏览器不动。

## 12. 对现有代码的改动点清单

| 文件 | 改动 |
|---|---|
| `PROTOCOL.md` | §4.1 authOK 带 payload；§4.2 加 nack(0x50)；§6 写 UDP 传输头 |
| `Sources/Server/WireCodec.swift` | authOK 编解码带 session/udpPort；加 nack；（UDP 头解析可放 UDPTransport） |
| `Sources/Resources/wire.js` | 同上（authOK/nack）；客户端不用 UDP 头，但要能收 nack |
| `Sources/Server/LANServer.swift` | session 登记表；authOK 带字段；持有 `UDPTransport`；NACK 经 WS 发；`routeInbound` 抽出供 UDP 复用；**WS listener 的 TCP options 开 `noDelay`（关 Nagle）** |
| `Sources/Server/UDPTransport.swift`（新） | NWListener udp + 传输头解析 + per-session `UDPReorder` + flushStale 定时器 |
| `Sources/App/AppModel.swift` | 基本不动（`handleInk`/`onScroll` 复用）；`authOK` 里的 session/udpPort 由 LANServer 生成，AppModel 无感 |
| `spike/` | `udp-reorder-test.swift`、`udp-client-test.js`；更新 codec 向量测试 |

## 13. 待定问题（评审定案 2026-07-25）

1. **是否要客户端「首帧回执」做 UDP 连通性判定**（§7.4 降级触发）？→ **定案：暂不做额外处理，先看效果**（客户端总是 UDP 发；无自动降级回 WS）。
2. **HELLO 保活是否必要**？→ **定案：不保活**，只在开 UDP 时发一发做 session 就绪校验（LAN 无 NAT，活性由 WS 心跳代表）。
3. **probe 是否真需要 REL**？→ **定案：保持 REL**，真机再看。（probe = 擦除/翻页模式下的探针流：不落墨，只驱动 Mac 侧长按检测/环形盘。）
4. **ringCap 512 是否够**？→ **定案：维持 512，等真机测试后看效果再调**。
5. **实现偏差记录**：`flushStale` 卡死判据从「上次交付时刻」改为「缺口首次出现时刻 `gapSince`」——原判据下两笔间的静置空档会让新缺口被立即跳过，NACK 重传来不及跑（`spike/udp-client-test.js` T2 抓出）。
