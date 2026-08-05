<script lang="ts">
  // 左侧拉抽屉：「目录」= 当前文档的 PDF 目录（可折叠树，点条目跳到章节标题那一行）；
  // 「书库」= 工作区全部文档（含 Mac 还没打开的，点它让 Mac 新开一个窗口）。
  //
  // 目录数据是**先序拍平 + depth**（PROTOCOL.md §4.2），树结构在这里按 depth 就地重建：
  // 前一项 depth 更小者即父。这样线上不必编码嵌套，客户端也不必递归。
  import { untrack } from "svelte";
  import { S } from "./lib/hud.svelte.js";
  import { actions } from "./lib/actions.js";
  import Icon from "./Icon.svelte";

  let expanded = $state(new Set<number>());
  let listEl: HTMLDivElement | undefined = $state(undefined);

  /// 目录归属核对：切档时 layout 与 toc 两条广播的先后没有保证，docId 对不上就不渲染
  /// （宁可空一瞬，也不能把上一本的目录挂到新书上）。
  const tocReady = $derived(S.toc.length > 0 && S.tocDocId === S.docV);

  interface Row { i: number; depth: number; page: number; frac: number; label: string; kids: boolean; parents: number[] }

  const rows: Row[] = $derived.by(() => {
    const t = S.toc, out: Row[] = [], stack: number[] = [];   // stack[d] = 深度 d 的最近一项下标
    for (let i = 0; i < t.length; i++) {
      const e = t[i];
      stack.length = e.depth;
      out.push({
        i, depth: e.depth, page: e.page, frac: e.frac, label: e.label,
        kids: i + 1 < t.length && t[i + 1].depth > e.depth,
        parents: stack.slice().filter((p) => p !== undefined),
      });
      stack[e.depth] = i;
    }
    return out;
  });

  /// 当前章节：起点不晚于当前页的项里页码最大的那个，并列取先序靠后（更深一层）的。
  /// 不能简单取「最后一个 page <= curPage」——真实 PDF 的书签先序页码常常不单调（Mac 端
  /// TOCListView 同款注释：末尾挂着的坏书签会把高亮永远钉在最后一项）。
  const curIdx = $derived.by(() => {
    let best = -1, bestPage = -1;
    for (const r of rows) {
      if (r.page < 0 || r.page > S.curPage) continue;
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
        {#if !tocReady}
          <p class="drawerEmpty">本文档没有目录</p>
        {:else}
          {#each visible as r (r.i)}
            <div class="tocRow" style="padding-left:{r.depth * 14}px" data-cur={r.i === curIdx}>
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
