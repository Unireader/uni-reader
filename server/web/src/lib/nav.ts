// 页面内导航：`#/`（工作区）→ `#/w/<工作区>`（书目）→ `#/w/<工作区>/d/<书>`（阅读）。
// 只用 `#` 后面的部分，服务器只认 `/` 一个页面（server/Sources/UniServerHTTP/WebFiles.swift）。

export function parseHash(hash = location.hash): string[] {
  return hash.replace(/^#\/?/, "").split("/").filter(Boolean).map(decodeURIComponent);
}

export function go(...parts: string[]) {
  location.hash = "#/" + parts.map(encodeURIComponent).join("/");
}
