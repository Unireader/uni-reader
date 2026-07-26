// 装配模块：把 Mac 注入的配置 + DOM 引用灌进共享状态袋 G，初始化 render/input/ws，
// 并把顶栏/键盘动作挂到 actions 袋（Svelte 组件经 actions.js 调用）。
import { G, MODES, clamp, curMode } from "./shared.js";
import { S, updateHud, updatePageLabel, startStats } from "./hud.svelte.js";
import { initRender } from "./render.js";
import { initInput } from "./input.js";
import { initWs } from "./ws.js";
import { actions } from "./actions.js";

export function startCapture(refs, config) {
  // ---- 原 IIFE 的全部模块级 var，集中初始化 ----
  Object.assign(G, {
    // 配置（Mac 端 CapturePage.swift 注入）
    PORT: config.port, TOKEN: config.token, PENS: config.pens,
    modeIdx: 0, penIdx: 0,
    // 画布/文档几何
    DPR: 1,
    docV: "", pageCount: 0, pagesWH: [],
    vw: 1, availH: 1, dispH: [], offY: [], totalH: 0,
    zoom: 1, scrollX: 0, scrollY: 0, maxScrollX: 0, maxScrollY: 0,
    imgs: {}, vpSeq: 0,
    // 笔迹：strokes = Mac 回传的已成形笔迹（静态层，唯一真源），cur = 正在写的这一笔（活体层）
    strokes: [], cur: null, radialActive: false, drawPage: 0,
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
  function turn(dir) {
    if (!G.pageCount || !G.offY.length) return;   // layout 未到时按了会把 scrollY 置成 NaN，整页卡死
    const i = clamp(G.topVisiblePage() + (dir === "prev" ? -1 : 1), 0, Math.max(0, G.pageCount - 1));
    G.scrollY = clamp(G.offY[i], 0, G.maxScrollY);
    G.ensureImages(); G.drawAll(); updatePageLabel(); G.emitScroll();
  }
  function cycleMode() { G.modeIdx = (G.modeIdx + 1) % MODES.length; G.activeId = null; G.penMode = ""; G.endHover(); updateHud(); G.send({ type: "mode", mode: curMode() }); }
  function cyclePen() {
    G.penIdx = (G.penIdx + 1) % G.PENS.length; G.modeIdx = 0; updateHud();
    G.send({ type: "pen", index: G.penIdx }); G.send({ type: "mode", mode: curMode() });
  }
  Object.assign(actions, {
    turn,
    cycleMode,
    cyclePen,
    selectDoc(id) { G.send({ type: "selectDoc", id: id }); },
    toggleStats() { S.statsOn = !S.statsOn; },
    // 夜间模式：仅反转背景页图 canvas（invert 反亮度、hue-rotate 复原彩色）；墨迹/圆环不反。
    toggleNight() {
      const on = !refs.bg.style.filter;
      refs.bg.style.filter = on ? "invert(1) hue-rotate(180deg)" : "";
      S.night = on;
    },
    toggleEye() { G.showPage = !G.showPage; S.showPage = G.showPage; if (G.showPage) G.ensureImages(); G.drawAll(); },
    toggleLock() { G.zoomLocked = !G.zoomLocked; S.zoomLocked = G.zoomLocked; },
    toggleFull() {
      if (!document.fullscreenElement) {
        const root = document.documentElement;
        const req = root.requestFullscreen || root.webkitRequestFullscreen;
        // 不锁定方向：竖屏/横屏均可，布局随 resize 自适应
        if (req) Promise.resolve(req.call(root)).catch(function () {});
      } else {
        (document.exitFullscreen || document.webkitExitFullscreen).call(document);
      }
    },
  });
  // 键盘侧键走 G（input.js 的 keydown 调用）
  G.cycleMode = cycleMode;
  G.cyclePen = cyclePen;

  updateHud(); G.relayout(); G.connect();
}
