// 文字笔记正文的排版（`pnpm test`）：Markdown、公式写法同 Mac，原样 HTML 不执行。
import { test } from "node:test";
import assert from "node:assert/strict";
import { renderNote } from "../.test-build/markdown.js";

test("Markdown：强调、列表、单个换行就换行", () => {
  assert.equal(renderNote("**重点**"), "<p><strong>重点</strong></p>\n");
  assert.match(renderNote("- 一\n- 二"), /<ul>\n<li>一<\/li>\n<li>二<\/li>\n<\/ul>/);
  assert.equal(renderNote("第一行\n第二行"), "<p>第一行<br>\n第二行</p>\n");
});

test("原样 HTML 当文字显示；危险链接不变成链接；链接新标签页打开", () => {
  const html = renderNote('<img src=x onerror="alert(1)"> <script>alert(2)</script>');
  assert.ok(!html.includes("<img") && !html.includes("<script"), html);
  assert.ok(html.includes("&lt;script&gt;"), html);
  assert.ok(!renderNote("[点我](javascript:alert(1))").includes("href"));
  assert.match(renderNote("[官网](https://katex.org)"), /<a href="https:\/\/katex\.org" target="_blank" rel="noopener noreferrer">官网<\/a>/);
});

test("公式：$…$ 行内、$$…$$ 单独成行（可跨行）", () => {
  const inline = renderNote("面积 $\\pi r^2$ 很好算");
  assert.match(inline, /class="katex"/);
  assert.ok(!inline.includes("$"), inline);
  const block = renderNote("$$\n\\int_0^1 x\\,dx\n$$");
  assert.match(block, /<div class="math-block"><span class="katex-display">/);
  assert.match(renderNote("$$x^2$$"), /katex-display/, "写在一行里");
  assert.match(renderNote("下面\n$$\na\n$$\n上面"), /katex-display/, "段落中间的公式块");
});

test("不是公式的 $：价钱、空格、没收尾、\\( \\) 写法", () => {
  for (const s of ["一共 $5 和 $6", "$ x $", "只有一个 $ 号", "\\(x\\)"]) {
    assert.ok(!renderNote(s).includes("katex"), s);
  }
  assert.ok(!renderNote("$$\n没有收尾").includes("katex"));
});

test("公式写错了不报错，原样标红显示", () => {
  assert.match(renderNote("$\\frac{1}$"), /katex-error|katex/);
});
