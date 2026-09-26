import AppKit

/// 分页画板的页面尺寸（新建表单与「页面」弹层共用）：预设（A4 / A5 / Letter / 当前屏幕 / 自定义）× 横竖，
/// 下面一行宽 × 高可直接输入（画布点，1pt = 1/72 英寸；A4 = 595 × 842）。
/// 改预设 / 横竖 → 数字跟着变；手输数字 → 预设自动落到匹配的那项或「自定义」，横竖按宽高比。
/// 只有用户操作才回调 `onChange`；外部赋 `size` 不回调。
/// 给出两行视图（`presetRow` / `sizeRow`）由调用方各自摆放：表单里各占 `NSGridView` 一行，标签才对得齐。
final class BoardPageSizeControl: NSObject {
    var onChange: (CGSize) -> Void = { _ in }

    static let range: ClosedRange<Double> = 100...10000

    private let presets = BoardPageSize.allCases
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let orient = NSSegmentedControl(labels: [L("Portrait"), L("Landscape")], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var current = CGSize(width: 595, height: 842)
    let presetRow = NSStackView()
    let sizeRow = NSStackView()

    var isEnabled = true {
        didSet { for c in [popup, orient, widthField, heightField] as [NSControl] { c.isEnabled = isEnabled } }
    }

    private var screen: CGSize { NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800) }

    var size: CGSize {
        get { current }
        set { current = newValue; syncControls() }
    }

    override init() {
        super.init()

        for p in presets { popup.addItem(withTitle: p.label) }
        popup.addItem(withTitle: L("Custom Size"))
        popup.target = self
        popup.action = #selector(presetPicked)
        orient.target = self
        orient.action = #selector(orientPicked)
        presetRow.setViews([popup, orient], in: .leading)
        presetRow.spacing = 8

        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.allowsFloats = false   // 范围不放格式器里卡（超范围会弹错误提示），`readFields` 自己夹
        for f in [widthField, heightField] {
            f.formatter = fmt
            f.alignment = .right
            f.target = self
            f.action = #selector(fieldCommitted)
            f.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        widthField.placeholderString = L("Page Width")
        heightField.placeholderString = L("Page Height")
        let times = NSTextField(labelWithString: "×")
        let unit = NSTextField(labelWithString: "pt")
        sizeRow.setViews([widthField, times, heightField, unit], in: .leading)
        sizeRow.spacing = 6
        syncControls()
    }

    /// 把输入框里还没按回车的数字收进来（点「创建」前调用）。
    func commitEditing() {
        widthField.window?.makeFirstResponder(nil)
        readFields()
    }

    // MARK: 同步

    private func syncControls() {
        widthField.integerValue = Int(current.width.rounded())
        heightField.integerValue = Int(current.height.rounded())
        if current.width != current.height { orient.selectedSegment = current.width > current.height ? 1 : 0 }
        let portrait = CGSize(width: min(current.width, current.height), height: max(current.width, current.height))
        let hit = presets.firstIndex { p in
            let s = p.portrait(screen: screen)
            return abs(s.width - portrait.width) < 1 && abs(s.height - portrait.height) < 1
        }
        popup.selectItem(at: hit ?? presets.count)
    }

    private func oriented(_ s: CGSize) -> CGSize {
        let landscape = orient.selectedSegment == 1
        return (s.width > s.height) == landscape || s.width == s.height ? s : CGSize(width: s.height, height: s.width)
    }

    private func apply(_ s: CGSize) {
        guard s != current else { syncControls(); return }
        current = s
        syncControls()
        onChange(s)
    }

    // MARK: 动作

    @objc private func presetPicked() {
        let i = popup.indexOfSelectedItem
        guard presets.indices.contains(i) else {   // 「自定义」：数字不动，光标进宽度框
            widthField.window?.makeFirstResponder(widthField)
            return
        }
        apply(oriented(presets[i].portrait(screen: screen)))
    }

    @objc private func orientPicked() { apply(oriented(current)) }

    @objc private func fieldCommitted() { readFields() }

    private func readFields() {
        func clamp(_ v: Double, _ fallback: CGFloat) -> CGFloat {
            v > 0 ? CGFloat(min(max(v, Self.range.lowerBound), Self.range.upperBound)).rounded() : fallback
        }
        let s = CGSize(width: clamp(widthField.doubleValue, current.width),
                       height: clamp(heightField.doubleValue, current.height))
        apply(s)
    }
}
