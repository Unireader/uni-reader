// 离屏验证习题 v21 的两块新界面（`EXERCISE-PLAN.md §11`）：填空 / 主观题作答区 `ExerciseFreeAnswerView` 与
// 手写小画板 `ExerciseInkPad` + 出图 `ExerciseInkRender`。编的是**真代码**，只把 `ExerciseDeck.Answer`
// （它那个文件牵出整个工作区）和 Markdown 引擎用不到的几个类型换成桩。依赖已编好的包模块（先按 AGENTS.md 编一次 Debug 包）。运行：
//
//   D=build/dev/Build/Products/Debug; O=/tmp/ex-free; mkdir -p $O && cp -R $D/Highlighter_Highlighter.bundle $D/SwiftMath_SwiftMath.bundle $O/ \
//   && cp spike/exercise-free-answer-test.swift $O/main.swift && swiftc -I $D $D/MarkdownEngine.o $D/MarkdownEngineLatex.o $D/SwiftMath.o $D/Highlighter.o \
//      Sources/Support/L.swift Sources/Markdown/MarkdownNoteEditor.swift Sources/Markdown/LatexCompat.swift Sources/Window/AI/AgentMarkdownView.swift \
//      Sources/Window/AI/AgentRowView.swift Sources/Agent/AgentMarkdownBlocks.swift Sources/Store/*.swift Sources/App/Exercise.swift \
//      Sources/App/InkModel.swift Sources/App/PenPreset.swift Sources/App/ScratchPadModel.swift Sources/App/BoardModel.swift \
//      Sources/Reader/InkRenderCG.swift Sources/Window/Exercise/ExerciseInkPad.swift Sources/Window/Exercise/ExerciseFreeAnswerView.swift \
//      $O/main.swift -o $O/t && $O/t $O
//
// 盯的事：
//  1. 画板：合成鼠标事件写一笔 → 笔迹在**逻辑坐标**（宽恒 600）里；橡皮整笔擦；撤销 / 清空 / 加高；只读时不收输入；
//  2. 出图：白底、尺寸按比例、笔画处有墨；没笔画 → nil；
//  3. 填空：空数 = 输入框数、草稿回填、输入 → `response`、回车跳下一空 / 最后一空 = 提交、交卷后锁住 + 对得上的标绿勾、
//     最终判错时对不上的标红叉；
//  4. 主观题：输入框 → `response.text`、打开手写 → 画板出现且高度变大、写一笔进 `response.ink`、交卷后输入框换成「你的作答」、
//     画板只读、参考答案出现；
//  5. 排版：看得见的子视图从上到下不重叠。
// 另出样张：$O/look-fill-light.png、$O/look-fill-answered-dark.png、$O/look-subjective-light.png、$O/look-subjective-answered-dark.png
import AppKit
import MarkdownEngine
import SwiftUI

// MARK: - 桩

struct AgentImage: Equatable { var data = Data() }

/// 同 `App/InkLayerModel.swift` 的默认图层 id（那个文件牵出笔记类型一整套）。
struct InkLayer { static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }

final class WorkspaceWikiIndex: WikiLinkResolver, EmbeddedImageProvider, @unchecked Sendable {
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
    func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    func fingerprint() -> AnyHashable { 0 }
}

enum NoteBubble {
    static let editorFontSizeKey = "spike.editorFontSize"
    static let defaultEditorFont: CGFloat = 13
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// 同 `Window/Exercise/ExerciseDeck.swift` 的 `Answer`（作答区只读 `response` / `correct`）。
enum ExerciseDeck {
    struct Answer: Equatable {
        var response: ExerciseResponse
        var correct: Bool?
        var earlier: Exercise.Earlier? = nil
        var attemptId: String? = nil
        var judgedBy: String = ""
    }
}

// MARK: - 断言

setvbuf(stdout, nil, _IONBF, 0)
UserDefaults.standard.removeObject(forKey: "exercise.handwriting")
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ex-free")
var failures = 0, checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if ok { print("  ✅ \(what)") } else { failures += 1; print("  ❌ \(what)") }
}

@MainActor
func pump(_ seconds: TimeInterval = 0.5) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

func exercise(_ kind: ExerciseKind, answer: [String] = [], blanks: Int? = nil, accept: [[String]]? = nil) -> Exercise {
    let p = ExercisePayload(stem: "题干", options: [], answer: answer, answerSource: answer.isEmpty ? nil : "book",
                            blanks: blanks, accept: accept)
    let row = LibExercise(id: UUID().uuidString, documentId: nil, page: 0, seq: 0, kind: kind.rawValue, number: "5",
                          section: "", payload: p.data(), starred: false, wrong: false, source: "t",
                          createdAt: .now, updatedAt: .now)
    return Exercise(row: row)!
}

/// 在一个离屏窗口里放视图（事件要窗口坐标）。
@MainActor
func host(_ v: NSView, width: CGFloat, height: CGFloat, dark: Bool = false) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                     backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let root = FlippedRoot(frame: NSRect(x: 0, y: 0, width: width, height: height))
    w.contentView = root
    root.addSubview(v)
    return w
}
final class FlippedRoot: NSView { override var isFlipped: Bool { true } }

/// 视图里 `p`（视图坐标）对应的鼠标事件。
@MainActor
func mouse(_ type: NSEvent.EventType, _ p: CGPoint, in v: NSView) -> NSEvent {
    let wp = v.convert(p, to: nil)
    return NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: 0,
                              windowNumber: v.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                              clickCount: 1, pressure: 1)!
}

@MainActor
func draw(_ pad: ExerciseInkPad, _ pts: [CGPoint]) {
    pad.mouseDown(with: mouse(.leftMouseDown, pts[0], in: pad))
    for p in pts.dropFirst() { pad.mouseDragged(with: mouse(.leftMouseDragged, p, in: pad)) }
    pad.mouseUp(with: mouse(.leftMouseUp, pts.last!, in: pad))
}

@MainActor
func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

/// 出样张：先铺一层窗口底色（按视图的外观），不然深色下的白字落在透明底上看不见。
@MainActor
func snapshot(_ v: NSView, _ name: String) {
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let img = NSImage(size: v.bounds.size)
    img.lockFocus()
    (v.appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
    }
    rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
             respectFlipped: true, hints: nil)
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) else { return }
    try? out.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
}

/// 看得见的直接子视图从上到下不重叠（同一行的按钮允许并排）。
@MainActor
func noOverlap(_ v: NSView, _ what: String) {
    let vis = v.subviews.filter { !$0.isHidden && $0.frame.height > 0 }
    var bad: [String] = []
    for (i, a) in vis.enumerated() {
        for b in vis[(i + 1)...] where a.frame.insetBy(dx: 1, dy: 1).intersects(b.frame.insetBy(dx: 1, dy: 1)) {
            bad.append("\(type(of: a))\(a.frame) × \(type(of: b))\(b.frame)")
        }
    }
    check(bad.isEmpty, "\(what)：子视图不重叠" + (bad.isEmpty ? "" : "（\(bad.prefix(3).joined(separator: "; "))）"))
}

// MARK: 1. 画板

@MainActor
func testPad() {
    print("1. 画板")
    let pad = ExerciseInkPad()
    pad.frame = NSRect(x: 0, y: 0, width: 300, height: pad.height(forWidth: 300))
    let win = host(pad, width: 320, height: 400)
    _ = win
    check(abs(pad.frame.height - 140) < 0.01, "300 宽时高 = 280 × 300/600 = 140")
    var changes = 0
    pad.onChange = { changes += 1 }
    draw(pad, [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 60, y: 50)])
    check(pad.ink.strokes.count == 1 && changes == 1, "写一笔 → 一条笔迹、通知一次")
    let p0 = pad.ink.strokes.first?.points.first ?? []
    check(p0.count == 3 && abs(p0[0] - 20) < 0.11 && abs(p0[1] - 40) < 0.11, "点在逻辑坐标里（视图 ×2）：\(p0)")
    check(abs((p0.last ?? 0) - 0.5) < 0.001, "鼠标没有压感 → 0.5")
    draw(pad, [CGPoint(x: 200, y: 100), CGPoint(x: 220, y: 110)])
    check(pad.ink.strokes.count == 2, "再写一笔")
    pad.tool = .eraser
    draw(pad, [CGPoint(x: 31, y: 41)])
    check(pad.ink.strokes.count == 1 && pad.ink.strokes[0].points.first?.first ?? 0 > 300, "橡皮碰到哪笔擦哪笔（另一笔不动）")
    draw(pad, [CGPoint(x: 5, y: 130)])
    check(pad.ink.strokes.count == 1, "没碰到不擦")
    pad.undo()
    check(pad.ink.strokes.count == 2, "撤销擦除 → 回来")
    pad.clear()
    check(pad.ink.isEmpty, "清空")
    pad.undo()
    check(pad.ink.strokes.count == 2, "撤销清空")
    pad.grow()
    check(pad.ink.height == 480 && abs(pad.height(forWidth: 300) - 240) < 0.01, "加高 200 逻辑点")
    pad.tool = .pen
    pad.isEditable = false
    draw(pad, [CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 120)])
    check(pad.ink.strokes.count == 2, "只读时不收输入")
    pad.load(nil)
    check(pad.ink.isEmpty && !pad.canUndo && pad.ink.height == ExerciseInk.defaultHeight, "换题：空白、撤销清零、高度复原")
}

// MARK: 2. 出图

@MainActor
func testRender() {
    print("2. 出图")
    var ink = ExerciseInk()
    check(ExerciseInkRender.png(ink, pixelWidth: 600) == nil, "没笔画 → nil")
    ink.strokes = [ExerciseInk.Stroke(width: 2.6, points: [[100, 100, 0.5], [300, 140, 0.5], [500, 120, 0.5]])]
    guard let png = ExerciseInkRender.png(ink, pixelWidth: 1200), let rep = NSBitmapImageRep(data: png) else {
        check(false, "出得了图"); return
    }
    check(rep.pixelsWide == 1200 && rep.pixelsHigh == 560, "尺寸按比例：\(rep.pixelsWide)×\(rep.pixelsHigh)")
    let corner = rep.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB)
    check((corner?.brightnessComponent ?? 0) > 0.98, "白底")
    let ink1 = rep.colorAt(x: 200, y: 200)?.usingColorSpace(.sRGB)   // 第一个点 (100,100) × 2
    check((ink1?.brightnessComponent ?? 1) < 0.4, "笔画处有墨（亮度 \(ink1?.brightnessComponent ?? -1)）")
    try? png.write(to: outDir.appendingPathComponent("look-ink.png"))
}

// MARK: 3. 填空

@MainActor
func testFill() {
    print("3. 填空")
    let e = exercise(.fill, answer: ["2", "\\frac{1}{2}"], blanks: 2, accept: [[], ["0.5"]])
    let v = ExerciseFreeAnswerView()
    v.frame = NSRect(x: 0, y: 0, width: 560, height: 10)
    let win = host(v, width: 600, height: 700)
    _ = win
    var edits = 0, submits = 0
    v.onEdit = { edits += 1 }
    v.onSubmit = { submits += 1 }
    v.begin(e, draft: ExerciseResponse(blanks: ["2", ""]))
    v.frame.size.height = v.height(forWidth: 560)
    v.layoutSubtreeIfNeeded()
    let fields = v.subviews.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
    check(fields.count == 2, "两空 → 两个输入框")
    check(fields.map(\.stringValue) == ["2", ""], "草稿回填")
    check(fields.allSatisfy { $0.frame.width > 300 }, "输入框够宽")
    fields[1].stringValue = " 0.5 "
    v.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: fields[1]))
    check(edits == 1, "输入变了 → onEdit")
    check(v.response.blanks == ["2", "0.5"] && v.response.ink == nil, "response = 每空去首尾空白，没开手写 → 没有笔迹")
    let tv = NSTextView()
    _ = v.control(fields[0], textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    check(submits == 0, "第一空回车不提交（跳下一空）")
    _ = v.control(fields[1], textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    check(submits == 1, "最后一空回车 = 提交")
    check(!v.isLocked, "没交 = 不锁")
    noOverlap(v, "填空作答中")
    snapshot(v, "look-fill-light.png")

    // 交卷：第一空对、第二空写成另一种认可写法（也对）→ 两个绿勾
    v.showAnswered(e, answer: ExerciseDeck.Answer(response: ExerciseResponse(blanks: ["2", "0.5"]), correct: true), ink: nil)
    v.frame.size.height = v.height(forWidth: 560)
    v.layoutSubtreeIfNeeded()
    let locked = v.subviews.compactMap { $0 as? NSTextField }.filter { $0.isBezeled }
    check(v.isLocked && locked.allSatisfy { !$0.isEditable }, "交卷后输入框锁住")
    let marks = v.subviews.compactMap { $0 as? NSImageView }.filter { $0.image != nil && !$0.isHidden }
    check(marks.count == 2 && marks.allSatisfy { $0.contentTintColor == .systemGreen }, "两空都对得上 → 两个绿勾")
    // 判错：对不上的标红叉
    v.showAnswered(e, answer: ExerciseDeck.Answer(response: ExerciseResponse(blanks: ["2", "1/3"]), correct: false), ink: nil)
    let marks2 = v.subviews.compactMap { $0 as? NSImageView }.filter { $0.image != nil }
    check(marks2.map { $0.contentTintColor == .systemGreen } == [true, false], "判错：对上的绿勾、对不上的红叉")
    // 还没判（对不上、等自己判）：对不上的不标
    v.showAnswered(e, answer: ExerciseDeck.Answer(response: ExerciseResponse(blanks: ["2", "1/3"]), correct: nil), ink: nil)
    check(v.subviews.compactMap { $0 as? NSImageView }.filter { $0.image != nil }.count == 1, "还没判：只标对上的那空")
    let ref = ExerciseFreeAnswerView.referenceMarkdown(e) ?? ""
    check(ref.contains("\\frac{1}{2}") && ref.contains("0.5") && ref.components(separatedBy: "\n").count == 2,
          "参考答案一空一行、带另外认可的写法：\(ref.debugDescription)")
    check(ExerciseFreeAnswerView.referenceMarkdown(exercise(.fill, blanks: 2)) == nil, "没答案 → 不显示参考答案")
    pump()
    v.frame.size.height = v.height(forWidth: 560)
    noOverlap(v, "填空交卷后")
    v.appearance = NSAppearance(named: .darkAqua)
    snapshot(v, "look-fill-answered-dark.png")
}

// MARK: 4. 主观题

@MainActor
func testSubjective() {
    print("4. 主观题")
    let e = exercise(.subjective, answer: ["反证法：设 $\\sqrt2=\\frac{p}{q}$，$p,q$ 互质……"])
    let v = ExerciseFreeAnswerView()
    v.frame = NSRect(x: 0, y: 0, width: 560, height: 10)
    let win = host(v, width: 600, height: 900)
    _ = win
    v.begin(e, draft: nil)
    v.frame.size.height = v.height(forWidth: 560)
    v.layoutSubtreeIfNeeded()
    let h0 = v.frame.height
    guard let tv = allSubviews(v).compactMap({ $0 as? NSTextView }).first else { check(false, "有多行输入框"); return }
    check(tv.isEditable, "多行输入框可写")
    tv.string = "设 $\\sqrt2$ 是有理数"
    v.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
    check(v.response.text == "设 $\\sqrt2$ 是有理数" && v.response.ink == nil, "response.text")
    guard let hand = v.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == L("Handwriting") }) else {
        check(false, "有「手写」开关"); return
    }
    let pad = v.subviews.compactMap { $0 as? ExerciseInkPad }.first!
    check(pad.isHidden, "手写默认收起")
    hand.performClick(nil)
    v.frame.size.height = v.height(forWidth: 560)
    v.layoutSubtreeIfNeeded()
    check(!pad.isHidden && v.frame.height > h0 + 200, "打开手写 → 画板出现、整块变高（\(h0) → \(v.frame.height)）")
    check(UserDefaults.standard.bool(forKey: "exercise.handwriting"), "开着手写记在本机")
    draw(pad, [CGPoint(x: 40, y: 40), CGPoint(x: 120, y: 60), CGPoint(x: 200, y: 50)])
    check(v.response.ink?.strokes.count == 1, "写一笔 → response.ink")
    noOverlap(v, "主观题作答中")
    snapshot(v, "look-subjective-light.png")
    let ink = v.response.ink

    // 下一题（新的一题）：开着手写的偏好留着，画板是空的
    v.begin(e, draft: nil)
    check(!pad.isHidden && pad.ink.isEmpty && v.response.text.isEmpty, "换题：手写照开、画板与输入框清空")

    // 交卷后
    v.showAnswered(e, answer: ExerciseDeck.Answer(response: ExerciseResponse(text: "设 $\\sqrt2$ 是有理数", ink: ink),
                                                  correct: nil), ink: nil)
    pump()
    v.frame.size.height = v.height(forWidth: 560)
    v.layoutSubtreeIfNeeded()
    let scroll = v.subviews.compactMap { $0 as? NSScrollView }.first
    check(scroll?.isHidden == true, "交卷后多行输入框收起")
    check(!pad.isHidden && !pad.isEditable && pad.ink == ink, "画板只读显示交过的笔迹")
    check(hand.isHidden, "交卷后没有手写开关")
    let titles = v.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
    check(titles.contains(L("Your Answer")) && titles.contains(L("Reference Answer")), "显示「你的作答」与「参考答案」：\(titles)")
    noOverlap(v, "主观题交卷后")
    v.appearance = NSAppearance(named: .darkAqua)
    snapshot(v, "look-subjective-answered-dark.png")

    // 只写在画板上（没打字）：交卷后不显示「你的作答」那一块
    v.showAnswered(e, answer: ExerciseDeck.Answer(response: ExerciseResponse(ink: ink), correct: true), ink: ink)
    let titles2 = v.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
    check(!titles2.contains(L("Your Answer")), "只手写：不出空的「你的作答」")
    // 没有参考答案
    let bare = exercise(.subjective)
    v.showAnswered(bare, answer: ExerciseDeck.Answer(response: ExerciseResponse(text: "x"), correct: nil), ink: nil)
    let titles3 = v.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
    check(!titles3.contains(L("Reference Answer")), "没有参考答案：不出那一块")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    testPad()
    testRender()
    testFill()
    testSubjective()
}
UserDefaults.standard.removeObject(forKey: "exercise.handwriting")
print("\n\(checks - failures) 通过，\(failures) 失败（样张在 \(outDir.path)）")
exit(failures == 0 ? 0 : 1)
