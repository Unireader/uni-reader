// 界面文字：英文原文当键，中文环境下查表（与 Mac App 的 Localizable.strings 同一个做法、同一套用词）。

const zh = (typeof navigator === "undefined" ? "" : navigator.language || "").toLowerCase().startsWith("zh");

export const lang = zh ? "zh-Hans" : "en";

const ZH: Record<string, string> = {
  "Pair": "配对",
  "Pairing…": "正在配对…",
  "Pairing Code": "配对码",
  "Device Name": "设备名",
  "Connect this browser to the UniReader server. Run `unireader-server pairing-code` on the server to see the code (it is the same code the Mac and Android apps use).":
    "把这个浏览器连到 UniReader 服务器。配对码在服务器上运行 `unireader-server pairing-code` 查看（与 Mac、安卓 App 配对用的是同一个码）。",
  "Wrong pairing code.": "配对码不对。",
  "Too many wrong codes. Try again in a minute.": "配对码试错太多，一分钟后再试。",
  "Cannot reach the server.": "连不上服务器。",
  "This browser's pairing is no longer valid (the device may have been revoked). Pair again.":
    "这个浏览器的配对已经失效（设备可能被吊销了），请重新配对。",
  "This page is open over plain HTTP: the pairing code, the token and your notes can be seen by others on the same network. Use HTTPS when connecting from outside your home network.":
    "当前是明文 HTTP 连接：配对码、令牌和笔记内容同一网络里的人都可能看到。在家庭网络以外访问请用 HTTPS。",
  "Workspaces": "工作区",
  "Sign Out": "退出",
  "Sign out of this server in this browser? You will need the pairing code to connect again.":
    "在这个浏览器里退出这台服务器？之后要用配对码重新配对。",
  "No workspaces on the server yet. Upload one from UniReader on the Mac.": "服务器上还没有工作区。可以在 Mac 的 UniReader 里把工作区上传到服务器。",
  "Loading…": "正在载入…",
  "Retry": "重试",
  "Back": "返回",
  "Filter": "筛选",
  "Ungrouped": "未分组",
  "{0} pages": "{0} 页",
  "PDF not on the server": "服务器上没有 PDF",
  "No books in this workspace.": "这个工作区里没有书。",
  "No matching books.": "没有符合的书。",
  "Opening…": "正在打开…",
  "This book is not in the workspace.": "这个工作区里没有这本书。",
  "The PDF of this book is not on the server yet.": "这本书的 PDF 还没有传到服务器上。",
  "Cannot open this PDF: {0}": "打不开这份 PDF：{0}",
  "Contents": "目录",
  "Text Note": "文字笔记",
  "This PDF has no contents.": "这份 PDF 没有目录。",
  "Page": "页码",
  "Zoom Out": "缩小",
  "Zoom In": "放大",
  "Fit Width": "适合宽度",
  "Web": "网页",
  // W3：书写与文字笔记（用词同 Mac App 的 Localizable.strings）
  "Page Turn": "翻页",
  "Write": "书写",
  "Eraser": "橡皮",
  "Add Text Note": "添加文字笔记",
  "Undo": "撤销",
  "Redo": "重做",
  "Edit": "编辑",
  "Delete": "删除",
  "Confirm Delete": "确认删除",
  "Save": "保存",
  "Cancel": "取消",
  "Blue": "蓝色",
  "Red": "红色",
  "Black": "黑色",
  "Highlighter": "荧光笔",
  "Saving…": "正在保存…",
  "{0} changes not saved yet: cannot reach the server. Retrying…": "有 {0} 处改动还没存上：连不上服务器，正在重试…",
  "This was changed on another device in the meantime. Reloaded the latest version.": "这期间别的设备改过这里，已重新载入最新的内容。",
  "The server did not accept this change. Reloaded the latest version.": "服务器没有收下这处改动，已重新载入最新的内容。",
  "Some changes are not saved to the server yet. Leave anyway?": "还有改动没存到服务器上，确定离开？",
  // 应用外壳与书库
  "Server": "服务器",
  "Hide Sidebar": "收起侧栏",
  "Show Sidebar": "显示侧栏",
  "Pick a workspace on the left.": "从左边选一个工作区。",
  "{0} books": "{0} 本书",
  "Filter books": "筛选书名",
  "Continue Reading": "继续阅读",
  "Page {0} of {1}": "第 {0} 页，共 {1} 页",
  "Library": "书库",
  "Contents and Notes": "目录与笔记",
  "Notes": "笔记",
  "No text notes in this book yet. Pick “Add Text Note” in the toolbar below and click on a page to write one.":
    "这本书还没有文字笔记。在下面的工具条里选「添加文字笔记」，再点一下页面就能写。",
  "Page {0}": "第 {0} 页",
  "{0} not saved": "{0} 处没存上",
  // 页面由谁来画（方案 §11）
  "Server Images": "服务器出图",
  "In Browser": "浏览器加载",
  "How pages are drawn: as images on the server, or from the PDF in this browser. Click to switch.":
    "页面由谁来画：服务器画成图片发过来，或者在这个浏览器里加载 PDF。点一下切换。",
  "The server cannot draw pages (MuPDF is not installed there). Loading the PDF in this browser instead.":
    "服务器画不了页面（没装 MuPDF），改用这个浏览器加载 PDF。",
  "The server could not draw this book ({0}). Loading the PDF in this browser instead.":
    "服务器没能画这本书（{0}），改用这个浏览器加载 PDF。",
};

/** 取一句界面文字；`{0}`、`{1}` 换成参数。 */
export function t(key: string, ...args: (string | number)[]): string {
  let s = zh ? (ZH[key] ?? key) : key;
  args.forEach((a, i) => (s = s.replace(`{${i}}`, String(a))));
  return s;
}
