// 页面上的输入（W3，方案 §1 第 4、5 条；主要设备 = 电脑浏览器 + 安卓平板浏览器，§0）：
// - 鼠标左键 / 手写笔：选了笔就写，选了橡皮就擦（手写笔的橡皮头任何时候都擦）；手指只滚动、缩放。
// - 写字：压感取指针事件的 pressure（鼠标按下时浏览器给 0.5，同 Mac 本机落笔），合并事件逐个取点；
//   落笔不跨页：拖出这一页的上下边就不再记点，左右越界夹在页边（同 Mac `inkDragged`）；按住 ⇧ 画直线（45° 吸附）。
//   鼠标要拖过 2 像素才算开始写（同 Mac：单击不留点）；手写笔一碰就写（点一下 = 一个点）。
// - 橡皮：整笔擦，半径 = 页宽 × 0.02，按页内归一化坐标量距离（同 Mac 整笔模式 `eraseNear`），只擦看得见的图层。
// - 文字笔记：点一下页面 = 在那儿新建（手指点也行）。
// - 写的时候手写笔 / 手掌碰到屏幕产生的触摸一律拦下，不让页面跟着滚。

import { drawPageInk } from "./ink";
import { rulerSnap } from "./inkmath";
import type { Stroke } from "./marks";
import { ERASER_RADIUS, type Pen, type Tool } from "./pens";
import { uuid } from "./uuid";

export interface InputHost {
  /** 视口里 (clientX, clientY) 落在哪一页的什么位置（页内归一化）；落在页外 / 页间空隙 = null */
  locate(clientX: number, clientY: number): { page: number; nx: number; ny: number } | null;
  /** 相对某一页的归一化位置（可以出界） */
  norm(page: number, clientX: number, clientY: number): [number, number];
  pageDiv(page: number): HTMLDivElement;
  /** 页在屏幕上的尺寸（CSS 像素） */
  pageSize(page: number): { w: number; h: number };
  /** 页在适合宽度下的尺寸（笔迹线宽的单位，同 `ink.ts`） */
  fitSize(page: number): { fw: number; fh: number };
  /** 正在写 / 擦：期间的触摸不滚动页面 */
  setInking(on: boolean): void;
}

export interface InputActions {
  tool(): Tool;
  pen(): Pen;
  /** 新的一笔写在哪个图层 */
  layerId(): string;
  /** 这一页看得见的笔迹（橡皮只擦这些） */
  visibleStrokes(page: number): Stroke[];
  strokeDone(page: number, stroke: Stroke): void;
  /** 一次擦除拖动：开始、每擦到一批、结束（撤销时整次拖动算一步） */
  eraseBegin(): void;
  erase(page: number, strokes: Stroke[]): void;
  eraseEnd(): void;
  noteTap(page: number, nx: number, ny: number): void;
}

interface Draft {
  pointerId: number;
  page: number;
  mouse: boolean;
  started: boolean;
  downX: number;
  downY: number;
  pts: number[];
  canvas: HTMLCanvasElement | null;
  frame: number;
}

interface Rub { pointerId: number; last: { page: number; nx: number; ny: number } | null; gone: Set<string> }

const LIVE_MAX_PIXELS = 8_000_000;

export class PageInput {
  private draft: Draft | null = null;
  private rub: Rub | null = null;
  private ring: HTMLDivElement;

  constructor(private scroller: HTMLElement, private host: InputHost, private act: InputActions) {
    this.ring = document.createElement("div");
    this.ring.className = "pv-eraser-ring";
    document.body.appendChild(this.ring);
    scroller.addEventListener("pointerdown", this.onDown);
    scroller.addEventListener("pointermove", this.onMove);
    scroller.addEventListener("pointerup", this.onUp);
    scroller.addEventListener("pointercancel", this.onUp);
    scroller.addEventListener("pointerleave", this.onLeave);
    scroller.addEventListener("click", this.onClick);
    scroller.addEventListener("contextmenu", this.onContextMenu);
  }

  destroy() {
    this.cancelDraft();
    const s = this.scroller;
    s.removeEventListener("pointerdown", this.onDown);
    s.removeEventListener("pointermove", this.onMove);
    s.removeEventListener("pointerup", this.onUp);
    s.removeEventListener("pointercancel", this.onUp);
    s.removeEventListener("pointerleave", this.onLeave);
    s.removeEventListener("click", this.onClick);
    s.removeEventListener("contextmenu", this.onContextMenu);
    this.ring.remove();
  }

  /** 工具换了：橡皮圈跟着显示 / 收起。 */
  toolChanged() {
    if (this.act.tool() !== "eraser") this.ring.style.display = "none";
  }

  private static onMark(e: Event) {
    return !!(e.target as Element | null)?.closest?.(".pv-pin-wrap, .pv-editor");
  }

  /** 这个指针这次该做什么：写、擦，还是不管（滚动、缩放、点图钉）。 */
  private intent(e: PointerEvent): "pen" | "eraser" | null {
    if (e.pointerType === "touch" || PageInput.onMark(e)) return null;
    if (e.pointerType === "pen" && (e.button === 5 || (e.buttons & 32) !== 0)) return "eraser";   // 手写笔的橡皮头
    if (e.pointerType === "mouse" && e.button !== 0) return null;
    const tool = this.act.tool();
    return tool === "pen" || tool === "eraser" ? tool : null;
  }

  private onDown = (e: PointerEvent) => {
    if (this.draft || this.rub) return;
    const intent = this.intent(e);
    if (!intent) return;
    const hit = this.host.locate(e.clientX, e.clientY);
    if (!hit) return;
    e.preventDefault();   // 鼠标不选中文字、不拖出图片
    this.scroller.setPointerCapture(e.pointerId);
    this.host.setInking(true);
    if (intent === "eraser") {
      this.rub = { pointerId: e.pointerId, last: null, gone: new Set() };
      this.act.eraseBegin();
      this.rubTo(hit);
      return;
    }
    this.draft = {
      pointerId: e.pointerId, page: hit.page, mouse: e.pointerType === "mouse", started: e.pointerType !== "mouse",
      downX: e.clientX, downY: e.clientY, pts: [], canvas: null, frame: 0,
    };
    this.addPoint(this.draft, hit.nx, hit.ny, e.pressure, false);
  };

  private onMove = (e: PointerEvent) => {
    this.moveRing(e);
    const d = this.draft;
    if (d && e.pointerId === d.pointerId) {
      if (!d.started) {
        if (Math.hypot(e.clientX - d.downX, e.clientY - d.downY) <= 2) return;
        d.started = true;
      }
      const evs = typeof e.getCoalescedEvents === "function" ? e.getCoalescedEvents() : [];
      for (const ev of evs.length ? evs : [e]) {
        const [nx, ny] = this.host.norm(d.page, ev.clientX, ev.clientY);
        if (ny < 0 || ny > 1) continue;   // 拖出这一页的上下边：不记点
        this.addPoint(d, Math.min(1, Math.max(0, nx)), ny, ev.pressure, e.shiftKey);
      }
      this.schedule(d);
      return;
    }
    const r = this.rub;
    if (r && e.pointerId === r.pointerId) {
      const evs = typeof e.getCoalescedEvents === "function" ? e.getCoalescedEvents() : [];
      for (const ev of evs.length ? evs : [e]) {
        const hit = this.host.locate(ev.clientX, ev.clientY);
        if (hit) this.rubTo(hit);
      }
    }
  };

  private onUp = (e: PointerEvent) => {
    const d = this.draft;
    if (d && e.pointerId === d.pointerId) {
      this.draft = null;
      this.host.setInking(false);
      cancelAnimationFrame(d.frame);
      // 鼠标单击（没拖动）不留点；指针被浏览器收走（pointercancel）时已写的照样留下
      if (d.started && d.pts.length) {
        const pen = this.act.pen();
        this.act.strokeDone(d.page, {
          id: uuid(), color: { ...pen.color }, width: pen.width, type: pen.type,
          layerId: this.act.layerId(), pts: Float32Array.from(d.pts), createdAt: "", updatedAt: "",
        });
      }
      d.canvas?.remove();   // 页上的笔迹已经重画好（含这一笔）才拿掉，不闪
      if (d.canvas) { d.canvas.width = 0; d.canvas.height = 0; }
      return;
    }
    const r = this.rub;
    if (r && e.pointerId === r.pointerId) {
      this.rub = null;
      this.host.setInking(false);
      this.act.eraseEnd();
    }
  };

  private onLeave = (e: PointerEvent) => {
    if (e.pointerType !== "touch" && !this.rub) this.ring.style.display = "none";
  };

  private onClick = (e: MouseEvent) => {
    if (this.act.tool() !== "note" || PageInput.onMark(e)) return;
    const hit = this.host.locate(e.clientX, e.clientY);
    if (hit) this.act.noteTap(hit.page, hit.nx, hit.ny);
  };

  private onContextMenu = (e: Event) => {
    if (this.draft || this.rub) e.preventDefault();   // 手写笔长按别弹菜单
  };

  // MARK: - 写

  private addPoint(d: Draft, nx: number, ny: number, pressure: number, ruler: boolean) {
    const z = pressure > 0 ? pressure : 0.5;
    if (ruler && d.pts.length >= 3) {
      // ⇧ 直线：整笔只留「起点 → 吸附后的终点」，鼠标恒 0.5（同 Mac）
      const { w, h } = this.host.pageSize(d.page);
      const [sx, sy] = rulerSnap(d.pts[0], d.pts[1], nx, ny, w > 0 ? h / w : 1);
      d.pts = [d.pts[0], d.pts[1], d.pts[2], sx, sy, d.mouse ? 0.5 : Math.max(d.pts[2], z)];
      return;
    }
    d.pts.push(nx, ny, d.mouse ? 0.5 : z);
  }

  private schedule(d: Draft) {
    if (d.frame) return;
    d.frame = requestAnimationFrame(() => {
      d.frame = 0;
      if (this.draft === d) this.paintLive(d);
    });
  }

  /** 正在写的这一笔：页上一块临时画布，每帧整笔重画一遍（画法同已存的笔迹）。 */
  private paintLive(d: Draft) {
    const div = this.host.pageDiv(d.page);
    const { w, h } = this.host.pageSize(d.page);
    let k = window.devicePixelRatio || 1;
    if (w * h * k * k > LIVE_MAX_PIXELS) k = Math.sqrt(LIVE_MAX_PIXELS / (w * h));
    const cw = Math.max(1, Math.round(w * k)), ch = Math.max(1, Math.round(h * k));
    let c = d.canvas;
    if (!c || !c.isConnected) {
      c = document.createElement("canvas");
      c.className = "pv-live";
      div.appendChild(c);
      d.canvas = c;
    }
    if (c.width !== cw || c.height !== ch) {
      c.width = cw;
      c.height = ch;
    }
    const ctx = c.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, cw, ch);
    const { fw, fh } = this.host.fitSize(d.page);
    const pen = this.act.pen();
    ctx.setTransform(cw / fw, 0, 0, ch / fh, 0, 0);
    drawPageInk(ctx, [{
      id: "", color: pen.color, width: pen.width, type: pen.type, layerId: "", pts: Float32Array.from(d.pts),
      createdAt: "", updatedAt: "",
    }], fw, fh, cw / fw);
  }

  private cancelDraft() {
    if (!this.draft) return;
    cancelAnimationFrame(this.draft.frame);
    this.draft.canvas?.remove();
    this.draft = null;
    this.host.setInking(false);
  }

  // MARK: - 擦

  /** 橡皮从上一个位置移到 [p]：沿途每隔半个半径量一次（快速划过时不漏），碰到的整笔擦掉。 */
  private rubTo(p: { page: number; nx: number; ny: number }) {
    const r = this.rub;
    if (!r) return;
    const from = r.last && r.last.page === p.page ? r.last : p;
    r.last = p;
    const steps = Math.max(1, Math.ceil(Math.hypot(p.nx - from.nx, p.ny - from.ny) / (ERASER_RADIUS / 2)));
    const r2 = ERASER_RADIUS * ERASER_RADIUS;
    const hits: Stroke[] = [];
    for (const s of this.act.visibleStrokes(p.page)) {
      if (r.gone.has(s.id)) continue;
      let hit = false;
      for (let k = 0; k <= steps && !hit; k++) {
        const ex = from.nx + ((p.nx - from.nx) * k) / steps, ey = from.ny + ((p.ny - from.ny) * k) / steps;
        for (let i = 0; i < s.pts.length; i += 3) {
          const dx = s.pts[i] - ex, dy = s.pts[i + 1] - ey;
          if (dx * dx + dy * dy <= r2) { hit = true; break; }
        }
      }
      if (hit) {
        r.gone.add(s.id);
        hits.push(s);
      }
    }
    if (hits.length) this.act.erase(p.page, hits);
  }

  private moveRing(e: PointerEvent) {
    if (e.pointerType === "touch") return;
    const erasing = this.act.tool() === "eraser" || (e.pointerType === "pen" && (e.buttons & 32) !== 0);
    const hit = erasing ? this.host.locate(e.clientX, e.clientY) : null;
    if (!hit) {
      this.ring.style.display = "none";
      return;
    }
    const d = 2 * ERASER_RADIUS * this.host.pageSize(hit.page).w;
    const s = this.ring.style;
    s.display = "block";
    s.width = s.height = `${d}px`;
    s.transform = `translate(${e.clientX - d / 2}px, ${e.clientY - d / 2}px)`;
  }
}
