// 每本书在这个浏览器里读到哪儿（页从 0 起 + 页内比例 + 缩放）。没有就用服务器上的阅读进度。
// 第一版只记在本浏览器，不写回服务器（写入接口在 W3）。

export interface Position { page: number; frac: number; zoom: number }

const key = (ws: string, doc: string) => `unireader.pos.${ws}.${doc}`;

export function loadPosition(ws: string, doc: string): Position | null {
  try {
    const p = JSON.parse(localStorage.getItem(key(ws, doc)) ?? "null");
    if (p && Number.isFinite(p.page) && Number.isFinite(p.frac) && Number.isFinite(p.zoom)) return p as Position;
  } catch { /* 没有或坏了 */ }
  return null;
}

export function savePosition(ws: string, doc: string, p: Position) {
  try { localStorage.setItem(key(ws, doc), JSON.stringify(p)); } catch { /* 存不下就算了 */ }
}
