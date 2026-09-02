<script lang="ts">
  // 左侧拉抽屉：「目录」= 当前文档的 PDF 目录（可折叠树，点条目跳到章节标题那一行）；
  // 「书库」= 工作区全部文档（含 Mac 还没打开的，点它让 Mac 新开一个窗口）。
  //
  // 目录数据是**先序拍平 + depth**（PROTOCOL.md §4.2），树结构在这里按 depth 就地重建：
  // 前一项 depth 更小者即父。这样线上不必编码嵌套，客户端也不必递归。
  import { untrack } from "svelte";
  import { S } from "./lib/hud.svelte.js";
  import { actions } from "./lib/actions.js";
  import { placeBookmarks } from "./lib/tocMerge.js";
  import Icon from "./Icon.svelte";

  let expanded = $state(new Set<number>());
  let listEl: HTMLDivElement | undefined = $state(undefined);
  let nameDraft = $state("");   // 新建/改名输入框里的字

  /// 目录归属核对：切档时 layout 与 toc 两条广播的先后没有保证，docId 对不上就不渲染
  /// （宁可空一瞬，也不能把上一本的目录挂到新书上）。书签同一口径。
  const tocReady = $derived(S.toc.length > 0 && S.tocDocId === S.docV);
  const bmReady = $derived(S.bookmarks.length > 0 && S.bookmarksDocId === S.docV);

  /// 一行：目录项（kind "toc"）或书签（kind "bm"）。`i` 只对目录行有意义（折叠态按它记）。
  interface Row {
    kind: "toc" | "bm";
    key: string;
    i: number;
    depth: number;
    page: number;
    frac: number;
    label: string;
    kids: boolean;
    parents: number[];
    id: string;      // 书签 id（目录行为 ""）
  }

  const tocRows: Row[] = $derived.by(() => {
    const t = tocReady ? S.toc : [], out: Row[] = [], stack: number[] = [];   // stack[d] = 深度 d 的最近一项下标
    for (let i = 0; i < t.length; i++) {
      const e = t[i];
      stack.length = e.depth;
      out.push({
        kind: "toc", key: "t" + i,
        i, depth: e.depth, page: e.page, frac: e.frac, label: e.label,
        kids: i + 1 < t.length && t[i + 1].depth > e.depth,
        parents: stack.slice().filter((p) => p !== undefined),
        id: "",
      });
      stack[e.depth] = i;
    }
    return out;
  });

  /// 目录 + 书签合并（规则在 `lib/tocMerge.ts`，与 Mac `TOCMerge.swift` / 安卓 `TocMerge.kt` 同源）。
  const rows: Row[] = $derived.by(() => {
    const base = tocRows;
    const bms = bmReady ? S.bookmarks : [];
    if (!bms.length) return base;
    const slots = placeBookmarks(base.map((r) => ({ depth: r.depth, page: r.page })), bms.map((b) => b.page));
    const ins = new Map<number, Row[]>();
    bms.forEach((b, k) => {
      const s = slots[k];
      const owner = s.owner >= 0 ? base[s.owner] : null;
      const row: Row = {
        kind: "bm", key: "b" + b.id,
        i: -1, depth: s.depth, page: b.page, frac: b.frac, label: b.title, kids: false,
        parents: owner ? owner.parents.concat([owner.i]) : [],
        id: b.id,
      };
      const arr = ins.get(s.insertBefore);
      if (arr) arr.push(row); else ins.set(s.insertBefore, [row]);
    });
    const out: Row[] = [];
    for (let i = 0; i < base.length; i++) {
      const pre = ins.get(i);
      if (pre) out.push(...pre);
      out.push(base[i]);
    }
    const tail = ins.get(base.length);
    if (tail) out.push(...tail);
    return out;
  });

  /// 当前章节：起点不晚于当前页的项里页码最大的那个，并列取先序靠后（更深一层）的。
  /// 不能简单取「最后一个 page <= curPage」——真实 PDF 的书签先序页码常常不单调（Mac 端
  /// TOCListView 同款注释：末尾挂着的坏书签会把高亮永远钉在最后一项）。
  /// **只认目录行**：它回答的是「我在第几章」，跳到书签行上没有意义（同 Mac）。
  const curIdx = $derived.by(() => {
    let best = -1, bestPage = -1;
    for (const r of rows) {
      if (r.kind !== "toc" || r.page < 0 || r.page > S.curPage) continue;
      if (r.page >= bestPage) { bestPage = r.page; best = r.i; }
    }
    return best;
  });

  const visible = $derived(rows.filter((r) => r.parents.every((p) => expanded.has(p))));

  // 自动追踪：展开当前章节的祖先链（只增展开，不动用户手动折叠的其它分支）。
  // untrack 读 expanded：否则这个 effect 依赖自己写的状态，会自激。
  $effect(() => {
    const i = curIdx;
    if (i < 0) return;
    const ps = rows[i]?.parents ?? [];
    const cur = untrack(() => expanded);
    if (!ps.length || ps.every((p) => cur.has(p))) return;
    const s = new Set(cur);
    for (const p of ps) s.add(p);
    expanded = s;
  });

  // 🔴 带书签的那些组自动展开一次：书签按页号挂进一级组，而一级组默认收着——不展开的话
  // 「加完书签在目录里找不到」（2026-09-02 用户在安卓上实测撞到，485 条目录的书，日志里
  // 收到了、docId 也对得上，纯粹是被折叠挡住）。三端同一处理。
  // 只在**书签集变了**时跑（依赖 bookmarks.length），之后用户手动折叠仍然收得住。
  $effect(() => {
    void S.bookmarks.length;
    const cur = untrack(() => expanded);
    const want: number[] = [];
    for (const r of untrack(() => rows)) if (r.kind === "bm") for (const p of r.parents) if (!cur.has(p)) want.push(p);
    if (!want.length) return;
    const s = new Set(cur);
    for (const p of want) s.add(p);
    expanded = s;
  });

  // 展开后把当前章节滚到视野中间（抽屉刚拉开时也滚一次）。
  $effect(() => {
    if (!S.drawer || S.drawerTab !== "toc" || curIdx < 0) return;
    void visible.length;   // 展开态变了要重滚（行可能刚插进来）
    const el = listEl?.querySelector('[data-cur="true"]');
    if (el) requestAnimationFrame(() => el.scrollIntoView({ block: "center" }));
  });

  function toggle(i: number): void {
    const s = new Set(expanded);
    if (s.has(i)) s.delete(i); else s.add(i);
    expanded = s;
  }
  function jump(r: Row): void {
    if (r.page < 0) return;          // 坏书签：跳不过去
    actions.gotoDest(r.page, r.frac);
    S.drawer = false;                // 跳完就收起，让出画布
  }
  /// 开始输入名字（新建 / 改名共用一个输入框）。名字必填，所以「加书签」天然分两步。
  function beginAdd(): void { S.bmRenaming = ""; S.bmAdding = true; nameDraft = ""; }
  function beginRename(r: Row): void { S.bmAdding = false; S.bmRenaming = r.id; nameDraft = r.label; }
  function cancelName(): void { S.bmAdding = false; S.bmRenaming = ""; nameDraft = ""; }
  /// 提交：只发请求，Mac 落库后以 bookmarks 全量回推为准（回推到了才收输入态，见 ws.ts）。
  function commitName(): void {
    const t = nameDraft.trim();
    if (!t) return;
    if (S.bmAdding) actions.bookmarkAdd(t);
    else if (S.bmRenaming) actions.bookmarkRename(S.bmRenaming, t);
    nameDraft = "";
  }
  function open(id: string): void {
    actions.openDoc(id);
    S.drawer = false;
  }
</script>

{#if S.drawer}
  <!-- 遮罩：点空白处关抽屉。写字时抽屉是关着的，不会挡笔。 -->
  <div
    id="drawerScrim"
    role="button"
    tabindex="-1"
    aria-label="关闭"
    onclick={() => (S.drawer = false)}
    onkeydown={(e) => { if (e.key === "Escape") S.drawer = false; }}
  ></div>
  <aside id="drawer">
    <div class="drawerTabs">
      <button class:on={S.drawerTab === "toc"} onclick={() => (S.drawerTab = "toc")}>
        <Icon name="list" /> 目录
      </button>
      <button class:on={S.drawerTab === "lib"} onclick={() => (S.drawerTab = "lib")}>
        <Icon name="book" /> 书库
      </button>
      <button class="drawerClose" title="关闭" onclick={() => (S.drawer = false)}><Icon name="x" /></button>
    </div>

    {#if S.drawerTab === "toc"}
      <div class="drawerBody" bind:this={listEl}>
        <!-- 加书签：落点 = 当前视口顶那一处（与 Mac 的 ⌘D 同口径）。名字必填 → 先出输入框。 -->
        <div class="bmAddBar">
          {#if S.bmAdding}
            <!-- svelte-ignore a11y_autofocus -->
            <input class="bmInput" placeholder="书签名字" bind:value={nameDraft} autofocus
              onkeydown={(e) => { if (e.key === "Enter") commitName(); if (e.key === "Escape") cancelName(); }} />
            <button class="bmOk" disabled={!nameDraft.trim()} onclick={commitName}>加</button>
            <button class="bmCancel" onclick={cancelName}>取消</button>
          {:else}
            <button class="bmAdd" onclick={beginAdd}><Icon name="bookmark" /> 添加书签</button>
          {/if}
        </div>
        {#if !tocReady && !bmReady}
          <p class="drawerEmpty">本文档没有目录</p>
        {:else}
          {#each visible as r (r.key)}
            <div class="tocRow" style="padding-left:{r.depth * 14}px"
              data-cur={r.kind === "toc" && r.i === curIdx}>
              {#if r.kind === "bm"}
                <span class="tocTwist bmDot"><Icon name="bookmark" /></span>
                {#if S.bmRenaming === r.id}
                  <!-- svelte-ignore a11y_autofocus -->
                  <input class="bmInput" bind:value={nameDraft} autofocus
                    onkeydown={(e) => { if (e.key === "Enter") commitName(); if (e.key === "Escape") cancelName(); }} />
                  <button class="bmOk" disabled={!nameDraft.trim()} onclick={commitName}>好</button>
                  <button class="bmCancel" onclick={cancelName}>取消</button>
                {:else}
                  <button class="tocLabel bmLabel" onclick={() => jump(r)}>
                    <span class="tocText">{r.label}</span>
                    <span class="tocPage">{r.page + 1}</span>
                  </button>
                  <button class="bmEdit" title="重命名" aria-label="重命名"
                    onclick={() => beginRename(r)}><Icon name="pencil" /></button>
                  <button class="bmDel" title="删除" aria-label="删除"
                    onclick={() => actions.bookmarkDelete(r.id)}><Icon name="x" /></button>
                {/if}
              {:else}
                {#if r.kids}
                  <button class="tocTwist" class:open={expanded.has(r.i)} onclick={() => toggle(r.i)}
                    aria-label="展开/折叠"><Icon name="chevron-right" /></button>
                {:else}
                  <span class="tocTwist"></span>
                {/if}
                <button class="tocLabel" class:cur={r.i === curIdx} class:dead={r.page < 0}
                  disabled={r.page < 0} onclick={() => jump(r)}>
                  <span class="tocText">{r.label || "—"}</span>
                  <!-- 坏书签留空而不是显示「1」：配合 disabled 表达「跳不过去」（同 Mac 端） -->
                  <span class="tocPage">{r.page >= 0 ? r.page + 1 : ""}</span>
                </button>
              {/if}
            </div>
          {/each}
        {/if}
      </div>
    {:else}
      <div class="drawerBody">
        {#if S.libraryWs}<p class="drawerWs">{S.libraryWs}</p>{/if}
        {#if !S.library.length}
          <p class="drawerEmpty">工作区里还没有文档</p>
        {:else}
          {#each S.library as d (d.id)}
            <button class="libRow" onclick={() => open(d.id)}>
              <Icon name="doc" />
              <span class="libTitle">{d.title}</span>
              {#if d.open}<span class="libBadge">已打开</span>{/if}
            </button>
          {/each}
        {/if}
      </div>
    {/if}
  </aside>
{/if}
