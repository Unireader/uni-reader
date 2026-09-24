#!/usr/bin/env python3
# MCP 输出 schema 审查：对着**运行中的 UniReader** 调一遍只读工具，按各自的 outputSchema 严格校验
# structuredContent（多余键 / 缺 required / 值类型）。只用 Python 标准库。
#
# 为什么要它（ACP-AGENT-PLAN.md §4）：我们的 outputSchema 全是 additionalProperties:false，Kimi 的 MCP 客户端
# 严格校验，返回里多一个 schema 没声明的键整个调用就判失败；Claude Code 不校验，所以这类漏洞不会自己暴露。
# 给 MCP 工具加返回字段后跑一遍。写入 / 导航类工具不调用（会改数据、动界面），只列出来提醒人工比对。
#
# 运行（App 开着、MCP 服务开着、最好有一篇文档打开着）：
#   python3 spike/mcp-schema-audit.py                    # 默认 127.0.0.1:8773
#   python3 spike/mcp-schema-audit.py --port 8773 --token <口令>
import argparse
import json
import sys
import urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8773)
ap.add_argument("--token", default=None)
opt = ap.parse_args()
URL = f"http://127.0.0.1:{opt.port}/mcp"
sid = None
seq = 0


def rpc(method, params):
    global sid, seq
    seq += 1
    body = json.dumps({"jsonrpc": "2.0", "id": seq, "method": method, "params": params}).encode()
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
         "MCP-Protocol-Version": "2025-11-25"}
    if sid:
        h["Mcp-Session-Id"] = sid
    if opt.token:
        h["Authorization"] = f"Bearer {opt.token}"
    r = urllib.request.urlopen(urllib.request.Request(URL, body, h))
    sid = r.headers.get("Mcp-Session-Id") or sid
    return json.loads(r.read())


def check(v, s, path, errs):
    if s is None:
        return
    t = s.get("type")
    types = t if isinstance(t, list) else [t] if t else []
    if v is None:
        if types and "null" not in types:
            errs.append(f"{path}: 是 null，schema 不允许")
        return
    if isinstance(v, dict):
        props = s.get("properties", {})
        if s.get("additionalProperties") is False:
            for k in v:
                if k not in props:
                    errs.append(f"{path}.{k}: schema 里没有（多余字段）")
        for k in s.get("required", []):
            if k not in v:
                errs.append(f"{path}.{k}: required 缺失")
        for k, sub in props.items():
            if k in v:
                check(v[k], sub, f"{path}.{k}", errs)
    elif isinstance(v, list):
        for n, x in enumerate(v[:50]):
            check(x, s.get("items"), f"{path}[{n}]", errs)
    else:
        vt = {bool: "boolean", int: "integer", float: "number", str: "string"}.get(type(v))
        if types and not (vt in types or (vt == "integer" and "number" in types)):
            errs.append(f"{path}: 值类型 {vt}，schema 要 {types}")


rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                   "clientInfo": {"name": "schema-audit", "version": "0"}})
tools = {t["name"]: t for t in rpc("tools/list", {})["result"]["tools"]}
cv = rpc("tools/call", {"name": "get_current_view", "arguments": {}}).get("result", {}).get("structuredContent") or {}
doc = cv.get("document_id")
if not doc:
    print("⚠️ 当前没有打开的文档：文档类工具会报错跳过，建议开一篇再跑")

READ_CALLS = [
    ("get_state", {}), ("list_workspaces", {}), ("list_documents", {}), ("get_current_view", {}),
    ("get_document", {"document_id": doc}), ("read_pages", {"document_id": doc, "pages": "1-2"}),
    ("search_text", {"document_id": doc, "query": "the"}), ("list_annotations", {"document_id": doc}),
    ("render_page", {"document_id": doc, "page": 1}),
    ("list_markdown_notes", {}),
]
# Markdown 读取的三种模式（工作区里至少要有一篇 Markdown 笔记）
md = (rpc("tools/call", {"name": "list_markdown_notes", "arguments": {"limit": 1}})
      .get("result", {}).get("structuredContent") or {}).get("notes") or []
if md:
    ref = md[0]["ref"]
    READ_CALLS += [("read_markdown", {"note_ref": ref, "limit": 20}),
                   ("read_markdown", {"note_ref": ref, "search": "a"}),
                   ("read_markdown", {"note_ref": ref, "outline": True})]
else:
    print("⚠️ 工作区里没有 Markdown 笔记：read_markdown 没有校验")
unchecked = set(tools)
bad = 0
for name, args in READ_CALLS:
    unchecked.discard(name)
    if name not in tools:
        print(f"?? {name} 不在工具表里（改名了？更新本脚本）")
        continue
    res = rpc("tools/call", {"name": name, "arguments": args}).get("result") or {}
    if res.get("isError"):
        print(f"⚠️ {name} 调用出错：{res['content'][0].get('text', '')[:120]}")
        continue
    sc = res.get("structuredContent")
    errs = []
    if tools[name].get("outputSchema") and sc is None:
        errs.append("有 outputSchema 却没有 structuredContent")
    check(sc, tools[name].get("outputSchema"), name, errs)
    bad += bool(errs)
    print(("✅ " if not errs else "❌ ") + name + ("" if not errs else "\n   " + "\n   ".join(errs)))
print("未调用（写入 / 导航类，改了返回字段请人工对照 schema）：", ", ".join(sorted(unchecked)))
sys.exit(1 if bad else 0)
