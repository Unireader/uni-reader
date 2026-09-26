import AppKit
import Combine
import Foundation

/// 一组按键：键 + 修饰键。菜单项的 key equivalent 与阅读区单键监视器两处的比对都用它，
/// 设置页的录制也产出它。
struct KeyCombo: Hashable {
    /// 键本身：可打印键存**小写**单字符（"a" / "=" / "["）；不可打印键存 `Named` 里的名字（"left" / "tab"…）。
    var key: String
    /// 只保留 ⌘ ⇧ ⌥ ⌃ 四个位（Caps Lock / fn / 数字键盘位一律抹掉）。
    var mods: NSEvent.ModifierFlags

    static let relevantMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    init(_ key: String, _ mods: NSEvent.ModifierFlags = []) {
        self.key = key
        self.mods = mods.intersection(Self.relevantMods)
    }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.key == b.key && a.mods.rawValue == b.mods.rawValue }
    func hash(into h: inout Hasher) { h.combine(key); h.combine(mods.rawValue) }

    /// 不可打印键：存储名 / 菜单 key equivalent 用的字符 / 显示用的符号。
    private struct Named { let name: String; let menu: String; let glyph: String }
    private static func fk(_ c: Int) -> String { String(UnicodeScalar(c)!) }
    private static let named: [UInt16: Named] = [
        123: .init(name: "left", menu: fk(NSLeftArrowFunctionKey), glyph: "←"),
        124: .init(name: "right", menu: fk(NSRightArrowFunctionKey), glyph: "→"),
        125: .init(name: "down", menu: fk(NSDownArrowFunctionKey), glyph: "↓"),
        126: .init(name: "up", menu: fk(NSUpArrowFunctionKey), glyph: "↑"),
        48: .init(name: "tab", menu: "\t", glyph: "⇥"),
        36: .init(name: "return", menu: "\r", glyph: "↩"),
        76: .init(name: "enter", menu: "\u{3}", glyph: "⌤"),
        53: .init(name: "escape", menu: "\u{1B}", glyph: "⎋"),
        51: .init(name: "delete", menu: "\u{8}", glyph: "⌫"),
        117: .init(name: "forwarddelete", menu: fk(NSDeleteFunctionKey), glyph: "⌦"),
        49: .init(name: "space", menu: " ", glyph: "␣"),
        115: .init(name: "home", menu: fk(NSHomeFunctionKey), glyph: "↖"),
        119: .init(name: "end", menu: fk(NSEndFunctionKey), glyph: "↘"),
        116: .init(name: "pageup", menu: fk(NSPageUpFunctionKey), glyph: "⇞"),
        121: .init(name: "pagedown", menu: fk(NSPageDownFunctionKey), glyph: "⇟"),
        122: .init(name: "f1", menu: fk(NSF1FunctionKey), glyph: "F1"),
        120: .init(name: "f2", menu: fk(NSF2FunctionKey), glyph: "F2"),
        99: .init(name: "f3", menu: fk(NSF3FunctionKey), glyph: "F3"),
        118: .init(name: "f4", menu: fk(NSF4FunctionKey), glyph: "F4"),
        96: .init(name: "f5", menu: fk(NSF5FunctionKey), glyph: "F5"),
        97: .init(name: "f6", menu: fk(NSF6FunctionKey), glyph: "F6"),
        98: .init(name: "f7", menu: fk(NSF7FunctionKey), glyph: "F7"),
        100: .init(name: "f8", menu: fk(NSF8FunctionKey), glyph: "F8"),
        101: .init(name: "f9", menu: fk(NSF9FunctionKey), glyph: "F9"),
        109: .init(name: "f10", menu: fk(NSF10FunctionKey), glyph: "F10"),
        103: .init(name: "f11", menu: fk(NSF11FunctionKey), glyph: "F11"),
        111: .init(name: "f12", menu: fk(NSF12FunctionKey), glyph: "F12"),
    ]
    private static let namedByName: [String: Named] = Dictionary(uniqueKeysWithValues: named.values.map { ($0.name, $0) })

    /// 从按键事件来（录制 + 监视器比对）。认不出的键（只有修饰键、死键等）返回 nil。
    /// 可打印键取 `charactersIgnoringModifiers`——⌥E 给的是 "e" 而不是 "´"，与菜单 key equivalent 的口径一致；
    /// 字母统一小写、⇧ 记进修饰键（⇧H = "h" + shift）；非字母带 ⇧ 时字符本身已是上档字（⇧2 = "@"），⇧ 位就不再记。
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(Self.relevantMods)
        if let n = Self.named[event.keyCode] {
            self.init(n.name, mods)
            return
        }
        guard let s = event.charactersIgnoringModifiers, s.count == 1,
              let ch = s.unicodeScalars.first, ch.value >= 0x20, ch.value != 0x7F else { return nil }
        if s.rangeOfCharacter(from: .letters) != nil {
            self.init(s.lowercased(), mods)
        } else {
            self.init(s, mods.subtracting(.shift))
        }
    }

    // MARK: 存储串（"cmd+shift+a" / "opt+e" / "h" / "cmd+="）

    var storageString: String {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    init?(storage: String) {
        guard !storage.isEmpty else { return nil }
        var parts = storage.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // 键本身就是 "+" 时会切出空串：末尾补回来。
        if parts.count >= 2, parts.last == "" { parts.removeLast(); parts[parts.count - 1] = "+" }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for p in parts {
            switch p {
            case "cmd": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt": mods.insert(.option)
            case "ctrl": mods.insert(.control)
            default: return nil
            }
        }
        guard key.count == 1 || Self.namedByName[key] != nil else { return nil }
        self.init(key, mods)
    }

    // MARK: 显示与菜单

    /// "⌘⇧A"、"⌥E"、"H"、"⌘←"。修饰键顺序按系统惯例 ⌃⌥⇧⌘。
    var display: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s + (Self.namedByName[key]?.glyph ?? key.uppercased())
    }

    /// AppKit 菜单要的 key equivalent 字符（字母小写；方向键等用功能键 unicode）。
    var menuKeyEquivalent: String { Self.namedByName[key]?.menu ?? key }

    var isFunctionKey: Bool { key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// 能不能挂到菜单上：得带 ⌘/⌥/⌃ 之一（功能键除外）。裸字母挂上菜单，在文本框里打字也会触发它。
    var isMenuSafe: Bool { isFunctionKey || !mods.intersection([.command, .option, .control]).isEmpty }
}

/// 可改快捷键的动作（默认值在这里；用户改的存 `Shortcuts`）。
///
/// **不进这张表的**（用户 2026-09-13：「基础的比如复制粘贴就不用支持设置了」）：App 菜单、文件的新建/打开/关闭/标签切换、
/// 编辑菜单的撤销/剪贴板/全选/查找、窗口菜单，以及阅读区数字键 1–9 直选笔槽（9 个连号，三端同约定）。
/// 它们列在 `Shortcuts.reserved` 里，改别的动作时不许撞上。
enum ShortcutAction: String, CaseIterable, Identifiable {
    // 视图
    case toggleSidebar, toggleInspector, zoomIn, zoomOut, zoomFit
    case addBookmark, jumpBack, jumpForward, jumpHistory, gotoPage
    case nightMode, canvasMode, refWindow
    // 笔与模式（菜单，带 ⌥）
    case penSlot1, penSlot2, penSlot3, penSlot4, eraser, pageTurn, write
    // AI
    case aiPanel, agentPanel, snipToAI
    // 阅读区单键（不带修饰键也行；文本框/AI 面板打字时一律放行）
    case highlightSelection, underlineSelection, boxSelection, noteFromSelection
    case keyEraser, keyWrite, keyPageTurn, keyLasso, keyLocalInk, keyTextSelect

    var id: String { rawValue }

    /// 菜单项的 key equivalent，还是阅读区监视器里比对。
    enum Scope { case menu, reader }

    var scope: Scope {
        switch self {
        case .highlightSelection, .underlineSelection, .boxSelection, .noteFromSelection,
             .keyEraser, .keyWrite, .keyPageTurn, .keyLasso, .keyLocalInk, .keyTextSelect:
            return .reader
        default:
            return .menu
        }
    }

    /// 设置页的分组（顺序即页面顺序）。
    enum Section: CaseIterable {
        case view, pens, ai, readerKeys
        var title: String {
            switch self {
            case .view: return L("View")
            case .pens: return L("Pens & Modes")
            case .ai: return L("AI")
            case .readerKeys: return L("Reader Keys")
            }
        }
        var actions: [ShortcutAction] { ShortcutAction.allCases.filter { $0.section == self } }
    }

    var section: Section {
        switch self {
        case .toggleSidebar, .toggleInspector, .zoomIn, .zoomOut, .zoomFit, .addBookmark,
             .jumpBack, .jumpForward, .jumpHistory, .gotoPage, .nightMode, .canvasMode, .refWindow:
            return .view
        case .penSlot1, .penSlot2, .penSlot3, .penSlot4, .eraser, .pageTurn, .write:
            return .pens
        case .aiPanel, .agentPanel, .snipToAI:
            return .ai
        default:
            return .readerKeys
        }
    }

    var title: String {
        switch self {
        case .toggleSidebar: return L("Toggle Sidebar")
        case .toggleInspector: return L("Toggle Inspector")
        case .zoomIn: return L("Zoom In")
        case .zoomOut: return L("Zoom Out")
        case .zoomFit: return L("Zoom to Fit Width")
        case .addBookmark: return L("Add Bookmark")
        case .jumpBack: return L("Back to Previous Position")
        case .jumpForward: return L("Forward to Next Position")
        case .jumpHistory: return L("Jump History")
        case .gotoPage: return L("Go to Page…")
        case .nightMode: return L("Night Mode")
        case .canvasMode: return L("Canvas Mode")
        case .refWindow: return L("Reference Window")
        case .penSlot1: return String(format: L("Pen Slot %d"), 1)
        case .penSlot2: return String(format: L("Pen Slot %d"), 2)
        case .penSlot3: return String(format: L("Pen Slot %d"), 3)
        case .penSlot4: return String(format: L("Pen Slot %d"), 4)
        case .eraser: return L("Eraser")
        case .pageTurn: return L("Page Turn")
        case .write: return L("Write")
        case .aiPanel: return L("AI Panel")
        case .agentPanel: return L("Agent Panel")
        case .snipToAI: return L("Snip to AI")
        case .highlightSelection: return L("Highlight Selection")
        case .underlineSelection: return L("Underline Selection")
        case .boxSelection: return L("Box Selection")
        case .noteFromSelection: return L("Note from Selection")
        case .keyEraser: return L("Eraser ⇄ Write")
        case .keyWrite: return L("Write")
        case .keyPageTurn: return L("Page Turn ⇄ Write")
        case .keyLasso: return L("Lasso Select ⇄ Text Selection")
        case .keyLocalInk: return L("Local Pen ⇄ Text Selection")
        case .keyTextSelect: return L("Text Selection")
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .toggleSidebar: return KeyCombo("b", .command)
        case .toggleInspector: return KeyCombo("i", .command)
        case .zoomIn: return KeyCombo("=", .command)
        case .zoomOut: return KeyCombo("-", .command)
        case .zoomFit: return KeyCombo("0", .command)
        case .addBookmark: return KeyCombo("d", .command)
        case .jumpBack: return KeyCombo("[", .command)
        case .jumpForward: return KeyCombo("]", .command)
        case .jumpHistory: return KeyCombo("j", [.command, .option])
        case .gotoPage: return KeyCombo("g", .control)   // ⌃G（用户 2026-09-21 指定）
        case .nightMode: return KeyCombo("n", [.command, .option])
        case .canvasMode: return KeyCombo("c", [.command, .option])
        case .refWindow: return KeyCombo("r", [.command, .option])
        case .penSlot1: return KeyCombo("1", .option)
        case .penSlot2: return KeyCombo("2", .option)
        case .penSlot3: return KeyCombo("3", .option)
        case .penSlot4: return KeyCombo("4", .option)
        case .eraser: return KeyCombo("e", .option)
        case .pageTurn: return KeyCombo("v", .option)
        case .write: return KeyCombo("b", .option)
        case .aiPanel: return KeyCombo("a", [.command, .shift])
        case .agentPanel: return KeyCombo("k", [.command, .shift])
        case .snipToAI: return KeyCombo("s", .option)
        case .highlightSelection: return KeyCombo("h")
        case .underlineSelection: return KeyCombo("h", .shift)    // ⇧H 画线（用户 2026-09-16：小写 h 铺色、大写 H 画线）
        case .boxSelection: return KeyCombo("h", .option)         // ⌥H 画框
        case .noteFromSelection: return KeyCombo("n")
        case .keyEraser: return KeyCombo("e")
        case .keyWrite: return KeyCombo("b")
        case .keyPageTurn: return KeyCombo("v")
        case .keyLasso: return KeyCombo("l")
        case .keyLocalInk: return KeyCombo("i")
        case .keyTextSelect: return KeyCombo("t")
        }
    }

    static func penSlot(_ i: Int) -> ShortcutAction {
        [.penSlot1, .penSlot2, .penSlot3, .penSlot4][i]
    }
}

/// 快捷键映射表：默认值 + 用户改动（`UserDefaults`，只存改过的那几条；空串 = 这个动作不设快捷键）。
/// 改动后发 `.shortcutsChanged`，主菜单据此重设各项的 key equivalent（`MainMenu.applyShortcuts`），
/// 阅读区监视器每次按键现查（`readerAction(for:)`）。
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()
    private static let key = "shortcutOverrides"

    @Published private(set) var overrides: [String: String]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    /// 这个动作当前的快捷键；nil = 用户清掉了。
    func combo(for a: ShortcutAction) -> KeyCombo? {
        guard let s = overrides[a.rawValue] else { return a.defaultCombo }
        return KeyCombo(storage: s)   // 空串 → nil = 无快捷键
    }

    func isDefault(_ a: ShortcutAction) -> Bool { overrides[a.rawValue] == nil }

    func set(_ c: KeyCombo?, for a: ShortcutAction) {
        if c == a.defaultCombo { overrides.removeValue(forKey: a.rawValue) }
        else { overrides[a.rawValue] = c?.storageString ?? "" }
        persist()
    }

    func reset(_ a: ShortcutAction) {
        guard overrides.removeValue(forKey: a.rawValue) != nil else { return }
        persist()
    }

    func resetAll() {
        guard !overrides.isEmpty else { return }
        overrides = [:]
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: Self.key)
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    }

    /// 阅读区监视器：按下的这组键对应哪个阅读区动作（无 → nil）。逐条比对——表就二十来行，不值得建反查表。
    func readerAction(for c: KeyCombo) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0.scope == .reader && combo(for: $0) == c }
    }

    /// 基础命令（不进映射表，改别的动作时不许撞上）：显示名用菜单里那几个词。
    static var reserved: [(combo: KeyCombo, name: String)] {
        [
            (KeyCombo("n", .command), L("New Window")),
            (KeyCombo("o", .command), L("Open PDF…")),
            (KeyCombo("t", .command), L("New Tab")),
            (KeyCombo("n", [.command, .control]), L("New Board")),
            (KeyCombo("w", .command), L("Close Tab")),
            (KeyCombo("w", [.command, .shift]), L("Close Window")),
            (KeyCombo("tab", .control), L("Next Tab")),
            (KeyCombo("tab", [.control, .shift]), L("Previous Tab")),
            (KeyCombo("z", .command), L("Undo")),
            (KeyCombo("z", [.command, .shift]), L("Redo")),
            (KeyCombo("x", .command), L("Cut")),
            (KeyCombo("c", .command), L("Copy")),
            (KeyCombo("v", .command), L("Paste")),
            (KeyCombo("a", .command), L("Select All")),
            (KeyCombo("f", .command), L("Find…")),
            (KeyCombo(",", .command), L("Settings…")),
            (KeyCombo("h", .command), L("Hide UniReader")),
            (KeyCombo("h", [.command, .option]), L("Hide Others")),
            (KeyCombo("q", .command), L("Quit UniReader")),
            (KeyCombo("m", .command), L("Minimize")),
        ] + (1...9).map { (KeyCombo("\($0)"), String(format: L("Pen Slot %d"), $0)) }
    }

    /// 这组键给 `a` 用会撞上谁：另一个动作的名字，或基础命令的名字。nil = 没冲突。
    func conflict(_ c: KeyCombo, for a: ShortcutAction) -> String? {
        if let r = Self.reserved.first(where: { $0.combo == c }) { return r.name }
        if let other = ShortcutAction.allCases.first(where: { $0 != a && combo(for: $0) == c }) { return other.title }
        return nil
    }
}

extension Notification.Name {
    /// 快捷键映射表变了（设置页改的）：主菜单重设 key equivalent。
    static let shortcutsChanged = Notification.Name("com.xvan.UniReader.shortcutsChanged")
}
