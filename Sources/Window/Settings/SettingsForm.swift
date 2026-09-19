import AppKit

// 设置页的排版（AppKit 版，替代 SwiftUI `Form(.grouped)`；方案定的是 `NSGridView` 表单）：
// 一页 = 竖向滚动的一列「分组」，每组 = 粗体标题 + 两列网格（左列说明文字右对齐、右列控件）+ 灰色小字脚注。
// 全用系统标准控件，不画任何仿系统的底板。会随时间 / 状态变的那几组（内存台账、打开耗时、已连客户端…）
// 可以单独清空重排（`FormSection.rebuild`），不动别的组——别的组里可能有人正在输入。

enum FormMetrics {
    static let columnWidth: CGFloat = 540
    static let labelWidth: CGFloat = 200
    static var controlWidth: CGFloat { columnWidth - labelWidth - 10 }
}

/// 一组：标题 + 网格 + 脚注。
@MainActor
final class FormSection {
    let view = NSStackView()
    private let grid = NSGridView()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private var builder: ((FormSection) -> Void)?

    init(header: String?, footer: String?) {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        if let header {
            let h = NSTextField(labelWithString: header)
            h.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            view.addArrangedSubview(h)
        }
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.addColumn(with: [])
        grid.addColumn(with: [])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = FormMetrics.labelWidth
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        view.addArrangedSubview(grid)
        footerLabel.font = .preferredFont(forTextStyle: .caption1)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.preferredMaxLayoutWidth = FormMetrics.columnWidth
        setFooter(footer)
        view.addArrangedSubview(footerLabel)
        view.setCustomSpacing(6, after: grid)
    }

    func setFooter(_ s: String?) {
        footerLabel.stringValue = s ?? ""
        footerLabel.isHidden = (s ?? "").isEmpty
    }

    /// 一行：左边说明（可空）+ 右边控件。
    func row(_ label: String?, _ control: NSView) {
        let l: NSView = label.map { t -> NSView in
            let f = NSTextField(labelWithString: t)
            f.alignment = .right
            f.lineBreakMode = .byWordWrapping
            f.preferredMaxLayoutWidth = FormMetrics.labelWidth
            return f
        } ?? NSGridCell.emptyContentView
        grid.addRow(with: [l, control])
    }

    /// 左边说明有两行（主标题 + 灰色小字）的一行。
    func row(_ label: String, detail: String, _ control: NSView) {
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment = .trailing
        s.spacing = 2
        let a = NSTextField(labelWithString: label)
        a.alignment = .right
        let b = NSTextField(wrappingLabelWithString: detail)
        b.font = .preferredFont(forTextStyle: .caption1)
        b.textColor = .secondaryLabelColor
        b.alignment = .right
        b.preferredMaxLayoutWidth = FormMetrics.labelWidth
        s.addArrangedSubview(a)
        s.addArrangedSubview(b)
        grid.addRow(with: [s, control])
        grid.row(at: grid.numberOfRows - 1).yPlacement = .center
    }

    /// 占满两列的一行（长说明、代码片段、列表）。
    func full(_ v: NSView) {
        grid.addRow(with: [v, NSGridCell.emptyContentView])
        let r = grid.numberOfRows - 1
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: r, length: 1))
        grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .leading
    }

    /// 内容由 `build` 决定、可以整组重排的组（`rebuild()` 清空后再调一次 `build`）。
    func dynamic(_ build: @escaping (FormSection) -> Void) {
        builder = build
        build(self)
    }

    func rebuild() {
        while grid.numberOfRows > 0 { grid.removeRow(at: 0) }
        builder?(self)
    }

    // 控件小工具

    static func text(_ s: String, selectable: Bool = false, mono: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.isSelectable = selectable
        t.textColor = color
        if mono { t.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        t.preferredMaxLayoutWidth = FormMetrics.controlWidth
        return t
    }

    static func caption(_ s: String, width: CGFloat = FormMetrics.columnWidth) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .preferredFont(forTextStyle: .callout)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = width
        return t
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = spacing
        return s
    }
}

/// 设置的一页：竖向滚动、内容一列居中、宽度固定。
@MainActor
class SettingsPage: NSViewController {
    let stack = NSStackView()
    private var sections: [FormSection] = []
    private var timer: Timer?

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 24, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.widthAnchor.constraint(equalToConstant: FormMetrics.columnWidth),
        ])
        view = scroll
        build()
    }

    /// 子类在这里搭各组。
    func build() {}

    @discardableResult
    func section(_ header: String?, footer: String? = nil) -> FormSection {
        let s = FormSection(header: header, footer: footer)
        stack.addArrangedSubview(s.view)
        sections.append(s)
        return s
    }

    private var tick: (() -> Void)?

    /// 每秒刷新一次（只在这一页显示时跑）：设置窗不销毁，静态取值会一直是第一次打开时的快照。
    func everySecond(_ tick: @escaping () -> Void) { self.tick = tick }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard let tick, timer == nil else { return }
        tick()
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
    }
}

/// 设置页里的开关（勾选框），点了回调新状态。
final class FormCheckbox: NSButton {
    private var handler: (Bool) -> Void = { _ in }
    convenience init(_ title: String, on: Bool, _ h: @escaping (Bool) -> Void) {
        self.init(checkboxWithTitle: title, target: nil, action: nil)
        state = on ? .on : .off
        handler = h
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { handler(state == .on) }
}

/// 下拉选择：选项 = (显示名, 值)。
final class FormPopup<T: Equatable>: NSPopUpButton {
    private var values: [T] = []
    private var handler: (T) -> Void = { _ in }

    convenience init(_ options: [(String, T)], selected: T, _ h: @escaping (T) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        values = options.map(\.1)
        addItems(withTitles: options.map(\.0))
        select(selected)
        handler = h
        target = self
        action = #selector(fire)
    }

    func select(_ v: T) {
        if let i = values.firstIndex(of: v) { selectItem(at: i) }
    }

    @objc private func fire() {
        let i = indexOfSelectedItem
        if values.indices.contains(i) { handler(values[i]) }
    }
}

/// 普通按钮 + 闭包。
final class FormButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(_ title: String, _ h: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        bezelStyle = .push
        handler = h
        target = self
        action = #selector(fire)
    }
    @objc private func fire() { handler() }
}

/// 复制到剪贴板。
func copyToPasteboard(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}
