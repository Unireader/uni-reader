// 页面标记的缓存：按块（8 页）向服务器取，只留视口附近的；工作区修订号变了就重取看得见的那几块，
// 只把内容真变了的页报出去重画（没变的页不动，不闪）。

import { pageMarks } from "./api";
import { parseMarks, type PageMarks } from "./marks";

const BLOCK = 8;
const KEEP_BLOCKS = 6;   // 视口所在块之外，前后各留几块

export const NO_MARKS: PageMarks = { strokes: [], highlights: [], notes: [], sig: "" };

export class MarkStore {
  private blocks = new Map<number, Map<number, PageMarks>>();
  private loading = new Map<number, number>();   // 块 → 那次取的代号
  private gen = 0;
  private lo = 0;
  private hi = -1;
  private destroyed = false;

  constructor(
    private ws: string,
    private doc: string,
    private count: number,
    /** 这几页的标记到了 / 变了 */
    private onPages: (pages: number[]) => void,
  ) {}

  destroy() { this.destroyed = true; }

  /** 页 [i] 的标记；还没取到 = undefined。 */
  page(i: number): PageMarks | undefined {
    return this.blocks.get(Math.floor(i / BLOCK))?.get(i) ?? (this.blocks.has(Math.floor(i / BLOCK)) ? NO_MARKS : undefined);
  }

  /** 视口附近是页 [lo]…[hi]：缺的块去取，离得远的扔掉。 */
  want(lo: number, hi: number) {
    this.lo = Math.max(0, lo);
    this.hi = Math.min(this.count - 1, hi);
    const b0 = Math.floor(this.lo / BLOCK), b1 = Math.floor(this.hi / BLOCK);
    for (const b of [...this.blocks.keys()]) if (b < b0 - KEEP_BLOCKS || b > b1 + KEEP_BLOCKS) this.blocks.delete(b);
    for (let b = b0; b <= b1; b++) if (!this.blocks.has(b) && !this.loading.has(b)) void this.load(b);
  }

  /** 别的设备改过了：视口附近的块重取，其余的扔掉（再看到时现取）。 */
  refresh() {
    this.gen++;
    this.loading.clear();
    const b0 = Math.floor(this.lo / BLOCK), b1 = Math.floor(this.hi / BLOCK);
    for (const b of [...this.blocks.keys()]) if (b < b0 || b > b1) this.blocks.delete(b);
    for (let b = b0; b <= b1; b++) void this.load(b);
  }

  private async load(b: number) {
    const gen = this.gen;
    this.loading.set(b, gen);
    const from = b * BLOCK, to = Math.min(this.count - 1, from + BLOCK - 1);
    let fresh: Map<number, PageMarks>;
    try {
      fresh = parseMarks(await pageMarks(this.ws, this.doc, from, to));
    } catch (e) {
      console.warn(`第 ${from + 1}~${to + 1} 页的标记没取到`, e);
      if (this.loading.get(b) === gen) this.loading.delete(b);
      return;
    }
    if (this.destroyed || this.loading.get(b) !== gen) return;
    this.loading.delete(b);
    const old = this.blocks.get(b);
    this.blocks.set(b, fresh);
    const changed: number[] = [];
    for (let i = from; i <= to; i++) {
      if (!old || (old.get(i)?.sig ?? "") !== (fresh.get(i)?.sig ?? "")) changed.push(i);
    }
    if (changed.length) this.onPages(changed);
  }
}
