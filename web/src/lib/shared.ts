// 共享常量 / 全局状态袋 / 与 Mac 端对齐的数学公式 / 跨模块共享类型。
// ⚠️ 公式与常量改动必须同步 Mac 端：strokeWidthFor/opacityMultFor ↔ Sources/App/PenPreset.swift，
// RD ↔ Sources/Views/RadialMenuView.swift（+ Sources/App/DocSession.swift 的 RadialLayout），
// PR ↔ Sources/Views/PageCellView.swift 的 pressRing。

// ---- 跨模块共享类型 ----

/// 收藏笔（Mac 端 PenPreset 的线上形状）。
export interface Pen {
  color: string;
  w: number;
  t: string;
  name?: string;
}

/// 一条已成形/正在写的笔迹（pts: [页内归一化 x, y, 压感]）。
export interface Stroke {
  page: number;
  pen: Pen;
  pts: [number, number, number][];
}

/// 一个笔迹图层（Mac 下发的 layers 全量镜像元素；颜色只是列表色点标识，与笔画自身墨色无关）。
export interface Layer {
  r: number; g: number; b: number;
  visible: boolean;
  name: string;
}

/// 一条自由文字笔记（Mac 下发的 notes 全量镜像元素；page/nx/ny 页内归一化坐标与笔迹同系）。
export interface TextNote {
  id: string;
  page: number;
  nx: number;
  ny: number;
  text: string;
  /// 展开方式（每条自己的属性，与 Mac `NoteDisplay` 同值）：0=点击 1=悬浮 2=始终。
  /// 老 Mac 不带这个字节时解码为 0，行为与从前一致。
  display: number;
}

/// 线上消息：字段随 type 变（契约 PROTOCOL.md / Sources/Resources/wire.js），这里保持宽松。
export interface WireMsg {
  type: string;
  [k: string]: any;
}

/// 环形选笔盘扇区项（Mac 下发）。
export interface RadialItem {
  kind: string;           // "pen" | "erase" | "page" | "scratchAdd" | "textNote"
  color?: string;
  t?: string;
  w?: number;
}

/// 环形选笔盘状态镜像（Mac 是唯一判定方，本地照画）。
export interface RadialState {
  open: boolean;
  page: number;
  cx: number;
  cy: number;
  highlight: number;      // -1 = 中心取消区（无高亮）
  items?: RadialItem[];
}

/// 长按进度环（环形盘前置动画）：on 时带锚点，t0 是本机起计时刻。
export interface PressRing {
  page: number;
  nx: number;
  ny: number;
  t0: number;
}

/// locate() 的命中结果：页号 + 页内归一化坐标。
export interface PageLoc {
  page: number;
  nx: number;
  ny: number;
}

/// 框选（lasso 模式）本地判定的选中集：镜像 Mac 端 `LassoSelection`，但这里只用于渲染高亮——
/// 命中算法是客户端复刻的一份乐观预览（同 `eraseHit` 先例），提交移动/缩放时 Mac 用真源重新判定，
/// 不信任这里算出来的 strokeIdx/noteIdx。
export interface LassoSelection {
  page: number;
  box: [number, number, number, number];      // x0,y0,x1,y1：选区包围盒（归一化，提交时原样带给 Mac 复判）
  poly: number[] | null;                      // 自由框选路径（扁平 [x0,y0,x1,y1,…]，归一化；提交时带给 Mac 多边形复判）
  strokeIdx: number[];                        // 命中的 G.strokes 下标（本地渲染高亮/ghost 用）
  noteIdx: number[];                          // 命中的 G.notes 下标
  bounds: [number, number, number, number];   // x,y,w,h：命中内容的联合包围盒（画高亮框用）
}

/// 双指捏合锚点状态。
export interface Pinch {
  d0: number;
  z0: number;
  fx: number;
  fy: number;
}

/// 一张草稿纸（Mac `scratchpads` 广播元素）。`page/nx/ny` 是**锚点**（Mac 页面上那枚图钉的位置），
/// 不是纸的内容位置；纸上的内容坐标是画布坐标，见 PROTOCOL.md §4.4。
export interface Pad {
  id: string;
  title: string;
  page: number;
  nx: number;
  ny: number;
  bg: string;
  /// 底纹（"plain" | "dots" | "grid"，v9）。与 Mac `ScratchPattern` 同一张表。
  pattern: string;
  /// 页面底图（v10）：把这张纸锚定的那一页垫在纸下面当参照。几何契约见 PROTOCOL.md §4.4。
  showPage: boolean;
}

/// 草稿纸视口（本端私有，不上线也不落库：三端各自独立缩放滚动）。
/// `ox/oy` = 视口左上角对应的画布坐标，`z` = 画布→屏幕倍率。
export interface PadViewport { ox: number; oy: number; z: number }

/// App.svelte 传给 startCapture 的 DOM 引用（页图/笔迹层 + 草稿纸层 + 选笔盘毛玻璃底盘）。
export interface CaptureRefs {
  bg: HTMLCanvasElement;
  ink: HTMLCanvasElement;
  live: HTMLCanvasElement;
  hover: HTMLCanvasElement;
  radial: HTMLCanvasElement;
  radialGlass: HTMLDivElement;
  scratch: HTMLCanvasElement;
}

/// 全局可变状态袋的形状：原 capture.html IIFE 的模块级 var + 各模块挂上来的跨模块函数。
/// 数据字段在 capture.ts 的 startCapture() 初始化；函数字段在 initRender/initInput/initWs 里
/// 经 Object.assign(G, ...) 挂上（挂载必然先于任何调用）。
export interface GState {
  // 配置（Mac 端 CapturePage.swift 注入）
  PORT: number; TOKEN: string; PENS: Pen[];
  modeIdx: number; penIdx: number;
  // 多层笔迹：LAYERS/layerIdx 由 Mac 的 layers 广播全量镜像（唯一真源，平板不新增/删除本地数据，
  // 只发 layerSelect/layerVisible/layerAdd 请求，见 ws.ts）。
  LAYERS: Layer[]; layerIdx: number;
  // 画布/文档几何
  DPR: number;
  docV: string; pageCount: number; pagesWH: [number, number][];
  vw: number; availH: number; dispH: number[]; offY: number[]; totalH: number;
  zoom: number; scrollX: number; scrollY: number; maxScrollX: number; maxScrollY: number;
  imgs: Record<number, HTMLImageElement>; vpSeq: number;
  // 画板模式（Mac 下发的 `canvas`，逐文档）：页面两侧的空白也可书写。
  // canvasMargin = 每侧页边宽度 ÷ 页宽；落笔中本端可乐观跳档，下一条下发即以 Mac 为准。
  canvasOn: boolean; canvasMargin: number;
  // 笔迹：strokes = Mac 回传的已成形笔迹（静态层，唯一真源），cur = 正在写的这一笔（活体层）
  strokes: Stroke[]; cur: Stroke | null; radialActive: boolean; drawPage: number;
  // 文字笔记：notes = Mac 下发的全量镜像（本地只乐观更新，回传即整体替换）；noteMode = 文字笔记模式开关
  notes: TextNote[]; noteMode: boolean;
  /// 手指点开着的笔记气泡 id（**瞬态、不上行**：本端自己的展开状态，同 Mac 的 expandedNotes）。
  /// `hover` 模式的笔记在没有笔悬停的触摸端也走这条降级路径。
  noteExpanded: string[];
  /// 笔正悬停在哪条笔记的标记上（`hover` 模式的展开条件）；null = 没有。
  noteHover: string | null;
  // 尺子模式：独立本地开关，note 模式下笔迹吸附 45° 倍数直线（吸附在上行点生成处做）；
  // lineStroke = 落笔那一刻锁进当前这一笔的尺子状态（随 ink begin 的 line 标记上报 Mac）；
  // linePress = 这一笔见过的**峰值压感**（两点直线恒宽，见 input.ts 的尺子分支）
  rulerOn: boolean;
  lineStroke: boolean;
  linePress: number;
  // 橡皮：归一化半径（页宽比，默认 0.02）；eraserMode 0=整笔 1=局部（默认局部）；
  // eraserRing = 尺寸圆环开关（默认开）；eraserRingAt = 圆环位置（视口 CSS px，null=不画）。
  // 三者随 eraser 消息双向同步，PenStat 弹层改动后防抖上行。
  eraserSize: number;
  eraserMode: number;
  eraserRing: boolean;
  eraserRingAt: { x: number; y: number } | null;
  // 框选（lasso 模式，仅页内；命中算法本地复刻一份 Mac 端算法，只为即时预览，
  // 真正的判定+变更+持久化在 Mac，见 PROTOCOL.md `lassoMove`/`lassoScale`）：
  lassoSelection: LassoSelection | null;              // 当前选中集（本地判定）
  lassoDragMode: "select" | "move" | "scale" | null;  // 进行中框选手势的形态（null=无手势在飞）
  lassoAnchor: { page: number; nx: number; ny: number } | null;  // 落笔点（页内归一化）
  lassoDownX: number; lassoDownY: number;             // 落笔点（视口 px，判是否越过死区）
  lassoMoved: boolean;                                 // 是否已越过最小拖动距离（同 Mac DragGesture minimumDistance）
  lassoPath: { nx: number; ny: number }[] | null;      // select 模式自由框选路径（页内归一化，clamp 到锚点页，≥3px 抽稀）
  lassoHandle: string | null;                          // scale 模式被拖的手柄（tl/tr/bl/br=角·等比，t/b/l/r=边中点·单轴）
  /// scale 模式的缩放（页内归一化锚点 + 按轴缩放比）：拖动中 = ghost 预览；提交后保留作乐观渲染
  /// （同 lassoTranslate 的「提交后等回传」语义），clearLasso 一并清掉。
  lassoScale: { ax: number; ay: number; sx: number; sy: number } | null;
  lassoTranslate: { dx: number; dy: number };          // move 模式下的位移（拖动中 = ghost；提交后 = 乐观预览用）
  lassoCommitted: boolean;                             // 已发 lassoMove/lassoScale、等 Mac 回传 strokes/notes 期间为 true
  /// 提交后两条镜像（strokes/notes）**分开记账**：Mac 是两条独立广播，任意一条先到就清掉全部乐观
  /// 变换会让另一层跳回原位再跳回来（2026-08-18 用户报「放下后笔迹闪烁」的根因）——
  /// 哪条到了哪层改画真源（该层命中下标同时清空，halo/乐观变换停止作用于它），**两条都到齐才 clearLasso**。
  lassoSyncStrokes: boolean;
  lassoSyncNotes: boolean;
  lassoPendingTimer: ReturnType<typeof setTimeout> | null;  // 提交后的兜底超时（正常路径 Mac 必回传——含零命中，这只是保险丝）
  // 指针/批点（batch 元素：note=[nx,ny,pressure]，erase=[nx,ny,page]）
  activeId: number | null; penMode: string; penX: number; penY: number; batch: number[][];
  pbatch: [number, number][]; probePage: number; probing: boolean;
  touches: Record<number, { x: number; y: number }>; touchOrder: number[];
  panId: number | null; lastPanX: number; lastPanY: number; pinch: Pinch | null;
  zoomLocked: boolean;
  /// 锁定水平滚动：内容的横向位置不再跟手改变（拖动/惯性只走纵向）。放大了看、或画板模式下
  /// 在页边写字时，竖着划一道很难不带横向分量，页面于是慢慢跑偏。缩放引起的横向重锚不受影响。
  hLocked: boolean;
  // 双指滚动模式（防误触）：单指划动不平移页面/草稿纸，滚动与缩放一律双指。
  // 单指仍可轻点图钉开纸、按住图钉拖动（刻意动作，不会是误触）。
  twoFinger: boolean;
  gestureBlocked: boolean;         // 本次手指手势被 twoFinger 挡下过 → 抬手不能再当轻点去开图钉
  showPage: boolean;
  panDownX: number; panDownY: number; panStarted: boolean;
  vx: number; vy: number; lastMoveT: number; momentumRAF: number | null;
  reportPending: boolean;
  // 悬停
  hoverPending: boolean; hoverMsg: WireMsg | null; hoverOn: boolean;
  // 环形选笔盘 + 长按进度环（Mac 下发的镜像状态）
  radialState: RadialState | null; pressRing: PressRing | null; pressRAF: number | null;
  // ---- 草稿纸（v8，见 lib/scratch.ts；坐标系契约 PROTOCOL.md §4.4）----
  // pads/padOpen 是 Mac `scratchpads` 广播的全量镜像（唯一真源）；padStrokes 同理来自 scratchStrokes。
  // padVp 是**本端私有**的视口，不上线不落库——三端各自独立的缩放滚动就是靠这个。
  pads: Pad[];
  padOpen: number;                 // 开着第几张（-1 = 没开，此时草稿纸层整层隐藏）
  padStrokes: Stroke[];            // 当前那张纸上的已成形笔迹（pts 是画布坐标，page 恒 0 无意义）
  padCur: Stroke | null;           // 正在写的这一笔（本地即时回显）
  padVp: PadViewport;
  padMini: boolean;                // minimap 开关
  padMiniDrag: boolean;            // 正在 minimap 上拖动定位
  // 草稿纸上的双指捏合锚点；mx/my = 上一帧两指中点（中点整体挪动 = 平移，见 scratch.ts padPointerMove）
  padPinch: { d0: number; z0: number; mx: number; my: number } | null;
  // 图钉页内拖动（手指按住图钉、越过死区 = 拖动，否则保持单击开纸）：
  // pinDragIndex/pinDragMoved 是手势瞬态；pinGhost 是乐观预览位置（拖动中 + 松手后等
  // scratchpads 回推期间），applyScratchPads 落地即清——以 Mac 回推为权威（同 scratchPaper 惯例）。
  pinDragIndex: number;            // 按住时命中的图钉下标（-1 = 无）
  pinDragMoved: boolean;           // 已越过死区 → 本次是拖动而非单击
  pinGhost: { index: number; nx: number; ny: number } | null;
  // 页宽上报去重
  lastGeomW: number;
  // WebSocket
  ws: WebSocket | null; pingTimer: ReturnType<typeof setInterval> | null;
  lastPong: number; retryTimer: ReturnType<typeof setTimeout> | null; retryDelay: number;
  // 统计计数（hud 的 1s 统计区间消费并清零）
  upCount: number; downCount: number; frames: number;
  /// 分层绘制耗时累计（每秒被 HUD 读走并清零）。「卡不卡」不能靠感觉——平板上滚动到底是
  /// 页图 drawImage 贵还是笔迹层贵，只有分开计时才分得清。
  drawN: number; drawBgMs: number; drawInkMs: number; drawRestMs: number;

  // ---- 跨模块函数（各 init 模块挂上，见上）----
  // ws.ts
  send(o: WireMsg): void;
  connect(): void;
  emitGeom(): void;
  applyViewport(o: WireMsg): void;
  // render.ts
  relayout(): void;
  recompute(): void;
  locate(x: number, vy: number, wide?: boolean): PageLoc | null;
  /// 画板模式变更（Mac 下发的 `canvas`，或落笔中的本地乐观跳档）：改内容宽 + 重算几何 + 重画。
  setCanvas(on: boolean, margin: number): void;
  /// 落笔中的乐观跳档：这一笔写到离页边不足 slack 就本地先把页边放宽一档，别等 Mac 的回程。
  growCanvas(nx: number): void;
  /// 真源回推的笔迹越界 → 本地放宽一档（只增不减；渲染按当前页边 clamp，档位不跟上就画成一条）
  growCanvasForStrokes(): void;
  pageToView(page: number, nx: number, ny: number): { x: number; y: number };
  inContent(x: number, y: number): boolean;
  drawAll(): void;
  drawBg(): void;
  drawInk(): void;
  drawLive(): void;
  eraseHit(x: number, y: number): void;
  ensureImages(): void;
  /// 取某一页的页图（缺就发起加载，返回当前的 Image 对象；草稿纸的页面底图用）。
  loadPageImage(i: number): HTMLImageElement | null;
  clearHover(): void;
  drawNotes(): void;
  setRadial(o: WireMsg | null): void;
  setPressRing(o: WireMsg | null): void;
  // 框选（lasso 模式，本地判定，见上 GState 字段注释）
  pageLocClamped(x: number, y: number, page: number, wide?: boolean): { nx: number; ny: number };
  lassoHitTest(page: number, poly: number[]): LassoSelection | null;
  /// 当前选中集的屏显框（外扩 6px + 最小 16px，**不含 ghost**）：渲染高亮框/手柄与手柄命中判定共用，
  /// 别各算各的（同 Mac `lassoDisplayBox`）。
  lassoViewBox(): { x: number; y: number; w: number; h: number } | null;
  /// 8 个缩放手柄的屏显位置（不含 ghost）：手柄命中判定与缩放锚点计算用（同 Mac `LassoHandle`）。
  lassoHandlePts(): { h: string; x: number; y: number }[];
  clearLasso(): void;
  // input.ts
  panBy(dx: number, dy: number): void;
  cancelMomentum(): void;
  startMomentum(): void;
  emitScroll(): void;
  topVisiblePage(): number;
  endHover(): void;
  // render.ts：笔迹几何的可复用内核（页内与草稿纸共用一份实现，见 buildGeomWith 注释）
  buildGeomWith(s: Stroke, px: (i: number) => number, py: (i: number) => number,
                wScale: number, key: number): unknown;
  paintInkGeom(cx: CanvasRenderingContext2D, g: unknown, tx: number, ty: number): void;
  /// 草稿纸图钉命中 → 下标（-1 = 没命中）。手指单击用，见 input.ts endTouch。
  padPinHit(x: number, y: number): number;
  /// 文字笔记标记命中 → 那条笔记（null = 没命中）。手指单击展开/收起气泡、笔悬停判 hover 模式用。
  noteMarkerHit(x: number, y: number): TextNote | null;
  /// 展开气泡右上角铅笔命中 → 那条笔记（null = 没命中）：点它进编辑器。
  noteEditHit(x: number, y: number): TextNote | null;
  // scratch.ts（草稿纸）
  padActive(): boolean;
  drawScratch(): void;
  padRecenter(): void;
  padFit(): void;
  padClamp(): void;
  padPointerDown(e: PointerEvent): boolean;
  padPointerMove(e: PointerEvent): boolean;
  padPointerUp(e: PointerEvent): boolean;
  padFlush(kind: "ink" | "erase"): void;
  padOpenIndex(i: number): void;
  padClose(): void;
  padAdd(): void;
  padSetPaper(bg: string | null, pattern: string | null): void;
  padSetShowPage(show: boolean): void;
  padDelete(i: number): void;
  padRename(i: number, title: string): void;
  applyScratchPads(o: WireMsg): void;
  applyScratchStrokes(o: WireMsg): void;
  // capture.ts（键盘侧键走 G，input.ts 的 keydown 调用）
  cycleMode(): void;
  cyclePen(): void;
  // 单键快捷键（input.ts keydown）：直切模式 / e 橡皮来回切 / 数字键直选笔
  setModeKey(key: string): void;
  toggleErase(): void;
  selectPen(i: number): void;
}

export const BAR = 46, GAP = 8, MINZ = 0.5, MAXZ = 5;

export const MODES = [{ key: "note", label: "笔记" }, { key: "erase", label: "擦除" }, { key: "page", label: "翻页" }, { key: "lasso", label: "框选" }];
export const BRUSH_LABELS: Record<string, string> = { ballpoint: "圆珠笔", fountain: "钢笔", marker: "马克笔", pencil: "铅笔" };

// 环形选笔盘几何/压暗常量：两端画的是同一个盘，Mac 的「中心取消区」判定用的就是 RD.hub
// 这个像素半径（配合 padGeom 上报的页宽换算）。wedgeDim/hubDim 越小越透。
export const RD = { hub: 46, inner: 54, outer: 134, gap: 1.5, wedgeDim: 0.16, hubDim: 0.22 };
// 长按进度环（环形盘的前置动画）：300ms 起显示、700ms 填满、直径 30 线宽 3、从正上方顺时针。
export const PR = { d: 30, lw: 3, delayMs: 300, fillMs: 700 };
// 手掌接触阈值(px)、单指平移死区(px)
export const PALM = 60, DEAD = 8;

/// 全局可变状态袋：原 capture.html IIFE 的模块级 var 的平移（避免各模块 own 一半状态的耦合地狱）。
/// 全部字段的初始化在 capture.ts 的 startCapture()；跨模块读写一律走 G。
export const G = {} as GState;

export function clamp(v: number, lo: number, hi: number): number { return Math.min(hi, Math.max(lo, v)); }

/// 尺子吸附（Sources/App/InkEdit.swift 的 rulerSnap 的 JS 版，两边算法保持一致）：
/// (ax,ay)→(x,y) 的角度距最近的 45° 倍数 ≤ thresholdDeg 时贴合到该倍数（保长度），否则原样返回。
/// `aspect` = 页高/页宽（显示比例）：坐标是页内归一化的，x/y 尺度不同，直接在归一化空间量角度的话
/// 「45°」在屏幕上是 atan(aspect)（A4 上约 54.7°）——先把 y 折算成与 x 同尺度再量角、贴合完再折回去，
/// 吸附的才是**看上去**的 0/45/90°，长度也是看上去的长度。aspect=1 即退化回纯归一化空间。
export function rulerSnap(ax: number, ay: number, x: number, y: number, aspect = 1, thresholdDeg = 7): [number, number] {
  const a = aspect > 0 ? aspect : 1;
  const dx = x - ax, dy = (y - ay) * a;
  const len = Math.hypot(dx, dy);
  if (!len) return [x, y];
  const step = Math.PI / 4;   // 45°
  const ang = Math.atan2(dy, dx);
  const snapped = Math.round(ang / step) * step;
  if (Math.abs(ang - snapped) > thresholdDeg * Math.PI / 180) return [x, y];
  return [ax + len * Math.cos(snapped), ay + len * Math.sin(snapped) / a];
}

export function curMode(): string { return MODES[G.modeIdx].key; }
export function curPen(): Pen { return G.PENS[G.penIdx]; }
export function curLayer(): Layer | undefined { return G.LAYERS[G.layerIdx]; }

export function pw(): number { return G.vw * G.zoom; }                                    // 页宽

// ---- 画板模式（PROTOCOL.md `canvas`）：页面两侧的空白也可书写，内容因此比页面宽 ----
// 页边笔迹仍是页内笔迹，只是归一化 x 越出 0…1；`margin` 由 Mac 单方面下发（页宽的倍数）。
// 关着时 cmargin()==0，下面三个函数全部退化成画板模式之前的老式子。

/// 每侧页边宽度（页宽的倍数）。
export function cmargin(): number { return G.canvasOn ? Math.max(0, G.canvasMargin) : 0; }
/// 可滚动内容总宽（页 + 两侧页边）。
export function contentW(): number { return pw() * (1 + 2 * cmargin()); }
/// 内容左缘视口 x（页边最左，画页边纸用）。窄于视口时整体居中。
export function canvasLeft(): number { const c = contentW(); return c <= G.vw ? (G.vw - c) / 2 : -G.scrollX; }
/// **页**左缘视口 x（页内归一化 x=0 处）——所有页内坐标换算都用它。
export function contentLeft(): number { return canvasLeft() + cmargin() * pw(); }
/// 页内归一化 x 的合法区间（画板模式放宽到页边），同 Mac `CanvasMargin.xRange`。
export function inkXMin(): number { return -cmargin(); }
export function inkXMax(): number { return 1 + cmargin(); }

// 软边界档位（**与 Mac `CanvasMargin` 同一组常数**）：客户端只在落笔中做乐观跳档，
// 免得写到边缘要等一个 RTT 才有地方下笔；Mac 的下发值一到即以它为准。
export const CANVAS_STEP = 0.5;
export const CANVAS_SLACK = 0.35;
export const CANVAS_LIMIT = 8;
/// 越界量 → 每侧页边宽度（档位化），同 Mac `CanvasMargin.margin(overflow:)`。
export function canvasMarginFor(overflow: number): number {
  const need = Math.max(0, overflow) + CANVAS_SLACK;
  return Math.min(CANVAS_LIMIT, Math.max(CANVAS_STEP, Math.ceil(need / CANVAS_STEP) * CANVAS_STEP));
}

// ---- 笔触类型：跟 Mac 端 PenBrushType.strokeWidth/opacityMultiplier 同一套公式 ----
export function strokeWidthFor(t: string, p: number, w: number): number {
  if (t === "fountain") return 0.3 + Math.pow(p, 1.6) * w * 1.3;
  if (t === "marker") return w;
  if (t === "pencil") return 0.5 + p * w * 0.85;
  return 0.6 + p * w;   // ballpoint / 未知类型兜底
}
export function opacityMultFor(t: string): number { return t === "pencil" ? 0.85 : 1; }

/**
 * 钢笔起收笔锥度（0~1 乘线宽）：`i/(n-1)` 为点在笔画中的归一化位置，两端渐细、中段为 1；
 * 非钢笔恒 1。与 Mac `PenBrushType.fountainTaper` / 安卓 `PadConst.fountainTaper` **逐字同式**。
 *
 * `n <= 2` 不锥：两点笔画 = 尺子直线或擦除切出的碎段，按 index 算的话整条都落在「两端」、
 * 会整体细成 0.18 倍。
 *
 * 2026-09-07 补：此前 web 与安卓**一行都没有**，只有 Mac 有——同一支钢笔在 Mac 上两头尖、
 * 在平板上齐头齐尾，`spike/ink-cross/` 的 `fountain-taper` 向量就是照出这条分叉的判据。
 */
export function fountainTaper(t: string, i: number, n: number): number {
  if (t !== "fountain" || n <= 2) return 1;
  const p = i / (n - 1), edge = 0.16;
  const a = Math.min(p, 1 - p) / edge;
  return a >= 1 ? 1 : (a * a * (3 - 2 * a)) * 0.82 + 0.18;
}

// ---- 铅笔「多道微波动叠加」：与 Mac `PenBrushType.pencilPasses` / 安卓 `PadConst.PENCIL_*` 同一套 ----
//
// 2026-09-07 补：此前 web 与安卓的铅笔是**一条光溜的粗实线**，只有 Mac 有石墨纹理，
// 墨量差 65%（`spike/ink-cross/` 的 pencil-texture 向量照出来的）。

/** 每道 (垂向波幅×线宽, 该道 alpha, 线宽比例, 相位)。首道波幅 0 作居中核心，其余低频垂向波动。 */
export const PENCIL_PASSES: { amp: number; alpha: number; wScale: number; phase: number }[] = [
  { amp: 0.0, alpha: 0.34, wScale: 0.55, phase: 0.0 },
  { amp: 0.34, alpha: 0.16, wScale: 0.45, phase: 2.3 },
  { amp: 0.34, alpha: 0.16, wScale: 0.45, phase: 4.6 },
];
/** 波幅公式里线宽项的上限：不封顶的话调粗画笔时波幅线性变大，显成锯齿尖刺而不是石墨纹理。 */
export const PENCIL_WOBBLE_REF_W = 9.0;
/** 波动相位推进速率（弧度/像素，按累计弧长走**不按点序号**）。觉得纹理太碎/太稀就改这一个数。 */
export const PENCIL_WOBBLE_FREQ = 0.025;

/**
 * GLSL 风 hash → [-1,1]，种子用**归一化**坐标（缩放无关；铅笔纹理重绘不抖）。
 * 与 Mac `InkRender.jitter` 同式。
 */
export function inkJitter(x: number, y: number): number {
  const v = Math.sin(x * 12.9898 + y * 78.233) * 43758.5453;
  return (v - Math.floor(v)) * 2 - 1;
}

/** 点 i 处的路径垂线单位向量（用前后邻点估切线）。与 Mac `InkRender.perp` 同式。 */
export function inkPerp(xs: number[], ys: number[], i: number): [number, number] {
  const a = Math.max(0, i - 1), b = Math.min(xs.length - 1, i + 1);
  const dx = xs[b] - xs[a], dy = ys[b] - ys[a];
  const len = Math.max(0.0001, Math.sqrt(dx * dx + dy * dy));
  return [-dy / len, dx / len];
}
export function scaledColor(css: string, mult: number): string {
  if (mult === 1) return css;
  const m = /rgba?\(([^)]+)\)/.exec(css);
  if (!m) return css;
  const parts = m[1].split(",").map((s) => parseFloat(s));
  const a = parts.length > 3 ? parts[3] : 1;
  return "rgba(" + parts[0] + "," + parts[1] + "," + parts[2] + "," + (a * mult) + ")";
}
