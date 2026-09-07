#!/usr/bin/env python3
"""三端笔迹绘制对比 —— 汇总报告。

    <venv>/bin/python spike/ink-cross/report.py <vectors.json> <outDir>

读 `<outDir>/{mac,web,android}/<name>.png`（三端各自用**产品代码**渲的同一份向量），
产出 `<outDir>/report.html`：每条笔画三端并排 + 两两差值图 + 一张可量化的指标表。

🔴 **为什么不是简单的逐像素 diff**：三端的抗锯齿、色彩管理、路径 tessellation 天生不同，
逐像素永远"有差异"，这个数字没有信息量。真正能指认算法分叉的是**结构性指标**：

  · `ink`    总墨量（∑(1−亮度)/像素数）。整体粗细差异——公式或 wScale 对不上就看它。
  · `bbox`   墨的包围盒。位置漂移、长度差异（末段补没补、起笔圆点画没画）。
  · `taper`  端部墨量 ÷ 中部墨量。**起收锥度的判据**：有锥度明显 <1，没锥度 ≈1。
             `fountain-taper` 那条向量就是专为这个指标设计的（Mac 有 fountainTaper，
             web/android 一行都没有）。
  · `rough`  列墨量的相邻差分均值 ÷ 平均列墨量。**纹理粗糙度**：铅笔三道抖动叠加会让它明显
             高于一条光溜的实线，`pencil-texture` 那条就是照它。

指标是**相对**的：同一条向量三端之间比，不与绝对值比。边缘 1px 的差是抗锯齿，看结构不看边缘。
"""

import base64
import json
import os
import sys

import numpy as np
from PIL import Image

PLATS = ["mac", "web", "android"]
PLAT_LABEL = {"mac": "macOS", "web": "web（采集页）", "android": "Android"}
# 墨判定阈值：低于它算纸。抗锯齿的半透明边缘因此不计入 bbox，位置指标才稳。
INK_THR = 0.15


def load_mask(path):
    """PNG → 墨强度矩阵 [0,1]（白纸=0）。

    🔴 用「离白最远的那个通道」而不是亮度：荧光笔是 rgba(250,204,21,0.4)，压在白纸上合成出来
    ≈(253,235,161)，**亮度只比白低 0.09** —— 按亮度算会整条被阈值滤成空白，bbox 直接是 None
    （第一版就栽在这儿）。按通道距离算是 0.37，与蓝笔、铅笔都在同一量级上可比。
    """
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0
    return 1.0 - a.min(axis=2)


def bbox(mask):
    ys, xs = np.where(mask > INK_THR)
    if len(xs) == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def col_ink(mask, box):
    """bbox 内每一列的墨量。比「垂直跨度」稳——跨度会把两条平行线之间的空白也算进去。"""
    x0, y0, x1, y1 = box
    return mask[y0:y1 + 1, x0:x1 + 1].sum(axis=0)


def metrics(mask):
    box = bbox(mask)
    if box is None:
        return {"empty": True}
    ci = col_ink(mask, box)
    n = len(ci)
    seg = max(1, n // 10)
    mid_lo, mid_hi = n // 2 - seg // 2, n // 2 + seg // 2 + 1
    head, tail, mid = ci[:seg].mean(), ci[-seg:].mean(), ci[mid_lo:mid_hi].mean()
    # 相邻列墨量的差分：光溜的线接近 0，抖动纹理明显更高
    rough = float(np.abs(np.diff(ci)).mean() / max(1e-6, ci.mean())) if n > 1 else 0.0
    return {
        "empty": False,
        "ink": float(mask.sum() / mask.size),
        "bbox": box,
        "taper": float((head + tail) / 2 / max(1e-6, mid)),
        "rough": rough,
        "cols": ci,
    }


def crop_box(masks, pad_frac=0.06):
    """三端并集 bbox + padding。🔴 必须三端裁**同一个**框，各裁各的会把位置差异抹掉。"""
    boxes = [bbox(m) for m in masks if m is not None]
    boxes = [b for b in boxes if b is not None]
    if not boxes:
        return None
    x0 = min(b[0] for b in boxes); y0 = min(b[1] for b in boxes)
    x1 = max(b[2] for b in boxes); y1 = max(b[3] for b in boxes)
    w, h = x1 - x0, y1 - y0
    px, py = int(w * pad_frac) + 8, int(h * pad_frac) + 8
    return max(0, x0 - px), max(0, y0 - py), x1 + px, y1 + py


def b64(path, max_w=760):
    img = Image.open(path)
    if img.width > max_w:
        img = img.resize((max_w, max(1, round(img.height * max_w / img.width))), Image.LANCZOS)
    from io import BytesIO
    buf = BytesIO()
    img.save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def diff_image(ma, mb):
    """差值热力图：白=一致，越红差得越多。放大 3 倍对比度，1px 的抗锯齿差看起来才不至于满屏。"""
    d = np.abs(ma - mb)
    v = np.clip(d * 3.0, 0, 1)
    rgb = np.zeros(d.shape + (3,), dtype=np.uint8)
    rgb[..., 0] = 255
    rgb[..., 1] = ((1 - v) * 255).astype(np.uint8)
    rgb[..., 2] = ((1 - v) * 255).astype(np.uint8)
    return Image.fromarray(rgb)


def fmt_bbox(b):
    return "—" if b is None else "%d,%d → %d,%d（%d×%d）" % (b[0], b[1], b[2], b[3], b[2] - b[0], b[3] - b[1])


def rel(a, b):
    """相对差异百分比。两个都接近 0 时返回 0（别让噪音放大成 999%）。"""
    m = max(abs(a), abs(b))
    return 0.0 if m < 1e-6 else abs(a - b) / m * 100


def main():
    vec_path, out_dir = sys.argv[1], sys.argv[2]
    doc = json.load(open(vec_path, encoding="utf-8"))
    crop_dir = os.path.join(out_dir, "crop")
    os.makedirs(crop_dir, exist_ok=True)

    rows, missing = [], []
    for v in doc["strokes"]:
        name = v["name"]
        masks, paths = {}, {}
        for p in PLATS:
            fp = os.path.join(out_dir, p, name + ".png")
            if os.path.exists(fp):
                paths[p] = fp
                masks[p] = load_mask(fp)
            else:
                missing.append("%s/%s" % (p, name))
        if not masks:
            continue

        box = crop_box(list(masks.values()))
        if box is None:
            # 三端都是白纸：不是"没差异"，是三端一起没画出来——当成缺图报出来，别静默跳过。
            missing.append("%s（三端都是空白）" % name)
            continue
        crops, diffs = {}, {}
        for p, m in masks.items():
            img = Image.open(paths[p]).crop(box)
            fp = os.path.join(crop_dir, "%s-%s.png" % (name, p))
            img.save(fp)
            crops[p] = fp
        have = [p for p in PLATS if p in masks]
        for i in range(len(have)):
            for j in range(i + 1, len(have)):
                a, b = have[i], have[j]
                x0, y0, x1, y1 = box
                d = diff_image(masks[a][y0:y1, x0:x1], masks[b][y0:y1, x0:x1])
                fp = os.path.join(crop_dir, "%s-diff-%s-%s.png" % (name, a, b))
                d.save(fp)
                diffs[(a, b)] = fp

        rows.append({
            "v": v, "name": name,
            "met": {p: metrics(m) for p, m in masks.items()},
            "crops": crops, "diffs": diffs, "have": have,
        })

    # ---------- HTML ----------
    H = []
    H.append("""<!doctype html><html lang="zh-Hans"><head><meta charset="utf-8">
<title>UniReader 三端笔迹绘制对比</title><style>
:root{color-scheme:light dark}
body{font:14px/1.6 -apple-system,"PingFang SC",system-ui,sans-serif;margin:0;padding:24px;
     background:#fbfbfd;color:#1c1c1e;max-width:1200px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:34px 0 6px;padding-top:14px;border-top:1px solid #e3e3e8}
.why{color:#5a5a63;font-size:13px;margin:0 0 12px;max-width:900px}
table{border-collapse:collapse;font-size:13px;margin:10px 0}
th,td{border:1px solid #e0e0e6;padding:4px 9px;text-align:right}
th{background:#f2f2f6;font-weight:600}td:first-child,th:first-child{text-align:left}
.grid{display:flex;flex-wrap:wrap;gap:14px;margin:10px 0}
.cell{flex:1 1 340px;min-width:300px}
.cell img{width:100%;border:1px solid #dcdce2;border-radius:6px;background:#fff}
.cap{font-size:12px;color:#5a5a63;margin:3px 0 0}
.flag{background:#fff2f2;border-left:3px solid #d2453d;padding:8px 12px;margin:8px 0;font-size:13px}
.ok{background:#f1f8f2;border-left:3px solid #3a9a52;padding:8px 12px;margin:8px 0;font-size:13px}
code{background:#f0f0f4;padding:1px 5px;border-radius:4px;font-size:12px}
.miss{color:#a04}
@media(prefers-color-scheme:dark){body{background:#141416;color:#e8e8ea}
 th{background:#26262a}th,td{border-color:#38383c}.why,.cap{color:#a0a0a8}
 .flag{background:#2c1a1a}.ok{background:#16241a}code{background:#26262a}
 .cell img{border-color:#38383c}}
</style></head><body>""")
    H.append("<h1>三端笔迹绘制对比</h1>")
    H.append("<p class=why>同一份输入向量（<code>spike/ink-cross/vectors.json</code>），三端各自用"
             "<b>产品代码本身</b>渲染：macOS <code>inkDrawStroke</code> / web <code>buildGeomWith</code> / "
             "Android <code>InkRenderer</code>。工具里没有任何一行复刻的渲染算法——复刻就等于自己跟自己比。<br>"
             "指标是<b>相对</b>的，三端之间比。边缘 1px 的差是抗锯齿，看结构不看边缘。</p>")
    if missing:
        H.append("<p class='why miss'>缺图：%s（那一端没跑或跑失败）</p>" % "、".join(missing))

    # 总览
    H.append("<h2>总览</h2><table><tr><th>笔画</th><th>墨量差异</th><th>锥度 taper</th>"
             "<th>粗糙度 rough</th><th>判读</th></tr>")
    for r in rows:
        met, have = r["met"], r["have"]
        inks = [met[p]["ink"] for p in have if not met[p]["empty"]]
        ink_spread = rel(max(inks), min(inks)) if len(inks) > 1 else 0.0
        tapers = ["%s %.2f" % (p, met[p]["taper"]) for p in have if not met[p]["empty"]]
        roughs = ["%s %.2f" % (p, met[p]["rough"]) for p in have if not met[p]["empty"]]
        tv = [met[p]["taper"] for p in have if not met[p]["empty"]]
        rv = [met[p]["rough"] for p in have if not met[p]["empty"]]
        verdict = []
        if ink_spread > 12:
            verdict.append("墨量差 %.0f%%" % ink_spread)
        if len(tv) > 1 and (max(tv) - min(tv)) > 0.15:
            verdict.append("<b>锥度不一致</b>")
        if len(rv) > 1 and rel(max(rv), min(rv)) > 40:
            verdict.append("<b>纹理不一致</b>")
        H.append("<tr><td><a href='#%s'>%s</a></td><td>%.0f%%</td><td>%s</td><td>%s</td><td>%s</td></tr>"
                 % (r["name"], r["name"], ink_spread, "　".join(tapers), "　".join(roughs),
                    "；".join(verdict) if verdict else "—"))
    H.append("</table>")

    # 逐条
    for r in rows:
        v, met, have = r["v"], r["met"], r["have"]
        H.append("<h2 id='%s'>%s</h2>" % (r["name"], r["name"]))
        H.append("<p class=why>%s</p>" % v.get("why", ""))
        H.append("<p class=why><code>%s</code>　宽 %.1f　%d 点　rgba(%g,%g,%g,%g)</p>"
                 % (v["type"], v["width"], len(v["points"]),
                    v["color"]["r"], v["color"]["g"], v["color"]["b"], v["color"]["a"]))

        H.append("<table><tr><th>端</th><th>墨量</th><th>锥度</th><th>粗糙度</th><th>包围盒</th></tr>")
        for p in have:
            m = met[p]
            if m["empty"]:
                H.append("<tr><td>%s</td><td colspan=4 class=miss>整张全白</td></tr>" % PLAT_LABEL[p])
            else:
                H.append("<tr><td>%s</td><td>%.5f</td><td>%.3f</td><td>%.3f</td><td>%s</td></tr>"
                         % (PLAT_LABEL[p], m["ink"], m["taper"], m["rough"], fmt_bbox(m["bbox"])))
        H.append("</table>")

        H.append("<div class=grid>")
        for p in have:
            H.append("<div class=cell><img src='%s'><p class=cap>%s</p></div>"
                     % (b64(r["crops"][p]), PLAT_LABEL[p]))
        H.append("</div>")
        if r["diffs"]:
            H.append("<div class=grid>")
            for (a, b), fp in r["diffs"].items():
                H.append("<div class=cell><img src='%s'><p class=cap>差值：%s ↔ %s（越红差越多）</p></div>"
                         % (b64(fp), PLAT_LABEL[a], PLAT_LABEL[b]))
            H.append("</div>")

    H.append("</body></html>")
    out = os.path.join(out_dir, "report.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(H))

    # 终端摘要：不打开浏览器也能看出哪几条要修
    print("✓ %s" % out)
    print("%-24s %-9s %s" % ("笔画", "墨量差", "判读"))
    for r in rows:
        met, have = r["met"], r["have"]
        inks = [met[p]["ink"] for p in have if not met[p]["empty"]]
        tv = [met[p]["taper"] for p in have if not met[p]["empty"]]
        rv = [met[p]["rough"] for p in have if not met[p]["empty"]]
        spread = rel(max(inks), min(inks)) if len(inks) > 1 else 0.0
        flags = []
        if spread > 12:
            flags.append("墨量")
        if len(tv) > 1 and (max(tv) - min(tv)) > 0.15:
            flags.append("锥度")
        if len(rv) > 1 and rel(max(rv), min(rv)) > 40:
            flags.append("纹理")
        print("%-24s %6.0f%%   %s" % (r["name"], spread, "、".join(flags) if flags else "—"))


if __name__ == "__main__":
    main()
