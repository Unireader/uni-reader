// 连续滚动的页面视图（docs/WEB-READER-PLAN.md §1 第 2 条）。
//
// - 所有页一样宽（适合宽度 × 缩放），高按各页长宽比。页面尺寸先按打开时那一页估，真拿到某页再改，
//   改的时候钉住视口里正看着的那一点，不跳。
// - 只给视口附近几页画画布，离开就收回（iPad 上 Safari 的画布总内存有上限，超了就画不出来）。
// - 新图画好才替换旧图，不先清空；缩放时先拉伸旧图，停手后按新倍率重画。
// - 缩放：按钮、Ctrl/⌘ + 滚轮（含触控板捏合）、Safari 的捏合手势、触屏两指捏合；捏合时手指下的那一点不动。
// - 扫描页对齐开着时（`SCAN-ALIGN-PLAN.md`）：页尺寸用对齐后的（宽一律 W、高各页 sh），画页时套每页的变换。
// - 页上的标记（W2）：页面图画好时同一时刻画好笔迹、摆好高亮与图钉（`decor.ts`），一起换上。

import { canvasTransform, type AlignTable } from "./align";
import type { Decor } from "./decor";
import { drawPageInk } from "./ink";
import type { InputHost } from "./input";
import { visibleStrokes, type PageMarks, type Stroke } from "./marks";
import { isCancel, type PageSize, type PageSource, type RenderJob } from "./source";

const GAP = 12;                  // 页与页、页与边的间距（CSS 像素）
const PREFETCH = 1;              // 视口外各预先画几页
const KEEP = 2;                  // 再往外各留几页的画布不收
const MAX_PIXELS = 16_000_000;   // 单块画布的像素上限（iOS Safari 约 1677 万）
const CONCURRENCY = 2;           // 同时画几页
const SETTLE_MS = 180;           // 缩放停手多久后重画
const DOCK_ROOM = 76;            // 最后一页下面留出浮动工具条的高度，能滚到它上面

export const MIN_ZOOM = 0.25;
export const MAX_ZOOM = 6;

interface Slot {
  div: HTMLDivElement;
  canvas: HTMLCanvasElement | null;
  /** 这页的笔迹（没有可见笔迹就没有） */
  ink: HTMLCanvasElement | null;
  /** 现有画布对应的倍率（像素 / pt，0 = 没画） */
  scale: number;
  /** 正在画的倍率（0 = 没在画） */
  busy: number;
  task: RenderJob | null;
  /** 每次开画 / 收回 +1，过期的那次画完就扔掉 */
  gen: number;
}

/** 视口里的一点在哪一页的什么位置（页内比例，可以略出页外，落在页间空隙时）。 */
interface Anchor { i: number; fx: number; fy: number }

interface GestureEventLike extends UIEvent { scale: number; clientX: number; clientY: number }

export interface ViewerEvents {
  /** 当前页（视口中线所在的页，从 0 起）变了 */
  onPage(page: number): void;
  onZoom(zoom: number): void;
  /** 视口附近（会留着画布的）是页 lo…hi：页上的标记该取这几页 */
  onRange?(lo: number, hi: number): void;
}

/** 页上的标记（W2）：数据从哪来、怎么摆。 */
export interface ViewerMarks {
  decor: Decor;
  /** 页 i 的标记；还没取到 = undefined */
  marks(i: number): PageMarks | undefined;
}

export class Viewer implements InputHost {
  readonly count: number;
  zoom = 1;

  private content: HTMLDivElement;
  private slots: Slot[] = [];
  private w: number[];
  private h: number[];
  private known: Uint8Array;
  private learnedAny = false;
  private tops: number[] = [];
  private heights: number[] = [];
  private pageWidth = 0;
  /** 适合宽度下的页宽（CSS 像素）：笔迹的线宽以它为准（同 Mac） */
  private fitWidth = 0;
  private left = 0;
  private running = 0;
  private wanted: number[] = [];
  private active = new Set<number>();
  private current = -1;
  private zooming = false;
  private settleTimer = 0;
  private scrollFrame = 0;
  private relayoutFrame = 0;
  private zoomFrame = 0;
  private pendingZoom: { z: number; a: Anchor; x: number; y: number } | null = null;
  private pinch: { d: number; zoom: number; a: Anchor } | null = null;
  private gesture: { zoom: number; a: Anchor; x: number; y: number } | null = null;
  private resizeObserver: ResizeObserver;
  private destroyed = false;
  /** 正在写 / 擦（W3）：期间的触摸（手写笔自己、手掌）不滚动页面 */
  private inking = false;

  constructor(
    private scroller: HTMLElement,
    private source: PageSource,
    estimate: { width: number; height: number },
    private events: ViewerEvents,
    zoom = 1,
    private align: AlignTable | null = null,
    private extras: ViewerMarks | null = null,
  ) {
    this.count = source.count;
    this.zoom = clamp(zoom, MIN_ZOOM, MAX_ZOOM);
    this.w = new Array(this.count).fill(estimate.width);
    this.h = new Array(this.count).fill(estimate.height);
    this.known = new Uint8Array(this.count);
    if (source.sizes) {
      // 服务器出图：各页尺寸打开时就齐了
      source.sizes.forEach((sz, i) => { this.w[i] = sz.w; this.h[i] = sz.h; });
      this.known.fill(1);
      this.learnedAny = true;
    }
    if (align) {
      // 对齐后的页尺寸是现成的：不用估、不用量
      for (let i = 0; i < this.count; i++) {
        this.w[i] = align.width;
        this.h[i] = align.pages[i].sh;
      }
      this.known.fill(1);
      this.learnedAny = true;
    }
    this.content = document.createElement("div");
    this.content.className = "pv-content";
    for (let i = 0; i < this.count; i++) {
      const div = document.createElement("div");
      div.className = "pv-page";
      div.dataset.label = String(i + 1);
      this.content.appendChild(div);
      this.slots.push({ div, canvas: null, ink: null, scale: 0, busy: 0, task: null, gen: 0 });
    }
    scroller.appendChild(this.content);
    this.layout();

    scroller.addEventListener("scroll", this.onScroll, { passive: true });
    scroller.addEventListener("click", this.onClick);
    scroller.addEventListener("wheel", this.onWheel, { passive: false });
    scroller.addEventListener("touchstart", this.onTouchStart, { passive: false });
    scroller.addEventListener("touchmove", this.onTouchMove, { passive: false });
    scroller.addEventListener("touchend", this.onTouchEnd);
    scroller.addEventListener("touchcancel", this.onTouchEnd);
    scroller.addEventListener("gesturestart", this.onGestureStart);
    scroller.addEventListener("gesturechange", this.onGestureChange);
    scroller.addEventListener("gestureend", this.onGestureEnd);
    this.resizeObserver = new ResizeObserver(() => this.relayout());
    this.resizeObserver.observe(scroller);
  }

  destroy() {
    this.destroyed = true;
    this.resizeObserver.disconnect();
    const s = this.scroller;
    s.removeEventListener("scroll", this.onScroll);
    s.removeEventListener("click", this.onClick);
    s.removeEventListener("wheel", this.onWheel);
    s.removeEventListener("touchstart", this.onTouchStart);
    s.removeEventListener("touchmove", this.onTouchMove);
    s.removeEventListener("touchend", this.onTouchEnd);
    s.removeEventListener("touchcancel", this.onTouchEnd);
    s.removeEventListener("gesturestart", this.onGestureStart);
    s.removeEventListener("gesturechange", this.onGestureChange);
    s.removeEventListener("gestureend", this.onGestureEnd);
    cancelAnimationFrame(this.scrollFrame);
    cancelAnimationFrame(this.relayoutFrame);
    cancelAnimationFrame(this.zoomFrame);
    clearTimeout(this.settleTimer);
    for (const i of [...this.active]) this.release(i);
    this.content.remove();
  }

  // MARK: - 对外

  /** 跳到某页（从 0 起）的某个位置（页内比例，0 = 页顶）。 */
  goTo(page: number, frac = 0) {
    const i = clamp(Math.round(page), 0, this.count - 1);
    this.scroller.scrollTop = this.tops[i] + clamp(frac, 0, 1) * this.heights[i] - (frac > 0 ? 0 : GAP / 2);
    this.update();
  }

  /** 视口顶边在哪一页的什么位置（记阅读进度用，口径同 Mac：视口顶部所在页 + 页内比例）。 */
  position(): { page: number; frac: number } {
    const top = this.scroller.scrollTop;
    const i = this.indexAt(top);
    return { page: i, frac: clamp((top - this.tops[i]) / this.heights[i], 0, 1) };
  }

  /** 缩放到 [z]，视口里 ([x], [y]) 这一点不动（默认视口中心）。 */
  setZoom(z: number, x = this.scroller.clientWidth / 2, y = this.scroller.clientHeight / 2) {
    this.applyZoom(z, this.anchor(x, y), x, y);
  }

  zoomBy(factor: number) { this.setZoom(this.zoom * factor); }

  // MARK: - 给输入用（W3，`input.ts`）

  locate(clientX: number, clientY: number): { page: number; nx: number; ny: number } | null {
    const r = this.scroller.getBoundingClientRect();
    const cx = clientX - r.left + this.scroller.scrollLeft, cy = clientY - r.top + this.scroller.scrollTop;
    const i = this.indexAt(cy);
    const nx = (cx - this.left) / this.pageWidth, ny = (cy - this.tops[i]) / this.heights[i];
    return nx >= 0 && nx <= 1 && ny >= 0 && ny <= 1 ? { page: i, nx, ny } : null;
  }

  norm(page: number, clientX: number, clientY: number): [number, number] {
    const r = this.scroller.getBoundingClientRect();
    const cx = clientX - r.left + this.scroller.scrollLeft, cy = clientY - r.top + this.scroller.scrollTop;
    return [(cx - this.left) / this.pageWidth, (cy - this.tops[page]) / this.heights[page]];
  }

  pageDiv(page: number) { return this.slots[page].div; }

  pageSize(page: number) { return { w: this.pageWidth, h: this.heights[page] }; }

  fitSize(page: number) { return { fw: this.fitWidth, fh: (this.fitWidth * this.h[page]) / this.w[page] }; }

  setInking(on: boolean) { this.inking = on; }

  /**
   * 页上刚加了一笔：它画在最上面（同页没有排在它后面的图层的笔迹）时直接补画到这页的笔迹画布上，
   * 不整页重画（一页几百笔时整页重画要好几十毫秒，写字时每一笔都卡一下）。补不了就整页重画。
   */
  appendInk(page: number, stroke: Stroke) {
    const s = this.slots[page];
    if (!s?.canvas || !this.extras) return;
    const marks = this.extras.marks(page);
    const order = marks ? visibleStrokes(marks.strokes, this.extras.decor.layers) : [];
    if (!s.ink || order[order.length - 1] !== stroke) {
      this.paintMarks(page, s, s.canvas);
      return;
    }
    const ctx = s.ink.getContext("2d");
    if (!ctx) return;
    const { fw, fh } = this.fitSize(page);
    const kx = s.ink.width / fw;
    ctx.setTransform(kx, 0, 0, s.ink.height / fh, 0, 0);
    drawPageInk(ctx, [stroke], fw, fh, kx);
  }

  /** 这几页（默认全部已画的页）的标记变了：重画笔迹、重摆高亮与图钉。页面图不动。 */
  refreshMarks(pages?: Iterable<number>) {
    if (this.destroyed || !this.extras) return;
    for (const i of pages ?? [...this.active]) {
      const s = this.slots[i];
      if (s?.canvas) this.paintMarks(i, s, s.canvas);
    }
  }

  // MARK: - 排版

  private layout() {
    const vw = this.scroller.clientWidth;
    this.fitWidth = Math.max(60, vw - 2 * GAP);
    this.pageWidth = Math.max(60, Math.round(this.fitWidth * this.zoom));
    const cw = Math.max(vw, this.pageWidth + 2 * GAP);
    this.left = Math.round((cw - this.pageWidth) / 2);
    let y = GAP;
    for (let i = 0; i < this.count; i++) {
      const hh = Math.max(1, Math.round((this.pageWidth * this.h[i]) / this.w[i]));
      const s = this.slots[i].div.style;
      s.top = `${y}px`;
      s.left = `${this.left}px`;
      s.width = `${this.pageWidth}px`;
      s.height = `${hh}px`;
      s.setProperty("--ph", `${hh}px`);   // 画线高亮的线粗随页高变（decor.ts）
      this.tops[i] = y;
      this.heights[i] = hh;
      y += hh + GAP;
    }
    this.content.style.width = `${cw}px`;
    this.content.style.height = `${y + DOCK_ROOM}px`;
  }

  /** 重新排版，视口顶边中点那一处不动（窗口变了 / 量到了某页的真尺寸）。 */
  private relayout() {
    if (this.destroyed) return;
    const x = this.scroller.clientWidth / 2;
    const a = this.anchor(x, 0);
    this.layout();
    this.restore(a, x, 0);
    this.update();
  }

  private anchor(x: number, y: number): Anchor {
    const cx = this.scroller.scrollLeft + x, cy = this.scroller.scrollTop + y;
    const i = this.indexAt(cy);
    return { i, fx: (cx - this.left) / this.pageWidth, fy: (cy - this.tops[i]) / this.heights[i] };
  }

  private restore(a: Anchor, x: number, y: number) {
    this.scroller.scrollLeft = this.left + a.fx * this.pageWidth - x;
    this.scroller.scrollTop = this.tops[a.i] + a.fy * this.heights[a.i] - y;
  }

  /** 纵坐标 [cy] 落在哪一页（落在页间空隙算上面那页）。 */
  private indexAt(cy: number): number {
    let lo = 0, hi = this.count - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (this.tops[mid] <= cy) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }

  // MARK: - 缩放

  private applyZoom(z: number, a: Anchor, x: number, y: number) {
    z = clamp(z, MIN_ZOOM, MAX_ZOOM);
    if (Math.abs(z - this.zoom) < 1e-4) return;
    this.zoom = z;
    this.layout();
    this.restore(a, x, y);
    this.events.onZoom(z);
    // 停手之前只拉伸已有的图，不重画
    this.zooming = true;
    clearTimeout(this.settleTimer);
    this.settleTimer = window.setTimeout(() => {
      this.zooming = false;
      this.update();
    }, SETTLE_MS);
    this.update();
  }

  /** 手势里的缩放：每帧最多排一次版。 */
  private requestZoom(z: number, a: Anchor, x: number, y: number) {
    this.pendingZoom = { z, a, x, y };
    if (this.zoomFrame) return;
    this.zoomFrame = requestAnimationFrame(() => {
      this.zoomFrame = 0;
      const p = this.pendingZoom;
      this.pendingZoom = null;
      if (p && !this.destroyed) this.applyZoom(p.z, p.a, p.x, p.y);
    });
  }

  private local(clientX: number, clientY: number): [number, number] {
    const r = this.scroller.getBoundingClientRect();
    return [clientX - r.left, clientY - r.top];
  }

  private onWheel = (e: WheelEvent) => {
    if (!e.ctrlKey && !e.metaKey) return;
    e.preventDefault();
    if (this.gesture) return;   // Safari 捏合走手势事件那条
    const [x, y] = this.local(e.clientX, e.clientY);
    const d = clamp(e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY, -30, 30);
    const base = this.pendingZoom?.z ?? this.zoom;
    this.requestZoom(base * Math.exp(-d / 100), this.pendingZoom?.a ?? this.anchor(x, y), x, y);
  };

  private onTouchStart = (e: TouchEvent) => {
    if (this.inking) {
      e.preventDefault();   // 写字时手写笔 / 手掌碰到屏幕：不滚动
      return;
    }
    if (e.touches.length !== 2) return;
    e.preventDefault();
    const [a, b] = [e.touches[0], e.touches[1]];
    const [x, y] = this.local((a.clientX + b.clientX) / 2, (a.clientY + b.clientY) / 2);
    this.pinch = { d: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY) || 1, zoom: this.zoom, a: this.anchor(x, y) };
  };

  private onTouchMove = (e: TouchEvent) => {
    if (this.inking) {
      e.preventDefault();
      return;
    }
    if (!this.pinch || e.touches.length !== 2) return;
    e.preventDefault();
    const [a, b] = [e.touches[0], e.touches[1]];
    const d = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
    // 两指中点下的那一点跟着中点走：既缩放，也能两指拖动
    const [x, y] = this.local((a.clientX + b.clientX) / 2, (a.clientY + b.clientY) / 2);
    this.requestZoom((this.pinch.zoom * d) / this.pinch.d, this.pinch.a, x, y);
  };

  private onTouchEnd = (e: TouchEvent) => {
    if (e.touches.length < 2) this.pinch = null;
  };

  private onGestureStart = (ev: Event) => {
    ev.preventDefault();   // 不让 Safari 把整个网页放大
    if (this.pinch) return;  // iPad 上触屏捏合已经由 touch 事件处理
    const e = ev as GestureEventLike;
    const [x, y] = this.local(e.clientX, e.clientY);
    this.gesture = { zoom: this.zoom, a: this.anchor(x, y), x, y };
  };

  private onGestureChange = (ev: Event) => {
    ev.preventDefault();
    const e = ev as GestureEventLike;
    if (!this.gesture || this.pinch) return;
    this.requestZoom(this.gesture.zoom * e.scale, this.gesture.a, this.gesture.x, this.gesture.y);
  };

  private onGestureEnd = (ev: Event) => {
    ev.preventDefault();
    this.gesture = null;
  };

  // MARK: - 画

  private onScroll = () => {
    if (this.scrollFrame) return;
    this.scrollFrame = requestAnimationFrame(() => {
      this.scrollFrame = 0;
      this.update();
    });
  };

  /** 按视口算当前页、要画哪些页、收回哪些页的画布。 */
  private update() {
    if (this.destroyed) return;
    const top = this.scroller.scrollTop, bottom = top + this.scroller.clientHeight;
    const first = this.indexAt(top), last = this.indexAt(Math.max(top, bottom - 1));
    const mid = this.indexAt((top + bottom) / 2);
    if (mid !== this.current) {
      this.current = mid;
      this.events.onPage(mid);
    }
    const wanted: number[] = [];
    for (let i = first; i <= last; i++) wanted.push(i);
    wanted.sort((a, b) => Math.abs(a - mid) - Math.abs(b - mid));
    for (let k = 1; k <= PREFETCH; k++) {
      if (last + k < this.count) wanted.push(last + k);
      if (first - k >= 0) wanted.push(first - k);
    }
    this.wanted = wanted;
    const lo = first - PREFETCH - KEEP, hi = last + PREFETCH + KEEP;
    for (const i of [...this.active]) if (i < lo || i > hi) this.release(i);
    this.events.onRange?.(Math.max(0, lo), Math.min(this.count - 1, hi));
    this.pump();
  }

  /** 这一页该用的倍率（像素 / pt）：页宽 × 屏幕像素比，超过画布上限就降。 */
  private targetScale(i: number): number {
    let s = (this.pageWidth / this.w[i]) * (window.devicePixelRatio || 1);
    const px = this.w[i] * this.h[i] * s * s;
    if (px > MAX_PIXELS) s *= Math.sqrt(MAX_PIXELS / px);
    return s;
  }

  private pump() {
    if (this.zooming || this.destroyed) return;
    for (const i of this.wanted) {
      if (this.running >= CONCURRENCY) return;
      const s = this.slots[i], target = this.targetScale(i);
      if (s.busy) {
        if (near(s.busy, target)) continue;
        this.cancel(s);   // 倍率变了：这一趟作废，下面重画
      }
      if (s.canvas && near(s.scale, target)) continue;
      void this.render(i);
    }
  }

  private cancel(s: Slot) {
    s.gen++;
    s.task?.cancel();
    s.task = null;
    s.busy = 0;
  }

  private async render(i: number) {
    const s = this.slots[i];
    const gen = ++s.gen;
    s.busy = this.targetScale(i);
    this.active.add(i);
    this.running++;
    let canvas: HTMLCanvasElement | null = null;
    try {
      const size = await this.source.pageSize(i);
      if (this.destroyed || gen !== s.gen) return;
      this.learn(i, size);
      const scale = this.targetScale(i);
      s.busy = scale;
      const pa = this.align?.pages[i];
      canvas = document.createElement("canvas");
      canvas.className = "pv-pdf";
      // 对齐开着：画布是对齐后的页（W × sh），原始页按每页的变换画上去（转出去的角裁掉、空出的角是白的）
      canvas.width = Math.max(1, Math.floor((pa ? pa.w : size.w) * scale));
      canvas.height = Math.max(1, Math.floor((pa ? pa.sh : size.h) * scale));
      const job = this.source.render(i, scale, canvas, pa ? canvasTransform(pa, scale) : undefined,
                                     pa ? { w: pa.sw, h: pa.sh } : undefined);
      s.task = job;
      await job.promise;
      if (this.destroyed || gen !== s.gen) return;
      if (s.canvas) {
        s.canvas.replaceWith(canvas);
        free(s.canvas);
      } else {
        s.div.prepend(canvas);
      }
      s.canvas = canvas;
      s.scale = scale;
      canvas = null;   // 已经换上了：下面出错也别在 finally 里把它收回
      if (this.extras) this.paintMarks(i, s, s.canvas);
    } catch (e) {
      if (!isCancel(e)) console.warn(`第 ${i + 1} 页没画出来`, e);
    } finally {
      if (canvas) free(canvas);
      if (gen === s.gen) {
        s.task = null;
        s.busy = 0;
      }
      this.running--;
      this.pump();
    }
  }

  /** 记下这一页的真尺寸，和估的不一样就（下一帧）重新排版。第一次量到的尺寸顺带当作其余没量过的页的估计。 */
  private learn(i: number, vp: PageSize) {
    if (this.known[i]) return;
    this.known[i] = 1;
    const changed = Math.abs(vp.w - this.w[i]) > 0.5 || Math.abs(vp.h - this.h[i]) > 0.5;
    if (!this.learnedAny) {
      this.learnedAny = true;
      for (let k = 0; k < this.count; k++) if (!this.known[k]) { this.w[k] = vp.w; this.h[k] = vp.h; }
    }
    this.w[i] = vp.w;
    this.h[i] = vp.h;
    if (changed && !this.relayoutFrame) {
      this.relayoutFrame = requestAnimationFrame(() => {
        this.relayoutFrame = 0;
        this.relayout();
      });
    }
  }

  /** 照页面图的像素画这页的笔迹（画好再换，旧的不先清），重摆高亮与图钉。 */
  private paintMarks(i: number, s: Slot, page: HTMLCanvasElement) {
    if (!this.extras) return;
    const marks = this.extras.marks(i);
    const fw = this.fitWidth, fh = (this.fitWidth * this.h[i]) / this.w[i];
    const ink = this.extras.decor.inkCanvas(marks, page.width, page.height, fw, fh);
    if (s.ink) {
      if (ink) s.ink.replaceWith(ink);
      else s.ink.remove();
      free(s.ink);
    } else if (ink) {
      page.after(ink);
    }
    s.ink = ink;
    this.extras.decor.attach(s.div, marks, i);
  }

  private onClick = (e: MouseEvent) => {
    if (!(e.target as Element | null)?.closest?.(".pv-pin-wrap")) this.extras?.decor.closeAll(this.content);
  };

  private release(i: number) {
    const s = this.slots[i];
    this.cancel(s);
    if (s.canvas) {
      s.canvas.remove();
      free(s.canvas);
      s.canvas = null;
      s.scale = 0;
    }
    if (s.ink) {
      s.ink.remove();
      free(s.ink);
      s.ink = null;
    }
    this.extras?.decor.detach(s.div);
    this.active.delete(i);
    this.source.release(i);
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

function near(a: number, b: number): boolean {
  return Math.abs(a - b) <= 0.01 * Math.max(a, b);
}

/** 画布占的内存马上还回去（只是从页面上拿掉的话，Safari 要等很久才回收）。 */
function free(c: HTMLCanvasElement) {
  c.width = 0;
  c.height = 0;
}
