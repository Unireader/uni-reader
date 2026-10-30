# WEB-READER-PLAN.md — 服务器自带的网页阅读器（`SERVER-MODE-PLAN.md` S6）

> 2026-10-30 起草。**状态：方案，待用户确认；代码一行没动。**
>
> **一句话**：独立服务器（`server/`）自己提供一个网页。浏览器打开服务器地址，配对后看服务器上的工作区与书，
> 能读 PDF、看到笔迹 / 高亮 / 文字笔记，能手写、能写文字笔记。只在线，不在浏览器里缓存整个工作区。

---

## 0. 已定（2026-10-30 用户）

| 项 | 决定 |
|---|---|
| App 里的网页 | **删掉**：原来的平板网页采集页（`web/`）不再随 macOS App 发布，工程整个删除（已做，见 §10） |
| 网页由谁提供 | 独立服务器自己提供 |
| 范围 | 完整网页阅读器（S6）：阅读 + 显示笔迹 / 高亮 / 文字笔记 + 手写 + 写文字笔记；**先出方案、确认后再动手** |

沿用 `SERVER-MODE-PLAN.md` 已定的：网页只在线；服务器不出页图（网页自己用 pdf.js 渲染）；只有用户一个人用，不做账号。

---

## 1. 第一版用户能做的事

1. 浏览器打开 `https://<服务器地址>/` → 输入配对码 → 配对成功。网页算一台设备，有自己的令牌，
   服务器命令行 `devices` 看得到、`revoke` 能吊销（与 App 同一套）。
2. 工作区列表 → 书目（按分组）→ 打开一本：连续滚动、缩放、跳页、PDF 目录。
3. 页上显示：笔迹（按图层的显示 / 隐藏）、高亮（三种画法与颜色）、文字笔记图钉，点图钉看内容。
4. 手写：几支笔（颜色 / 粗细 / 笔型）+ 橡皮（整条擦）+ 撤销 / 重做（只在本次打开的页面里）。
5. 文字笔记：在页上点一下新建；编辑；删除。
6. 别的设备改了：几秒内网页上看得到（轮询服务器的修订号，变了就重拉看得见的那几页）。

**第一版不做**（以后按需要再排）：画板笔记、草稿纸、习题、Markdown 笔记、图片笔记（显示也不做）、
划字加高亮（要 PDF 文字层，扫描书还要 OCR 结果）、全文搜索、改书名 / 分组、离线使用。

---

## 2. 结构

```
server/
  web/                         网页前端工程（Svelte 5 + Vite + TypeScript + pdf.js）
    src/…
    dist/                      构建产物（不入 git）
  scripts/build-web.sh         npm 构建 → 生成 Sources/UniServerHTTP/WebAssets.swift（产物嵌进服务器程序）
  Sources/UniServerHTTP/
    WebAssets.swift            生成物：文件名 → 内容（不入 git，构建服务器前先跑上面那个脚本）
    WebRoutes.swift            静态页路由 + 网页用的 JSON 接口（§3）
```

- **构建产物嵌进服务器程序**：部署照旧是单个文件（Linux 静态版也一样），不用另外拷一个网页目录。
  开发时用 `--web-dir <目录>` 直接读磁盘上的文件，配合 vite 的开发服务器（接口转发到本机服务器）。
- 前端沿用旧采集页的技术（Svelte 5 + Vite + TypeScript），PDF 渲染用 `pdfjs-dist`。
  旧采集页里的笔迹画法（`web/src/lib/render.ts` 等）在 git 历史里，可以参考算法，但**照 Mac 现在的代码重新核对**，不直接搬。

---

## 3. 接口（都在 `/v1` 下，都要令牌）

| 方法 路径 | 用途 |
|---|---|
| `GET workspaces/:ws/documents` | 书目：id / 书名 / 分组 / 页数 / 用哪份 PDF（内容哈希）/ 扫描页对齐参数 |
| `GET workspaces/:ws/pdf/:hash` | **已有**（支持 `Range`）。pdf.js 按需分段取，大书不必整本下完才显示 |
| `GET workspaces/:ws/documents/:doc/marks?from=&to=` | 一段页范围内的笔迹（点集原样，见 §4）、高亮、文字笔记、图层 |
| `POST workspaces/:ws/edits` | 一批改动（`note` 行的新增 / 修改 / 删除，`ink_layer` 不改） |
| `GET workspaces/:ws/head` | 当前修订号（轮询用，很轻） |

🔴 **写入不另写一套**：服务器把网页的一批改动当成一次「基线 = 服务器现状」的推送，交给现有的 `pushLocked`。
于是「先归档再删除」（红线⑪）、修订号、父行删除时的子行补记、三方判定，全都和设备推送是同一份代码。

---

## 4. 坐标与显示（跨端契约，必须与 Mac 逐式一致）

- **页面** = 每页的有效页框（CropBox 有效用 CropBox，否则 MediaBox）按 `/Rotate` 转正，左上原点、y 向下、单位 pt
  （`SCAN-ALIGN-PLAN.md §2.1`）。pdf.js 的 `page.view` + `rotate` 与之对应，但要**逐页实测核对**：
  验收标准沿用方案 §10 S6 那条「三端页面尺寸逐页一致」，拿用户手上的几本真书（含拼页扫描、带 `/Rotate` 的）比对 Mac 的页尺寸。
- **扫描页对齐**开着的书：页面坐标是对齐后的空间，网页出图时套同一个变换（`SCAN-ALIGN-PLAN.md §2.2`，canvas 的 `setTransform`
  用 y 向下那组）；笔迹 / 高亮 / 笔记坐标照旧是归一化的。
- **笔迹点集**：`note.points`（`BINARY-INK-PLAN.md §2`：`u8 版本 = 1` + n ×（`f32 x` `f32 y` `f32 z`），小端）+ payload 里的笔型 / 颜色 / 宽度。
  接口里点集原样给（base64），网页自己解；已有的跨端向量 `spike/ink-blob-vectors.txt` 直接拿来测 TS 版解码。
- **画法**：笔宽、压感、荧光笔透明度照 Mac `PenPreset` / `InkRenderCG` 的公式写一份 TS 版，用 node 对着 Swift 出的向量测
  （同 `spike/wire-cross-test.js` 的做法）。
- **网页写回的笔迹**：点集与 payload 的字段与 Mac 写的完全一致，Mac / 安卓读得出、能擦能挪。

---

## 5. 认证

- **网页本身**（HTML / JS / CSS，不含任何数据）**不要令牌**——这是服务器「所有接口都要令牌」的唯一例外；
  数据接口照旧 `Authorization: Bearer <令牌>`，令牌存在浏览器的 localStorage。
- 备选：配对后服务器发一个 HttpOnly Cookie，连网页本身也要登录才给（更严，但多一套登录状态要管）。
- 只在 HTTPS 下用（用户 NAS 上的 caddy 已经在做）；明文 HTTP 打开时网页顶上提示风险。

---

## 6. 与其他设备的关系

- 网页的改动直接写进服务器，修订号 +1，别的设备下次同步拿到。
- ⚠️ Mac 开着同一个工作区时**只推不拉**（S2 档），网页写的要等 Mac 关掉再开这个工作区才看得到；
  开着时也能看到是 S4（「打开状态接收改动」）的事，不在本方案里。安卓模式1 同理。
- 同一条笔记网页与设备几乎同时改：沿用推送的三方判定，网页这边相当于「已经在服务器上的那份」。

---

## 7. 分期

| 期 | 内容 | 验证 |
|---|---|---|
| W1 | 静态页 + 配对 + 工作区 / 书目 + pdf.js 阅读（缩放、跳页、目录） | 服务器接口测试；页尺寸与 Mac 逐页核对；界面用户实测 |
| W2 | 显示笔迹 / 高亮 / 文字笔记（只读）+ 扫描页对齐 + 轮询刷新 | node 单测：点集解码、对齐变换、笔宽公式对 Swift 向量；用户实测 |
| W3 | 手写（笔、橡皮、撤销）+ 文字笔记新建 / 编辑 / 删除（写接口） | 服务器测试：网页写的行能被设备拉到、删除先归档；Mac 打开后笔迹位置一致（用户实测） |

---

## 8. 要用户装的东西

- `server/web/` 的 npm 依赖（svelte、vite、typescript、pdfjs-dist）：我给命令，用户执行 `npm install`。
- 服务器的 Swift 依赖不变（Hummingbird 已有）。
- 服务器构建多一步：先 `server/scripts/build-web.sh` 生成 `WebAssets.swift`，再 `swift build` / `build-linux.sh`。

---

## 9. 待用户确认

1. 第一版范围（§1，含「不做」那一串）。
2. 网页本身不要令牌（§5），还是用 Cookie 连网页也要登录。
3. 前端技术：Svelte 5 + Vite + TypeScript + pdf.js。
4. 主要拿什么设备开网页（iPad + Apple Pencil？电脑浏览器？安卓平板的浏览器？）——决定手写先照顾哪种输入（压感、手掌误触）。
5. 网页产物嵌进服务器程序（单文件部署），开发时才读磁盘。

---

## 10. 实现记录

### 10.1 2026-10-30：App 不再带网页（已做）

- 删除 `web/` 整个工程、`Sources/Server/CapturePage.swift`、`scripts/build-web.sh`；`capture.html`（构建产物）不再进 App。
- Mac 局域网服务的 `GET /` 改回一句停用说明（410）。二维码里的地址格式**不变**：安卓 App 扫它取 IP 与配对码，不会去打开它。
  平板面板的提示从「在平板的 Firefox 中打开此地址」改成「用平板上的 UniReader App 扫这个二维码」。
- 线格式的 JS 编解码器 `Sources/Resources/wire.js` 挪到 `spike/wire.js`，只给 node 测试用（`spike/wire-cross-test.js` 243 项照旧全过）。
- `scripts/package.sh` / `release.sh` 不再构建网页，发布不再需要 npm。红线⑩（`splitStroke` 与 JS 版同步）作废，编号保留。
- `spike/ink-cross/` 去掉 web 那一端（它的 Mac 一端本来就因为 `Sources/Views/` 删除而编不过，见 `APPKIT-REWRITE-PLAN.md §9.3`）。
- 已知：`spike/udp-client-test.js` 早在 2026-08-13 起就编不过（harness 没带 `PageRenderer`），与这次无关，没修。
