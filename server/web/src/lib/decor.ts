// 页上的标记怎么摆（方案 §1 第 3 条，只读）：
// - 高亮 / 文字笔记的选区：网页元素（位置用页的百分比，缩放时跟着页走，不用重画）。
//   三种画法照 Mac `PageMarksLayer`：铺色（外扩 1pt × 0.5pt、圆角 2pt）、画线（行框底下，粗 max(1.5pt, 行高 × 7%)）、
//   画框（外扩 1.5pt × 1pt、线宽 1.5pt）。这些「屏幕上固定几点」的量在网页里就是 CSS 像素。
// - 笔迹：每页一块画布（只有这页有可见笔迹时才有），和页面图同样的像素、同时换上。
// - 文字笔记的图钉：直径 18 像素，位置规则同 Mac `ReaderView.notePinCenter`；点它看正文。

import { t } from "./i18n";
import { drawPageInk } from "./ink";
import {
  css, MARK_COLORS, noteMarkColor, pinColor, visibleStrokes,
  type Color, type InkLayer, type MarkStyle, type NoteType, type PageMarks, type TextNote,
} from "./marks";

export class Decor {
  layers: InkLayer[] = [];
  types: NoteType[] = [];
  /** 展开着的笔记气泡（点开的；「始终展开」的笔记被点收起后记在 [closed]）。 */
  private open = new Set<string>();
  private closed = new Set<string>();

  /** 画这一页的笔迹：没有可见笔迹 → null。[cw] × [ch] = 页面图的像素，[fw] × [fh] = 页在适合宽度下的尺寸。 */
  inkCanvas(marks: PageMarks | undefined, cw: number, ch: number, fw: number, fh: number): HTMLCanvasElement | null {
    if (!marks?.strokes.length) return null;
    const strokes = visibleStrokes(marks.strokes, this.layers);
    if (!strokes.length) return null;
    const canvas = document.createElement("canvas");
    canvas.className = "pv-ink";
    canvas.width = cw;
    canvas.height = ch;
    const ctx = canvas.getContext("2d");
    if (!ctx) return null;
    const kx = cw / fw, ky = ch / fh;
    ctx.setTransform(kx, 0, 0, ky, 0, 0);
    drawPageInk(ctx, strokes, fw, fh, kx);
    return canvas;
  }

  /** 在页 [div] 里摆上高亮与图钉（再调 = 按新数据重摆）。 */
  attach(div: HTMLDivElement, marks: PageMarks | undefined) {
    this.detach(div);
    if (!marks || (!marks.highlights.length && !marks.notes.length)) return;
    const layer = el("div", "pv-marks");
    for (const h of marks.highlights) {
      addMark(layer, h.rects, h.style, h.color, MARK_COLORS.highlightFillOpacity);
    }
    for (const n of marks.notes) {
      if (n.rects.length) addMark(layer, n.rects, n.style, noteMarkColor(n, this.types), MARK_COLORS.noteFillOpacity);
    }
    div.appendChild(layer);
    if (!marks.notes.length) return;
    const pins = el("div", "pv-pins");
    for (const n of marks.notes) pins.appendChild(this.pin(n));
    div.appendChild(pins);
  }

  detach(div: HTMLDivElement) {
    div.querySelector(":scope > .pv-marks")?.remove();
    div.querySelector(":scope > .pv-pins")?.remove();
  }

  /** 点在图钉 / 气泡之外：收起点开的气泡（「始终展开」的不收）。 */
  closeAll(root: HTMLElement) {
    if (!this.open.size) return;
    this.open.clear();
    for (const b of root.querySelectorAll<HTMLElement>(".pv-pin-wrap.open:not(.always)")) b.classList.remove("open");
  }

  private isOpen(n: TextNote) {
    return n.display === "always" ? !this.closed.has(n.id) : this.open.has(n.id);
  }

  private pin(n: TextNote): HTMLElement {
    // 图钉中心：选区笔记在选区右上角外侧，点笔记在锚点处；钳在页内（同 Mac，单位是屏幕点）
    const [ax, ay, aw] = n.anchor;
    const hasRects = n.rects.length > 0;
    const x = hasRects ? `calc(${pct(ax + aw)} + 9px)` : pct(ax);
    const y = hasRects ? `calc(${pct(ay)} + 7px)` : pct(ay);
    const wrap = el("div", "pv-pin-wrap");
    wrap.style.left = `clamp(12px, ${x}, calc(100% - 12px))`;
    wrap.style.top = `clamp(10px, ${y}, calc(100% - 10px))`;
    // 图钉在页的右侧四成里时，气泡往左开
    if ((hasRects ? ax + aw : ax) > 0.6) wrap.classList.add("left");
    if (n.display === "always") wrap.classList.add("always");
    if (this.isOpen(n)) wrap.classList.add("open");

    const btn = el("button", "pv-pin") as HTMLButtonElement;
    btn.type = "button";
    btn.style.background = css(pinColor(n, this.types), 1);
    btn.title = n.text || n.quote;
    btn.setAttribute("aria-label", t("Text Note"));
    btn.innerHTML = PIN_ICON;
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      const now = !wrap.classList.contains("open");
      wrap.classList.toggle("open", now);
      if (n.display === "always") {
        if (now) this.closed.delete(n.id);
        else this.closed.add(n.id);
      } else if (now) this.open.add(n.id);
      else this.open.delete(n.id);
    });
    // 「悬停展开」：鼠标 / 手写笔停在图钉上就展开，移开收起（手指没有悬停，照点按处理）
    if (n.display === "hover") {
      btn.addEventListener("pointerenter", (e) => {
        if (e.pointerType !== "touch") wrap.classList.add("hovering");
      });
      btn.addEventListener("pointerleave", () => wrap.classList.remove("hovering"));
    }
    wrap.appendChild(btn);

    // 正文原样显示（Markdown 还没排版）；没写正文的显示原文
    const bubble = el("div", "pv-bubble");
    bubble.textContent = n.text || n.quote;
    if (!n.text) bubble.classList.add("quote");
    bubble.addEventListener("click", (e) => e.stopPropagation());
    wrap.appendChild(bubble);
    return wrap;
  }
}

const PIN_ICON =
  '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 3.5h8M4 6.5h8M4 9.5h5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" fill="none"/></svg>';

function el(tag: string, cls: string): HTMLElement {
  const e = document.createElement(tag);
  e.className = cls;
  return e;
}

const pct = (v: number) => `${(v * 100).toFixed(4)}%`;

/** 一条高亮 / 笔记选区的逐行框。 */
function addMark(layer: HTMLElement, rects: number[][], style: MarkStyle, color: Color, fillOpacity: number) {
  for (const [x, y, w, h] of rects) {
    const d = el("div", `pv-mark ${style}`);
    const s = d.style;
    if (style === "fill") {
      s.left = `calc(${pct(x)} - 1px)`;
      s.top = `calc(${pct(y)} - 0.5px)`;
      s.width = `calc(${pct(w)} + 2px)`;
      s.height = `calc(${pct(h)} + 1px)`;
      s.background = css(color, fillOpacity);
    } else if (style === "underline") {
      // 线粗 = max(1.5, 行高 × 7%)，行高随缩放变：用页高（--ph，排版时设）算
      const thick = `max(1.5px, calc(var(--ph) * ${(h * 0.07).toFixed(6)}))`;
      s.left = `calc(${pct(x)} - 1px - ${thick} / 2)`;
      s.width = `calc(${pct(w)} + 2px + ${thick})`;
      s.top = pct(y + h);
      s.height = thick;
      s.background = css(color, MARK_COLORS.strokeOpacity);
    } else {
      // Mac 的框线居中压在外扩后的框上：网页的边框在盒子里面，所以再外扩半个线宽
      s.left = `calc(${pct(x)} - 2.25px)`;
      s.top = `calc(${pct(y)} - 1.75px)`;
      s.width = `calc(${pct(w)} + 4.5px)`;
      s.height = `calc(${pct(h)} + 3.5px)`;
      s.borderColor = css(color, MARK_COLORS.strokeOpacity);
    }
    layer.appendChild(d);
  }
}
