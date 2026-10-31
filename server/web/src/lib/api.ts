// 服务器接口（路由表在 server/Sources/UniServerHTTP/ServerApp.swift 文件头）。
// 网页算一台设备：配对拿到的令牌存在这个浏览器的 localStorage，数据接口一律带 `Authorization: Bearer <令牌>`。

import { t } from "./i18n";
import type { InkLayer, MarkRow } from "./marks";

export interface Workspace { id: string; name: string; head: number }

export interface DocumentInfo {
  id: string;
  title: string;
  group: string;
  pageCount: number;
  /** 阅读进度：页从 0 起 + 页内比例（各设备经同步共用的那份） */
  readPage: number;
  readFrac: number;
  /** 打开用的那份 PDF；没有 = 服务器上还没有这本书的 PDF */
  contentHash?: string;
  pdfBytes?: number;
}

export class ApiError extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

const TOKEN_KEY = "unireader.token";
const SERVER_KEY = "unireader.serverName";

function read(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}

function write(key: string, value: string | null) {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch { /* 无痕模式等：只在这一页里有效 */ }
}

export const token = () => read(TOKEN_KEY);
export const serverName = () => read(SERVER_KEY) ?? "";

export function signOut() {
  write(TOKEN_KEY, null);
  write(SERVER_KEY, null);
}

let unauthorized: (() => void) | null = null;
/** 令牌失效（被吊销）时调：清掉令牌、回配对页。 */
export function onUnauthorized(f: () => void) { unauthorized = f; }

async function errorOf(r: Response): Promise<ApiError> {
  let message = "";
  try { message = (await r.json())?.error?.message ?? ""; } catch { /* 不是 JSON */ }
  return new ApiError(r.status, message || `HTTP ${r.status}`);
}

async function send(url: string, init: RequestInit): Promise<Response> {
  try { return await fetch(url, init); } catch { throw new ApiError(0, t("Cannot reach the server.")); }
}

/** 带令牌取一个地址（令牌失效时清掉令牌、回配对页）；不看状态码，由调用方看。 */
export async function authFetch(url: string, init: RequestInit = {}): Promise<Response> {
  const tk = token();
  const headers = new Headers(init.headers);
  if (tk) headers.set("Authorization", `Bearer ${tk}`);
  const r = await send(url, { ...init, headers });
  if (r.status === 401 && tk) {
    signOut();
    unauthorized?.();
  }
  return r;
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const r = await authFetch(`/v1/${path}`, init);
  if (!r.ok) throw await errorOf(r);
  return (await r.json()) as T;
}

export { errorOf };

/** 配对码换令牌（唯一不要令牌的接口）。成功后令牌存进本浏览器。 */
export async function pair(code: string, deviceName: string): Promise<void> {
  const r = await send("/v1/pair", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: code.trim().toUpperCase(), deviceName: deviceName.trim() }),
  });
  if (r.status === 401) throw new ApiError(401, t("Wrong pairing code."));
  if (r.status === 429) throw new ApiError(429, t("Too many wrong codes. Try again in a minute."));
  if (!r.ok) throw await errorOf(r);
  const p = (await r.json()) as { token: string; serverName: string };
  write(TOKEN_KEY, p.token);
  write(SERVER_KEY, p.serverName);
}

export const workspaces = () => api<{ workspaces: Workspace[] }>("workspaces").then((r) => r.workspaces);

export const documents = (ws: string) =>
  api<{ documents: DocumentInfo[] }>(`workspaces/${encodeURIComponent(ws)}/documents`).then((r) => r.documents);

export const pdfURL = (ws: string, hash: string) => `/v1/workspaces/${encodeURIComponent(ws)}/pdf/${hash}`;

/** 服务器出图（方案 §11）：各页尺寸（pt，已转正）+ 目录。服务器没装 MuPDF → 501。 */
export interface ServerOutline { title: string; page: number; y: number | null; children: ServerOutline[] }
/** [pages] 每页 `[宽 pt, 高 pt, 扫描图多少像素宽（0 = 不是扫描页）]`；老服务器只给前两个。 */
export interface PageInfo { pages: number[][]; outline: ServerOutline[] }

// `v=2`：内容加了扫描图宽度。浏览器把这个地址长期缓存，内容格式变了要换地址，不然拿到的是缓存里的旧格式
export const pageInfo = (ws: string, hash: string) => api<PageInfo>(`workspaces/${encodeURIComponent(ws)}/pdf/${hash}/info?v=2`);

/** 第 [page] 页（从 0 起）[width] 像素宽的图。 */
export const pageImageURL = (ws: string, hash: string, page: number, width: number) =>
  `${pdfURL(ws, hash)}/page/${page}?w=${width}`;

/** 打开一本书要的几样：图层、笔记类型（JSON 文本）、扫描页对齐参数（JSON 文本，没开就没有）。 */
export interface DocumentView { layers: InkLayer[]; noteTypes?: string; align?: string }

const book = (ws: string, doc: string) => `workspaces/${encodeURIComponent(ws)}/documents/${encodeURIComponent(doc)}`;

export const documentView = (ws: string, doc: string, hash?: string) =>
  api<DocumentView>(`${book(ws, doc)}/view${hash ? `?hash=${hash}` : ""}`);

/** 页 [from]…[to]（从 0 起，含两端）上的文字笔记 / 笔迹 / 高亮。 */
export const pageMarks = (ws: string, doc: string, from: number, to: number) =>
  api<{ marks: MarkRow[] }>(`${book(ws, doc)}/marks?from=${from}&to=${to}`).then((r) => r.marks);

export interface EditUpsert {
  id: string; kind: 0 | 2; page: number; anchor: number[]; payload: string;
  /** 笔迹点集的二进制（base64）；文字笔记不带 */
  points?: string;
  /** 看到的服务器上这一行的更新时间（新建不带）：服务器上已经变了就不写 */
  baseUpdatedAt?: string;
  /** 行不在服务器上时用的创建时间（撤销删除时恢复原来的叠放顺序） */
  createdAt?: string;
}
export interface EditDelete { id: string; baseUpdatedAt?: string }
export type EditOutcome = "applied" | "stale" | "rejected";

/** 写一批文字笔记 / 笔迹（方案 §3：服务器当成一次推送）。 */
export const postEdits = (ws: string, doc: string, upserts: EditUpsert[], deletes: EditDelete[]) =>
  api<{ head: number; updatedAt: string; results: { id: string; outcome: EditOutcome }[] }>(`${book(ws, doc)}/edits`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ upserts, deletes }),
  });

/** 整本书的文字笔记（阅读页的「笔记」列表；格式同 [pageMarks]，只有文字笔记）。 */
export const bookNotes = (ws: string, doc: string) =>
  api<{ marks: MarkRow[] }>(`${book(ws, doc)}/notes`).then((r) => r.marks);

/** 工作区当前的修订号：别的设备改了什么，它就变。 */
export const head = (ws: string) => api<{ head: number }>(`workspaces/${encodeURIComponent(ws)}/head`).then((r) => r.head);

export function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
