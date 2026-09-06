// UniReader 发送适配器 —— 把一张图（和一段提示词）塞进 AI 网页版的输入框。
//
// 🔴 三条设计约束，都踩过或推演过（见 AI-PLAN.md §3）：
//  ① **不走系统级模拟 ⌘V**：CGEvent 全局注入要辅助功能授权，而且焦点不在输入框就粘到别处去了。
//  ② **不用 fetch(dataURL) 造 Blob**：站点 CSP 的 connect-src 会挡。这里手工 atob → Uint8Array → File，
//     全程不发任何请求。（注入脚本本身不受站点 CSP 约束，但页面内的 fetch 受。）
//  ③ **必须跑在 page world**（Swift 侧 contentWorld: .page）：在 isolated world 里造的 File/DataTransfer，
//     页面的 React 处理器拿不到。
//
// 三级回退：file input → 合成 drop → 合成 paste。**每一级都要验证**——光"派发了事件"不等于站点收下了，
// 所以每次尝试后等一下，看有没有冒出预览缩略图或带文件名的附件条，没有就退下一级。
//
// 这个文件同时被 `spike/ai-adapter-test.html` 直接 <script src> 引用（单一真源，勿复制）：
// 站点改版坏了的时候，先跑那个自检页 —— 三条链路各出一个 PASS/FAIL，一分钟就能分清
// 是脚本坏了还是站点变了。
(function () {
  'use strict';
  if (window.__unireader) return;

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ── base64 → File（不经 fetch，见约束②）
  function b64ToFile(b64, name, mime) {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new File([bytes], name, { type: mime, lastModified: 0 });
  }

  function transferOf(file) {
    const dt = new DataTransfer();
    dt.items.add(file);
    return dt;
  }

  function isVisible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const st = getComputedStyle(el);
    return st.visibility !== 'hidden' && st.display !== 'none';
  }

  // ── 输入框：可见的 textarea / contenteditable / role=textbox 里面积最大的那个。
  // 面积最大这条经验规则比任何选择器都稳 —— 各家的 class 名每周都在变，"最大的那个输入框
  // 就是主输入框"却一直成立。
  function findEditor() {
    const cands = [...document.querySelectorAll(
      'textarea, div[contenteditable="true"], [contenteditable="true"], [role="textbox"]')];
    let best = null, bestArea = 0;
    for (const el of cands) {
      if (!isVisible(el) || el.disabled || el.readOnly) continue;
      const r = el.getBoundingClientRect();
      const area = r.width * r.height;
      if (area > bestArea) { best = el; bestArea = area; }
    }
    return best;
  }

  // file input 通常是隐藏的（点"+"才触发），所以**不能**按可见性筛。取最后一个未禁用的：
  // 后挂载的一般就是当前 composer 的那个。
  function findFileInput() {
    const list = [...document.querySelectorAll('input[type=file]')].filter((el) => !el.disabled);
    return list.length ? list[list.length - 1] : null;
  }

  // 拖放目标候选：输入框自己 → 它往上数几层容器（drop 处理器多半挂在 composer 外壳上）→ body。
  function dropTargets(editor) {
    const out = [];
    let el = editor;
    for (let i = 0; el && i < 5; i++) { out.push(el); el = el.parentElement; }
    if (document.body) out.push(document.body);
    return out.filter(Boolean);
  }

  // ── 验证：站点收下附件后，要么冒出 blob:/data: 预览缩略图，要么出现一条带文件名的附件条。
  // 两种样式都覆盖，所以文件名要取一个页面上不可能自然出现的串（Swift 侧保证）。
  function evidence(name) {
    const imgs = document.querySelectorAll('img[src^="blob:"], img[src^="data:image"]').length;
    const named = name && document.body ? (document.body.innerText || '').includes(name) : false;
    return { imgs, named };
  }

  async function verified(before, name, waitMs) {
    const deadline = Date.now() + (waitMs || 1500);
    while (Date.now() < deadline) {
      await sleep(120);
      const now = evidence(name);
      if (now.named && !before.named) return true;
      if (now.imgs > before.imgs) return true;
    }
    return false;
  }

  // ── 三级策略
  function viaFileInput(file) {
    const input = findFileInput();
    if (!input) return false;
    input.files = transferOf(file).files;
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.dispatchEvent(new Event('change', { bubbles: true }));
    return true;
  }

  function viaDrop(file, editor) {
    let sent = false;
    for (const target of dropTargets(editor)) {
      const dt = transferOf(file);
      const opts = { bubbles: true, cancelable: true, composed: true, dataTransfer: dt };
      target.dispatchEvent(new DragEvent('dragenter', opts));
      target.dispatchEvent(new DragEvent('dragover', opts));
      target.dispatchEvent(new DragEvent('drop', opts));
      sent = true;
    }
    return sent;
  }

  function viaPaste(file, editor) {
    const target = editor || document.body;
    if (!target) return false;
    if (target.focus) target.focus();
    const dt = transferOf(file);
    target.dispatchEvent(new ClipboardEvent('paste', {
      bubbles: true, cancelable: true, composed: true, clipboardData: dt,
    }));
    return true;
  }

  // ── 提示词：textarea 是 React 受控组件，直接改 .value 无效（React 记着上一个值，
  // 派发 input 时会认为没变），必须走原型上的原生 setter 再派发。contenteditable 走 execCommand。
  function insertText(text) {
    const el = findEditor();
    if (!el || !text) return false;
    el.focus();
    const tag = el.tagName;
    if (tag === 'TEXTAREA' || tag === 'INPUT') {
      const proto = tag === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      const joined = el.value ? el.value.replace(/\s+$/, '') + '\n' + text : text;
      setter.call(el, joined);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      try {
        el.setSelectionRange(joined.length, joined.length);
      } catch (e) { /* 有的实现不支持，忽略 */ }
      return true;
    }
    document.execCommand('insertText', false, text);
    return true;
  }

  // ── 「模式」分段控件（DeepSeek 新对话页：快速模式 / 专家模式 / 识图模式）
  //
  // 🔴 **只按可见文字整段相等来认**，不猜 class 名（class 每周都在变；可见文字变了用户一眼看得出来，
  // 改外部配置即可）。认不出就什么都不做 —— 这条控件**只在新对话页存在**，聊起来之后它就没了，
  // 那时找不到是正常的，正好等于「只在新建对话时切一次」这条规则，不必另记状态。
  function modeNode(labels) {
    const want = (labels || []).map((s) => String(s).trim()).filter(Boolean);
    if (!want.length) return null;
    let best = null;
    for (const el of document.querySelectorAll(
      'button, a, li, span, div, [role="button"], [role="tab"], [role="radio"]')) {
      if (!isVisible(el)) continue;
      const t = (el.innerText || '').replace(/\s+/g, ' ').trim();
      if (want.indexOf(t) < 0) continue;
      // 取**最深**的那个（文字所在的那一层）：点它，事件照样冒泡到挂着 onClick 的祖先，
      // 而点祖先有可能命中整条控件的空白处。
      if (!best || best.contains(el)) best = el;
    }
    return best;
  }

  // 选没选中：各家没有统一写法，这里只是**尽力判断**（aria 优先，再看 class 里的常见词）。
  // 判不出就返回 null —— 报给原生侧当诊断信息，**不拿它当失败依据**。
  function selectedish(el) {
    for (let e = el, i = 0; e && i < 4; e = e.parentElement, i++) {
      const sel = e.getAttribute && (e.getAttribute('aria-selected') || e.getAttribute('aria-checked'));
      if (sel === 'true') return true;
      if (sel === 'false') return false;
      const cls = (e.className && e.className.baseVal !== undefined ? e.className.baseVal : e.className) || '';
      if (typeof cls === 'string' && /(^|[-_ ])(active|selected|checked|current)([-_ ]|$)/i.test(cls)) return true;
    }
    return null;
  }

  // ── 选区回传
  //
  // 为什么必须自己推：SwiftUI 的 `.webViewContextMenu` 给的 `ActivatedElementInfo` **只有 linkURL**，
  // 拿不到选中文字（已核 SDK swiftinterface）。所以这里监听选区变化，经 messageHandler 推给原生侧，
  // 原生那边把最后一次选区记着，右键菜单项直接用。
  let lastSent = null;
  function reportSelection() {
    let text = '';
    try { text = String(window.getSelection ? window.getSelection() : ''); } catch (e) { return; }
    text = text.replace(/\u00a0/g, ' ').trim();
    if (text === lastSent) return;
    lastSent = text;
    try {
      const mh = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.unireader;
      if (mh) mh.postMessage({ type: 'selection', text: text.slice(0, 20000) });
    } catch (e) { /* 没注册 handler（比如自检页）就当没这回事 */ }
  }

  let selTimer = null;
  function scheduleReport(delay) {
    clearTimeout(selTimer);
    selTimer = setTimeout(reportSelection, delay);
  }
  // selectionchange 在拖选过程中会疯狂触发 → 节流；mouseup/keyup 再补一次确保落定。
  document.addEventListener('selectionchange', () => scheduleReport(150), true);
  document.addEventListener('mouseup', () => scheduleReport(0), true);
  document.addEventListener('keyup', () => scheduleReport(200), true);

  const ORDER = ['input', 'drop', 'paste'];

  window.__unireader = {
    version: 1,

    /// 把图塞进输入框。返回 {ok, method, tried, textOK, editor}。
    /// **不自动发送**（默认关，见 AI-PLAN.md §3）：填好让用户自己按发送键——对 ToS 友好，
    /// 也避免被 Cloudflare 判成 bot。
    async attach(b64, name, mime, text, order) {
      const file = b64ToFile(b64, name, mime || 'image/jpeg');
      const editor = findEditor();
      const seq = Array.isArray(order) && order.length ? order : ORDER;
      const tried = [];
      let method = null;

      for (const step of seq) {
        const before = evidence(name);
        let fired = false;
        try {
          if (step === 'input') fired = viaFileInput(file);
          else if (step === 'drop') fired = viaDrop(file, editor);
          else if (step === 'paste') fired = viaPaste(file, editor);
        } catch (e) {
          tried.push(step + ':err(' + (e && e.message ? e.message : e) + ')');
          continue;
        }
        if (!fired) { tried.push(step + ':n/a'); continue; }
        const ok = await verified(before, name, 1500);
        tried.push(step + (ok ? ':ok' : ':no-evidence'));
        if (ok) { method = step; break; }
      }

      const textOK = text ? insertText(text) : false;
      // 聚焦输入框但**不抢窗口焦点**（JS focus 只在页面内生效，用户还在读书）。
      if (editor && editor.focus) editor.focus();

      return {
        ok: method !== null,
        method: method,
        tried: tried.join(', '),
        textOK: textOK,
        editor: editor ? (editor.tagName + (editor.id ? '#' + editor.id : '')) : null,
      };
    },

    /// 这个页面**能不能收东西**了：适配器已注入（能调到这个函数就说明已注入）+ 主输入框已经在 DOM 里。
    /// 原生侧「等页面就绪再投递」的唯一判据（`AIPanelModel.waitUntilReady`）——首次打开面板时
    /// webview 还在拉首屏，此刻注入必然扑空；登录页上也永远返回 false（那儿没有输入框）。
    ready() {
        return !!findEditor();
    },

    /// 切「模式」。`labels` = 原生侧给的可见文字候选（见 `AIMode.labels`）。
    /// 返回 `{found}`：**没找到不算错**——聊到一半那条控件本来就不在了（见 `modeNode` 的注释）。
    /// `selected` 只是尽力而为的诊断信息，判不出为 null。
    async setMode(labels) {
        const el = modeNode(labels);
        if (!el) return { found: false, clicked: false, selected: null };
        if (selectedish(el) === true) return { found: true, clicked: false, selected: true };
        el.click();
        await sleep(200);
        const after = modeNode(labels);
        return { found: true, clicked: true, selected: after ? selectedish(after) : null };
    },

    /// 只填一段文字、不带附件（划字发送）。同样**不自动发送**——填好让用户自己按发送键。
    insert(text) {
        const ok = insertText(text);
        const el = findEditor();
        if (el && el.focus) el.focus();   // 只在页面内聚焦，不抢窗口焦点（用户还在读书）
        return ok;
    },

    /// 让原生侧主动问一次当前选区（右键菜单弹出前兜底：万一某次事件没捕到）。
    selection() {
      try { return String(window.getSelection ? window.getSelection() : '').trim(); } catch (e) { return ''; }
    },

    /// 自检 / 排障用：这个页面上我们认得出哪些东西。
    probe() {
      const editor = findEditor();
      const input = findFileInput();
      return {
        version: 1,
        editor: editor ? editor.tagName : null,
        editorArea: editor ? Math.round(editor.getBoundingClientRect().width
                                        * editor.getBoundingClientRect().height) : 0,
        fileInputs: document.querySelectorAll('input[type=file]').length,
        hasUsableFileInput: !!input,
        blobImages: evidence('').imgs,
      };
    },
  };
})();
