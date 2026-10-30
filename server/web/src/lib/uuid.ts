/**
 * 新行的 id：大写 UUID（同 Mac `UUID().uuidString`）。
 * 不用 `crypto.randomUUID()`：它只在 HTTPS / 本机地址下有，用局域网明文地址打开时没有；`getRandomValues` 哪儿都有。
 */
export function uuid(): string {
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40;   // 版本 4
  b[8] = (b[8] & 0x3f) | 0x80;   // RFC 4122 变体
  const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("").toUpperCase();
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
