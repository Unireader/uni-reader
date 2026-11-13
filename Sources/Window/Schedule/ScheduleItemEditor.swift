import AppKit
import MarkdownEngine

/// 日程页右下：选中的那件事的详情，就地改、改了就存（`SCHEDULE-PLAN.md §4.3`）。
///
/// 从上到下：勾选框（打勾 = 做完）+ 标题、所属计划 · 谁排的；日期 / 时间 / 时长三行（左边标签右对齐）；
/// 说明——平时显示排好版的 Markdown（公式、列表、表格都排；`[[…]]` 显示成「书名 · 第 N 页」这样的链接，点了打开），
/// 点「编辑」才换成原文输入框（随内容长高）；做得怎样；删除 + 完成时间。
/// 全是系统标准控件（红线③），Markdown 只读显示走 `AgentMarkdownView`（红线②那一处例外）。
/// 排版同 `ExerciseNoteView`：按 frame 手摆，`height(forWidth:)` 与 `layout()` 走同一个 `arrange`。
@MainActor
final class ScheduleItemEditor: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    /// 改过的那件（整行；由页面写库）。
    var onChange: (LibScheduleItem) -> Void = { _ in }
    var onDelete: (String) -> Void = { _ in }
    /// 点了说明里的一个链接（原样的 `[[…]]` 里那串）。
    var onOpenLink: (String) -> Void = { _ in }
    /// 要的高度变了（页面重摆滚动视图）。
    var onHeightChange: () -> Void = {}

    private(set) var item: LibScheduleItem?

    private let doneCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleField = NSTextField()
    private let metaLabel = NSTextField(wrappingLabelWithString: "")
    private let lines = (0..<4).map { _ in NSBox() }
    private let dateLabel = ScheduleItemEditor.formLabel(L("Date"))
    private let timeLabel = ScheduleItemEditor.formLabel(L("Time"))
    private let durationLabel = ScheduleItemEditor.formLabel(L("Duration"))
    private let datePicker = NSDatePicker()
    private let noDateCheck = NSButton(checkboxWithTitle: L("No Date"), target: nil, action: nil)
    private let timeCheck = NSButton(checkboxWithTitle: L("At"), target: nil, action: nil)
    private let timePicker = NSDatePicker()
    private let durationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detailTitle = ScheduleItemEditor.sectionLabel(L("Details"))
    private let detailButton = NSButton()
    private let rendered = AgentMarkdownView(text: "", fontSize: 13, documentId: "schedule-detail")
    private let noDetail = NSTextField(labelWithString: L("No details yet."))
    private let detailScroll = NSScrollView()
    private let detailView = NSTextView()
    private let resultTitle = ScheduleItemEditor.sectionLabel(L("How It Went"))
    private let resultField = NSTextField()
    private let deleteButton = NSButton()
    private let doneAtLabel = NSTextField(labelWithString: "")

    /// 说明正在编辑（原文输入框开着）。
    private var editingDetail = false
    private var renderedSource: String?
    private var detailHeight: CGFloat = 96
    private var lastHeight: CGFloat = 0

    private static let durations = [0, 15, 30, 45, 60, 90, 120, 180, 240]
    private static let pad: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        doneCheck.target = self
        doneCheck.action = #selector(toggleDone)

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize + 3, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.placeholderString = L("Title")
        titleField.isBezeled = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.delegate = self
        titleField.usesSingleLineMode = false
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.lineBreakMode = .byWordWrapping

        metaLabel.font = .preferredFont(forTextStyle: .caption1)
        metaLabel.textColor = .labelColor
        for b in lines { b.boxType = .separator }

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .yearMonthDay
        datePicker.calendar = ScheduleDay.calendar
        datePicker.timeZone = .current
        datePicker.target = self
        datePicker.action = #selector(controlChanged)
        noDateCheck.target = self
        noDateCheck.action = #selector(controlChanged)
        timeCheck.target = self
        timeCheck.action = #selector(controlChanged)
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.calendar = ScheduleDay.calendar
        timePicker.timeZone = .current
        timePicker.target = self
        timePicker.action = #selector(controlChanged)
        for m in Self.durations {
            durationPopup.addItem(withTitle: m == 0 ? L("No Duration") : ScheduleFormat.duration(m))
            durationPopup.lastItem?.tag = m
        }
        durationPopup.target = self
        durationPopup.action = #selector(controlChanged)
        durationPopup.toolTip = L("How long it should take")

        detailButton.bezelStyle = .push
        detailButton.controlSize = .small
        detailButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailButton.target = self
        detailButton.action = #selector(toggleDetailEditing)
        rendered.onHeightChange = { [weak self] in self?.heightMayChange() }
        rendered.openLink = { [weak self] link in
            guard let t = MarkdownDisplayRenderer.wikiLinkTarget(link) else { return false }
            self?.onOpenLink(t)
            return true
        }
        noDetail.font = .preferredFont(forTextStyle: .callout)
        noDetail.textColor = .labelColor

        detailView.isRichText = false
        detailView.font = .systemFont(ofSize: 13)
        detailView.textColor = .labelColor
        detailView.isAutomaticQuoteSubstitutionEnabled = false
        detailView.isAutomaticDashSubstitutionEnabled = false
        detailView.isAutomaticTextReplacementEnabled = false
        detailView.allowsUndo = true
        detailView.delegate = self
        detailView.isVerticallyResizable = true
        detailView.isHorizontallyResizable = false
        detailView.autoresizingMask = [.width]
        detailView.textContainer?.widthTracksTextView = true
        detailView.textContainerInset = NSSize(width: 4, height: 6)
        detailScroll.documentView = detailView
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.borderType = .bezelBorder

        resultField.placeholderString = L("When it’s done, a line on how it went (agents use it to adjust the plan)")
        resultField.delegate = self
        resultField.font = .systemFont(ofSize: 13)
        resultField.usesSingleLineMode = false
        resultField.cell?.wraps = true
        resultField.cell?.isScrollable = false
        resultField.lineBreakMode = .byWordWrapping

        deleteButton.bezelStyle = .push
        deleteButton.title = L("Delete…")
        deleteButton.target = self
        deleteButton.action = #selector(deleteItem)
        doneAtLabel.font = .preferredFont(forTextStyle: .caption1)
        doneAtLabel.textColor = .labelColor
        doneAtLabel.alignment = .right

        for v in [doneCheck, titleField, metaLabel, dateLabel, datePicker, noDateCheck, timeLabel, timeCheck, timePicker,
                  durationLabel, durationPopup, detailTitle, detailButton, rendered, noDetail, detailScroll,
                  resultTitle, resultField, deleteButton, doneAtLabel] as [NSView] + lines {
            addSubview(v)
        }
        refreshDetailControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }   // 放在滚动视图里时从顶上排起

    private static func formLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: NSFont.systemFontSize)
        f.textColor = .labelColor
        f.alignment = .right
        return f
    }

    private static func sectionLabel(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        f.textColor = .labelColor
        return f
    }

    /// 这个文字框此刻是不是正在打字（打字时库里重读回来的值不往框里填，免得吞字）。
    private func editing(_ field: NSTextField) -> Bool {
        guard let fr = window?.firstResponder as? NSTextView, fr.isFieldEditor else { return false }
        return (fr.delegate as? NSTextField) === field
    }

    // MARK: 显示

    /// 显示一件（nil = 清空）。同一件重读回来时只更新没在打字的框；换了一件先把上一件存下、收起说明的输入框。
    func show(_ m: LibScheduleItem?, plan: LibSchedulePlan?) {
        let same = m?.id == item?.id
        if !same {
            commit()
            if editingDetail { editingDetail = false }
        }
        item = m
        guard let m else { return }
        if !same || !editing(titleField) { titleField.stringValue = m.title }
        if !same || !editing(resultField) { resultField.stringValue = m.result }
        doneCheck.state = m.isDone ? .on : .off
        doneCheck.toolTip = m.isDone ? L("Mark as Not Done") : L("Mark as Done")
        noDateCheck.state = m.day.isEmpty ? .on : .off
        datePicker.isEnabled = !m.day.isEmpty
        datePicker.dateValue = ScheduleDay.date(m.day) ?? ScheduleDay.date(ScheduleDay.today()) ?? Date()
        timeCheck.state = m.startMin >= 0 ? .on : .off
        timePicker.isEnabled = m.startMin >= 0
        timePicker.dateValue = Self.timeDate(m.startMin >= 0 ? m.startMin : 9 * 60)
        if durationPopup.indexOfItem(withTag: m.durationMin) < 0 {
            // 不在常用时长里（Agent 给的 50 分钟这类）：临时加一项
            durationPopup.addItem(withTitle: ScheduleFormat.duration(m.durationMin))
            durationPopup.lastItem?.tag = m.durationMin
        }
        durationPopup.selectItem(withTag: m.durationMin)
        var meta: [String] = []
        if let plan { meta.append(String(format: L("Plan: %@"), plan.title)) }
        if !m.agent.isEmpty { meta.append(String(format: L("Planned by %@"), m.agent)) }
        metaLabel.stringValue = meta.joined(separator: " · ")
        metaLabel.isHidden = meta.isEmpty
        doneAtLabel.stringValue = m.doneAt.map { String(format: L("Done %@"), ScheduleFormat.doneAt($0)) } ?? ""
        if !editingDetail {
            if !same || detailView.string != m.detail { detailView.string = m.detail }
            renderDetail(m.detail)
        }
        refreshDetailControls()
        heightMayChange()
    }

    private func renderDetail(_ text: String) {
        guard text != renderedSource else { return }
        renderedSource = text
        rendered.update(text: ScheduleText.displayMarkdown(text, scheme: MarkdownDisplayRenderer.wikiLinkScheme) { name, page in
            String(format: L("%@ · p. %d"), name, page)
        })
    }

    private func refreshDetailControls() {
        let has = !(item?.detail.isEmpty ?? true)
        rendered.isHidden = editingDetail || !has
        noDetail.isHidden = editingDetail || has
        detailScroll.isHidden = !editingDetail
        detailButton.title = editingDetail ? L("Done") : (has ? L("Edit") : L("Add Details"))
    }

    private static func timeDate(_ minute: Int) -> Date {
        let cal = ScheduleDay.calendar
        let base = cal.startOfDay(for: Date())
        return cal.date(byAdding: .minute, value: minute, to: base) ?? base
    }

    private static func minute(of date: Date) -> Int {
        let c = ScheduleDay.calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: 存

    /// 把控件里的值写回（有变化才发）。换选中 / 页面拆掉之前也调。
    func commit() {
        guard var m = item else { return }
        let t = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { m.title = t }
        m.day = noDateCheck.state == .on ? "" : ScheduleDay.string(datePicker.dateValue)
        m.startMin = timeCheck.state == .on ? Self.minute(of: timePicker.dateValue) : -1
        m.durationMin = durationPopup.selectedItem?.tag ?? 0
        if editingDetail { m.detail = detailView.string.trimmingCharacters(in: .whitespacesAndNewlines) }
        m.result = resultField.stringValue
        guard m != item else { return }
        item = m
        onChange(m)
    }

    @objc private func controlChanged() {
        datePicker.isEnabled = noDateCheck.state != .on
        timePicker.isEnabled = timeCheck.state == .on
        commit()
    }

    @objc private func toggleDone() {
        commit()
        guard var m = item else { return }
        m.doneAt = doneCheck.state == .on ? Date() : nil
        item = m
        onChange(m)
    }

    @objc private func toggleDetailEditing() {
        guard let m = item else { return }
        if editingDetail {
            commit()
            editingDetail = false
            renderDetail(item?.detail ?? "")
            refreshDetailControls()
            heightMayChange()
            window?.makeFirstResponder(nil)
        } else {
            editingDetail = true
            detailView.string = m.detail
            detailView.undoManager?.removeAllActions()
            fitDetailHeight()
            refreshDetailControls()
            heightMayChange()
            window?.makeFirstResponder(detailView)
            detailView.setSelectedRange(NSRange(location: (detailView.string as NSString).length, length: 0))
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
        heightMayChange()   // 标题 / 结果折行了几行
    }
    func controlTextDidChange(_ obj: Notification) { heightMayChange() }
    func textDidEndEditing(_ notification: Notification) { commit() }   // 输入框照旧开着，字先存下
    func textDidChange(_ notification: Notification) { fitDetailHeight() }

    /// Esc / ⌘Return：收起说明的输入框（字已经存了，要改回去用 ⌘Z）。
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSTextView.complete(_:)) {
            if editingDetail { toggleDetailEditing() }
            return true
        }
        return false
    }

    /// 输入框随内容长高：约四行起步，最多 320，超出框内滚。
    private func fitDetailHeight() {
        guard let lm = detailView.layoutManager, let tc = detailView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = min(320, max(96, lm.usedRect(for: tc).height + 14))
        if abs(h - detailHeight) > 0.5 { detailHeight = h; heightMayChange() }
    }

    @objc private func deleteItem() {
        guard let m = item else { return }
        onDelete(m.id)
    }

    // MARK: 排版

    private func heightMayChange() {
        needsLayout = true
        let h = height(forWidth: bounds.width)
        if abs(h - lastHeight) > 0.5 { lastHeight = h; onHeightChange() }
    }

    func height(forWidth w: CGFloat) -> CGFloat { arrange(width: w, apply: false) }

    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, apply: true)
    }

    private func fieldHeight(_ f: NSTextField, width: CGFloat, min minH: CGFloat) -> CGFloat {
        guard let cell = f.cell?.copy() as? NSCell else { return minH }
        cell.stringValue = f.stringValue.isEmpty ? (f.placeholderString ?? " ") : f.stringValue
        let h = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
        return max(minH, h)
    }

    private func arrange(width w: CGFloat, apply: Bool) -> CGFloat {
        func put(_ v: NSView, _ r: NSRect) { if apply { v.frame = r.integral } }
        let pad = Self.pad
        let inner = max(0, w - pad * 2)
        var y: CGFloat = 14

        // 勾选框 + 标题（折行）
        let check = doneCheck.fittingSize
        let tx = pad + check.width + 6
        let tw = max(0, w - tx - pad)
        let th = fieldHeight(titleField, width: tw, min: 24)
        put(doneCheck, NSRect(x: pad, y: y + 3, width: check.width, height: check.height))
        put(titleField, NSRect(x: tx - 2, y: y, width: tw + 2, height: th))
        y += th + 4
        if !metaLabel.isHidden {
            let mh = ceil(metaLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: tw, height: .greatestFiniteMagnitude)).height ?? 16)
            put(metaLabel, NSRect(x: tx, y: y, width: tw, height: mh))
            y += mh + 4
        }
        y += 8
        put(lines[0], NSRect(x: pad, y: y, width: inner, height: 1))
        y += 12

        // 日期 / 时间 / 时长：标签右对齐成一列
        let labelW = ([dateLabel, timeLabel, durationLabel].map { ceil($0.intrinsicContentSize.width) }.max() ?? 40) + 4
        let cx = pad + labelW + 10
        func row(_ label: NSTextField, _ controls: [NSControl]) {
            let rowH: CGFloat = 26
            let lh = label.intrinsicContentSize.height
            put(label, NSRect(x: pad, y: y + (rowH - lh) / 2, width: labelW, height: lh))
            var x = cx
            for c in controls {
                let s = c.fittingSize
                put(c, NSRect(x: x, y: y + (rowH - s.height) / 2, width: s.width, height: s.height))
                x += s.width + 8
            }
            y += rowH + 6
        }
        row(dateLabel, [datePicker, noDateCheck])
        row(timeLabel, [timeCheck, timePicker])
        row(durationLabel, [durationPopup])
        y += 4
        put(lines[1], NSRect(x: pad, y: y, width: inner, height: 1))
        y += 12

        // 说明：标题 + 右边「编辑 / 完成」，下面是排好版的说明或原文输入框
        let bs = detailButton.fittingSize
        let dh = detailTitle.intrinsicContentSize.height
        put(detailTitle, NSRect(x: pad, y: y + (bs.height - dh) / 2, width: max(0, inner - bs.width - 8), height: dh))
        put(detailButton, NSRect(x: w - pad - bs.width, y: y, width: bs.width, height: bs.height))
        y += bs.height + 6
        if !rendered.isHidden {
            let h = rendered.intrinsicContentSize.height
            put(rendered, NSRect(x: pad, y: y, width: inner, height: h))
            y += h + 10
        }
        if !noDetail.isHidden {
            let h = noDetail.intrinsicContentSize.height
            put(noDetail, NSRect(x: pad, y: y, width: inner, height: h))
            y += h + 10
        }
        if !detailScroll.isHidden {
            put(detailScroll, NSRect(x: pad, y: y, width: inner, height: detailHeight))
            y += detailHeight + 10
        }
        put(lines[2], NSRect(x: pad, y: y, width: inner, height: 1))
        y += 12

        // 做得怎样
        let rh = resultTitle.intrinsicContentSize.height
        put(resultTitle, NSRect(x: pad, y: y, width: inner, height: rh))
        y += rh + 6
        let fh = fieldHeight(resultField, width: inner - 4, min: 40) + 4
        put(resultField, NSRect(x: pad, y: y, width: inner, height: fh))
        y += fh + 12
        put(lines[3], NSRect(x: pad, y: y, width: inner, height: 1))
        y += 12

        // 删除 + 完成时间
        let ds = deleteButton.fittingSize
        put(deleteButton, NSRect(x: pad, y: y, width: ds.width, height: ds.height))
        let lh = doneAtLabel.intrinsicContentSize.height
        put(doneAtLabel, NSRect(x: pad + ds.width + 8, y: y + (ds.height - lh) / 2, width: max(0, inner - ds.width - 8), height: lh))
        y += ds.height + 14
        return y
    }
}
