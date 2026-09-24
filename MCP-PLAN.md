# MCP 服务方案（macOS 端，2026-09-13 首版）

> 状态：**方案已拍板（2026-09-13，决策见 §2）；三批已全部落地并于同日合入 `main`（批 1 用户实测通过，见 §15；批 2、批 3 待用户实测，清单在 §16.2 / §17.4）**。
> 目标：让外部 Agent（Claude Code、Codex 等命令行 Agent）通过 MCP 协议操作 UniReader——
> 前期只做**读取类**（打开工作区、打开文档、读 PDF 文本/目录/页图、看当前阅读位置），
> 后期再加**写入类**（跳页、书签、文字笔记、高亮、导入 PDF）。分批上线，每批都能单独交付。
>
> 本版**只做 macOS**。安卓端没有这个需求（Agent 跑在电脑上）。

---

## 0. 一句话定义

> **UniReader 自己就是一个 MCP 服务器**：App 开一个 HTTP 端点（默认只在本机回环地址，也可绑所有网络接口），Agent 连上来就能
> 「看到用户正在读哪本书的哪一页、把某几页的文字读出来、替用户打开某个工作区或文档」。

这与 `AI-PLAN.md` 是**相反的方向**：AI 面板是「App 里嵌网页版 AI，把选中内容发过去问」；MCP 是
「外面的 Agent 反过来驱动 App、读 App 里的数据」。两者互不依赖，只在「Agent 写进来的笔记要标来源」
这一处共用 `NoteSource`（见 §9.2）。

---

## 1. 需求与分批

**用户原话（2026-09-13）**：「给项目添加 MCP 功能，提供给其他 Agent 使用。MCP 能够完成的功能可以按批添加，
前期可以是打开项目，打开文件，读取 pdf，这些读取类的后面再加上写入类的。」

| 批次 | 性质 | 内容 | 交付物 |
|---|---|---|---|
| **批 1** | 读取 | 服务骨架（监听地址/端口/口令可配）+ `get_state` / `list_workspaces` / `open_workspace` / `list_documents` / `open_document` / `get_document` / `read_pages` | 能在 Claude Code 里 `claude mcp add` 后读书 |
| **批 2** | 读取 + 导航 | `search_text` / `render_page`（页图） / `get_current_view` / `list_annotations` / `goto`；MCP 资源（resources） | Agent 能「找到那段、看到那张图、翻到那页」 |
| **批 3** | 写入 | `add_bookmark` / `add_note` / `add_highlight` / `import_pdf`（含 `open_document` 接受库外路径） / `create_workspace` / `run_ocr`；写入开关 + 来源标记 | Agent 能把结论写回笔记、把 PDF 导进书库 |
| 批 1b（可选） | 兼容 | stdio 桥接小工具（给只支持 stdio 的客户端 + 自动拉起 App） | 单独一个可执行文件 |
| 批 1c（可选） | 兼容 | MCP 2026-07-28「新版」协议（无握手、`server/discover`） | 只改 `MCPProtocol.swift` |

「打开工作区 / 打开文档 / 翻页」这类动作**不写数据**，归「导航」，不受批 3 的写入开关管。
**往书库插行的都算写入**——所以「打开一个还不在书库里的 PDF」（= 导入）在批 3（决策 D7），批 1 的
`open_document` 只认库里已有的文档。读取工具带 `path` 参数直接读库外 PDF（纯 PDFKit，不碰书库）不受此限，见 §7.6。

---

## 2. 已拍板的决策（用户 2026-09-13）

| # | 问题 | 决定 | 落在哪 |
|---|---|---|---|
| D1 | 服务形态 | **App 内置** HTTP 服务（Streamable HTTP 传输），不做独立进程 | §3 |
| D2 | 页码 | 对 Agent **1 起**，内部 0 起，换算只在一处 | §6.2 |
| D3 | 依赖 | **自己写** JSON-RPC/HTTP 层，不引 SDK | §4.5 |
| D4 | 端口 | **可配置，默认 8773** | §4.6 / §10 |
| D5 | 监听地址与口令 | **监听地址可配置：默认只绑本机回环（`127.0.0.1`），也可以绑所有网络接口（`0.0.0.0`）**。回环模式**不必**设口令；**改到其他地址就必须设口令**，没口令服务不启动 | §4.6 |
| D6 | 写入工具可见性 | 写入开关关着时工具**照常列出**，调用时拦下并提示去设置里开 | §9.1 |
| D7 | 导入 PDF | **放批 3**：`import_pdf` 与 `open_document(path:)` 都在批 3；批 1 的 `open_document` 只认库文档 id | §7.5 / §7.13 |

---

## 3. 形态：App 内置服务，Streamable HTTP 传输

### 3.1 为什么是 App 内置、不是独立进程

- Agent 要的三样东西——**打开窗口**、**当前阅读位置**、**已打开文档的内存状态**（笔记/高亮/OCR 文本层）——
  全在 App 进程里。独立进程只能再造一条 IPC 把这些搬出来，等于做两遍。
- 🔴 **独立进程直连 `library.sqlite` 这条路不走**：`REQUIREMENTS.md §8.1` 明文「同一工作区路径必须共享同一个
  `WorkspaceManager`，否则两个 `LibraryStore` 会互相清库丢笔记」。哪怕只读，也不要在 App 之外再开一份库。
- 已有先例：`LANServer` 就是 App 内置的 HTTP + WebSocket 服务（`Network.framework`，无第三方）。MCP 照这个
  样子再起一个**独立的**监听，**不复用 `LANServer` 的端口和队列**（理由见 §5.3）。

### 3.2 为什么是 Streamable HTTP、不是 stdio

- stdio 传输要求「客户端拉起服务进程」，App 不能被 Agent 当子进程拉起（它是 GUI App，且单实例守卫会
  杀旧实例，见 `AppDelegate.applicationWillFinishLaunching`）。
- Streamable HTTP 是 MCP 现行的远程传输方式，Claude Code（`claude mcp add --transport http`）、Codex、
  Cursor 等主流客户端都直接支持，配置只是一条 URL。
- 只支持 stdio 的客户端 → 批 1b 的桥接小工具（§3.3），不改服务本身。

### 3.3 批 1b：stdio 桥接小工具（可选，批 1 验证好用了再做）

一个 Foundation 级别的命令行程序 `unireader-mcp`，随 App 打包在 `UniReader.app/Contents/MacOS/`：

- 从 stdin 逐行读 JSON-RPC，转发到 `http://127.0.0.1:<port>/mcp`，把响应写回 stdout；旧版协议要把
  `Mcp-Session-Id` 在两边之间原样带上。
- App 没在跑就 `NSWorkspace.openApplication`（按 bundle id）拉起，轮询 `/health` 最多 10 秒。
- 客户端配置成 `command: /Applications/UniReader.app/Contents/MacOS/unireader-mcp`。
- xcodegen 加一个 `tool` 类型的 target（`project.yml`），编译产物用 build phase 拷进 App 包。

它的价值只有两点：**自动拉起 App** 和 **兼容 stdio-only 客户端**。批 1 用 HTTP 直连就够，不要为它耽误主线。

---

## 4. 协议层

### 4.1 支持的协议版本

MCP 在 2026-07-28 出了一版**去掉初始化握手**的「新版」协议（无会话、每个请求自带版本与能力、
`server/discover` 取代 `initialize`），把之前的 2025-03-26 ~ 2025-11-25 统称「旧版」。截至本方案
（2026-09-13）主流客户端仍然主要说旧版，所以：

- **批 1 实现旧版**（`2025-06-18` 与 `2025-11-25` 两个版本号都接受，差异对我们用到的方法没有影响）。
- **批 1c 补新版**：加 `server/discover` 一个方法 + 从 `params._meta` 读版本号。调度器（§5.2）本来就设计成
  「会话可空」，新版接上只改 `MCPProtocol.swift`。两版并存（协议文档称 dual-era）。
- 判别办法：来 `initialize` 就是旧版客户端，来 `server/discover` 或请求带
  `_meta["io.modelcontextprotocol/protocolVersion"]` 就是新版。

### 4.2 旧版 Streamable HTTP 的具体行为（批 1）

| 项 | 做法 |
|---|---|
| 端点 | `POST http://127.0.0.1:8773/mcp`；另有 `GET /health` 回 `ok`（探活/桥接工具用） |
| 请求体 | 一个 JSON-RPC 2.0 对象。**不接受数组**（2025-06-18 起协议已去掉批量），来了回 `-32600` |
| 响应 | 永远 `Content-Type: application/json` 单个对象；**不做 SSE**（我们没有服务端主动推送的需求；协议允许服务器按请求选择） |
| 通知（无 `id`） | `notifications/initialized` / `notifications/cancelled` 等一律 `202 Accepted` 空体，不处理取消（所有操作都有上限，见 §7） |
| `GET /mcp` | `405 Method Not Allowed`（协议允许；表示我们不提供服务端推送流） |
| `DELETE /mcp` | 删会话，`200` |
| 会话 | `initialize` 成功时响应头发 `Mcp-Session-Id`（随机 32 字节十六进制）；之后请求带错/不带 → `404`（客户端会重新握手）。会话表在内存，记 `clientInfo`、协议版本、建立/最近时刻；30 分钟没动静就清 |
| `MCP-Protocol-Version` 头 | 读到就校验是否在支持列表，不在回 `400`；没带按 `2025-03-26` 处理（协议规定的兜底） |
| `Origin` | 带了且不是 `http://localhost[:port]` / `http://127.0.0.1[:port]` / `http://<本机监听地址>[:port]` → `403`（防 DNS 重绑定，协议要求）。命令行 Agent 不带 `Origin`，只有浏览器里的客户端才带 |
| 监听地址 | **可配置（D5）**：默认只绑 `127.0.0.1`（`NWParameters.requiredLocalEndpoint`）；设置里可切到「所有网络接口」（`0.0.0.0`），此时**必须有口令**，细则见 §4.6。IPv6 回环 `::1` 不绑——本机客户端一律用 `127.0.0.1` |
| `Authorization` | 设了口令就每个 `POST /mcp` 都要 `Authorization: Bearer <口令>`（含 `initialize`），否则 `401`；`/health` 不校验 |
| 请求体上限 | 4 MB；`Transfer-Encoding: chunked` 回 `411`（客户端都带 `Content-Length`） |
| 连接 | 响应后 `Connection: close`，一问一答。旧版客户端本来就是每个请求一个 POST |

`initialize` 的应答：

```json
{
  "protocolVersion": "2025-11-25",
  "capabilities": { "tools": { "listChanged": false }, "resources": { "subscribe": false, "listChanged": false } },
  "serverInfo": { "name": "UniReader", "version": "<MARKETING_VERSION>" },
  "instructions": "Pages are 1-based. Call get_state first to learn which workspace, document and page the user is looking at. document_id is a stable UUID inside a workspace; file paths may change. read_pages returns the PDF's own text, or cached OCR text for scanned pages."
}
```

`instructions` 用英文——它是给模型看的，不给用户看。批 1 只声明 `tools`；`resources` 到批 2 再打开。

### 4.3 JSON-RPC 方法表

| 方法 | 批次 | 说明 |
|---|---|---|
| `initialize` / `notifications/initialized` / `ping` | 1 | 握手、心跳 |
| `tools/list` / `tools/call` | 1 | 工具目录与调用（不分页，`nextCursor` 不给） |
| `resources/list` / `resources/templates/list` / `resources/read` | 2 | 资源（§8） |
| `server/discover` | 1c | 新版协议 |
| `prompts/*` / `completion/*` / `logging/*` | 不做 | 没有场景 |

### 4.4 错误分两层（别混）

- **协议错误**用 JSON-RPC `error`：解析失败 `-32700`、不认识的方法 `-32601`、工具名不存在或参数不合法 `-32602`。
- **工具执行失败**用 `tools/call` 的 `isError: true` + 一段人话（英文，给模型看）：「document not found」
  「page 400 is out of range (document has 312 pages)」「writes are disabled in UniReader › Settings › Agent」。
  模型读得懂就能自己纠正，这是协议推荐的做法。

### 4.5 为什么自己写、不引 SDK

- 协议面很小：旧版 6 个方法 + 新版 1 个，HTTP 只要 POST 单对象。`LANServer` 已经证明用
  `Network.framework` 手写 HTTP 够用。
- 项目至今**零第三方依赖**（SQLite 直接调系统库、线格式自写）；官方 Swift SDK 偏客户端与 stdio，
  HTTP 服务端还得配 Web 框架，引进来就是两三个包。
- 自己写的代价是要自己读一遍协议文档把细节对齐（§4.2 那张表就是对齐结果）；spike 测试覆盖调度器（§11）。

### 4.6 监听地址、端口与口令（D4 / D5，批 1 就做）

三个设置项（`UserDefaults`，口令本体在 Keychain）：

| 设置 | 取值 | 默认 |
|---|---|---|
| `mcpBind` | `loopback`（`127.0.0.1`）/ `all`（`0.0.0.0`，所有网络接口） | `loopback` |
| `mcpPort` | 1024~65535 | `8773` |
| `mcpToken` | Keychain 里的一串随机口令（同 `Pairing.persistentToken` 的做法，32 字节 base64url）；有/无 | 回环模式：无；所有接口模式：**自动生成** |

规则：

1. **回环模式**：口令可有可无（默认无）。设置里有「设置口令」按钮，想挡本机其他程序就点一下。
2. **所有接口模式**：切换过去的那一刻若没有口令就**自动生成一个**并显示；服务启动前再校验一次——
   🔴 **没口令绝不以 `0.0.0.0` 启动**（用户 2026-09-13 定），校验失败就回落到回环并在设置页给一行红字说明。
3. 口令校验在 HTTP 层做（§4.2 的 `Authorization` 行），在解 JSON-RPC 之前；`401` 响应体给一句
   `missing or wrong bearer token; copy it from UniReader › Settings › Agent`。
4. 「重置口令」= 换一串新的 + 清空会话表（已连上的客户端下次请求就 `401`，重配即可）。
5. 改监听地址或端口都要**重启服务**（`stop` → `start`，与 `LANServer.resetToken` 那套「主线程排队后再 start」的坑同款，别在 `isRunning` 还没翻回去时 `start`）。

所有接口模式的两点说明（写进设置页的辅助文字，不写进代码注释以外的地方）：

- 这是**明文 HTTP**，口令在局域网上明文传输——与平板配对码同一姿态，不做 TLS。适用场景是「Agent 跑在同一
  局域网的另一台机器/虚拟机/容器里」，不适合公网。
- macOS 防火墙开着时首次监听会弹「是否允许接受传入连接」，那是系统的框，不是我们的。
  `NSLocalNetworkUsageDescription` 已在 `project.yml` 里（平板服务加的），无需再加。

配置片段随模式变化（§10）：回环模式给 `http://127.0.0.1:<port>/mcp`；所有接口模式给
`http://<本机局域网 IP>:<port>/mcp`（`NetInfo.wifiIPv4()`，与 `LANServer.pageURL` 同一来源）+
`--header "Authorization: Bearer <口令>"`。

---

## 5. 代码结构与线程模型

### 5.1 新目录 `Sources/MCP/`

```
Sources/MCP/
  MCPServer.swift        监听（NWListener，回环或所有接口）+ 最小 HTTP/1.1 解析（POST + Content-Length，读满再解）+ 口令校验 + 会话表 + 设置开关
  MCPProtocol.swift      JSON-RPC 编解码、错误码、版本协商、方法调度（initialize/ping/tools/*/resources/*，1c 加 server/discover）
  MCPCatalog.swift       工具/资源注册表：name → (inputSchema, outputSchema, annotations, tier, handler)
  MCPTools+Workspace.swift   list_workspaces / open_workspace / create_workspace
  MCPTools+Document.swift    list_documents / open_document / get_document / read_pages / search_text / render_page / import_pdf / run_ocr
  MCPTools+Reader.swift      get_state / get_current_view / goto
  MCPTools+Notes.swift       list_annotations / add_bookmark / add_note / add_highlight
  MCPFacade.swift        🔴 全项目唯一碰 App 活状态的地方（@MainActor）：把 AppDelegate/WorkspaceRegistry/TabsModel/DocSession 拼成 DTO；写操作也只经它
  MCPDocReader.swift     离主线程读 PDF：私有 PDFDocument 缓存（LRU 4 份）、文本抽取、OCR 缓存读取、页图渲染
  MCPModels.swift        DTO（Codable）、id 规则、页码 1 起 ↔ 0 起换算（只在这里换）
```

`xcodegen generate` 后 `Sources` 整目录进 target，不用改 `project.yml`（批 1b 的桥接工具除外）。

### 5.2 请求的一生

```
NWListener(127.0.0.1 或 0.0.0.0 : port) ──serial queue "mcp.net"──▶ 解 HTTP → 校口令/Origin → 解 JSON-RPC → MCPProtocol.dispatch(session?, request) async
        │
        ├─ 纯协议方法（initialize/ping/tools/list）：原地应答
        └─ tools/call → MCPCatalog[name].handler(args) async throws
                 ├─ 要活状态 → await MainActor.run { MCPFacade... }   （只拼 DTO，几十微秒；绝不在主线程读 PDF）
                 └─ 要读 PDF → MCPDocReader（serial queue "mcp.doc"，私有 PDFDocument）
```

- `dispatch` 是**纯函数**：`(会话, 请求) → 应答`，不碰网络。spike 就测它（§11）。
- 会话参数**可空**——新版协议无会话，旧版有；调度器不依赖它，只用来记 `clientInfo`（写入来源标记要用）。
- 一个连接一个请求，串行处理；不做并发限制之外的复杂调度。`read_pages` 40 页的文本抽取在 `mcp.doc` 队列上
  跑几百毫秒，期间下一个请求排队等——可以接受，Agent 本来就是一问一答。

### 5.3 三条线程红线

1. 🔴 **`session.pdf` 只许主线程碰**（现有纪律，OCR 渲染已经为此单开了 `ocrRenderPDF`）。MCP 读文本/渲页图
   一律在 `MCPDocReader` 里**按路径另开一份 `PDFDocument`**，LRU 缓存 4 份（键 = 路径 + 内容 hash），
   文档关闭/工作区关闭时不必同步清（它只读文件，不持有会话）。
2. 🔴 **不上 `LANServer` 的串行队列**。那条队列是平板取页图的热路径（`PadLog` 里「距上次页图请求结束」那笔账），
   一次 40 页文本抽取塞进去平板就卡半秒。MCP 自己两条队列（`mcp.net` / `mcp.doc`）。
3. 🔴 **主线程只做拼装**：`MCPFacade` 里不许有循环遍历几千条笔迹、不许 `JSONEncoder` 大数组。
   笔迹只给「每页几条」的汇总（库里 `inkPageSummaries` 一条 GROUP BY，现成的）。

### 5.4 要给现有代码加的小口子（都是只读访问器或拆函数，不改行为）

| 位置 | 加什么 | 为什么 |
|---|---|---|
| `AppDelegate` | `readerWindows` 的只读访问（现在是 `private`）+ `keyReaderWindow` | `get_state` 要枚举窗口/标签；`open_document` 要找目标窗口 |
| `AppDelegate.openReaderWindow` | 拆一个 **`throws` 版本**，`NSAlert` 留在现有调用方 | Agent 调用失败要拿到错误文本，不能弹框卡住 |
| `ReaderWindowController` | 暴露 `windowId` / `tabs`（`tabs` 已是 `let`，`windowId` 现在 `private`） | 同上 |
| `ReaderWindowController.ingest(urls:)` | （批 3）拆出「算 hash + 入库 + 开标签」的 async 函数，面板/拖拽/MCP 三处共用 | `import_pdf` / `open_document(path:)` |
| `LibraryStore` | `ocrPages(contentHash:provider:) -> [OCRPage]` 批量读 | `read_pages` 对扫描页要一次拿多页 OCR 缓存；现在只有单页 `ocrPage(...)` |
| `DocSession` | （批 2）`currentSelection: (page, text)?`，**只在选区变化时写一次** | `get_current_view` 想给 Agent 看「用户选中了什么」；选区现在只在视图 `@State` 里，模型层拿不到。⚠️ 别每帧写，参考 `readZoom` 那条性能红线 |
| `Pairing` 同款 | `MCPToken`（批 1：口令生成/读取/重置，Keychain） | §4.6 |

---

## 6. 对象模型与约定

### 6.1 三个 id 空间（沿用 `PROTOCOL.md §4.1` 的划分，别混）

| 对象 | Agent 看到的键 | 来源 | 稳定性 |
|---|---|---|---|
| 工作区 | `path`（`.unrd` 绝对路径，**输入用它**）+ `id`（`meta.workspace_id`） | `WorkspaceRegistry` / `LibraryStore.ensureWorkspaceId` | id 跨改名/搬家稳定；path 是用户认得的 |
| 文档 | `document_id`（库文档 UUID） | `LibDocument.id` | 跨版本（variant）稳定；**不是**内容 hash |
| 窗口 | `window_id` | `ReaderWindowController.windowId` | 窗口生命周期内 |
| 标签 | `session_id` | `DocSession.id` | 标签生命周期内 |

所有工具的目标参数都**可省略**：省略 = 「key 窗口的活动标签」。Agent 大多数时候只关心用户眼前那本书，
省略参数就是最自然的写法；要指定别的文档再传 `document_id`。

### 6.2 页码：对外 1 起，对内 0 起

- 所有工具的入参、出参、文本里的「Page N」都是 **1 起**（D2）。
- 换算只在 `MCPModels.swift` 的 `PageNo` 一处做；`MCPFacade` / `MCPDocReader` 接口全部用内部 0 起。
- 出参另带 `label`（`PDFPage.label`，书自己印的页码，如 `xii` / `37`），与序号不同才带；**入参不接受 label**。

### 6.3 坐标

矩形一律**页内归一化 0~1、左上原点**——与 `InkStroke` / `TextNote.anchor` / `PROTOCOL.md` 同一约定，
写成 `[x, y, w, h]` 数组（与 payload 里 `rects` 同款）。

### 6.4 应答形态：`content` 给模型读，`structuredContent` 给程序用

每个工具同时返回两份（2025-06-18 起协议支持 `structuredContent` + `outputSchema`）：

- `content: [{type:"text", text: …}]`——紧凑的可读文本（Markdown 风格，如 `--- Page 12 (label 8) · native ---` 后接正文）；
- `structuredContent`——JSON 对象，字段按 §7 各表；工具声明 `outputSchema`。

页图工具的 `content` 是 `{type:"image", data:<base64>, mimeType:"image/jpeg"}`。

### 6.5 工具注解

按协议的 `annotations` 如实标：读取类 `readOnlyHint: true`；导航类 `readOnlyHint: false, destructiveHint: false, idempotentHint: true`；
写入类 `destructiveHint: false`（批 3 不提供删除）。客户端会据此决定要不要向用户确认。

---

## 7. 工具目录

> 参数省略规则见 §6.1。`pages` 这类范围参数写法：`"12"` / `"3-7"` / `"1-3,9,20-22"`。

### 7.1 `get_state`（批 1）— Agent 的第一问

入参：无。出参：

```json
{
  "app": { "version": "0.1.35", "pid": 4321, "writes_enabled": false, "bind": "loopback" },
  "key_window_id": "…",
  "windows": [{
    "window_id": "…", "is_key": true,
    "workspace": { "id": "…", "name": "考研数学", "path": "/Volumes/T7/考研数学.unrd", "is_mirror": false },
    "tabs": [{ "session_id": "…", "is_active": true, "document_id": "…", "title": "高等数学 上",
               "page": 12, "page_count": 312, "zoom": 1.0, "canvas_mode": false }]
  }],
  "tablet": { "running": true, "clients": 1 }
}
```

来源：`AppDelegate.readerWindows` → `tabs.tabs` → `DocSession`（`currentPageIndex` / `readZoom` / `canvasMode` /
`title` / `documentId`）+ `WorkspaceManager`（`name` / `folder`）+ `WorkspaceRegistry`（是否离线镜像）+ `LANServer`。
没有窗口时 `windows: []`，`key_window_id: null`——不报错。

2026-09-21 补 Markdown 标签：每个标签另带 content_type（empty / pdf / markdown）；Markdown 标签的
markdown 对象含 ref、来源、相对路径、链接与文件是否存在，不把正文塞进状态列表。get_current_view 遇到
Markdown 活动标签时返回编辑器的实时正文（包括尚未自动保存的改动）；目前不提供 Markdown 写入工具。

### 7.2 `list_workspaces`（批 1）

入参：无。出参 `workspaces: [{id, name, path, mirror_path?, is_open, window_ids: []}]`。
来源：`WorkspaceRegistry.recents`（最多 10 条）+ 当前开着的窗口。**不扫磁盘**。

### 7.3 `open_workspace`（批 1，导航）

入参 `{ path: string, activate?: bool = true }`。
逻辑 = 双击 `.unrd` 那条路：`WorkspaceManager.validate` → 已有窗口就激活 → 否则开新窗（走 §5.4 的 `throws` 版）。
出参 `{ workspace: {id,name,path}, window_id, was_open }`。
失败文本：`not a UniReader workspace: <path>`（`validate` 的错误原样带上）。
`activate=false` 时不 `NSApp.activate`（Agent 只想后台准备好，不抢焦点）。

### 7.4 `list_documents`（批 1）

入参 `{ workspace?: path, group?: string }`。出参：

```json
{ "workspace": {…},
  "documents": [{ "id": "…", "title": "…", "page_count": 312, "group": "上册",
                  "read_page": 12, "read_frac": 0.31, "last_opened_at": "…", "added_at": "…",
                  "file": { "path": "/…/x.pdf", "exists": true, "in_workspace": false },
                  "content_hash": "sha256…", "open_in": ["session_id…"] }] }
```

来源：`WorkspaceManager.documents` + `currentFilePath(documentId:)` + `hasLocalFileCached`。
🔴 `workspace` 指向的工作区**必须已开着**（有 `WorkspaceManager`）；没开 → 失败文本提示先 `open_workspace`。
不为「列个目录」临时开库（§3.1 那条红线）。

### 7.5 `open_document`（批 1，导航）

入参 `{ document_id: string, workspace?: path, window_id?: string, page?: int, activate?: bool = true }`。
**批 1 只认库文档 id**（D7）：传一个不在库里的 PDF 路径 = 导入 = 写入，在批 3 给 `open_document` 加
`path` 参数并与 `import_pdf` 共用同一条导入函数（§7.13）；批 1 里传了 `path` 直接按参数不合法拒绝。

- 某标签已在显示它 → 激活那个标签；否则在目标窗口 `tabs.open(id)`（活动标签是空标签就复用，
  否则新开——与用户点侧栏一致）；目标工作区没窗口 → 开窗并直接带 `docId`。
- `page` 给了就在打开后跳过去（同 `goto`）。
- 文件不在了（`missingDoc`）→ 标签照开（与用户点侧栏一致，界面会给重新关联的入口），出参 `file.exists=false`。

出参 `{ session_id, window_id, document: {…}, page }`。

### 7.6 `get_document`（批 1）

入参 `{ document_id?: string, path?: string, include_toc?: bool = true }`。
`path` = 直接读一个**库外** PDF（纯 PDFKit 打开文件，**不碰书库、不导入**，与 D7 不冲突）；
`read_pages` / `search_text` / `render_page` 的 `path` 参数同义。出参：

```json
{ "document": {…同 list_documents 一项…},
  "page_count": 312, "first_page_size_pt": [595, 842],
  "text": { "native_sample_pages": 5, "native_pages": 5, "ocr_cached_pages": 0 },
  "toc": [{ "title": "第一章 函数", "page": 1, "children": [{ "title": "§1 集合", "page": 3 }] }] }
```

- `toc` 来自 `TOCEntry.build(from:)`（现成）；没有目录 → `[]`。
- `text` 是给 Agent 判断「这书能不能直接读文字」的：抽样前 5 页看原生文本（`NativePDFTextProvider.isLikelyScanned`），
  再数 `ocr_page` 里有几页缓存（`ocrPageCount`）。扫描件没 OCR 时 Agent 就知道该提醒用户先跑 OCR（批 3 `run_ocr`）。

### 7.7 `read_pages`（批 1）— 核心

入参 `{ document_id?: string, path?: string, pages?: string, prefer?: "auto"|"native"|"ocr" = "auto", max_chars?: int = 200000 }`。
`pages` 省略 = 该文档当前页（开着）或第 1 页。**上限 40 页/次**，超了直接失败让 Agent 分次。

每页取文本的规则（`auto`）：
1. 原生：`PDFPage.string`（私有 `PDFDocument`，`mcp.doc` 队列）。字符数 ≥ 8 就用它，`source: "native"`。
2. 否则查 OCR 缓存：`ocrPages(contentHash:provider:)`，按行 y→x 排、同行按 x 拼，行间换行；
   用 `OCRWatermark.buildProfile/mask`（纯函数）滤掉平铺水印——与阅读区 `ocrVisibleRuns` 同一条判据。`source: "ocr"`, 带 `provider`。
3. 都没有 → `source: "none"`，`text: ""`，并在整体 `hint` 里写：`pages 3-7 are scanned and have no OCR text yet; ask the user to run OCR in UniReader (or call run_ocr)`。

出参：

```json
{ "document_id": "…", "pages": [{ "page": 12, "label": "8", "source": "native", "chars": 1830, "text": "…" },
                                 { "page": 13, "source": "ocr", "provider": "paddle-http", "text": "…" }],
  "truncated": false, "hint": null }
```

`max_chars` 超了就在那一页截断并置 `truncated: true`，后面的页不再给（`content` 文本里最后一行写
`[truncated; continue from page N]`）。

`content_hash` 从哪来：文档开着 → `session.contentHash`；没开 → 该文档**最新一个 variant** 的 `contentHash`
（`variants(documentId:)` 按 `addedAt` 取最后）。

### 7.8 `search_text`（批 2）

入参 `{ document_id?: string, path?: string, query: string, pages?: string, max_hits?: int = 50 }`。
原生：`TextSearch.find`（`PDFDocument.findString`，现成）→ 每个命中取 ±80 字符上下文
（`page.string` 里按命中行文本定位）；OCR 页：在缓存的 `runs` 里做不区分大小写包含匹配（与 `DocSession.searchOCR` 同法）。
出参 `hits: [{page, snippet, rects: [[x,y,w,h]]}]`。

### 7.9 `render_page`（批 2）

入参 `{ document_id?: string, path?: string, page: int, width?: int = 1080, format?: "jpeg"|"png" = "jpeg" }`。
`width` 归到 `LANServer.pageWidthSteps` 的档位、上限 2160（与平板同一张阶梯，`PageRenderEngine` 缓存能共享命中）。
渲染用 `PageRenderer.image(page:pixelWidth:format:)`（现成），在 `mcp.doc` 队列。
出参：`content` 一张 `image`；`structuredContent: {page, width, height, mime}`。
**只渲原页**，不叠笔迹/高亮（与 `/page.png` 同口径）；`with_annotations` 参数留名字，批 3 再看要不要做。

### 7.10 `get_current_view`（批 2）

入参 `{ window_id? }`。出参 `{ window_id, session_id, document_id, page, frac, zoom, canvas_mode, selection?: {page, text} }`。
`frac` 来自 `session.jumps.currentMark`（页 + 页内比例）；`selection` 依赖 §5.4 那条 `currentSelection`，
没做之前字段省略。

### 7.11 `list_annotations`（批 2）

入参 `{ document_id?: string, kinds?: ["note","highlight","bookmark","ai_thread","scratch_pad","ink"], pages?: string }`。
出参各一组：

- `notes: [{id, page, rect, quote, text, type, display, source: {kind, provider}?, created_at, updated_at}]`
- `highlights: [{id, page, rect, quote, color: "#RRGGBB"}]`
- `bookmarks: [{id, page, frac, title}]`
- `ai_threads: [{id, provider, url, title, page}]`
- `scratch_pads: [{id, title, anchor_page}]`
- `ink: { pages: [{page, count}] }`（只有汇总，**不给点**）

来源：文档在某标签开着 → 读 `DocSession` 的数组（内存真源，含节流中未落库的改动）；没开 →
`WorkspaceManager.textNotes/highlights/bookmarks/aiThreads/scratchPads(documentId:)` + `store.inkPageSummaries`。

### 7.12 `goto`（批 2，导航）

入参 `{ page: int, frac?: double = 0, session_id?: string, document_id?: string, window_id?: string }`。
实现：`session.jump(page:frac:kind: .list, label: "Agent", origin: "mcp")`——走跳转历史（用户 ⌘[ 能跳回来），
`origin != "mac"` 会驱动阅读区滚动（`PageStreamView` 的 `foreignAnchor` 路径），平板跟随照常。
`ScrollAnchor.origin` 现有取值 `mac/pad/toc/search/restore`，加 `mcp`；消费方只判 `!= "mac"` / `!= "pad"`，不用改。

### 7.13 批 3 写入工具（设计定了，细节到时候再核）

| 工具 | 入参 | 实现落点 | 备注 |
|---|---|---|---|
| `add_bookmark` | `document_id?, page, frac?, title` | 开着 → `session.bookmarks.append`；没开 → `workspace.saveBookmark` | `title` 必填（`Bookmark.validTitle`，用户 2026-09-02 拍板） |
| `add_note` | `document_id?, page, text, quote?, rect?, type?` | 同上两条路（`textNotes` / `saveTextNote`） | 锚点：给了 `quote` 就在该页 `findString` 取行框；给 `rect` 直接用；都没有 → 页左上 `[0.05,0.05,0.9,0.02]` 一条横条。`source` 见 §9.2 |
| `add_highlight` | `document_id?, page, quote, color?, style?` | 同上（`highlights` / `saveHighlight`） | `quote` 在该页找不到 → 失败，不猜；`style` = fill / underline / box（2026-09-16 加，缺省 fill） |
| `import_pdf` | `path, workspace?, group?, open?: bool = false` | §5.4 拆出的导入函数（`FileHasher.sha256Cached` 后台算 hash → `workspace.ingest`）；`open=true` 再开标签 | **同一文件已在库里就是同一篇**（`findOrCreate` 按 hash 去重），不会重复插行；大文件算 hash 要几秒，工具等它算完再应答。同一批给 `open_document` 加 `path` 参数 = `import_pdf(open: true)` |
| `create_workspace` | `path` | `WorkspaceManager.createWorkspace(at:)` + 开窗 | 路径必须以 `.unrd` 结尾 |
| `run_ocr` | `document_id?, pages` | `session.enqueueOCR`（文档必须开着，OCR 走会话的队列） | 立即返回 `{queued: n}`；Agent 之后再 `read_pages` |

**不做**：删除任何东西、写笔迹、改阅读进度、改工作区/文档名。真要删让用户自己动手。

---

## 8. 资源（批 2）

工具是主路径（模型主要靠工具）；资源只是给支持它的客户端一个「把某页当附件拖进上下文」的入口，
内容与工具完全一致，**不另起一套读法**。

| URI 模板 | 内容 | mime |
|---|---|---|
| `unireader://state` | 同 `get_state` | `application/json` |
| `unireader://doc/{document_id}` | 同 `get_document` | `application/json` |
| `unireader://doc/{document_id}/page/{page}` | 同 `read_pages` 单页（文本） | `text/plain` |
| `unireader://doc/{document_id}/page/{page}/image` | 同 `render_page`（`blob` base64） | `image/jpeg` |
| `unireader://doc/{document_id}/toc` | 目录 | `application/json` |

`resources/list` 只列当前开着的文档（每篇一条 `unireader://doc/{id}`），其余靠 `resources/templates/list`。
不做 `subscribe`。

---

## 9. 写入策略（批 3 的地基，批 1 就把位子留好）

### 9.1 开关

设置 › Agent 页一个开关「允许 Agent 写入（书签/笔记/高亮/导入）」，默认**关**。关着时写入工具照常出现在
`tools/list`（D6），调用回 `isError` + `writes are disabled in UniReader › Settings › Agent`。
`get_state.app.writes_enabled` 也报出来，Agent 不用试。

### 9.2 来源标记：Agent 写的笔记要认得出来

`NoteSource.kind` 现在恒为 `"ai"`（AI 面板回填）。加一个 `"agent"`：

```json
"source": { "kind": "agent", "provider": "claude-code", "url": "", "at": "…" }
```

`provider` = `initialize` 里 `clientInfo.name`（新版协议从 `_meta` 取）。`url` 空串（`NoteSource.url` 非可选，不改类型）。
旧 payload 无 `source` → nil，**零迁移**（与 `type_id` 同一先例）；安卓端读 `source` 只看有无，不认 kind，不受影响。
Inspector 里 `isAI` 的角标逻辑加一个 Agent 角标（图标 `terminal`），筛选也能按来源筛。

### 9.3 🔴 写入的两条路径，按文档开没开分（漏一条就丢数据）

- 文档**在某个标签开着** → 只许改 `DocSession` 的数组（`textNotes` / `highlights` / `bookmarks`），
  由 `DocTabModel` 现有的对账逻辑落库并广播平板。
  **直接写库会被对账当成「内存里没有的行」删掉**——这就是 `ink-edit-three-paths` 那条教训的笔记版。
- 文档**没开** → `WorkspaceManager.save*`（记账队列）。
- 判「开没开」要遍历所有窗口所有标签（`WorkspaceRegistry.window(for:)` 那张表按 session 分，没有按文档的索引；
  `MCPFacade` 自己扫，几十个标签而已）。

### 9.4 口令与写入的关系

口令在批 1 就有（§4.6，跟着监听地址走），**不是**写入开关的一部分：回环模式下没口令也能开写入，
所有接口模式下有口令但写入开关照样默认关。两个开关各管各的——口令管「谁能连」，写入开关管「连上了能不能改」。

---

## 10. 设置与配置片段

设置窗加一页 **Agent**（`SettingsTab.agent`，图标 `terminal`；文案走 `L()`，`en` / `zh-Hans` 两份 `.strings` 同步）：

- 开关「启动时开启 MCP 服务」（`@AppStorage("mcpAutoStart")`，同 `autoStartServer` 先例，默认关）+ 状态行（运行中 / 监听地址:端口 / 已连接客户端名与版本）
- 「监听地址」选择：只限本机（127.0.0.1）/ 所有网络接口（`Picker`，系统样式）；选「所有网络接口」时下面显示一行辅助文字（§4.6 那两点）
- 端口输入框（默认 8773；改地址或端口都要重启服务，界面上直接做「保存并重启」）
- 口令区：当前口令（可复制）/「设置口令」（回环模式可选）/「重置口令」；所有接口模式下口令必有、不能删
- 「允许 Agent 写入」开关（批 3）
- 配置片段（只读文本 + 复制按钮，随模式与口令变化）：

  回环、无口令：
  ```
  claude mcp add --transport http unireader http://127.0.0.1:8773/mcp
  ```
  ```json
  { "mcpServers": { "unireader": { "type": "http", "url": "http://127.0.0.1:8773/mcp" } } }
  ```
  有口令（回环设了口令，或所有接口模式；URL 里的地址按模式给 `127.0.0.1` 或本机局域网 IP）：
  ```
  claude mcp add --transport http unireader http://192.168.1.20:8773/mcp --header "Authorization: Bearer <口令>"
  ```
  ```json
  { "mcpServers": { "unireader": { "type": "http", "url": "http://192.168.1.20:8773/mcp",
                                   "headers": { "Authorization": "Bearer <口令>" } } } }
  ```
  其他客户端本质都是这一条 URL + 一个请求头，写法看各家文档。
- 最近调用（最多 50 条：时刻 / 客户端 / 工具 / 耗时 / 成功或错误摘要）——排障用，进程内环形缓冲，不落盘。

菜单：「服务」菜单（或现有平板服务旁边）加「MCP 服务：开/关」，与设置页同一个状态。

🔴 UI 红线照旧：系统标准控件，不自绘；material 底上文字显式 `.primary`。

---

## 11. 日志、测试与验收

### 11.1 日志

`mcpLog`，同 `wsLog`/`PadLog` 的开关方式：`touch ~/Library/Logs/UniReader-mcp.log` 开、删文件关。
记每个请求一行：方法 / 工具名 / 参数摘要（**不记 `text` 全文**）/ 耗时 / 结果。

### 11.2 spike（我能自证的部分）

`spike/mcp-protocol-test.swift`：不起网络，直接喂 JSON 给 `MCPProtocol.dispatch`，用一个假的 `MCPFacade`
（协议抽象成 `protocol MCPFacadeType`，测试里塞固定数据）。覆盖：

- 握手：`initialize` 版本协商（三种版本号 + 不支持的版本）、`initialized` 通知回 202、没握手就 `tools/call` 回错
- `tools/list` 的 schema 合法（每个工具 `inputSchema.type == "object"`）
- `tools/call`：不存在的工具 `-32602`；参数缺失/类型错 `-32602`；执行失败 `isError`
- 页码换算：`"1-3,9"` → 内部 `[0,1,2,8]`；越界报错文本带页数
- `read_pages` 的截断与 `hint` 生成
- HTTP 解析（`MCPServer` 里把「字节 → 请求」拆成纯函数）：头部与体分两次到达、Content-Length 不足、超 4 MB、Origin 校验
- 口令：设了口令时无头/错头 → `401`，`/health` 不受影响；所有接口模式 + 无口令 → 启动被拒并回落回环（把「启动前校验」拆成纯函数测）

### 11.3 用户实测清单（我不能自证，见 `user-must-test`）

```bash
# 1. 探活
curl -s http://127.0.0.1:8773/health
# 2. 握手（记下响应头里的 Mcp-Session-Id）
curl -si http://127.0.0.1:8773/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}'
# 3. 看状态
curl -s http://127.0.0.1:8773/mcp -H 'Content-Type: application/json' -H 'Mcp-Session-Id: <上面的>' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_state","arguments":{}}}'
# 4. 真客户端
claude mcp add --transport http unireader http://127.0.0.1:8773/mcp
# 然后在 Claude Code 里问：「我正在读哪本书的哪一页？把这一页的内容读给我」
# 5. 口令与所有接口模式（设置里切到「所有网络接口」后，从另一台机器或本机换 IP 访问）
curl -si http://<本机IP>:8773/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'   # 期望 401
curl -si http://<本机IP>:8773/mcp -H 'Content-Type: application/json' -H 'Authorization: Bearer <口令>' \
  -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'   # 期望 200
```

验收点：① 在 Claude Code 里能列出工具；② `get_state` 报的页码与窗口标题一致；③ `read_pages` 对原生 PDF 出正文、
对已 OCR 的扫描页出 OCR 文本、对没 OCR 的页给出提示；④ `open_workspace`/`open_document` 打开的窗口/标签与手动
操作一致（已开着的不重开）；⑤ 开着 MCP 服务时阅读区手感与平板取图无变化（§5.3）；⑥ 所有接口模式下无口令
拒绝、有口令通过，把口令删掉再切模式会被拦回回环。

---

## 12. 与代码现状的核对（2026-09-13）

| 依赖点 | 现状 | 结论 |
|---|---|---|
| 窗口枚举 | `AppDelegate.readerWindows` 是 `private`；`ReaderWindowController.windowId` 是 `private` | 加只读访问器（§5.4） |
| 开窗 | `openReaderWindow` 失败弹 `NSAlert` | 拆 `throws` 版 |
| 工作区路由 | `WorkspaceRegistry.route(to:strict:)` 现成，含「已有窗口就激活」 | 直接用；但它不返回窗口，之后用 `hasWindow`/访问器找 |
| 打开文档到标签 | `TabsModel.open(_:)` 现成（复用空标签 / 已开则激活） | 直接用 |
| 导入 PDF | `ReaderWindowController.ingest(urls:)` 内联了 hash + 入库 + 开标签 | 批 3 再拆函数三处共用 |
| 口令存储 | `Pairing.persistentToken()` / `resetToken()`（Keychain，`Sources/Support/Keychain.swift`） | 照抄成 `MCPToken`，另一个 Keychain 键 |
| 本机局域网 IP | `NetInfo.wifiIPv4()`（`LANServer.pageURL` 在用） | 所有接口模式的配置片段直接用 |
| 页文本 | `PDFPage.string`（PDFKit）；`NativePDFTextProvider.textLayer` 至今是 TODO 骨架 | 不动它，MCP 自己在 `MCPDocReader` 抽 |
| OCR 缓存 | `LibraryStore.ocrPage(contentHash:page:provider:)` 单页；`OCRWatermark` 是纯函数 | 加批量读；水印过滤直接复用 |
| 目录 | `TOCEntry.build(from:)`（`Sources/Views/TOCView.swift`）| 直接用（它住在 Views 里但不依赖视图；顺手挪不挪到 App/ 随意） |
| 全文搜索 | `TextSearch.find` + `DocSession.searchOCR`（私有） | 前者直接用；后者的逻辑复制到 `MCPDocReader`（十几行） |
| 页图 | `PageRenderer.image(page:pixelWidth:format:)` + `LANServer.pageWidthSteps` | 直接用 |
| 跳转 | `DocSession.jump(page:frac:kind:label:origin:)`；`origin` 消费方只判 `!= "mac"` / `!= "pad"` | 加 `"mcp"` 取值即可 |
| 笔记来源 | `NoteSource.kind` 目前只有 `"ai"` | 加 `"agent"`，零迁移 |
| 设置窗 | `SettingsTab` 枚举 + `SettingsTabController`（AppKit 标签） | 加一个 case，照 `tablet` 页写 |
| 主线程隔离 | `WorkspaceManager` 是 `@MainActor`，`AppModel` 不是 | `MCPFacade` 标 `@MainActor`，从工具里 `await MainActor.run` 进去 |
| 端口 | 8770/8771 TCP、8772 UDP 已占 | 8773 TCP 空着 |

---

## 13. 落地顺序与工作量

| 步 | 内容 | 量级 |
|---|---|---|
| 1 | `MCPServer` 监听（回环/所有接口）+ HTTP 解析 + 口令校验 + 会话表；`MCPToken`；`/health`；设置页（开关 / 监听地址 / 端口 / 口令） | ~400 行 |
| 2 | `MCPProtocol` 调度器 + `MCPCatalog` + spike 骨架 | ~300 行 |
| 3 | `MCPFacade` + §5.4 的访问器/拆函数；`get_state` / `list_workspaces` / `open_workspace` / `list_documents` / `open_document` | ~350 行 |
| 4 | `MCPDocReader` + `get_document` / `read_pages`（含 OCR 缓存与水印过滤） | ~300 行 |
| 5 | 设置页配置片段（随模式/口令变化）+ 最近调用列表 + 双语文案；用户按 §11.3 实测 | ~150 行 |
| — | **批 1 交付** | ≈ 1500 行 |
| 6 | 批 2：`search_text` / `render_page` / `get_current_view` / `list_annotations` / `goto` / resources | ~500 行 |
| 7 | 批 3：写入开关 + 来源标记 + 六个写入工具（含导入函数拆分、`open_document(path:)`） | ~500 行 |
| 8 | 批 1b / 1c 视需要 | 各 ~150 行 |

每步结束 `xcodegen generate` + `xcodebuild … -derivedDataPath build/dev`（产物纪律见 `AGENTS.md`）。

---

## 14. 红线汇总（做的时候对着查）

1. 🔴 默认只绑 `127.0.0.1`；绑所有接口**必须有口令，没口令不启动**（回落回环）；校验 `Origin`；不复用 `LANServer` 的端口与队列。
2. 🔴 不在 App 之外再开 `LibraryStore`；`list_documents` 等一律要求工作区已开着；批 1 不往书库写任何行（导入在批 3）。
3. 🔴 `session.pdf` 不出主线程；MCP 读 PDF 用 `MCPDocReader` 的私有 `PDFDocument`。
4. 🔴 主线程只拼 DTO，不遍历笔迹点、不编码大数组。
5. 🔴 写入按「文档开没开」分两条路（§9.3），开着时只改 `DocSession` 数组。
6. 🔴 页码换算只在 `MCPModels.PageNo` 一处；对外 1 起。
7. 🔴 每次调用有上限（40 页 / 200k 字符 / 一张页图 / 4 MB 请求体），不做取消。
8. 🔴 设置页文案双语、系统控件、`.primary` 颜色。
9. 🔴 不提供删除类工具。

---

## 15. 实现记录 — 批 1（2026-09-13 落地，分支 `worktree-mcp`）

`xcodebuild … -derivedDataPath build/dev` 通过；两个 spike 全绿（协议层 68 项、监听链路 31 项）。
**用户 2026-09-13 实测通过**（「agent 可以调用到这些信息了」）。

### 15.1 文件（与 §5.1 的出入）

| 文件 | 内容 | 与方案的差别 |
|---|---|---|
| `Sources/MCP/MCPModels.swift` | `MCPObject` / `MCPJSON` / `MCPToolError`（→ isError）/ `MCPInvalidParams`（→ -32602）/ `PageNo`（1 起 ↔ 0 起唯一换算点）/ `MCPArgs` 入参读取器 / `MCPSchema` | — |
| `Sources/MCP/MCPHTTP.swift` | 字节 → 请求（按 `Content-Length` 读满）、应答 → 字节、`Origin` / `Bearer` / 口令定长比较，全是纯函数 | 从 `MCPServer` 拆出来单独一个文件，为了 spike 能直接喂字节 |
| `Sources/MCP/MCPCatalog.swift` | 工具注册表：`MCPTool`（name / schema / tier / handler）、`MCPToolResult`（text + structuredContent + image）、两层错误映射、写入开关拦截 | — |
| `Sources/MCP/MCPProtocol.swift` | 版本协商、`MCPSession` + `MCPSessionStore`（actor，30 分钟清）、`MCPDispatcher.dispatch(body:session:)` 纯逻辑 | `resources/list` / `resources/templates/list` / `prompts/list` 批 1 就应答空列表（有客户端会无差别探一遍） |
| `Sources/MCP/MCPServer.swift` | `mcpLog`、`MCPToken`（Keychain）、`MCPServer`（`NWListener` 回环或所有接口、口令/Origin/版本头校验、会话、面板账）| 多了 `tokenProvider` 注入点（spike 不碰真 Keychain）；「最近调用」环形缓冲 50 条 |
| `Sources/MCP/MCPFacade.swift` | `@MainActor` 唯一活状态入口：`state` / `workspaces` / `openWorkspace` / `documents` / `openDocument` / `resolveTarget` | 文件下落用只读探测（不走 `openTarget`，那个会写 lastOpened） |
| `Sources/MCP/MCPDocReader.swift` | 私有 `PDFDocument` LRU 4 份 + OCR 文本层缓存 2 本；原生文本 / 抽样 / 目录 / OCR 行拼段落（滤水印） | `allOCRPayloads` 库里本来就有，§5.4 那条「加批量读」作废；页图渲染没做（批 2 的事） |
| `Sources/MCP/MCPTools.swift` + `MCPTools+Workspace.swift` + `MCPTools+Document.swift` | 七个工具的 schema / 文本拼装 / 处理函数 | 方案写的是四个 `MCPTools+*.swift`，批 1 只需要两个；`+Reader` / `+Notes` 到批 2/3 再加 |
| `Sources/Views/MCPSettingsView.swift` | 设置 › Agent 页（服务开关 / 监听地址 / 端口 / 口令 / 配置片段 / 已连接客户端 / 最近调用） | 端口改完要按回车才重启（改到一半的数字不能拿去重启） |
| `spike/mcp-protocol-test.swift` / `spike/mcp-server-test.swift` | 见文件头的运行命令 | — |

现有代码只动了四处：`AppDelegate.readerWindowControllers`（只读访问器）+ `makeReaderWindow(…) throws`（`openReaderWindow` 改为调它并保留弹框）、
`ReaderWindowController.windowId` 改成 internal、`AppModel.mcp`、`applicationDidFinishLaunching` 里装配工具目录 + 按设置自启。
`SettingsTab` 加 `agent`；双语文案各加 35 条。

### 15.2 行为要点（读代码前先知道）

- **口令与监听地址在批 1 就做了**（决策 D5）：`MCPServer.start()` 发现「所有接口 + 无口令」→ 回落回环并写 `lastError`；
  设置页切到「所有接口」时没口令就当场生成。`/health` 不校验口令。
- `open_document` 只认库文档 id（决策 D7）；读取类工具的 `path` 参数直接读库外 PDF（不碰书库）。
- `read_pages` 的 `auto`：原生文本 ≥ 8 字符就用它，否则查 OCR 缓存（`PaddleOCR.providerID`），行按 y 分行、x 排序拼段落，
  水印按 `OCRWatermark` 整本指纹过滤；都没有 → `source: "none"` + `hint`。
- 会话表在 `restart()` / `stop()` 时清空，改口令/地址/端口后客户端要重新握手（旧版客户端收到 404 会自动做）。

### 15.3 用户实测（按 §11.3；另加两条）

```bash
open build/dev/Build/Products/Debug/UniReader.app     # 在 worktree 目录下
# 设置 › Agent → 启动；然后 §11.3 的 1~4
```
⑦ 设置页「复制」出来的 Claude Code 命令直接能用；⑧ 「所有网络接口」模式下口令自动出现、「删除口令」灰掉。

### 15.4 批 1 已知未做

- 「服务」菜单里的 MCP 开关（方案 §10 提了一句）没加，只有设置页——够用就不加了。
- 新版协议（2026-07-28，`server/discover`）没做，等客户端开始发再补（批 1c）。

---

## 16. 实现记录 — 批 2（2026-09-13 落地，同一分支，待用户实测）

编译通过；协议层 spike 加了资源与页码筛选 9 项（77/77），监听链路 31/31 不变。**没有启动 App 自测**。

### 16.1 新增

| 东西 | 在哪 | 要点 |
|---|---|---|
| `search_text` | `MCPTools+Document.swift` + `MCPDocReader.searchNative/searchOCR` | 原生走 `PDFDocument.findString`（与 ⌘F 同路），摘要 = 选区两头各扩 80 字符再压平；OCR 缓存逐行包含匹配，**同一页两层都有只报原生**；`pages` 筛选、`max_hits` 默认 50 |
| `render_page` | 同上 + `MCPDocReader.render` | `PageBitmap.render` + `PageRenderer.encode`（与 `/page.png` 同一条原语），宽度归 `pageWidthSteps` 档、上限 2160；返回 `image` 内容 + 尺寸 |
| `get_current_view` | `MCPTools+Reader.swift` + `MCPFacade.currentView` | 页/页内比例取 `scrollAnchor`；`chapter` 用 `TOCEntry.chapterLabel`；`selection` 取 `DocSession.currentSelection` |
| `goto` | 同上 + `MCPFacade.goto` | `session.jump(kind: .list, label: "Agent", origin: "mcp")`，进跳转历史；**默认不抢焦点**（`activate=false`，与 `open_document` 相反——翻页时用户多半正在终端里打字） |
| `list_annotations` | 同上 + `MCPFacade.annotations` | 七类（note / highlight / bookmark / image_note / ai_thread / scratch_pad / ink 汇总）；开着读 `DocSession`、没开读库；**不要求文件在**（文件丢了的文档照样有笔记） |
| 资源 | `MCPResources.swift` + `MCPCatalog.resources` + `MCPProtocol` 三个 `resources/*` 方法 | 五条 URI（§8 那张表），**每条就是调一次对应工具再取 `structuredContent`/图片**，没有第二套读法；`initialize` 装了提供者才声明 `resources` 能力 |
| 选区镜像 | `DocSession.currentSelection`（普通属性）+ `PageStreamView` 里一个 `onChange` | 🔴 `onChange` **不能再挂主修饰符链**（多一个就超类型检查器时限，2026-09-13 实测），搭在框选覆盖层的 `ZStack` 里；换文档 `DocTabModel.load` 清空 |
| `PageNo.parse(limit:)` | `MCPModels.swift` | 筛选类参数（搜索 / 批注列表）传 `Int.max`，不受 40 页上限 |

### 16.2 用户实测清单

在 Claude Code 里：① 「在这本书里找 X」→ `search_text` 报页码与摘要；② 「看看第 N 页的图」→ `render_page` 出图（模型能描述页面内容）；
③ 选中一段文字后问「我选了什么」→ `get_current_view.selection`；④ 「翻到第 N 页」→ `goto` 滚动、⌘[ 能跳回；
⑤ 「我在这本书上记了什么」→ `list_annotations` 与 Inspector 一致；⑥ 客户端若支持资源，`unireader://doc/<id>/page/<n>` 能当附件拉进来。

---

## 17. 实现记录 — 批 3（2026-09-13 落地，同一分支，待用户实测）

编译通过；spike 不变（写入开关的拦截在批 1 的 spike 里就测了）。**没有启动 App 自测**。

### 17.1 新增

| 东西 | 在哪 | 要点 |
|---|---|---|
| 写入开关 | 设置 › Agent「允许 Agent 写入」（`mcpAllowWrites`，默认关）| 关着时写入工具照常列出、调用时拦（D6）；`get_state.app.writes_enabled` 报出来 |
| 来源标记 | `NoteSource.agentKind = "agent"` + `isAgent`；Inspector 笔记行加 `terminal` 图标（悬停显示客户端名）| `provider` = `initialize` 的 `clientInfo.name`，`url` 空串；payload 零迁移 |
| `add_bookmark` | `MCPTools+Notes.swift` + `MCPFacade.addBookmark` | 名字必填（`Bookmark.validTitle`）；开着 → `session.addBookmark`，没开 → `ws.saveBookmark` |
| `add_note` | 同上 + `MCPFacade.addNote` | 锚点三选一：`quote`（`MCPDocReader.locate`：先 `findString`、再 OCR 行；找不到**报错不猜**）> `rect` > 页顶横条；`type` 按名字对 `noteTypes`，不存在就报错并列出可用的；开着时经 `session.inkEdit` 进撤销栈 |
| `add_highlight` | 同上 + `MCPFacade.addHighlight` | `quote` 必填、必须找得到；颜色收色板名或 `#RRGGBB`；`style` 收 fill / underline / box（2026-09-16），`list_annotations` 的高亮 DTO 回 `style`、笔记 DTO 回 `style` + 设了才有的 `color` |
| `update_markdown`（2026-09-21；2026-09-24 移到 `MCPTools+Markdown.swift`、可按 `note_ref` 指定任意一篇，并新增局部修改 `edit_markdown`，见 §19） | `MCPTools+Notes.swift` + `MCPFacade.updateMarkdown` | 只改目标窗口的活动 Markdown 标签；先用 `get_current_view.markdown.revision` 做乐观锁，再原子写完整正文并同步所有正在显示该笔记的编辑器。用户在读取后有新编辑或多窗口存在不同未保存正文时拒绝覆盖 |
| `import_pdf` / `open_document(path:)` | `MCPTools+Document.swift` + **`WorkspaceManager.importPDF(at:)`**（新，面板/拖拽/MCP 三处共用，`ReaderWindowController.ingest` 改为调它）| 按 hash 去重，返回 `imported` 是否新建；`open_document` 带 `path` 时虽是导航级工具也按写入开关拦 |
| `create_workspace` | `MCPTools+Workspace.swift` + `MCPFacade.createWorkspace` | 🔴 **已存在的路径一律拒绝**（界面那条 `createWorkspace(at:)` 会覆盖非工作区路径，那是保存面板确认过「替换」才允许的）；缺 `.unrd` 自动补 |
| `run_ocr` | 同上 + `MCPFacade.runOCR` | 文档必须开着（OCR 走会话队列）；没配引擎报错；立即返回队列状态，Agent 稍后再 `read_pages` |

### 17.2 🔴 写入两条路径的落点（§9.3 的兑现）

`MCPFacade.writeTarget` 先查「有没有标签正显示这篇」：有 → 只改 `DocSession` 的数组（`textNotes` / `highlights` / `bookmarks`），
由 `DocTabModel` 现有对账落库并广播平板；没有 → `WorkspaceManager.save*` 直接写库。出参里 `via: session | library` 说明走了哪条。

Markdown 不走 PDF 的 `writeTarget`：`update_markdown` 的目标是窗口当前活动标签，正文真源仍是文件；写前比较
`get_current_view` 返回的实时编辑器正文 revision，写后把相同正文推回所有可见编辑器，避免 0.8 秒自动保存把 Agent
改动覆盖掉。

### 17.3 首轮反馈修复：Agent 建的笔记图钉跑到行末（2026-09-13）

用户报「有选中文字的笔记位置跑到很右边去了，没有像手动那样紧贴选中文字」。根因：OCR 页上手动选字的行框是按
选中字符范围**裁剪**的（`OCRTextSelect.clip`），而 `MCPDocReader.locate` 的 OCR 分支给的是**整行**框——图钉落在
`anchor.maxX` 右侧（`PageCellView.markerPos`），整行的 maxX 就是行末。原生 PDF 页不受影响（`findString` 本来就贴字）。

修法：新增 **`MCPQuoteLocator`**（纯函数）——行按阅读顺序拼起来、去空白、折叠大小写找引文，首行/末行按字符裁、
中间行整行；`search_text` 的 OCR 命中框也改用它。spike `mcp-quote-locator-test.swift` 15 项（行内/行首/跨行/空白与
换行/大小写/单字框优先/乱序行）。**待用户实测**：在 OCR 页让 Agent 在一句话中间加笔记，图钉应贴在引文末字右侧。

顺带记入 `TODO.md` 第 5 条：选区型笔记的图钉将来要能拖拽改位置（用户 2026-09-13 提）。

### 17.4 用户实测清单

开写入开关后在 Claude Code 里：① 「在第 N 页加个书签叫 X」→ 目录树里出现；② 「把第 N 页的『……』那句高亮成绿色」→ 页面铺色、
Inspector 有条目；③ 「在这句话上加个笔记：……」→ 图钉出现、气泡正文对、Inspector 行末有终端图标；④ 关掉文档再做 ①~③（走库那条路）→
重新打开都在；⑤ 「把 ~/Downloads/x.pdf 导进来」→ 侧栏出现、再导一次不重复；⑥ 「新建一个工作区放到 ~/Desktop/试试」→ 生成 `试试.unrd` 并开窗，
对已存在路径拒绝；⑦ 关掉写入开关再试 ① → 拦下并提示。

---

## 18. 2026-09-14 追加：DTO 带 `link`、`open_document` 中段与 `unireader://` 链接共用

`URL-SCHEME-PLAN.md` 落地时顺手改了三处，读 §7 / §15–17 时按这里为准：

- `documentDTO`、`list_annotations` 的每条（notes / highlights / bookmarks / image_notes / ai_threads / scratch_pads）、`get_current_view`、
  `open_document`、`goto` 的结果都多一个 **`link`** = `unireader://open?…`（`MCPFacade.link`）。Agent 把它原样写进 Obsidian 等处，点了就回到那一处。
  `get_state.app.deep_link` 是一行格式说明（`DeepLink.formatHint`）。
- `open_document` 的「已在显示 → 切过去；该工作区有窗 → 开标签；没窗 → 新开一扇只装这篇」抽成 **`AppDelegate.showDocument`**，
  与链接路由共用；`window_id` 分支仍在 `MCPFacade` 里。行为不变。
- `image_notes[].image_sha256` 的 schema 描述补了文件位置 `<workspace>/Images/<sha256>.<ext>`（Agent 导出图片要复制它）。

## 19. 2026-09-24 Markdown 笔记的读写细化：局部修改 + 分页读取

用户原话：「优化编辑文档 tool，达到 code agent 那种能够修改部分内容的能力，以及读取 tool 也细化优化下」。
起因见 TODO「Agent 面板把『模型还在写工具参数』显示成『工具正在执行』」：原来只有 `update_markdown` 交整篇新正文，
17K 字的笔记改一句也要模型重吐全文（那次 68 秒全花在吐字上，工具本身 0.46 秒）。

| 工具 | 级别 | 要点 |
|---|---|---|
| `list_markdown_notes`（新） | 读 | 工作区全部笔记（内建 + 引用源）的 `note_ref` / 标题 / 路径；可按 `source` / `folder` / `query` 筛 |
| `read_markdown`（新） | 读 | 三种模式：按行分页（`offset`/`limit`，默认 400 行、上限 2000 行 / 约 6 万字，`cat -n` 式行号前缀）、`search`（只回含该文字的行 + 行号）、`outline`（`#` 标题大纲，跳过代码块与 frontmatter）。回 `revision` / `line_count` / `unsaved_edits` |
| `edit_markdown`（新） | 写 | code agent 式局部修改：`old_text` → `new_text`（**逐码元精确匹配，必须唯一**，否则报出现在哪几行；`replace_all` 换全部）或 `insert_line` + `new_text`（整行插入，0 = 最前）。单条用顶层字段，多条用 `edits` 数组，**依次生效、整批原子**。`expected_revision` 可选——不给时「原文必须精确匹配」本身就是防覆盖的检查。结果带改动行号 + 前后 3 行的核对片段 |
| `update_markdown`（改） | 写 | 仍是整篇替换 + revision 必填；描述里明确「优先用 edit_markdown」 |
| `get_current_view`（改） | 读 | Markdown 多回 `line_count`；文字结果超过 300 行只给开头，提示改用 `read_markdown`（结构化结果仍是全文，兼容旧用法） |

- **目标不再限于活动标签**：三个笔记工具都收 `note_ref`（`NoteRef.key` / 库行 UUID / 笔记名，同 `WorkspaceManager.note(key:)`），
  笔记不必开着；不给 = `window_id` 那扇的活动标签 → key 窗口里的编辑区（**含笔记小窗**）→ key 阅读窗的活动标签。
  ⚠️ `update_markdown` 的 `note_ref` 语义随之从「核对活动标签是不是它」变成「就写它」。
- **实时正文从哪来**：`MarkdownDocView` 自带一张弱引用登记表（`editors(showing:in:)` / `keyEditor`），标签页与笔记小窗都在里面；
  原来只问 `ReaderPaneController.mdView`，会漏掉小窗（`ReaderWindowController.markdownText/applyMarkdownText` 已删）。
- **写入同一条路**（`MCPFacade.markdownForWrite` → `commitMarkdown`）：同一篇开在几个编辑器里且未保存正文不一致 → 拒绝；
  原子写文件后把新正文推回所有编辑器（防 0.8 秒自动保存盖回去）。
- 纯逻辑 `MCPMarkdownText`（分行口径：结尾换行不多算一行、`\r` 原样留在行内；匹配失败时「忽略空白」再找一遍**只拿来写提示**，
  另能认出「把行号前缀也抄进来了」这种常见错误）。测试 `spike/mcp-markdown-text-test.swift`（43 项）；
  `spike/mcp-schema-audit.py` 补了 `list_markdown_notes` 与 `read_markdown` 三种模式。
