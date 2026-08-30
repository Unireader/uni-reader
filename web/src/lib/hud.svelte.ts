// HUD 响应式状态（Svelte 5 runes）+ 顶栏/状态胶囊/延迟统计的更新函数。
// 高频命令式逻辑仍走 shared.ts 的 G 袋；只有 HUD 绑定字段进 S（组件据此渲染）。
import { G, curMode, curPen } from "./shared.js";
import type { Layer, Pen } from "./shared.js";

export interface DocEntry {
  id: string;
  title: string;
}

/// 工作区书库一项（Mac `library` 广播）。`id` 是**库文档 id**，与 DocEntry 的窗口会话 id 不是一个
/// 空间（PROTOCOL.md §4.1）；`open` = 该文档已在 Mac 某个窗口里开着。
export interface LibEntry {
  id: string;
  title: string;
  open: boolean;
}

/// PDF 目录一项（Mac `toc` 广播，先序拍平）。`page` = -1 是坏书签（跳不过去，渲染成灰行）。
export interface TocEntry {
  depth: number;
  page: number;
  frac: number;
  label: string;
}

/// 草稿纸列表一项（Mac `scratchpads` 广播）。`page` = 锚点所在页（列表里显示「第 N 页」）。
export interface PadEntry {
  id: string;
  title: string;
  page: number;
  index: number;
  /// 这张纸有没有垫着它锚定的那一页（v10；几何契约见 PROTOCOL.md §4.4）
  showPage: boolean;
}

/// 文字笔记编辑器的打开状态（低频 UI，放 runes；面板定位用打开瞬间的视口坐标）。
export interface NoteEditorState {
  id: string;                          // 笔记 id（新建时打开即生成）
  page: number; nx: number; ny: number; // 页内归一化锚点（与笔迹同系）
  x: number; y: number;                // 打开时的视口坐标（面板定位用）
  text: string;                        // 初始文本
  display: number;                     // 展开方式 0=点击 1=悬浮 2=始终（每条笔记自己的属性）
  isNew: boolean;                      // true = 新建（编辑器不显示删除按钮）
}

export const S = $state({
  connected: false,        // WS 已认证（顶栏绿点）
  latText: "— ms",         // 顶栏延迟读数
  docs: [] as DocEntry[],  // Mac 下发的文档列表 [{id,title}]
  docValue: "",            // 文档下拉的当前值（"" = 跟随 Mac）
  zoomLabel: "100%",
  pageLabel: "— / —",
  modeKey: "note",         // 当前模式 key（penStat 显示分支）
  pen: null as Pen | null, // 当前笔 {color,w,t}（penStat 色块/标签）
  layers: [] as Layer[],   // 图层表（layerStat 列表，Mac layers 广播镜像）
  layerIdx: 0,             // 当前作画图层在 layers 里的下标
  statsOn: false,          // 延迟统计面板开关
  statsText: "",
  night: false,            // 夜间模式（按钮图标回显）
  noteMode: false,         // 文字笔记模式（顶栏按钮激活态回显）
  rulerOn: false,          // 尺子模式（顶栏按钮激活态回显）
  noteEditor: null as NoteEditorState | null,   // 文字笔记编辑器（非 null = 打开中）
  showPage: true,          // 页面图显示（眼睛按钮回显）
  canvasOn: false,         // 画板模式（Mac 下发，顶栏按钮回显）
  zoomLocked: false,       // 锁定缩放（锁按钮回显）
  hLocked: false,          // 锁定水平滚动（顶栏按钮激活态回显）
  twoFinger: false,        // 双指滚动模式 / 防误触（顶栏按钮激活态回显）
  // ---- 侧拉抽屉（目录 / 书库）----
  drawer: false,           // 抽屉开关
  drawerTab: "toc" as "toc" | "lib",   // 停在哪一页（关掉再开回到这里）
  toc: [] as TocEntry[],   // 当前文档目录（Mac toc 广播镜像）
  tocDocId: "",            // 这份目录属于哪个文档（内容哈希）
  docV: "",                // 当前显示文档的内容哈希（layout 广播带来）——与 tocDocId 一致才敢渲染目录
  library: [] as LibEntry[],  // 工作区书库（Mac library 广播镜像）
  libraryWs: "",           // 工作区显示名
  curPage: 0,              // 当前页（0-based）：目录的「当前章节」追踪用
  // ---- 草稿纸（v8）----
  pads: [] as PadEntry[],  // 草稿纸列表（Mac scratchpads 广播镜像）
  padOpen: -1,             // 当前打开第几张（-1 = 没开）
  padMini: true,           // minimap 开关（顶栏按钮回显）
  padList: false,          // 草稿纸列表弹层开关
  padPaper: false,         // 纸样面板开关
  padBg: "",               // 当前那张纸的底色（CSS rgba，色块选中态回显）
  padPattern: "dots",      // 当前那张纸的底纹
  padShowPage: false,      // 当前那张纸是否垫着锚定页（v10，工具条按钮激活态回显）
  padRenaming: -1,         // 列表里正在改名的是第几张（-1 = 没有；行内输入框）
  padDeleting: -1,         // 列表里正在等确认删除的是第几张（-1 = 没有；两步删，防误触）
  // ---- 参考窗（只读小窗，`../../REF-WINDOW-PLAN.md`）----
  // 🔴 **整组都是本端私有**：不落库、不上线（开着没有 / 看的哪本 / 滚到哪，都没有跨端真源可言）。
  // 位置与尺寸另存 localStorage，见 RefWindow.svelte。
  ref: false,              // 小窗开关
  refCollapsed: false,     // 折叠成气泡（展开保持滚动位置；关闭再开才回到进度）
  refDocId: "",            // 看的哪本（**库文档 id**，与 docs 的窗口会话 id 不是一个空间）
  refTitle: "",
  refPageCount: 0,
  refPages: [] as [number, number][],   // 页尺寸表（/docmeta 拉来）
  refSeedPage: 0,          // 那本书在库里的阅读进度（打开就定位到这儿）
  refSeedFrac: 0,
  refSeedRev: 0,           // 「打开 / 换书 / 回到进度」各 +1，组件据此重新定位
  refViewPage: 0,          // 当前视口顶端位置（折叠→展开靠它复位）
  refViewFrac: 0,
  refCurPage: 0,           // 标题栏那个页码
});

export function updatePageLabel(): void {
  S.pageLabel = G.pageCount ? (G.topVisiblePage() + 1) + " / " + G.pageCount : "— / —";
  S.curPage = G.pageCount ? G.topVisiblePage() : 0;   // 目录抽屉据此高亮/展开当前章节
}

// 笔的用途状态胶囊：笔记模式显示当前笔（色块/类型/粗细），其余模式显示模式名。
// 状态可来自本地侧键、Mac 悬浮工具条或环形选笔盘下发，统一在这里回显。
export function updatePenStat(): void {
  S.modeKey = curMode();
  const p = curPen();
  S.pen = p ? { color: p.color, w: p.w, t: p.t } : null;
}

// 图层胶囊/面板：G.LAYERS 是非响应式的命令式袋（Mac layers 广播落地处），这里镜像进 $state
// 让 LayerStat.svelte 能响应式重渲染——同 updatePenStat 的 G→S 拷贝惯例。
export function updateLayerStat(): void {
  S.layers = G.LAYERS.slice();
  S.layerIdx = G.layerIdx;
}

export function updateHud(): void {
  S.zoomLabel = Math.round(G.zoom * 100) + "%";
  updatePageLabel();
  updatePenStat();
  updateLayerStat();
}

// ---- 延迟统计（点击顶栏延迟数字展开面板）----
const rtts: number[] = [];

export function recordRtt(rtt: number): void {
  rtts.push(rtt);
  if (rtts.length > 40) rtts.shift();
}

export function startStats(): void {
  setInterval(() => {
    const n = rtts.length;
    let sum = 0, mn = 1e9, mx = 0, jit = 0;
    for (let i = 0; i < n; i++) {
      const r = rtts[i];
      sum += r;
      if (r < mn) mn = r;
      if (r > mx) mx = r;
      if (i > 0) jit += Math.abs(r - rtts[i - 1]);
    }
    const avg = n ? sum / n : 0;
    jit = n > 1 ? jit / (n - 1) : 0;
    if (!n) { mn = 0; mx = 0; }
    S.latText = n ? (Math.round(avg) + "±" + Math.round(jit) + " ms") : "— ms";
    /// 每帧均值，一位小数；没画过帧就显示 —
    const ms = (total: number): string => (G.drawN ? (total / G.drawN).toFixed(1) : "—") + "ms";
    if (S.statsOn) {
      S.statsText =
        "RTT  avg " + Math.round(avg) + " ms\n" +
        "     min " + Math.round(mn) + "  max " + Math.round(mx) + "\n" +
        "     jitter " + Math.round(jit) + " ms  (n=" + n + ")\n" +
        "↑ 上行  " + G.upCount + " msg/s\n" +
        "↓ 下行  " + G.downCount + " msg/s\n" +
        "画面 fps " + G.frames + "\n" +
        "绘制/帧 " + ms(G.drawBgMs) + " 页图  " + ms(G.drawInkMs) + " 笔迹  " + ms(G.drawRestMs) + " 其余";
    }
    G.upCount = 0; G.downCount = 0; G.frames = 0;
    G.drawN = 0; G.drawBgMs = 0; G.drawInkMs = 0; G.drawRestMs = 0;
  }, 1000);
}
