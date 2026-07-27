// 装配模块：把 Mac 注入的配置 + DOM 引用灌进共享状态袋 G，初始化 render/input/ws，
// 并把顶栏/键盘动作挂到 actions 袋（Svelte 组件经 actions.ts 调用）。
import { G, MODES, clamp, curMode } from "./shared.js";
import type { CaptureRefs, Pen } from "./shared.js";
import { S, updateHud, updatePageLabel, startStats } from "./hud.svelte.js";
import { initRender } from "./render.js";
import { initInput } from "./input.js";
import { initWs } from "./ws.js";
import { actions } from "./actions.js";

export interface StartConfig {
  port: number;
  token: string;
  pens: Pen[];
}

export function startCapture(refs: CaptureRefs, config: StartConfig): void {
  // ---- 原 IIFE 的全部模块级 var，集中初始化 ----
  Object.assign(G, {
    // 配置（Mac 端 CapturePage.swift 注入）
    PORT: config.port, TOKEN: config.token, PENS: config.pens,
    modeIdx: 0, penIdx: 0,
    // 多层笔迹：空列表兜底（Mac 的 layers 广播到达前，LayerStat 胶囊显示占位文案）。
    LAYERS: [], layerIdx: 0,
    // 画布/文档几何
    DPR: 1,
    docV: "", pageCount: 0, pagesWH: [],
    vw: 1, availH: 1, dispH: [], offY: [], totalH: 0,
    zoom: 1, scrollX: 0, scrollY: 0, maxScrollX: 0, maxScrollY: 0,
    imgs: {}, vpSeq: 0,
    // 笔迹：strokes = Mac 回传的已成形笔迹（静态层，唯一真源），cur = 正在写的这一笔（活体层）
    strokes: [], cur: null, radialActive: false, drawPage: 0,
    // 文字笔记：Mac 下发全量镜像；noteMode = 文字笔记模式开关
    notes: [], noteMode: false,
    // 尺子模式：独立本地开关（note 模式下 45° 吸附直线）；lineStroke = 当前这一笔锁定的尺子状态
    rulerOn: false, lineStroke: false,
    // 橡皮：归一化半径（页宽比）/ 模式（1=局部）/ 尺寸圆环开关与位置（Mac 的 eraser 消息下发后更新）
    eraserSize: 0.02, eraserMode: 1, eraserRing: true, eraserRingAt: null,
    // 框选移动（lasso 模式，全部瞬态，本地判定仅用于预览）
    lassoSelection: null, lassoDragMode: null, lassoAnchor: null,
    lassoDownX: 0, lassoDownY: 0, lassoMoved: false, lassoCurBox: null,
    lassoTranslate: { dx: 0, dy: 0 }, lassoCommitted: false, lassoPendingTimer: null,
    // 指针/批点
    activeId: null, penMode: "", penX: 0, penY: 0, batch: [],
    pbatch: [], probePage: 0, probing: false,           // 探针流（擦除/翻页模式专用）：平行上报笔位置给 Mac 做长按检测/环形盘
    touches: {}, touchOrder: [], panId: null, lastPanX: 0, lastPanY: 0, pinch: null,
    zoomLocked: false,
    showPage: true,                                     // false = 纯手写板（不取图、只白底）
    panDownX: 0, panDownY: 0, panStarted: false,
    vx: 0, vy: 0, lastMoveT: 0, momentumRAF: null,      // 惯性滚动（速度单位: scroll px/ms）
    reportPending: false,
    // 悬停
    hoverPending: false, hoverMsg: null, hoverOn: false,
    // 环形选笔盘 + 长按进度环（Mac 下发的镜像状态）
    radialState: null, pressRing: null, pressRAF: null,
    // 页宽上报去重
    lastGeomW: -1,
    // WebSocket
    ws: null, pingTimer: null, lastPong: 0, retryTimer: null, retryDelay: 1500,
    // 统计计数（hud 的 1s 统计区间消费并清零）
    upCount: 0, downCount: 0, frames: 0,
  });

  initRender(refs);
  initInput(refs);
  initWs();
  startStats();

  // ---- 顶栏/键盘动作 ----
  // 翻页按钮：滚到相邻页顶部（并上报，Mac 跟随）。
  function turn(dir: "prev" | "next"): void {
    if (!G.pageCount || !G.offY.length) return;   // layout 未到时按了会把 scrollY 置成 NaN，整页卡死
    const i = clamp(G.topVisiblePage() + (dir === "prev" ? -1 : 1), 0, Math.max(0, G.pageCount - 1));
    G.scrollY = clamp(G.offY[i], 0, G.maxScrollY);
    G.ensureImages(); G.drawAll(); updatePageLabel(); G.emitScroll();
  }
  // 切走框选工具即放弃选中（同 Mac 端 `pointerTool != .lasso` 清 lassoSelection 同理，残留高亮框会误导）。
  function cycleMode(): void {
    const leavingLasso = curMode() === "lasso";
    G.modeIdx = (G.modeIdx + 1) % MODES.length;
    G.activeId = null; G.penMode = ""; G.eraserRingAt = null;
    if (leavingLasso) G.clearLasso();
    G.drawNotes(); G.endHover(); updateHud();
    G.send({ type: "mode", mode: curMode() });
  }
  function cyclePen(): void {
    // 非笔模式（橡皮/翻页/框选）按切笔键 = 恢复之前那支笔，不轮替下一支；笔模式下才轮替。
    if (G.modeIdx === 0) { G.penIdx = (G.penIdx + 1) % G.PENS.length; }
    if (curMode() === "lasso") G.clearLasso();
    G.modeIdx = 0; updateHud();
    G.send({ type: "pen", index: G.penIdx }); G.send({ type: "mode", mode: curMode() });
  }
  Object.assign(actions, {
    turn,
    cycleMode,
    cyclePen,
    selectDoc(id: string) { G.send({ type: "selectDoc", id: id }); },
    toggleStats() { S.statsOn = !S.statsOn; },
    // 夜间模式：仅反转背景页图 canvas（invert 反亮度、hue-rotate 复原彩色）；墨迹/圆环不反。
    toggleNight() {
      const on = !refs.bg.style.filter;
      refs.bg.style.filter = on ? "invert(1) hue-rotate(180deg)" : "";
      S.night = on;
    },
    toggleEye() { G.showPage = !G.showPage; S.showPage = G.showPage; if (G.showPage) G.ensureImages(); G.drawAll(); },
    // 文字笔记模式：独立本地开关，只影响后续 pen pointerdown 分派（点页面开编辑器，不写字）。
    toggleTextNote() {
      G.noteMode = !G.noteMode; S.noteMode = G.noteMode;
      if (!G.noteMode) S.noteEditor = null;   // 关掉模式时顺手收起开着的编辑器
      updateHud();
    },
    // 尺子模式：独立本地开关，只影响 note 模式 pointermove 的采点（45° 吸附直线）。
    toggleRuler() { G.rulerOn = !G.rulerOn; S.rulerOn = G.rulerOn; },
    toggleLock() { G.zoomLocked = !G.zoomLocked; S.zoomLocked = G.zoomLocked; },
    toggleFull() {
      if (!document.fullscreenElement) {
        const root = document.documentElement;
        const req = root.requestFullscreen || (root as any).webkitRequestFullscreen;
        // 不锁定方向：竖屏/横屏均可，布局随 resize 自适应
        if (req) Promise.resolve(req.call(root)).catch(function () {});
      } else {
        ((document as any).exitFullscreen || (document as any).webkitExitFullscreen).call(document);
      }
    },
  });
  // 键盘侧键走 G（input.ts 的 keydown 调用）
  G.cycleMode = cycleMode;
  G.cyclePen = cyclePen;

  updateHud(); G.relayout(); G.connect();
}
