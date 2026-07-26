// HUD 响应式状态（Svelte 5 runes）+ 顶栏/状态胶囊/延迟统计的更新函数。
// 高频命令式逻辑仍走 shared.ts 的 G 袋；只有 HUD 绑定字段进 S（组件据此渲染）。
import { G, curMode, curPen } from "./shared.js";
import type { Pen } from "./shared.js";

export interface DocEntry {
  id: string;
  title: string;
}

/// 文字笔记编辑器的打开状态（低频 UI，放 runes；面板定位用打开瞬间的视口坐标）。
export interface NoteEditorState {
  id: string;                          // 笔记 id（新建时打开即生成）
  page: number; nx: number; ny: number; // 页内归一化锚点（与笔迹同系）
  x: number; y: number;                // 打开时的视口坐标（面板定位用）
  text: string;                        // 初始文本
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
  statsOn: false,          // 延迟统计面板开关
  statsText: "",
  night: false,            // 夜间模式（按钮图标回显）
  noteMode: false,         // 文字笔记模式（顶栏按钮激活态回显）
  rulerOn: false,          // 尺子模式（顶栏按钮激活态回显）
  noteEditor: null as NoteEditorState | null,   // 文字笔记编辑器（非 null = 打开中）
  showPage: true,          // 页面图显示（眼睛按钮回显）
  zoomLocked: false,       // 锁定缩放（锁按钮回显）
});

export function updatePageLabel(): void {
  S.pageLabel = G.pageCount ? (G.topVisiblePage() + 1) + " / " + G.pageCount : "— / —";
}

// 笔的用途状态胶囊：笔记模式显示当前笔（色块/类型/粗细），其余模式显示模式名。
// 状态可来自本地侧键、Mac 悬浮工具条或环形选笔盘下发，统一在这里回显。
export function updatePenStat(): void {
  S.modeKey = curMode();
  const p = curPen();
  S.pen = p ? { color: p.color, w: p.w, t: p.t } : null;
}

export function updateHud(): void {
  S.zoomLabel = Math.round(G.zoom * 100) + "%";
  updatePageLabel();
  updatePenStat();
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
    if (S.statsOn) {
      S.statsText =
        "RTT  avg " + Math.round(avg) + " ms\n" +
        "     min " + Math.round(mn) + "  max " + Math.round(mx) + "\n" +
        "     jitter " + Math.round(jit) + " ms  (n=" + n + ")\n" +
        "↑ 上行  " + G.upCount + " msg/s\n" +
        "↓ 下行  " + G.downCount + " msg/s\n" +
        "画面 fps " + G.frames;
    }
    G.upCount = 0; G.downCount = 0; G.frames = 0;
  }, 1000);
}
