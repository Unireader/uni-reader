import AppKit

/// 日程页左边的月历（`SCHEDULE-PLAN.md §4.1`）：顶上一行星期，下面 6 周 × 7 天；每天的格子里列出那天的事项
/// （定了时间的带时间，做完的划掉），放不下的写「还有 N 件」。
///
/// 一整个视图自己画（格子是内容排版，不是在仿系统控件；颜色全用系统语义色，深浅色自动跟）。
/// 点格子 = 选这一天；点格子里的一件事 = 选中它；双击格子空白处 = 往这一天加一件；
/// 一件事可以拖到别的格子（挪日子），右边列表里的事项也能拖进来。
@MainActor
final class ScheduleMonthView: NSView, NSDraggingSource {
    static let dragType = NSPasteboard.PasteboardType("com.xvan.UniReader.scheduleItem")

    var onSelectDay: (String) -> Void = { _ in }
    var onSelectItem: (_ id: String, _ day: String) -> Void = { _, _ in }
    var onDoubleClickDay: (String) -> Void = { _ in }
    var onDropItems: (_ ids: [String], _ day: String) -> Void = { _, _ in }

    private var month = ""
    private var days: [String] = []
    private var itemsByDay: [String: [LibScheduleItem]] = [:]
    private var selectedDay = ""
    private var selectedItem: String?
    private var today = ""
    private var firstWeekday = Calendar.current.firstWeekday
    /// 上一次画出来的每件事的位置（点击 / 拖动按它认）。
    private var itemRects: [(rect: NSRect, id: String, day: String)] = []
    /// 拖着东西经过的那一天（画个框）。
    private var dropDay: String?
    /// 按下时压着的那件事（拖出去用）。
    private var pressed: (id: String, day: String, at: NSPoint)?

    private let headerHeight: CGFloat = 24
    private let lineHeight: CGFloat = 17
    private let itemFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([Self.dragType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func show(month: String, days: [String], items: [String: [LibScheduleItem]], selectedDay: String,
              selectedItem: String?, today: String, firstWeekday: Int) {
        self.month = month
        self.days = days
        self.itemsByDay = items
        self.selectedDay = selectedDay
        self.selectedItem = selectedItem
        self.today = today
        self.firstWeekday = firstWeekday
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: 几何

    private var gridRect: NSRect {
        NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
    }

    private func cellRect(_ i: Int) -> NSRect {
        let g = gridRect
        let w = g.width / 7, h = g.height / 6
        let col = i % 7, row = i / 7
        let x0 = (CGFloat(col) * w).rounded(), x1 = (CGFloat(col + 1) * w).rounded()
        let y0 = (g.minY + CGFloat(row) * h).rounded(), y1 = (g.minY + CGFloat(row + 1) * h).rounded()
        return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func dayIndex(at p: NSPoint) -> Int? {
        guard gridRect.contains(p), days.count == 42 else { return nil }
        let g = gridRect
        let col = min(6, max(0, Int((p.x / g.width) * 7)))
        let row = min(5, max(0, Int(((p.y - g.minY) / g.height) * 6)))
        return row * 7 + col
    }

    // MARK: 画

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        itemRects.removeAll()
        drawWeekdayHeader()
        guard days.count == 42 else { return }
        for i in 0..<42 { drawCell(i) }
        // 格线：竖线 6 条、横线 6 条（最上一条与星期行之间）
        NSColor.separatorColor.setFill()
        for c in 1..<7 {
            let x = cellRect(c).minX
            NSRect(x: x, y: gridRect.minY, width: 1, height: gridRect.height).fill()
        }
        for r in 0..<6 {
            let y = cellRect(r * 7).minY
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
    }

    private func drawWeekdayHeader() {
        let symbols = ScheduleFormat.weekdaySymbols(firstWeekday: firstWeekday)
        let w = bounds.width / 7
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                                                     .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        for (i, s) in symbols.enumerated() {
            let r = NSRect(x: CGFloat(i) * w, y: 5, width: w, height: headerHeight - 6)
            (s as NSString).draw(in: r, withAttributes: attrs)
        }
    }

    private func drawCell(_ i: Int) {
        let r = cellRect(i)
        let day = days[i]
        let inMonth = ScheduleDay.month(of: day) == month
        if day == selectedDay {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            r.fill()
        } else if !inMonth {
            NSColor.underPageBackgroundColor.withAlphaComponent(0.35).setFill()
            r.fill()
        }
        if day == dropDay {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
            p.lineWidth = 2
            p.stroke()
        }
        // 日子：右上角；今天用强调色加粗，旁边一个小圆点
        let isToday = day == today
        let num = String(Int(day.suffix(2)) ?? 0)
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: isToday ? .bold : .regular),
            .foregroundColor: isToday ? NSColor.controlAccentColor : (inMonth ? NSColor.labelColor : NSColor.secondaryLabelColor),
        ]
        let ns = num as NSString
        let size = ns.size(withAttributes: numAttrs)
        let numRect = NSRect(x: r.maxX - 6 - size.width, y: r.minY + 4, width: size.width, height: size.height)
        ns.draw(in: numRect, withAttributes: numAttrs)
        if isToday {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: numRect.minX - 8, y: numRect.midY - 2.5, width: 5, height: 5)).fill()
        }
        // 事项
        let items = itemsByDay[day] ?? []
        guard !items.isEmpty else { return }
        let top = r.minY + 24
        let avail = r.maxY - 3 - top
        let fit = max(0, Int(avail / lineHeight))
        guard fit > 0 else { return }
        let shown = items.count > fit ? max(0, fit - 1) : items.count
        for (k, m) in items.prefix(shown).enumerated() {
            let lr = NSRect(x: r.minX + 3, y: top + CGFloat(k) * lineHeight, width: r.width - 6, height: lineHeight - 1)
            drawItem(m, in: lr)
            itemRects.append((lr, m.id, day))
        }
        if shown < items.count {
            let more = String(format: L("%d more"), items.count - shown)
            let lr = NSRect(x: r.minX + 6, y: top + CGFloat(shown) * lineHeight + 1, width: r.width - 12, height: lineHeight - 1)
            (more as NSString).draw(in: lr, withAttributes: [.font: itemFont, .foregroundColor: NSColor.labelColor])
        }
    }

    private func drawItem(_ m: LibScheduleItem, in lr: NSRect) {
        let selected = m.id == selectedItem
        if selected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: lr, xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: itemFont, .foregroundColor: color, .paragraphStyle: para]
        if m.isDone { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let mark = m.isDone ? "✓ " : "• "
        let time = ScheduleTime.string(m.startMin).map { "\($0) " } ?? ""
        let text = NSMutableAttributedString(string: mark, attributes: [.font: itemFont, .foregroundColor: color, .paragraphStyle: para])
        text.append(NSAttributedString(string: time + m.title, attributes: attrs))
        // 整串同一个段落样式（按字截断）：只给后半段的话会在词边界提前换行，第一行早早就截了
        text.draw(with: lr.insetBy(dx: 3, dy: 1), options: [.usesLineFragmentOrigin])
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = nil
        if let hit = itemRects.first(where: { $0.rect.contains(p) }) {
            pressed = (hit.id, hit.day, p)
            onSelectItem(hit.id, hit.day)
            return
        }
        guard let i = dayIndex(at: p) else { return }
        if event.clickCount == 2 { onDoubleClickDay(days[i]) } else { onSelectDay(days[i]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pr = pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - pr.at.x, p.y - pr.at.y) > 4 else { return }
        pressed = nil
        let pb = NSPasteboardItem()
        pb.setString(pr.id, forType: Self.dragType)
        let item = NSDraggingItem(pasteboardWriter: pb)
        let r = itemRects.first { $0.id == pr.id }?.rect ?? NSRect(x: p.x, y: p.y, width: 120, height: lineHeight)
        item.setDraggingFrame(r, contents: snapshot(of: r))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { pressed = nil }

    private func snapshot(of r: NSRect) -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: r) else { return nil }
        cacheDisplay(in: r, to: rep)
        let img = NSImage(size: r.size)
        img.addRepresentation(rep)
        return img
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    // MARK: 拖进来

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropDay = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropDay = nil; needsDisplay = true }
        let p = convert(sender.draggingLocation, from: nil)
        guard let i = dayIndex(at: p) else { return false }
        let ids = (sender.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.dragType) }
        guard !ids.isEmpty else { return false }
        onDropItems(ids, days[i])
        return true
    }

    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        let d = dayIndex(at: p).map { days[$0] }
        if d != dropDay { dropDay = d; needsDisplay = true }
        return d == nil ? [] : .move
    }
}

/// 日程界面共用的日期文字（随系统语言）。
enum ScheduleFormat {
    /// 星期的短名，按一周从哪天起排好（「一 二 三 …」/「Mon Tue …」）。
    static func weekdaySymbols(firstWeekday: Int) -> [String] {
        let cal = Calendar.current
        let s = cal.locale?.language.languageCode?.identifier == "zh"
            ? cal.veryShortStandaloneWeekdaySymbols : cal.shortStandaloneWeekdaySymbols
        guard s.count == 7 else { return s }
        let k = (firstWeekday - 1 + 7) % 7
        return Array(s[k...] + s[..<k])
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = ScheduleDay.calendar
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }
    private static let monthF = formatter("yyyyMMMM")
    private static let dayF = formatter("MMMdEEEE")
    private static let dayYearF = formatter("yyyyMMMdEEEE")
    private static let shortF = formatter("MMMd")
    private static let timeF: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// 「2026年11月」
    static func month(_ m: String) -> String {
        ScheduleDay.date(m + "-01").map { monthF.string(from: $0) } ?? m
    }

    /// 「11月14日 星期五」（不是今年的带上年份）。
    static func day(_ d: String, today: String = ScheduleDay.today()) -> String {
        guard let date = ScheduleDay.date(d) else { return d }
        return (d.prefix(4) == today.prefix(4) ? dayF : dayYearF).string(from: date)
    }

    /// 「今天」「明天」「昨天」，其余「11月14日」。
    static func relativeDay(_ d: String, today: String = ScheduleDay.today()) -> String {
        if d.isEmpty { return L("No Date") }
        switch ScheduleDay.days(from: today, to: d) {
        case 0?: return L("Today")
        case 1?: return L("Tomorrow")
        case .some(-1): return L("Yesterday")
        default: return ScheduleDay.date(d).map { shortF.string(from: $0) } ?? d
        }
    }

    /// 时长：「30 分钟」「1 小时 30 分钟」。
    static func duration(_ minutes: Int) -> String {
        guard minutes > 0 else { return "" }
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return String(format: L("%d min"), m) }
        return m == 0 ? String(format: L("%d hr"), h) : String(format: L("%d hr %d min"), h, m)
    }

    /// 做完的时间：「11月14日 11:20」。
    static func doneAt(_ date: Date) -> String {
        shortF.string(from: date) + " " + timeF.string(from: date)
    }

    /// 一件事下面那行小字：时间 · 时长 · 计划名（有哪样写哪样）。
    static func subtitle(_ m: LibScheduleItem, planTitle: String?, showDay: Bool, today: String) -> String {
        var parts: [String] = []
        if showDay { parts.append(relativeDay(m.day, today: today)) }
        if let t = ScheduleTime.string(m.startMin) { parts.append(t) }
        if m.durationMin > 0 { parts.append(duration(m.durationMin)) }
        if let p = planTitle, !p.isEmpty { parts.append(p) }
        return parts.joined(separator: " · ")
    }
}
