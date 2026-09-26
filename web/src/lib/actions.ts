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
  // ---- 书签（REQUIREMENTS.md §1.9）：三个都只发**请求**，Mac 是唯一真源，等 bookmarks 全量回推 ----
  /// 在当前视口顶处加一枚（id 本端生成 UUID）。名字空白不发。
  bookmarkAdd(title: string): void;
  bookmarkRename(id: string, title: string): void;
  bookmarkDelete(id: string): void;
  // ---- 编辑（撤销/重做 + 剪贴板；两者的真源都在 Mac，见 PROTOCOL.md `undo`/`clip`）----
  /// 撤销（redo=false）/ 重做。平板只发意图，不做乐观预览——等 Mac 把结果镜像回来。
  undo(redo: boolean): void;
  /// 剪切/复制：把当前框选选中集发给 Mac（它用真源复判命中），剪贴板落在 Mac 的系统剪贴板上。
  clipCopy(cut: boolean): void;
  /// 粘贴：落点 = 当前视口正中那一页那一处（平板没有鼠标指针可用）。
  clipPaste(): void;
  toggleDrawer(): void;
  toggleStats(): void;
  toggleNight(): void;
  toggleTextNote(): void;
  toggleRuler(): void;
  toggleEye(): void;
  toggleLock(): void;
  /// 锁定水平滚动：内容横向位置不再跟手改变（拖动/惯性只走纵向），缩放重锚不受影响。
  toggleHLock(): void;
  /// 双指滚动模式（防误触）：单指划动不平移，滚动/缩放一律双指。
  toggleTwoFinger(): void;
  /// 画板模式（页面两侧的空白也能写字）：只发请求，Mac 是唯一真源（逐文档记，见 PROTOCOL.md `canvas`）。
  toggleCanvas(): void;
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
  /// 页面底图开关（v10）：把当前这张纸锚定的那一页垫在纸下面。跟着纸走、跨端同步。
  togglePadPage(): void;
  /// 删掉第 i 张纸（连同纸上笔迹）。UI 上是两步确认，这里只发请求。
  deletePad(i: number): void;
  /// 改第 i 张纸的名字（空串 = 回到「草稿纸 N」兜底名）。
  renamePad(i: number, title: string): void;
  // ---- 画板笔记（v16，PROTOCOL.md §4.8）：都只发请求，Mac 开标签 / 落库后回推 boards ----
  toggleBoardList(): void;
  /// 请 Mac 在它跟随的窗口里打开这篇画板。
  openBoard(id: string): void;
  /// 请 Mac 新建一篇画板并打开。
  addBoard(): void;
  /// 改当前画板的名字（走 scratchRename index=0，画板在会话里就是那张纸）。
  renameBoard(title: string): void;
}

export const actions = {} as Actions;
