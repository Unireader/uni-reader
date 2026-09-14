# `unireader://` 链接（macOS 端，2026-09-14 落地）

> 状态：**已落地并合入 `main`（2026-09-14，合并提交 `5ad9f1d`），用户同日实测通过。**
> 背景：2026-09-13 分析「怎么和 Obsidian 打通」，用户拍板——**不做 App 内导出**（导出交给 Agent：MCP 已有
> `list_annotations` 等工具，配一份 skill 让 Agent 把笔记写进 Obsidian，见 `skills/unireader-obsidian-export/`），
> **优先做「从 Obsidian 回跳到 UniReader」**——这就是本文件。

---

## 0. 一句话定义

> **`unireader://open?…` 是一个能贴进任何 Markdown / 笔记 / 终端的链接，点了就把 UniReader 打开到
> 「某个工作区 › 某篇 › 某页（或某条笔记）」。** MCP 返回的每篇文档、每条批注、每个阅读位置都自带一个现成的 `link`。

它与 MCP 是同一件事的两半：MCP 让 Agent **读出**笔记（带链接）写到别处；链接让用户从别处**点回来**。

---

## 1. 契约（改这里先改 `DeepLink.swift`，两边一起）

只有一个入口 `unireader://open`，全部靠查询参数，**每个都可省**：

| 参数 | 含义 | 备注 |
|---|---|---|
| `ws` | 工作区 `.unrd` 包的**绝对路径** | 也接受 `file://…` 与 `~/…`；生成时按 RFC 3986 unreserved 严格编码（空格/括号/中文/`#` 全编码，见 §3） |
| `wsid` | 工作区 `workspace_id` | 可选的第二把钥匙：路径变了（盘换挂载点、开的是离线副本）靠它在最近列表里找回。**很多工作区没有 id**（只在建镜像时才补），所以 `ws` 才是主键 |
| `doc` | 文档 id（`document.id`） | |
| `hash` | 文件内容 SHA-256（`variant.content_hash`） | `doc` 找不到时兜底（删了重导入的文档 id 会变，hash 不变） |
| `page` | 页码，**1 起** | 与 MCP 同口径（换算只在 `PageNo`）；越界钳到末页，不报错 |
| `frac` | 页内位置 0（页顶）… 1（页底） | 默认 0；越界钳到 0…1 |
| `note` | 笔记 id | 文字笔记 / 高亮 / 图片笔记 / 书签任一（`note.id`，UUID）。跳到它所在处；文字/图片笔记还会**展开气泡**。给了它，`page`/`frac` 只在找不到这条笔记时兜底 |

不认识的参数一律忽略（以后加参数，老版本 App 照样能开）。`unireader://open` 光杆 = 只把 App 叫到前台。

**例子**（MCP `list_annotations` 里每条 `link` 就长这样）：

```
unireader://open?ws=%2FVolumes%2FT7%2F%E8%AF%BB%E4%B9%A6.unrd&doc=6F2A…&note=6BA7B810-9DAD-11D1-80B4-00C04FD430C8
unireader://open?ws=%2FUsers%2Fxvan%2FDocuments%2F%E8%AF%BB%E4%B9%A6.unrd&doc=6F2A…&page=12&frac=0.43
```

### 1.1 解析顺序（`DeepLinkRouter.route`，每步可省、省了就往下兜底）

1. **工作区**：`ws` 路径正开着 → 它；`wsid` 在开着的实例 / 最近列表 → 它（源盘不在就开离线副本，`WorkspaceRegistry.resolve`）；
   `ws` 路径在最近列表 → 同上兜底副本；`ws` 本身是真实工作区 → 开它；`ws`/`wsid` 都没给 → 哪个开着的工作区有这篇（按 `doc`，再按 `hash`）就用哪个，
   还没有就用 key 窗口的。给了却找不到 → 报错。
2. **窗口**：该工作区没有窗口就新开一扇——**照常恢复它上次的标签**（`docId: nil`），与双击 `.unrd` 一样；链接只是往里多开一篇。
   （MCP 的 `open_document` 在这一步是「只装这一篇」，两者刻意不同：Agent 要的是干净窗口，用户点链接要的是「我的工作区」。）
3. **文档**：`doc` → 直接；找不到再按 `hash` 查 `variant`；给了却都找不到 → 报错，**不静默落在别的文档上**。
   没给 → 停在该工作区当前标签。
4. **位置**：`note` > `page`+`frac`。笔记的位置 = 所在页 + 锚点上沿再往上 3%（与 Inspector 点条目同口径）；书签 = 它自己的 `frac`。
5. **展开**：文字 / 图片笔记把 id 交给 `DocSession.revealNoteID`，阅读区（`PageStreamView.revealNote`）把它加进 `expandedNotes`。
   `hover` 模式的笔记展不开（它只认悬停），`always` 本来就开着。

---

## 2. 落地（文件与去向）

| 文件 | 内容 |
|---|---|
| `Sources/Info.plist` | `CFBundleURLTypes`：scheme `unireader`，角色 Viewer |
| `Sources/App/DeepLink.swift` | **纯 Foundation**：`DeepLink` 值 + `parse(URL)`（七个参数、`ws` 三种写法归一、坏值报 `ParseError`）+ `url`/`absoluteString` 生成 + `formatHint`（给 `get_state` 用的一行格式说明） |
| `Sources/App/DeepLinkRouter.swift` | `@MainActor`：§1.1 的解析顺序、`Target`（笔记 → 页/位置/要展开的 id）、失败弹框（本地化） |
| `Sources/UniReaderApp.swift` | `application(_:open:)` 按 scheme 分流（`.unrd` 文件 / `unireader://`）；冷启动缓冲原始 URL（`pendingDeepLinkURL`），`didFinishLaunching` 消费（**优先级低于 `.unrd` 双击**；链接写坏也是先开默认窗口再弹框）；新增 **`showDocument(_:in:activate:)`** 与 `tabShowing(_:)` |
| `Sources/MCP/MCPFacade.swift` | `openDocument` 的「已在显示 → 切过去；有窗 → 开标签；没窗 → 新开」改调 `AppDelegate.showDocument`（**与链接共用一份**，`window_id` 分支保留）；新增 `link(…)`；`documentDTO` / `list_annotations` 每条 / `get_current_view` / `open_document` / `goto` 结果都带 `link`；`get_state.app.deep_link` = 格式说明 |
| `Sources/MCP/MCPTools*.swift` | 对应的 outputSchema 与工具描述 |
| `Sources/App/DocSession.swift` | `@Published var revealNoteID: UUID?`（一次性请求，取走即清） |
| `Sources/Views/PageStreamView.swift` | `revealNote(_:)`；`onChange` 挂在 `canvasRoutes` 层（`surfaceBody` 那条链再加一个就超类型检查器时限，2026-09-14 实测又踩一次）；首帧 `setup()` 末尾补取（视图建在请求之后的情形） |
| `Sources/*.lproj/Localizable.strings` | 弹框文案 11 条（中 / 英） |
| `spike/deep-link-test.swift` | 解析 / 生成 34 项，全绿 |

### 2.1 🔴 两条要记住的

- **「让某篇显示出来」只有 `AppDelegate.showDocument` 一份**（MCP 与链接共用）。别在任何一边另写「找标签 / 挑窗口」——
  两边规则一分叉，Agent 开的和链接开的就会落在不同窗口。
- `WorkspaceRegistry.acquire` 带引用计数，**路由阶段只查不 acquire**（`resolveFolder` 只看 `openManager(at:)` / `recents` / `hasLibrary`），
  开窗那一步（`makeReaderWindow`）才 acquire。查 `hash` 需要 store，所以「工作区没开 + 只给 hash」的链接先开窗（恢复标签）再查——这也是 §1.1 第 2 步选「恢复标签」而不是「只装这篇」的原因之一。

---

## 3. 为什么生成时编码这么严

`URLComponents` 默认不编码 `(`、`)`、`'`、中文之外的很多字符，而这个链接的归宿是 **Markdown 的 `[text](url)`**：
路径里一个空格、一对括号、一个 `#`，Obsidian 就把链接截断。所以 `DeepLink.encode` 只放行 `A-Z a-z 0-9 - . _ ~`，
其余全部 `%XX`。解析侧用 `URLComponents`，任何编法都解得开（spike「往返」一项）。

---

## 4. 与 Obsidian 的配合（导出由 Agent 做）

- Agent 用 MCP `list_annotations` 拿到每条批注的 `link`，写进 vault 时每条末尾放一个 `[在 UniReader 中打开](unireader://…)`。
  图片笔记的文件在 `<工作区>/Images/<sha256>.<ext>`，Agent 直接复制进 vault 附件目录（不碰 `library.sqlite`）。
- 具体的写法约定（每篇一文件、frontmatter、生成区标记、标签体系）在 `skills/unireader-obsidian-export/SKILL.md`。
- Obsidian 里点 `unireader://` 链接：Obsidian 对非 http 的 scheme 会交给系统打开，无需插件。
  第一次点可能弹「是否允许打开 UniReader」的系统确认，勾选记住即可。

---

## 5. 没做 / 刻意不做

- **不做 App 内导出 / 同步到 vault**（用户 2026-09-14 拍板：Agent 来做）。
- 链接不带 `hash`（MCP 生成的 `link` 只有 `ws` + `wsid` + `doc` [+ `page`/`frac`/`note`]）——64 位十六进制会让每条链接长一倍，
  而文档 id 只在「删了重导入」时才变。Agent 想要更耐用的链接可以自己拼上 `&hash=`（`documentDTO.content_hash` 给了）。
- 不做 `unireader://` 之外的第二个 host（`workspace`、`search` 之类）。要加就在 `open` 上加参数。
- 笔迹 / 草稿纸没有「定位到某一笔」——`list_annotations` 里草稿纸的 `link` 指向它图钉所在的页。
- 反向（Obsidian 里改了笔记回写 UniReader）不做；要反向写走 MCP 批 3 的 `add_note`。

---

## 6. 用户实测清单（2026-09-14 用户已过；留作回归清单）

> 先跑一次 Debug 包让 LaunchServices 登记 scheme：`open build/dev/Build/Products/Debug/UniReader.app`。
> 机器上若同时有别的 UniReader.app（主目录的 `build/dev`、`/Applications`），系统可能把链接派给另一份——
> 实测前确认 `open` 拉起的是哪一份（菜单 › 关于 看版本 / 路径）。

1. **热启动 · 跳页**：App 开着，终端 `open "unireader://open?ws=<路径>&doc=<id>&page=12&frac=0.5"`（路径与 id 从 MCP `list_documents` 或
   `get_current_view` 的 `link` 里直接拷）→ 应切到那篇、翻到第 12 页页中、窗口到前台。
2. **热启动 · 笔记**：`…&note=<文字笔记 id>` → 翻到那条、气泡展开；高亮 / 书签 → 只翻到，不展开。
3. **冷启动**：退出 App，再 `open` 同一条链接 → App 起来、工作区**恢复上次的标签** + 目标那篇在前、位置到位（不该只剩一篇）。
4. **文档在别的窗口**：两扇窗（两个工作区），链接指向非 key 窗口那篇 → 那扇窗到前台，不重开标签。
5. **工作区没开**：链接指向一个最近列表里、当前没开的工作区 → 新开一扇窗（恢复标签）+ 目标那篇。
6. **坏链接三种**：`page=0` / `note=abc` / `ws` 指向不存在的路径 → 各弹一个「无法打开链接」框，App 不该无窗口。
7. **Obsidian**：把 `list_annotations` 里某条的 `link` 贴进 vault 里一个 `[回去](…)`，阅读模式点它 → 同 1/2。
8. **MCP 面**：`get_state` 的 `app.deep_link` 有格式说明；`list_annotations` 每条有 `link`；`get_current_view` 的文本最后一行是 `link …`。
9. **回归**：MCP `open_document`（工作区已开 / 未开 / 指定 `window_id` 三种）行为与改前一致——它的中段换成了 `showDocument`。
