# BACKUP-PLAN.md — 回收站与工作区备份

> 2026-09-21 拍板。两套互补的兜底机制：**回收站**管「误操作删掉了东西」，**定时备份**管
> 「库被改坏了 / 想回到几天前」。两者都只在**工作区内部**做文章，不往别处写文件。
>
> 目标只有一个：**笔迹永远找得回来。** PDF 丢了可以再下一份，几百小时的手写笔记丢了就没了。

---

## 0. 为什么要做（现状的两个洞）

| 洞 | 现状 | 后果 |
|---|---|---|
| 删文档零确认 | 侧栏右键「删除」→ 直接 `DELETE FROM document`，`note` / `ink_layer` / `scratch_pad` 全部 `ON DELETE CASCADE` | 手滑一下，一篇书的全部笔迹、文字笔记、高亮、书签、草稿纸当场消失，**没有任何撤销路径** |
| 库无快照 | 只有「建离线镜像」时才整库复制一次，平时不留任何历史 | 库损坏 / 误操作 / 想回到昨天 → 只能认 |

顺带一提：`delete(documentId:)` **不删** `PDFs/` 里的副本文件（只删库行），所以恢复时只要把库行放回去，
文件还在原处、`location` 那条相对路径照样有效——这是下面「回收站只存库行、不存 PDF」能成立的前提。

---

## 1. 两套机制的分工

```
误删一篇文档 / 一个图层  ──→  回收站（Trash）   ──→  逐条恢复，30 天后自动清
库被改坏 / 想回到前天    ──→  定时备份（Backups）──→  整库还原到某个时间点
```

不互相替代：回收站救不了「库文件本身坏了」，备份救不了「昨天删的那篇今天才发现」（备份是整库快照，
还原会把这段时间**别的**改动一起退回去）。

---

## 2. 回收站（Trash）

### 2.1 形态：快照文件，不动 schema

```
<工作区>.unrd/
  UniReader/
    library.sqlite
    Trash/
      2026-09-21T14-03-11_高等数学/
        snapshot.sqlite      ← 被删的那些库行，独立的一个小库
        manifest.json        ← 标题 / 类型 / 条数 / 时间 / 引用到的图片
```

🔴 **刻意不用「库内软删除」**（`document.deleted_at` 那种）。`document` / `note` 是**三端契约**
（Mac / 安卓模式1 / 离线镜像），加一个状态列意味着：安卓 `Schema.kt` 要跟、`MirrorDiff` 的判定表要重新想
（删除变成了修改，一端删一端改的规则全要重写）、主库里每一处查询都要补一道 `WHERE deleted_at IS NULL`
——漏一处就是「已删的文档又冒出来」，而漏得最狠的地方一定是最少走的那条路（镜像合并）。

快照文件这条路：**schema 仍是 v15，一个字都不改**。删除对三端来说和今天完全一样（硬删、照常传播），
回收站纯粹是 Mac 端在删之前多存了一份。安卓端不认识 `Trash/` 目录，它也不需要认识。

### 2.2 一条回收站条目存什么

**文档级**（`kind = "document"`）：

| 表 | 取哪些行 |
|---|---|
| `document` | 那一行 |
| `variant` | `document_id = ?` |
| `location` | `variant_id IN (…)` |
| `note` | `document_id = ?`（**全部 kind**：文字 0 / AI 绑定 1 / 页内笔迹 2 / 高亮 3 / 草稿纸笔迹 4 / 书签 5 / 图片笔记 6） |
| `ink_layer` | `document_id = ?` |
| `scratch_pad` | `document_id = ?` |

**图层级**（`kind = "inkLayer"`）：`ink_layer` 那一行 + 该层的 `note`（kind=2）。
默认图层还要带上 payload 里没有 `layerId` 键的老行（与 `LibraryStore.deleteInkStrokes` 同一套判定）。

**刻意不存的**：

- `ocr_page` / `page_geom` / `page_align` —— 它们按 **content_hash** 存，删文档根本不会删它们
  （没有外键）。留在主库里，同一份 PDF 重新导入立刻复用，不必往回收站抄一份几百 MB 的 OCR。
- **PDF 本体** —— 删文档不删 `PDFs/` 里的文件（见 §0）。外部文件更不用说，本来就没碰过。
- **图片本体**（`Images/<sha256>`）—— 不抄字节，改成**护住**：manifest 里记下引用到的 sha256，
  `WorkspaceManager.purgeImages` 跳过还被回收站引用着的图（详见 §2.6）。

### 2.3 manifest.json

```json
{
  "v": 1,
  "kind": "document",
  "deletedAt": "2026-09-21T06:03:11.000Z",
  "title": "高等数学",
  "documentId": "…UUID…",
  "documentTitle": "高等数学",
  "layerId": null,
  "pageCount": 340,
  "counts": { "ink": 2616, "text": 12, "highlight": 30, "bookmark": 5,
              "image": 3, "aiThread": 0, "scratchInk": 88,
              "inkLayer": 4, "scratchPad": 2 },
  "images": ["<sha256>", "…"],
  "contentHashes": ["<sha256 of pdf>", "…"]
}
```

`contentHashes` 是**恢复时认「这份 PDF 是不是又被导入过」的钥匙**（§2.5），`images` 是清理时的护身符（§2.6）。
条目目录名带一份可读标题只为在 Finder 里认得出来，程序一律读 manifest，不解析目录名。

### 2.4 删除流程（用户视角）

1. 侧栏右键「删除」→ **确认框**（今天连这个都没有）：
   「删除《高等数学》？— 2616 笔笔迹、12 条笔记、30 处高亮会一并移入回收站，30 天后自动清除。」
2. 确认 → 先写快照，写成功了才 `DELETE FROM document`。
   🔴 **顺序不能反**：先删再存，中间失败就什么都没了。快照写失败 → 整个删除放弃并报错。
3. 图层删除同理（`LayerManagerNSView.confirmDelete` 的确认框已有，只是加一句「可从回收站恢复」）。

### 2.5 恢复流程

读 snapshot.sqlite，按列名把行通用地写回主库（`INSERT OR REPLACE`，与 `MirrorApply` 同一套写法）。
两种情形：

**A. 那篇文档还不在库里**（常规）：整份放回去，`document` / `variant` / `location` / `note` /
`ink_layer` / `scratch_pad` 全量恢复，id 原样——`unireader://` 链接、MCP 里记的 document_id 全都还有效。

**B. 同一份 PDF 已经被重新导入过**（`variant.content_hash` 在主库里已属于另一篇文档）：
这正是最常见的现实场景——误删 → 重新拖进来 → 才发现笔记没了。
此时**不能**照搬 `variant`（`content_hash` 有 UNIQUE 约束，直接撞）。做法是**并入**：
把快照里所有行的 `document_id` 改写成主库那篇的 id，只恢复 `note` / `ink_layer` / `scratch_pad`，
`document` / `variant` / `location` 三张表整个跳过（保留现有那篇的标题、进度、分组）。
UI 上说清楚：「《高等数学》已重新导入过，将把 2616 笔笔迹并入现有的那一篇」。

恢复成功 → 删掉回收站条目目录 → `refresh()` + `reconcileAndPurgeImages()`（把图片的待删除标记摘掉）。

### 2.6 保留期与图片的相互作用

- 默认 **30 天**自动清除（与图片本体的 `imagePurgeAfter` 同一口径），设置里可改 30 / 90 / 永不。
- 清理时机：打开工作区时跑一次（`WorkspaceManager.open` 末尾，同 `reconcileAndPurgeImages`）。
- 🔴 **图片清理要让路**：图片笔记的本体走「数引用 → 没人引用就 `orphaned_at` 打标 → 30 天后真删」。
  文档一删，它引用的图立刻变成孤儿并开始计时——若回收站保留期设成 90 天 / 永不，
  30 天后图片先被清掉，再恢复就只剩一个空框。
  所以 `purgeImages(before:)` 前先收集全部 manifest 的 `images`，**被回收站引用着的一张都不删**。
  恢复或彻底删除那条回收站条目后，护身符自然消失，图片回到正常计时。

### 2.7 界面

「文件 › 回收站…」开一扇面板（`Sources/Window/Sheets/TrashSheet.swift`）：表格列出条目
（标题 / 类型 / 删除时间 / 内容摘要 / 占用），按钮 **恢复** / **彻底删除** / **清空** / **在 Finder 中显示**。
彻底删除与清空各自要一次确认——回收站是最后一道防线，它自己的删除不能再有回收站。

---

## 3. 工作区定时备份（Backups）

### 3.1 位置与内容

```
<工作区>.unrd/UniReader/Backups/library-20260921-140311.sqlite
```

**只备份 `library.sqlite`**，用 `checkpointTruncate()` + `VACUUM INTO`（见 `LibraryStore` 那两个方法的
注释：`VACUUM INTO` 在一个读事务里生成，天生一致、顺带压缩、不必停写；`cp` 那三个文件不是原子的）。

不备份 PDF（几十 GB，而且 App 从不修改它们）、不备份 `Images/` 与 `Notes/`（普通文件，
App 不会擅自删——图片的 30 天清理只清「没有任何笔记引用」的那些）。笔迹、文字笔记、高亮、书签、
草稿纸、OCR 缓存、对齐参数**全都在库里**，一份库就是全部心血。

写入走「临时名 → `rename`」：半截文件不能被当成一份有效备份。

### 3.2 触发时机

| 时机 | 说明 |
|---|---|
| 打开工作区后 | 延迟几秒、后台跑，不拖慢开窗 |
| 每 6 小时 | 单例里一只 timer，按工作区逐个跑（设置里可改 1 / 6 / 12 / 24 小时） |
| 退出 App 前 | `applicationShouldTerminate` 里同步跑一次 |
| 设置页「立即备份」 | 手动 |

**节流 30 分钟**：距最近一份备份不足 30 分钟就跳过（拿备份文件自己的时间戳判断，不另存状态——
少一处能和现实不一致的记录）。手动「立即备份」不受节流限制。

### 3.3 保留策略（分级稀释）

```
最近 5 份      全留
每天 1 份      留最近 7 天（每个自然日保留该日最新的一份）
每周 1 份      留最近 4 周（ISO 周，同上）
────────────────────────────
约 16 份封顶
```

纯函数 `BackupRetention.plan(stamps:now:)` → `(keep, drop)`，离屏可测（`spike/backup-retention-test.swift`）。
**只按规则删**：规则之外的文件（用户自己放进去的、命名对不上的）一律不碰。

### 3.4 还原

低频高危，流程要笨一点才安全：

1. 确认框写明：「将把资料库还原到 2026-09-19 08:00 的状态。这之后的全部笔迹、笔记、阅读进度都会退回。
   当前的资料库会先另存为一份还原点。UniReader 随后会退出，请重新打开工作区。」
2. 当前库先 `VACUUM INTO` 一份 `library-<now>-before-restore.sqlite`（**永不参与保留策略的稀释**）。
3. `WorkspaceManager.teardown()` 关连接 → 替换 `library.sqlite`（连 `-wal` / `-shm` 一并删掉）。
4. `NSApp.terminate(nil)`。

🔴 **为什么是退出而不是原地重开**：库连接、打开的标签页、笔迹的按页窗口、笔架、草稿纸、Agent 面板
全都挂在「当前这个 store 实例」上，原地换库等于要求每一处都正确地丢弃并重建状态——那是一整轮
「重开文档」的代码路径，而这个功能一年用不上一次。退出重开是**零新状态**的做法，用户少点一下，
换一条不会出错的路。

### 3.5 界面

「文件 › 工作区备份…」开面板（`Sources/Window/Sheets/BackupsSheet.swift`）：列出备份
（时间 / 大小 / 是不是还原点），按钮 **立即备份** / **还原…** / **在 Finder 中显示** / **删除**。
设置 ›「通用」加一个「备份」小节：开关 + 频率 + 上次备份时间 + 「管理…」。

---

## 4. 代码落点

| 文件 | 干什么 |
|---|---|
| `Sources/Store/TrashStore.swift` | 只碰 SQLite：把某文档 / 某图层的行 `ATTACH` 出去写进快照库；从快照库通用地写回。同 `MirrorStore` 的定位——`LibraryStore` 的 DAO 约定在这里开一条窄口子 |
| `Sources/App/TrashModel.swift` | 纯 Foundation：`TrashEntry` / manifest 编解码 / 目录扫描 / 到期判定。可离屏测 |
| `Sources/App/WorkspaceManager+Trash.swift` | 执行层：删除前归档、恢复（含 §2.5 的 A/B 两种情形）、彻底删除、清空、到期清理 |
| `Sources/App/BackupRetention.swift` | 纯函数：保留策略 `BackupRetention` + 文件命名 `BackupFile`（命名与解析对不上 = 备份照写、列表永远空着，是典型的静默失效，所以放进能离屏测的纯文件里） |
| `Sources/App/BackupService.swift` | 调度：timer、节流、按工作区跑、还原 |
| `Sources/Window/Sheets/TrashSheet.swift` | 回收站面板 |
| `Sources/Window/Sheets/BackupsSheet.swift` | 备份面板 |
| `spike/trash-test.swift` | 归档 → 删除 → 恢复的库回环（含「PDF 重新导入过」那条分支），62 项 |
| `spike/backup-retention-test.swift` | 保留策略 + 文件命名，39 项 |

改动：`LibraryStore`（加窄入口）、`WorkspaceManager`（`delete` 改走回收站、`purgeImages` 让路、
`open` 末尾清理 + 触发备份）、`SidebarViewController`（删除确认框）、`LayerManagerNSView`（归档后再删）、
`MainMenu`（两个入口）、`SettingsView`（备份小节）、`UniReaderApp`（退出前备份）、两份 `Localizable.strings`。

**schema 不变，仍是 v15。安卓端不用动。**

---

## 5. 刻意没做

- **库内软删除**（理由见 §2.1）。
- **单条笔记 / 单笔笔迹进回收站**：擦除、删笔画已经有撤销栈（`InkUndo`），再叠一层回收站只会让
  「刚才那一下到底能不能撤回」变得说不清。回收站只收**不可逆的大动作**：删整篇、删整层。
- **Markdown 笔记进回收站**：正文是 `Notes/` 下的真文件，删除时走的是文件系统；这一轮先不动，
  以后要做就是把 `.md` 文件本身挪进条目目录。
- **备份连 PDF 一起**：一份几十 GB，不适合定时跑。要整份留档用现成的「离线镜像」。
- **备份到工作区外**（iCloud / 另一块盘）：用户明确要求「数据库保存在工作区里面」，
  工作区跟着走，备份就跟着走。
