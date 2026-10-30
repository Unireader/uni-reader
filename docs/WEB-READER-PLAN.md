# WEB-READER-PLAN.md — 服务器自带的网页阅读器（`SERVER-MODE-PLAN.md` S6）

> 2026-10-30 起草；同日用户说「开始做」，按本方案动手（§9 的默认做法）。**状态：W1 已部署到 NAS，用户实测能看到 PDF**（其余几项待测，§10.2）；**W2 代码已写，待用户实测**（§10.3）；W3 待做。
>
> **一句话**：独立服务器（`server/`）自己提供一个网页。浏览器打开服务器地址，配对后看服务器上的工作区与书，
> 能读 PDF、看到笔迹 / 高亮 / 文字笔记，能手写、能写文字笔记。只在线，不在浏览器里缓存整个工作区。

---

## 0. 已定（2026-10-30 用户）

| 项 | 决定 |
|---|---|
| App 里的网页 | **删掉**：原来的平板网页采集页（`web/`）不再随 macOS App 发布，工程整个删除（已做，见 §10） |
| 网页由谁提供 | 独立服务器自己提供 |
| 范围 | 完整网页阅读器（S6）：阅读 + 显示笔迹 / 高亮 / 文字笔记 + 手写 + 写文字笔记；先出方案，用户说「开始做」后按方案动手 |
| §9 第 1、2、3、5 条 | 用户没另提要求，按方案的默认做法：第一版范围照 §1；网页本身不要令牌；Svelte 5 + Vite + TypeScript + pdf.js；产物编进服务器程序 |
| §9 第 4 条（主要用什么设备开网页） | **电脑浏览器 + 安卓平板的浏览器**（2026-10-30 用户答）。手写先照顾这两种输入：电脑用鼠标 / 触控板（没有压感），安卓平板用手写笔（指针事件里笔型为 `pen`、带压感），手指只用来滚动和缩放；iPad 不专门适配 |

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
    test/                      node 测试（npm test）：公式与解码对 Mac 代码生成的跨端向量（spike/web-ink-vectors.txt）
    node_modules/ dist/        依赖与构建产物（都不入 git；pnpm-lock.yaml 入 git）
  scripts/build-web.sh         类型检查 + 测试 + 构建 → web/dist/
  Plugins/EmbedWebAssets/      SwiftPM 构建插件：swift build 时把 web/dist 编进 UniServerHTTP（生成 EmbeddedWeb.swift，在 .build 里）
  Sources/web-embed/           插件用的生成器（每个文件一个 base64 字符串）
  Sources/UniServerHTTP/
    WebFiles.swift             静态页路由（不要令牌）+ 读编进程序的那份 / --web-dir 指的目录
  Sources/UniServerCore/
    HostedWorkspace+Web.swift  网页用的查询（书目）
```

- **构建产物嵌进服务器程序**：部署照旧是单个文件（Linux 静态版也一样），不用另外拷一个网页目录。
  没有 `web/dist` 也能编，只是程序里不带网页（`GET /` 回一句说明）；经 `build-web.sh` 重新构建网页后，下次 `swift build` 插件自动重新生成（§10.3 末）。
  `scripts/build-linux.sh` 装了网页依赖时会先跑 `build-web.sh`。
  开发时用 `--web-dir <目录>` 直接读磁盘上的文件，或 `npm run dev`（vite 的开发服务器，`/v1` 转发到本机 8790 端口的服务器）。
- 前端沿用旧采集页的技术（Svelte 5 + Vite + TypeScript），PDF 渲染用 `pdfjs-dist`。
  旧采集页里的笔迹画法（`web/src/lib/render.ts` 等）在 git 历史里，可以参考算法，但**照 Mac 现在的代码重新核对**，不直接搬。

---

## 3. 接口（都在 `/v1` 下，都要令牌）

| 方法 路径 | 用途 |
|---|---|
| `GET workspaces/:ws/documents` | 书目：id / 书名 / 分组 / 页数 / 阅读进度 / 用哪份 PDF（内容哈希）。**W1 已做** |
| `GET workspaces/:ws/pdf/:hash` | **已有**（支持 `Range`）。pdf.js 按需分段取，大书不必整本下完才显示 |
| `GET workspaces/:ws/documents/:doc/view?hash=` | 打开一本书：笔迹图层、笔记类型（`meta.note_types` 原样）、扫描页对齐参数（`page_align.payload` 原样，只给 `hash` 这份、且开着的）。**W2 已做** |
| `GET workspaces/:ws/documents/:doc/marks?from=&to=` | 一段页（从 0 起、含两端，一次最多 200 页）上的文字笔记 / 笔迹 / 高亮：payload 原样（JSON 文本）；笔迹的点按 App 的规则挑好（`BINARY-INK-PLAN.md §3`），一律给二进制（base64），payload 里的点摘掉。**W2 已做** |
| `POST workspaces/:ws/edits` | 一批改动（`note` 行的新增 / 修改 / 删除，`ink_layer` 不改）。W3 |
| `GET workspaces/:ws/head` | 当前修订号（轮询用，很轻）。**W2 已做** |

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
- **线宽的单位**照 Mac：笔的粗细是「适合宽度下」的屏幕点，放大时跟着页面一起变粗（Mac 阅读区按适合宽度画、`inkScale = 1`、由缩放整体放大）。
  ⚠️ 安卓阅读区不一样：线宽是屏幕上的 dp、不随页面缩放（`InkRenderer.kt` 注释），两端在放大时粗细比例不同，网页跟 Mac。
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

- `server/web/` 的 npm 依赖（版本钉死在 `package.json`）：svelte 5.56.8、vite 6.4.3、@sveltejs/vite-plugin-svelte 5.1.1、
  typescript 5.9.3（这四个与旧采集页用过的同一版）、svelte-check 4.7.6（`.svelte` 文件的类型检查）、pdfjs-dist 5.4.624。
  用户执行 `cd server/web && pnpm install`（2026-10-30 用户用 pnpm 10 装的，锁文件 `pnpm-lock.yaml` 入 git）。
  pdfjs-dist 停在 5.4：5.5 起要求 Node 22，用户机器上是 Node 20；6.x 的接口变化也还没核对过。
- 服务器的 Swift 依赖不变（Hummingbird 已有；构建插件只用 SwiftPM 自带的 PackagePlugin）。
- 服务器构建多一步：先 `server/scripts/build-web.sh` 出 `web/dist`，再 `swift build` / `build-linux.sh`（后者会自己先跑前者）。

---

## 9. 待用户确认

1. 第一版范围（§1，含「不做」那一串）。
2. 网页本身不要令牌（§5），还是用 Cookie 连网页也要登录。
3. 前端技术：Svelte 5 + Vite + TypeScript + pdf.js。
4. 主要拿什么设备开网页（iPad + Apple Pencil？电脑浏览器？安卓平板的浏览器？）——决定手写先照顾哪种输入（压感、手掌误触）。→ **已答：电脑 + 安卓平板的浏览器**（§0）。
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

### 10.2 2026-10-30：W1（静态页 + 配对 + 工作区 / 书目 + 阅读）

服务器：
- 网页路由（`WebFiles.swift`）：`GET /`、`/assets/**`、`/pdfjs/**`、`/favicon.svg`，**不要令牌**。只认普通相对路径（`..`、空段、点开头的段一律 404）；
  页面带内容安全策略（只许本服务器上的脚本 / 样式；pdf.js 解 JPEG 2000 要 `wasm-unsafe-eval`）、`nosniff`、`no-referrer`；
  `assets/` 文件名带内容哈希，长缓存；页面本身 `no-cache`。
- 网页编进程序：SwiftPM 构建插件 `EmbedWebAssets` + 生成器 `web-embed`（§2）。`serve --web-dir <目录>` 改读磁盘；启动信息多一行「网页：…」。
- `GET /v1/workspaces/:ws/documents`（`HostedWorkspace.documents()`）：顺序同 App 书目（`sort_order`、`last_opened_at`）；
  每本挑**第一个服务器上有文件的版本**（口径同 App 的 `fetchDocument`），页数用那个版本的；都没有就不给哈希（网页里那本灰掉）。

网页（`server/web/src/`）：
- `#/` 工作区 → `#/w/<工作区>` 书目（按分组、可筛选）→ `#/w/<工作区>/d/<书>` 阅读。令牌在 localStorage；任何接口回 401 就清掉令牌回配对页。
  设备名默认「网页 · iPad · Safari」这样，服务器 `devices` 里认得出来。明文 HTTP 且不是本机时，列表页顶上提示风险。
- 阅读（`lib/viewer.ts`）：连续滚动，所有页一样宽（适合宽度 × 缩放），高按各页长宽比；页尺寸先按打开的那一页估，画到哪页量到真尺寸再改，
  改时钉住视口顶边那一处。只给视口附近几页画画布（前后各预画 1 页、再各留 2 页），离开就收回（iPad Safari 画布内存有上限）；
  单块画布不超过 1600 万像素。新图画好才替换旧图；缩放时先拉伸旧图，停手 180ms 后按新倍率重画。
- 缩放：顶栏按钮（百分比 = 相对适合宽度，点它回适合宽度）、Ctrl/⌘ + 滚轮（含触控板捏合）、⌘+ / ⌘− / ⌘0、Safari 捏合手势、触屏两指捏合
  （两指中点下的那一点跟着中点走）。阅读区 `touch-action: pan-x pan-y`，不会把整个网页放大。
- 跳页（顶栏页码框）、PDF 目录（侧栏，窄屏时盖在上面；能读出纵坐标的目录项跳到页内那个位置）。
- 读到哪儿记在本浏览器（页 + 页内比例 + 缩放）；没有就从服务器上的阅读进度开始。**不写回服务器**（写入接口在 W3）。
- pdf.js：按需分段取 PDF（`Range`，每段 256KB，不自动预取整本）；字形表 / 标准字体 / wasm 构建时拷进 `dist/pdfjs/`；`isEvalSupported: false`。
- 界面文字中英两套（`lib/i18n.ts`，按浏览器语言），用词同 Mac App。

验证：服务器 `swift test` 核心 25 项（新增书目一项：顺序、挑版本、灰掉、删除后拒绝）+ HTTP 7 项（新增：网页不要令牌、带安全策略、
点开头的文件与 `..` 拒绝、书目要令牌；PDF 整份下载带 `Content-Length` 与 `Accept-Ranges`，pdf.js 靠它们改用分段下载）。
网页 `svelte-check` 0 错误 0 警告；构建产物 4.8MB / 202 个文件（脚本 467KB、pdf.js 解析线程 1.08MB、`pdfjs/` 3.3MB），编进程序后
本机起服务器逐个取回、与 `dist` 逐字节一致，类型头都对（`.mjs` 是 JavaScript、`.wasm` 是 `application/wasm`）。
Linux 交叉编译（Swift 6.2.3）带构建插件照常通过；同日换到用户 NAS 上（启动信息「网页：编在程序里（202 个文件）」，`/` 与脚本、字形表都能取到，`/v1` 不带令牌 401）。
用户实测：能看到 PDF；缩放、跳页、目录、刷新回原位等其余几项还没反馈。

pdf.js 5.4 的两处用法：`render` 只传 `canvas`（同时传 `canvasContext` 时要求 `canvas` 为空）；多了 `iccUrl`（色彩配置，`iccs/` 一并拷进 `dist/pdfjs/`）。
`wasm/` 里有 JPEG 2000 与 JBIG2 两种扫描图的解码器，扫描书常用。


### 10.3 2026-10-30：W2（显示笔迹 / 高亮 / 文字笔记 + 扫描页对齐 + 轮询刷新）

服务器（`HostedWorkspace+Web.swift`、`ServerApp.swift`）：
- `documents/:doc/view`、`documents/:doc/marks`、`head` 三条（§3 表）。书不在 → 404（新错误 `unknownDocument`）。
- 笔迹的点在服务器上挑：二进制有效 → 用它；否则 JSON 里有点 → 编成二进制；否则有二进制 → 用它（同 Mac `InkStrokePayload.read`）。
  网页只认二进制一种格式。只给 kind 0 / 2 / 3（文字笔记、页内笔迹、高亮）；草稿纸笔迹、图片笔记、对话不给。

网页（`server/web/src/lib/`）：
- `inkmath.ts`（笔宽 / 钢笔锥度 / 铅笔三道参数与抖动 / 点集解码）、`align.ts`（对齐的正逆变换、解析、画页用的 canvas 矩阵）：
  逐式照 Mac `PenPreset.swift` / `ScanAlign.swift`。
- `ink.ts`：照 Mac `InkRenderCG.drawStroke`（非快速那条）逐分支写：中点二次曲线 + 补末段；马克笔整条一次描边、平头、正片叠底；
  铅笔三道波动叠加；圆珠笔 / 钢笔逐段变宽。Mac 把每段描边转成轮廓再一次填充（半透明笔接缝不叠深），canvas 没有这个功能，
  改成每段拆成「两端半圆 + 矩形」的胶囊（绕向一致），全部放进一条路径按非零规则填一次，效果相同；曲线约 3 像素拆一段。
- `marks.ts`：payload 的键与缺省值照 Mac（没有 `type` = 圆珠笔、没有 `layerId` = 默认层、`display` 缺省点按展开、`style` 缺省铺色）；
  图层：隐藏的不画，按图层顺序、同层保持原顺序；笔迹指向不存在的图层时按 Mac 打开时补建的结果算（可见、排在最后）。
  笔记底色：自选色 > 没类型的暖黄 > 类型色（找不到 = 通用的灰）；图钉色：有类型用类型色，否则暖黄。
- `decor.ts`：高亮 / 笔记选区用网页元素按页的百分比摆（缩放时跟着走、不重画），三种画法的外扩与线宽照 Mac `PageMarksLayer`；
  笔迹每页一块画布（有可见笔迹才有），与页面图同像素、同一时刻换上；图钉直径 18 像素，位置规则同 Mac `notePinCenter`，
  点开看正文（「悬停展开」的鼠标 / 笔停上去就开，「始终展开」的默认开着）。图钉图标统一画成一个简单的笔记符号（网页没有 SF Symbols）；
  **正文按纯文字显示**，Markdown 还没排版（要加排版库，得用户装依赖）；卡片手动摆过的位置 / 大小（`card`）网页不认，按自动规则放。
- `markstore.ts`：按 8 页一块取，只留视口附近的；每 5 秒（页面在前台时）问一次 `head`，变了就重取图层 / 笔记类型和视口附近的块，
  只重画内容真变了的页。对齐参数变了（Mac 上开 / 关了对齐）→ 整本重新打开。
- 扫描页对齐（`viewer.ts`）：开着时页尺寸直接用对齐后的（宽一律 W、高 sh，不用估）；画页时 pdf.js 的 `transform` 参数套每页的变换
  （作用在像素上：线性部分不变、平移乘每 pt 的像素数），pdf.js 先把整块画布铺白，转出去的角裁掉、空出的角是白的。目录落点也转到对齐后的坐标。

验证：服务器核心测试 27 项（新增两项：点集三种来源的挑法、范围 / 种类过滤、坏行跳过；图层顺序、笔记类型、对齐只给开着的那份）+ HTTP 7 项
（新接口要令牌、参数不对 400、书不在 404）。网页 `npm test` 9 项：笔宽 60 组、锥度、抖动、对齐正逆变换与画页矩阵对 **Mac 代码生成的向量**
（`spike/web-ink-vectors.swift` → `spike/web-ink-vectors.txt`），点集解码对 `spike/ink-blob-vectors.txt`，标记解析、图层规则、配色规则。
`svelte-check` 0 错误 0 警告。**界面待用户实测**（笔迹观感要和 Mac 对着看）。

构建插件的坑（同日）：插件原来把 `web/dist` 里的文件逐个登记成输入。Linux 交叉编译用的 SwiftPM 6.2.3 在源文件清单没变时沿用上次的构建计划、
不重新运行插件，网页重新构建后文件名（带内容哈希）全换了，报「missing inputs」。改成只登记 `index.html` 一个输入，`build-web.sh` 构建完删掉
生成文件（没有 dist 时那条命令没有输入，靠这个保证重新生成）。已有的旧构建计划要 `touch Package.swift` 让它重新规划一次（只这一次）。
