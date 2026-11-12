# 全工作区搜索（MCP `search`）+ 语义搜索

> 2026-11-12 用户：「把搜索这块整体都强化下。适当的话还可以做一下 vector 支持。」
> 本轮只做 Agent 用的 MCP 工具与设置页一节；App 里没有加搜索界面（⌘F 仍是单篇、⌘P 仍只搜标题）。

## 1. 现状与问题（做之前）

- `search_text` 只能搜**一篇** PDF：先查 OCR 缓存、再 `PDFDocument.findString`；OCR 那路按**行**比对，一句话被版面换行切开就搜不到；
  要跨全库只能一本本循环，私有 `PDFDocument` 缓存 4 份 / OCR 缓存 2 本会反复换进换出，还占住 `mcp.doc` 队列。
- Markdown 笔记只能一篇篇 `read_markdown search=`；`list_markdown_notes query=` 只比标题 / 路径。批注、习题、Agent 上下文没有文字查询。
- 没有任何全文索引（没有 FTS 表）。

## 2. 索引什么（`Sources/Search/SearchSources.swift`）

每个**来源**有一个键和一个「指纹」，指纹变了才重建这个来源的块：

| 来源键 | 内容 | 指纹 |
|---|---|---|
| `pdf:<文档 id>` | 每页文字：OCR 缓存优先（滤水印、按版面拼行，与 `read_pages` 同一套 `MCPDocReader.ocrTexts`）；OCR 少于 8 个字的页用 PDF 自带文字（每 40 页一批取，别长时间占住读 PDF 的队列） | 当前版本 hash · OCR 引擎 · `ocrStamp` · 文件在不在 |
| `ann:<文档 id>` | 文字笔记（原文 + 正文）、高亮原文、书签名、图片笔记说明 | 条数 · 最新修改时间 |
| `md:<note key>` | Markdown 笔记，按标题 / 约 500 字切块，块带**起始行号**与所在标题 | 文件修改时间 · 大小 |
| `ex:all` | 全部习题：题干、选项、答案、解析、笔记、标签 | 条数 · 最新修改时间 |
| `ctx:all` | Agent 上下文：标题 + 摘要 | 条数 · 最新修改时间 |

- 块不超过约 500 字（`SearchText.chunks` / `markdownChunks`）：语义检索的本机模型一次只看约 256 个字。结果给人看时 PDF 同一页、笔记同一段只留分最高的一块。
- 画板（手写）不进索引：没有文字。

## 3. 放哪：单独一个库，不进 `library.sqlite`

`~/Library/Application Support/UniReader/SearchIndex/<workspace_id>.sqlite`（老库没有 `workspace_id` 就按路径算一个）。

- 🔴 不进 `library.sqlite`：那个库每次备份 / 建离线镜像都整库 `VACUUM INTO`，同步按表白名单走；`Sources/Store/` 还经符号链接编进服务器。
  索引是**派生数据**，随时能重建——不该跟着备份、同步，也不该成为三端的表结构契约。删掉这个文件只是下次搜索重建。
- 表：`source(key, stamp, title)`、`chunk(id AUTOINCREMENT, source, kind, owner, sub, page, line, title, heading, body, norm, title_norm)`、
  `chunk_fts`（FTS5 外部内容表，`tokenize='trigram'`，两个触发器同步）、`vec(chunk_id, model, v)`、`meta(schema)`。
  `chunk.id` 用 AUTOINCREMENT：向量按 id 挂，id 被复用就会挂到别的块上。
- 表结构版本 `SearchIndex.schemaVersion`（现为 3）：改了切块 / 归一化规则就加一，旧库整个丢掉重建。

## 4. 关键词查法（`SearchIndex.keyword` + `SearchText`）

- **归一化**（建索引与查询同一套）：兼容分解（全角 → 半角）、小写、**去掉全部空白**。去空白是为 OCR：一句中文常被换行 / 版面空格切开，
  去掉后整句照样搜得中；西文词连起来（`matrixrank`）不影响子串匹配。
- **词**：空白分开；`"…"` / `“…”` 括起来的算一个词；去重。
- **候选**：三个字及以上的词走 FTS5 trigram（`MATCH "词"`，`AND` 连接）；一两个字的词 trigram 用不上，退回 `LIKE`（正文或标题）。
  所有词都要真的出现（正文或标题）——在 Swift 里再核实一遍；一个结果都没有、又不止一个词 → 自动退回「任一词」，结果里 `relaxed = true`。
  候选最多 4000 块。
- **打分**（`SearchText.score`）：每个词 `(1 + ln tf) × idf` 累加（idf 按候选集算），标题里出现再加 0.8 × idf；乘「命中词占比」的平方；按块长略压。
- **摘要**（`SearchText.snippet`）：在归一化文本里找命中，再映射回原文，前后各 60 字，命中词用 `[ ]` 括起来，换行变空格。
- **筛选**：种类、文档（PDF 页与批注按 owner、习题按所属文档 `sub = doc:<id>`；限定文档时笔记 / 上下文不出现）、笔记来源（note key 前缀）、
  笔记目录（只给目录不给来源时在结果里再筛）。

### 4.1 何时更新

每次 `search` 先 `refresh`：在索引自己的线程上算全部来源的指纹，删掉没了的、重建变了的。最多等 `wait` 秒（默认 20），没建完就先用已有的结果，
结果里 `index.complete = false`、`pending = 还剩几个来源`，后台接着建。同时只有一轮在建；建的过程中又来一份清单就排在后面（只留最新一份）。

### 4.2 实测（`spike/search-test.swift` 外另做的规模测试，2026-11-12，Release 编译）

30 本 × 500 页、每页约 800 字（约 1200 万字、3 万块，随机汉字）：建索引 14 秒；查「拉格朗日中值定理」1 ms、「中值」（两个字走 LIKE）41 ms、
「理论 实践」（退回任一词，候选 339）129 ms；指纹没变时再对一遍 0 ms。索引文件 242 MB（随机汉字的三字组合远多于真实文字，真实书会小不少）。
试过 FTS5 `detail='none'`：只省 15%，而且多字词（三字组合连成的短语）查不出来了，放弃。

## 5. 语义搜索（向量）

### 5.1 模型选型实测（2026-11-12，本机）

拿考研政治 / 数学 10 段、两组问题测「首位命中」：

| | 问法与原文字面重合多（10 问） | 换说法、字面不同（12 问） |
|---|---|---|
| `NLEmbedding.sentenceEmbedding(.simplifiedChinese)` | 4/10 | 2/12 |
| `NLContextualEmbedding`（中日韩模型，按字向量取平均） | 10/10 | 4/12 |
| 字的二元组词袋（不用模型，当关键词基线） | 9/10 | 2/12 |

结论：系统自带的上下文模型**能用，但只比关键词好一点**（换说法那组随机猜约 1.2/12）。所以：

- 语义搜索**默认关**，开了也一律「关键词 + 语义」两路按排名合并（倒数排名融合 k = 60），不单靠向量；
- 另给一种 **OpenAI 兼容接口**（`POST <地址>/embeddings`，默认 SiliconFlow `BAAI/bge-m3`，本机 Ollama 也行），中文效果好得多。
  🔴 代价：PDF 与笔记的文字会发给那个服务——设置页写明，用户自己选。

### 5.2 实现（`Sources/Search/Embedding.swift`、`SearchIndex` 的向量部分）

- 本机模型：含中日韩文字的块用中日韩模型、其余用拉丁模型（`vec.model` = `system-cjk` / `system-latn`）；查询两个模型各算一遍，只和同一模型的向量比。
  输入截到 250 字（模型一次约 256 个字）。`NLContextualEmbedding` 不保证线程安全，全部串在一个 actor 里。
- 接口：一次 32 段；输入截到 1500 字；密钥在钥匙串（`searchEmbeddingKey`），地址 / 模型在 UserDefaults。
- 存盘：单位向量量化成 Int8（×127），一维一字节；查询时整批读进内存（按模型分），点积排序；向量一变内存那份作废。
- 何时算：关键词索引建完后在后台接着算还没有向量的块；换了模型 → 别的模型算的向量先全部删掉；接口出错（没网、密钥不对）就停下、记下原因，下次搜索再接着算。
  设置里关掉语义搜索 → 正在算的停下。

## 6. MCP 工具 `search`（`Sources/MCP/MCPTools+Search.swift`，`.read`）

- 入参：`query`（必填）、`kinds`（pdf / markdown / annotation / exercise / context）、`document_ids`、`note_source`、`note_folder`、
  `mode`（auto / keyword / semantic / hybrid；auto = 语义开着且有向量就 hybrid，否则 keyword）、`limit`（默认 20，最多 100）、`wait`（秒，默认 20）、`workspace`。
- 每条结果：`kind`、`title`、`snippet`、`score`、`link`，以及各自的身份字段：PDF `document_id` + `page`；笔记 `note_ref` + `line` + `heading`；
  批注 `annotation_id` + `annotation_kind` + `document_id` + `page`；习题 `exercise_id`（+ 所属文档 / 页 / 章节）；上下文 `context_id` + `agent`。
- 还给 `terms`、`mode`、`relaxed`、`index{complete, pending, chunks, semantic{enabled, embedded, error}}`。
- 后续动作写在工具说明里：PDF 页 → `read_pages` / `search_text`（要高亮框）；笔记 → `read_markdown offset=line`；批注 → `list_annotations`；习题 → `list_exercises`。
- `search_text` 不变（单篇、给框）。MCP `instructions` 与 Agent 面板上下文都加了「找东西先用 search」。

## 7. 设置（设置 › Agent › 搜索）

「同时按意思搜索」开关；模型（本机 / OpenAI 兼容接口：地址、模型名称、API 密钥）；搜索索引一行（key 窗口工作区的块数、已算向量数、正在建、上次出错）+「重建索引」。
改开关 / 换模型会让开着的工作区在后台把索引与向量建起来（`MCPFacade.warmUpSearchIndexes`）。中英文案都在 `Localizable.strings`。

## 8. 验证

- `spike/search-test.swift` 35 项（归一化 / 切段 / 摘要 / 打分；索引建、查、增量、删来源；短词 LIKE、多词、退回任一词、按种类 / 文档 / 来源筛；
  假模型的向量、语义检索、合并排序、量化点积）。命令在文件头。
- Mac Debug 编译通过。🔴 没对着运行中的 App 跑过（真实书库的建索引时间、OCR 解码开销、索引大小待用户实测）。
- 实测清单（用户）：
  141. 让 Agent「在整个工作区里找讲『矛盾的普遍性』的地方」→ 一次调用就列出书里的页、笔记、批注、习题；点链接能跳过去；扫描书里跨行的句子也能找到。
  142. 第一次搜一个大书库 → 回话里说索引还没建完；过一会儿再搜 → 结果完整；设置 › Agent › 搜索那一行的块数在涨。
  143. 改一篇笔记、加一条批注后马上再搜 → 新内容能搜到。
  144. 打开「同时按意思搜索」（本机模型）→ 设置里「已算好向量」的数在涨；换个说法搜 → 结果里混进意思相近的段落。
  145. 换成 OpenAI 兼容接口、填 SiliconFlow 的密钥 → 向量重算；密钥填错 → 设置那一行显示上次出错的原因，搜索照样能出关键词结果。

## 9. 没做 / 以后

- App 里的全局搜索界面（⌘⇧F 之类）：索引已经有了，界面没做，用户要再排。
- `search_text` 的 OCR 那路仍按行比对：跨行的短语在单篇里给不出框（全库 `search` 能找到那一页，Agent 再用短一点的词取框）。
- 安卓 / 服务器 / 网页都不做（索引不是契约，各端要的话各建各的）。
