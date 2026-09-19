import AppKit
import Combine

/// 设置 › 快捷键：每个可改动作一行，点按钮进入录制，按下一组键就记下（`Shortcuts`）。
/// 基础命令（新建 / 打开 / 关闭 / 撤销 / 剪贴板 / 查找 / 退出…）与数字键选笔固定，不在这一页。
final class ShortcutsSettingsPage: SettingsPage {
    private let store = Shortcuts.shared
    private var bag = Set<AnyCancellable>()
    private var sections: [FormSection] = []
    private var defaultsSection: FormSection!
    /// 正在录制的那一行（同时只有一行）与它的键盘监视器。
    private var recording: ShortcutAction?
    private var monitor: Any?
    /// 每个动作最近一次录制出的问题（冲突 / 菜单键缺修饰键），显示在动作名下面。
    private var problems: [ShortcutAction: String] = [:]

    override func build() {
        for sec in ShortcutAction.Section.allCases {
            let footer = sec == .readerKeys
                ? L("Reader keys work while reading; they are ignored while typing in a text field or the AI panel. Keys 1–9 pick a pen and are fixed.")
                : nil
            let s = section(sec.title, footer: footer)
            s.dynamic { [weak self] s in
                for a in sec.actions { self?.buildRow(a, in: s) }
            }
            sections.append(s)
        }
        defaultsSection = section(nil, footer: L("Click a shortcut to change it, then press the new keys. Esc cancels; Delete removes the shortcut. Basic commands (New, Open, Close, Undo, Copy, Paste, Find, Quit…) are fixed."))
        defaultsSection.dynamic { [weak self] s in
            guard let self else { return }
            let reset = FormButton(L("Reset All Shortcuts")) { [weak self] in self?.store.resetAll() }
            reset.isEnabled = !self.store.overrides.isEmpty
            s.row(L("Defaults"), reset)
        }
        store.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildAll() }.store(in: &bag)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stop()
    }

    private func rebuildAll() {
        for s in sections { s.rebuild() }
        defaultsSection.rebuild()
    }

    /// 一行：动作名（下面可能有一行问题说明）+ 当前键（点它录制）+ 改过才出现的「恢复默认」。
    private func buildRow(_ a: ShortcutAction, in s: FormSection) {
        let title = recording == a ? L("Press keys…") : (store.combo(for: a)?.display ?? L("None"))
        let key = FormButton(title) { [weak self] in
            guard let self else { return }
            if self.recording == a { self.stop() } else { self.start(a) }
        }
        key.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        key.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        var controls: [NSView] = [key]
        if !store.isDefault(a) {
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil) ?? NSImage(),
                                 target: nil, action: nil)
            reset.toolTip = L("Reset to default")
            let acts = ButtonActions()
            acts.bind(reset) { [weak self] in self?.store.reset(a) }
            objc_setAssociatedObject(reset, &ButtonActions.key, acts, .OBJC_ASSOCIATION_RETAIN)
            controls.insert(reset, at: 0)
        }
        let row = FormSection.hstack(controls)
        if let p = problems[a] {
            s.row(a.title, detail: p, row)
        } else {
            s.row(a.title, row)
        }
    }

    /// 录制：本地监视器**吃掉**按下的键（返回 nil）——否则按 ⌘Q 这类组合键时菜单会先响应。
    private func start(_ a: ShortcutAction) {
        stop()
        problems[a] = nil
        recording = a
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return nil
        }
        rebuildAll()
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        rebuildAll()
    }

    private func handle(_ e: NSEvent) {
        guard let a = recording else { return }
        let mods = e.modifierFlags.intersection(KeyCombo.relevantMods)
        if e.keyCode == 53, mods.isEmpty { stop(); return }                         // Esc：取消
        if e.keyCode == 51, mods.isEmpty { store.set(nil, for: a); stop(); return }  // ⌫：清掉
        guard let c = KeyCombo(event: e) else { return }                           // 认不出的键：继续等
        if a.scope == .menu, !c.isMenuSafe {
            problems[a] = L("Menu shortcuts need ⌘, ⌥ or ⌃ (or a function key).")
        } else if let who = store.conflict(c, for: a) {
            problems[a] = String(format: L("Already used by “%@”."), who)
        } else {
            store.set(c, for: a)
        }
        stop()
    }
}
