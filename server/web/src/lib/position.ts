// 每本书在这个浏览器里读到哪儿（页从 0 起 + 页内比例 + 缩放 + 什么时候）。没有就用服务器上的阅读进度。
// 书库页的「继续阅读」按 [at] 排（只看这个浏览器读过的）。

export interface Position { page: number; frac: number; zoom: number; at?: number }

const prefix = (ws: string) => `unireader.pos.${ws}.`;
const key = (ws: string, doc: string) => prefix(ws) + doc;

function valid(p: unknown): p is Position {
  const o = p as Position | null;
  return !!o && Number.isFinite(o.page) && Number.isFinite(o.frac) && Number.isFinite(o.zoom);
}

export function loadPosition(ws: string, doc: string): Position | null {
  try {
    const p = JSON.parse(localStorage.getItem(key(ws, doc)) ?? "null");
    if (valid(p)) return p;
  } catch { /* 没有或坏了 */ }
  return null;
}

export function savePosition(ws: string, doc: string, p: Position) {
  try { localStorage.setItem(key(ws, doc), JSON.stringify({ ...p, at: Date.now() })); } catch { /* 存不下就算了 */ }
}

/** 这个工作区里在本浏览器读过的书：书 id → 位置（含时间）。 */
export function positionsIn(ws: string): Map<string, Position> {
  const out = new Map<string, Position>();
  try {
    const pre = prefix(ws);
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (!k?.startsWith(pre)) continue;
      const p = JSON.parse(localStorage.getItem(k) ?? "null");
      if (valid(p)) out.set(k.slice(pre.length), p);
    }
  } catch { /* 读不了就当没有 */ }
  return out;
}
