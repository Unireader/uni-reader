import AppKit

/// 离屏验证 Agent 面板的**权限请求卡片**布局（`AgentChatNSView.refreshPermissions` / `fitPermissions`）。
/// 跑：`swift spike/agent-permission-card-test.swift`
///
/// 这里是同款装配的第二份实现（视图那边改了要同步这边）。起因（2026-09-26 用户报「元素全挤在一行」）：
/// 旧写法 `box.contentView = stack`，box 的内容视图走 autoresizing，`fittingSize` 只算出标题一行高（14pt），
/// 详情和按钮全叠在标题上。盯四件事：
///  1. 卡片高度装得下全部内容：标题 / 详情 / 按钮行上下不重叠、都不被压成 0 高、都在卡片框里；
///  2. 按钮不超出卡片右边——放不下时要改竖排；
///  3. 宽度从窄到宽都对（Inspector 最窄 300pt → 面板里卡片宽 276pt）；
///  4. 不出约束冲突（`permissions` 是按 frame 摆的，又挂了一条宽度约束）。

_ = NSApplication.shared
UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutLogUnsatisfiable")

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String) {
    checks += 1
    if !ok { failures += 1; print("  ✗ \(what)") }
}

struct Ask { let title: String; let detail: String; let options: [String] }

final class Harness {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 900))
    let permissions = NSStackView()
    var permissionLabels: [NSTextField] = []
    var permissionButtonRows: [(row: NSStackView, spacer: NSView)] = []
    lazy var permissionsWidth = permissions.widthAnchor.constraint(equalToConstant: 0)
    var cards: [(box: NSBox, rows: [NSView], buttons: [NSView])] = []

    init() {
        permissions.orientation = .vertical
        permissions.alignment = .leading
        permissions.spacing = 8
        host.addSubview(permissions)
    }

    func refresh(_ asks: [Ask]) {
        for v in permissions.arrangedSubviews { permissions.removeArrangedSubview(v); v.removeFromSuperview() }
        permissionLabels = []
        permissionButtonRows = []
        cards = []
        permissionsWidth.isActive = !asks.isEmpty
        for ask in asks {
            let box = NSBox()
            box.titlePosition = .noTitle
            let title = NSTextField(wrappingLabelWithString: "Allow “\(ask.title)”?")
            title.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
            var rows: [NSView] = [title]
            var labels = [title]
            if !ask.detail.isEmpty {
                let d = NSTextField(wrappingLabelWithString: ask.detail)
                d.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                d.maximumNumberOfLines = 5
                rows.append(d)
                labels.append(d)
            }
            let spacer = NSView()
            var buttons: [NSView] = [spacer]
            for o in ask.options.reversed() {
                let b = NSButton(title: o, target: nil, action: nil)
                b.bezelStyle = .push
                buttons.append(b)
            }
            let br = NSStackView(views: buttons)
            br.spacing = 6
            rows.append(br)
            let stack = NSStackView(views: rows)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView()
            content.addSubview(stack)
            box.contentView = content
            content.translatesAutoresizingMaskIntoConstraints = false
            permissions.addArrangedSubview(box)
            var cs: [NSLayoutConstraint] = [
                content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
                content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
                content.topAnchor.constraint(equalTo: box.topAnchor, constant: 5),
                content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -5),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
                box.widthAnchor.constraint(equalTo: permissions.widthAnchor),
                br.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ]
            cs += labels.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) }
            for l in labels { l.setContentCompressionResistancePriority(.required, for: .vertical) }
            NSLayoutConstraint.activate(cs)
            permissionLabels += labels
            permissionButtonRows.append((br, spacer))
            cards.append((box, rows, Array(buttons.dropFirst())))
        }
    }

    func fit(width: CGFloat) {
        permissions.frame.size.width = width
        permissionsWidth.constant = width
        let inner = width - 10 - 16
        for l in permissionLabels where l.preferredMaxLayoutWidth != inner { l.preferredMaxLayoutWidth = inner }
        for (row, spacer) in permissionButtonRows {
            let buttons = row.arrangedSubviews.filter { $0 !== spacer }
            let need = buttons.reduce(0) { $0 + $1.fittingSize.width } + row.spacing * CGFloat(max(0, buttons.count - 1))
            let orientation: NSUserInterfaceLayoutOrientation = need <= inner ? .horizontal : .vertical
            guard row.orientation != orientation else { continue }
            row.orientation = orientation
            row.alignment = orientation == .vertical ? .width : .centerY
            spacer.isHidden = orientation == .vertical
        }
    }

    /// 同 `AgentChatNSView.layout()` 里那段：定宽 → 取 fittingSize → 摆 frame。
    func layout(panelWidth: CGFloat) {
        host.frame.size.width = panelWidth
        fit(width: panelWidth - 24)
        let ph = permissions.fittingSize.height
        permissions.frame = NSRect(x: 12, y: 100, width: panelWidth - 24, height: ph)
        host.layoutSubtreeIfNeeded()
    }
}

let longDetail = "diff --git a/notes/极限.md b/notes/极限.md\n+ 一行相当长的新增内容，会在窄面板里折好几行 and some English too\n+ two\n+ three\n+ four\n+ five\n+ six"
let asks = [
    Ask(title: "Edit /Users/someone/Documents/workspace/notes/very/long/path/极限与连续.md",
        detail: longDetail, options: ["Allow Once", "Always Allow", "Reject"]),
    Ask(title: "Run shell", detail: "", options: ["Allow once", "Allow always for this session", "Reject"]),
]

let h = Harness()
h.refresh(asks)
for panel in [300, 360, 460, 560] as [CGFloat] {
    h.layout(panelWidth: panel)
    let W = panel - 24
    check(abs(h.permissions.frame.width - W) < 0.5, "W=\(panel) 卡片区宽度 \(h.permissions.frame.width) ≠ \(W)")
    var prevBottom: CGFloat = .infinity   // host 不翻转：y 向上，第一张卡在最上面
    for (i, card) in h.cards.enumerated() {
        let boxR = card.box.convert(card.box.bounds, to: h.host)
        check(boxR.maxY <= prevBottom + 0.5, "W=\(panel) 卡片 \(i) 与上一张重叠")
        prevBottom = boxR.minY
        check(abs(boxR.width - W) < 0.5, "W=\(panel) 卡片 \(i) 宽 \(boxR.width) ≠ \(W)")
        let rs = card.rows.map { $0.convert($0.bounds, to: h.host) }
        for (j, r) in rs.enumerated() {
            check(r.height >= 5, "W=\(panel) 卡片 \(i) 第 \(j) 行被压扁（高 \(r.height)）")
            check(r.minY >= boxR.minY - 0.5 && r.maxY <= boxR.maxY + 0.5, "W=\(panel) 卡片 \(i) 第 \(j) 行超出卡片上下")
            if j > 0 { check(r.maxY <= rs[j - 1].minY + 0.5, "W=\(panel) 卡片 \(i) 第 \(j) 行与上一行重叠") }
        }
        for b in card.buttons {
            let r = b.convert(b.bounds, to: h.host)
            check(r.minX >= boxR.minX - 0.5 && r.maxX <= boxR.maxX + 0.5, "W=\(panel) 卡片 \(i) 按钮「\((b as! NSButton).title)」超出卡片左右")
            check(r.height >= 15, "W=\(panel) 卡片 \(i) 按钮「\((b as! NSButton).title)」被压扁")
        }
        let bs = card.buttons.map { $0.convert($0.bounds, to: h.host) }
        for x in 0..<bs.count { for y in (x + 1)..<bs.count {
            check(!bs[x].insetBy(dx: 0.5, dy: 0.5).intersects(bs[y].insetBy(dx: 0.5, dy: 0.5)), "W=\(panel) 卡片 \(i) 按钮互相重叠")
        } }
        let row = h.permissionButtonRows[i].row
        print("W=\(Int(panel)) 卡片\(i) 高 \(Int(boxR.height)) 按钮\(row.orientation == .horizontal ? "横排" : "竖排") 行高 \(rs.map { Int($0.height) })")
    }
    check(h.permissions.hasAmbiguousLayout == false, "W=\(panel) 布局有歧义")
}
// 从宽拖回窄，排法要跟着改回来
h.layout(panelWidth: 300)
check(h.permissionButtonRows[1].row.orientation == .vertical, "从宽拖回 300 后长选项那张没改回竖排")

print(failures == 0 ? "✅ \(checks) 项全部通过" : "❌ \(failures)/\(checks) 项失败")
exit(failures == 0 ? 0 : 1)
