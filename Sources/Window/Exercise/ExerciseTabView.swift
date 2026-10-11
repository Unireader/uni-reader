import AppKit
import Combine

/// 一个习题标签在阅读窗格里的样子（`EXERCISE-PLAN.md §4.2`）：顶上一条（范围名 + 进度 + 「练习 / 列表」），
/// 下面是练习页或列表页。窗格切标签时整个拆掉重建，练到哪了在 `ExerciseDeck.shared` 里。
@MainActor
final class ExerciseTabView: NSView {
    let scope: ExerciseScope
    private let workspace: WorkspaceManager
    private let deck: ExerciseDeck
    /// 「到 PDF 原页」（窗格接 `AppDelegate.showDocument` + 跳页）。
    var onOpenSource: (Exercise) -> Void = { _ in }
    /// 顶部让开工具栏的高度（由窗格设）。
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }

    private let header = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(labels: [L("Practice"), L("List")], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    /// 筛选（用户 2026-10-11 要的）：可以组合出「第二章的错题」「这本书还没做过的题」。
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 全部重做（用户 2026-10-11 要的批量重做）：当前这一组（范围 + 筛选）显示着作答的题都当没答过，从第一题练起。
    private let redoAllButton = NSButton()
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
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        progressLabel.font = .preferredFont(forTextStyle: .caption1)
        progressLabel.textColor = .labelColor
        progressLabel.lineBreakMode = .byTruncatingTail
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        for f in ExerciseFilter.allCases {
            filterPopup.addItem(withTitle: Self.filterTitle(f))
            filterPopup.lastItem?.tag = f.rawValue
        }
        filterPopup.selectItem(withTag: deck.filter.rawValue)
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        filterPopup.contentTintColor = .labelColor
        redoAllButton.bezelStyle = .push
        redoAllButton.title = L("Redo All Questions")
        redoAllButton.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        redoAllButton.imagePosition = .imageLeading
        redoAllButton.contentTintColor = .labelColor
        redoAllButton.toolTip = L("Do every question in this list again. Your earlier answers stay in the practice history.")
        redoAllButton.target = self
        redoAllButton.action = #selector(redoAll)
        separator.boxType = .separator
        for v in [practice, list, header, titleLabel, progressLabel, redoAllButton, filterPopup, modeControl, separator] as [NSView] {
            addSubview(v)
        }

        practice.onOpenSource = { [weak self] e in self?.onOpenSource(e) }
        practice.onChange = { [weak self] in self?.syncHeader() }
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
                self.filterPopup.selectItem(withTag: self.deck.filter.rawValue)
                self.practice.show()
                self.list.reload()
                self.syncHeader()
            }
            .store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    private func syncHeader() {
        titleLabel.stringValue = workspace.exerciseScopeTitle(scope)
        let n = deck.items.count
        let s = deck.sessionSummary
        var parts = [String(format: L("%d questions"), n)]
        if s.done > 0 { parts.append(String(format: L("this round: %d done, %d right"), s.done, s.correct)) }
        progressLabel.stringValue = parts.joined(separator: " · ")
        redoAllButton.isEnabled = deck.hasShownAnswers
    }

    @objc private func redoAll() {
        redo(deck.items.map(\.id), from: 0)
    }

    /// 重做这几道题，切到练习页、从第 `row` 题开始。
    private func redo(_ ids: [String], from row: Int) {
        deck.redo(ids)
        deck.index = min(row, max(0, deck.items.count - 1))
        setMode(.practice)
        practice.restart()
        list.reload()
        syncHeader()
    }

    private static func filterTitle(_ f: ExerciseFilter) -> String {
        switch f {
        case .all: return L("All")
        case .unanswered: return L("Not Done Yet")
        case .wrong: return L("Mistakes")
        case .starred: return L("Starred")
        }
    }

    @objc private func filterChanged() {
        deck.setFilter(ExerciseFilter(rawValue: filterPopup.selectedTag()) ?? .all)
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
        filterPopup.sizeToFit()
        let fw = filterPopup.frame.width
        filterPopup.frame = NSRect(x: modeControl.frame.minX - 10 - fw, y: topInset + (headerH - filterPopup.frame.height) / 2,
                                   width: fw, height: filterPopup.frame.height)
        redoAllButton.sizeToFit()
        let rw = redoAllButton.frame.width
        redoAllButton.frame = NSRect(x: filterPopup.frame.minX - 10 - rw, y: topInset + (headerH - redoAllButton.frame.height) / 2,
                                     width: rw, height: redoAllButton.frame.height)
        let tw = max(0, redoAllButton.frame.minX - pad * 2)
        titleLabel.frame = NSRect(x: pad, y: topInset + 5, width: tw, height: 19)
        progressLabel.frame = NSRect(x: pad, y: topInset + 24, width: tw, height: 14)
        separator.frame = NSRect(x: 0, y: header.frame.maxY, width: b.width, height: 1)
        let body = NSRect(x: 0, y: separator.frame.maxY, width: b.width, height: max(0, b.height - separator.frame.maxY))
        practice.frame = body
        list.frame = body
    }
}
