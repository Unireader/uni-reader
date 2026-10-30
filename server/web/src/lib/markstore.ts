// 页面标记的缓存：按块（8 页）向服务器取，只留视口附近的；工作区修订号变了就重取看得见的那几块，
// 只把内容真变了的页报出去重画（没变的页不动，不闪）。
//
// 网页自己的改动（W3，`edits.ts`）先记在这里，叠在服务器的数据上显示，不等存上：
// - 还没存上的改动一直叠着；
// - 存上了的，要等「存上之后才发出的那次拉取」回来才撤掉（之前发出的拉取里还没有它，撤早了那一笔会闪没）。
// 「服务器上这一行现在的更新时间」也记在这里（[serverStamp]），改 / 删时带给服务器核对。

import { pageMarks } from "./api";
import { pageSig, parseMarks, type MarkRow, type PageMarks, type Stroke, type TextNote } from "./marks";

const BLOCK = 8;
const KEEP_BLOCKS = 6;   // 视口所在块之外，前后各留几块

export const NO_MARKS: PageMarks = { strokes: [], highlights: [], notes: [], sig: pageSig({ strokes: [], highlights: [], notes: [] }) };

/** 网页自己的一处改动：[item] 为 null = 删掉。 */
export interface LocalOp {
  id: string;
  page: number;
  kind: "stroke" | "note";
  item: Stroke | TextNote | null;
  /** 存上的时刻（本缓存自己的计数）；0 = 还没存上。 */
  ackedAt: number;
}

interface Block { pages: Map<number, PageMarks>; startedAt: number }

export class MarkStore {
  private blocks = new Map<number, Block>();
  private loading = new Map<number, number>();   // 块 → 那次取的代号
  private gen = 0;
  private clock = 0;
  private lo = 0;
  private hi = -1;
  private destroyed = false;
  private ops = new Map<string, LocalOp>();
  private merged = new Map<number, PageMarks>();
  /** 服务器上这一行的更新时间：null = 服务器上没有（删掉了 / 从没存过）；不在表里 = 不知道。 */
  readonly serverStamp = new Map<string, string | null>();

  constructor(
    private ws: string,
    private doc: string,
    private count: number,
    /** 这几页的标记到了 / 变了（服务器那边的变化；网页自己的改动由调用方自己重画） */
    private onPages: (pages: number[]) => void,
    private fetchRows: (ws: string, doc: string, from: number, to: number) => Promise<MarkRow[]> = pageMarks,
  ) {}

  destroy() { this.destroyed = true; }

  /** 页 [i] 的标记（服务器的 + 网页自己的改动）；还没取到 = undefined。 */
  page(i: number): PageMarks | undefined {
    const b = this.blocks.get(Math.floor(i / BLOCK));
    if (!b) return undefined;
    let m = this.merged.get(i);
    if (!m) {
      m = this.merge(i, b);
      this.merged.set(i, m);
    }
    return m;
  }

  /** 视口附近是页 [lo]…[hi]：缺的块去取，离得远的扔掉。 */
  want(lo: number, hi: number) {
    this.lo = Math.max(0, lo);
    this.hi = Math.min(this.count - 1, hi);
    const b0 = Math.floor(this.lo / BLOCK), b1 = Math.floor(this.hi / BLOCK);
    for (const b of [...this.blocks.keys()]) {
      if (b < b0 - KEEP_BLOCKS || b > b1 + KEEP_BLOCKS) this.dropBlock(b);
    }
    for (let b = b0; b <= b1; b++) if (!this.blocks.has(b) && !this.loading.has(b)) void this.load(b);
  }

  /** 别的设备改过了：视口附近的块重取，其余的扔掉（再看到时现取）。 */
  refresh() {
    this.gen++;
    this.loading.clear();
    const b0 = Math.floor(this.lo / BLOCK), b1 = Math.floor(this.hi / BLOCK);
    for (const b of [...this.blocks.keys()]) if (b < b0 || b > b1) this.dropBlock(b);
    for (let b = b0; b <= b1; b++) void this.load(b);
  }

  // MARK: - 网页自己的改动

  /** 记下一处改动（同一行以最后一次为准）。调用方自己重画那一页。 */
  local(op: LocalOp) {
    this.ops.set(op.id, op);
    this.merged.delete(op.page);
  }

  /** 这一处存上了：服务器给的更新时间记到那一行上。 */
  acked(op: LocalOp, stamp: string) {
    if (op.item) {
      op.item.updatedAt = stamp;
      if (!op.item.createdAt) op.item.createdAt = stamp;
    }
    this.serverStamp.set(op.id, op.item ? stamp : null);
    if (this.ops.get(op.id) === op) {
      op.ackedAt = ++this.clock;
      this.merged.delete(op.page);
    }
  }

  /** 这一处没写上（别的设备改过 / 服务器不让写）：撤掉，那一页回到服务器的样子。 */
  dropped(op: LocalOp) {
    if (this.ops.get(op.id) !== op) return;
    this.ops.delete(op.id);
    this.merged.delete(op.page);
    this.onPages([op.page]);
  }

  // MARK: - 内部

  private dropBlock(b: number) {
    this.blocks.delete(b);
    for (let i = b * BLOCK; i < (b + 1) * BLOCK; i++) this.merged.delete(i);
  }

  /** 叠上网页自己的改动：还没存上的，或存上时这块的数据已经在路上了（里面还没有它）。 */
  private merge(i: number, b: Block): PageMarks {
    const base = b.pages.get(i) ?? NO_MARKS;
    let strokes: Stroke[] | null = null, notes: TextNote[] | null = null;
    for (const op of this.ops.values()) {
      if (op.page !== i || (op.ackedAt && op.ackedAt <= b.startedAt)) continue;
      let list: (Stroke | TextNote)[];
      if (op.kind === "stroke") list = strokes ??= [...base.strokes];
      else list = notes ??= [...base.notes];
      const k = list.findIndex((x) => x.id === op.id);
      if (op.item) {
        if (k >= 0) list[k] = op.item;
        else list.push(op.item);
      } else if (k >= 0) {
        list.splice(k, 1);
      }
    }
    if (!strokes && !notes) return base;
    const m = { strokes: strokes ?? base.strokes, highlights: base.highlights, notes: notes ?? base.notes, sig: "" };
    m.sig = pageSig(m);
    return m;
  }

  private async load(b: number) {
    const gen = this.gen;
    this.loading.set(b, gen);
    const startedAt = this.clock;
    const from = b * BLOCK, to = Math.min(this.count - 1, from + BLOCK - 1);
    let fresh: Map<number, PageMarks>;
    try {
      fresh = parseMarks(await this.fetchRows(this.ws, this.doc, from, to));
    } catch (e) {
      console.warn(`第 ${from + 1}~${to + 1} 页的标记没取到`, e);
      if (this.loading.get(b) === gen) this.loading.delete(b);
      return;
    }
    if (this.destroyed || this.loading.get(b) !== gen) return;
    this.loading.delete(b);
    const had = this.blocks.has(b);
    const before = new Map<number, string>();
    if (had) for (let i = from; i <= to; i++) before.set(i, this.page(i)?.sig ?? "");
    this.blocks.set(b, { pages: fresh, startedAt });
    // 这块里已经包含了的改动不用再叠；服务器上的更新时间以这次取到的为准（网页还有更新的改动的行除外）
    const newer = new Set<string>();
    for (const op of [...this.ops.values()]) {
      if (op.page < from || op.page > to) continue;
      if (op.ackedAt && op.ackedAt <= startedAt) this.ops.delete(op.id);
      else newer.add(op.id);
    }
    for (const m of fresh.values()) {
      for (const x of [...m.strokes, ...m.notes]) if (!newer.has(x.id)) this.serverStamp.set(x.id, x.updatedAt);
    }
    const changed: number[] = [];
    for (let i = from; i <= to; i++) {
      this.merged.delete(i);
      if (!had || before.get(i) !== this.page(i)!.sig) changed.push(i);
    }
    if (changed.length) this.onPages(changed);
  }
}
