// 笔迹画到 canvas 上。🔴 逐分支照 Mac `Sources/Reader/InkRenderCG.swift`（drawStroke，非快速那条）：
// - 四种笔：圆珠笔 / 钢笔（压感变宽 + 钢笔锥度）、马克笔（恒宽、平头、正片叠底）、铅笔（三道波动叠加）；
// - 中点二次曲线平滑 + 补末段；
// - 一笔的各段先合成一个轮廓再一次填充：半透明的笔在段与段的接缝处不会叠深。
//   Mac 用 `copy(strokingWithWidth:)` 把每段描边转成轮廓；canvas 没有这个，这里把每段拆成「胶囊」
//   （两端半圆 + 中间矩形，方向一致），全部放进一条路径按非零规则填充，效果相同。
//
// 单位：画之前调用方把上下文缩放好，这里的坐标与线宽都是「适合宽度下的页内点」——
// 与 Mac 一样（阅读区按适合宽度画、`inkScale = 1`，缩放时整体放大），所以笔迹粗细与页面的比例同 Mac。

import {
  fountainTaper, jitter, perp, strokeWidth,
  PENCIL_PASSES, PENCIL_WOBBLE_FREQ, PENCIL_WOBBLE_REF_WIDTH,
} from "./inkmath";
import { css, type Stroke } from "./marks";

/**
 * 一页的笔迹。[fw] × [fh] = 页面在「适合宽度」下的尺寸（CSS 像素）；
 * [pixelsPerUnit] = 画布上一个这种单位是多少像素（决定曲线拆成多细的直线段）。
 */
export function drawPageInk(ctx: CanvasRenderingContext2D, strokes: Stroke[], fw: number, fh: number, pixelsPerUnit: number) {
  for (const st of strokes) drawStroke(ctx, st, fw, fh, pixelsPerUnit);
}

function drawStroke(ctx: CanvasRenderingContext2D, st: Stroke, fw: number, fh: number, ppu: number) {
  const n = st.pts.length / 3;
  if (!n) return;
  const xs = new Float64Array(n), ys = new Float64Array(n), zs = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    xs[i] = st.pts[i * 3] * fw;
    ys[i] = st.pts[i * 3 + 1] * fh;
    zs[i] = st.pts[i * 3 + 2];
  }
  const { type, width: w, color: c } = st;

  if (n === 1) {
    const a = type === "pencil" ? c.a * 0.6 : c.a;
    const r = strokeWidth(type, zs[0], w) / 2;
    ctx.fillStyle = css(c, a);
    ctx.beginPath();
    ctx.arc(xs[0], ys[0], r, 0, Math.PI * 2);
    ctx.fill();
    return;
  }

  if (type === "marker") {
    ctx.save();
    ctx.globalCompositeOperation = "multiply";
    ctx.strokeStyle = css(c);
    ctx.lineWidth = w;
    ctx.lineCap = "square";
    ctx.lineJoin = "round";
    ctx.beginPath();
    ctx.moveTo(xs[0], ys[0]);
    let lx = xs[0], ly = ys[0];
    for (let i = 1; i < n; i++) {
      ctx.quadraticCurveTo(lx, ly, (lx + xs[i]) / 2, (ly + ys[i]) / 2);
      lx = xs[i];
      ly = ys[i];
    }
    ctx.lineTo(lx, ly);
    ctx.stroke();
    ctx.restore();
    return;
  }

  if (type === "pencil") {
    for (const pass of PENCIL_PASSES) {
      const path = new Path2D();
      let px = 0, py = 0, dist = 0;
      for (let i = 0; i < n; i++) {
        if (i > 0) dist += Math.hypot(xs[i] - xs[i - 1], ys[i] - ys[i - 1]);
        const lw = strokeWidth(type, zs[i], w);
        const [nx, ny] = perp(xs, ys, i);
        // 抖动的种子用归一化坐标（Float32 原样，同 Mac 的 `raw[i].dx`）
        const rnd = jitter(st.pts[i * 3], st.pts[i * 3 + 1] + pass.phase);
        const wobW = Math.min(lw, PENCIL_WOBBLE_REF_WIDTH);
        const wob = (Math.sin(dist * PENCIL_WOBBLE_FREQ + pass.phase) * pass.amp + rnd * pass.amp * 0.7) * wobW;
        const cx = xs[i] + nx * wob, cy = ys[i] + ny * wob;
        if (i > 0) capsule(path, px, py, cx, cy, Math.max(0.7, lw * pass.wScale) / 2, true);
        px = cx;
        py = cy;
      }
      ctx.fillStyle = css(c, c.a * pass.alpha);
      ctx.fill(path, "nonzero");
    }
    return;
  }

  // 圆珠笔 / 钢笔
  const path = new Path2D();
  let mx0 = xs[0], my0 = ys[0], lx = xs[0], ly = ys[0];
  for (let i = 1; i < n; i++) {
    const mx = (lx + xs[i]) / 2, my = (ly + ys[i]) / 2;
    const lw = strokeWidth(type, zs[i], w) * fountainTaper(type, i, n);
    quad(path, mx0, my0, lx, ly, mx, my, lw / 2, ppu);
    mx0 = mx;
    my0 = my;
    lx = xs[i];
    ly = ys[i];
  }
  // 补末段：中点链止于倒数两点的中点，末点要单独连上
  const tail = strokeWidth(type, zs[n - 1], w) * fountainTaper(type, n - 1, n);
  capsule(path, mx0, my0, lx, ly, tail / 2, true);
  ctx.fillStyle = css(c);
  ctx.fill(path, "nonzero");
}

/** 二次曲线（起点、控制点、终点）按约 3 像素一段拆成直线，每段一个胶囊。 */
function quad(path: Path2D, x0: number, y0: number, cx: number, cy: number, x1: number, y1: number, r: number, ppu: number) {
  const len = (Math.hypot(cx - x0, cy - y0) + Math.hypot(x1 - cx, y1 - cy)) * ppu;
  const k = Math.min(16, Math.max(1, Math.ceil(len / 3)));
  let px = x0, py = y0;
  for (let j = 1; j <= k; j++) {
    const t = j / k, u = 1 - t;
    const qx = u * u * x0 + 2 * u * t * cx + t * t * x1;
    const qy = u * u * y0 + 2 * u * t * cy + t * t * y1;
    capsule(path, px, py, qx, qy, r, j === 1);
    px = qx;
    py = qy;
  }
}

/**
 * 一段粗线的轮廓：起点圆（[head] 为真时）+ 矩形 + 终点圆。三者绕向相同（屏幕上顺时针），
 * 按非零规则填充时重叠处只算一次。连续的段共用端点，所以起点圆只在一串的第一段画。
 */
function capsule(path: Path2D, x0: number, y0: number, x1: number, y1: number, r: number, head: boolean) {
  if (!(r > 0)) return;
  if (head) circle(path, x0, y0, r);
  const dx = x1 - x0, dy = y1 - y0, len = Math.hypot(dx, dy);
  if (len > 1e-9) {
    const nx = (-dy / len) * r, ny = (dx / len) * r;
    path.moveTo(x0 + nx, y0 + ny);
    path.lineTo(x0 - nx, y0 - ny);
    path.lineTo(x1 - nx, y1 - ny);
    path.lineTo(x1 + nx, y1 + ny);
    path.closePath();
  }
  circle(path, x1, y1, r);
}

function circle(path: Path2D, x: number, y: number, r: number) {
  path.moveTo(x + r, y);
  path.arc(x, y, r, 0, Math.PI * 2, false);
  path.closePath();
}
