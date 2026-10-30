// 网页写笔迹 / 文字笔记（方案 §1 第 4、5 条，W3）：
// - 每处改动马上显示（记进 `MarkStore` 叠在服务器数据上），再按顺序一批批发给服务器（同一行以最后一次为准）；
// - 连不上就隔一会儿再发，攒着的不丢；服务器说「别的设备改过了」的那处撤掉、重新取；
// - 撤销 / 重做只管这次打开期间自己做的（方案 §1 第 4 条），撤销 = 把反向的改动再发一次。

import { ApiError, postEdits, type EditDelete, type EditUpsert } from "./api";
import { bytesBase64, encodePoints, pointsBounds } from "./inkmath";
import { notePayload, strokePayload, type Stroke, type TextNote } from "./marks";
import type { LocalOp, MarkStore } from "./markstore";

/** 一处改动：[item] 为 null = 删掉。 */
interface Change { id: string; page: number; kind: "stroke" | "note"; item: Stroke | TextNote | null }

interface Entry { redo: Change[]; undo: Change[] }

export interface SaveState {
  /** 还没存上的改动数 */
  pending: number;
  /** 连不上服务器（正在等着重试） */
  offline: boolean;
}

const MAX_UNDO = 200;
const RETRY_MAX_MS = 30_000;

export class EditSession {
  private queue: LocalOp[] = [];
  private sending: LocalOp[] = [];
  private retryTimer = 0;
  private retryDelay = 0;
  private offline = false;
  private undoStack: Entry[] = [];
  private redoStack: Entry[] = [];
  private group: Entry | null = null;
  private closed = false;
  /** 阅读页已经关了：不再回调界面，没存上的接着发完 */
  private detached = false;

  constructor(
    private ws: string,
    private doc: string,
    private store: MarkStore,
    /** 这几页因为网页自己的改动要重画；[added] = 这次只是加了一笔（能直接补画就不整页重画） */
    private repaint: (pages: number[], added?: { page: number; stroke: Stroke }) => void,
    private onState: (s: SaveState) => void,
    /** 有改动没写上（别的设备改过 / 服务器不收）：[message] 给用户看 */
    private onProblem: (message: "stale" | "rejected") => void,
    private post: typeof postEdits = postEdits,
  ) {}

  /** 阅读页关了：还有没存上的就在后台接着发完（不再回调界面），没有就停。 */
  close() {
    this.detached = true;
    if (this.pending) return;
    this.closed = true;
    clearTimeout(this.retryTimer);
  }

  get canUndo() { return this.undoStack.length > 0; }
  get canRedo() { return this.redoStack.length > 0; }
  get pending() { return this.queue.length + this.sending.length; }

  // MARK: - 动作

  addStroke(page: number, stroke: Stroke) {
    const c: Change = { id: stroke.id, page, kind: "stroke", item: stroke };
    this.record({ redo: [c], undo: [{ ...c, item: null }] });
    this.apply([c], { page, stroke });
  }

  eraseStrokes(page: number, strokes: Stroke[]) {
    if (!strokes.length) return;
    const redo = strokes.map((s): Change => ({ id: s.id, page, kind: "stroke", item: null }));
    this.record({ redo, undo: strokes.map((s) => ({ id: s.id, page, kind: "stroke", item: s })) });
    this.apply(redo);
  }

  /** 新建（[before] 为 null）或改一条文字笔记。 */
  saveNote(page: number, before: TextNote | null, after: TextNote) {
    const c: Change = { id: after.id, page, kind: "note", item: after };
    this.record({ redo: [c], undo: [{ ...c, item: before }] });
    this.apply([c]);
  }

  deleteNote(page: number, note: TextNote) {
    const c: Change = { id: note.id, page, kind: "note", item: null };
    this.record({ redo: [c], undo: [{ ...c, item: note }] });
    this.apply([c]);
  }

  /** 一次拖动（擦除）里的多批改动合成撤销的一步：[beginGroup] 与 [endGroup] 之间记的都并进去。 */
  beginGroup() { this.group = { redo: [], undo: [] }; }

  endGroup() {
    const g = this.group;
    this.group = null;
    if (g?.redo.length) this.record(g);
  }

  undo() {
    const e = this.undoStack.pop();
    if (!e) return;
    this.redoStack.push(e);
    this.apply(e.undo);
  }

  redo() {
    const e = this.redoStack.pop();
    if (!e) return;
    this.undoStack.push(e);
    this.apply(e.redo);
  }

  // MARK: - 内部

  private record(e: Entry) {
    if (this.group && e !== this.group) {
      this.group.redo.push(...e.redo);
      this.group.undo.unshift(...e.undo);   // 撤销时后做的先撤
      return;
    }
    this.undoStack.push(e);
    if (this.undoStack.length > MAX_UNDO) this.undoStack.shift();
    this.redoStack = [];
  }

  private apply(changes: Change[], added?: { page: number; stroke: Stroke }) {
    const pages = new Set<number>();
    for (const c of changes) {
      const op: LocalOp = { ...c, ackedAt: 0 };
      this.store.local(op);
      // 还没发出去的同一行：以这次为准
      const k = this.queue.findIndex((q) => q.id === c.id);
      if (k >= 0) this.queue.splice(k, 1);
      this.queue.push(op);
      pages.add(c.page);
    }
    if (!this.detached) this.repaint([...pages], changes.length === 1 ? added : undefined);
    this.report();
    this.flush();
  }

  private report() {
    if (this.detached) {
      if (!this.pending) this.closed = true;
      return;
    }
    this.onState({ pending: this.pending, offline: this.offline });
  }

  private flush() {
    if (this.closed || this.sending.length || !this.queue.length || this.retryTimer) return;
    const batch = this.queue.splice(0);
    this.sending = batch;
    void this.send(batch);
  }

  private async send(batch: LocalOp[]) {
    const upserts: EditUpsert[] = [], deletes: EditDelete[] = [];
    for (const op of batch) {
      const base = this.store.serverStamp.get(op.id) ?? undefined;
      if (!op.item) {
        deletes.push({ id: op.id, baseUpdatedAt: base });
      } else if (op.kind === "stroke") {
        const s = op.item as Stroke;
        upserts.push({
          id: s.id, kind: 2, page: op.page, anchor: pointsBounds(s.pts), payload: strokePayload(s),
          points: bytesBase64(encodePoints(s.pts)), baseUpdatedAt: base, createdAt: s.createdAt || undefined,
        });
      } else {
        const n = op.item as TextNote;
        upserts.push({
          id: n.id, kind: 0, page: op.page, anchor: n.anchor, payload: notePayload(n),
          baseUpdatedAt: base, createdAt: n.createdAt || undefined,
        });
      }
    }
    try {
      const r = await this.post(this.ws, this.doc, upserts, deletes);
      const outcome = new Map(r.results.map((x) => [x.id, x.outcome]));
      let problem: "stale" | "rejected" | null = null;
      for (const op of batch) {
        const o = outcome.get(op.id) ?? "rejected";
        if (o === "applied") {
          this.store.acked(op, r.updatedAt);
        } else {
          this.store.dropped(op);
          problem ??= o;
        }
      }
      this.offline = false;
      this.retryDelay = 0;
      this.sending = [];
      if (problem && !this.detached) {
        this.onProblem(problem);
        this.store.refresh();
      }
    } catch (e) {
      this.sending = [];
      if (e instanceof ApiError && e.status >= 400 && e.status < 500) {
        // 请求本身不对（不会因为重试变好）：这批作废，回到服务器的样子
        for (const op of batch) this.store.dropped(op);
        if (!this.detached) {
          this.onProblem("rejected");
          this.store.refresh();
        }
      } else {
        // 连不上 / 服务器出错：放回队首（之后又改过的同一行以新的为准），过一会儿再发
        const later = new Set(this.queue.map((q) => q.id));
        this.queue.unshift(...batch.filter((op) => !later.has(op.id)));
        this.offline = true;
        this.retryDelay = Math.min(RETRY_MAX_MS, this.retryDelay ? this.retryDelay * 2 : 2000);
        this.retryTimer = setTimeout(() => {
          this.retryTimer = 0;
          this.flush();
        }, this.retryDelay);
      }
    }
    this.report();
    this.flush();
  }
}
