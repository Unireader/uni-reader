// 文字笔记正文的排版：Markdown + 公式（同 Mac 笔记气泡）。这个模块连同 markdown-it / KaTeX 单独打包，
// 第一次要显示笔记正文时才加载（`decor.ts`，KaTeX 的样式表也在那里一起加载），不拖慢打开书。
//
// - 不认原样 HTML（`html: false`）：正文里写的 HTML 当文字显示，不会执行；链接只认 http(s) 等安全的地址（markdown-it 自带的检查）。
// - 单个换行就换行（`breaks`）：笔记是在输入框里一行行写的，照写的样子显示。
// - 公式写法同 Mac（见 MCP 说明）：`$…$` 行内、写在一行里；`$$…$$` 单独成行（可以跨几行）。`\(…\)` / `\[…\]` 不认。
//   行内的 `$` 后面紧跟空格、或结束的 `$` 前面是空格 / 后面紧跟数字的，不当公式（「$5 和 $6」这类）。

import MarkdownIt from "markdown-it";
import katex from "katex";

type StateInline = Parameters<Parameters<MarkdownIt["inline"]["ruler"]["after"]>[2]>[0];
type StateBlock = Parameters<Parameters<MarkdownIt["block"]["ruler"]["before"]>[2]>[0];

function tex(src: string, display: boolean): string {
  return katex.renderToString(src, { displayMode: display, throwOnError: false, output: "html", trust: false });
}

function mathInline(state: StateInline, silent: boolean): boolean {
  const s = state.src, start = state.pos;
  if (s.charCodeAt(start) !== 0x24 /* $ */ || s.charCodeAt(start + 1) === 0x24) return false;
  const first = s[start + 1];
  if (first === undefined || /\s/.test(first)) return false;
  let end = start + 1;
  for (;;) {
    end = s.indexOf("$", end);
    if (end < 0) return false;
    if (s[end - 1] === "\\") { end++; continue; }
    break;
  }
  const body = s.slice(start + 1, end);
  if (!body || body.includes("\n") || /\s/.test(body[body.length - 1]) || /\d/.test(s[end + 1] ?? "")) return false;
  if (!silent) {
    const tok = state.push("math_inline", "", 0);
    tok.content = body;
  }
  state.pos = end + 1;
  return true;
}

function mathBlock(state: StateBlock, startLine: number, endLine: number, silent: boolean): boolean {
  const lineText = (n: number) => state.src.slice(state.bMarks[n] + state.tShift[n], state.eMarks[n]);
  const first = lineText(startLine);
  if (!first.startsWith("$$")) return false;
  let body: string, last = startLine;
  const rest = first.slice(2);
  if (rest.trimEnd().endsWith("$$") && rest.trim().length >= 2) {
    body = rest.trimEnd().slice(0, -2);
  } else {
    const lines = [rest];
    let n = startLine + 1;
    for (; n < endLine; n++) {
      const t = lineText(n);
      if (t.trimEnd().endsWith("$$")) {
        lines.push(t.trimEnd().slice(0, -2));
        break;
      }
      lines.push(t);
    }
    if (n >= endLine) return false;   // 没有收尾的 $$：不当公式
    body = lines.join("\n");
    last = n;
  }
  if (silent) return true;
  const tok = state.push("math_block", "", 0);
  tok.content = body;
  tok.block = true;
  tok.map = [startLine, last + 1];
  state.line = last + 1;
  return true;
}

const md = new MarkdownIt({ html: false, linkify: true, breaks: true });
md.inline.ruler.after("escape", "math_inline", mathInline);
md.block.ruler.before("fence", "math_block", mathBlock, { alt: ["paragraph", "reference", "blockquote", "list"] });
md.renderer.rules.math_inline = (tokens, i) => tex(tokens[i].content, false);
md.renderer.rules.math_block = (tokens, i) => `<div class="math-block">${tex(tokens[i].content, true)}</div>`;
// 链接在新标签页打开，不带来源
const defaultLink = md.renderer.rules.link_open ?? ((tokens, i, opts, _env, self) => self.renderToken(tokens, i, opts));
md.renderer.rules.link_open = (tokens, i, opts, env, self) => {
  tokens[i].attrSet("target", "_blank");
  tokens[i].attrSet("rel", "noopener noreferrer");
  return defaultLink(tokens, i, opts, env, self);
};

export function renderNote(text: string): string {
  return md.render(text);
}
