# 网页（静态 HTML 课件）方案 — WEB-DOC-PLAN

> 2026-11-19 用户提：「对于一些静态 HTML 教学，我希望放到 UniReader，用户可以打开浏览器查看（或者内嵌 WebKit），
> 需要支持文件夹（包含图片等资源），手机端也需要支持」；同日补充：「内嵌 WebKit 做一个注入，网页往 UniReader 读取 / 写入，
> 这样网页就可以同步进度，做一个 JSON 或者 KV 保存」。
>
> 用户同日选定：① 拷进工作区、按内容寻址；② Mac 内嵌标签页 + 可在浏览器打开；③ 移动端 = 安卓 App 内 WebView；
> ④ 分批：第一批 Mac + 数据同步、第二批安卓模式1 都已写，**待实测**（§8.1、§9）。

## 1. 是什么

工作区里多一类内容「网页」：导入一个文件夹（html + 图片 / css / js / 字体 / 视频），侧栏「网页」一段里一行，
点开是一个标签页（`WKWebView`），也可以在默认浏览器里打开。内容只读：课件改了就「从文件夹重新导入」。
页面里有 `window.unireader`，课件可以把学到哪了 / 做题记录存进工作区，随同步到别的设备。

## 2. 数据（加在已发布的 v28 上，不升版本号）

v28 已于 2026-11-16 发布（服务器 v0.7.0 / Mac v0.3.32 / 安卓 0.3.23）。两张新表**不升版本号**：同步两端都跳过不认识的表
（服务器 `pushLocked` / 客户端 `applyPulled` 都先问 `SyncRows.isSynced`），旧版服务器、旧版 Mac、安卓只是看不到网页，不会出错，
也不用强制所有设备一起升级。服务器换了这一版，网页的行与文件才在 Mac 之间同步；安卓第二批再建逐字相同的两张表（§9）。

```sql
CREATE TABLE web_doc (id, title, entry, manifest, bytes, group_name, created_at, updated_at, last_opened_at);
CREATE TABLE web_kv  (id, web_id, key, value, updated_at);   -- id = web_id + 0x1F + key
```

- **文件本体**：`<工作区>/Web/<sha256>`，一个文件一份、不带扩展名（类型按清单里的路径定）。同一份 js 库 / 图片在几份网页里只存一份；
  重新导入改过的课件只多存改了的那几个文件。写入一律 `.part` → 原子改名（`Sources/Store/WebAssets.swift`）。
- **清单** `manifest`：JSON 数组 `[{"h":sha256,"n":字节数,"p":相对路径}]`，按路径排序、键序固定（进行指纹，抖一下就算「改过」）。
  路径规则：`/` 分隔、不以 `/` 开头、没有空段 / `.` / `..` / 反斜杠 / 控制字符（`WebAssets.isSafeRelative`，解码时不合规的条目直接丢）。
- `entry` = 入口页：根目录的 `index.html` / `index.htm`，没有就挑最浅的 html；选单个 html 导入时就是它；侧栏右键「首页」可以换。
- 导入：跳过隐藏文件 / `.git` / `__MACOSX` / 符号链接；上限 2 万个文件、4 GB（防误选整个下载目录）。标题取入口页的 `<title>`，没有用文件夹名。
- `web_kv.value` = JSON 文本。每份网页至多 2000 个键、单个值 1 MB、合计 8 MB；值没变不改 `updated_at`。

## 3. Mac 显示

### 3.1 内嵌标签页（`Sources/Window/Web/WebDocView.swift`）

- 第六种标签内容：`DocTabModel.webDocID`（与 `docID` / `noteRef` / `boardID` / `exerciseScope` / 日程互斥，开之前 `select(nil)`），
  选中键 `web:<id>`（`LibWebDoc.rowPrefix`），标签组持久化 / 冷启动恢复 / 返回前进都认它。
- 文件经自定义协议 `unireader-web://<网页 id 小写>/<路径>` 读（`WebDocSchemeHandler`，**不开端口**）；每份网页的 id 当主机名 →
  各份网页是不同的源，`localStorage` 互不串。支持 `Range`（视频）；读文件在后台队列。
- 顶上一条：后退 / 前进、回到首页、重新载入、标题、「在浏览器中打开」。「回到首页」（2026-11-20 补，用户报手机和 Mac 都回不到首页）：
  课件的子页面不一定有回首页的链接，重新打开又停在上次那一页、后退历史是空的，就没有路回去；点它载入 `entry`（进后退历史），已在首页时灰着
  （目录地址 `/`、`chapter/` 按它的 index 认，页内 `#锚点` 不算离开）。安卓同（`WebPageController.goHome`，图标 `ic_home`）。主框架点到外面网站 → 交给默认浏览器；`alert` / `confirm` / `prompt` /
  文件选择框都接了（不接会被 WebKit 悄悄吞掉）；`isInspectable = true`（课件作者可以用 Safari「开发」菜单调试）。
- 本机记住每份网页上次看到哪一页（`UserDefaults` `web.lastPath.<id>`，不同步）。
- 连同那一页滚到哪（2026-11-20 补，用户报每次打开都从头开始；`UserDefaults` `web.scroll.<id>`，不同步）：只在主框架跑的一小段脚本
  （`WebBridgeScript.scrollSource`，放在隔离的脚本环境 `.defaultClient`，页面看不到也改不了），停手 0.3 秒报一次
  `{ p: location.pathname, x, y }`；有的课件整页不动、内容在铺满的 `overflow: auto` 容器里滚，这种容器（高 ≥ 视口一半，
  挡掉代码块 / 表格这类小滚动框）另记选择器 `s` + `sx` / `sy`。打开这份网页（`load()`）和**重新载入**时（`decidePolicyFor` 认
  `navigationType == .reload`：顶上的按钮、右键菜单、页面自己调都算）置上 `restorePending`，页面加载好后来问时交出记下的位置一次
  （到这时才读记忆：刚滚完就刷新，旧页面卸下时 `pagehide` 补报的那一下排在新页面的询问之前），`p` 对得上才滚回去；
  图片、公式晚到会撑高内容，所以反复滚到位，到位且页面加载完稳定 0.5 秒、或 6 秒、或用户自己动了（滚轮 / 触摸 / 点按 / 按键）就停，
  滚回去之前不记。页内点链接去别的页照常从顶上开始；后退 / 前进由 WebKit 自己恢复。Mac 切走标签会把网页视图拆掉，切回来也走这条。
  「在浏览器中打开」不管。
  - 重新载入不能交给 WebKit（2026-11-20 用户报「不断点击刷新页面就会往上跑」，离屏实测加不加脚本都一样）：它在内容还没撑高时恢复，
    位置被截到当时的最大值（内容晚到的页 3000 → 300），滚动容器里的位置干脆回到 0；截短后的位置还会被脚本当成新位置记下。
- 文件还没同步下来：顶上一条提示「有 N 个文件还不在这台设备上」，下完自动重新载入。

### 3.2 在浏览器中打开（`Sources/App/WebDocLocalServer.swift`）

- 第一次用到才起：`NWListener` **只听 127.0.0.1**、端口系统给；地址 `http://127.0.0.1:<端口>/<口令>/<id>/<路径>`，口令每次启动随机。
- 同一套 `WebDocFiles`（`Sources/App/WebDocFiles.swift`）按路径回文件，类型 / Range / 404 与内嵌一致；大文件 1 MB 一块地发。
- html 响应里在 `<head>` 开头塞进 `window.unireader`（经 `fetch` 到 `…/__unireader__/api`），与内嵌读写同一份数据。
  API 只认同源请求（`Origin` 不对 → 403；跨源 JSON POST 要先预检，这里不答）。

## 4. 同步

- 两张表都在 `MirrorFp.specs`（`web_doc` / `web_kv` 都按 `updated_at` 取新；`last_opened_at` 不进指纹）。
- 离线镜像：建镜像时按库里全部清单拷文件（`MirrorBuilder.webFilesToCopy`）；合并后两边各按自己的清单向另一边要缺的文件（`MirrorApply.fillWebFiles`）。
- 服务器：线格式见 `PROTOCOL.md §9.8`。推 `web_doc` 行前先传文件、拉到后按清单补；上传整个工作区时 `Web/` 一起传。
  服务器只存文件，不清理（同 `Images/`）。端到端测试 `spike/server-client-test.sh`（网页那 5 项）。
- **补拉旧版跳过的这两张表**（`SyncClient.catchUp`，`meta.srv_catchup` 记补过哪几张）：旧版客户端拉取时跳过不认识的表、修订号却照样往前记，
  升级后只拉新改动就永远拉不到那些行，所以升级后要从修订号 0 补拉一次、只留这两张表的行（先清这两张表的基线，旧服务器忽略过的本机行重新推）。
  🔴 **补拉要把整个工作区从头过一遍**：只放在「打开前那一轮」（限时 2.5～3 秒、超时取消）里，大工作区每次都超时，关掉后那一轮又常被再次打开取消——
  2026-11-20 用户报 mac-mini 上 301 工作区（3.2 万个修订号、库 83MB）升级到 0.3.37 后网页一直是空的，库里 `srv_catchup` 一直没写上。
  修法同安卓 0.3.25 的 `ServerSync.catchUpWhileOpen`：Mac 开着工作区时再补一次（`ServerSyncCoordinator.catchUpWhileOpen`，
  拉取与解码在后台、`ServerSyncIO.fetchCatchUp` 逐页过滤；攒齐后等推送空下来，主线程用窗口那条连接 `ServerSyncIO.applyCatchUp` 清基线 + 应用 + 记上，
  再刷新列表、补网页文件）。补上之后打开前那一轮恢复原样。端到端测试多了「开着时补拉 / 补推」10 项。

## 5. `window.unireader`（`Sources/App/WebBridgeScript.swift`）

```js
await unireader.set('progress', { chapter: 3, done: [1, 2] })      // 任何能 JSON.stringify 的值
const p = await unireader.get('progress', { chapter: 1, done: [] }) // 第二个参数 = 没存过时的默认值
await unireader.remove('progress'); await unireader.keys(); await unireader.getAll(); await unireader.clear()
unireader.page            // { id, title }
window.addEventListener('unireader:ready', …)   // 脚本在页面最前面执行，一般用不着等
window.addEventListener('unireader:change', …)  // 内嵌显示时：服务器同步拉到别处改的数据（浏览器那条路不推）
```

- 只给这份网页自己的页面用：内嵌时核对消息来源的源（`unireader-web://<自己的 id>`），页面里嵌的外部 iframe 调不了。
- 课件里判断 `if (window.unireader)` 再用，放到别的地方（普通网页服务器）照样能跑。

### 5.1 只读查询（2026-11-22，`unireader.version = 2`）

课件里可以查工作区的习题库和做题状态（只读，不能改题、不能写作答）：

```js
await unireader.documents()                       // { documents: [{ id, title, page_count, exercise_count }], ungrouped_exercise_count, groups }
await unireader.exercises({ document, group, filter, tag, chapter, status, ids, offset, limit })
   // document = 文档 id / 前 8 位 / 准确标题；group = 不关联 PDF 的题的分组名（"" = 没分组）；filter = all | mistakes | starred；
   // status = any | new | practiced | last_correct | last_wrong；limit 默认 50、最多 200
   // → { total, offset, groups, exercises: [{ id, type, number, section, stem, options, answer, chapter, tags, starred, in_mistakes,
   //      attempts, correct, wrong, ungraded, last_correct, document_id | group, page(1 起), explanation?, note?, passage? }] }
await unireader.exerciseStatus({ document, group, chapter, filter, tag, status, ids })  // 轻量：每道题只有 id / number / chapter / attempts / correct / wrong / ungraded / last_correct / in_mistakes / starred / link，不带题干，不分页；watch 里重查用它
await unireader.exercise(id)                      // 单题（带文章全文）；没有 = null
await unireader.exerciseStats({ document?, group? })  // { total, practiced, unpracticed, mistakes, starred, attempts, correct, wrong, ungraded }
await unireader.attempts({ exerciseId?, exerciseIds?, document?, ungraded?, offset, limit })  // 作答记录，新的在前
await unireader.query(name, args)                 // 上面几个的底层
```

- 每道题都带 `link`：Mac 是 `unireader://open?ws=…&ex=<id>`（点了 `NSWorkspace` 打开 App 自己），安卓只有 `?ex=<id>`；
  安卓 `WebPageController` 拦下 `unireader://` 的点击，认 `ex` 参数：开那道题所在的一组、停在它上面（`ReaderActivity.openExerciseById`，找不到提示一句）；别的参数本端不处理。
- **监听**（同日）：`const stop = unireader.watch(() => 重查)`，习题 / 作答有变就调（自己答题 / 判定 / 清除 / 导入删除 / 同步拉到别处的改动；停手 300ms 才调一次，第二个参数改毫秒数）；
  底层是页面事件 `unireader:exercises`。内嵌（Mac）和安卓会推；**本机浏览器那条路不推**（同 `unireader:change`），要刷新就自己定时 `exerciseStats()`。
  Mac 在 `WebDocView` 接 `exercisesDidChange` / `exerciseDoneDidChange` / `exerciseAttemptDidRecord`；安卓在 `ExerciseController.onDataChanged` → `WebPageController.exercisesChanged`。
- 传输没改：`query` 是 `webKV` 的一个 op（`key` = 查询名，`value` = 参数 JSON）。Mac `WorkspaceManager+WebQuery.swift`，安卓 `local/web/WebQuery.kt`，
  🔴 名字 / 参数 / 字段两边逐项一致，改一边改两边。安卓补了读 `exercise.tags` 与 `exerciseUngradedCounts`。
- 还没有自动测试，等用户实测（内嵌 / 浏览器 / 安卓三条路各查一次）。

## 6. 删除与清理

- 侧栏右键「删除…」：**先归档进回收站再删**（红线⑪，`Trash.Kind.webDoc`，快照里是那一行 + 存的数据）；文件留在 `Web/`，
  回收站条目的 manifest `webFiles` 护住它们。🔴 `webFiles` 是可选键：老条目的 manifest 没有它，合成解码要求非可选键必须在。
- 清理（打开工作区 / 回收站变动时，`WorkspaceManager.purgeWebFiles`）：库里的网页与回收站都不用、且修改时间早于一天前的删掉。
  拷进来的文件修改时间一律记成「现在」（`WebAssets.copy`），否则导入到一半碰上清理会删掉刚拷的文件。

## 7. 入口

文件菜单「导入网页文件夹…」、侧栏「网页」段头右键；网页右键：在新标签页中打开 / 在浏览器中打开 / 重命名 / 首页 / 从文件夹重新导入 / 删除。
MCP：`get_state` / `get_current_view` 的标签报 `content_type: "web"` + `web_id`。

### 7.1 MCP 工具（批 9，2026-11-19 用户要「Agent 可以访问、更新这些 HTML」，`Sources/MCP/MCPTools+Web.swift`）

| 工具 | 级别 | 做什么 |
|---|---|---|
| `list_web_pages` | read | 列出网页（id / 标题 / 首页 / 文件数 / 还没下载的文件数） |
| `read_web_page` | read | 不给 `path` = 文件清单；给 `path` = 那个文本文件的原文（非 UTF-8 / 超 2 MB 拒绝） |
| `update_web_page` | write | 一次改：`edits`（精确替换，`old_text` 必须恰好出现一次）/ `files`（整份写，`content` 或 `source_path` 拷本机文件）/ `delete` / `title` / `start_page` |
| `create_web_page` | write | 新建：给 `files`，或 `folder` = 本机文件夹整个导入；`open` 顺便打开 |
| `open_web_page` | navigate | 在标签里打开，可指定某一页（标签已开着就跳过去，`.webDocNavigate`） |
| `delete_web_page` | delete | 删几份网页（连同存的数据）：先全部认出来，再逐个归档进回收站再删（红线⑪） |
| `read_web_page_data` / `write_web_page_data` | read / write | 读写 `window.unireader` 存的键值；写完开着的页面收到 `unireader:change` |

- 改文件 = 新内容落进 `Web/<新哈希>`、换清单、改 `updated_at`（`WorkspaceManager.changeWebDoc`）：开着的标签自己重新载入，随同步到别的设备；
  旧内容没人用了一天后被清理。网页存的数据不动。
- 网页可以被 id 全串、前 8 位或准确的标题指到（`MCPFacade.resolveWebPage`）。

## 8. 测试

- `spike/web-doc-test.swift`（67 项）：路径规则、清单编解码、按路径找文件、Range、导入、库读写、回收站回环、清理、脚本注入。
- `spike/web-scroll-test.swift`（23 项）：记住滚动位置那段脚本，真 WKWebView 离屏跑（记位置、内容晚到撑高也能滚到位、
  别的页不滚、用户动了不再拽回、铺满的滚动容器、连着刷新三次不往上跑且记忆不被截短、刚滚完马上刷新、清洗）。离屏页面算隐藏页面，WebKit 约 1 秒后给定时器降频，测试里等得久些。
- `spike/server-client-test.sh`：网页文件经服务器同步 + 存的数据双向同步。`server/` `swift test` 59 项、Linux 交叉编译通过。
- 视图层（标签页 / 侧栏 / 浏览器服务）**没有自动测试**，等用户实测。

### 8.1 实测清单（第一批）

1. 导入一个带图片 / css / js 的课件文件夹，侧栏出现、标签页里显示正常；选单个 html 导入，入口是它。
2. 课件里有视频：内嵌与浏览器里都能拖进度条（Range）。
3. 「在浏览器中打开」：默认浏览器打开、子页面链接与相对路径正常。
4. 课件里调 `unireader.set` / `get`：关掉再开还在；内嵌与浏览器读到同一份；另一台 Mac 经服务器同步后读到。
5. 重命名、换首页、从文件夹重新导入（存的数据保留）、删除后从「最近删除」恢复。
6. 服务器工作区：另一台设备同步后文件下来、显示正常（服务器程序要换成这一版）。
7. Agent：让它列出网页、读某个 html、改一段文字（开着的标签自动刷新）、新写一份课件并打开、读 / 改页面存的数据。
8. 回到首页（Mac + 安卓）：点进子页面 → 关掉标签再开（停在子页面、后退是灰的）→ 点房子图标回到首页、再点后退回到子页面；在首页时房子是灰的。
9. 记住滚动位置（Mac + 安卓）：一个长页滚到中间 → 切到别的标签再切回来 / 关掉标签再开 / 退出 App 再开，都停在刚才的位置；
   内容在侧栏布局的滚动区里的课件同样；滚回去的过程中自己滚一下，不会再被拽回去；点链接去别的页从顶上开始；
   带图片的长页滚到中间后连着点「重新载入」，位置不变。

## 9. 第二批：安卓模式1（2026-11-19 已写，待实测）

- 表：`Schema.kt` 两张表逐字同 Mac；`MirrorFp.kt` 两张表规格（向量 #41 / #42，`spike/mirror-fp-vectors.txt` 末尾追加）、`needsMigrate` 认 `web_` 前缀。
- 文件层 `local/web/WebAssets.kt`（逐条照 Mac：清单编码、路径规则、入口、Range、导入、清理）；`LibraryStore` 网页一节（SQL 照抄）。
- 回收站：`Trash.deleteWebDoc`（`KIND_WEB_DOC = "webDoc"`，manifest `webFiles`）、恢复认 `web_doc` / `web_kv`；开工作区时清理 `Web/`（同图片那一步）。
- 离线镜像：建镜像拷 `Web/`、合并后双向补文件（`MirrorApply.fillWebFiles`）。
- 服务器：推 `web_doc` 前传文件、拉到后在**网络线程**补文件（课件里可能有视频，别占库队列）、建缓存 / 上传工作区带 `Web/`。
- 界面：标签 `web:<id>`（`TabSet.WEB_PREFIX`）；整页 `local/web/WebPageController`（顶上一条 后退 / 前进 · 回到首页 · 标题 · 重新载入 + `WebView`）。
  文件经 `shouldInterceptRequest` 读，地址 `https://<id>.unireader-web.invalid/<路径>`（每份网页一个源）；`window.unireader` 注入 html
  （`WebBridge`），经 `addJavascriptInterface` 同步调库队列（`WebKV`，规则照 Mac）。🔴 JS 接口对所有框架可见：每次装载一个随机口令写进注入脚本，
  不带口令的调用一律拒。滚动位置（2026-11-20，同 §3.1）：`WebBridge.scrollSource` 与 Mac 那段 JS 逐字相同、只差传输
  （`__unireaderNative.scrollSave` / `scrollTarget`，同样带口令），记在 prefs `webPages` 的 `scroll.<id>`；口令和网页 id 一起换（`ScrollSlot`），
  旧页面晚到的报告记不到新那份上。重新载入（按钮 / 文件下完自动重载）走 `reload()`：先 `ScrollSlot.arm()` 再 `web.reload()`，同 Mac 由脚本滚回去。返回键网页里能退先退。抽屉书库页「网页」一组（点开 / 更多：改名、首页、从文件夹重新导入、删除）+「导入网页文件夹…」
  （目录浏览器 FOLDER 模式）；书库页（`LibraryActivity`）有网页时列一组、点开进阅读界面。
- Agent（`local/agent/AgentTools.kt`）：同 Mac 八个工具（含 `delete_web_page`）；`write_web_page_data` 的 `set` 在安卓是 `[{key, value}]`（值是 JSON 文本），
  Mac 是对象（Koog 的参数类型没有自由键对象）。
- 模式2（连 Mac 当输入板）：Mac 当前标签是网页时平板上不显示它（线格式没有这一种），没做。
- 测试：JVM 单测 260 项全过（含 `MirrorFpTest` 新向量）；插桩测试 / 平板端到端还没跑（这次平板没接着）。
- 服务器自带的网页阅读器要不要也能看网页：未定。

## 网页标签沉浸（2026-11-28，Mac）

- 网页铺满整块、伸到工具栏和顶上那一条后面：`WKWebView.obscuredContentInsets` 让出版面（macOS 26），
  它设了顶部内边距会自己挂一层系统边缘效果（`NSScrollPocket`，离屏实测），顶上那一条不再垫不透明底、按钮浮在模糊上（`WebHeaderStrip` 接住空白处的点击、可拖窗口）。
- 🔴 模糊层取色 = `underPageBackgroundColor`，默认等于网页底色：白底网页会把工具栏带成浅色。钉成 `.windowBackgroundColor`、外观切换时重设（`PITFALLS.md`「工具栏」）。
- **2026-11-28 统一到工具栏**（用户：「网页 标题…和 html 的标题（用这个）显示到 toolbar 的标题…跳转移除用 app 的」）：
  顶上那一条整个去掉；窗口标题 = 那一页的 HTML `<title>`（`WebDocView.onPageTitle` → `DocTabModel.webPageTitle` → `ReaderWindowController.refreshTitle`），
  副标题 = 网页名（与标题相同不重复）；后退 / 前进用 App 的「返回」与 ⌘[ ⌘]（`ReaderPaneController.navigate`：网页先走自己的历史）；
  首页 / 刷新 / 在浏览器中打开挪进网页独有的悬浮工具条 `WebToolCapsule`（系统材质胶囊、可拖、位置全局记 `webToolFrac*`，默认右上角）。
  不放进工具栏：工具栏随标签换按钮，切标签时整排会挪。
