---
name: unireader-obsidian-export
description: 把 UniReader（macOS PDF 阅读器）里的笔记——文字笔记、高亮、图片笔记、书签、AI 对话链接——通过它的 MCP 服务读出来，写成 Obsidian vault 里的 Markdown 文件，每条都带能点回 UniReader 原处的 unireader:// 链接。当用户要「把 UniReader 的笔记导到 Obsidian」「同步阅读笔记到 vault」「更新某本书在 Obsidian 里的笔记」时使用。
---

# UniReader → Obsidian 导出

## 前提

- UniReader 正在运行，MCP 服务已开（设置 › Agent）。本 skill 只用**读取类**工具，不需要打开写入开关。
- 已配置好 MCP 连接（例：`claude mcp add --transport http unireader http://127.0.0.1:8773/mcp`）。
- 知道 vault 在哪。用户没说就问；**不要猜路径**，也不要把文件写到 vault 之外。
- 只读 MCP 和工作区里的 `Images/` 文件夹。**绝不直接打开 `library.sqlite`**（App 之外再开一份库会丢笔记，这是项目红线）。

## 流程

1. `get_state` → 看开着哪些窗口 / 工作区；记下 `app.deep_link` 里的链接格式（一般用不上，每条数据都自带 `link`）。
2. 定目标文档：用户说了书名就 `list_documents`（可带 `workspace`）按 `title` 找；没说就取 key 窗口那篇（`get_current_view`）。
3. `list_annotations`，`document_id` 给上，`kinds` 默认全要。拿到的每条都有：
   - `page`（1 起）、`quote`（原文）、`text`（正文，**已经是 Markdown**）、`type`（笔记类型名，可能 null）、`source`（AI/Agent 来源）
   - `link` —— `unireader://open?…`，**原样使用，不要自己改写或解码**（它已按 Markdown 安全编码）
4. 按下面的映射写文件。写之前先看目标文件在不在：在，只替换生成区；不在，整份新建。
5. 图片笔记：文件在 `<工作区路径>/Images/<image_sha256>.<ext>`（用 `ls <工作区>/Images/<sha>.*` 找扩展名），
   复制到 vault 附件目录，**文件名保持 sha256**——同一张图重复导出不会复制第二份。
6. 完成后告诉用户写了哪个文件、几条笔记、几张图；有找不到的图片文件就列出来，不要静默跳过。

## 文件布局（默认，用户另有约定就听用户的）

- 每篇 PDF 一个文件：`<vault>/UniReader/<工作区名>/<文档标题>.md`
  - 标题里的 `/ \ : * ? " < > | # ^ [ ]` 换成 `-`；同名冲突在末尾加 `content_hash` 前 6 位
- 附件：`<vault>/UniReader/_images/<sha256>.<ext>`
- 想按条筛选（Bases / Dataview）的用户可以要「每条笔记一个文件」：`<vault>/UniReader/<工作区名>/<文档标题>/<page>-<id 前 8 位>.md`，
  frontmatter 多写 `page`、`kind`、`type`、`color`，正文只有那一条。映射规则相同。

## 映射

### frontmatter（重导出时靠 `unireader_doc` 找回文件，不靠文件名——用户可能改名/移动）

```yaml
---
title: <文档标题>
unireader_doc: <document_id>
content_hash: <content_hash>
workspace: <工作区名>
source_pdf: <file.path>
pages: <page_count>
group: <group，空就不写>
tags: [unireader]
last_synced: <ISO-8601 本地时间>
---
```

### 生成区

正文第一段是**生成区**，用 Obsidian 注释包住（阅读模式不显示）。重导出时只替换标记之间的内容，
标记之外是用户自己写的，**一个字都不动**：

```markdown
%% unireader:begin — 这段由 Agent 从 UniReader 生成，重新导出时整体替换；在标记外面写你自己的内容 %%
…
%% unireader:end %%
```

### 每条笔记的写法（按页升序，同页按 `rect[1]` 升序）

按页分节 `## 第 12 页`。每条一个 callout，末尾一行回跳链接：

高亮：
```markdown
> [!quote] p.12 · #hl/yellow
> <quote 原文，多行保留>
> [在 UniReader 中打开](<link>)
```
颜色由 `color`（#RRGGBB）映射：`#FFD628`→yellow、`#96DC78`→green、`#78BEFF`→blue、`#FF96BE`→pink；不认识的写 `#hl/other`。

文字笔记：
```markdown
> [!note] p.12 · #note/<type，null 写 general>
> <quote 原文；没有 quote（点注解）就省这一行>
>
> <text 正文原样，Markdown 不转换；多行每行前加 `> `>
> [在 UniReader 中打开](<link>)
```
`source.kind` 是 `ai` → 标题行再加 `#src/ai`，正文后加一行 `来源对话：<source.url>`；是 `agent` → `#src/agent`。

图片笔记：
```markdown
> [!example] p.12 · 图片
> ![[UniReader/_images/<sha256>.<ext>]]
> <caption，空就省>
> [在 UniReader 中打开](<link>)
```

书签：单独一节 `## 书签`，列表 `- p.12 <title> — [打开](<link>)`。

AI 对话（`ai_threads`）：单独一节 `## AI 对话`，`- p.12 <provider> · [<title 或 url>](<url>) — [打开](<link>)`。

草稿纸 / 笔迹：**不导**（Obsidian 没有对应物）。生成区末尾写一行统计即可：`笔迹：N 笔，分布在 M 页`。

### 不要做的事

- 不改写 `text` 的 Markdown（公式 `$…$` 原样；`==高亮==`、`[[wikilink]]` 用户写了就是给 Obsidian 看的）
- 不删用户区、不重排用户区
- 内容没变就不要重写文件（先比对生成区，避免 Obsidian 正在编辑时被外部改写）
- 不复制 PDF 本体进 vault（除非用户明确要）

## 链接格式（需要自己拼的时候）

```
unireader://open?ws=<.unrd 绝对路径>&doc=<document_id>[&page=N][&frac=0…1][&note=<笔记 id>]
```
值按 RFC 3986 unreserved 编码（只保留 `A-Z a-z 0-9 - . _ ~`，其余 `%XX`）。`page` 1 起；`note` 给了会跳到那条并展开气泡。
想让链接在文档被删除重导入后仍有效，加 `&hash=<content_hash>`。
