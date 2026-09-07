// 笔迹几何构建与绘制——**四种笔型的形状算法**，web 端的唯一出处。
//
// 从 `render.ts` 的 `initRender` 闭包里搬出来（2026-09-07），因为它们本来就是纯函数：
// 只吃入参和 `shared.ts` 的公式，一个闭包变量都没用到。搬出来有两个好处：
//  ① 三端绘制对比工具（`spike/ink-cross/`）能直接 import 它们出图——比的是**真源**，
//     不必在工具里复刻一份算法（复刻 = 自己跟自己比，分叉照样藏着）；
//  ② 「几何怎么算」从此不与「画布在哪、滚到哪了」搅在一起。
//
// 🔴 **改这里的算法必须同步另外两端**：Mac `Sources/Views/InkLayers.swift` 的 `inkDrawStroke`、
// 安卓 `android/…/shared/InkRenderer.kt` 的 `build`。三份实现同算法，改一边不改另两边就是分叉
// ——`spike/ink-cross/` 就是用来把这种分叉照出来的，改完顺手跑一次。

import { strokeWidthFor, opacityMultFor, scaledColor, fountainTaper } from "./shared.js";
import type { Stroke } from "./shared.js";

/// 一条笔迹已构建好的几何。路径建在**页局部坐标**（原点＝该页左上角，单位 CSS px，随缩放变），
/// 画的时候只 `translate` 到该页当前位置——于是滚动不改变任何几何，Path2D 原样复用。
export interface InkSeg { w: number; path: Path2D; fill?: boolean }
export interface InkGeom { pw: number; color: string; multiply: boolean; segs: InkSeg[] }

/// 构建几何，**坐标映射与线宽倍率由调用方给**。页笔迹传「归一化 × 页尺寸」、草稿纸传
/// 「点 × zoom」（无限画布上放大就该连笔迹一起放大）。
/// 拆出来的唯一目的是让四种笔型的几何**一份实现两处用**，别再抄一遍（抄一遍就会分叉）。
/// `key` 存进 `InkGeom.pw` 作缓存失效键（页笔迹用页宽，草稿纸用 zoom）。
export function buildGeomWith(s: Stroke, px: (i: number) => number, py: (i: number) => number,
                              wScale: number, key: number): InkGeom {
  const pts = s.pts;
  const t = s.pen.t || "ballpoint";
  const color = scaledColor(s.pen.color, opacityMultFor(t));
  const p = key;
  const segs: InkSeg[] = [];

  if (pts.length === 1) {   // 单点 = 一个圆点（同 Mac 端单点分支）
    const path = new Path2D();
    path.arc(px(0), py(0), strokeWidthFor(t, pts[0][2], s.pen.w) * wScale / 2, 0, Math.PI * 2);
    segs.push({ w: 0, path, fill: true });
    return { pw: p, color, multiply: false, segs };
  }

  let lx = px(0), ly = py(0);
  if (t === "marker") {
    // marker 必须**整条一次成 path**（平头 + multiply）：逐段 stroke 会让相邻段的线帽互相重叠，
    // 不透明笔看不出来，半透明的荧光笔就叠成一串圆斑。
    const path = new Path2D();
    path.moveTo(lx, ly);
    for (let i = 1; i < pts.length; i++) {
      const qx = px(i), qy = py(i);
      path.quadraticCurveTo(lx, ly, (lx + qx) / 2, (ly + qy) / 2);
      lx = qx; ly = qy;
    }
    path.lineTo(lx, ly);   // 补末段（同下方分支：中点平滑链止于倒数两点的中点）
    segs.push({ w: s.pen.w * wScale, path });
    return { pw: p, color, multiply: true, segs };
  }

  // ballpoint / fountain / pencil：线宽随压感变，没法像 marker 那样整条一次 stroke。
  // 但**相邻的、宽度差不多的段可以攒进同一条 Path2D**：它们本就首尾相接（都经过中点），
  // 攒起来不改变形状，一条 50 点的笔迹于是从 50 次 stroke 降到个位数。
  // 合并顺带修掉一个观感 bug：逐段各自半透明合成会让相邻段共享的圆头越叠越黑（Mac 端记的
  // 「黑点瑕疵」根因，那边已改成整条一次 fill），攒进同一条路径后不再重复合成。
  // 断开用**迟滞**而不是绝对分桶：压感几乎每点都在抖，按固定档位会断得比不合并还碎。
  // 起笔圆点。钢笔在这里要吃 taper（i=0 是最细的那一端），否则起笔处凭空鼓出一个圆头。
  const n = pts.length;
  const dot = new Path2D();
  dot.arc(lx, ly, strokeWidthFor(t, pts[0][2], s.pen.w) * fountainTaper(t, 0, n) * wScale / 2, 0, Math.PI * 2);
  segs.push({ w: 0, path: dot, fill: true });

  let lastMidX = lx, lastMidY = ly, curW = -1;
  let cur: Path2D | null = null;
  const openAt = (w: number): void => {
    cur = new Path2D();
    cur.moveTo(lastMidX, lastMidY);
    curW = w;
    segs.push({ w, path: cur });
  };
  const needsBreak = (w: number): boolean => cur === null || Math.abs(w - curW) > Math.max(0.35, curW * 0.08);
  for (let i = 1; i < n; i++) {
    const qx = px(i), qy = py(i);
    // 🔴 `fountainTaper` 是 2026-09-07 补的：此前 web 端一行都没有，同一支钢笔在 Mac 上两头尖、
    // 在平板上齐头齐尾（`spike/ink-cross/` 的 fountain-taper 向量照出来的）。
    const w = strokeWidthFor(t, pts[i][2], s.pen.w) * fountainTaper(t, i, n) * wScale;
    if (needsBreak(w)) openAt(w);
    const mx = (lx + qx) / 2, my = (ly + qy) / 2;
    cur!.quadraticCurveTo(lx, ly, mx, my);
    lastMidX = mx; lastMidY = my; lx = qx; ly = qy;
  }
  // 补末段：上面每步只画到「相邻两点的中点」，末点从来没被连上——长笔画差这半段看不出来，
  // 两点直线（尺子）就是整整少画一半（线尾追不上笔尖）。补一段 lastMid → 末点才落到笔尖。
  const lastW = strokeWidthFor(t, pts[n - 1][2], s.pen.w) * fountainTaper(t, n - 1, n) * wScale;
  if (needsBreak(lastW)) openAt(lastW);
  cur!.lineTo(lx, ly);
  return { pw: p, color, multiply: false, segs };
}

/// 把几何画到指定 context 的指定平移处（页笔迹平移到页左上角，草稿纸平移到 `−视口原点×zoom`）。
export function paintGeomAt(cx: CanvasRenderingContext2D, g: InkGeom, tx: number, ty: number): void {
  cx.save();
  cx.translate(tx, ty);
  if (g.multiply) { cx.globalCompositeOperation = "multiply"; cx.lineCap = "square"; }
  cx.strokeStyle = g.color; cx.fillStyle = g.color;
  for (let i = 0; i < g.segs.length; i++) {
    const seg = g.segs[i];
    if (seg.fill) { cx.fill(seg.path); } else { cx.lineWidth = seg.w; cx.stroke(seg.path); }
  }
  cx.restore();
}
