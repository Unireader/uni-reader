import AppKit
import Combine

/// 一个习题标签在阅读窗格里的样子（`EXERCISE-PLAN.md §4.2`）：顶上一条（进度 + 全部重做 + 重做上次做错的 +
/// 只看没做过 + 「练习 / 列表」），下面是练习页或列表页。窗格切标签时整个拆掉重建，练到哪了在 `ExerciseDeck.shared` 里。
/// 范围名不在这一条里写：窗口标题已经是它（`DocTabModel` 把它写进 `session.title`），再写一遍就重复了（用户 2026-10-11 指出）。
@MainActor
final class ExerciseTabView: NSView {
    let scope: ExerciseScope
    private let workspace: WorkspaceManager
    private let deck: ExerciseDeck
    /// 「到 PDF 原页」（窗格接 `AppDelegate.showDocument` + 跳页）。
    var onOpenSource: (Exercise) -> Void = { _ in }
    /// 这扇窗的 id（练习页「让 Agent 批改」用，窗格设）。
    var agentWindow: () -> UUID? = { nil }
    /// 顶部让开工具栏的高度（由窗格设）。
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    /// 底下浮着的标签栏占的高度（窗格给）：练习页的「上一题 / 下一题」摆在它上面，列表的最后几行能滚到它上面。
    var bottomInset: CGFloat = 0 {
        didSet {
            guard bottomInset != oldValue else { return }
            practice.bottomInset = bottomInset
            list.bottomInset = bottomInset
        }
    }

    private let header = NSVisualEffectView()
    private let progressLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(labels: [L("Practice"), L("List")], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    /// 只看没做过（开关，按下时高亮）。「哪一组题」都在侧栏里选，这里只管做题进度；错题本那一支不显示
    /// （错题都做过，`ExerciseDeck.offersUnansweredFilter`）。
    private let unansweredButton = NSButton()
    /// 全部重做（用户 2026-10-11 要的批量重做）：当前这一组（范围 + 筛选）显示着作答的题都当没答过，从第一题练起。
    /// 开着「重做上次做错的」时 = 按此刻的结果再挑一遍上次做错的（这一轮答对的不拉回来）。
    private let redoAllButton = NSButton()
    /// 重做上次做错的（开关，用户 2026-10-27 要的）：只留上一次结果是错的题，这一轮都重新作答；答对一次下次就不在了。
    /// 与「只看没做过」至多开一个（同一个 `ExerciseDeck.filter`）；哪一组都有，错题本里正好挑出还没做对的。
    private let lastWrongButton = NSButton()
    private let separator = NSBox()
    private let practice: ExercisePracticeView
    private let list: ExerciseListView
    private var bag = Set<AnyCancellable>()

    init(scope: ExerciseScope, workspace: WorkspaceManager) {
        self.scope = scope
        self.workspace = workspace
        deck = ExerciseDeck.shared(scope: scope, workspace: workspace)
        practice = ExercisePracticeView(deck: deck, workspace: workspace)
        list = ExerciseListView(deck: deck, workspace: workspace)
        super.init(frame: .zero)
        header.material = .headerView
        header.blendingMode = .withinWindow
        progressLabel.font = .preferredFont(forTextStyle: .body)
        progressLabel.textColor = .labelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        unansweredButton.bezelStyle = .push
        unansweredButton.setButtonType(.pushOnPushOff)
        unansweredButton.title = L("Not Done Only")
        unansweredButton.toolTip = L("Show only the questions you haven’t done yet.")
        unansweredButton.target = self
        unansweredButton.action = #selector(unansweredToggled)
        unansweredButton.isHidden = !deck.offersUnansweredFilter
        redoAllButton.bezelStyle = .push
        redoAllButton.title = L("Redo All Questions")
        redoAllButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        redoAllButton.imagePosition = .imageLeading
        redoAllButton.contentTintColor = .labelColor
        redoAllButton.toolTip = L("Do every question in this list again. Your earlier answers stay in the practice history.")
        redoAllButton.target = self
        redoAllButton.action = #selector(redoAll)
        lastWrongButton.bezelStyle = .push
        lastWrongButton.setButtonType(.pushOnPushOff)
        lastWrongButton.title = L("Redo Last Wrong")
        lastWrongButton.target = self
        lastWrongButton.action = #selector(lastWrongToggled)
        separator.boxType = .separator
        for v in [practice, list, header, progressLabel, redoAllButton, lastWrongButton, unansweredButton, modeControl,
                  separator] as [NSView] {
            addSubview(v)
        }

        practice.onOpenSource = { [weak self] e in self?.onOpenSource(e) }
        practice.onChange = { [weak self] in self?.syncHeader() }
        practice.agentWindow = { [weak self] in self?.agentWindow() }
        list.onOpenSource = { [weak self] e in self?.onOpenSource(e) }
        list.onPractice = { [weak self] i in
            guard let self else { return }
            self.deck.index = i
            self.setMode(.practice)
            self.practice.show()
        }
        list.onRedo = { [weak self] ids, row in self?.redo(ids, from: row) }
        applyMode()
        list.reload()

        // 库里的习题变了（Agent 导入 / 补答案、收藏、移出错题本、删）→ 快照就地刷新
        workspace.$exerciseRevision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.deck.reload()
                self.practice.show()
                self.list.reload()
                self.syncHeader()
            }
            .store(in: &bag)

        // 平板开着同一组题（`EXERCISE-PLAN.md §10.4`）：平板那边答了 / 翻了 / 重做了 / 换了筛选，这边跟着重画。
        // Mac 本机的改动这边自己已经画过了，不重复。
        ExerciseDeck.changed
            .filter { [weak self] in $0.origin == .pad && $0.deck === self?.deck }
            .sink { [weak self] _ in
                guard let self else { return }
                self.practice.show()
                self.list.reload()
                self.syncHeader()
            }
            .store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    private func syncHeader() {
        let n = deck.items.count
        let s = deck.sessionSummary
        var parts = [String(format: L("%d questions"), n)]
        if s.done > 0 { parts.append(String(format: L("this round: %d done, %d right"), s.done, s.correct)) }
        progressLabel.stringValue = parts.joined(separator: " · ")
        redoAllButton.isEnabled = deck.hasShownAnswers
        unansweredButton.state = deck.filter == .unanswered ? .on : .off   // 平板那边换了，这边跟着
        let wrongs = deck.lastWrongCount
        lastWrongButton.state = deck.filter == .lastWrong ? .on : .off
        lastWrongButton.isEnabled = deck.filter == .lastWrong || wrongs > 0   // 开着时总能关掉
        lastWrongButton.toolTip = L("Practice only the questions you got wrong last time, all ready to answer again. Get one right and it won’t come back next time.")
            + "\n" + String(format: L("Wrong last time here: %d"), wrongs)
    }

    @objc private func redoAll() {
        // 开着「重做上次做错的」：再挑一遍上次做错的（这一轮答对的就不在了），而不是把答对的也拉回来重做
        if deck.filter == .lastWrong {
            deck.startLastWrongRound()
            restartPractice()
            return
        }
        redo(deck.items.map(\.id), from: 0)
    }

    @objc private func lastWrongToggled() {
        deck.setFilter(lastWrongButton.state == .on ? .lastWrong : .all)
        if deck.filter == .lastWrong { restartPractice(); return }   // 开 = 重做一轮：到练习页，从第一道练起
        practice.show()
        list.reload()
        syncHeader()
    }

    /// 重做一轮之后（`deck.index` 已挪到第一道）：切到练习页、从头计时重画。
    private func restartPractice() {
        setMode(.practice)
        practice.restart()
        list.reload()
        syncHeader()
    }

    /// 重做这几道题，切到练习页、从第 `row` 题开始。
    private func redo(_ ids: [String], from row: Int) {
        deck.redo(ids)
        deck.index = min(row, max(0, deck.items.count - 1))
        restartPractice()
    }

    @objc private func unansweredToggled() {
        deck.setFilter(unansweredButton.state == .on ? .unanswered : .all)
        practice.show()
        list.reload()
        syncHeader()
    }

    @objc private func modeChanged() {
        setMode(ExerciseDeck.Mode(rawValue: modeControl.selectedSegment) ?? .practice)
    }

    private func setMode(_ m: ExerciseDeck.Mode) {
        deck.mode = m
        applyMode()
    }

    private func applyMode() {
        modeControl.selectedSegment = deck.mode.rawValue
        practice.isHidden = deck.mode != .practice
        list.isHidden = deck.mode != .list
        if deck.mode == .list { list.reload() } else { practice.takeFocus() }
        syncHeader()
    }

    override func layout() {
        super.layout()
        let b = bounds
        let headerH: CGFloat = 44
        header.frame = NSRect(x: 0, y: 0, width: b.width, height: topInset + headerH)
        let pad: CGFloat = 16
        modeControl.sizeToFit()
        let mw = modeControl.frame.width
        modeControl.frame = NSRect(x: b.width - pad - mw, y: topInset + (headerH - modeControl.frame.height) / 2,
                                   width: mw, height: modeControl.frame.height)
        // 往左依次排：只看没做过（错题本里不显示）、重做上次做错的、全部重做
        var right = modeControl.frame.minX
        for b in [unansweredButton, lastWrongButton, redoAllButton] where !b.isHidden {
            b.sizeToFit()
            let bw = b.frame.width
            b.frame = NSRect(x: right - 10 - bw, y: topInset + (headerH - b.frame.height) / 2, width: bw, height: b.frame.height)
            right = b.frame.minX
        }
        let tw = max(0, redoAllButton.frame.minX - pad * 2)
        let ph = progressLabel.intrinsicContentSize.height
        progressLabel.frame = NSRect(x: pad, y: topInset + (headerH - ph) / 2, width: tw, height: ph)
        separator.frame = NSRect(x: 0, y: header.frame.maxY, width: b.width, height: 1)
        let body = NSRect(x: 0, y: separator.frame.maxY, width: b.width, height: max(0, b.height - separator.frame.maxY))
        practice.frame = body
        list.frame = body
    }
}
