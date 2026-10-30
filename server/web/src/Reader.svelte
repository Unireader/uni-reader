<script lang="ts">
  import { onMount } from "svelte";
  import type { PDFDocumentProxy } from "pdfjs-dist";
  import { documents, documentView, head, message, pdfURL, token, type DocumentInfo } from "./lib/api";
  import { parseAlign, toAligned, type AlignTable } from "./lib/align";
  import { Decor } from "./lib/decor";
  import { EditSession, type SaveState } from "./lib/edits";
  import { PageInput } from "./lib/input";
  import { css, DEFAULT_LAYER, parseNoteTypes, visibleStrokes, type TextNote } from "./lib/marks";
  import { MarkStore } from "./lib/markstore";
  import { loadTool, PENS, saveTool, type Tool } from "./lib/pens";
  import { uuid } from "./lib/uuid";
  import { go } from "./lib/nav";
  import { t } from "./lib/i18n";
  import { loadOutline, openPDF, resolveDest, type OutlineNode } from "./lib/pdf";
  import { loadPosition, savePosition } from "./lib/position";
  import { MAX_ZOOM, MIN_ZOOM, Viewer } from "./lib/viewer";
  import Icon from "./Icon.svelte";
  import Outline from "./Outline.svelte";

  let { ws, doc }: { ws: string; doc: string } = $props();

  const POLL_MS = 5000;   // 多久问一次服务器「有没有别的设备改过」

  let scroller: HTMLDivElement;
  let viewer: Viewer | null = null;
  let pdf: PDFDocumentProxy | null = null;
  let task: ReturnType<typeof openPDF> | null = null;
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
  let showOutline = $state(false);
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

  async function pick(n: OutlineNode) {
    if (!pdf || !viewer) return;
    const d = await resolveDest(pdf, n.dest);
    if (d) {
      // 对齐开着时页面坐标是对齐后的：把目录落点的纵坐标也转过去
      const pa = align?.pages[d.page];
      const frac = pa && d.y !== null ? Math.min(1, Math.max(0, toAligned(pa, pa.sw / 2, d.y)[1] / pa.sh)) : d.frac;
      viewer.goTo(d.page, frac);
    }
    if (matchMedia("(max-width: 700px)").matches) showOutline = false;
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
    }, () => {});
  }

  function editNote(page: number, n: TextNote) {
    if (!viewer) return;
    decor.openEditor(viewer.pageDiv(page), n, 0, 0, (text) => {
      if (text === n.text || !edits) return;
      decor.markOpen(n.id);
      edits.saveNote(page, n, { ...n, text });
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
      task = openPDF(pdfURL(ws, d.contentHash), token() ?? "");
      let loaded: PDFDocumentProxy;
      try {
        loaded = await task.promise;
      } catch (e) {
        throw new Error(t("Cannot open this PDF: {0}", message(e)));
      }
      if (!alive()) return;
      pdf = loaded;
      alignRaw = view.align ?? "";
      align = parseAlign(view.align, loaded.numPages);
      decor.layers = view.layers;
      decor.types = parseNoteTypes(view.noteTypes);
      // 本浏览器读到哪儿；没有就用服务器上的阅读进度（各设备同步的那份）
      const saved = loadPosition(ws, doc) ?? { page: d.readPage, frac: d.readFrac, zoom: 1 };
      const start = Math.min(Math.max(0, saved.page), loaded.numPages - 1);
      // 先按要打开的那一页估所有页的尺寸，真画到哪页再改（对齐开着时尺寸是现成的）
      const vp = (await loaded.getPage(start + 1)).getViewport({ scale: 1 });
      if (!alive()) return;
      count = loaded.numPages;
      const marks = new MarkStore(ws, doc, count, (pages) => viewer?.refreshMarks(pages));
      store = marks;
      viewer = new Viewer(scroller, loaded, { width: vp.width, height: vp.height }, {
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
        remove: (p, n) => session.deleteNote(p, n),
      };
      viewer.goTo(start, saved.frac);
      status = "";
      scroller.focus({ preventScroll: true });   // 方向键、翻页键直接滚
      outline = await loadOutline(loaded);
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
  <header class="bar">
    <button class="icon" onclick={() => go("w", ws)} title={t("Back")} aria-label={t("Back")}><Icon name="back" /></button>
    <button class="icon" class:on={showOutline} onclick={() => (showOutline = !showOutline)} disabled={!count}
            title={t("Contents")} aria-label={t("Contents")} aria-pressed={showOutline}><Icon name="list" /></button>
    <div class="title">{info?.title ?? ""}</div>
    {#if count}
      <form class="pageno" onsubmit={jump}>
        <input bind:value={pageText} inputmode="numeric" aria-label={t("Page")}
               onfocus={(e) => { editingPage = true; e.currentTarget.select(); }}
               onblur={() => { editingPage = false; pageText = String(page + 1); }} />
        <span>/ {count}</span>
      </form>
      <div class="zoom">
        <button class="icon" onclick={() => viewer?.zoomBy(0.8)} disabled={zoom <= MIN_ZOOM}
                title={t("Zoom Out")} aria-label={t("Zoom Out")}><Icon name="minus" /></button>
        <button class="text pct" onclick={() => viewer?.setZoom(1)} title={t("Fit Width")}>{Math.round(zoom * 100)}%</button>
        <button class="icon" onclick={() => viewer?.zoomBy(1.25)} disabled={zoom >= MAX_ZOOM}
                title={t("Zoom In")} aria-label={t("Zoom In")}><Icon name="plus" /></button>
      </div>
    {/if}
  </header>
  {#if count}
    <div class="bar tools" role="toolbar" aria-label={t("Write")}>
      <button class="icon" class:on={tool === "none"} onclick={() => setTool("none")}
              title={`${t("Page Turn")} (V)`} aria-label={t("Page Turn")} aria-pressed={tool === "none"}><Icon name="pointer" /></button>
      {#each PENS as pen, i}
        <button class="icon pen" class:on={tool === "pen" && penIndex === i} onclick={() => setTool("pen", i)}
                title={`${t("Write")} · ${t(pen.name)} (${i + 1})`} aria-label={`${t("Write")} · ${t(pen.name)}`}
                aria-pressed={tool === "pen" && penIndex === i}>
          <span class="pen-dot" class:marker={pen.type === "marker"} style:background={css(pen.color, pen.type === "marker" ? 0.75 : 1)}></span>
        </button>
      {/each}
      <button class="icon" class:on={tool === "eraser"} onclick={() => setTool("eraser")}
              title={`${t("Eraser")} (E)`} aria-label={t("Eraser")} aria-pressed={tool === "eraser"}><Icon name="eraser" /></button>
      <button class="icon" class:on={tool === "note"} onclick={() => setTool("note")}
              title={t("Add Text Note")} aria-label={t("Add Text Note")} aria-pressed={tool === "note"}><Icon name="note" /></button>
      <span class="sep"></span>
      <button class="icon" onclick={undo} disabled={!canUndo} title={t("Undo")} aria-label={t("Undo")}><Icon name="undo" /></button>
      <button class="icon" onclick={redo} disabled={!canRedo} title={t("Redo")} aria-label={t("Redo")}><Icon name="redo" /></button>
      <span class="save-state" class:warn={saveState.offline}>
        {#if saveState.offline && saveState.pending}
          {t("{0} changes not saved yet: cannot reach the server. Retrying…", saveState.pending)}
        {:else if saveState.pending}
          {t("Saving…")}
        {/if}
      </span>
    </div>
  {/if}
  <div class="reader-body">
    {#if showOutline}
      <aside class="outline-pane">
        {#if outline.length}
          <Outline nodes={outline} onpick={pick} />
        {:else}
          <p class="hint">{t("This PDF has no contents.")}</p>
        {/if}
      </aside>
    {/if}
    <div class="scroller" class:inking={tool !== "none"} bind:this={scroller} tabindex="-1"></div>
    {#if notice}<div class="notice" role="status">{notice}</div>{/if}
    {#if status}
      <div class="overlay" class:error={failed}>
        <p>{status}</p>
        {#if failed}<button onclick={() => go("w", ws)}>{t("Back")}</button>{/if}
      </div>
    {/if}
  </div>
</div>
