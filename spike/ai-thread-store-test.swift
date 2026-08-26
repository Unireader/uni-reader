// AI 会话绑定 round-trip 测试（note kind=1，零 schema 迁移复用 note 表）。运行：
//   cp spike/ai-thread-store-test.swift /tmp/main.swift && swiftc Sources/Store/*.swift Sources/AI/AIThread.swift Sources/AI/AIProvider.swift Sources/App/TextNoteModel.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/NoteTypeModel.swift Sources/App/PenPreset.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/aitt && /tmp/aitt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
//
// 覆盖五块：
//  ① AIThread ↔ note kind=1 的 round-trip（URL / 标题 / 状态 / contexts / 归一化矩形 / 时间戳）；
//  ② `contexts` 第一条决定 page/anchor —— 用户定的「多张图用第一张」规则；
//  ③ kind 隔离与容错：kind≠1 一律不认、payload 损坏返回 nil、未知 context kind 跳过（前向兼容）；
//  ④ **会话 URL 正则**：DeepSeek 的真实会话 URL 必须命中、首页/登录页必须不命中。
//     第 ④ 块是这套里最要紧的 —— 正则写错就是「绑定永远不 commit」这种查不出的静默失效。
//  ⑤ `TextNote.source`（S5 回填来源）的 round-trip 与**零迁移**：旧 payload 无 source 键 → nil。
import Foundation
import CoreGraphics

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ai_test_\(UInt64.random(in: 0..<1_000_000))")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

let store = try LibraryStore(workspaceFolder: tmp)
let (doc, _) = try store.findOrCreate(hash: "h1", title: "Doc", pageCount: 40, path: "/tmp/a.pdf")

// ────────────────────────────────────────────────────────────
print("① note kind=1 round-trip")

let liveURL = "https://chat.deepseek.com/a/chat/s/66ecab55-6b60-4b56-8e92-39cb9e95c0e5"
var t = AIThread(page: 11, provider: "deepseek", url: liveURL, title: "泰勒展开为什么要在 0 附近")
t.addContext(AIContext(kind: .region, page: 11,
                       rect: CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.125)))
t.addContext(AIContext(kind: .quote, page: 12, rect: nil, text: "余项的拉格朗日形式"))

guard let n = t.toNote(documentId: doc.id) else { fatalError("toNote 返回 nil") }
try store.upsertNote(n)

let backRows = try store.notes(documentId: doc.id).filter { $0.kind == AIThread.noteKind }
check(backRows.count == 1, "库里恰好一条 kind=1")
guard let back = backRows.first.flatMap({ AIThread(note: $0) }) else { fatalError("复原失败") }

check(back.id == t.id, "id 保持")
check(back.url == liveURL, "会话 URL 无损")
check(back.title == t.title, "标题无损（含中文）")
check(back.provider == "deepseek", "provider 保持")
check(back.state == .ok, "state 默认 ok")
check(back.contexts.count == 2, "contexts 两条")
check(back.contexts[0].kind == .region && back.contexts[1].kind == .quote, "contexts 顺序与 kind 保持")
check(back.contexts[1].text == "余项的拉格朗日形式", "quote 原文无损")
let r = back.contexts[0].rect ?? .zero
check(abs(r.minX - 0.125) < 1e-9 && abs(r.minY - 0.25) < 1e-9
      && abs(r.width - 0.5) < 1e-9 && abs(r.height - 0.125) < 1e-9, "归一化矩形无损")
check(back.contexts[1].rect == nil, "无矩形的 context 复原后仍为 nil")
check(abs(back.contexts[0].sentAt.timeIntervalSince(t.contexts[0].sentAt)) < 0.01, "sent_at 走 ISO-8601 往返")
check(back.lastOpenedAt == nil, "未打开过 → last_opened_at 为空")

var opened = back
opened.lastOpenedAt = Date(timeIntervalSince1970: 1_800_000_000)
opened.state = .suspect
try store.upsertNote(opened.toNote(documentId: doc.id)!)
guard let reopened = (try store.notes(documentId: doc.id))
        .first(where: { $0.kind == AIThread.noteKind }).flatMap({ AIThread(note: $0) })
else { fatalError("二次复原失败") }
check(reopened.state == .suspect, "state=suspect 往返（失效标记不会丢）")
check(abs((reopened.lastOpenedAt ?? .distantPast).timeIntervalSince1970 - 1_800_000_000) < 0.01,
      "last_opened_at 往返")
check((try store.notes(documentId: doc.id)).filter { $0.kind == AIThread.noteKind }.count == 1,
      "upsert 覆盖同 id，不产生第二行")

// ────────────────────────────────────────────────────────────
print("② contexts 第一条决定 page/anchor（多张图用第一张）")

var fresh = AIThread(page: 3, provider: "deepseek", url: liveURL)
check(fresh.page == 3 && fresh.anchor == .zero, "还没发东西时：页 = 发起绑定时所在页，anchor 为空")

fresh.addContext(AIContext(kind: .region, page: 7, rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))
check(fresh.page == 7, "第一条 context 把 page 改成它的页")
check(fresh.anchor == CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), "第一条 context 把 anchor 设成它的矩形")

fresh.addContext(AIContext(kind: .region, page: 9, rect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)))
check(fresh.page == 7 && fresh.anchor.minX == 0.1, "第二条起不再改 page/anchor（第一张说了算）")

var pageOnly = AIThread(page: 3, provider: "deepseek", url: liveURL)
pageOnly.addContext(AIContext(kind: .page, page: 5, rect: nil))
check(pageOnly.page == 5 && pageOnly.anchor == .zero, "整页 context：改页但 anchor 仍为空")

// 落库再取，page/anchor 走的是 note 的列而不是 payload
try store.upsertNote(fresh.toNote(documentId: doc.id)!)
let freshBack = (try store.notes(documentId: doc.id))
    .first { $0.id == fresh.id.uuidString }.flatMap { AIThread(note: $0) }
check(freshBack?.page == 7, "page 经 note 列往返")
check(freshBack.map { abs($0.anchor.width - 0.3) < 1e-9 } == true, "anchor 经 note 列往返")

// ────────────────────────────────────────────────────────────
print("③ kind 隔离与容错")

// 手写一条 kind=0（文字注解）到同一文档：绝不能被当成会话读出来
let alien = LibNote(id: UUID().uuidString, documentId: doc.id, kind: 0, page: 1,
                    anchor: CGRect(x: 0, y: 0, width: 1, height: 0.1),
                    payload: Data(#"{"quote":"x","text":"y","rects":[]}"#.utf8),
                    createdAt: .now, updatedAt: .now)
try store.upsertNote(alien)
check(AIThread(note: alien) == nil, "kind=0 的 note 不会被当成 AI 会话")
check((try store.notes(documentId: doc.id)).compactMap { AIThread(note: $0) }.count == 2,
      "全量扫描只捡出 kind=1 的那两条")

let broken = LibNote(id: UUID().uuidString, documentId: doc.id, kind: AIThread.noteKind, page: 0,
                     anchor: .zero, payload: Data("{ not json".utf8), createdAt: .now, updatedAt: .now)
check(AIThread(note: broken) == nil, "payload 损坏 → nil（不炸、不半残）")

let badID = LibNote(id: "not-a-uuid", documentId: doc.id, kind: AIThread.noteKind, page: 0,
                    anchor: .zero, payload: Data(#"{"provider":"x","url":"u","title":"","state":0,"contexts":[]}"#.utf8),
                    createdAt: .now, updatedAt: .now)
check(AIThread(note: badID) == nil, "id 不是 UUID → nil")

// 前向兼容：将来新增的 context kind，旧版本读到应当跳过那一条而不是整条会话报废
let futureJSON = #"{"provider":"deepseek","url":"u","title":"t","state":0,"contexts":"#
    + #"[{"kind":"hologram","page":1,"sent_at":"2026-08-25T00:00:00.000Z"},"#
    + #"{"kind":"page","page":2,"sent_at":"2026-08-25T00:00:00.000Z"}]}"#
let future = LibNote(id: UUID().uuidString, documentId: doc.id, kind: AIThread.noteKind, page: 2,
                     anchor: .zero, payload: Data(futureJSON.utf8), createdAt: .now, updatedAt: .now)
let futureBack = AIThread(note: future)
check(futureBack != nil, "含未知 context kind 的 payload 仍能读出会话")
check(futureBack?.contexts.count == 1 && futureBack?.contexts.first?.kind == .page,
      "未知 kind 的那条被跳过，认识的那条留下")

// 解绑 = 删这一行，平台上的对话与其他笔记都不受影响
try store.deleteNote(id: fresh.id.uuidString)
check((try store.notes(documentId: doc.id)).contains { $0.id == alien.id }, "解绑不碰别的 kind")
check(!(try store.notes(documentId: doc.id)).contains { $0.id == fresh.id.uuidString }, "解绑那条确实没了")

// ────────────────────────────────────────────────────────────
print("④ 会话 URL 正则（内置 DeepSeek，2026-08-25 用户实测核对）")

guard let ds = AIProvider.builtin.first(where: { $0.id == "deepseek" }) else { fatalError("内置表里没有 deepseek") }
check(AIProvider.builtin.count == 1, "内置表只有 DeepSeek 一家（用户拍板）")
check(ds.home == "https://chat.deepseek.com/", "首页 URL 与实测一致")

check(ds.matchesThread(liveURL), "实测会话 URL 命中")
check(ds.matchesThread("https://chat.deepseek.com/a/chat/s/00000000-0000-0000-0000-000000000000"),
      "同形态的另一个 uuid 也命中")
check(!ds.matchesThread("https://chat.deepseek.com/"), "首页不命中（否则一进门就误 commit）")
check(!ds.matchesThread("https://chat.deepseek.com/sign_in"), "登录页不命中")
check(!ds.matchesThread("https://chat.deepseek.com/a/chat/s/"), "缺 id 的路径不命中")
check(!ds.matchesThread(""), "空串不命中")
check(!ds.matchesThread("https://evil.com/?x=https://chat.deepseek.com/a/chat/s/66ecab55"),
      "正则锚在开头：别家域名里夹带我们的路径不算命中")
check(ds.clearDomains == ["deepseek.com"], "清除登录数据的域名单")

// ────────────────────────────────────────────────────────────
print("⑤ TextNote.source：AI 回填来源（S5）")

let threadID = UUID()
var aiNote = TextNote(page: 11, anchor: CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.125),
                      quote: "余项的拉格朗日形式", text: "**泰勒展开**在 0 附近……\n$$f(x)=\\sum$$",
                      rects: [])
aiNote.source = NoteSource(kind: NoteSource.aiKind, provider: "deepseek", url: liveURL,
                           threadId: threadID, at: Date(timeIntervalSince1970: 1_800_000_123))
try store.upsertNote(aiNote.toNote(documentId: doc.id)!)

guard let noteBack = (try store.notes(documentId: doc.id))
        .first(where: { $0.id == aiNote.id.uuidString }).flatMap({ TextNote(note: $0) })
else { fatalError("TextNote 复原失败") }

check(noteBack.source?.isAI == true, "source.kind = ai")
check(noteBack.source?.provider == "deepseek", "provider 保持")
check(noteBack.source?.url == liveURL, "出处会话 URL 无损（笔记能点回对话就靠它）")
check(noteBack.source?.threadId == threadID, "thread_id 保持")
check(abs((noteBack.source?.at ?? .distantPast).timeIntervalSince1970 - 1_800_000_123) < 0.01,
      "来源时间走 ISO-8601 往返")
check(noteBack.text.contains("$$f(x)=\\sum"), "Markdown/LaTeX 原样存（不做转换）")
check(noteBack.quote == "余项的拉格朗日形式", "quote 存的是对话里发过的引文")
check(noteBack.anchor == aiNote.anchor, "锚点 = contexts 第一条的矩形（多张图用第一张）")

// 🔴 零迁移：**旧 payload 没有 source 键**，解出来必须是 nil 而不是报废整条笔记
let legacy = LibNote(id: UUID().uuidString, documentId: doc.id, kind: 0, page: 2,
                     anchor: CGRect(x: 0, y: 0.1, width: 1, height: 0.05),
                     payload: Data(#"{"quote":"q","text":"t","rects":[[0,0.1,1,0.05]]}"#.utf8),
                     createdAt: .now, updatedAt: .now)
try store.upsertNote(legacy)
let legacyBack = TextNote(note: legacy)
check(legacyBack != nil, "旧 payload（无 source 键）仍能读出笔记")
check(legacyBack?.source == nil, "旧 payload → source 为 nil（零迁移）")
check(legacyBack?.text == "t" && legacyBack?.rects.count == 1, "旧 payload 其余字段不受影响")

// 反向：新写的笔记若没有来源，payload 里不该冒出一个 null source 把旧端弄糊涂
let plain = TextNote(page: 0, anchor: .zero, quote: "", text: "手写的", rects: [])
let plainJSON = String(data: plain.toNote(documentId: doc.id)!.payload, encoding: .utf8) ?? ""
check(!plainJSON.contains("source"), "没有来源时 payload 里不写 source 键")

print("\n\(pass) 通过，\(fail) 失败")
if fail > 0 { exit(1) }
