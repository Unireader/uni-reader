<script lang="ts">
  import { onMount, tick } from "svelte";
  import type { PDFDocumentLoadingTask, PDFDocumentProxy } from "pdfjs-dist";
  import { ApiError, bookNotes, documents, documentView, head, message, pageInfo, pdfURL, token, type DocumentInfo, type ServerOutline } from "./lib/api";
  import { parseAlign, toAligned, type AlignTable } from "./lib/align";
  import { Decor } from "./lib/decor";
  import { EditSession, type SaveState } from "./lib/edits";
  import { PageInput } from "./lib/input";
  import { css, DEFAULT_LAYER, parseMarks, parseNoteTypes, visibleStrokes, type TextNote } from "./lib/marks";
  import { MarkStore } from "./lib/markstore";
  import { loadTool, PENS, saveTool, type Tool } from "./lib/pens";
  import { uuid } from "./lib/uuid";
  import { narrow, setRail, ui } from "./lib/ui.svelte";
  import { go } from "./lib/nav";
  import { t } from "./lib/i18n";
  // pdf.js 只在「浏览器加载」时才用：单独成包、用到才下载（服务器出图时不下）
  import type { OutlineNode } from "./lib/pdf";
  const pdfLib = () => import("./lib/pdf");
  import { loadPosition, savePosition } from "./lib/position";
  import { MAX_ZOOM, MIN_ZOOM, Viewer } from "./lib/viewer";
  import { ImageSource, PdfSource, type PageSource } from "./lib/source";
  import Icon from "./Icon.svelte";
  import Outline from "./Outline.svelte";

  let { ws, doc }: { ws: string; doc: string } = $props();

  const POLL_MS = 5000;   // 多久问一次服务器「有没有别的设备改过」

  let scroller: HTMLDivElement;
  let viewer: Viewer | null = null;
  let pdf: PDFDocumentProxy | null = null;
  let task: PDFDocumentLoadingTask | null = null;
  let store: MarkStore | null = null;
  let align: AlignTable | null = null;
  let alignRaw = "";
  let lastHead = -1;
  let polling = false;
  let opened = 0;   // 每打开一次 +1：重新打开时，上一次还没做完的就作废
  const decor = new Decor();
  // W3：书写与文字笔记
  let edits: EditSession | null = null;
  let input: PageInput | null = null;
  const initialTool = loadTool();
  let tool = $state<Tool>(initialTool.tool);
  let penIndex = $state(initialTool.pen);
  let canUndo = $state(false);
  let canRedo = $state(false);
  let saveState = $state<SaveState>({ pending: 0, offline: false });
  let notice = $state("");
  let noticeTimer = 0;
  let info = $state<DocumentInfo | null>(null);
  let status = $state(t("Opening…"));
  let failed = $state(false);
  let page = $state(0);
  let count = $state(0);
  let zoom = $state(1);
  let outline = $state<OutlineNode[]>([]);
  // 左边的面板：目录 / 笔记（宽屏默认开着，窄屏默认收起；开关与选的标签记在本浏览器）
  const PANEL_KEY = "unireader.panel";
  const savedPanel = (() => {
    try { return JSON.parse(localStorage.getItem(PANEL_KEY) ?? "null") as { open?: boolean; tab?: string } | null; } catch { return null; }
  })();
  let panelOpen = $state(!narrow() && (savedPanel?.open ?? true));
  let panelTab = $state<"toc" | "notes">(savedPanel?.tab === "notes" ? "notes" : "toc");
  let notesList = $state<{ page: number; note: TextNote }[] | null>(null);
  // 页面由谁来画（方案 §11）：服务器画成图片（默认）/ 这个浏览器加载 PDF；选哪种记在本浏览器
  const MODE_KEY = "unireader.render";
  type RenderMode = "server" | "browser";
  let renderMode = $state<RenderMode>((() => {
    try { return localStorage.getItem(MODE_KEY) === "browser" ? "browser" : "server"; } catch { return "server"; }
  })());
  /** 这次实际用的（服务器画不了时退回浏览器） */
  let usedMode = $state<RenderMode>("server");
  let sizes: { w: number; h: number }[] | null = null;
  let notesTimer = 0;
  let pageText = $state("1");
  let editingPage = false;
  let saveTimer = 0;

  function save() {
    if (!viewer) return;
    const p = viewer.position();
    savePosition(ws, doc, { page: p.page, frac: p.frac, zoom: viewer.zoom });
  }

  function scheduleSave() {
    clearTimeout(saveTimer);
    saveTimer = window.setTimeout(save, 800);
  }

  function jump(e: SubmitEvent) {
    e.preventDefault();
    const n = parseInt(pageText, 10);
    if (Number.isFinite(n)) viewer?.goTo(n - 1);
    (document.activeElement as HTMLElement | null)?.blur();
  }

  function savePanel() {
    try { localStorage.setItem(PANEL_KEY, JSON.stringify({ open: panelOpen, tab: panelTab })); } catch { /* 无痕模式等 */ }
  }

  function togglePanel() {
    panelOpen = !panelOpen;
    savePanel();
  }

  function showTab(tab: "toc" | "notes") {
    panelTab = tab;
    savePanel();
    if (tab === "notes" && notesList === null) void loadNotes();
  }

  /** 整本书的文字笔记（「笔记」标签）。 */
  async function loadNotes() {
    try {
      const marks = parseMarks(await bookNotes(ws, doc));
      const out: { page: number; note: TextNote }[] = [];
      for (const [page, m] of [...marks.entries()].sort((a, b) => a[0] - b[0])) {
        for (const note of [...m.notes].sort((a, b) => a.anchor[1] - b.anchor[1])) out.push({ page, note });
      }
      notesList = out;
    } catch (e) {
      console.warn("笔记列表没取到", e);
    }
  }

  /** 网页自己改了笔记：等它存上再刷新列表。 */
  function notesChanged() {
    clearTimeout(notesTimer);
    notesTimer = window.setTimeout(() => { if (notesList !== null) void loadNotes(); }, 1500);
  }

  /** 列表里点一条笔记：翻到那儿、气泡打开。 */
  function openNote(page: number, n: TextNote) {
    if (!viewer) return;
    viewer.goTo(page, Math.max(0, n.anchor[1] - 0.06));
    decor.markOpen(n.id);
    viewer.refreshMarks([page]);
    if (narrow()) panelOpen = false;
  }

  async function pick(n: OutlineNode) {
    if (!viewer) return;
    // 服务器出图：目录项里已经有页和纵坐标；浏览器加载：让 pdf.js 解析
    const d = n.page !== undefined
      ? (n.page >= 0 && n.page < count
        ? { page: n.page, y: n.y ?? null, frac: n.y != null && sizes ? Math.min(1, Math.max(0, n.y / sizes[n.page].h)) : 0 }
        : null)
      : pdf ? await (await pdfLib()).resolveDest(pdf, n.dest) : null;
    if (d) {
      // 对齐开着时页面坐标是对齐后的：把目录落点的纵坐标也转过去
      const pa = align?.pages[d.page];
      const frac = pa && d.y !== null ? Math.min(1, Math.max(0, toAligned(pa, pa.sw / 2, d.y)[1] / pa.sh)) : d.frac;
      viewer.goTo(d.page, frac);
    }
    if (narrow()) panelOpen = false;
  }

  function setTool(next: Tool, pen?: number) {
    tool = next;
    if (pen !== undefined) penIndex = pen;
    saveTool(tool, penIndex);
    input?.toolChanged();
  }

  function syncUndo() {
    canUndo = edits?.canUndo ?? false;
    canRedo = edits?.canRedo ?? false;
  }

  function undo() { edits?.undo(); syncUndo(); }
  function redo() { edits?.redo(); syncUndo(); }

  function showNotice(text: string) {
    notice = text;
    clearTimeout(noticeTimer);
    noticeTimer = window.setTimeout(() => (notice = ""), 6000);
  }

  /** 点一下页面：在那儿开一个编辑框，保存了才新建（空的不建）。字段同 Mac 新建点笔记（`TextNotePayload`）。 */
  function newNote(page: number, nx: number, ny: number) {
    if (!viewer) return;
    decor.openEditor(viewer.pageDiv(page), null, nx, ny, (text) => {
      if (!text.trim() || !edits) return;
      const n: TextNote = {
        id: uuid(), anchor: [nx, ny, 0, 0], rects: [], quote: "", text, color: null, style: "fill", typeId: null,
        display: "tap", raw: { style: "fill", display: "tap" }, createdAt: "", updatedAt: "",
      };
      decor.markOpen(n.id);
      edits.saveNote(page, null, n);
      notesChanged();
    }, () => {});
  }

  function editNote(page: number, n: TextNote) {
    if (!viewer) return;
    decor.openEditor(viewer.pageDiv(page), n, 0, 0, (text) => {
      if (text === n.text || !edits) return;
      decor.markOpen(n.id);
      edits.saveNote(page, n, { ...n, text });
      notesChanged();
    }, () => {});
  }

  const typing = (e: Event) => !!(e.target as Element | null)?.closest?.("input, textarea, [contenteditable]");

  function onKey(e: KeyboardEvent) {
    if (!viewer || typing(e)) return;
    const mod = e.ctrlKey || e.metaKey;
    if (mod && !e.altKey) {
      const k = e.key.toLowerCase();
      if (k === "z" && !e.shiftKey) undo();
      else if ((k === "z" && e.shiftKey) || (k === "y" && e.ctrlKey)) redo();
      else if (e.key === "=" || e.key === "+") viewer.zoomBy(1.25);
      else if (e.key === "-") viewer.zoomBy(0.8);
      else if (e.key === "0") viewer.setZoom(1);
      else return;
      e.preventDefault();   // 不让浏览器把整个网页放大 / 撤销地址栏
      return;
    }
    if (mod || e.altKey) return;
    // 单键工具（同 Mac：v 翻页、b 书写、e 橡皮 ⇄ 书写、数字选笔）
    if (e.key === "v") setTool("none");
    else if (e.key === "b") setTool("pen");
    else if (e.key === "e") setTool(tool === "eraser" ? "pen" : "eraser");
    else if (/^[1-9]$/.test(e.key) && Number(e.key) <= PENS.length) setTool("pen", Number(e.key) - 1);
    else return;
    e.preventDefault();
  }

  function onBeforeUnload(e: BeforeUnloadEvent) {
    if (!edits?.pending) return;
    e.preventDefault();
    e.returnValue = t("Some changes are not saved to the server yet. Leave anyway?");
  }

  function switchMode() {
    renderMode = usedMode === "server" ? "browser" : "server";
    try { localStorage.setItem(MODE_KEY, renderMode); } catch { /* 无痕模式等 */ }
    save();
    close();
    status = t("Opening…");
    failed = false;
    void open();
  }

  const fromServer = (items: ServerOutline[]): OutlineNode[] =>
    items.map((o) => ({ title: o.title, dest: null, page: o.page, y: o.y, children: fromServer(o.children ?? []) }));

  function close() {
    input?.destroy();
    input = null;
    edits?.close();   // 还有没存上的就在后台接着发完
    edits = null;
    decor.actions = null;
    viewer?.destroy();
    viewer = null;
    store?.destroy();
    store = null;
    void task?.destroy();
    task = null;
    pdf = null;
  }

  async function open() {
    const me = ++opened;
    const alive = () => me === opened;
    try {
      lastHead = await head(ws);
      const d = (await documents(ws)).find((x) => x.id === doc);
      if (!alive()) return;
      if (!d) throw new Error(t("This book is not in the workspace."));
      info = d;
      if (!d.contentHash) throw new Error(t("The PDF of this book is not on the server yet."));
      const view = await documentView(ws, doc, d.contentHash);
      // 页面从哪来：默认服务器出图（各页尺寸 + 目录一次给齐，不加载 pdf.js）；服务器没装 MuPDF（501）就退回浏览器加载
      let source: PageSource | null = null;
      let serverOutline: OutlineNode[] | null = null;
      usedMode = renderMode;
      if (renderMode === "server") {
        try {
          const inf = await pageInfo(ws, d.contentHash);
          if (!alive()) return;
          const img = new ImageSource(ws, d.contentHash, inf.pages);
          if (img.count > 0) {
            source = img;
            serverOutline = fromServer(inf.outline ?? []);
          }
        } catch (e) {
          if (!(e instanceof ApiError) || e.status === 401) throw e;
          showNotice(e.status === 501
            ? t("The server cannot draw pages (MuPDF is not installed there). Loading the PDF in this browser instead.")
            : t("The server could not draw this book ({0}). Loading the PDF in this browser instead.", message(e)));
        }
      }
      if (!source) {
        usedMode = "browser";
        const lib = await pdfLib();
        if (!alive()) return;
        task = lib.openPDF(pdfURL(ws, d.contentHash), token() ?? "");
        let loaded: PDFDocumentProxy;
        try {
          loaded = await task.promise;
        } catch (e) {
          throw new Error(t("Cannot open this PDF: {0}", message(e)));
        }
        if (!alive()) return;
        pdf = loaded;
        source = new PdfSource(loaded);
      }
      const total = source.count;
      sizes = source.sizes;
      alignRaw = view.align ?? "";
      align = parseAlign(view.align, total);
      decor.layers = view.layers;
      decor.types = parseNoteTypes(view.noteTypes);
      // 本浏览器读到哪儿；没有就用服务器上的阅读进度（各设备同步的那份）
      const saved = loadPosition(ws, doc) ?? { page: d.readPage, frac: d.readFrac, zoom: 1 };
      const start = Math.min(Math.max(0, saved.page), total - 1);
      // 先按要打开的那一页估所有页的尺寸，真画到哪页再改（服务器出图 / 对齐开着时尺寸是现成的）
      const vp = await source.pageSize(start);
      if (!alive()) return;
      count = total;
      // 侧栏（目录 / 笔记）要等有了页数才显示：等它占好位置再建阅读区，页宽一次量准
      // （不然先按整个宽度要一遍图，侧栏一出来页变窄又按新宽度要一遍，白画一张）
      await tick();
      if (!alive()) return;
      const marks = new MarkStore(ws, doc, count, (pages) => viewer?.refreshMarks(pages));
      store = marks;
      viewer = new Viewer(scroller, source, { width: vp.w, height: vp.h }, {
        onPage: (i) => {
          page = i;
          if (!editingPage) pageText = String(i + 1);
          scheduleSave();
        },
        onZoom: (z) => {
          zoom = z;
          scheduleSave();
        },
        onRange: (lo, hi) => marks.want(lo, hi),
      }, saved.zoom, align, { decor, marks: (i) => marks.page(i) });
      zoom = viewer.zoom;
      const v = viewer;
      const session = new EditSession(ws, doc, marks, (pages, added) => {
        if (added) v.appendInk(added.page, added.stroke);
        else v.refreshMarks(pages);
        syncUndo();
      }, (st) => (saveState = st), (problem) => showNotice(problem === "stale"
        ? t("This was changed on another device in the meantime. Reloaded the latest version.")
        : t("The server did not accept this change. Reloaded the latest version.")));
      edits = session;
      input = new PageInput(scroller, v, {
        tool: () => tool,
        pen: () => PENS[penIndex],
        // 新的一笔写在第一个看得见的图层（一层都没有 = 默认层，Mac 打开时会补建）
        layerId: () => ((decor.layers.find((l) => l.visible) ?? decor.layers[0])?.id ?? DEFAULT_LAYER).toUpperCase(),
        visibleStrokes: (p) => {
          const m = marks.page(p);
          return m ? visibleStrokes(m.strokes, decor.layers) : [];
        },
        strokeDone: (p, s) => session.addStroke(p, s),
        eraseBegin: () => session.beginGroup(),
        erase: (p, ss) => session.eraseStrokes(p, ss),
        eraseEnd: () => {
          session.endGroup();
          syncUndo();
        },
        noteTap: (p, nx, ny) => newNote(p, nx, ny),
      });
      decor.actions = {
        edit: (p, n) => editNote(p, n),
        remove: (p, n) => {
          session.deleteNote(p, n);
          notesChanged();
        },
      };
      viewer.goTo(start, saved.frac);
      status = "";
      scroller.focus({ preventScroll: true });   // 方向键、翻页键直接滚
      if (panelOpen && panelTab === "notes") void loadNotes();
      outline = serverOutline ?? (pdf ? await (await pdfLib()).loadOutline(pdf) : []);
    } catch (e) {
      if (!alive()) return;
      failed = true;
      status = message(e);
    }
  }

  /** 别的设备改过这个工作区（修订号变了）：重取图层 / 笔记类型与看得见的几页的标记。对齐参数变了就整本重新打开。 */
  async function poll() {
    if (polling || !viewer || !store || !info?.contentHash || document.visibilityState !== "visible") return;
    polling = true;
    const me = opened;
    try {
      const h = await head(ws);
      if (h === lastHead || me !== opened) return;
      const view = await documentView(ws, doc, info.contentHash);
      if (me !== opened) return;
      lastHead = h;
      if ((view.align ?? "") !== alignRaw) {
        save();
        close();
        status = t("Opening…");
        void open();
        return;
      }
      const before = JSON.stringify([decor.layers, decor.types]);
      decor.layers = view.layers;
      decor.types = parseNoteTypes(view.noteTypes);
      if (JSON.stringify([decor.layers, decor.types]) !== before) viewer.refreshMarks();
      store.refresh();
      if (notesList !== null) void loadNotes();
    } catch (e) {
      console.warn("查服务器修订号没成功", e);
    } finally {
      polling = false;
    }
  }

  onMount(() => {
    void open();
    const timer = window.setInterval(() => void poll(), POLL_MS);
    const onVisibility = () => {
      if (document.visibilityState === "hidden") save();
      else void poll();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      clearTimeout(noticeTimer);
      clearTimeout(notesTimer);
      opened++;
      clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisibility);
      clearTimeout(saveTimer);
      save();
      close();
    };
  });
</script>

<svelte:window onkeydown={onKey} onbeforeunload={onBeforeUnload} />

<div class="reader">
  <header class="topbar">
    {#if !ui.rail}
      <button class="icon" onclick={() => setRail(true)} title={t("Show Sidebar")} aria-label={t("Show Sidebar")}><Icon name="sidebar" /></button>
    {/if}
    <button class="icon" onclick={() => go("w", ws)} title={t("Library")} aria-label={t("Library")}><Icon name="back" /></button>
    <button class="icon" class:on={panelOpen} onclick={togglePanel} disabled={!count}
            title={t("Contents and Notes")} aria-label={t("Contents and Notes")} aria-pressed={panelOpen}><Icon name="panel" /></button>
    <div class="title">{info?.title ?? ""}</div>
    {#if count}
      <button class="mode" onclick={switchMode} title={t("How pages are drawn: as images on the server, or from the PDF in this browser. Click to switch.")}>
        {usedMode === "server" ? t("Server Images") : t("In Browser")}
      </button>
      <form class="pageno" onsubmit={jump}>
        <input bind:value={pageText} inputmode="numeric" aria-label={t("Page")}
               onfocus={(e) => { editingPage = true; e.currentTarget.select(); }}
               onblur={() => { editingPage = false; pageText = String(page + 1); }} />
        <span>/ {count}</span>
      </form>
    {/if}
  </header>
  <div class="reader-body">
    {#if panelOpen && count}
      <aside class="side">
        <div class="tabs" role="tablist">
          <button role="tab" aria-selected={panelTab === "toc"} onclick={() => showTab("toc")}>
            <span class="mk" class:on={panelTab === "toc"}>{t("Contents")}</span>
          </button>
          <button role="tab" aria-selected={panelTab === "notes"} onclick={() => showTab("notes")}>
            <span class="mk" class:on={panelTab === "notes"}>{t("Notes")}</span>
            {#if notesList?.length}<span class="tab-count">{notesList.length}</span>{/if}
          </button>
        </div>
        <div class="side-body">
          {#if panelTab === "toc"}
            {#if outline.length}
              <Outline nodes={outline} onpick={pick} />
            {:else}
              <p class="side-empty">{t("This PDF has no contents.")}</p>
            {/if}
          {:else if notesList === null}
            <p class="side-empty">{t("Loading…")}</p>
          {:else if notesList.length === 0}
            <p class="side-empty">{t("No text notes in this book yet. Pick “Add Text Note” in the toolbar below and click on a page to write one.")}</p>
          {:else}
            <ul class="note-list">
              {#each notesList as { page: p, note: n } (n.id)}
                <li>
                  <button class="note-item" onclick={() => openNote(p, n)}>
                    <span class="note-page">{t("Page {0}", p + 1)}</span>
                    <span class="note-text" class:quote={!n.text}>{n.text || n.quote}</span>
                  </button>
                </li>
              {/each}
            </ul>
          {/if}
        </div>
      </aside>
    {/if}
    <div class="stage">
      <div class="scroller" class:inking={tool !== "none"} bind:this={scroller} tabindex="-1"></div>
      {#if count}
        <div class="dock" role="toolbar" aria-label={t("Write")}>
          <button class="tool" class:on={tool === "none"} onclick={() => setTool("none")}
                  title={`${t("Page Turn")} (V)`} aria-label={t("Page Turn")} aria-pressed={tool === "none"}><Icon name="pointer" /></button>
          {#each PENS as pen, i}
            <button class="tool" class:on={tool === "pen" && penIndex === i} onclick={() => setTool("pen", i)}
                    title={`${t("Write")} · ${t(pen.name)} (${i + 1})`} aria-label={`${t("Write")} · ${t(pen.name)}`}
                    aria-pressed={tool === "pen" && penIndex === i}>
              <span class="pen-dot" class:marker={pen.type === "marker"} style:background={css(pen.color, pen.type === "marker" ? 0.8 : 1)}></span>
            </button>
          {/each}
          <button class="tool" class:on={tool === "eraser"} onclick={() => setTool("eraser")}
                  title={`${t("Eraser")} (E)`} aria-label={t("Eraser")} aria-pressed={tool === "eraser"}><Icon name="eraser" /></button>
          <button class="tool" class:on={tool === "note"} onclick={() => setTool("note")}
                  title={t("Add Text Note")} aria-label={t("Add Text Note")} aria-pressed={tool === "note"}><Icon name="note" /></button>
          <span class="dock-sep"></span>
          <button class="tool" onclick={undo} disabled={!canUndo} title={`${t("Undo")} (⌘Z)`} aria-label={t("Undo")}><Icon name="undo" /></button>
          <button class="tool" onclick={redo} disabled={!canRedo} title={`${t("Redo")} (⇧⌘Z)`} aria-label={t("Redo")}><Icon name="redo" /></button>
          <span class="dock-sep"></span>
          <button class="tool" onclick={() => viewer?.zoomBy(0.8)} disabled={zoom <= MIN_ZOOM}
                  title={t("Zoom Out")} aria-label={t("Zoom Out")}><Icon name="minus" /></button>
          <button class="tool pct" onclick={() => viewer?.setZoom(1)} title={t("Fit Width")}>{Math.round(zoom * 100)}%</button>
          <button class="tool" onclick={() => viewer?.zoomBy(1.25)} disabled={zoom >= MAX_ZOOM}
                  title={t("Zoom In")} aria-label={t("Zoom In")}><Icon name="plus" /></button>
          {#if saveState.pending}
            <span class="save-state" class:warn={saveState.offline}
                  title={saveState.offline ? t("{0} changes not saved yet: cannot reach the server. Retrying…", saveState.pending) : t("Saving…")}>
              {saveState.offline ? t("{0} not saved", saveState.pending) : t("Saving…")}
            </span>
          {/if}
        </div>
      {/if}
      {#if notice}<div class="notice" role="status">{notice}</div>{/if}
      {#if status}
        <div class="overlay" class:error={failed}>
          <p>{status}</p>
          {#if failed}<button onclick={() => go("w", ws)}>{t("Back")}</button>{/if}
        </div>
      {/if}
    </div>
  </div>
</div>
