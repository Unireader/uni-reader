#!/usr/bin/env python3
"""假 OCR 服务：只用来验 UniReader 客户端的**异步 job 语义**，不需要真模型。

按 `ocr-services/docs/API.md` 同一套格式回：提交即入队（立刻返回 jobId）、状态要走
`pending → running → done`、排队满回 503 + `Retry-After`、识别出错走 `failed` + `errorMsg`、
没跑完就下载回 409。真服务在跑时不用它；它守的是客户端那几轮循环写没写对。

用法：
    python3 spike/ocr-stub-server.py 8790              # 起在 127.0.0.1:8790
控制（先打一条，影响下一个任务）：
    curl -X POST 127.0.0.1:8790/control/503-once        # 下一次提交先吃一个 503
    curl -X POST 127.0.0.1:8790/control/fail-next       # 下一个任务走到 failed
    curl -X POST 127.0.0.1:8790/control/slow            # 任务多轮几次（验轮询节奏）
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# 结果体用云端真实响应裁出来的夹具（与真服务同一套字段），保证解析路径也在被测范围内。
RESULT_FIXTURE = "spike/ocr-wordbox-vector.jsonl"
POLL_ROUNDS = 2          # 默认节奏：pending → running → done（第三次查询才到终态）

with open(RESULT_FIXTURE, "rb") as f:
    RESULT_BODY = f.read()

lock = threading.Lock()
jobs = {}                   # jobId -> 还剩几次查询才到终态
terminal = {}               # jobId -> "done" | "failed"
flags = {"503_once": False, "fail_next": False, "slow": False}
counter = [0]


def reply(handler, code, body=b"", headers=None):
    handler.send_response(code)
    for k, v in (headers or {}).items():
        handler.send_header(k, v)
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    if body:
        handler.wfile.write(body)


def reply_json(handler, code, obj, headers=None):
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    reply(handler, code, json.dumps(obj).encode(), h)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        path = self.path.split("?")[0]
        if path.startswith("/control/"):
            key = path.rsplit("/", 1)[-1].replace("-", "_")
            with lock:
                if key in flags:
                    flags[key] = True
                    reply_json(self, 200, {"ok": key})
                else:
                    reply_json(self, 404, {"detail": "unknown control"})
            return
        if path != "/api/v2/ocr/jobs":
            reply_json(self, 404, {"detail": "no such path"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)                     # 图片收下来就丢，只验流程
        with lock:
            if flags["503_once"]:
                flags["503_once"] = False
                reply_json(self, 503, {"detail": "queue full"}, {"Retry-After": "1"})
                return
            counter[0] += 1
            job = "stub%03d" % counter[0]
            jobs[job] = POLL_ROUNDS + (3 if flags["slow"] else 0)
            terminal[job] = "failed" if flags["fail_next"] else "done"
            flags["fail_next"] = False
            flags["slow"] = False
        reply_json(self, 200, {"data": {"jobId": job}})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/healthz":
            reply_json(self, 200, {"loaded": True, "idle_seconds": 300.0})
            return
        parts = [p for p in path.split("/") if p]
        # /api/v2/ocr/jobs/{id}  或  /api/v2/ocr/jobs/{id}/result.jsonl
        if len(parts) < 5 or parts[:4] != ["api", "v2", "ocr", "jobs"]:
            reply_json(self, 404, {"detail": "no such path"})
            return
        job = parts[4]
        wants_result = path.endswith("result.jsonl")
        with lock:
            if job not in jobs:
                reply_json(self, 404, {"detail": "unknown job"})
                return
            left = jobs[job]
            if left > 1:
                state, jobs[job] = "pending", left - 1
            elif left == 1:
                state, jobs[job] = "running", 0
            else:
                state = terminal[job]
        if wants_result:
            if state != "done":
                reply_json(self, 409, {"detail": "job not finished"})
                return
            reply(self, 200, RESULT_BODY, {"Content-Type": "application/x-ndjson"})
            return
        data = {"state": state}
        if state == "done":
            # 故意回一个指不到人的绝对地址：客户端不该信它（本机服务改过端口就回错地址）。
            data["resultUrl"] = {"jsonUrl": "http://127.0.0.1:1/api/v2/ocr/jobs/%s/result.jsonl" % job}
        if state == "failed":
            data["errorMsg"] = "model load failed (stub)"
        reply_json(self, 200, {"data": data})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
    print("ocr stub on http://127.0.0.1:%d" % port, file=sys.stderr)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
