<script lang="ts">
  // 文字笔记编辑器：圆形选择器风格的弹出面板（形制呼应选笔盘毛玻璃底盘）。
  // 打开状态在 hud 的 S.noteEditor（低频 UI 走 runes）；输入文本是组件本地 $state。
  // 保存/删除发 textNote 上行帧并乐观更新 G.notes（Mac 随后回传 notes 全量镜像，整体替换也一致）。
  import { S } from "./lib/hud.svelte.js";
  import type { NoteEditorState } from "./lib/hud.svelte.js";
  import { G, BAR, clamp } from "./lib/shared.js";

  let text = $state("");
  // 每次打开（S.noteEditor 变化）重置输入框为初始文本
  $effect(() => { text = S.noteEditor ? S.noteEditor.text : ""; });

  const PANEL_W = 280;   // 面板宽（定位夹取用，与 CSS 一致）

  function panelPos(ed: NoteEditorState): string {
    const left = clamp(ed.x - PANEL_W / 2, 8, Math.max(8, window.innerWidth - PANEL_W - 8));
    const top = clamp(ed.y + 28, BAR + 8, Math.max(BAR + 8, window.innerHeight - 220));
    return "left:" + left + "px;top:" + top + "px";
  }

  function close(): void { S.noteEditor = null; }

  function save(): void {
    const ed = S.noteEditor; if (!ed) return;
    const t = text.trim();
    if (!t) {   // 空文本：新建 = 直接取消；已有 = 等同删除（与 Mac「空 upsert 即删除」语义一致）
      if (!ed.isNew) removeNote(ed.id);
      close(); return;
    }
    G.send({ type: "textNote", id: ed.id, op: "upsert", page: ed.page, nx: ed.nx, ny: ed.ny, text: t });
    // 乐观更新本地列表（不等 Mac 回传）并重画标记
    const rec = { id: ed.id, page: ed.page, nx: ed.nx, ny: ed.ny, text: t };
    const i = G.notes.findIndex((n) => n.id === ed.id);
    if (i >= 0) G.notes[i] = rec; else G.notes.push(rec);
    G.drawNotes();
    close();
  }

  function removeNote(id: string): void {
    const ed = S.noteEditor; if (!ed) return;
    G.send({ type: "textNote", id: id, op: "delete", page: ed.page, nx: ed.nx, ny: ed.ny, text: "" });
    G.notes = G.notes.filter((n) => n.id !== id);
    G.drawNotes();
  }

  function del(): void {
    const ed = S.noteEditor; if (!ed) return;
    removeNote(ed.id);
    close();
  }

  function onKey(e: KeyboardEvent): void {
    if (!S.noteEditor) return;
    if (e.key === "Escape") { e.preventDefault(); close(); }
  }

  function focusMe(el: HTMLTextAreaElement): void { el.focus(); }
</script>

<svelte:window onkeydown={onKey} />

{#if S.noteEditor}
  <button id="noteEditorMask" aria-label="关闭编辑器" onclick={close}></button>
  <div id="noteEditor" style={panelPos(S.noteEditor)}>
    <textarea bind:value={text} placeholder="输入笔记内容…" use:focusMe></textarea>
    <div class="row">
      {#if !S.noteEditor.isNew}
        <button class="del" onclick={del}>删除</button>
      {/if}
      <button onclick={close}>取消</button>
      <button class="save" onclick={save}>保存</button>
    </div>
  </div>
{/if}
