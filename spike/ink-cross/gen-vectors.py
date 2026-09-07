#!/usr/bin/env python3
# 三端笔迹绘制对比工具的**输入向量生成器**。产物 `vectors.json` 是三端共同的唯一真源。
#
#   python3 spike/ink-cross/gen-vectors.py
#
# 🔴 **只许在 STROKES 末尾追加，不许改动已有条目**（同 `wire-cross-test` 向量表、
# `mirror-fp-vectors.txt` 的纪律）。报告要跨时间比对——改了老条目，历史上那些"已修/未修"
# 的结论就全部作废，而你不会知道是哪一条变了。
#
# 坐标一律**页内归一化** [0,1]，第三个分量是压感 [0,1]；三端各自把它乘上同一个画布尺寸。
# 每条笔画单独出一张图（笔型混在一张里，差异会被互相遮住）。

import json
import math
import os

# 画布：三端必须用同一组数。900×600 横幅，一条笔画占满，差异才看得见。
# scale=2 是 HiDPI 倍率——三端都按它出图，否则比的是抗锯齿而不是几何。
CANVAS = {"w": 900, "h": 600, "scale": 2}

BLUE = {"r": 24, "g": 90, "b": 210, "a": 1.0}
BLUE_HALF = {"r": 24, "g": 90, "b": 210, "a": 0.5}
INK = {"r": 30, "g": 30, "b": 34, "a": 1.0}
YELLOW = {"r": 250, "g": 204, "b": 21, "a": 0.4}
GRAPHITE = {"r": 60, "g": 60, "b": 66, "a": 0.95}


def wave(x0, x1, y0, amp, n, press):
    """水平正弦波。press(t) 给出该点压感（t 是 0..1 的归一化行程）。"""
    out = []
    for i in range(n):
        t = i / (n - 1)
        x = x0 + (x1 - x0) * t
        y = y0 + math.sin(t * math.pi * 2.2) * amp
        out.append([round(x, 6), round(y, 6), round(press(t), 6)])
    return out


def line(x0, y0, x1, y1, n, press):
    out = []
    for i in range(n):
        t = i / (n - 1)
        out.append([round(x0 + (x1 - x0) * t, 6), round(y0 + (y1 - y0) * t, 6), round(press(t), 6)])
    return out


def zigzag(x0, x1, ylo, yhi, teeth, per_tooth, press):
    """之字形：段与段之间是急转角——查轮廓拼接处的白洞/黑点。"""
    out = []
    total = teeth * per_tooth
    for i in range(total + 1):
        t = i / total
        x = x0 + (x1 - x0) * t
        phase = (i % (per_tooth * 2)) / (per_tooth * 2)
        y = ylo + (yhi - ylo) * (phase * 2 if phase < 0.5 else (1 - phase) * 2)
        out.append([round(x, 6), round(y, 6), round(press(t), 6)])
    return out


# 🔴 只许在末尾追加。每条的 `why` 说明它是为找什么差异而存在的——没有 why 的向量是死重量。
STROKES = [
    {
        "name": "ballpoint-ramp",
        "why": "基线：压感 0.1→1.0 线性渐变。三端的 strokeWidthFor 公式相同，"
               "所以这条应当高度一致；不一致说明差在几何/平滑链而不是公式。",
        "type": "ballpoint", "color": BLUE, "width": 8.0,
        "points": wave(0.08, 0.92, 0.5, 0.22, 48, lambda t: 0.1 + 0.9 * t),
    },
    {
        "name": "ballpoint-alpha-zigzag",
        "why": "半透明（a=0.5）之字形：查相邻段共享端点的圆头是否被重复合成（"
               "「接缝黑点」的判据）。Mac 已改成攒轮廓一次 fill，web 攒 Path2D，安卓 getFillPath。",
        "type": "ballpoint", "color": BLUE_HALF, "width": 10.0,
        "points": zigzag(0.08, 0.92, 0.3, 0.7, 6, 4, lambda t: 0.75),
    },
    {
        "name": "fountain-taper",
        "why": "🔴 已知分叉的判据：恒压 0.8 的直线。Mac 有 fountainTaper 起收锥度（两端渐细），"
               "web 与 android 一行都没有 → 应当出现「Mac 两头尖、另两端齐头」的显著差异。"
               "修好之后这条会变成三端一致——它是这次对比工具的校准样本。",
        "type": "fountain", "color": INK, "width": 9.0,
        "points": line(0.08, 0.5, 0.92, 0.5, 40, lambda t: 0.8),
    },
    {
        "name": "fountain-ramp",
        "why": "钢笔压感响应曲线（pow(p,1.6)*w*1.3）。公式三端一致，差异只可能来自锥度与平滑链。",
        "type": "fountain", "color": INK, "width": 9.0,
        "points": wave(0.08, 0.92, 0.5, 0.2, 44, lambda t: 0.15 + 0.85 * t),
    },
    {
        "name": "marker-single",
        "why": "马克笔单笔：恒宽 + 平头（square cap）+ multiply。查线帽形状与 multiply 是否都接上了。",
        "type": "marker", "color": YELLOW, "width": 26.0,
        "points": line(0.1, 0.42, 0.9, 0.42, 20, lambda t: 0.7),
    },
    {
        "name": "marker-overlap",
        "why": "🔴 已知欠账「马克笔叠笔接缝变深」的判据：一条自我折返的马克笔。"
               "multiply 下重叠区必然变深，问题是三端深的程度是否一致（"
               "整条一次 path 自重叠 vs 逐段重复合成，差别就在这里）。",
        "type": "marker", "color": YELLOW, "width": 26.0,
        "points": line(0.12, 0.35, 0.88, 0.35, 14, lambda t: 0.7)
                  + line(0.88, 0.62, 0.12, 0.62, 14, lambda t: 0.7)[0:1]
                  + line(0.88, 0.62, 0.12, 0.62, 14, lambda t: 0.7),
    },
    {
        "name": "pencil-texture",
        "why": "🔴 已知欠账「pad 实时反馈阶段铅笔无抖动纹理」的判据：长曲线。"
               "Mac 是 pencilPasses 三道（amp/alpha/wScale/phase）+ 按弧长推进的波动 + jitter；"
               "另两端若只画一道实线，这张图会明显更「干净」。",
        "type": "pencil", "color": GRAPHITE, "width": 12.0,
        "points": wave(0.08, 0.92, 0.5, 0.24, 60, lambda t: 0.45 + 0.35 * math.sin(t * 3.1)),
    },
    {
        "name": "pencil-decel-tail",
        "why": "收笔减速：后半程采样点密度翻三倍。Mac 的波动按**累计弧长**推进正是为了这个"
               "（按点序号走，尾部会炸成锯齿）。查另两端在密采样区会不会炸。",
        "type": "pencil", "color": GRAPHITE, "width": 12.0,
        "points": (line(0.08, 0.5, 0.55, 0.5, 20, lambda t: 0.7)
                   + line(0.55, 0.5, 0.92, 0.5, 60, lambda t: 0.7 - 0.5 * t)),
    },
    {
        "name": "ruler-two-point",
        "why": "尺子直线 = 只有两个采样点。中点平滑链止于「倒数两点的中点」，不补末段就整整少画一半"
               "（三端都补过这个坑，这条是回归）。另：2026-09-06 修过「整条取抬笔前最后一个采样的"
               "压感 → 细成头发丝」，所以两点的压感都给峰值 0.9。",
        "type": "ballpoint", "color": INK, "width": 10.0,
        "points": [[0.1, 0.3, 0.9], [0.9, 0.7, 0.9]],
    },
    {
        "name": "single-dot",
        "why": "单点笔迹走各端的「画个圆」分支（pencil 另有 0.6 alpha 的特判）。查半径公式与 alpha。",
        "type": "ballpoint", "color": BLUE, "width": 16.0,
        "points": [[0.5, 0.5, 0.85]],
    },
    {
        "name": "sharp-turn-backtrack",
        "why": "原路折返：去程与回程的描边轮廓若绕向反号，WINDING 填充会把重叠区抵消成白洞。"
               "安卓 InkRendererTest 专门测过这个，另两端没测——这条把它拉平到三端。",
        "type": "ballpoint", "color": INK, "width": 14.0,
        "points": (line(0.15, 0.5, 0.85, 0.5, 18, lambda t: 0.8)
                   + line(0.85, 0.5, 0.15, 0.5, 18, lambda t: 0.8)),
    },
]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    doc = {
        "_readme": "三端笔迹绘制对比的共同输入向量。由 gen-vectors.py 生成，勿手改；"
                   "只许在生成器的 STROKES 末尾追加。坐标为页内归一化 [0,1]，第三分量是压感。",
        "canvas": CANVAS,
        "strokes": STROKES,
    }
    out = os.path.join(here, "vectors.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("✓ %s（%d 条笔画）" % (out, len(STROKES)))
    for s in STROKES:
        print("   %-24s %-10s %d 点" % (s["name"], s["type"], len(s["points"])))


if __name__ == "__main__":
    main()
