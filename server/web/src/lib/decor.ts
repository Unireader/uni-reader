// 页上的标记怎么摆（方案 §1 第 3 条）：
// - 高亮 / 文字笔记的选区：网页元素（位置用页的百分比，缩放时跟着页走，不用重画）。
//   三种画法照 Mac `PageMarksLayer`：铺色（外扩 1pt × 0.5pt、圆角 2pt）、画线（行框底下，粗 max(1.5pt, 行高 × 7%)）、
//   画框（外扩 1.5pt × 1pt、线宽 1.5pt）。这些「屏幕上固定几点」的量在网页里就是 CSS 像素。
// - 笔迹：每页一块画布（只有这页有可见笔迹时才有），和页面图同样的像素、同时换上。
// - 文字笔记的图钉：直径 18 像素，位置规则同 Mac `ReaderView.notePinCenter`；点它看正文。
// - W3：气泡里能编辑、删除（删除点两次才算）；新建 / 编辑用页上的一个编辑框（`openEditor`）。
// - 正文按 Markdown + 公式排版（`markdown.ts`，第一次用到时才加载；到之前先显示纯文字）。

import { t } from "./i18n";
import { drawPageInk } from "./ink";
import {
  css, MARK_COLORS, noteMarkColor, pinColor, visibleStrokes,
  type Color, type InkLayer, type MarkStyle, type NoteType, type PageMarks, type TextNote,
} from "./marks";

/** 文字笔记的编辑 / 删除交给谁（W3）；没有 = 只读。 */
export interface NoteActions {
  edit(page: number, note: TextNote): void;
  remove(page: number, note: TextNote): void;
}

export class Decor {
  layers: InkLayer[] = [];
  types: NoteType[] = [];
  actions: NoteActions | null = null;
  /** 展开着的笔记气泡（点开的；「始终展开」的笔记被点收起后记在 [closed]）。 */
  private open = new Set<string>();
  private closed = new Set<string>();
  /** 正在编辑的笔记（它的气泡先收起来）与编辑框 */
  private editingId: string | null = null;
  private editor: { el: HTMLElement; cancel: () => void } | null = null;

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

  /** 在页 [div]（第 [page] 页）里摆上高亮与图钉（再调 = 按新数据重摆）。 */
  attach(div: HTMLDivElement, marks: PageMarks | undefined, page: number) {
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
    for (const n of marks.notes) pins.appendChild(this.pin(n, page));
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

  /** 下次摆这条笔记时气泡开着（刚新建 / 刚改完）。 */
  markOpen(id: string) {
    this.open.add(id);
    this.closed.delete(id);
  }

  /**
   * 页上的编辑框：新建（[note] 为 null，放在 ([nx], [ny])）或编辑一条笔记（放在它的图钉处，气泡先收起）。
   * 同一时刻只有一个，再开一个 = 先取消前一个。⌘ / Ctrl + 回车保存，Esc 取消。
   */
  openEditor(div: HTMLDivElement, note: TextNote | null, nx: number, ny: number,
             onSave: (text: string) => void, onClose: () => void) {
    this.editor?.cancel();
    const box = el("div", "pv-editor");
    const [x, y, left] = note ? pinPos(note) : [pct(nx), pct(ny), nx > 0.6];
    box.style.left = `clamp(12px, ${x}, calc(100% - 12px))`;
    box.style.top = `clamp(10px, ${y}, calc(100% - 10px))`;
    if (left) box.classList.add("left");
    const area = el("textarea", "") as HTMLTextAreaElement;
    area.value = note?.text ?? "";
    area.placeholder = t("Text Note");
    area.rows = 4;
    const row = el("div", "pv-editor-actions");
    const cancel = button(t("Cancel"), "");
    const save = button(t("Save"), "primary");
    row.append(cancel, save);
    box.append(area, row);
    box.addEventListener("click", (e) => e.stopPropagation());
    box.addEventListener("pointerdown", (e) => e.stopPropagation());

    const close = () => {
      if (this.editor?.el !== box) return;
      this.editor = null;
      this.editingId = null;
      box.remove();
      div.querySelector(`.pv-pin-wrap[data-id="${note?.id ?? ""}"]`)?.classList.remove("editing");
      onClose();
    };
    cancel.addEventListener("click", close);
    save.addEventListener("click", () => {
      const text = area.value;
      close();
      onSave(text);
    });
    area.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close();
      } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        save.click();
      }
    });
    this.editor = { el: box, cancel: close };
    this.editingId = note?.id ?? null;
    div.querySelector<HTMLElement>(`.pv-pin-wrap[data-id="${note?.id ?? ""}"]`)?.classList.add("editing");
    div.appendChild(box);
    area.focus({ preventScroll: true });
  }

  private isOpen(n: TextNote) {
    return n.display === "always" ? !this.closed.has(n.id) : this.open.has(n.id);
  }

  private pin(n: TextNote, page: number): HTMLElement {
    const [x, y, left] = pinPos(n);
    const wrap = el("div", "pv-pin-wrap");
    wrap.dataset.id = n.id;
    wrap.style.left = `clamp(12px, ${x}, calc(100% - 12px))`;
    wrap.style.top = `clamp(10px, ${y}, calc(100% - 10px))`;
    if (left) wrap.classList.add("left");
    if (n.display === "always") wrap.classList.add("always");
    if (this.isOpen(n)) wrap.classList.add("open");
    if (this.editingId === n.id) wrap.classList.add("editing");

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

    // 正文按 Markdown 排版；没写正文的显示原文（纯文字）
    const bubble = el("div", "pv-bubble");
    const body = el("div", "pv-bubble-text");
    if (n.text) fillMarkdown(body, n.text);
    else {
      body.textContent = n.quote;
      body.classList.add("quote");
    }
    bubble.appendChild(body);
    const actions = this.actions;
    if (actions) {
      const row = el("div", "pv-bubble-actions");
      const edit = button(t("Edit"), "");
      edit.addEventListener("click", () => actions.edit(page, n));
      // 删除要点两次：第一次变成「确认删除」，3 秒内再点才删
      const del = button(t("Delete"), "danger");
      let armed = 0;
      del.addEventListener("click", () => {
        if (armed) {
          clearTimeout(armed);
          actions.remove(page, n);
          return;
        }
        del.textContent = t("Confirm Delete");
        del.classList.add("armed");
        armed = window.setTimeout(() => {
          armed = 0;
          del.textContent = t("Delete");
          del.classList.remove("armed");
        }, 3000);
      });
      row.append(edit, del);
      bubble.appendChild(row);
    }
    bubble.addEventListener("click", (e) => e.stopPropagation());
    wrap.appendChild(bubble);
    return wrap;
  }
}

/** 图钉中心（CSS 的 left / top）与气泡是否往左开：选区笔记在选区右上角外侧，点笔记在锚点处（同 Mac，单位是屏幕点）。 */
function pinPos(n: TextNote): [string, string, boolean] {
  const [ax, ay, aw] = n.anchor;
  const hasRects = n.rects.length > 0;
  const x = hasRects ? `calc(${pct(ax + aw)} + 9px)` : pct(ax);
  const y = hasRects ? `calc(${pct(ay)} + 7px)` : pct(ay);
  // 图钉在页的右侧四成里时，气泡往左开
  return [x, y, (hasRects ? ax + aw : ax) > 0.6];
}

// MARK: - 正文排版（按需加载）

let render: ((text: string) => string) | null = null;
let loading: Promise<void> | null = null;
const waiting = new Map<HTMLElement, string>();
const rendered = new Map<string, string>();   // 同一段正文只排一次（缩放、刷新时气泡会重建）

function markdown(text: string): string {
  let html = rendered.get(text);
  if (html === undefined) {
    html = render!(text);
    if (rendered.size > 500) rendered.clear();
    rendered.set(text, html);
  }
  return html;
}

function fillMarkdown(el: HTMLElement, text: string) {
  if (render) {
    el.innerHTML = markdown(text);
    el.classList.add("md");
    return;
  }
  el.textContent = text;
  waiting.set(el, text);
  loading ??= Promise.all([import("./markdown"), import("katex/dist/katex.min.css")]).then(([m]) => {
    render = m.renderNote;
    for (const [e, t] of waiting) {
      if (!e.isConnected) continue;
      e.innerHTML = markdown(t);
      e.classList.add("md");
    }
    waiting.clear();
  }).catch((e) => {
    console.warn("排版模块没加载上，正文按纯文字显示", e);
    loading = null;
  });
}

function button(label: string, cls: string): HTMLButtonElement {
  const b = el("button", cls) as HTMLButtonElement;
  b.type = "button";
  b.textContent = label;
  return b;
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
