// 顶栏/键盘动作袋：startCapture() 装配时填充，Svelte 组件（TopBar 等）经这里调用。
// 组件只依赖这个空袋的形状，不依赖装配顺序（点击必然发生在 mount 之后）。
export const actions = {};
