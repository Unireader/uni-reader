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
  // 笔迹：strokes = Mac 回传的已成形笔迹（静态层，唯一真源），cur = 正在写的这一笔（活体层）
  strokes: Stroke[]; cur: Stroke | null; radialActive: boolean; drawPage: number;
  // 文字笔记：notes = Mac 下发的全量镜像（本地只乐观更新，回传即整体替换）；noteMode = 文字笔记模式开关
  notes: TextNote[]; noteMode: boolean;
  // 尺子模式：独立本地开关，note 模式下笔迹吸附 45° 倍数直线（吸附在上行点生成处做）；
  // lineStroke = 落笔那一刻锁进当前这一笔的尺子状态（随 ink begin 的 line 标记上报 Mac）
  rulerOn: boolean;
  lineStroke: boolean;
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
  lassoPendingTimer: ReturnType<typeof setTimeout> | null;  // 提交后的兜底超时（Mac 判定为零变化时不会回传，靠它兜底清状态）
  // 指针/批点（batch 元素：note=[nx,ny,pressure]，erase=[nx,ny,page]）
  activeId: number | null; penMode: string; penX: number; penY: number; batch: number[][];
  pbatch: [number, number][]; probePage: number; probing: boolean;
  touches: Record<number, { x: number; y: number }>; touchOrder: number[];
  panId: number | null; lastPanX: number; lastPanY: number; pinch: Pinch | null;
  zoomLocked: boolean;
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
  locate(x: number, vy: number): PageLoc | null;
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
  pageLocClamped(x: number, y: number, page: number): { nx: number; ny: number };
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

export function pw(): number { return G.vw * G.zoom; }                                    // 页(内容)宽
export function contentLeft(): number { const p = pw(); return p <= G.vw ? (G.vw - p) / 2 : -G.scrollX; }   // 内容左缘视口 x

// ---- 笔触类型：跟 Mac 端 PenBrushType.strokeWidth/opacityMultiplier 同一套公式 ----
export function strokeWidthFor(t: string, p: number, w: number): number {
  if (t === "fountain") return 0.3 + Math.pow(p, 1.6) * w * 1.3;
  if (t === "marker") return w;
  if (t === "pencil") return 0.5 + p * w * 0.85;
  return 0.6 + p * w;   // ballpoint / 未知类型兜底
}
export function opacityMultFor(t: string): number { return t === "pencil" ? 0.85 : 1; }
export function scaledColor(css: string, mult: number): string {
  if (mult === 1) return css;
  const m = /rgba?\(([^)]+)\)/.exec(css);
  if (!m) return css;
  const parts = m[1].split(",").map((s) => parseFloat(s));
  const a = parts.length > 3 ? parts[3] : 1;
  return "rgba(" + parts[0] + "," + parts[1] + "," + parts[2] + "," + (a * mult) + ")";
}
