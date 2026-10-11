# 习题（Exercise）方案 — Agent 识别导入 + Mac 练习 / 错题本 / 收藏

> 状态：**2026-10-10 定方案并落地（Mac）**，实现记录见 §9。本轮只做**选择题**（单选 / 多选）。
> 三条拍板（用户 2026-10-10 选的）：① 练习界面 = **主窗口标签页**（侧栏加「习题」一段）；
> ② 本轮**只做 Mac**，安卓只按 schema 契约同步建表（`Schema.kt` 升 v20），平板练习 / 离线镜像同步习题放下一轮；
> ③ 错题本 = **答错自动进，只能手动移出**。
> **2026-10-11 第二批**（用户追加）：④ **章节**——按「课本 + 章节」练，章节从 PDF 目录自动取、可手动设，
> 侧栏按**目录整棵树**展开（§2.3）；⑤ **导入书上已有的作答**（用户「选择题一般高亮作答，部分手写」，§2.4）+
> 答案后补时**重判**；⑥ 习题标签顶上加**筛选**（全部 / 没做过 / 错题 / 收藏，§4.2）。
> 两列（`exercise.chapter`、`exercise_attempt.source`）在 v20 发布前补进同一版（开发包已建过表的库靠 `ADD COLUMN` 补）。

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
| `kind` | 0 单选 / 1 多选（以后：2 判断 / 3 填空 / 4 解答，本轮不认） |
| `number` / `section` | 书上印的题号（原样，如 `"5"`、`"例 3"`）/ 章节或套卷名 |
| `starred` | 收藏 |
| `wrong` | 在错题本里。**答错置 1；只有用户手动「移出错题本」置 0**（拍板 ③）；答对不动它 |
| `source` | 谁导入的（MCP 客户端名，同批注的 `NoteSource.provider`） |
| `chapter` | 所属章节在目录里的路径，**JSON 字符串数组**（顶层 → 最深一级）；空串 = 没设（§2.3） |
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
| `import_exercises` | write | 按 §2 的结构批量写入一篇文档的习题（一次 ≤50 道）。逐条校验，不合格的退回原因、其余照常写入；命中去重键即更新。可带 `chapter`（不带 = 按目录自动）、`user_answer`（书上的作答，§2.4） |
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
  - 已经有标签开着被点的那一组（单独的 / 错题本 / 公用的）→ 直接切过去。
  - 单独开的标签跨启动记得住（存成 `exs:<范围键>`）；改之前存下的几个习题标签恢复时只留第一个公用，其余算单独开的。

### 4.2 练习界面（`Sources/Window/Exercise/`，AppKit；题干 / 选项 / 解析用 Markdown 引擎只读渲染，红线 ② 那一处例外）

- 顶栏：范围名 + 进度 + **筛选**（全部 / 没做过 / 错题 / 收藏，2026-10-11 用户要的；与范围组合出「第二章的错题」）+
  「练习 / 列表」切换。换筛选 = 按新条件重取一份快照、尽量停在原来那题。
- **练习**：一次一题。题号 · 第几页 · 单选/多选；按钮：收藏、看原题、到 PDF 原页（`AppDelegate.showDocument` + `jump`）。
  - 单选：点选项即判；多选：勾完点「提交」。键盘 A~H 选、Return 提交、←/→ 上一题 / 下一题。
  - 判完：正确项标绿勾、选错的标红叉（SF Symbols），显示解析；答错 → 进错题本。
    没有答案的题：记一次作答（`correct = NULL`），提示「这道题还没有答案」。
  - 错题本里练：判完多一个「移出错题本」。
  - **做过的题直接显示上次结果**（2026-10-11 用户定）：这一轮还没答、以前做过的题，一翻到就是判完的样子——
    上次选的勾上、对错标记、正确答案、解析，结果那行写「上次作答：A，错误。正确答案是 C。」，下面一行
    「那次的时间 · 共做 3 次，对 1 次」。想重答点「再做一次」（这一轮当没答过，库里记录不动）。
    「以前那次」= App 里练的最近一次；App 里没练过才拿书上的作答（结果那行写「书上的作答：…」）。
    书上那条不算「最近」：它的时间是导入那一刻，重导一次会盖过真正后做的练习。对错按现在的答案现判。
    代价（用户知情）：在「错题」筛选下练，每题都先看到答案，要先点「再做一次」。
  - **批量重做**（2026-10-11 用户要的）：顶栏「全部重做」= 当前这一组（范围 + 筛选）都当没答过、从第一题练起；
    列表多选右键「重做这 N 道题」= 选中里显示着作答的那几道，从其中第一道练起。和「再做一次」一样只管这一轮
    （App 开着期间），库里记录不动；退出重开后做过的题照旧显示上次结果。先筛「错题」再「全部重做」就是重练错题。
- **列表**：一行一题（题号 / 题干一行纯文本 / 章节 / 页 / 题型 / **我的答案**（同练习页那一份，如「A（错）」）/
  作答次数与对错 / 收藏与错题标记），
  双击 = 从这题开始练；右键：收藏、移出错题本、**设置章节…**（同一本书里的题）、到 PDF 原页、删除。
- 题目集合在打开 / 切回标签时取一次快照（错题本里移出的题这一轮不会突然消失，下次进来才不在）；
  Agent 补了答案（`refreshExercises`）就地刷新当前题。

### 4.3 设置

本轮没有设置项。

## 5. 回收站 / 离线镜像 / 备份 / 安卓

- **回收站**：`TrashStore.documentTables` 末尾加 `exercise`、`exercise_attempt`（父在前），删文档时随文档归档；
  `exercise` 有级联子表，恢复用 `OR IGNORE`（同 `document` / `board_note` 的理由）。删习题新增一种条目
  `Trash.Kind.exercises`（`archiveExercises`）。`Counts` 加 `exercise`。
- **关联为同一文档**（`mergeDocument`）：`exercise.document_id` 跟着改到目标文档，否则会被级联删掉。
- **离线镜像**：本轮**不进** `MirrorFp.specs`（Mac 独有，镜像合并不碰这两张表；平板上看不到习题）。
  下一轮做安卓练习时再进同步表，届时要补「父题已删」的过滤（同 `livingBoards`）。
- **备份**：`VACUUM INTO` 整库，自动包含。
- **安卓**：`Schema.kt` 加同样 DDL、`VERSION = 20`；不读不写这两张表。

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

- `spike/exercise-test.swift`（149 项）：建表 / 导入校验（各种不合格输入）/ 去重更新不冲掉收藏与错题 / 判题 /
  作答记录与错题本规则 / 删文档级联 / 回收站归档与恢复 / `mergeDocument` 带走习题；第二批：目录查页 / 章节列回环 /
  章节范围与计数与建树 / 书上的作答只留一条 / 重判 / `user_answer`·`chapter` 校验 / 筛选 / 开发包老库补列；
  做过的题显示哪一次（App 里最近一次优先、书上的作答兜底、按现在的答案判）；错题本按书 / 按章（计数、建树、范围键回环）。
- 回归：`store-test` / `trash-test` / `mirror-fp-test`（specs 不变）。
- `xcodebuild`（`build/dev`）；安卓 `assembleDebug`。
- 🔴 练习界面的手感 / 观感由用户实测。

## 8. 本轮不做

判断 / 填空 / 解答题；平板（安卓模式1 / 网页）练习与离线镜像同步；乱序 / 计时 / 正确率统计图表；
「连续答对 N 次自动移出错题本」（用户选了只能手动出）；页面上标出已识别的题（PDF 上的框）；题目笔记。

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
  17. 批量重做：筛「错题」→ 顶栏「全部重做」→ 跳到第一题、全部可以重答，「本轮已做」从 0 算；
      列表多选右键「重做这 N 道题」→ 跳到选中的第一道，没选中的题照旧显示上次结果；
      没有任何题显示着作答时「全部重做」是灰的。
  18. 只用一个习题标签：侧栏依次点「全部习题」「某本书」「某一章」「收藏」→ 始终是同一个标签在换，切回之前那组停在原来那题；
      点「错题本」→ 另开一个标签，再点别的组回到公用标签；右键某一章「在新标签页中打开」→ 单独一个标签，
      之后点别的组它不变；退出重开，公用 / 单独 / 错题本三种标签都还在、行为不变。
      某本书删掉 → 开着它（或它某一章）的习题标签跟着退。
  19. 错题本展开：底下是有错题的书 → 章节树，数是错题数；点书 / 章都在同一个错题标签里换，和练习的公用标签互不影响；
      书 / 章右键「在新标签页中打开」单独开；移出错题本后侧栏的数跟着减，这一轮标签里那道题还在。
