// 顶栏/键盘动作袋：startCapture() 装配时填充，Svelte 组件（TopBar 等）经这里调用。
// 组件只依赖这个空袋的形状，不依赖装配顺序（点击必然发生在 mount 之后）。
export interface Actions {
  turn(dir: "prev" | "next"): void;
  gotoPage(page: number): void;
  /// 目录跳转：0-based 页 + 页内纵向比例（章节标题常在页中部起，只跳页会落在上一节末尾）。
  gotoDest(page: number, frac: number): void;
  cycleMode(): void;
  cyclePen(): void;
  selectDoc(id: string): void;
  /// 打开工作区里的某个文档（库文档 id）。已打开的 Mac 会自己切过去，未打开的新开一个 Mac 窗口。
  openDoc(id: string): void;
  toggleDrawer(): void;
  toggleStats(): void;
  toggleNight(): void;
  toggleTextNote(): void;
  toggleRuler(): void;
  toggleEye(): void;
  toggleLock(): void;
  /// 双指滚动模式（防误触）：单指划动不平移，滚动/缩放一律双指。
  toggleTwoFinger(): void;
  toggleFull(): void;
  // ---- 草稿纸（v8）：开/关/新建只发请求，Mac 是「哪张纸开着」的唯一真源 ----
  openPad(i: number): void;
  closePad(): void;
  addPad(): void;
  togglePadList(): void;
  padRecenter(): void;
  padFit(): void;
  togglePadMini(): void;
  togglePadPaper(): void;
  setPadPaper(bg: string | null, pattern: string | null): void;
}

export const actions = {} as Actions;
