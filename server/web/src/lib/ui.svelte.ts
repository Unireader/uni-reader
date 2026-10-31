// 界面上几处共享的开关：工作区侧栏开没开。
// - 宽屏（≥ 760px）：侧栏占一栏，开关记在本浏览器；进阅读页时屏幕不够宽（< 1280px）就先收起，给页面让地方。
// - 窄屏：侧栏从左边拉出、盖在内容上，换页面就收起。

const KEY = "unireader.rail";

export const NARROW = 760;
const READER_ROOM = 1280;

function load(): boolean {
  try {
    const v = localStorage.getItem(KEY);
    if (v !== null) return v === "1";
  } catch { /* 无痕模式等 */ }
  return true;
}

export const ui = $state({ rail: typeof window !== "undefined" && window.innerWidth >= NARROW && load() });

export const narrow = () => window.innerWidth < NARROW;

export function setRail(open: boolean) {
  ui.rail = open;
  if (!narrow()) {
    try { localStorage.setItem(KEY, open ? "1" : "0"); } catch { /* 无痕模式等 */ }
  }
}

/** 进了一个页面：窄屏收起侧栏；进阅读页时宽度不够也先收起（不记，回书库时照记下的来）。 */
export function routeChanged(reading: boolean) {
  if (narrow()) ui.rail = false;
  else ui.rail = reading && window.innerWidth < READER_ROOM ? false : load();
}
