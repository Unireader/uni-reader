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
  kind: string;           // "pen" | "erase" | "page"
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

/// 双指捏合锚点状态。
export interface Pinch {
  d0: number;
  z0: number;
  fx: number;
  fy: number;
}

/// App.svelte 传给 startCapture 的 DOM 引用（5 层 canvas + 选笔盘毛玻璃底盘）。
export interface CaptureRefs {
  bg: HTMLCanvasElement;
  ink: HTMLCanvasElement;
  live: HTMLCanvasElement;
  hover: HTMLCanvasElement;
  radial: HTMLCanvasElement;
  radialGlass: HTMLDivElement;
}

/// 全局可变状态袋的形状：原 capture.html IIFE 的模块级 var + 各模块挂上来的跨模块函数。
/// 数据字段在 capture.ts 的 startCapture() 初始化；函数字段在 initRender/initInput/initWs 里
/// 经 Object.assign(G, ...) 挂上（挂载必然先于任何调用）。
export interface GState {
  // 配置（Mac 端 CapturePage.swift 注入）
  PORT: number; TOKEN: string; PENS: Pen[];
  modeIdx: number; penIdx: number;
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
  // 指针/批点（batch 元素：note=[nx,ny,pressure]，erase=[nx,ny,page]）
  activeId: number | null; penMode: string; penX: number; penY: number; batch: number[][];
  pbatch: [number, number][]; probePage: number; probing: boolean;
  touches: Record<number, { x: number; y: number }>; touchOrder: number[];
  panId: number | null; lastPanX: number; lastPanY: number; pinch: Pinch | null;
  zoomLocked: boolean;
  showPage: boolean;
  panDownX: number; panDownY: number; panStarted: boolean;
  vx: number; vy: number; lastMoveT: number; momentumRAF: number | null;
  reportPending: boolean;
  // 悬停
  hoverPending: boolean; hoverMsg: WireMsg | null; hoverOn: boolean;
  // 环形选笔盘 + 长按进度环（Mac 下发的镜像状态）
  radialState: RadialState | null; pressRing: PressRing | null; pressRAF: number | null;
  // 页宽上报去重
  lastGeomW: number;
  // WebSocket
  ws: WebSocket | null; pingTimer: ReturnType<typeof setInterval> | null;
  lastPong: number; retryTimer: ReturnType<typeof setTimeout> | null; retryDelay: number;
  // 统计计数（hud 的 1s 统计区间消费并清零）
  upCount: number; downCount: number; frames: number;

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
  clearHover(): void;
  drawNotes(): void;
  setRadial(o: WireMsg | null): void;
  setPressRing(o: WireMsg | null): void;
  // input.ts
  panBy(dx: number, dy: number): void;
  cancelMomentum(): void;
  startMomentum(): void;
  emitScroll(): void;
  topVisiblePage(): number;
  endHover(): void;
  // capture.ts（键盘侧键走 G，input.ts 的 keydown 调用）
  cycleMode(): void;
  cyclePen(): void;
}

export const BAR = 46, GAP = 8, MINZ = 0.5, MAXZ = 5;

export const MODES = [{ key: "note", label: "笔记" }, { key: "erase", label: "擦除" }, { key: "page", label: "翻页" }];
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

export function curMode(): string { return MODES[G.modeIdx].key; }
export function curPen(): Pen { return G.PENS[G.penIdx]; }

export function pw(): number { return G.vw * G.zoom; }                                    // 页(内容)宽
export function contentLeft(): number { const p = pw(); return p <= G.vw ? (G.vw - p) / 2 : -G.scrollX; }   // 内容左缘视口 x

// ---- 笔触类型：跟 Mac 端 PenBrushType.strokeWidth/opacityMultiplier 同一套公式 ----
export function strokeWidthFor(t: string, p: number, w: number): number {
  if (t === "fountain") return 0.3 + Math.pow(p, 1.6) * w * 1.15;
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
