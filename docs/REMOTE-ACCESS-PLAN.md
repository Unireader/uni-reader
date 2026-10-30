# 远程连接（Tailscale / 公网 IPv6）——现状分析

> 2026-10-10 起草。**只是分析，代码一行没改。** 用户定：先用 Tailscale 实测（§5），按实测结果再决定改哪几条（§6）。
> 模式2 输入板（`pad/`）与网页采集页走同一套服务，下文说的「平板」两者都算；模式1 不连 Mac，不涉及。

## 1. 结论

1. **走 Tailscale，现有设计基本能直接用。** Mac 面板已经列出 Tailscale 的 100.x 地址（`NetInfo` 把 utun 标成「VPN」），
   选它出二维码、平板开着 Tailscale 扫码即可。安全交给 Tailscale（WireGuard 加密 + 只有自己 tailnet 里的设备能连），
   协议本身的明文问题（§2）可以先不管。
2. **公网 IPv6 直连现状不能开放**：全程明文，且 `GET /` 直接给出配对码（§2）。要做得先补 TLS + 全部接口鉴权，
   有了 Tailscale 之后收益很小，**暂不做**。
3. 真正要修的是**慢网络 / 丢包下的行为**（§3）：现在的设计默认局域网（往返 ~5ms、几乎不丢包），
   到了公网有几处会直接出错。这些在 Tailscale 下同样会遇到，尤其是走中继（DERP）时。

本机现状（2026-10-10 查）：这台 Mac **没有公网 IPv6**（en0 只有 ULA 内网地址，utun5 是 Tailscale 的地址）；已装 Tailscale。

## 2. 安全（只影响公网直连；Tailscale 下不成问题）

- **全程明文**：HTTP（8770）/ WebSocket（8771）/ UDP（8772）都没加密。配对码在 `auth` 帧里明文传，二维码地址里也带着。
- **根页面直接给出配对码**：`GET /` 不校验配对码，返回的采集页已替换进配对码
  （`LANServer.route` 的 `"/"` 分支 → `CapturePage.html` 替换 `__TOKEN__`；地址里的 `?token=` 服务端根本不看）。
  能连到 8770 的人就能拿到配对码 → 读书库、看页图、写 / 擦笔迹。局域网里这本来也成立，只是默认同一 Wi-Fi 可信。
- `/page.png`（不带 `d=` = 当前那篇）、`/docmeta`、`/image`、`/info` 都不校验配对码。
- UDP 只认 32 位会话号（`authOK` 里明文下发），不绑定来源地址（这点对换网反而有利）；任何来源都会在
  `UDPTransport.flows` 里留一条连接，只在出错时清。
- **监听不限网卡、IPv4/IPv6 双栈**（`NWListener` 只给端口）：Mac 一旦拿到公网 IPv6 而路由器又不拦入站，
  **不改任何代码就已经在公网上了**。MCP 默认只听 127.0.0.1，切「所有接口」时要求口令，但同样是明文 HTTP。

## 3. 可靠性（慢网络 / 丢包会出错；两条路线都受影响）

1. **写字只走 UDP，没有退路。** 安卓 `PadActivity.sendRel` 只交给 `UdpSender`；HELLO 只发不回（`PROTOCOL.md §6`），
   平板无从知道 UDP 通没通。8772/UDP 一旦被挡（酒店 / 公司网络、只转发了 TCP 端口等）：页图能看、连接显示正常，
   **写的字 Mac 一笔都收不到**。
2. **一笔末尾的包丢了没人发现。** 补发请求（nack）只在「后面的包到了、发现中间缺号」时才发（`UDPReorder.reliable`）。
   一笔的 `ink end` 丢了而后面没有新包 → Mac 不知道少了 → 这一笔一直悬着直到下一笔；平板的乐观笔迹也等不到 `ackRel`。
3. **缺号只等 200ms（`UDPReorder.stallMs`）。** 一次补发 = Mac 定时器 ≤30ms + 经 WS 发 nack + 平板重发 UDP。
   往返 > ~150ms 就来不及，Mac 跳过 → 笔迹缺一段；丢的是 `ink begin` 则整笔没了。而 nack 走的 WS 正是下面那些大帧占着的那条。
4. **心跳 5 秒判死，而心跳会被大帧挡住。** pong 和整份笔迹同走一条 TCP（`MacClient.PONG_TIMEOUT_MS = 5000`）。
   画板整份可到几 MB（`PROTOCOL.md §4.4` 实测 9214 笔 ≈ 8MB），10 Mbps 下要 6~7 秒 → 平板判「心跳超时」断开重连 →
   重连后 Mac 补发全部状态（`AppModel` 的 clientCount sink：strokes / notes / layers …）→ 又是同样大的帧 → **可能一直在重连**。
   追加积压超 64 帧（`LANServer.mirrorQueueCap`）就作废改发全量，慢网下会进一步放大。
5. **页图每张新开一个 TCP 连接**（Mac 回 `Connection: close`），每张多一个往返；首次翻到的页 = 200~600KB + 两个往返 +
   Mac 串行服务队列的排队与渲染。回看靠平板磁盘缓存，不受影响。

## 4. 交互延迟与地址管理

**要等 Mac 回话的操作**（Mac 是唯一真源，往返时间直接变成手感；写字本身是本地先画，不受影响）：
长按环形选笔盘（长按判定和盘上选择都在 Mac）、撤销 / 重做（无本地预览，回来的是整份笔迹）、擦除与框选的最终结果（整份）、翻页跟随。

**地址**：
- Mac 面板 / 二维码只列 IPv4（`NetInfo.ipv4Addresses`），IPv6 不出现。
- 安卓端一律按 `http://$host:8770` / `ws://$host:8771` 拼地址，IPv6 字面量要方括号；局域网发现只收 IPv4（`MacDiscovery` 注释写明是有意的）。
- **历史设备一台 Mac 只留一个地址**：`KnownMacs.renamed` 会删掉「同名不同地址」的旧条目。在家用局域网地址连一次，
  Tailscale 那条就没了，出门得重新扫码；反之亦然。
- Bonjour 发现不跨 Tailscale（不转发组播），出门后只能靠历史设备。
- 用 Tailscale 的 MagicDNS 名字代替 IP 可以免去地址变化（OkHttp 与 `InetAddress.getByName` 都认域名）。

**运行环境**（与代码无关）：外出时 Mac 必须醒着、App 与平板服务开着（睡眠后 Tailscale 也唤不醒）；
安卓同一时间只能跑一个 VPN 类应用，平板若在用别的代理应用就开不了 Tailscale；打洞失败走中继时带宽小、延迟高，§3 会被放大。
有公网 IPv6 的一端能提高 Tailscale 直连成功率——IPv6 与 Tailscale 不是二选一。

## 5. Tailscale 实测怎么做、看什么

1. Mac 平板服务面板里选 Tailscale 那个 100.x 地址（标「VPN」）出二维码；平板开 Tailscale，扫码连上。
2. `tailscale status` / `tailscale ping <平板>` 看是直连还是走中继（`via DERP(...)`）。
3. 看的数：安卓输入板状态栏的延迟图（`rtt` / `e2e` / `nackRTT`）；Mac 日志里 `UDP session …: flushStale 跳过缺口`
   （= 补发没赶上、笔迹缺段）；安卓 logcat `心跳超时，重连中…`（= §3.4）、`UdpSender` 的 `UDP 发送失败`、`UniReader/PageFetch` 的页图耗时。
4. 有意识地试：长时间写字看有无缺段 / 悬着的笔；在大画板上擦除 / 撤销看会不会断线重连；切到手机网络再试一遍。

## 6. 要改的（按优先级，等实测结果再排）

1. **心跳改成「收到任何帧都算活着」**，不再只认 pong（只改安卓 `MacClient` + 网页 `ws.ts`，不动协议）。解决 §3.4 的重连循环。
2. **UDP 要有确认和退路**：Mac 回应 HELLO；收不到就把 ink / erase / probe 改走 WS。🔴 改协议 → 先改 `PROTOCOL.md`，三端同步。
3. **补发改成平板对未确认的包超时主动重发**（`ackRel` 已经是现成的确认），解决 §3.2；`stallMs` 按实测往返放宽或自适应。
4. **历史设备一台 Mac 多个地址**：按配对码指纹归并，不再按名字互删（`KnownMacs`）。
5. 页图 HTTP 支持保持连接（keep-alive）。
6. （暂不做）公网直连所需的 TLS + 全部 HTTP 接口鉴权 + `GET /` 不再无条件下发配对码。
