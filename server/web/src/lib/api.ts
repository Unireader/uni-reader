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

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const tk = token();
  const headers = new Headers(init.headers);
  if (tk) headers.set("Authorization", `Bearer ${tk}`);
  const r = await send(`/v1/${path}`, { ...init, headers });
  if (r.status === 401 && tk) {
    signOut();
    unauthorized?.();
  }
  if (!r.ok) throw await errorOf(r);
  return (await r.json()) as T;
}

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

/** 打开一本书要的几样：图层、笔记类型（JSON 文本）、扫描页对齐参数（JSON 文本，没开就没有）。 */
export interface DocumentView { layers: InkLayer[]; noteTypes?: string; align?: string }

const book = (ws: string, doc: string) => `workspaces/${encodeURIComponent(ws)}/documents/${encodeURIComponent(doc)}`;

export const documentView = (ws: string, doc: string, hash?: string) =>
  api<DocumentView>(`${book(ws, doc)}/view${hash ? `?hash=${hash}` : ""}`);

/** 页 [from]…[to]（从 0 起，含两端）上的文字笔记 / 笔迹 / 高亮。 */
export const pageMarks = (ws: string, doc: string, from: number, to: number) =>
  api<{ marks: MarkRow[] }>(`${book(ws, doc)}/marks?from=${from}&to=${to}`).then((r) => r.marks);

/** 工作区当前的修订号：别的设备改了什么，它就变。 */
export const head = (ws: string) => api<{ head: number }>(`workspaces/${encodeURIComponent(ws)}/head`).then((r) => r.head);

export function message(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
