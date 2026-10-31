# 习题（Exercise）方案 — Agent 识别导入 + Mac 练习 / 错题本 / 收藏

> 状态：**2026-10-10 定方案并落地（Mac）**，实现记录见 §9。本轮只做**选择题**（单选 / 多选）。
> 三条拍板（用户 2026-10-10 选的）：① 练习界面 = **主窗口标签页**（侧栏加「习题」一段）；
> ② 本轮**只做 Mac**，安卓只按 schema 契约同步建表（`Schema.kt` 升 v20），平板练习 / 离线镜像同步习题放下一轮
> （**第二轮 2026-10-11 已做：安卓模式1 + 模式2 + 离线镜像，§10**）；
> ③ 错题本 = **答错自动进，只能手动移出**。
> **2026-10-11 第二批**（用户追加）：④ **章节**——按「课本 + 章节」练，章节从 PDF 目录自动取、可手动设，
> 侧栏按**目录整棵树**展开（§2.3）；⑤ **导入书上已有的作答**（用户「选择题一般高亮作答，部分手写」，§2.4）+
> 答案后补时**重判**；⑥ 习题标签顶上加**筛选**（全部 / 没做过 / 错题 / 收藏，§4.2）。
> **同日第三次调整**（用户：「选了错题后还显示分类筛选就有点问题了」，§9.5）：侧栏管「哪一组题」（收藏也像错题本那样
> 按书 → 章展开），顶栏的筛选只剩**「只看没做过」**一个开关，错题本那一支不显示。
> 两列（`exercise.chapter`、`exercise_attempt.source`）在 v20 发布前补进同一版（开发包已建过表的库靠 `ADD COLUMN` 补）。
> **2026-10-13 第三轮：填空 / 主观题**（schema v21，§11）：填空能程序判对的直接判、对不上的交给人判；主观题只给参考答案、
> 用户自己判对错；可以打字也可以在内置小画板上手写；Agent 能读作答（含手写图）并批改。本轮只做 Mac，平板只显示题干。
> **2026-10-27 第四轮：题目笔记 + 重做上次做错的**（schema v22，§12）：每道题能写一段自己的笔记（判完才显示）；
> 顶栏加「重做上次做错的」开关，只练上一次结果是错的题、都重新作答，答对一次下次就不在了。本轮只做 Mac。
> **2026-10-31 第五轮：章节怎么分**（§14）：Agent 第一次往一本书里导题先问用户怎么分（按 PDF 目录 / 按用户说的方式自己分、几级都行 / 不分），
> 以后沿用；侧栏右键一本书能「移除章节分级」（题目和用户状态都不动）/「按目录分章节」。用户说的「习题册 / 练习册 / 练习库」= App 的习题。不改表结构。

## 1. 需求

**用户原话**：「习题识别功能，让 agent 识别内容，然后输出 pdf 上的习题，这个习题按照固定的标准导入到工程中，
方便练习，记错以及收藏。一般主要是选择题。可以先做选择题部分。」

一句话定义：

> **习题 = 工作区里的一条结构化记录（题干 + 选项 + 答案 + 解析 + 出处），由 Agent 看 PDF 页面识别后经 MCP 按固定格式写入；
> App 负责练习、判对错、记错题、收藏，并能一键回到 PDF 原题。**

- 识别这件事**不做进 App**：App 只提供「固定格式的写入口」（MCP 工具）和一份写给 Agent 的操作说明
  （`skills/unireader-exercise-import/SKILL.md`）。看图、转写、对答案都是 Agent 的事。
- 「固定的标准」= §3.1 的 JSON 结构，MCP 工具的输入就是它；校验在 App 里做，不合格的题逐条退回并说明原因。

## 2. 数据（schema v19 → v20，跨端契约）

两张新表，都只**新增**、不动已有表（`migrate()` 里 `CREATE TABLE IF NOT EXISTS` 覆盖，无需 ALTER）。
安卓 `Schema.kt` 同一次改动里逐字补上同样的 DDL、`VERSION = 20`（`android/AGENTS.md` 的契约纪律）。

```sql
-- v20：习题（`EXERCISE-PLAN.md §2`）。一行一道题；题目内容在 payload（JSON），可筛选 / 排序的放列。
CREATE TABLE IF NOT EXISTS exercise (
  id TEXT PRIMARY KEY,
  document_id TEXT REFERENCES document(id) ON DELETE CASCADE,
  page INTEGER,
  seq INTEGER NOT NULL DEFAULT 0,
  kind INTEGER NOT NULL DEFAULT 0,
  number TEXT NOT NULL DEFAULT '',
  section TEXT NOT NULL DEFAULT '',
  payload BLOB NOT NULL,
  starred INTEGER NOT NULL DEFAULT 0,
  wrong INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  chapter TEXT NOT NULL DEFAULT ''          -- §2.3（2026-10-11 补）
);
CREATE INDEX IF NOT EXISTS idx_exercise_doc ON exercise(document_id, page, seq);
-- 每次作答一行（练习记录）。answer = 选中的选项键按字母序拼起来（"B" / "AC"）；
-- correct 1 对 / 0 错 / NULL 这道题还没有答案、没法判。
CREATE TABLE IF NOT EXISTS exercise_attempt (
  id TEXT PRIMARY KEY,
  exercise_id TEXT NOT NULL REFERENCES exercise(id) ON DELETE CASCADE,
  answer TEXT NOT NULL,
  correct INTEGER,
  elapsed_ms INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT ''           -- §2.4（2026-10-11 补）
);
CREATE INDEX IF NOT EXISTS idx_exercise_attempt_ex ON exercise_attempt(exercise_id, created_at);
```

列的语义：

| 列 | 说明 |
|---|---|
| `document_id` | 出处那篇 PDF（逻辑文档 UUID）。**可空**：给以后「不来自 PDF 的题」留口子；本轮写入一律有值 |
| `page` | 出处页，**0 起**（对外 1 起，换算只在 `PageNo`）；可空 = 不知道在哪页 |
| `seq` | 同一页内的先后（Agent 按阅读顺序给的下标）。练习顺序 = 文档 → 页 → `seq` |
| `kind` | 0 单选 / 1 多选 / 3 填空 / 4 主观题（v21，§11）；2 留给以后的判断题。不认识的值各端整行跳过 |
| `number` / `section` | 书上印的题号（原样，如 `"5"`、`"例 3"`）/ 章节或套卷名 |
| `starred` | 收藏 |
| `wrong` | 在错题本里。**答错置 1；只有用户手动「移出错题本」置 0**（拍板 ③）；答对不动它 |
| `source` | 谁导入的（MCP 客户端名，同批注的 `NoteSource.provider`） |
| `chapter` | 所属章节在目录里的路径，**JSON 字符串数组**（顶层 → 最深一级）；空串 = 没设（§2.3） |
| `note` | 用户给这道题写的笔记（Markdown + `$…$`），空串 = 没写。用户状态，重导题目不动它（v22，§12） |
| `exercise_attempt.source` | `''` = 在 App 里练的；`'mark'` = 从用户在文档上的作答（高亮 / 手写）认出来的，**每道题至多一条**（§2.4） |

`payload`（JSON，键 snake_case，新键一律可选、`decodeIfPresent`，老行不迁移）：

```json
{
  "stem": "设 $f(x)=x^2$，则 $f'(1)=$",
  "options": [{"key": "A", "text": "$0$"}, {"key": "B", "text": "$1$"}, {"key": "C", "text": "$2$"}],
  "answer": ["C"],
  "answer_source": "book",
  "explanation": "……",
  "region": [0.08, 0.31, 0.84, 0.12],
  "figure": false
}
```

- `stem` / `options[].text` / `explanation`：Markdown + `$…$` 公式（规则同 MCP 说明里的「Math in notes」）。
- `answer`：选项键数组，空数组 = 还没有答案。单选恰 1 个，多选 ≥1 个，都必须是 `options` 里有的键。
- `answer_source`：`"book"` = 书上印的（答案页 / 题后），`"agent"` = Agent 自己解出来的。
  🔴 练习时 `agent` 来源的答案要明说「答案由 Agent 推算，未经核对」——判错了用户得知道可能是答案本身错了。
- `region`：题目在**那一页**上的框（归一化 0~1、左上原点，同批注坐标；开着扫描页对齐就是对齐后的页面）。
  有它就能在练习时切到「看原题」（从 PDF 现渲那一块，不存图）。
- `figure`：题目带图 / 表，文字转写不全 → 练习时**默认显示原题截图**。

### 2.1 去重（同一题再导一次 = 更新，不重复）

键 = `(document_id, page, section, number)`；`number` 为空时退回 `(document_id, page, 规整后的题干)`
（规整 = 去掉全部空白）。命中 → **只覆盖内容**（`kind/number/section/seq/payload/updated_at`），
`starred` / `wrong` / 作答记录一个不动；没命中 → 新建。于是「先导题目、后补答案」「识别错了重导一遍」都安全。

### 2.2 为什么这样分列 / payload

- 要按它筛选、排序、计数的（文档、页、题型、收藏、错题）放列；题目内容整体进 payload——
  选项个数不定、以后的题型字段各不相同，放列等于每加一种题型改一次表。
- 收藏与错题是**用户状态**，与题目内容分开存，重导题目不会把它们冲掉。
- 作答记录单独一张表而不是 payload 里的数组：练习一次写一行，不必重写整道题；
  以后离线镜像按行合并时两端各自的作答也能合在一起，不会互相覆盖。

### 2.3 章节（2026-10-11，用户：「方便按照课本 + 章节来做题；章节一般可以从 toc 获取到」）

- **存什么**：`exercise.chapter` = 目录路径，JSON 字符串数组，存**最深一级**的完整路径（`["第二章 导数","2.3 求导法则"]`）。
  用户选的「按目录整棵树」：侧栏每本书展开成章节树，点哪一级就练那一级及以下的全部题（前缀匹配，`ExerciseScope.chapter`）。
  与 `section` 分开：`section` 是书上印的题组名、参与去重；`chapter` 是归属、用于按章节练，手动改了也不影响认同一道题。
- **怎么来**（优先级从高到低）：Agent 明确给的 `chapter` > 已有的题原来的章节（可能是用户手动设的，重导不冲掉）>
  **按页码从 PDF 自带目录自动定**（`ExerciseChapter.path`：每层取「起始页 ≤ 题目页」的最后一项，一直走到最深；
  目录项没落点的按它第一个有落点的子孙算；章开头、第一节之前的页停在章这一级）。
- **分法**（2026-10-31，§14）：按目录（上面这条）/ Agent 按用户说的方式自己写（页面标题、题组，层数不限）/ 不分。
  Agent 第一次往一本书里导题时问用户；`import_exercises` 的 `chapters` 只管没自己带 `chapter` 的题；不分章节的书再导题也不按目录分。
- 🔴 **只用 PDF 自带的目录，不用用户书签**——书签名字随手起，当章节会乱。没有目录的扫描件章节留空：
  可以让 Agent 按页面标题填，或用户在列表里右键「设置章节…」（下拉框：按页码自动 / 不设 / 目录里任一节 / 手动填写，
  手填用「›」分级）。
- 侧栏章节树的数与顺序：一条 `GROUP BY document_id, chapter` 拿每个路径恰好几道 + 最早页码；上一级的数是下面各级之和，
  同级按最早页码排（就是书里的先后——侧栏手上没有目录也排得对）。有题没设章节时末尾多一行「未分章节」。

### 2.4 书上已有的作答 + 答案后补时重判（2026-10-11）

- 用户原话：「选择题我一般是会高亮作答；部分也会手写笔记」。**认作答是 Agent 的事**：高亮走 `list_annotations`
  （`quote` + `rects` 是结构化数据，不用看图），手写走 `render_page` 新加的 `include_marks`（把可见图层的笔迹和高亮叠画在页图上）。
- 写入：`import_exercises` / `update_exercises` 的 `user_answer`。存成一条 `source = 'mark'` 的作答，**每道题至多一条**
  （重导 / 再给一次 = 替换，不会越记越多；给空串 = 撤掉）；照常判题，**判错进错题本**（同拍板 ③）。时间记写入那一刻。
- **重判**：一道题的答案变了（补上 / 改了，`import_exercises` 命中已有题或 `update_exercises`），把它的作答**全部**按新答案重判。
  重判出错 → 进错题本；重判成对 → **不**移出（只能手动出）。原先没答案时练的那几次（`correct = NULL`）也在这时判出来。
- 练习页判完后多一行「你在书上选的是 B（错）」——判完才显示，免得先剧透。统计里的「做过几次」含书上这一条，所以
  「没做过」筛选会把书上做过的排除掉。

## 3. 导入：MCP 工具 + Agent 说明

### 3.1 工具（`Sources/MCP/MCPTools+Exercises.swift`，批 4）

| 工具 | 层级 | 作用 |
|---|---|---|
| `import_exercises` | write | 按 §2 的结构批量写入一篇文档的习题（一次 ≤50 道）。逐条校验，不合格的退回原因、其余照常写入；命中去重键即更新。可带 `chapter`（不带 = 按目录自动）、`user_answer`（书上的作答，§2.4）；顶层 `chapters`（`"toc"` / `"none"`，不带 = 按这本书现在的样子，§14.2） |
| `list_exercises` | read | 列出习题（按文档 / 页范围 / 章节 / 收藏 / 错题筛选，分页），带 id、题号、章节、书上的作答、作答统计；补答案前先用它对号 |
| `update_exercises` | write | 按 id 改部分字段（最常见：补 `answer` + `answer_source` + `explanation`；也能改 `chapter`、`user_answer`）。答案变了 → 重判 |
| `delete_exercises` | delete | 按 id 删（🔴 **先归档进回收站再删**，红线 11） |
| `render_page` 的 `include_marks` | read | （已有工具的新参数）把用户可见图层的笔迹与高亮叠画在页图上，给 Agent 认手写的作答（§2.4） |

- 输入里的题型写 `"single"` / `"multiple"`，答案写字符串（`"B"`、`"AC"`）——对模型最不容易写错；
  进库前统一成 §2 的形态。页码对外 1 起。
- 习题不进 `DocSession`（阅读区不画它），所以**没有「文档开没开」两条写路径的问题**：一律直接写库，
  写完 `WorkspaceManager.refreshExercises()` 通知侧栏和练习标签。
- 🔴 每个返回的键都要在 `outputSchema` 里声明（Kimi 的客户端严格校验，多一个键整次调用作废）；
  新的读工具加进 `spike/mcp-schema-audit.py` 的 `READ_CALLS`。

### 3.2 Agent 说明（`skills/unireader-exercise-import/SKILL.md`）

流程：`get_state` → 确定文档与页范围 → 逐页 `render_page`（看图）+ `read_pages`（拿 OCR 文本对照）→
按阅读顺序转写 → `import_exercises` → 答案在书后的，翻到答案页后 `list_exercises` 对题号 → `update_exercises`。
写明：只转写不改写；看不清的字不猜（宁可整题标 `figure: true` 让用户看原图）；答案只有书上印的才写 `book`。

Agent 面板（Kimi）的上下文串里补一句有这组工具（`AgentChat.swift`），`MCPServer.instructions` 同。

## 4. Mac：练习

### 4.1 侧栏与标签页

- 侧栏新增「习题」一段（**有题时才出现**）：`全部习题` / `错题本` / `收藏` / 每篇有题的文档一行，行尾显示题数。
  有章节的书可以展开成**章节树**（§2.3），展开状态记在本机（与笔记子目录同一张表）。
- 点一行 = 打开一个**习题标签**（第四种标签，与 PDF / Markdown / 画板互斥，照画板的做法：`DocTabModel.exerciseScope`，
  `docID == nil`，所有按 PDF 记账的地方看到的是空标签）。身份 = 范围（`ex:all` / `ex:wrong` / `ex:starred` / `ex:doc:<id>` /
  `ex:chap:<id>:<路径 JSON>`），同一范围已开着就切过去；跨启动恢复同其它标签（`TabsModel.StoredTab`）。
- **默认只用一个习题标签**（2026-10-11 用户定：「所有的练习题默认只在一个 tab，除非右键选择单独的 tab 打开，错题除外」）：
  - 侧栏点哪组题（全部 / 收藏 / 某本书 / 某一章）都在这个**公用标签**里换，不另开（`DocTabModel.isSharedExerciseTab`）。
  - 右键「在新标签页中打开」= 单独开一个（`exerciseSeparate`），之后点别的组不会换掉它；
    若那一组正开在公用标签里，就地把公用标签改成单独的（不开一个重复的），下次点别的组再新开公用标签。
  - **错题本**那一支另有自己的一个公用标签（`ExerciseScope.isMistakes`），不和上面那个混；错题本那一行右键没有这一项。
  - **错题本按书 / 按章展开**（2026-10-11 用户要的）：错题本那一行底下列出有错题的书，每本再按章节树展开（同书底下那棵，
    只留有错题的章节，数的是错题；`ExerciseSummary.mistakeChapters`，`exerciseChapterCounts` 多数一列 `SUM(wrong)`）。
    范围是 `wrongDocument(id)` / `wrongChapter(id, 路径)`，键 `wrong:doc:<id>` / `wrong:chap:<id>:<路径 JSON>`。
    点哪一级默认都在那一个错题标签里换；书 / 章两级右键也能「在新标签页中打开」。
  - **收藏也按书 / 按章展开**（2026-10-11 用户定，§9.5）：规则同错题本（只留有收藏的书 / 章节，数的是收藏；
    `ExerciseSummary.starredChapters`，`exerciseChapterCounts` 再多数一列 `SUM(starred)`）。范围 `starredDocument(id)` /
    `starredChapter(id, 路径)`，键 `starred:doc:<id>` / `starred:chap:<id>:<路径 JSON>`；和「收藏」本身一样在公用标签里换。
  - 已经有标签开着被点的那一组（单独的 / 错题本 / 公用的）→ 直接切过去。
  - 单独开的标签跨启动记得住（存成 `exs:<范围键>`）；改之前存下的几个习题标签恢复时只留第一个公用，其余算单独开的。

### 4.2 练习界面（`Sources/Window/Exercise/`，AppKit；题干 / 选项 / 解析用 Markdown 引擎只读渲染，红线 ② 那一处例外）

- 顶栏：进度 + 全部重做 + **只看没做过**（开关按钮，按下时高亮）+「练习 / 列表」切换。
  范围名只在窗口标题里（用户 2026-10-11 指出顶栏再写一遍是重复）；安卓顶栏没有窗口标题，范围名照旧写在习题页顶上。
  开关一换 = 按新条件重取一份快照、尽量停在原来那题。错题本那一支不显示这个开关（进了错题本的题一定做过）。
  - 2026-10-11 先做的是下拉框「全部 / 没做过 / 错题 / 收藏」，同日改成现在这样（§9.5）：「错题 / 收藏」两项和侧栏重复
    （「第二章的错题」既能点 错题本 › 书 › 第二章，也能点 书 › 第二章 再筛「错题」，开在不同标签里），
    在错题本里又分不出东西。现在「哪一组题」都在侧栏选，顶栏只管做题进度。
- **练习**：一次一题。题号 · 第几页 · 单选/多选；按钮：收藏、看原题、到 PDF 原页（`AppDelegate.showDocument` + `jump`）。
  - 单选：点选项即判；多选：勾完点「提交」。键盘 A~H 选、Return 提交、←/→ 上一题 / 下一题。
  - 「上一题 / 下一题」**钉在练习页底部**、滚动区外面（2026-10-27 用户：「要固定位置，不能随着内容变化显示高度」——
    原先排在题目内容最后，每题高度不同、按钮跟着上下跳）。左右与题目那一栏对齐；安卓同样改了（`ExerciseScreen.navBar`）。
    底下浮着标签栏（胶囊 / 贴底整条，两个以上标签才有）时摆在它上面：窗格把让位高度（`tabBarInset + scrollerLift`，同笔架）
    经 `ExerciseTabView.bottomInset` 交给练习页与列表（列表照样铺满、最后几行能滚到胶囊上面）。
  - 判完：正确项标绿勾、选错的标红叉（SF Symbols），显示解析；答错 → 进错题本。
    没有答案的题：记一次作答（`correct = NULL`），提示「这道题还没有答案」。
  - 错题本里练：判完多一个「移出错题本」。
  - **做过的题直接显示上次结果**（2026-10-11 用户定）：这一轮还没答、以前做过的题，一翻到就是判完的样子——
    上次选的勾上、对错标记、正确答案、解析，结果那行写「上次作答：A，错误。正确答案是 C。」，下面一行
    「那次的时间 · 共做 3 次，对 1 次」。想重答点「再做一次」（这一轮当没答过，库里记录不动）。
    「以前那次」= App 里练的最近一次；App 里没练过才拿书上的作答（结果那行写「书上的作答：…」）。
    书上那条不算「最近」：它的时间是导入那一刻，重导一次会盖过真正后做的练习。对错按现在的答案现判。
    代价（用户知情）：在错题本里练，每题都先看到答案，要先点「再做一次」。
  - **批量重做**（2026-10-11 用户要的）：顶栏「全部重做」= 当前这一组（范围 + 筛选）都当没答过、从第一题练起；
    列表多选右键「重做这 N 道题」= 选中里显示着作答的那几道，从其中第一道练起。和「再做一次」一样只管这一轮
    （App 开着期间），库里记录不动；退出重开后做过的题照旧显示上次结果。在错题本（或它底下某本书 / 某一章）里点
    「全部重做」就是重练错题。
- **列表**：一行一题（题号 / 题干一行纯文本 / 章节 / 页 / 题型 / **我的答案**（同练习页那一份，如「A（错）」）/
  作答次数与对错 / 收藏与错题标记），
  双击 = 从这题开始练；右键：收藏、移出错题本、**设置章节…**（同一本书里的题）、到 PDF 原页、删除。
- 题目集合在打开 / 切回标签时取一次快照（错题本里移出的题这一轮不会突然消失，下次进来才不在）；
  Agent 补了答案（`refreshExercises`）就地刷新当前题。
- **打开时停在哪一道**（2026-10-31，§13）：每次启动后第一次打开某一组 = 接着上次做的往下（`Exercise.resumeIndex`）；
  App 开着期间切回来照旧停在原来那题。

### 4.3 设置

本轮没有设置项。

## 5. 回收站 / 离线镜像 / 备份 / 安卓

- **回收站**：`TrashStore.documentTables` 末尾加 `exercise`、`exercise_attempt`（父在前），删文档时随文档归档；
  `exercise` 有级联子表，恢复用 `OR IGNORE`（同 `document` / `board_note` 的理由）。删习题新增一种条目
  `Trash.Kind.exercises`（`archiveExercises`）。`Counts` 加 `exercise`。
- **关联为同一文档**（`mergeDocument`）：`exercise.document_id` 跟着改到目标文档，否则会被级联删掉。
- **离线镜像**：~~本轮不进 `MirrorFp.specs`~~ → 2026-10-11 第二轮起进（§10.2）。
- **备份**：`VACUUM INTO` 整库，自动包含。
- **安卓**：`Schema.kt` 加同样 DDL、`VERSION = 20`；~~不读不写这两张表~~ → 两种模式都能练（§10）。

## 6. 代码落点

| 层 | 文件 |
|---|---|
| 存储 | `Store/LibraryStore.swift`（DDL + DAO）、`Store/LibraryModels.swift`（`LibExercise` / `LibExerciseAttempt`）、`Store/TrashStore.swift` |
| 纯逻辑 | `App/Exercise.swift`（payload 编解码 / 导入校验 / 去重键 / 判题，只依赖 Foundation） |
| 执行层 | `App/WorkspaceManager+Exercise.swift`、`App/WorkspaceManager+Trash.swift`、`App/TrashModel.swift` |
| 标签 | `App/DocTabModel.swift`、`App/TabsModel.swift` |
| 界面 | `Window/Exercise/*`（含 `ExerciseChapterPicker`「设置章节…」）、`Window/Sidebar/SidebarViewController.swift`、`Reader/Pane/ReaderPaneController.swift` |
| MCP | `MCP/MCPTools+Exercises.swift`、`MCP/MCPFacade+Exercises.swift`、`MCP/MCPTools.swift`（注册）、`MCP/MCPPageMarks.swift` + `MCPTools+Document.swift`（`render_page` 的 `include_marks`） |
| Agent | `skills/unireader-exercise-import/SKILL.md`、`Agent/AgentChat.swift`、`MCP/MCPServer.swift` |
| 安卓 | `android/…/local/store/Schema.kt`、`android/AGENTS.md` |

## 7. 验证

- `spike/exercise-test.swift`（156 项）：建表 / 导入校验（各种不合格输入）/ 去重更新不冲掉收藏与错题 / 判题 /
  作答记录与错题本规则 / 删文档级联 / 回收站归档与恢复 / `mergeDocument` 带走习题；第二批：目录查页 / 章节列回环 /
  章节范围与计数与建树 / 书上的作答只留一条 / 重判 / `user_answer`·`chapter` 校验 / 筛选 / 开发包老库补列；
  做过的题显示哪一次（App 里最近一次优先、书上的作答兜底、按现在的答案判）；错题本按书 / 按章（计数、建树、范围键回环）。
- 回归：`store-test` / `trash-test` / `mirror-fp-test`（specs 不变）。
- `xcodebuild`（`build/dev`）；安卓 `assembleDebug`。
- 🔴 练习界面的手感 / 观感由用户实测。

## 8. 本轮不做

判断题；~~填空 / 解答题~~（2026-10-13 做了，§11）；~~平板（安卓模式1 / 网页）练习与离线镜像同步~~（安卓两种模式 + 离线镜像见 §10，网页采集页仍不做）；乱序 / 计时 / 正确率统计图表；
「连续答对 N 次自动移出错题本」（用户选了只能手动出）；页面上标出已识别的题（PDF 上的框）；~~题目笔记~~（2026-10-27 做了，§12）。

## 9. 实现记录（2026-10-10）

### 9.1 与方案的出入

- 页内先后 `seq` 不直接用 Agent 给的下标：命中去重的题保留原位置，新题接在**这一页已有的题后面**（按这一批的顺序）。
  这样一页分两次导（先前半页再后半页）顺序也对。
- 「移出错题本」按钮不只在错题本里出现：任何范围里，只要这道题在错题本里就有。
- 练习页的题目集合是快照：错题本里移出的题、取消收藏的题这一轮还留着，下次打开才不在；Agent 新导进来的题接在末尾。
- 「原题」：有 `region` 渲那一块（四周各放 1.5% 页宽），没有就渲整页；渲不出来（文件不在）就不显示。
- MCP 的题型 / 答案写法：`type` 写 `single` / `multiple`（可省，按答案个数推），`answer` 写 `"B"` / `"AC"`，`has_figure` 对应 payload 的 `figure`。

### 9.2 实测清单（用户）

1. 让 Agent（面板里的 Kimi，或 Claude Code 接 MCP）识别某几页的选择题 → 侧栏出现「习题」一段，题数对。
2. 公式、多行题干、带图的题（原题截图默认摆出来）显示是否正常；`region` 框得准不准。
3. 单选点一下即判；多选勾完「提交」；A~H / Return / ← → 键盘操作；判完对错标记、解析、「Agent 推算」提示。
4. 答错 → 侧栏「错题本」数字 +1；「移出错题本」后 -1；答对不会自动移出。
5. 收藏、列表页双击 / 右键、删除后在回收站里能放回来。
6. 切到别的标签再切回来，停在原来那题；退出重开，习题标签还在。
7. 「到 PDF 原页」跳到对的页和位置。
8. 先导题目、后让 Agent 按答案页补答案：练习页当场刷新出答案。

### 9.3 第二批：章节 / 书上的作答 / 筛选（2026-10-11）

- 方案见 §2.3 / §2.4 / §4.2。两列补进 v20（`exercise.chapter`、`exercise_attempt.source`），CREATE 里写在表尾、
  另有 `addColumnIfMissing`（开发包已建过表的库），安卓 `Schema.kt` DDL 与 `ADD_COLUMNS` 同序跟上，`assembleDebug` 通过。
- 侧栏章节树的顺序按「最早一道题的页码」，不读目录（侧栏不开 PDF）；目录只在导入时（MCP 层，`MCPDocReader`）
  和「设置章节…」时（`ExerciseOriginal.chapters`，自己一份 PDF + 串行队列）读。
- `render_page` 的 `include_marks`：笔迹走 `InkRenderCG`、线宽按 800pt 页宽折算；高亮按三种样式简画；隐藏图层不画；
  开着这篇的标签先 `flushPersist()`。
- 实测再加几条：
  9. 有目录的书：导入后侧栏能展开成章节树，数对；点章 / 点节练的题对；「未分章节」行。
  10. 列表右键「设置章节…」：按页码自动 / 不设 / 选目录里一节 / 手填「第二章 › 2.3」。
  11. 顶上筛选：没做过 / 错题 / 收藏，与章节组合。
  12. 高亮作答过的页：让 Agent 认出 `user_answer` → 书上答错的进错题本；练习页判完显示「你在书上选的是…」。
  13. 手写作答：Agent 用 `render_page include_marks` 能看到笔迹（隐藏的图层不出现）。

### 9.4 做过的题显示自己的答案（2026-10-11）

- 方案见 §4.2。库里只加读：`ExerciseAttemptStats.lastAnswer` / `lastAt`（App 里练的最近一次，`source <> 'mark'`），
  没改表。挑哪一次、怎么判在 `Exercise.earlierAnswer`（纯函数，spike 覆盖）；`ExerciseDeck.answer(for:)`
  先看这一轮、再看它，点过「再做一次」的题这一轮不再显示以前的。列表的「作答」列中文改叫「次数」，免得和「我的答案」混。
- 实测再加几条：
  14. 退出重开（或换个范围）后翻到做过的题：显示上次选的、对错、答案、解析和「那次的时间 · 共做几次」；没做过的题照常作答。
  15. 只有书上作答的题：结果那行是「书上的作答：…」，下面不再重复「你在书上选的是…」。
  16. 「再做一次」后能重答，答完显示这一次的结果；列表「我的答案」列跟着变。
  17. 批量重做：在错题本里点顶栏「全部重做」→ 跳到第一题、全部可以重答，「本轮已做」从 0 算；
      列表多选右键「重做这 N 道题」→ 跳到选中的第一道，没选中的题照旧显示上次结果；
      没有任何题显示着作答时「全部重做」是灰的。
  18. 只用一个习题标签：侧栏依次点「全部习题」「某本书」「某一章」「收藏」→ 始终是同一个标签在换，切回之前那组停在原来那题；
      点「错题本」→ 另开一个标签，再点别的组回到公用标签；右键某一章「在新标签页中打开」→ 单独一个标签，
      之后点别的组它不变；退出重开，公用 / 单独 / 错题本三种标签都还在、行为不变。
      某本书删掉 → 开着它（或它某一章）的习题标签跟着退。
  19. 错题本展开：底下是有错题的书 → 章节树，数是错题数；点书 / 章都在同一个错题标签里换，和练习的公用标签互不影响；
      书 / 章右键「在新标签页中打开」单独开；移出错题本后侧栏的数跟着减，这一轮标签里那道题还在。

### 9.5 侧栏管哪一组题，顶栏只留「只看没做过」（2026-10-11 第三次调整）

- 用户看截图提的：侧栏和顶栏两处不统一，「选了错题后还显示分类筛选就有点问题了」。分析下来是两个维度混在一起：
  侧栏既按出处分（全部 / 书 / 章）又按状态分（错题本 / 收藏，错题本还按书 / 章展开），顶栏的筛选按的也是状态 →
  同一组题两条路能到、开在不同标签里；错题本里筛「错题」等于没筛、「没做过」永远是空的。
- 给了两个方案，用户选「侧栏放题集，顶栏只留进度」（另一个是侧栏只按出处分、状态全放顶栏，要推翻错题本按书 / 按章展开
  和错题单独一个标签，没选）：
  - 错题本、收藏都是自己维护的本子，当成和书并列的题集放侧栏；**收藏补上按书 → 章展开**，与错题本同一套规则（§4.1）。
  - 顶栏下拉框换成「只看没做过」开关；错题本那一支不显示（`ExerciseDeck.offersUnansweredFilter`，平板发来的也不认）。
  - `ExerciseFilter` 只剩 `all = 0` / `unanswered = 1`，`2` / `3` 不再用（老平板发来就丢）。
  - 线上：`exDeck` 尾部多一个可选字节 `noFilter`（1 = 这一组没有这个开关），平板据它藏开关——范围键对平板是不透明的串，
    不该由平板自己去认「是不是错题本」；范围键多两种前缀 `starred:doc:` / `starred:chap:`（`PROTOCOL.md §4.9`）。
  - 安卓两模式同改：`Exercise.kt` 范围 / 计数 / 分组照抄，`LocalExerciseDeck` 同样挡掉错题本里的开关，
    共用顶栏 `ExerciseScreen` 的下拉换成开关（`ExDeckView.noFilter` 为真时不显示）。
- 验证：Mac Debug 编译通过；`spike/exercise-test.swift` 168 项全过（新加收藏按书 / 按章 10 项、分组 2 项、筛选改 1 项）；
  `spike/wire-codec-test.swift` 127 项 + `spike/wire-cross-test.js` 243 项全过（向量 120 → 121 条：#116 的 filter 由 2 改 1、
  #116 / #117 末尾多一个 `00`，新加 #121 = 错题本那一支 noFilter = 1；另验「老 Mac 不带尾部照样解得出」）。
  安卓 `assembleDebug` 通过，JVM 单测 18 组 157 项全过（`ExerciseTest` / `WireCodecTest` 跟着改）。🔴 界面没实际跑过。
- 实测再加几条：
  27. Mac：书 / 章 / 全部 / 收藏的标签顶栏有「只看没做过」，按下高亮、只剩没做过的题，再按一下回到全部；
      错题本（含它底下的书 / 章）顶栏没有这个开关。这里的题都做过时，练习页写「这里的题都做过了。」
  28. 收藏几道不同章节的题 → 侧栏「收藏」能展开成书 → 章，数对；点书 / 章在公用标签里换，标题是「收藏 · 书名 · 章名」；
      取消收藏后数跟着减。
  29. 平板（模式1 / 模式2）同上两条；模式2 在 Mac 和平板开着同一组时，任一边按「只看没做过」两边一起变。

## 10. 安卓：模式1 + 模式2 + 离线镜像（2026-10-11 第二轮）

用户原话：「平板上两个都做吧」。两条拍板：

- **模式2**：「mac 和 pad 同步，但是 tab 页可以不一样，比如 macOS 显示 pdf，pad 显示练习题，也是可以的」。
  → 数据只有 Mac 一份；平板可以自己开一组题，Mac 不跟着换；两边开着**同一组**题时，答了什么、翻到第几题、筛选都同步。
- **公式**：「安卓自带控件画」→ Markwon + JLaTeXMath（`android/app/build.gradle.kts`，依赖由用户下载）。
  题干 / 选项 / 解析画在普通 `TextView` 里；`$…$` 行内、单独成行的 `$$…$$` 成块（同 Mac 引擎的写法）。

### 10.1 共用的界面（`android/…/shared/exercise/`）

- 只认一份中立数据 `ExCard`（一道题的内容 + 该显示的作答 + 统计）/ `ExDeckView`（一组题 + 第几题 + 筛选 + 这一轮做了几道），
  操作经宿主接口 `ExHost` 交出去：**模式1 本机算、写本机库；模式2 由 Mac 算好发来、操作发回 Mac**。界面一行不分叉。
  `ExCard` 的字段与线上 `exDeck`（`PROTOCOL.md §4.9`）一一对应——Mac 怎么算「该显示哪次作答」，模式1 就照同一份规则在本机算。
- 顶栏：范围名 + 进度 + 全部重做 + 只看没做过（开关，错题本那一支不显示，§9.5）+ 练习 / 列表。
- 练习：同 Mac §4.2（单选点即判、多选勾完提交、判完对错标记 + 结果那行 + 「上次作答」时间与次数 + Agent 推算提示 +
  书上的作答 + 解析、再做一次、移出错题本、收藏、看原题、到 PDF 原页、上一题 / 下一题、左右滑翻题）。
- 列表：一行一题（题号 / 题干一行 / 章节 / 页 / 我的答案 / 次数）；点一行从这题练；长按进多选，底下「重做这 N 道题」
  （模式1 另有「设置章节…」）；单行长按菜单：收藏、移出错题本、到 PDF 原页。
- 抽屉多一页「习题」（目录 / 书库之后，`ReaderDrawer.setExercises`，两模式共用；**工作区有题才出现**，同 Mac）：
  同 Mac 侧栏——全部 / 错题本（按书 → 章展开）/ 收藏（按书 → 章展开）/ 每本书 → 章节树，行尾是数，可展开收起（默认收起，当前那组的上级自动展开）。
  不塞进书库页：章节树一长，书库那几行就被挤到下面去了。
  摊平成「一行一个范围 + 缩进层级」的一列（`ExGroup`），模式1 本机建、模式2 是 Mac 下发的 `exGroups`。
  建这一列的规则只有一份（Mac `ExerciseGroupNode.build`，侧栏也改用它），安卓模式1 `ExGroupNode.build` 逐条照抄。

### 10.2 模式1（平板本机打开工作区）

- 纯逻辑 `local/exercise/Exercise.kt`：逐条对应 Mac `Exercise.swift` 里练习要用的那部分（payload 解码、判题、范围键与
  `includes`、筛选、章节树、`earlierAnswer`、侧栏分组）；JVM 单测 `ExerciseTest` 对应 `spike/exercise-test.swift` 的同名几段。
- 读写在 `local/store/LibraryStore`（经 `StoreQueue`），SQL 与 Mac 逐字一致：作答一行 = 大写 UUID + ISO 毫秒 UTC 时间；
  答错同一个事务进错题本；收藏 / 移出错题本 / 设章节都改 `updated_at`。
- 一组题的进度（`LocalExerciseDeck`）照 Mac `ExerciseDeck`：按「工作区 + 范围」存在进程里，快照、这一轮的作答、
  再做一次、筛选、库变了就地刷新，规则全同。
- 标签页：docId 存 `ex:<范围键>`（公用）/ `exs:<范围键>`（单独开的），同 Mac `StoredTab`：抽屉里点哪组都在公用标签里换，
  错题本那一支另一个；长按「在新标签页中打开」单独开。
- 看原题：本机 Pdfium 渲那一块（四周放 1.5% 页宽，同 Mac）。到 PDF 原页：开那篇的标签、跳到题目框上沿。
  设置章节：按页码自动 / 不设 / 目录里一节 / 手填（「›」分级），目录取那本书的 PDF 自带目录（`PdfSource.toc`）。
- **不做**：删习题（安卓没有回收站，删只在 Mac 做，红线 11）；导入（识别是 Agent 在 Mac 上做的）。

### 10.3 离线镜像

- `exercise`、`exercise_attempt` 进 `MirrorFp.specs`（Mac `MirrorFingerprint.swift` ↔ 安卓 `MirrorFp.kt`，列序 = 建表顺序，
  向量表 `spike/mirror-fp-vectors.txt` 尾部追加）。`exercise` 按 `updated_at` 取新；`exercise_attempt` 没有修改时间，
  两边都改了同一条（只有 Mac 重判会改它）→ 保留源盘那份。
- 两边各做的题、各自的作答**按行并起来**，不会互相覆盖（这正是 §2.2 把作答单独成表的理由）。
- 父题已删的作答不写（同画板的 `livingBoards`），否则外键挡下整次同步。

### 10.4 模式2（平板连 Mac）

- **一份进度两边共用**：平板开某一组题 = 用 Mac 上**同一个** `ExerciseDeck`（工作区 + 范围）。所以两边开着同一组时，
  作答、第几题、筛选天然同步；Mac 在看 PDF 时平板照样能做题。平板上的「练习 / 列表」切换各管各的。
- 入口：
  - 抽屉「习题」一段（Mac 下发 `exGroups`：被跟随会话所在工作区的分组）；点一行 = **平板自己的习题标签**
    （标签栏末尾一个，可以关；再点别的组就在这个标签里换），Mac 不切。
  - Mac 当前标签就是习题（`boards.kind = 3`，`current` = 范围键）：平板跟随时显示那一组（同 PDF / 画板的跟随）。
  - 点标签栏上 Mac 的标签 = 回到跟随 Mac；平板自己的习题标签留在栏上，点回来接着做。
- 看原题：`GET /exercise.png?id=<题 id>&w=<像素宽>`，Mac 渲（同 Mac 本机那块），只认平板正开着的那组里的题。
- 到 PDF 原页：发给 Mac，Mac 打开那篇、跳到那页，并把平板锁到那个标签。
- 协议 `PROTOCOL.md §4.9`（`exGroups` 0x5E / `exOpen` 0x5F / `exDeck` 0x60 / `exIndex` 0x61 / `exAct` 0x62）。
- Mac 侧：`AppModel+Exercise.swift`（下发 / 收操作）；`ExerciseDeck` 每次变化发 `ExerciseDeck.changed`，
  平板发来的改动由开着同一组的 Mac 标签据它重画，Mac 本机的改动由它推给平板。

### 10.5 代码落点（第二轮）

| 端 | 文件 |
|---|---|
| Mac | `App/Exercise.swift`（`ExerciseGroupNode`）、`Window/Exercise/ExerciseDeck.swift`（变化通知、按 id 交卷）、`ExerciseTabView.swift`（平板改动后重画）、`App/AppModel+Exercise.swift`（新）、`App/AppModel.swift`（分发 + `/exercise.png`）、`App/AppModel+Board.swift`（`boards.kind = 3`）、`App/DocSession.swift` / `DocTabModel.swift`（会话记着习题范围）、`Server/LANServer.swift`、`Server/WireCodec.swift`、`Resources/wire.js`、`Store/MirrorFingerprint.swift`、`Store/MirrorDiff.swift` / `MirrorApply.swift` |
| 安卓共用 | `shared/exercise/*`（`ExModel` 中立数据 + `ExHost` / `ExerciseScreen` 顶栏 + 练习页 + 列表页 / `MathText` 公式）、`shared/ReaderDrawer.kt`（「习题」页）、`shared/DocTabsBar.kt`（逐个标签能不能关）、`tools/icons/gen.py`（`exercise` / `star` / `image`） |
| 安卓模式1 | `local/exercise/*`（`Exercise.kt` 纯逻辑 + `LocalExerciseDeck`）、`local/ExerciseController.kt`（`ExHost` 实现：写库 / 原题图 / 设章节）、`local/store/LibraryStore.kt`、`local/ReaderActivity.kt`、`local/TabSet.kt`、`local/store/MirrorFp.kt` + `local/mirror/*` |
| 安卓模式2 | `pad/WireCodec.kt`、`pad/MacClient.kt`、`pad/PadActivity.kt`、`pad/RemoteExHost.kt`（新） |
| 测试 | Mac `spike/exercise-test.swift`（分组）、`spike/wire-codec-test.swift` + 向量、`spike/mirror-fp-test.swift` + 向量、`spike/mirror-apply-test.swift`（⑤b 习题）；安卓 `ExerciseTest` / `WireCodecTest` / `MirrorFpTest` |

### 10.6 实现记录与验证（2026-10-11）

- 与方案的出入：抽屉里「习题」单独成一页（不塞进书库页，§10.1）；`ExHost.loadOriginal` 模式1 是「本机出整页再裁框」，
  框四周放 1.5% 页宽，与 Mac 同；列表页的单行操作并进了长按多选的底栏（选中一道时多出收藏 / 移出错题本 / 到 PDF 原页）。
- Mac：Debug 编译通过；`spike/exercise-test.swift` 156 项全过（新加分组 7 项）；`spike/wire-codec-test.swift` 125 项 +
  `spike/wire-cross-test.js` 240 项全过（向量 112 → 120 条，前 112 条一个字节没变）；`spike/mirror-fp-test.swift` 62 项全过
  （向量 29 → 31 条，尾部追加）；`spike/mirror-apply-test.swift` 55 过 1 不过——不过的是「上次打开取了较晚的那个」，
  **改动之前就不过**（基线 49 过 1 不过），与这次无关、没碰。
- 安卓：`assembleDebug` 通过；JVM 单测全过（`ExerciseTest` 14、`WireCodecTest` 12、`MirrorFpTest` 6，其余原有的照旧）。
  数据层（`LibraryStore` 习题一节）只能在设备上验，**没写插桩测试、没在设备上跑过**。
- 公式库 Markwon 4.6.2 + ext-latex + inline-parser（传递依赖 JLaTeXMath），由用户下载（代理 IP 会让 Maven 中央仓库回 403）。
- 🔴 界面全部没实际跑过，手感 / 观感由用户实测。

实测清单（用户）：

  20. 模式1：开一个有题的工作区 → 抽屉多出「习题」一页，分组、数、章节树与 Mac 侧栏一致；点哪组都在一个习题标签里换，
      错题本那一支另一个；长按一组「在新标签页中打开」；退出重开标签还在。
  21. 模式1 练习：公式显示（行内 / 单独成行）、单选点即判、多选提交、左右划翻题、做过的题直接显示上次结果、再做一次、
      全部重做、筛选、收藏、移出错题本、看原题（框得准不准）、到 PDF 原页（跳到题目那一处）。
  22. 模式1 列表：点一行从这题练；长按多选 → 重做这 N 道题 / 设置章节（按页码自动 / 不设 / 目录里一节 / 手填）。
  23. 离线副本：平板上做题 + 收藏，接回 Mac 同步 → Mac 上作答次数、上次作答、收藏、错题本都对；两边各做过的都在。
  24. 模式2：Mac 看 PDF，平板抽屉「习题」点一组 → 平板标签栏末尾多一个习题标签，Mac 不动；点回 Mac 的标签回到跟随；× 能关。
  25. 模式2 同步：Mac 也开同一组 → 两边翻题互相跟、在平板答的 Mac 上马上显示、筛选两边一起变；Mac 切到习题标签时平板跟随显示。
  26. 模式2：看原题图、到 PDF 原页（Mac 打开那一篇、平板回到跟随并停在那一页）。

## 11. 第三轮：填空题 + 主观题（2026-10-13，schema v21）

用户原话：「开始给习题练习识别做一下填空支持，以及主观题支持，主观题只提供参考答案，不对比正确，用户自己选答对了还是错了，
支持填写答案，支持手写（一个内置小画板）支持 agent 读取，然后 agent 可以判断用户答案。」

四条拍板（用户 2026-10-13 选的，都是推荐项）：

1. **填空能自动判就自动判**：每空规整后与参考答案（可给几种等价写法）一致 → 直接判对；有对不上的空 → 亮出参考答案，
   由用户点「对 / 错」。**不直接判错**——`1/2` 和 `0.5` 这类等价写法程序认不出。
2. **本轮只做 Mac**：安卓只同步表结构（`Schema.kt` v21 + 镜像列规格），平板上新题型只显示题干、提示到 Mac 上作答；
   平板上作答与手写放下一轮。
3. **练习页加「让 Agent 批改」按钮**：把题号这句话放进这扇窗 Agent 页的输入框（手写附成图片），用户自己点发送。
4. **后判的为准**：一次作答只留一个结论，Agent 判了覆盖自己判的（带评语），用户不同意可以再改判；判错照旧进错题本。

### 11.1 数据（v20 → v21，跨端契约）

- `exercise.kind`：`3` 填空 · `4` 主观题（`2` 留给判断题）。老版本 App 读到不认识的题型整行跳过，不会出错。
- `exercise.payload`（新键都可选，选择题的 payload 一个字节不变）：

  | 题型 | `answer` | 新键 |
  |---|---|---|
  | 填空 | 每空一个参考答案（按空的先后），空 = 还没有 | `blanks`：空数（没答案时靠它摆输入框）；`accept`：每空**另外**认可的写法（与 `answer` 等长，全空不写这个键） |
  | 主观题 | 恰一个元素：参考答案正文（Markdown + 公式），空 = 还没有 | — |

  填空的参考答案「要么每空都给、要么都不给」（MCP 校验）；`answer_source` 规则同选择题。
- `exercise_attempt` 表尾加三列（`addColumnIfMissing`，安卓 `ADD_COLUMNS` 同序；也是 `MirrorFp.specs` 的列序）：

  ```sql
  ink BLOB,                                -- 手写（ExerciseInk JSON），没写 = NULL
  judged_by TEXT NOT NULL DEFAULT '',      -- '' 程序判（或还没判）/ 'self' 自己判 / 'agent' Agent 判
  feedback TEXT NOT NULL DEFAULT ''        -- Agent 批改的评语（Markdown）
  ```

  `answer` 列：选择题照旧（键拼起来）；填空 = JSON 字符串数组（每空一格，没填的是空串）；主观题 = 写的文字。
  `correct` NULL 的含义扩成「还没判」（没答案没法判，或等自己判 / Agent 判）。
- 手写 `ExerciseInk`：`{"width":600,"height":280,"strokes":[{"width":2.6,"points":[[x,y,压感],…]},…]}`——
  **逻辑坐标**（宽恒 600，界面按实际宽度等比缩放；高随「加高」每次 +200，最多 1800），点是显式数组（红线 6）。
  一道题的笔画少，不走 v18 的二进制点集。
- **重判**（答案改了）：只重判 `judged_by = ''` 的作答（程序判的那部分）；自己判 / Agent 判过的保持原结论。
  填空原来程序判对的、答案改了对不上 → 回到「还没判」。
- 书上的作答（§2.4）照旧每题至多一条：填空走 `user_blanks`（每空一格）、主观题 `user_answer`（Agent 转写的文字），
  程序能判的判上，其余等自己判或 Agent 批改。

### 11.2 Mac 练习页

- 选项那一块换成作答区 `Window/Exercise/ExerciseFreeAnswerView`：
  - **填空**：每空一行「第 N 空 + 输入框」，回车跳下一空、最后一空回车 = 提交；交卷后锁住，对得上参考答案的空标绿勾，
    最终判错时对不上的标红叉。
  - **主观题**：多行输入框（`$…$` 写公式，随内容长高到 320 点），⌘Return 提交；交卷后换成渲染好的「你的作答」。
  - **手写**（两种题型都有）：「手写」开关 → 笔 / 橡皮（整笔擦）/ 撤销 / 清空 / 加高 + 白纸小画板
    （`ExerciseInkPad`：鼠标 / 触控板按压感 0.5 画，数位板用真实压感）。开没开记在本机，下一题照旧。
  - 没交的输入按题存在 `ExerciseDeck.drafts`：翻到别的题、切标签再回来，写了一半的还在。
  - 交卷后亮出参考答案（填空每空一行，另外认可的写法跟在后面）。
- 判题与结果那一行：程序判对 →「每个空都和参考答案一致，正确」；还没判 → 说清楚为什么、该怎么办
  （填空有空对不上 / 主观题请对照参考答案 / 还没有参考答案），下面 **「答对了」「答错了」**；判过的 → 「你判为… / Agent 判为…」，
  下面 **「改判为错误 / 正确」**。有 Agent 评语就在下面显示（Markdown）。做过的题照旧直接显示上次那次（§4.2），
  对错用库里记的（自己判 / Agent 判的没法现算）。
- **「让 Agent 批改」**（Agent 开着、这扇窗开了工作区才有）：`AgentPanelModel.prepare` 往这扇窗 Agent 页的输入框放一句
  「请批改我这道题的作答（第 N 题）：判断对错，并说明哪里需要改进。」，手写附成 PNG，题目 / 作答的 id 放进**隐藏上下文块**
  （`AgentChat.contextNotes`，随下一次发送带走）；Agent 页亮出来，用户点发送。
- 列表：「题型」列多「填空 / 主观题」；「我的答案」列填空显示 `2 / 1/2`、主观题显示正文一行、只手写的显示「手写」，
  还没判的标「（未判）」。

### 11.3 判定的规则（`Exercise.autoJudge` / `ExerciseDeck.judge` / `LibraryStore.judgeExerciseAttempt`）

- 填空的规整（`Exercise.normalizeBlank`，**只做肯定等价的变换**）：NFKC（全角转半角）、去掉 `$` 和全部空白、
  `\dfrac` / `\tfrac` → `\frac`、去掉 `\left` `\right` 与 `\,` `\;` `\!` `\ `、去掉句末标点；**不并大小写**
  （宁可交给人判，也不把错的判成对）。每空与「参考答案 + accept」任一个一致即对得上；全对得上 → 判对，否则还没判。
  只写在画板上的一律交给人判。
- 自己判 / Agent 判都是改**那一条作答**（`correct` + `judged_by`，Agent 还写 `feedback`）；自己改判时 Agent 的评语保留。
  判错的同一个事务进错题本；判对不移出（拍板 ③）。
- 这一轮答过的题，标签视图刷新时按库里的对错重读一遍（`ExerciseDeck.refreshRoundVerdicts`）：Agent 批改完、答案补上重判了，
  眼前的结果跟着变。

### 11.4 MCP（`MCPTools+Exercises` / `MCPFacade+Exercises`）

| 工具 | 层级 | 变化 |
|---|---|---|
| `import_exercises` | write | `type` 多 `fill` / `subjective`；填空给 `blanks: [{answer, accept}]`，主观题的参考答案写 `answer`；书上的作答：填空 `user_blanks`、主观题 `user_answer`；`options` 不再必填 |
| `list_exercises` | read | 每道题多 `blanks`、`user_blanks`、`ungraded`（还没判的作答次数）；主观题的 `answer` = 参考答案 |
| `update_exercises` | write | 同上可改 `blanks` / `user_blanks`；换了一类题（选择 ↔ 填空 ↔ 主观）时原来的选项 / 空 / 答案没另给就丢掉 |
| `list_exercise_attempts`（新） | read | 作答一览，新的在前：题干、参考答案（一行文字）、作答（文字 / 每空 + 每空对不对得上）、`has_handwriting`、对错与谁判的（`app` / `user` / `agent`）、评语；按 `exercise_ids` / `document_id` 缩小，`ungraded_only` = 只要还没判的填空 / 主观题 |
| `render_exercise_answer`（新） | read | 手写作答出 PNG（白底黑字，默认 1200 像素宽） |
| `grade_exercise_attempts`（新） | write | `[{attempt_id, correct, feedback}]`（≤50），整批先校验、一条不对就都不写；**选择题不收**（程序自己判）；没给评语 = 清掉旧评语 |

- 作答 id 同题目 id：完整或 8 位以上前缀（`LibraryStore.exerciseAttemptPage(prefix:)`）。
- 新的读工具加进 `spike/mcp-schema-audit.py` 的 `READ_CALLS`（`render_exercise_answer` 要工作区里有手写作答才校验得到）。
- `MCPServer.instructions`、Agent 面板上下文串（`AgentChat.exercises`）、`skills/unireader-exercise-import/SKILL.md` 都补了
  填空 / 主观题的导入写法与批改流程。

### 11.5 离线镜像 / 回收站 / 备份

- `exercise_attempt` 的 `MirrorFp.specs` 表尾加三列（Mac ↔ 安卓同序）。向量表 **#31 的编码与 fp 变了**
  （同一行在 10 列规格下多三个 NULL 列，`…1f031f001f001f00`），这是列规格本身变了，不是数据含义变了；新加 #32（主观题作答：
  手写 + Agent 判 + 评语）。⚠️ 旧版 App 借出的离线副本用新版同步时，作答行的基线指纹对不上 → 两边都算「改过」→ 按规则保留源盘，
  安卓本轮不改作答，所以不丢东西。
- 回收站 / 备份按列通用复制，自动带上新列（`trash-test` 71 项照过）。

### 11.6 安卓（本轮只跟契约）

- `Schema.kt` v21（DDL 逐字 + `ADD_COLUMNS` 同序）、`MirrorFp.kt` 列规格、`MirrorFpTest` 向量 #31 / #32。
- 模式1 读得出 3 / 4 两种题（`LibraryStore.exercise`），`ExCard.kind` 带上题型；练习页显示题干 + 「填空题和主观题暂时请在 Mac 上作答。」，
  不能交卷（`LocalExerciseDeck.submit` 挡掉），不显示以前的作答。
- 模式2：Mac 照常在 `exDeck` 里发这两种题（`kind` 3 / 4），但**选项、答案、解析、作答、书上的作答一律不发**（`shown = 0`），
  `exAct` 0 交卷遇到这两种题丢掉。平板同上显示题干 + 提示。线格式没变（`PROTOCOL.md §4.9` 只补了 `kind` 的取值）。
- 下一轮：平板上作答 + 手写（模式1 本机画板；模式2 要扩协议把笔迹 / 文字发回 Mac）。

### 11.7 代码落点

| 层 | 文件 |
|---|---|
| 纯逻辑 | `App/Exercise.swift`（题型、payload 新键、`ExerciseResponse` / `ExerciseInk` / `ExerciseJudge`、`autoJudge` / `normalizeBlank` / `earlierResponse`、导入校验 `validateFree`） |
| 存储 | `Store/LibraryStore.swift`（v21 列、`judgeExerciseAttempt`、`exerciseAttemptPage`、统计多 `lastId` 等）、`Store/LibraryModels.swift`、`Store/MirrorFingerprint.swift` |
| 执行层 | `App/WorkspaceManager+Exercise.swift`（记作答返回 id、判一次作答、书上作答按题型） |
| 界面 | `Window/Exercise/ExerciseFreeAnswerView.swift`（新）、`ExerciseInkPad.swift`（新，含出图 `ExerciseInkRender`）、`ExercisePracticeView.swift`、`ExerciseDeck.swift`、`ExerciseListView.swift`、`ExerciseTabView.swift`、`Reader/Pane/ReaderPaneController.swift` |
| Agent | `Agent/AgentPanelModel.swift`（`prepare`）、`Agent/AgentChat.swift`（`draftRequest` / `contextNotes`）、`Window/AI/AgentChatNSView.swift`（输入框取走那句话） |
| MCP | `MCP/MCPTools+Exercises.swift`、`MCP/MCPFacade+Exercises.swift`、`MCP/MCPTools.swift`、`MCP/MCPServer.swift` |
| 平板下发 | `App/AppModel+Exercise.swift` |
| 安卓 | `local/store/Schema.kt`、`local/store/MirrorFp.kt`、`local/store/LibraryStore.kt`、`local/exercise/Exercise.kt` / `LocalExerciseDeck.kt`、`shared/exercise/ExModel.kt` / `ExerciseScreen.kt`、`pad/WireCodec.kt`、`res/values*/strings.xml` |

### 11.8 验证（2026-10-13）

- `spike/exercise-test.swift` 258 项全过（新加 90 项：题型、填空 / 主观题校验、payload 编码不影响老题、规整与判题、
  作答编解码、自己判 / Agent 判 / 改判、重判跳过人判过的、统计、作答一览、update 起点还原、老库补列）。
- `spike/exercise-free-answer-test.swift`（新，离屏）48 项全过：画板（合成鼠标事件写 / 擦 / 撤销 / 清空 / 加高 / 只读）、出图、
  填空作答区（草稿回填、回车跳空与提交、交卷后锁住与对错标记、参考答案）、主观题作答区（手写开关、交卷后的显示）、子视图不重叠；
  出了浅色 / 深色样张自查过排版。
- 回归：`mirror-fp-test` 63 项、`trash-test` 71 项、`store-test` 54 项全过；`mirror-apply-test` 55 过 1 不过（就是 TODO 里那条
  「上次打开取了较晚的那个」，改动前就不过）。
- Mac Debug 编译通过、无新警告；安卓 `assembleDebug` 通过，JVM 单测 158 项全过（`ExerciseTest` 新加一组、`MirrorFpTest` 向量跟上）。
- 🔴 练习页整体、MCP 三个新工具、「让 Agent 批改」都没有在真 App 里跑过（不替用户实测），由用户实测。

### 11.9 实测清单（用户）

  30. 让 Agent 识别有填空题 / 计算题的几页 → 侧栏数对；列表「题型」列显示「填空 / 主观题」。
  31. 填空：每空一个输入框，回车跳下一空、最后一空回车提交；全对 → 直接判对、空旁绿勾；写成另一种写法（如 `0.5`）→
      显示参考答案，点「答对了 / 答错了」；判错进错题本。
  32. 主观题：多行输入框写公式，⌘Return 提交；交卷后看到渲染好的「你的作答」+ 参考答案；点「答对了 / 答错了」；「改判」。
  33. 手写：打开「手写」，鼠标 / 触控板 / 数位板写字、橡皮、撤销、清空、加高；下一题手写照开；交卷后画板只读显示。
  34. 写了一半翻到别的题再翻回来（或切标签再回来），输入和手写都还在。
  35. 「让 Agent 批改」：Agent 页亮出来，输入框里有那句话、手写附成图；点发送 → Agent 读作答、写回对错和评语 →
      练习页当场显示「Agent 判为…」和评语；不同意可以改判。
  36. 让 Agent「批改今天做的主观题」（不点按钮，直接在面板里说）→ 它用 `list_exercise_attempts ungraded_only` 找到并批改。
  37. 平板（模式1 / 模式2）：新题型只显示题干 + 「填空题和主观题暂时请在 Mac 上作答。」，选择题照常。

## 12. 第四轮：题目笔记 + 重做上次做错的（2026-10-27，schema v22）

用户原话：「题目补充文字笔记（备注）：这样可以给错题补上笔记」「加一个 重做上一次做错的，这样可以继续做没有做对过的题，错题，
以及做过一次正确的就可以不做」。

三条拍板（用户 2026-10-27 选的，都是推荐项）：

1. **挑「最近一次是错的」**：看每道题最近一次的结果（就是练习页上显示的「上次作答」）——错的进、对的不进。
   答对一次下次就不再出现；答对过、后来又做错的也会进来。还没判对错的（主观题等自己判、题目没答案）不算错。
   （另一个选项是「从来没答对过」，没选。）
2. **本轮只做 Mac**：安卓只跟表结构（`Schema.kt` v22）+ 离线镜像把笔记带过去；平板上看不到笔记、没有这个开关，放下一轮。
3. **笔记判完才显示**（同解析）：作答之前不显示，免得重做错题时笔记先把答案剧透了。

### 12.1 题目笔记

- **数据**：`exercise` 表尾加一列 `note TEXT NOT NULL DEFAULT ''`（`addColumnIfMissing`，安卓 `ADD_COLUMNS` 同序；也是 `MirrorFp.specs`
  的列序）。一道题一段，Markdown + `$…$`，空串 = 没写。和收藏 / 错题一样是**用户状态**：`upsertExercise` 的 `ON CONFLICT` 不碰它，
  Agent 重导题目冲不掉；只经 `LibraryStore.setExerciseNote` 写（同时改 `updated_at`，离线镜像按它取新）。
- **练习页**（`Window/Exercise/ExerciseNoteView`）：判完后在解析下面——没写过只有「添加笔记」；写过是「笔记」标题 + 渲染好的笔记 +
  「编辑笔记」。编辑 = 多行输入框（随内容长高到 320 点）+「完成」。**边写边存**（停手 0.8 秒存一次，没变不写），
  「完成」/ ⌘Return / Esc 收起；输入框失去焦点、换题、「再做一次」、切走标签时都先存下。没有「取消」——字已经存了，改回去用 ⌘Z。
- **列表**：多一列「笔记」（一行），同练习页的规则——显示着作答的题才露出笔记，「重做上次做错的」里还没重做的题这一列是空的。
- **MCP**：`list_exercises` 每道题多 `note`（没写就不带这个键）；`update_exercises` 可以给 `note`（整段替换，空串 = 删掉），
  说明里写明**只在用户要求时写**（`MCPServer.instructions`、Agent 面板上下文串、`skills/unireader-exercise-import/SKILL.md` 同）。
  `import_exercises` 不收它。写入经 `WorkspaceManager.saveExercise`：笔记变了另调 `setExerciseNote`。
- 它和 PDF 上的文字笔记（批注，`note` 表）是两回事：界面上叫「笔记」，英文键用 `Add a Note` / `Edit Note` / `My Note`
  （`Add Note` / `Note` 已被批注占用、中文是「添加批注」「批注」）。

### 12.2 重做上次做错的

- **规则**（`Exercise.lastResultWrong`，纯函数，spike 覆盖）：选择题看 `earlierAnswer(stats).correct == false`，
  填空 / 主观题看 `earlierResponse(stats).correct == false`——和练习页挑「上次作答」是同一份规则（App 里练的最近一次优先，
  没练过才看书上的作答；选择题按现在的答案现判）。
- **筛选值** `ExerciseFilter.lastWrong = 4`（`2` / `3` 是去掉的错题 / 收藏，不许再分配）。`includes` 改成收这道题的统计。
- **顶栏**：「全部重做」右边多一个开关「重做上次做错的」（按下时高亮），与「只看没做过」至多开一个（同一个 `ExerciseDeck.filter`）。
  **哪一组都有**，错题本里也有——错题本里的题只能手动移出，所以里面有答对过的；开这个开关正好挑出还没做对的。
  这一组里一道上次做错的都没有时它是灰的（开着时总能关）；提示里写这一组有几道。
- **开 = 重做一轮**（`ExerciseDeck.startLastWrongRound`）：按此刻的统计重挑一遍，这一轮在它们上答过的清掉，切到练习页、从第一道练起。
  开着时以前的作答一律不显示（`answer(for:)`），所以挑出来的都等着重新作答。这一轮答对的照旧留在眼前（不会突然消失），
  下次再挑就不在了。开着时点「全部重做」= 再挑一遍（不把这一轮答对的拉回来）。关掉 = 回到全部，这一轮答的照旧显示。
- 只管 App 开着期间（同「全部重做」）；退出重开后开关是关着的。
- **平板**：`exDeck.filter` 可能发 `4`；老平板只认 `1`，按「全部」显示开关状态，看到的是同一份挑出来的题（`PROTOCOL.md §4.9`）。
  平板发 `exAct` 4 带 `0` / `1` 照旧，会把 Mac 这边的开关一起关掉。

### 12.3 代码落点

| 层 | 文件 |
|---|---|
| 存储 | `Store/LibraryStore.swift`（v22 列、`setExerciseNote`、`upsertExercise` 不碰笔记）、`Store/LibraryModels.swift`、`Store/MirrorFingerprint.swift` |
| 纯逻辑 | `App/Exercise.swift`（`Exercise.note`、`lastResultWrong`、`ExerciseFilter.lastWrong`） |
| 执行层 | `App/WorkspaceManager+Exercise.swift`（`setExerciseNote`、`saveExercise` 带笔记） |
| 界面 | `Window/Exercise/ExerciseNoteView.swift`（新，离屏测试 `spike/exercise-note-test.swift`）、`ExercisePracticeView.swift`、`ExerciseDeck.swift`、`ExerciseTabView.swift`、`ExerciseListView.swift` |
| MCP / Agent | `MCP/MCPTools+Exercises.swift`、`MCP/MCPFacade+Exercises.swift`、`MCP/MCPServer.swift`、`Agent/AgentChat.swift`、`skills/unireader-exercise-import/SKILL.md` |
| 安卓 | `local/store/Schema.kt`（v22）、`local/store/MirrorFp.kt`、`MirrorFpTest`（向量 #30 改 / #33 新） |

### 12.4 验证（2026-10-27）

- `spike/exercise-test.swift` 280 项全过（新加 22 项：笔记列新建能写 / 重导不冲掉 / `setExerciseNote` 改 `updated_at` / 删掉 /
  老库补列；「上一次的结果是错的」各种情形：没做过、错、错后对、对后错、只有书上的、书上错练对、没答案、答案改了、主观题判错 / 没判 / 判对、
  库里真记几次作答；筛选值 0 / 1 / 4）。
- `spike/mirror-fp-test.swift` 64 项全过；向量 33 → 34 条：**#30 的编码与 fp 变了**（同一行在 15 列规格下多一个 NULL 列，
  末尾多 `1f00`），这是列规格本身变了，同 §11.5 的 #31；新加 #33（写了笔记的那一行）。⚠️ 旧版 App 借出的离线副本用新版同步时，
  `exercise` 行的基线指纹对不上 → 两边都算「改过」→ 按 `updated_at` 取新，内容一样，不丢东西。
- `spike/exercise-note-test.swift`（新，离屏）26 项全过：三种样子、边写边存（停手 0.8 秒存一次、没改不再存）、正在写时库里变了不动输入框、
  「完成」/ Esc / 换题（按原来那道题的 id 存）/ 失去焦点 / 离开窗口都先存下、只写空白不存、输入框随内容长高、排版不重叠；
  出了浅色 / 深色样张自查过（离屏截图画不出公式图，位置是留出来的）。
- Mac Debug 编译通过、改动的文件没有新警告；回归 `trash-test` 71 项、`store-test` 54 项全过，`mirror-apply-test` 55 过 1 不过（TODO 里那条老的）。
- 安卓 `assembleDebug` 通过，JVM 单测 158 项全过（`MirrorFpTest` 列表 + 向量 #30 / #33 跟上）。
- 🔴 练习页的笔记、顶栏开关都没有在真 App 里跑过（不替用户实测），由用户实测。

### 12.5 实测清单（用户）

  38. 做完一道题（或翻到做过的题）：解析下面有「添加笔记」；写几行（含 `$…$` 公式）→ 停一下、点「完成」/ ⌘Return / Esc 收起，
      显示渲染好的笔记 +「编辑笔记」；写到一半直接翻下一题 / 切标签再回来，写的还在。
  39. 没作答的题（或点了「再做一次」）看不到笔记；列表「笔记」列只在显示着作答的题上有字。
  40. 让 Agent「给这道错题写个笔记」→ 它用 `update_exercises` 的 `note` 写，练习页当场显示；Agent 重导题目后笔记还在。
  41. 顶栏「重做上次做错的」：按下 → 只剩上次做错的题、都能重新作答、从第一道开始；答对几道后关掉再按一次 → 答对的不在了；
      和「只看没做过」互斥；一道错题都没有时是灰的；错题本里也有这个开关。
  42. 开着「重做上次做错的」点「全部重做」→ 重新挑一遍（这一轮答对的不再出现）。
  43. 平板（模式2）开着同一组：Mac 按下开关后平板看到的也是挑出来的那几道、都等着作答；平板点「只看没做过」会把 Mac 的开关一起关掉。

## 13. 打开一组题时停在哪一道（2026-10-31，Mac + 安卓模式1）

用户原话：「练习册默认到最近一个没做的题目」。原先每次启动后第一次打开某一组都从第 1 题开始。

两条拍板（用户 2026-10-31 选的，都是推荐项）：

1. **接着上次做的往下**（另一个选项「从头第一道没做过的」没选）：先找这一组里**在 App 里最近练过**的那道，从它后面找第一道没做过的；
   后面都做过了，从头找第一道没做过的；全做过 → 第 1 题。按顺序做时两种选法结果一样；跳着做时能回到上次停下的地方。
2. **安卓模式1 一起改**；模式2 用的是 Mac 那份进度（`ExerciseDeck.shared`），不用另改。

### 13.1 规则（`Exercise.resumeIndex`，纯函数，两端逐条相同）

- 「最近练过」= `ExerciseAttemptStats.lastAt` 最大的那道（App 里练的最近一次；**书上的作答不算**，它的时间是导入那一刻，同 §9.4）。
  两道时间一样取排在后面的那道。安卓按 ISO 串比（两端同一种定长格式，库里 `MAX(created_at)` 也是按串比）。
- 「没做过」= 一次作答都没有（`attempts == 0`），与顶栏「只看没做过」同一个标准——书上已有作答的题算做过。
- 只在**这一份进度新建时**算一次：Mac 是 `ExerciseDeck.init`（`decks` 按「工作区 + 范围」存到 App 退出），安卓是
  `LocalExerciseDeck.applyFresh` 第一次读库（`loaded` 为假；关工作区时 `forget` 清掉，下次打开重算）。之后切回来、换筛选、
  库里变了都照旧（停在原来那题）。「重做上次做错的」「全部重做」照旧从第一道练起。
- 错题本里的题都做过：照规则落到第 1 题（和原来一样）。

### 13.2 代码落点

| 端 | 文件 |
|---|---|
| Mac | `App/Exercise.swift`（`Exercise.resumeIndex`）、`Window/Exercise/ExerciseDeck.swift`（`init` 里设 `index`） |
| 安卓 | `local/exercise/Exercise.kt`（`Exercise.resumeIndex`）、`local/exercise/LocalExerciseDeck.kt`（`applyFresh`） |

### 13.3 验证（2026-10-31）

- `spike/exercise-test.swift` 291 项全过（新加 11 项：没题 / 没做过 / 按顺序 / 跳着做 / 后面都做过 / 最近做的是最后一道 /
  书上的作答算做过 / 只有书上的作答 / 全做过 / 时间一样 / 最近那道后面也做过）。
- 安卓 `ExerciseTest.resumeIndex` 与上面 11 项逐条对应，外加「第一次读库停在接着做的那道、刷新和换筛选不再挪」；JVM 单测 181 项全过，`assembleDebug` 通过。
- Mac Debug 编译通过、改动的文件没有新警告。🔴 没有在真 App 里跑过，由用户实测。

### 13.4 实测清单（用户）

  44. 某本书按顺序做了前几道 → 退出 App 重开、点这本书：停在下一道没做过的题。
  45. 跳着做（做第 1、2 题，再到列表双击第 5 题做完）→ 重开：停在第 6 题；第 5 题之后都做过时停在第 3 题。
  46. App 开着期间：在别的组和这一组之间来回切，停在原来那题（不会被拉回「接着做」的那道）。
  47. 错题本 / 全做过的组：重开后停在第 1 题。
  48. 平板模式1：同 44~47（关掉工作区再打开算「重开」）；模式2 在平板上开一组 Mac 还没开过的题：停的位置同 Mac。

## 14. 章节怎么分：Agent 先问、侧栏能移除（2026-10-31，Mac）

用户原话：「允许直接移除练习册的section分级，不影响题目」「创建导入练习册时需要AI询问是否要secion 分级」
「练习库，允许动态添加多级的section」「agent 提示词优化，当用户说习题册，练习册，指的就是软件的练习库Exercises」。

- 用户说的 **section 分级 = 侧栏里书底下那棵章节树**（`exercise.chapter`），不是参与去重的题组名 `exercise.section`（它不分级）。
- 「动态添加多级」拍板（用户 2026-10-31 选的）：**Agent 按对话自己建**——不受 PDF 目录限制，按页面上印的标题、题组
  （「习题 2.3 › A 组」）或用户说的任何分法，层数不限。没选的两种：列表右键把题归到已有的自定义章节 / 在章节下新建子章节；
  侧栏先建空章节再放题（要新表，改表结构与三端同步）。
- 数据层没变：`chapter` 本来就是任意层数的路径，侧栏树按路径拼、同级按最早页码排（§2.3）。

### 14.1 三种分法

| 分法 | 章节从哪来 | Agent 怎么导 |
|---|---|---|
| 按目录 | `ExerciseChapter.path`（按页码查 PDF 自带目录） | 带 `chapters: "toc"`，题不带 `chapter` |
| 自己分 | Agent 给每道题写的完整路径（几级都行，已有的上级原样照抄） | 每道题带 `chapter`，同时带 `chapters: "none"`（漏写的那道不会被按目录分走） |
| 不分 | 都空，侧栏里这本书只有书名一行 | 带 `chapters: "none"` |

- **第一次往一本书里导题**（`list_exercises` 里这本书一道都没有）Agent 先问用户选哪种；PDF 没目录就不提「按目录」。
  以后不再问、沿用原来的分法：看已有题的 `chapter` 对照目录判断是哪一种（SKILL.md 流程第 2 步）。
- 写在：`skills/unireader-exercise-import/SKILL.md`、`MCPServer.instructions`、Agent 面板上下文串（`AgentChat.exercises`）、
  `import_exercises` 的说明与 `chapter` / `chapters` 两个参数说明、`update_exercises` 的 `chapter`（中途改分法 / 挪题）。

### 14.2 `import_exercises` 的 `chapters`

- 顶层参数 `"toc"` / `"none"`（Swift 里是 `ExerciseChapterMode.toc` / `.flat`），只管**没自己带 `chapter` 的题**；
  题自己带的永远优先，§2.3 的优先级不变（已有的题有章节就沿用）。
- **不传 = 按这本书现在的样子**（`ExerciseChapter.usesTOC`）：不分章节的书保持不分，其余照旧按目录。
- 「不分章节的书」**不另存标记，从库里推出来**（`ExerciseChapter.bookIsFlat`）：已经有题、一道都没设章节，
  而且至少有一道按目录本来能分进某一章。最后这条把「用户选了不分 / 移除过」和「题恰好都在目录管不到的页上」
  （比如目录从第 10 页起、先导了前面的题）分开——后者照旧按目录分。没目录的书恒为「不是」（反正分不出来）。
  - 为什么不存标记：存进 `meta` 要进同步白名单，而 NAS 上现在的服务器会把不认识的 `meta` 键丢掉（`HostedWorkspace` 推送整理那一步），
    等于还得跟着发服务器；另加一列要升表结构、改安卓。推出来的规则只在 Mac 导题时用（导题只经 Mac 的 MCP），别的端不用懂。
  - 已知的边角：「不分」的书、已有的题全在目录管不到的页上，跨对话再导、Agent 又没带 `chapters` 时，落在目录里的新题会按目录分。
    遇到了在侧栏「移除章节分级…」一次就好——这时已经有落在目录里的题，之后就判得出来了。
- 按「不分章节的书」处理了的（没传 `chapters`、书是平的），文字结果多一行告诉 Agent；`structured` 不变，`outputSchema` 不用动。

### 14.3 侧栏：移除 / 恢复

- 「全部」底下**一本书那一行**右键：有章节树 →「移除章节分级…」（确认表）；没有 →「按目录分章节」。
  错题本 / 收藏底下那几行是筛出来的视图，不放这两项。
- **移除** = 这本书的题 `chapter` 全部清空（`WorkspaceManager.clearExerciseChapters` → `setExerciseChapter(ids:, [])`，一个事务，
  连带改 `updated_at`，离线镜像 / 服务器同步按它取新）。题目内容、作答、收藏、错题本、题目笔记都不动；
  手动或 Agent 设过的章节也一起清掉、恢复不了（确认表里写明）。不进回收站：没删行，只改一列。
- 各窗口里**开着这本书某一章的习题标签**退回整本书那一级（书底下 / 错题本底下 / 收藏底下各对各的，单独开的仍是单独的，
  `TabsModel.exerciseChaptersRemoved`），不留一个空章节。
- **按目录分章节** = 每道题按页码去目录里找（同列表「设置章节… → 按页码自动」；`autoAssignExerciseChapters` 顺手改成同一章的一起写，
  整本几百道不再一道一次提交）。PDF 没目录 → 提示改用列表「设置章节…」手填或让 Agent 填。

### 14.4 叫法

用户说的「习题册」「练习册」「练习库」= App 的习题（Exercises，侧栏「习题」那一段），不是文件、也不是某一本 PDF。
写进 SKILL.md（description + 开头一段）、`MCPServer.instructions`、Agent 面板上下文串、`import_exercises` 说明。

### 14.5 安卓 / 服务器

不用改：没动表结构和同步线格式；移除分级就是改了一批行的 `chapter`，经离线镜像 / 服务器照常同步，平板侧栏跟着变平。导题只在 Mac。

### 14.6 代码落点

| 层 | 文件 |
|---|---|
| 纯逻辑 | `App/Exercise.swift`（`ExerciseChapterMode`、`ExerciseChapter.bookIsFlat` / `usesTOC`） |
| 执行层 | `App/WorkspaceManager+Exercise.swift`（`clearExerciseChapters`、`autoAssignExerciseChapters` 按章成批写）、`App/TabsModel.swift`（`exerciseChaptersRemoved`） |
| 界面 | `Window/Sidebar/SidebarViewController.swift`（`buildExerciseBookMenu` / `confirmRemoveChapters` / `groupExercisesByTOC`）、两份 `Localizable.strings` |
| MCP / Agent | `MCP/MCPTools+Exercises.swift`（`chapters` 参数、导入时判断）、`MCP/MCPServer.swift`、`Agent/AgentChat.swift`、`skills/unireader-exercise-import/SKILL.md` |

### 14.7 验证（2026-10-31）

- `spike/exercise-test.swift` 309 项全过（新加 18 项：「不分章节的书」各种情形——有题都没章节、新书、有一道带章节、没目录、
  题都在目录管不到的页上、有一道落在目录里、不知道页码；`chapters` 明说 toc / none、没说时新书 / 平的书 / 分了章节的书；线上写法；
  整本清空章节后题目内容 / 收藏 / 错题 / 笔记不动、`updated_at` 变了、侧栏分组只剩一组、之后算「不分章节的书」）。
- Mac Debug 编译通过、改动的文件没有新警告。
- 🔴 侧栏右键、确认表、标签退回，以及 Agent 问不问 / 怎么问 / 自己分的章节对不对，都没有在真 App 里跑过，由用户实测。

### 14.8 实测清单（用户）

  49. 侧栏「习题」里一本有章节树的书，右键 →「移除章节分级…」→ 确认：书底下不再展开；点书看题，题目、做过的记录、错题本、收藏、
      题目笔记都还在；错题本 / 收藏底下这本书也不再展开。
  50. 移除前开着这本书某一章（也试错题本底下的某一章）：移除后那个标签换成整本书那一级，不是空列表。
  51. 移除后让 Agent 再往这本书导几道题：新题也不分章节。右键这本书「按目录分章节」：按目录重新分好。没目录的 PDF：提示没有目录。
  52. 一本还没导过题的书，让 Agent 导题：它先问怎么分（按目录 / 按页面标题或题组自己分 / 不分），选哪种侧栏就是哪种。
  53. 选「自己分」（比如「按习题 2.3 › A 组这样分」）：侧栏按 Agent 写的多级章节展开；换一次对话接着导，Agent 不再问、沿用同一套，
      同名的上级没有多出一份；让它「把这几道挪到 B 组」能挪。
  54. 跟 Agent 说「把这几页加到练习册」「习题册里有几道错题」：它明白指的是 App 里的习题。
