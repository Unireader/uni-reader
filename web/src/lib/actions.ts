// 顶栏/键盘动作袋：startCapture() 装配时填充，Svelte 组件（TopBar 等）经这里调用。
// 组件只依赖这个空袋的形状，不依赖装配顺序（点击必然发生在 mount 之后）。
export interface Actions {
  turn(dir: "prev" | "next"): void;
  cycleMode(): void;
  cyclePen(): void;
  selectDoc(id: string): void;
  toggleStats(): void;
  toggleNight(): void;
  toggleTextNote(): void;
  toggleEye(): void;
  toggleLock(): void;
  toggleFull(): void;
}

export const actions = {} as Actions;
