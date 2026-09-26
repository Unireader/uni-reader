<script lang="ts">
  // 草稿纸的工具条与列表（入口按钮在顶栏，见 TopBar.svelte）：
  //  · 开着纸时 = 一条工具条（纸名 / 回中 / 适应内容 / minimap / 关闭），压在草稿纸画布之上；
  //  · 列表弹层 = 切换已有的纸 + 新建（顶栏按钮和工具条最左的图标都能开）。
  // 开/关/新建都只是发请求，Mac 是「哪张纸开着」的唯一真源（见 PROTOCOL.md §4.4）。
  //
  // ⚠️ 样式一律写在 web/src/app.css，**不要在这里加 <style> 块**：本组件曾是全项目唯一自带
  // scoped style 的组件，而 Svelte 5 对带 `class:` 指令的元素会漏掉作用域类
  // （生成 `#id.svelte-xxxx{...}` 规则，元素上却没有那个类）→ 样式整块失效、按钮退回
  // position:static 被 z-index 1~7 的 canvas 盖死，界面上彻底看不见。别再走一遍。
  import { S } from "./lib/hud.svelte.js";
  import { actions } from "./lib/actions.js";
  import Icon from "./Icon.svelte";

  const name = (p: { title: string; index: number }) => p.title || "草稿纸 " + (p.index + 1);
  /// 画板名：取 boards 列表里已兜底的显示名（纸那边的 title 可能是空串）。
  const boardName = () => S.boards.find((b) => b.id === S.boardCurrent)?.title || "未命名画板";

  /// 行内改名的草稿（只在「正在改名的那一行」有意义；提交/取消后由 S.padRenaming 归位）。
  let draft = $state("");
  function startRename(p: { title: string; index: number }): void {
    draft = p.title;
    S.padDeleting = -1;
    S.padRenaming = p.index;
  }

  // 纸样备选（与 Mac 端 ScratchPattern / ScratchPad.paperPalette 同一组，改一边要同步另一边）。
  const PATTERNS = [
    { key: "plain", label: "纯色" },
    { key: "dots", label: "点阵" },
    { key: "grid", label: "小格" },
  ];
  const PAPERS = [
    { key: "white", css: "rgba(255,255,255,1.0)" },
    { key: "cream", css: "rgba(252,247,235,1.0)" },
    { key: "gray",  css: "rgba(241,242,245,1.0)" },
    { key: "kraft", css: "rgba(246,236,214,1.0)" },
    { key: "green", css: "rgba(233,243,234,1.0)" },
    { key: "blue",  css: "rgba(234,241,250,1.0)" },
  ];
  // —— 分页画板（v17）：背景模板（线上 u8，与 Mac `BoardTemplate` 同序）与页面大小预设（画布 px，竖版）——
  const TEMPLATES = [
    { code: 0, label: "空白" }, { code: 1, label: "横线" }, { code: 2, label: "方格" },
    { code: 3, label: "点阵" }, { code: 4, label: "康奈尔" }, { code: 5, label: "两栏" },
  ];
  const SIZES = [
    { key: "a4", label: "A4", w: 595, h: 842 },
    { key: "a5", label: "A5", w: 420, h: 595 },
    { key: "letter", label: "Letter", w: 612, h: 792 },
    { key: "screen", label: "当前屏幕", w: 0, h: 0 },
  ];
  let nPaged = $state(false), nSize = $state("a4"), nLand = $state(false), nTpl = $state(1), nCount = $state(1);
  function createBoard(): void {
    if (!nPaged) { actions.addBoard(); return; }
    const sz = SIZES.find((s) => s.key === nSize) || SIZES[0];
    // 当前屏幕 = 这台平板的逻辑尺寸（竖版取短边为宽）
    let w = sz.w, h = sz.h;
    if (sz.key === "screen") { w = Math.min(screen.width, screen.height); h = Math.max(screen.width, screen.height); }
    if (nLand) { const t = w; w = h; h = t; }
    actions.addBoard({ w, h, template: nTpl, count: Math.min(100, Math.max(1, Math.round(nCount || 1))) });
  }

  /// 线上颜色串的写法可能有细微差异（"1" vs "1.0"），比对时按数值归一。
  const sameColor = (a: string, b: string) => {
    const n = (c: string) => (/rgba?\(([^)]+)\)/.exec(c || "")?.[1] || "")
      .split(",").map((v) => Math.round(parseFloat(v) * 1000) / 1000).join(",");
    return n(a) === n(b);
  };
</script>

{#if S.padOpen >= 0 && S.pads[S.padOpen]}
  <div id="padbar">
    {#if S.boardKind === 2}
      <!-- 画板笔记（v16）：这张纸就是整篇画板——没有列表 / 页面底图 / 关闭（关 = 在 Mac 上关标签），
           名字取 boards 列表里已兜底的显示名，改名走 scratchRename index=0 -->
      <button title="画板笔记列表" onclick={() => actions.toggleBoardList()}><Icon name="board" /></button>
      {#if S.boardRenaming}
        <!-- svelte-ignore a11y_autofocus -->
        <input id="boardNameInput" bind:value={draft} autofocus aria-label="画板笔记名字"
          onkeydown={(e) => { if (e.key === "Enter") actions.renameBoard(draft.trim());
                              if (e.key === "Escape") S.boardRenaming = false; }} />
        <button title="确定" onclick={() => actions.renameBoard(draft.trim())}><Icon name="check" /></button>
      {:else}
        <span id="padName">{boardName()}</span>
        <button title="改名" onclick={() => { draft = S.pads[S.padOpen]?.title || ""; S.boardRenaming = true; }}>
          <Icon name="pencil" /></button>
      {/if}
    {:else}
      <button title="草稿纸列表" onclick={() => actions.togglePadList()}><Icon name="scratch" /></button>
      <span id="padName">{name(S.pads[S.padOpen])}</span>
    {/if}
    {#if S.boardPaged}
      <!-- 分页画板（v17）：页码读数 + 这一页的背景（插页 / 删页 / 批量设置在 Mac 上做） -->
      <span id="pageNo">第 {S.boardCurPage + 1} / {S.boardPageCount} 页</span>
      <button class:on={S.boardTplPanel} title="这一页的背景" onclick={() => (S.boardTplPanel = !S.boardTplPanel)}>
        <Icon name="doc" /></button>
    {/if}
    <button title={S.boardPaged ? "回到本页页顶" : "回中"} onclick={() => actions.padRecenter()}><Icon name="scope" /></button>
    <button title={S.boardPaged ? "适配页宽" : "适应内容"} onclick={() => actions.padFit()}><Icon name="fit" /></button>
    {#if !S.boardPaged}
      <button class:on={S.padMini} title="缩略图" onclick={() => actions.togglePadMini()}><Icon name="map" /></button>
    {/if}
    {#if S.boardKind !== 2}
      <!-- 页面底图（v10）：把这张纸锚定的那一页垫在纸下面。跟着纸走、跨端同步 -->
      <button class:on={S.padShowPage} title="显示所在页面" onclick={() => actions.togglePadPage()}><Icon name="doc" /></button>
    {/if}
    <button class:on={S.padPaper} title="纸样" onclick={() => actions.togglePadPaper()}><Icon name="palette" /></button>
    {#if S.boardKind !== 2}
      <button title="关闭草稿纸（Esc）" onclick={() => actions.closePad()}><Icon name="x" /></button>
    {/if}
  </div>
{/if}

{#if S.boardList && !S.padList}
  <!-- 画板笔记列表：与草稿纸列表共用一套样式（两个弹层互斥，同一时刻只会有一个 #padlist） -->
  <button id="padListMask" aria-label="关闭画板笔记列表" onclick={() => actions.toggleBoardList()}></button>
  <div id="padlist">
    <div class="phead">画板笔记</div>
    {#if !S.boards.length}
      <div class="pempty">还没有画板笔记</div>
    {/if}
    {#each S.boards as b (b.id)}
      <div class="prow" class:cur={S.boardKind === 2 && b.id === S.boardCurrent}>
        <button class="popen" onclick={() => actions.openBoard(b.id)}><span class="pt">{b.title}</span></button>
      </div>
    {/each}
    {#if !S.boardNewPanel}
      <button class="prow padd" onclick={() => (S.boardNewPanel = true)}>
        <Icon name="plus" /><span class="pt">新建画板笔记</span>
      </button>
    {:else}
      <!-- 新建：先选模式（建好之后不再转换）。分页再选页面大小 / 横竖 / 背景 / 页数 -->
      <div class="pnew">
        <div class="pnrow">
          <button class="pbtn" class:cur={!nPaged} onclick={() => (nPaged = false)}>无限画布</button>
          <button class="pbtn" class:cur={nPaged} onclick={() => (nPaged = true)}>分页</button>
        </div>
        {#if nPaged}
          <div class="pnrow">
            {#each SIZES as sz (sz.key)}
              <button class="pbtn" class:cur={nSize === sz.key} onclick={() => (nSize = sz.key)}>{sz.label}</button>
            {/each}
          </div>
          <div class="pnrow">
            <button class="pbtn" class:cur={!nLand} onclick={() => (nLand = false)}>竖版</button>
            <button class="pbtn" class:cur={nLand} onclick={() => (nLand = true)}>横版</button>
          </div>
          <div class="pnrow">
            {#each TEMPLATES as t (t.code)}
              <button class="pbtn" class:cur={nTpl === t.code} onclick={() => (nTpl = t.code)}>{t.label}</button>
            {/each}
          </div>
          <div class="pnrow">
            <span class="pt">页数</span>
            <input class="pcount" type="number" min="1" max="100" bind:value={nCount} aria-label="页数" />
          </div>
        {/if}
        <div class="pnrow">
          <button class="pbtn" onclick={() => (S.boardNewPanel = false)}>取消</button>
          <button class="pbtn primary" onclick={createBoard}>创建</button>
        </div>
      </div>
    {/if}
  </div>
{/if}

{#if S.boardTplPanel && S.boardPaged}
  <button id="padPaperMask" aria-label="关闭背景面板" onclick={() => (S.boardTplPanel = false)}></button>
  <div id="padpaper">
    <div class="phead">第 {S.boardCurPage + 1} 页的背景</div>
    <div class="prow2 pwrap">
      {#each TEMPLATES as t (t.code)}
        <button class="pbtn" class:cur={S.boardCurTemplate === t.code} onclick={() => actions.setPageTemplate(t.code)}>
          {t.label}</button>
      {/each}
    </div>
  </div>
{/if}

{#if S.pullHint}
  <div id="pullHint">继续上拉添加新页</div>
{/if}

{#if S.boardKind === 1}
  <!-- Mac 正在看 Markdown 笔记：平板不参与 md 笔记，给个说明，别停在上一篇 PDF 的页面上 -->
  <div id="mdEmpty">
    <div class="mt">Mac 正在看 Markdown 笔记</div>
    <div class="md">平板暂不显示 Markdown 笔记。在 Mac 上切到 PDF 或画板笔记，或从顶栏打开一篇画板笔记。</div>
  </div>
{/if}

{#if S.padPaper && S.padOpen >= 0}
  <button id="padPaperMask" aria-label="关闭纸样" onclick={() => actions.togglePadPaper()}></button>
  <div id="padpaper">
    <div class="phead">底纹</div>
    <div class="prow2">
      {#each PATTERNS as pt (pt.key)}
        <button class="pswatch" class:cur={S.padPattern === pt.key}
          onclick={() => actions.setPadPaper(null, pt.key)}>
          <span class="pv {pt.key}" style="background:{S.padBg || '#fff'}"></span>
          <span class="pl">{pt.label}</span>
        </button>
      {/each}
    </div>
    <div class="phead">纸色</div>
    <div class="prow2">
      {#each PAPERS as c (c.key)}
        <button class="pcolor" class:cur={sameColor(S.padBg, c.css)}
          style="background:{c.css}" aria-label={c.key}
          onclick={() => actions.setPadPaper(c.css, null)}></button>
      {/each}
    </div>
  </div>
{/if}

{#if S.padList}
  <button id="padListMask" aria-label="关闭草稿纸列表" onclick={() => actions.togglePadList()}></button>
  <div id="padlist">
    <div class="phead">草稿纸</div>
    {#if !S.pads.length}
      <div class="pempty">还没有草稿纸</div>
    {/if}
    {#each S.pads as p (p.id)}
      {#if S.padRenaming === p.index}
        <!-- 行内改名：平板上没有键盘弹窗可用，就地改最省事（空串 = 回到「草稿纸 N」兜底名） -->
        <div class="prow prename">
          <!-- svelte-ignore a11y_autofocus -->
          <input bind:value={draft} autofocus aria-label="草稿纸名字"
            onkeydown={(e) => { if (e.key === "Enter") actions.renamePad(p.index, draft.trim());
                                if (e.key === "Escape") S.padRenaming = -1; }} />
          <button class="pact" title="确定" onclick={() => actions.renamePad(p.index, draft.trim())}>
            <Icon name="check" /></button>
          <button class="pact" title="取消" onclick={() => (S.padRenaming = -1)}><Icon name="x" /></button>
        </div>
      {:else if S.padDeleting === p.index}
        <!-- 两步删：纸上的笔迹会一起没，误触一下就没了太亏 -->
        <div class="prow pconfirm">
          <span class="pt">删除《{name(p)}》？</span>
          <button class="pbtn danger" onclick={() => actions.deletePad(p.index)}>删除</button>
          <button class="pbtn" onclick={() => (S.padDeleting = -1)}>取消</button>
        </div>
      {:else}
        <div class="prow" class:cur={p.index === S.padOpen}>
          <button class="popen" onclick={() => actions.openPad(p.index)}>
            <span class="pt">{name(p)}</span>
            <span class="pp">第 {p.page + 1} 页</span>
          </button>
          <button class="pact" title="改名" onclick={() => startRename(p)}><Icon name="pencil" /></button>
          <button class="pact danger" title="删除" onclick={() => { S.padRenaming = -1; S.padDeleting = p.index; }}>
            <Icon name="trash" /></button>
        </div>
      {/if}
    {/each}
    <button class="prow padd" onclick={() => actions.addPad()}>
      <Icon name="plus" /><span class="pt">在当前位置新建</span>
    </button>
  </div>
{/if}
