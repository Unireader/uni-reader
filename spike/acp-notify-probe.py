#!/usr/bin/env python3
"""ACP 通知探针（不改 App，只观察外部 Agent 实际推来什么）。运行：

    python3 spike/acp-notify-probe.py kimi
    python3 spike/acp-notify-probe.py qwen -p '/compact'
    python3 spike/acp-notify-probe.py claude --seconds 90

要定下两件事的做法：
  ① `session/update` 里到底有没有 `usage_update`，`used` / `size` 什么口径、什么时候更新；
  ② 有没有 `available_commands_update`，命令名带不带斜杠、`/compact` 在不在里面。

只观察不实现：通知原样打出类型与关键字段。🔴 权限请求一律按**取消**回——探针把工作目录放在临时目录，
但绝不批准 Agent 写文件或执行命令（发探针不该有的副作用）。Agent 反过来要读 / 写文件、开终端，
探针也不提供这些能力（回 method not found），让它按自己的内部工具走。
"""
import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

# 预设与 Sources/Agent/AgentConfig.swift 的 Preset 保持一致
PRESETS = {
    "kimi": (["kimi", "acp"], "127.0.0.1"),
    "qwen": (["qwen", "--acp"], ""),
    "claude": (["claude-agent-acp"], ""),
}

PROTOCOL_VERSION = 1


class Probe:
    def __init__(self, argv, workdir, seconds):
        self.argv = argv
        self.workdir = workdir
        self.seconds = seconds
        self.proc = None
        self.inbox = queue.Queue()
        self.next_id = 0
        self.updates = {}          # sessionUpdate 类型 -> 次数
        self.usage = []            # 每次 usage_update 的原始内容
        self.commands = []         # 每次 available_commands_update 的命令名
        self.reply = []            # agent_message_chunk 攒出来的整段回话
        self.prompt_caps = None
        self.cancel_next = False   # --send-then-cancel 时用

    # MARK: 收发

    def start(self):
        env = dict(os.environ)
        # 让 nvm / npm 装的命令找得到（GUI App 里靠登录 shell 的 PATH 解析，这里直接补上）
        extra = [os.path.expanduser("~/.nvm/versions/node/v20.19.5/bin"),
                 os.path.expanduser("~/.local/bin"),
                 os.path.expanduser("~/.kimi-code/bin")]
        env["PATH"] = ":".join(extra) + ":" + env.get("PATH", "")
        self.proc = subprocess.Popen(self.argv, cwd=self.workdir, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, bufsize=1, env=env)
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.inbox.put(json.loads(line))
            except json.JSONDecodeError:
                pass    # Agent 的日志串进 stdout 时忽略

    def send(self, obj):
        self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params, timeout=90):
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.inbox.get(timeout=1)
            except queue.Empty:
                if self.proc.poll() is not None:
                    return None
                continue
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                return msg
            self.handle(msg)
        print(f"  ⏱ {method} {timeout}s 无应答")
        return None

    def handle(self, msg):
        """应答 Agent 发来的请求；通知交给 pump 统一处理。"""
        if "method" not in msg:
            return
        if "id" not in msg:
            return
        method = msg["method"]
        if method == "session/request_permission":
            # 🔴 按取消回：不批准任何写文件 / 执行命令
            self.send({"jsonrpc": "2.0", "id": msg["id"],
                       "result": {"outcome": {"outcome": "cancelled"}}})
            print("  · 权限请求已按取消回")
        else:
            self.send({"jsonrpc": "2.0", "id": msg["id"],
                       "error": {"code": -32601, "message": "probe does not implement " + method}})
            print(f"  · 拒了 {method}（探针不提供该能力）")

    def pump(self, seconds, label=""):
        """收通知，收到 timeout 为止。"""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                msg = self.inbox.get(timeout=0.5)
            except queue.Empty:
                if self.proc.poll() is not None:
                    print(f"  进程已退出（{label}）")
                    return
                continue
            if "method" in msg:
                self.handle(msg)
                if msg.get("method") == "session/update":
                    self.note(msg["params"].get("update", {}))
                elif msg.get("method") == "session/notification":
                    self.note(msg["params"].get("update", {}))
            elif "result" in msg or "error" in msg:
                pass    # 迟到的应答

    def note(self, update):
        kind = update.get("sessionUpdate", "?")
        self.updates[kind] = self.updates.get(kind, 0) + 1
        if kind == "usage_update":
            self.usage.append(update)
            used, size = update.get("used"), update.get("size")
            pct = f" 占比 {used / size * 100:.1f}%" if used and size else ""
            print(f"  · usage_update used={used} size={size}{pct} cost={update.get('cost')}")
        elif kind == "available_commands_update":
            names = [c.get("name") for c in update.get("availableCommands", [])]
            self.commands.append(names)
            print(f"  · available_commands_update（{len(names)} 条）：{' '.join(str(n) for n in names[:40])}")
        elif kind == "agent_message_chunk":
            # 攒成整段回话打印：发命令时「它到底执行了没有」只看这段
            c = update.get("content", {})
            if c.get("type") == "text":
                self.reply.append(c.get("text", ""))
        elif kind == "agent_thought_chunk":
            pass    # 思考碎片不打，只统计
        else:
            print(f"  · {kind}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("agent", nargs="?", default="kimi", choices=list(PRESETS))
    ap.add_argument("-p", "--prompt", default="你好，只回一个字")
    ap.add_argument("--seconds", type=int, default=45, help="等回包与通知的秒数")
    ap.add_argument("--no-prompt", action="store_true", help="只握手 + 建会话，看开局推不推")
    args = ap.parse_args()

    argv, _ = PRESETS[args.agent]
    workdir = tempfile.mkdtemp(prefix=f"acp-probe-{args.agent}-")
    print(f"=== {args.agent}：{' '.join(argv)}（cwd={workdir}）===")
    try:
        p = Probe(argv, workdir, args.seconds)
        try:
            p.start()
        except FileNotFoundError:
            print(f"找不到命令 {argv[0]}（PATH 已补 nvm / ~/.local/bin / ~/.kimi-code/bin）")
            return 1

        ini = p.request("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False},
                                   "terminal": False},
            "clientInfo": {"name": "UniReaderProbe", "title": "UniReaderProbe", "version": "0"},
        })
        if not ini:
            print("握手失败（Agent 可能没登录，或命令不对）")
            return 1
        res = ini.get("result", {})
        caps = res.get("agentCapabilities", {})
        p.prompt_caps = caps.get("promptCapabilities", {})
        print(f"握手 proto={res.get('protocolVersion')} 能力={json.dumps(caps, ensure_ascii=False)}")

        sess = p.request("session/new", {"cwd": workdir, "mcpServers": []})
        if not sess:
            print("建会话失败")
            return 1
        sid = sess["result"]["sessionId"]
        print(f"会话 {sid} modes={json.dumps(sess['result'].get('modes'), ensure_ascii=False)}")

        p.pump(3, "开局")
        if not args.no_prompt:
            print(f"发一句话：{args.prompt}")
            got = p.request("session/prompt",
                            {"sessionId": sid, "prompt": [{"type": "text", "text": args.prompt}]},
                            timeout=args.seconds)
            if got:
                r = got.get("result") or got.get("error")
                print(f"回包：{json.dumps(r, ensure_ascii=False)[:300]}")
            p.pump(5, "回包后")

        print(f"\n=== {args.agent} 结论 ===")
        if p.reply:
            print("Agent 的回话：" + "".join(p.reply)[:400].replace("\n", " ⏎ "))
        print("通知统计：" + (", ".join(f"{k}×{v}" for k, v in sorted(p.updates.items())) or "一条都没有"))
        if p.usage:
            print(f"usage_update {len(p.usage)} 次，最后一次：{json.dumps(p.usage[-1], ensure_ascii=False)}")
        if p.commands:
            flat = p.commands[-1]
            print(f"available_commands_update 最后一次 {len(flat)} 条；"
                  f"带 compact 的：{[n for n in flat if 'compact' in str(n).lower()]}")
        print(f"usage_update: {'有' if 'usage_update' in p.updates else '没有'}；"
              f"available_commands_update: {'有' if 'available_commands_update' in p.updates else '没有'}")
        p.proc.terminate()
        return 0
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
