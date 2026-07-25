#!/usr/bin/env python3
# UDP 平板模拟器（真·局域网 UX/延迟实测）：单文件、纯标准库（tkinter + socket），另一台 Mac 直接跑：
#   python3 udp-pad-sim.py --host <Mac的IP> --token <配对token>
# token 在 UniReader「Tablet Handwriting」面板的 URL 里（http://<ip>:8770/?token=XXXX 的 XXXX）。
#
# 行为等价未来的安卓模式2 客户端（PROTOCOL.md §6）：
#   WS（ws://host:8771）auth → authOK 拿 session/udpPort → UDP 发一发 HELLO →
#   RT 流全走 UDP：scroll/hover = UNREL（最新胜），ink/erase = REL（环形缓冲 ringCap=512，
#   收 WS nack 即重发）。pageTurn/ping 走 WS（控制/心跳）。
#
# 操作：拖动 = 手写；滚轮 = 滚动；移动 = hover；E = 橡皮；P = 换笔；←/→ = 翻页；Q = 退出。
# 状态栏：RTT（WS ping）/ REL 已发 / NACK 与重传次数——NACK>0 说明 UDP 真在丢包。
import argparse, base64, os, queue, socket, struct, sys, threading, time
import tkinter as tk

ap = argparse.ArgumentParser()
ap.add_argument("--host", required=True)
ap.add_argument("--token", required=True)
ap.add_argument("--port", type=int, default=8771)
args = ap.parse_args()

# ---------------- 线格式（镜像 WireCodec.swift / wire.js，全小端） ----------------

def s8(v): return struct.pack("<B", v)
def s16(v): return struct.pack("<H", v & 0xFFFF)
def s32(v): return struct.pack("<I", v & 0xFFFFFFFF)
def f32(v): return struct.pack("<f", v)
def f64(v): return struct.pack("<d", v)
def sstr(s):
    b = s.encode()
    return s16(len(b)) + b

BRUSH = {"ballpoint": 0, "fountain": 1, "marker": 2, "pencil": 3}
PENS = [((24, 90, 210, 0.95), 4, "ballpoint"), ((20, 20, 20, 1.0), 6, "pencil"),
        ((220, 40, 40, 0.9), 2.5, "fountain"), ((255, 214, 40, 0.35), 22, "marker")]

def pen_bytes(pen):
    (r, g, b, a), w, t = pen
    return s8(r) + s8(g) + s8(b) + f32(a) + f32(w) + s8(BRUSH[t])

def fr_auth(): return s8(0x01) + sstr(args.token)
def fr_ping(t): return s8(0x10) + f64(t)
def fr_pageturn(d): return s8(0x21) + s8(d)
def fr_scroll(page, frac, t): return s8(0x40) + s32(page) + f32(frac) + f64(t)
def fr_hover(page, nx, ny): return s8(0x41) + s8(1) + s32(page) + f32(nx) + f32(ny)
def fr_hover_end(): return s8(0x41) + s8(2)
def fr_ink_begin(page, pen, pt):
    return s8(0x42) + s8(0) + s32(page) + pen_bytes(pen) + s16(1) + f32(pt[0]) + f32(pt[1]) + f32(pt[2])
def fr_ink_move(pts):
    return s8(0x42) + s8(1) + s16(len(pts)) + b"".join(f32(x) + f32(y) + f32(p) for x, y, p in pts)
def fr_ink_end(): return s8(0x42) + s8(2)
def fr_erase_move(page, pts):
    return s8(0x43) + s8(1) + s32(page) + s16(len(pts)) + b"".join(f32(x) + f32(y) for x, y in pts)
def fr_erase_end(): return s8(0x43) + s8(2)

# ---------------- WS 客户端（stdlib 手写：HTTP Upgrade + 帧编解码） ----------------

class WS:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk: raise RuntimeError("WS 握手被关闭: " + resp.decode(errors="replace"))
            resp += chunk
        head, rest = resp.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n", 1)[0]:
            raise RuntimeError("WS 握手失败: " + head.decode(errors="replace"))
        self.buf = rest
        self.sock.settimeout(None)

    def send(self, payload: bytes):
        # 客户端帧必须掩码
        mask = os.urandom(4)
        n = len(payload)
        if n < 126: head = s8(0x82) + s8(0x80 | n)
        elif n < 65536: head = s8(0x82) + s8(0x80 | 126) + s16(n)
        else: head = s8(0x82) + s8(0x80 | 127) + struct.pack("<Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(head + mask + masked)

    def _need(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk: raise ConnectionError("WS 断开")
            self.buf += chunk

    def recv(self):
        """返回 (opcode, payload)；opcode 2=binary 8=close 9=ping 10=pong"""
        self._need(2)
        b0, b1 = self.buf[0], self.buf[1]
        op = b0 & 0x0F
        masked, ln = b1 & 0x80, b1 & 0x7F
        off = 2
        if ln == 126:
            self._need(off + 2); ln = struct.unpack_from("<H", self.buf, off)[0]; off += 2
        elif ln == 127:
            self._need(off + 8); ln = struct.unpack_from("<Q", self.buf, off)[0]; off += 8
        mask = b""
        if masked:
            self._need(off + 4); mask = self.buf[off:off + 4]; off += 4
        self._need(off + ln)
        payload = self.buf[off:off + ln]
        self.buf = self.buf[off + ln:]
        if mask: payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return op, payload

# ---------------- 客户端状态 ----------------

class Sim:
    def __init__(self):
        self.session = 0
        self.udp_port = 8772
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.seq_rel = 0
        self.seq_unrel = 0
        self.ring = {}          # seq -> datagram（保持插入序，cap 512）
        self.page = 0
        self.page_count = 0
        self.erase = False
        self.pen_i = 0
        self.sent_rel = 0
        self.nacks = 0
        self.resends = 0
        self.rtt = -1.0
        self.ping_t = 0.0
        self.udp_ready = False
        # —— 量化 ——
        self.send_time = {}       # seq -> 首发时刻（随 ring 同步淘汰），nack RTT 用
        self.nack_rtt = -1.0      # 最近 nack 环路耗时（首发→收到 nack）ms
        self.t_end = 0.0          # 最近 ink end 发出时刻
        self.e2e = -1.0           # 最近一笔 end→strokes 回传 ms
        self.mv_count = 0         # 1s 窗口内 move 帧数（看发送端有没有卡）
        self.mv_rate = 0

    def datagram(self, ptype, seq=None, body=b""):
        d = s8(0x01) + s8(ptype) + s32(self.session)
        if seq is not None: d += s32(seq)
        return d + body

    def udp_send(self, d):
        if self.udp_ready: self.udp.sendto(d, (args.host, self.udp_port))

    def send_rel(self, body):
        self.seq_rel += 1
        dg = self.datagram(2, self.seq_rel, body)
        self.ring[self.seq_rel] = dg
        self.send_time[self.seq_rel] = time.time() * 1000
        while len(self.ring) > 512:
            old = next(iter(self.ring))
            del self.ring[old]; self.send_time.pop(old, None)
        self.udp_send(dg)
        self.sent_rel += 1

    def send_unrel(self, body):
        self.seq_unrel += 1
        self.udp_send(self.datagram(1, self.seq_unrel, body))

sim = Sim()
inbox = queue.Queue()     # WS 收线程 → UI 线程

def ws_recv_thread(ws):
    try:
        while True:
            op, payload = ws.recv()
            if op == 8: inbox.put(("closed", None)); return
            if op == 9: ws.send_pong(payload); continue
            if op != 2 or not payload: continue
            t = payload[0]
            if t == 0x02 and len(payload) >= 7:      # authOK
                inbox.put(("authOK", struct.unpack_from("<I", payload, 1)[0],
                           struct.unpack_from("<H", payload, 5)[0]))
            elif t == 0x03: inbox.put(("authFail", None))
            elif t == 0x11 and len(payload) >= 9:    # pong
                inbox.put(("pong", struct.unpack_from("<d", payload, 1)[0]))
            elif t == 0x30 and len(payload) >= 13:   # page
                inbox.put(("page", struct.unpack_from("<I", payload, 5)[0],
                           struct.unpack_from("<I", payload, 9)[0]))
            elif t == 0x50 and len(payload) >= 3:    # nack
                n = struct.unpack_from("<H", payload, 1)[0]
                inbox.put(("nack", [struct.unpack_from("<I", payload, 3 + 4 * i)[0] for i in range(n)]))
            elif t == 0x36:                          # strokes（ink end/erase 后 Mac 全量回传）
                inbox.put(("strokes", time.time() * 1000))
    except Exception as e:
        inbox.put(("error", str(e)))

def ws_send_pong(self, payload):  # 控制帧：opcode 0x8A
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    self.sock.sendall(s8(0x8A) + s8(0x80 | len(payload)) + mask + masked)
WS.send_pong = ws_send_pong

# ---------------- 主流程 + tkinter UI ----------------

def main():
    print(f"UDP Pad Sim → {args.host}（ws:{args.port}）")
    print("操作：拖动=手写 滚轮=滚动 E=橡皮 P=换笔 ←/→=翻页 Q=退出")
    try:
        ws = WS(args.host, args.port)
    except Exception as e:
        print("WS 连接失败:", e); sys.exit(1)
    print("WS 已连接，auth…")
    ws.send(fr_auth())
    threading.Thread(target=ws_recv_thread, args=(ws,), daemon=True).start()

    root = tk.Tk()
    root.title(f"UDP Pad Sim → {args.host}")
    status = tk.Label(root, text="…", anchor="w", font=("Menlo", 11))
    status.pack(fill="x")
    cv = tk.Canvas(root, width=720, height=900, bg="white",
                   highlightthickness=1, highlightbackground="#ccc")
    cv.pack(fill="both", expand=True)

    ink_pts, erase_pts = [], []
    scroll_frac = [0.0]
    scroll_page = [0]
    last_xy = [None]          # 本地回显用：上一段终点（canvas 像素）

    def pen_hex():
        (r, g, b, _), _, _ = PENS[sim.pen_i]
        return "#%02x%02x%02x" % (r, g, b)

    def norm(e):
        w, h = max(cv.winfo_width(), 1), max(cv.winfo_height(), 1)
        return min(max(e.x / w, 0), 1), min(max(e.y / h, 0), 1)

    def flush_batch():
        nonlocal ink_pts, erase_pts
        if ink_pts:
            sim.send_rel(fr_ink_move(ink_pts)); ink_pts = []; sim.mv_count += 1
        if erase_pts:
            sim.send_rel(fr_erase_move(sim.page, erase_pts)); erase_pts = []; sim.mv_count += 1
        root.after(8, flush_batch)

    def on_down(e):
        nonlocal ink_pts, erase_pts
        ink_pts, erase_pts = [], []
        last_xy[0] = (e.x, e.y)
        if not sim.erase:
            x, y = norm(e)
            sim.send_rel(fr_ink_begin(sim.page, PENS[sim.pen_i], (x, y, 0.5)))
        refresh()

    def on_drag(e):
        x, y = norm(e)
        if sim.erase:
            erase_pts.append((x, y))
        else:
            ink_pts.append((x, y, 0.5))
            # 本地即时回显（等价浏览器采集页的本地笔画；Mac 真源以 A 机屏幕为准）
            if last_xy[0]:
                cv.create_line(last_xy[0][0], last_xy[0][1], e.x, e.y,
                               fill=pen_hex(), width=max(1, PENS[sim.pen_i][1] / 2),
                               capstyle="round", smooth=True)
        last_xy[0] = (e.x, e.y)

    def on_up(e):
        on_drag(e)
        nonlocal_flush()
        if sim.erase:
            sim.send_rel(fr_erase_end())
        else:
            sim.t_end = time.time() * 1000       # e2e 计时起点
            sim.send_rel(fr_ink_end())
        last_xy[0] = None

    def nonlocal_flush():
        nonlocal ink_pts, erase_pts
        if ink_pts: sim.send_rel(fr_ink_move(ink_pts)); ink_pts = []; sim.mv_count += 1
        if erase_pts: sim.send_rel(fr_erase_move(sim.page, erase_pts)); erase_pts = []; sim.mv_count += 1

    def on_move(e):
        x, y = norm(e)
        sim.send_unrel(fr_hover(sim.page, x, y))

    def on_leave(e): sim.send_unrel(fr_hover_end())

    def on_wheel(e):
        if sim.page_count <= 0: return
        if scroll_page[0] != sim.page: scroll_page[0], scroll_frac[0] = sim.page, 0.0
        scroll_frac[0] -= e.delta / 600.0      # 方向不对就翻转这行符号
        while scroll_frac[0] >= 1 and scroll_page[0] < sim.page_count - 1:
            scroll_frac[0] -= 1; scroll_page[0] += 1
        while scroll_frac[0] < 0 and scroll_page[0] > 0:
            scroll_frac[0] += 1; scroll_page[0] -= 1
        scroll_frac[0] = min(max(scroll_frac[0], 0), 1)
        sim.send_unrel(fr_scroll(scroll_page[0], scroll_frac[0], time.time() * 1000))

    def on_key(e):
        k = e.keysym.lower()
        if k == "e": sim.erase = not sim.erase
        elif k == "p": sim.pen_i = (sim.pen_i + 1) % len(PENS); sim.erase = False
        elif k == "q":
            sim.udp_send(sim.datagram(4)); root.destroy(); return   # BYE
        elif k == "left": ws.send(fr_pageturn(0))
        elif k == "right": ws.send(fr_pageturn(1))
        refresh()

    def refresh():
        tool = "橡皮" if sim.erase else PENS[sim.pen_i][2]
        status.config(text=("%s  page %d/%d  rtt %.0fms  e2e %.0fms  nackRTT %.0fms"
                            "  mv/s %d  nack %d  resend %d  [%s]") % (
            "UDP✓" if sim.udp_ready else "…", sim.page + 1, sim.page_count,
            sim.rtt, sim.e2e, sim.nack_rtt, sim.mv_rate, sim.nacks, sim.resends, tool))

    def pump():
        while True:
            try: msg = inbox.get_nowait()
            except queue.Empty: break
            kind = msg[0]
            if kind == "authOK":
                sim.session, sim.udp_port = msg[1], msg[2]
                sim.udp_ready = True
                sim.udp_send(sim.datagram(3))        # HELLO 一发（不保活，评审定案）
                print(f"authOK session={sim.session} udpPort={sim.udp_port} → UDP 就绪")
            elif kind == "authFail":
                print("authFail：token 不对（App 每次启动重新生成，去面板复制最新的）")
            elif kind == "pong":
                sim.rtt = time.time() * 1000 - msg[1]
            elif kind == "page":
                sim.page, sim.page_count = msg[1], msg[2]
            elif kind == "nack":
                seqs = msg[1]
                sim.nacks += len(seqs)
                now = time.time() * 1000
                for sq in seqs:
                    t0 = sim.send_time.get(sq)
                    if t0: sim.nack_rtt = now - t0
                    dg = sim.ring.get(sq)
                    if dg: sim.udp.sendto(dg, (args.host, sim.udp_port)); sim.resends += 1
            elif kind == "strokes":
                if sim.t_end: sim.e2e = msg[1] - sim.t_end
            elif kind in ("closed", "error"):
                print("WS", kind, msg[1] or "")
            refresh()
        root.after(15, pump)

    def heartbeat():
        sim.ping_t = time.time() * 1000
        try: ws.send(fr_ping(sim.ping_t))
        except Exception: pass
        root.after(2000, heartbeat)

    def sampler():
        sim.mv_rate = sim.mv_count; sim.mv_count = 0
        refresh()
        root.after(1000, sampler)

    cv.bind("<ButtonPress-1>", on_down)
    cv.bind("<B1-Motion>", on_drag)
    cv.bind("<ButtonRelease-1>", on_up)
    cv.bind("<Motion>", on_move)
    cv.bind("<Leave>", on_leave)
    cv.bind("<MouseWheel>", on_wheel)
    root.bind("<Key>", on_key)

    root.after(8, flush_batch)
    root.after(15, pump)
    root.after(2000, heartbeat)
    root.after(1000, sampler)
    refresh()
    root.mainloop()

if __name__ == "__main__":
    main()
