import AppKit

/// 练习：一次一题（`EXERCISE-PLAN.md §4.2`）。
///
/// 题干 / 选项 / 解析走 Markdown 引擎只读渲染（`AgentMarkdownView`，带公式），其余全是标准控件。
/// 排版按 frame 手摆（同 `AgentRowView` 的做法）：一题里有好几块高度要等引擎排完才知道，
/// 每块报回新高度就整列重摆一次，简单可控，也不用操心约束激活的先后。
///
/// 填空 / 主观题（`EXERCISE-PLAN.md §11`）：选项那一块换成 `ExerciseFreeAnswerView`（输入框 + 手写小画板），
/// 交卷后程序判不了的由用户点「答对了 / 答错了」，或「让 Agent 批改」；判过的可以改判，后判的为准。
///
/// 「上一题 / 下一题」在滚动区外面、钉在底部一条（用户 2026-10-27：「要固定位置，不能随着内容变化显示高度」——
/// 原先排在题目内容最后，每题高度不同，按钮跟着上下跳）。底下浮着标签栏时摆在它上面（`bottomInset`，同日用户截图：
/// 胶囊压在这一条上）。
///
/// 「答对自动下一题」（用户 2026-11-02 要的开关，`EXERCISE-PLAN.md §17`）：底部那条正中一个复选框，本机记住、默认关。
/// 开着时这一轮刚交的作答判为对（程序判对，或自己点「答对了」）→ 停一下让人看到绿勾 → 翻到下一题；判错停在这一题看解析。
///
/// 键盘：A~H 选、Return 提交 / 下一题、← → 上一题 / 下一题；填空 / 主观题 ⌘Return 提交。
@MainActor
final class ExercisePracticeView: NSView {
    private let deck: ExerciseDeck
    private weak var workspace: WorkspaceManager?
    /// 「到 PDF 原页」（窗格那边接 `AppDelegate.showDocument`）。
    var onOpenSource: (Exercise) -> Void = { _ in }
    /// 题号 / 作答变了（顶栏那行进度跟着刷）。
    var onChange: () -> Void = {}
    /// 这扇阅读窗口的 id（「让 Agent 批改」往这扇窗的 Agent 页发；拿不到 = 不显示那个按钮）。
    var agentWindow: () -> UUID? = { nil }

    private let scroll = NSScrollView()
    private let doc = FlippedDocView()
    private let metaLabel = NSTextField(labelWithString: "")
    private let starButton = NSButton()
    private let tagsButton = NSButton()
    private let originalButton = NSButton()
    private let sourceButton = NSButton()
    /// 在 Agent 中引用这道题（`ACP-AGENT-PLAN.md §15`）：这扇窗能发给 Agent 时才显示。
    private let referButton = NSButton()
    private let stemView = AgentMarkdownView(text: "", fontSize: 16, documentId: "exercise-stem")
    private let originalImage = NSImageView()
    /// 原题图下面：设置原题区域…（`ExerciseRegionPicker`，原题图显示着才有）。
    private let regionButton = NSButton()
    private var optionRows: [ExerciseOptionRow] = []
    private let submitButton = NSButton()
    private let resultIcon = NSImageView()
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    /// 显示的是以前的作答时：那次是什么时候、一共做过几次。
    private let historyNote = NSTextField(wrappingLabelWithString: "")
    private let agentNote = NSTextField(wrappingLabelWithString: "")
    /// 书上的作答（从高亮 / 手写认出来的那一条）：判完才显示，免得先把对错剧透了。
    private let markNote = NSTextField(wrappingLabelWithString: "")
    private let explanationTitle = NSTextField(labelWithString: L("Explanation"))
    private let explanationView = AgentMarkdownView(text: "", fontSize: 14, documentId: "exercise-explanation")
    private let retryButton = NSButton()
    private let mistakeButton = NSButton()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    /// 底部那条（上一题 / 下一题）上沿的分隔线。
    private let navLine = NSBox()
    /// 答对自动下一题（底部那条正中）。
    private let autoNextBox = NSButton(checkboxWithTitle: L("Next When Right"), target: nil, action: nil)
    /// 等着自动翻页的那一次（换题 / 再做一次 / 关开关时作废）。
    private var autoNextToken: UUID?
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    /// 填空 / 主观题的作答区（选择题时藏起来）。
    private let freeView = ExerciseFreeAnswerView()
    /// 自己判：还没判时「答对了 / 答错了」，判过了「改判为…」。
    private let rightButton = NSButton()
    private let wrongButton = NSButton()
    private let flipButton = NSButton()
    private let askAgentButton = NSButton()
    /// Agent 批改的评语。
    private let feedbackTitle = NSTextField(labelWithString: L("Agent Feedback"))
    private let feedbackView = AgentMarkdownView(text: "", fontSize: 14, documentId: "exercise-feedback")
    private var shownFeedback = ""
    /// 题目笔记（判完才显示，在解析下面，`EXERCISE-PLAN.md §12.1`）。
    private let noteView = ExerciseNoteView()

    /// 当前这道题正选着的（还没交）。
    private var picked: Set<String> = []
    /// 当前这道题从什么时候开始看的（记作答用时）。
    private var shownAt = Date()
    /// 当前显示的是哪一题、哪一版内容（内容没变就不重建选项，免得引擎白排一遍）。
    /// 🔴 别拿 `updatedAt` 认：收藏 / 移出错题本也会改它，那样点一下星标选项就整排重建、闪一下。
    private var shownId = ""
    private var shownContent: ExercisePayload?
    private var shownKind: ExerciseKind?
    /// 原题图开着吗（按题记：带图的题默认开）。
    private var originalShown: [String: Bool] = [:]
    private var originalFor = ""

    init(deck: ExerciseDeck, workspace: WorkspaceManager) {
        self.deck = deck
        self.workspace = workspace
        super.init(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true   // 「总是显示滚动条」时，题目不够一屏也别画一条（同日用户截图）
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        addSubview(scroll)

        metaLabel.font = .preferredFont(forTextStyle: .subheadline)
        metaLabel.textColor = .labelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        setup(starButton, symbol: "star", title: L("Star"), action: #selector(toggleStar))
        setup(tagsButton, symbol: "tag", title: L("Tags"), action: #selector(editTags))
        setup(originalButton, symbol: "photo", title: L("Original"), action: #selector(toggleOriginal))
        setup(sourceButton, symbol: "doc.text.magnifyingglass", title: L("Open Page"), action: #selector(openSource))
        setup(referButton, symbol: "at", title: L("Reference in Agent"), action: #selector(referenceInAgent))
        setup(regionButton, symbol: "crop", title: L("Set Question Area…"), action: #selector(setRegion))
        regionButton.toolTip = L("Choose which part of the page Original shows, instead of the whole page. A question that runs onto the next page can have a box on each page.")
        regionButton.isHidden = true
        referButton.toolTip = L("Put this question into the Agent’s message box, so you can ask about it.")
        originalButton.setButtonType(.pushOnPushOff)
        originalImage.imageScaling = .scaleProportionallyDown
        originalImage.imageAlignment = .alignTopLeft
        // 不设 keyEquivalent：Return 由 `keyDown` 统一管（判完之后它是「下一题」）
        setup(submitButton, symbol: nil, title: L("Submit"), action: #selector(submit))
        resultLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        resultLabel.textColor = .labelColor
        historyNote.font = .preferredFont(forTextStyle: .callout)
        historyNote.textColor = .labelColor
        agentNote.font = .preferredFont(forTextStyle: .callout)
        agentNote.textColor = .labelColor
        markNote.font = .preferredFont(forTextStyle: .callout)
        markNote.textColor = .labelColor
        explanationTitle.font = .preferredFont(forTextStyle: .headline)
        explanationTitle.textColor = .labelColor
        setup(retryButton, symbol: "arrow.counterclockwise", title: L("Try Again"), action: #selector(retry))
        setup(mistakeButton, symbol: "xmark.bin", title: L("Remove from Mistakes"), action: #selector(toggleMistake))
        setup(prevButton, symbol: "chevron.left", title: L("Previous"), action: #selector(prev))
        setup(nextButton, symbol: "chevron.right", title: L("Next"), action: #selector(next))
        nextButton.imagePosition = .imageTrailing
        autoNextBox.state = Self.autoNext ? .on : .off
        autoNextBox.toolTip = L("When you get a question right, go on to the next one after a moment. Get it wrong and you stay to read the explanation.")
        autoNextBox.target = self
        autoNextBox.action = #selector(autoNextToggled)
        emptyLabel.alignment = .center
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.textColor = .labelColor
        setup(rightButton, symbol: "checkmark.circle", title: L("I Got It Right"), action: #selector(markRight))
        setup(wrongButton, symbol: "xmark.circle", title: L("I Got It Wrong"), action: #selector(markWrong))
        setup(flipButton, symbol: "arrow.left.arrow.right", title: "", action: #selector(flipVerdict))
        setup(askAgentButton, symbol: "sparkles", title: L("Ask the Agent to Grade"), action: #selector(askAgent))
        feedbackTitle.font = .preferredFont(forTextStyle: .headline)
        feedbackTitle.textColor = .labelColor
        freeView.onHeightChange = { [weak self] in self?.needsLayout = true }
        freeView.onEdit = { [weak self] in self?.freeEdited() }
        freeView.onSubmit = { [weak self] in self?.submit() }
        noteView.onHeightChange = { [weak self] in self?.needsLayout = true }
        noteView.onSave = { [weak self] id, text in self?.deck.setNote(id: id, text) }
        noteView.onEndEditing = { [weak self] in self?.takeFocus() }
        for v in [metaLabel, starButton, tagsButton, originalButton, sourceButton, referButton, stemView, originalImage, regionButton, freeView, submitButton,
                  resultIcon, resultLabel, historyNote, rightButton, wrongButton, flipButton, askAgentButton,
                  feedbackTitle, feedbackView, agentNote, markNote, explanationTitle, explanationView, noteView,
                  retryButton, mistakeButton, emptyLabel] as [NSView] { doc.addSubview(v) }
        navLine.boxType = .separator
        for v in [navLine, prevButton, nextButton, autoNextBox] as [NSView] { addSubview(v) }
        for v in [stemView, explanationView, feedbackView] { v.onHeightChange = { [weak self] in self?.needsLayout = true } }
        show()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    private func setup(_ b: NSButton, symbol: String?, title: String, action: Selector) {
        b.bezelStyle = .push
        b.title = title
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); b.imagePosition = .imageLeading }
        b.target = self
        b.action = action
        b.contentTintColor = .labelColor
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.takeFocus() } }
    }

    func takeFocus() { window?.makeFirstResponder(self) }

    /// 点空白处把键盘焦点拿回来：点过题干（引擎的文本视图可以划选）之后，A~H / 方向键会落到那个文本视图上。
    override func mouseDown(with event: NSEvent) { takeFocus() }

    // MARK: - 显示一题

    /// 库里变了 / 换题了：按 `deck` 的现状重画。内容没变的题不重建选项（引擎排一次不便宜）。
    func show() {
        guard let e = deck.current else {
            shownId = ""; shownContent = nil; shownKind = nil
            noteView.commit()
            for v in doc.subviews { v.isHidden = v !== emptyLabel }
            for v in [navLine, prevButton, nextButton, autoNextBox] as [NSView] { v.isHidden = true }
            switch deck.filter {
            case .unanswered: emptyLabel.stringValue = L("You’ve done every question here.")
            case .lastWrong: emptyLabel.stringValue = L("No question here was wrong last time.")
            case .all: emptyLabel.stringValue = L("No exercises here yet. Ask the Agent to recognize the exercises in a PDF.")
            }
            needsLayout = true
            onChange()
            return
        }
        for v in doc.subviews { v.isHidden = false }
        for v in [navLine, prevButton, nextButton, autoNextBox] as [NSView] { v.isHidden = false }
        emptyLabel.isHidden = true
        if e.id != shownId {
            autoNextToken = nil
            picked = []
            shownAt = Date()
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if e.id != shownId || e.payload != shownContent || e.kind != shownKind {
            shownId = e.id; shownContent = e.payload; shownKind = e.kind
            stemView.update(text: e.payload.stem)
            explanationView.update(text: e.payload.explanation ?? "")
            rebuildOptions(e)
            freeView.begin(e, draft: deck.drafts[e.id])   // 选择题也有：只是手写演算那一块
        }
        refreshState()
    }

    private func rebuildOptions(_ e: Exercise) {
        for r in optionRows { r.removeFromSuperview() }
        guard e.kind.isChoice else { optionRows = []; return }
        optionRows = e.payload.options.map { o in
            let r = ExerciseOptionRow(key: o.key, text: o.text, multiple: e.kind == .multiple)
            r.onToggle = { [weak self] in self?.toggle(o.key) }
            r.onHeightChange = { [weak self] in self?.needsLayout = true }
            doc.addSubview(r)
            return r
        }
    }

    /// 选中态 / 判题结果 / 按钮这些便宜的东西（不碰引擎）。
    private func refreshState() {
        guard let e = deck.current else { return }
        let answer = deck.answer(for: e)
        let judged = answer != nil
        var meta = [String(format: L("Question %d of %d"), deck.index + 1, deck.items.count)]
        if !e.number.isEmpty { meta.append(String(format: L("No. %@"), e.number)) }
        if let p = e.page {
            if let q = e.lastPage, q > p { meta.append(String(format: L("Pages %d–%d"), p + 1, q + 1)) }
            else { meta.append(String(format: L("Page %d"), p + 1)) }
        }
        meta.append(Self.kindName(e.kind))
        if !e.section.isEmpty { meta.append(e.section) }
        if let c = e.chapter.last, c != e.section { meta.append(c) }
        metaLabel.stringValue = meta.joined(separator: " · ")
        metaLabel.toolTip = e.chapter.isEmpty ? nil : ExerciseChapter.display(e.chapter)
        starButton.image = NSImage(systemSymbolName: e.starred ? "star.fill" : "star", accessibilityDescription: nil)
        starButton.title = e.starred ? L("Starred") : L("Star")
        tagsButton.title = e.tags.isEmpty ? L("Tags") : Self.tagsTitle(e.tags)
        tagsButton.toolTip = e.tags.isEmpty ? L("Add tags to this question, such as Past Paper") : e.tags.joined(separator: "\n")
        sourceButton.isEnabled = e.documentId != nil && e.page != nil
        referButton.isHidden = agentWindow().map { AgentPanelModel.shared.canAttach(from: $0) } != true
        originalButton.isEnabled = e.documentId != nil && e.page != nil
        let showOriginal = originalShown[e.id] ?? e.payload.figure
        originalButton.state = showOriginal ? .on : .off
        loadOriginal(e, show: showOriginal)

        let chosen = answer?.chosen ?? picked
        let truth = Set(e.payload.answer)
        for r in optionRows {
            r.isSelected = chosen.contains(r.key)
            r.isLocked = judged
            if judged, answer?.correct != nil {
                r.mark = truth.contains(r.key) ? .correct : (chosen.contains(r.key) ? .wrong : .none)
            } else {
                r.mark = .none
            }
        }
        let free = !e.kind.isChoice
        freeView.isHidden = false
        // 交过的锁住显示作答（笔迹在库里那条上，统计里不带），没交的照常输入。选择题只有手写演算那一块
        let row = answer?.attemptId.flatMap { workspace?.exerciseAttempt(id: $0) }
        if let a = answer { freeView.showAnswered(e, answer: a, ink: ExerciseInk.decode(row?.ink)) }
        else if freeView.isLocked { freeView.begin(e, draft: deck.drafts[e.id]) }
        submitButton.isHidden = judged || e.kind == .single
        submitButton.isEnabled = free ? !freeView.response.isEmpty(e.kind) : !picked.isEmpty
        // 填空 / 主观题打字时 Return 是换行 / 下一空，提交用 ⌘Return；选择题的 Return 由 `keyDown` 管
        submitButton.keyEquivalent = free && !judged ? "\r" : ""
        submitButton.keyEquivalentModifierMask = free ? .command : []

        resultIcon.isHidden = !judged
        resultLabel.isHidden = !judged
        let stat = deck.stats[e.id]
        if let a = answer {
            switch a.correct {
            case true?:
                resultIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                resultIcon.contentTintColor = .systemGreen
            case false?:
                resultIcon.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
                resultIcon.contentTintColor = .systemRed
            case nil:
                resultIcon.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
                resultIcon.contentTintColor = .labelColor
            }
            resultLabel.stringValue = free ? Self.freeResultText(a, e) : Self.resultText(a, truth: e.payload.answer.joined())
        }
        // 自己判 / 改判 / 让 Agent 批改（只有填空 / 主观题；后判的为准）
        let canJudge = free && answer?.attemptId != nil
        rightButton.isHidden = !(canJudge && answer?.correct == nil)
        wrongButton.isHidden = rightButton.isHidden
        flipButton.isHidden = !(canJudge && answer?.correct != nil)
        flipButton.title = answer?.correct == true ? L("Mark as Wrong") : L("Mark as Right")
        askAgentButton.isHidden = !(canJudge && agentWindow().map { AgentPanelModel.shared.canAttach(from: $0) } == true)
        let feedback = row?.feedback ?? ""
        if feedback != shownFeedback { shownFeedback = feedback; feedbackView.update(text: feedback) }
        feedbackTitle.isHidden = feedback.isEmpty
        feedbackView.isHidden = feedback.isEmpty
        if case .practiced(let at)? = answer?.earlier {
            let counts = String(format: L("%d tries, %d right"), stat?.attempts ?? 0, stat?.correct ?? 0)
            historyNote.stringValue = at.map { Self.whenFormatter.string(from: $0) + " · " + counts } ?? counts
            historyNote.isHidden = false
        } else {
            historyNote.isHidden = true
        }
        agentNote.isHidden = !(judged && e.answerFromAgent)
        agentNote.stringValue = L("The answer was worked out by the Agent and has not been checked against the book.")
        // 显示的就是书上那条时，结果那行已经说了，不重复
        if judged, answer?.earlier != .book, let m = stat?.markedAnswer {
            let verdict: String
            switch stat?.markedCorrect {
            case true?: verdict = L("right")
            case false?: verdict = L("wrong")
            case nil: verdict = L("not judged")
            }
            markNote.stringValue = free
                ? String(format: L("In the book you wrote: %@ (%@)."),
                         ExerciseResponse.decode(e.kind, answer: m).summary(e.kind), verdict)
                : String(format: L("In the book you chose %@ (%@)."), m, verdict)
            markNote.isHidden = false
        } else {
            markNote.isHidden = true
        }
        let hasExplanation = !(e.payload.explanation ?? "").isEmpty
        explanationTitle.isHidden = !(judged && hasExplanation)
        explanationView.isHidden = !(judged && hasExplanation)
        // 笔记同解析，判完才显示（「再做一次」后又藏起来：写着的先存下）
        if !judged { noteView.commit() }
        noteView.show(note: e.note, exerciseId: e.id)
        noteView.isHidden = !judged
        retryButton.isHidden = !judged
        mistakeButton.isHidden = !e.wrong
        prevButton.isEnabled = deck.index > 0
        nextButton.isEnabled = deck.index < deck.items.count - 1
        needsLayout = true
        onChange()
    }

    /// 结果那行：这一轮刚答的 / 上次作答 / 书上的作答，各说各的。
    private static func resultText(_ a: ExerciseDeck.Answer, truth: String) -> String {
        let mine = Exercise.answerString(a.chosen)
        switch (a.earlier, a.correct) {
        case (nil, true?): return L("Correct")
        case (nil, false?): return String(format: L("Wrong. The answer is %@."), truth)
        case (nil, nil): return L("This question has no answer yet. Your choice was recorded.")
        case (.practiced?, true?): return String(format: L("Last time you chose %@. Correct."), mine)
        case (.practiced?, false?): return String(format: L("Last time you chose %@. Wrong. The answer is %@."), mine, truth)
        case (.practiced?, nil): return String(format: L("Last time you chose %@. This question has no answer yet."), mine)
        case (.book?, true?): return String(format: L("In the book you chose %@. Correct."), mine)
        case (.book?, false?): return String(format: L("In the book you chose %@. Wrong. The answer is %@."), mine, truth)
        case (.book?, nil): return String(format: L("In the book you chose %@. This question has no answer yet."), mine)
        }
    }

    static func kindName(_ k: ExerciseKind) -> String {
        switch k {
        case .single: return L("Single choice")
        case .multiple: return L("Multiple choice")
        case .fill: return L("Fill in the blank")
        case .subjective: return L("Subjective")
        }
    }

    /// 填空 / 主观题结果那行：谁判的、判成什么；还没判的说清楚该怎么办。以前的作答前面标「上次作答 / 书上的作答」。
    private static func freeResultText(_ a: ExerciseDeck.Answer, _ e: Exercise) -> String {
        let verdict: String
        switch (a.correct, a.judgedBy) {
        case (nil, _):
            if !e.hasAnswer { verdict = L("This question has no reference answer yet. Mark it yourself, or ask the Agent to grade it.") }
            else if e.kind == .fill { verdict = L("Some blanks don’t match the reference answer (it may just be written differently). Compare and mark it yourself.") }
            else { verdict = L("Compare with the reference answer and mark it yourself.") }
        case (true?, ExerciseJudge.bySelf): verdict = L("You marked it right.")
        case (false?, ExerciseJudge.bySelf): verdict = L("You marked it wrong.")
        case (true?, ExerciseJudge.byAgent): verdict = L("The Agent marked it right.")
        case (false?, ExerciseJudge.byAgent): verdict = L("The Agent marked it wrong.")
        case (true?, _): verdict = L("Every blank matches the reference answer.")
        case (false?, _): verdict = L("Wrong")
        }
        switch a.earlier {
        case nil: return verdict
        case .practiced?: return String(format: L("Last time: %@"), verdict)
        case .book?: return String(format: L("In the book: %@"), verdict)
        }
    }

    /// 「上次作答」那次的时间：今天 / 昨天用相对说法。
    private static let whenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    // MARK: - 原题图

    private func loadOriginal(_ e: Exercise, show: Bool) {
        originalImage.isHidden = !show
        regionButton.isHidden = !show
        guard show else { return }
        let want = "\(e.id)|\(e.documentId ?? "")|\(e.page ?? -1)|\(e.payload.region ?? [])|\(e.payload.nextRegions ?? [])"
        guard originalFor != want, let ws = workspace else { return }
        originalFor = want
        originalImage.image = nil
        let px = Int(min(1600, max(600, columnWidth * 2)))
        ExerciseOriginal.image(for: e, workspace: ws, pixelWidth: px) { [weak self] img in
            guard let self, self.originalFor == want else { return }
            self.originalImage.image = img
            // 渲不出来（文件不在了）就别留一块空框；按钮仍可以再点一次重试
            if img == nil { self.originalImage.isHidden = true; self.regionButton.isHidden = true; self.originalFor = "" }
            self.needsLayout = true
        }
    }

    // MARK: - 操作

    private func toggle(_ key: String) {
        guard let e = deck.current, deck.answer(for: e) == nil else { return }
        takeFocus()
        if e.kind == .single {
            picked = [key]
            refreshState()
            submit()
        } else {
            if picked.contains(key) { picked.remove(key) } else { picked.insert(key) }
            refreshState()
        }
    }

    @objc private func submit() {
        guard let e = deck.current, deck.answer(for: e) == nil else { return }
        let ms = Int(Date().timeIntervalSince(shownAt) * 1000)
        if e.kind.isChoice {
            guard !picked.isEmpty else { return }
            // 演算的手写跟着这次作答一起存（没写就不带）
            deck.submit(ExerciseResponse(keys: picked, ink: freeView.response.ink), elapsedMs: ms)
            picked = []
        } else {
            let r = freeView.response
            guard !r.isEmpty(e.kind) else { return }
            deck.submit(r, elapsedMs: ms)
            takeFocus()   // 交了之后输入框锁住，键盘交回给练习页（← → / Return 下一题）
        }
        refreshState()
        scheduleAutoNext(e)
    }

    /// 填空 / 主观题输入变了：存草稿（翻走再回来还在），「提交」能不能点跟着变。
    private func freeEdited() {
        guard let e = deck.current, deck.answer(for: e) == nil else { return }
        let r = freeView.response
        if e.kind.isChoice {
            // 选择题：草稿只有演算的手写（选了哪个不进草稿，「提交」能不能点看选没选）
            deck.drafts[e.id] = (r.ink?.isEmpty ?? true) ? nil : r
            return
        }
        deck.drafts[e.id] = r.isEmpty(e.kind) ? nil : r
        submitButton.isEnabled = !r.isEmpty(e.kind)
    }

    @objc private func markRight() {
        judgeCurrent(true)
        if let e = deck.current { scheduleAutoNext(e) }
    }
    @objc private func markWrong() { judgeCurrent(false) }

    @objc private func flipVerdict() {
        guard let e = deck.current, let c = deck.answer(for: e)?.correct else { return }
        judgeCurrent(!c)
    }

    private func judgeCurrent(_ correct: Bool) {
        guard let e = deck.current else { return }
        deck.judge(e, correct: correct)   // 判错进错题本；库变了 → 标签视图 reload → show()
        refreshState()
    }

    /// 让 Agent 批改：把题号这句话放进这扇窗 Agent 页的输入框（手写附成图片），题目与作答的 id 放进隐藏说明，用户点发送。
    /// Agent 按说明用 `list_exercise_attempts` 读作答、`grade_exercise_attempts` 写回对错与评语（`EXERCISE-PLAN.md §11.4`）。
    @objc private func askAgent() {
        guard let e = deck.current, let a = deck.answer(for: e), let aid = a.attemptId, let win = agentWindow() else { return }
        var images: [AgentImage] = []
        if let ink = ExerciseInk.decode(workspace?.exerciseAttempt(id: aid)?.ink) ?? a.response.ink,
           let png = ExerciseInkRender.png(ink, pixelWidth: 1200) {
            images.append(AgentImage(data: png, mimeType: "image/png", caption: L("Handwritten answer"),
                                     note: "the user's handwritten answer to exercise \(e.id) (attempt_id \(aid))"))
        }
        let label = e.number.isEmpty ? Self.kindName(e.kind) : String(format: L("No. %@"), e.number)
        let text = String(format: L("Please grade my answer to this question (%@): say whether it is right and what to improve."), label)
        let note = AgentSentContext.Marker.grading + " exercise_id \(e.id), attempt_id \(aid). "
            + "Read the question, the reference answer and the user's answer with list_exercise_attempts (exercise_ids: [\"\(e.id)\"]); "
            + "if it has handwriting, look at it with render_exercise_answer. Then save the verdict and feedback with "
            + "grade_exercise_attempts — it replaces any verdict the user gave themselves."
        let name = AgentPanelModel.shared.agentName(for: win)
        if !AgentPanelModel.shared.prepare(text: text, note: note, images: images, from: win) {
            let alert = NSAlert()
            alert.messageText = String(format: L("%@ is not available."), name)
            if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
        }
    }

    /// 设置原题区域：整页上框一块，存进这道题（`EXERCISE-PLAN.md §25`）；存完原题图按新框重渲（`loadOriginal` 认框）。
    @objc private func setRegion() {
        guard let e = deck.current, let ws = workspace, let win = window else { return }
        Self.pickRegion(e, deck: deck, workspace: ws, on: win)
    }

    /// 列表右键也走这里。
    static func pickRegion(_ e: Exercise, deck: ExerciseDeck, workspace ws: WorkspaceManager, on win: NSWindow) {
        ExerciseRegionPicker.present(on: win, exercise: e, workspace: ws) { [weak deck] region, next in
            deck?.setRegion(id: e.id, region, next: next)
        }
    }

    @objc private func referenceInAgent() {
        guard let e = deck.current, let ws = workspace, let win = agentWindow() else { return }
        Self.reference([e], in: ws, from: win, sheetOn: window)
    }

    /// 几道题插进这扇窗 Agent 输入框的光标处（`@书名 · 第 N 页 · 题号 X`），发送时照 `@` 选的一样附上说明
    /// （`AgentMention.exercise`：只给位置和 exercise_id，题目内容 Agent 自己经 MCP 读）。列表右键也走这里。
    static func reference(_ items: [Exercise], in ws: WorkspaceManager, from win: UUID, sheetOn window: NSWindow?) {
        let ms = items.map { AgentMention.exercise($0, in: ws) }
        guard !ms.isEmpty, !AgentPanelModel.shared.reference(ms, from: win) else { return }
        let a = NSAlert()
        a.messageText = String(format: L("%@ is not available."), AgentPanelModel.shared.agentName(for: win))
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }

    @objc private func retry() {
        autoNextToken = nil
        deck.retry()
        picked = []
        shownAt = Date()
        refreshState()
    }

    /// 批量重做之后（`deck.index` 已由调用方挪好）：当前题从头计时、清掉没交的勾选再重画。
    func restart() {
        autoNextToken = nil
        picked = []
        shownAt = Date()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        show()
    }

    @objc private func toggleStar() {
        guard let e = deck.current else { return }
        deck.setStarred(e, !e.starred)   // 库变了 → `exerciseRevision` → 标签视图 reload → show()
    }

    /// 按钮上最多露出前两枚标签，其余写「+N」。
    private static func tagsTitle(_ tags: [String]) -> String {
        let shown = tags.prefix(2).joined(separator: " · ")
        return tags.count > 2 ? shown + " +\(tags.count - 2)" : shown
    }

    @objc private func editTags() {
        guard let e = deck.current, let win = window else { return }
        ExerciseTagEditor.present(on: win, kind: .edit, count: 1, current: e.tags, suggestions: deck.availableTags) { [weak self] tags in
            self?.deck.setTags(ids: [e.id], tags, mode: .replace)
            self?.takeFocus()
        }
    }

    @objc private func toggleMistake() {
        guard let e = deck.current, e.wrong else { return }
        deck.setWrong(e, false)
    }

    @objc private func toggleOriginal() {
        guard let e = deck.current else { return }
        originalShown[e.id] = !(originalShown[e.id] ?? e.payload.figure)
        refreshState()
    }

    @objc private func openSource() {
        guard let e = deck.current else { return }
        onOpenSource(e)
    }

    @objc func prev() { go(deck.index - 1) }
    @objc func next() { go(deck.index + 1) }

    func go(_ i: Int) {
        guard deck.items.indices.contains(i), i != deck.index else { return }
        autoNextToken = nil
        deck.index = i
        show()
    }

    // MARK: - 答对自动下一题

    private static let autoNextKey = "exerciseAutoNext"
    /// 本机记住（同一台 Mac 上各个习题标签共用）。
    static var autoNext: Bool {
        get { UserDefaults.standard.bool(forKey: autoNextKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoNextKey) }
    }
    /// 判对之后停多久再翻：够看清绿勾，又不至于等得不耐烦。
    private static let autoNextDelay: TimeInterval = 0.8

    @objc private func autoNextToggled() {
        Self.autoNext = autoNextBox.state == .on
        if !Self.autoNext { autoNextToken = nil }
        takeFocus()
    }

    /// 这一轮刚交的 `e` 判为对 → 过一会儿翻到下一题。到时候再核一遍：开关还开着、还停在这道题、
    /// 显示的仍是这一轮答对的那次（没点「再做一次」、没改判），且不是最后一题。
    private func scheduleAutoNext(_ e: Exercise) {
        guard Self.autoNext, isRight(e) else { return }
        let token = UUID()
        autoNextToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoNextDelay) { [weak self] in
            guard let self, self.autoNextToken == token else { return }
            self.autoNextToken = nil
            guard Self.autoNext, self.window != nil, !self.isHidden, let cur = self.deck.current, cur.id == e.id,
                  self.isRight(cur) else { return }
            self.go(self.deck.index + 1)
        }
    }

    /// 眼下显示的是这一轮答的、而且判为对。
    private func isRight(_ e: Exercise) -> Bool {
        guard let a = deck.answer(for: e) else { return false }
        return a.earlier == nil && a.correct == true
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: prev(); return                       // ←
        case 124: next(); return                       // →
        case 36, 76:                                   // Return / Enter
            if let e = deck.current, deck.answer(for: e) != nil { next() } else { submit() }
            return
        default: break
        }
        if let ch = event.charactersIgnoringModifiers?.uppercased(), ch.count == 1,
           optionRows.contains(where: { $0.key == ch }) {
            toggle(ch)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - 排版

    private var columnWidth: CGFloat { max(280, min(760, bounds.width - 48)) }

    /// 底部那条（上一题 / 下一题）的高度。
    private static let navHeight: CGFloat = 52
    /// 底下浮着的标签栏占的高度（窗格经 `ExerciseTabView` 给）：底部那条摆在它上面，那一截留给标签栏。
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        let navShown = deck.current != nil
        let navH = navShown ? Self.navHeight : 0
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bottomInset - navH))
        let w = scroll.contentSize.width
        let colW = max(280, min(760, w - 48))
        let x0 = max(24, (w - colW) / 2)
        var y: CGFloat = 20

        if deck.current == nil {
            let h = emptyLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: colW, height: 10_000)).height ?? 40
            emptyLabel.frame = NSRect(x: x0, y: 80, width: colW, height: h)
            doc.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.contentSize.height, 80 + h + 40))
            return
        }

        // 顶行：题号这些 + 右侧几个按钮
        var bx = x0 + colW
        func placeTopButtons() {
            bx = x0 + colW
            for b in [referButton, sourceButton, originalButton, tagsButton, starButton] where !b.isHidden {
                b.sizeToFit()
                bx -= b.frame.width
                b.frame = NSRect(x: bx, y: y - 2, width: b.frame.width, height: b.frame.height)
                bx -= 6
            }
        }
        // 五个按钮挤得题号那行放不下时，「在 Agent 中引用」只留图标（提示文字里有全称）
        referButton.title = L("Reference in Agent")
        referButton.imagePosition = .imageLeading
        placeTopButtons()
        if !referButton.isHidden, bx - x0 < 220 {
            referButton.title = ""
            referButton.imagePosition = .imageOnly
            placeTopButtons()
        }
        metaLabel.frame = NSRect(x: x0, y: y + 3, width: max(0, bx - x0 - 8), height: 18)
        y += 38

        stemView.frame = NSRect(x: x0, y: y, width: colW, height: stemView.intrinsicContentSize.height)
        y = stemView.frame.maxY + 16

        if !originalImage.isHidden {
            let size = originalImage.image?.size ?? NSSize(width: colW, height: 60)
            let scale = min(1, colW / max(size.width, 1))
            let h = min(520, size.height * scale)
            originalImage.frame = NSRect(x: x0, y: y, width: colW, height: max(h, 40))
            y = originalImage.frame.maxY + 8
            if !regionButton.isHidden {
                regionButton.sizeToFit()
                regionButton.frame = NSRect(x: x0, y: y, width: regionButton.frame.width, height: regionButton.frame.height)
                y = regionButton.frame.maxY + 8
            }
            y += 8
        }

        for r in optionRows {
            let h = r.height(forWidth: colW)
            r.frame = NSRect(x: x0, y: y, width: colW, height: h)
            y += h + 6
        }
        if !freeView.isHidden {
            let h = freeView.height(forWidth: colW)
            freeView.frame = NSRect(x: x0, y: y, width: colW, height: h)
            y += h + 4
        }
        y += 10

        if !submitButton.isHidden {
            submitButton.sizeToFit()
            submitButton.frame = NSRect(x: x0, y: y, width: max(96, submitButton.frame.width), height: submitButton.frame.height)
            y = submitButton.frame.maxY + 14
        }

        if !resultLabel.isHidden {
            resultIcon.frame = NSRect(x: x0, y: y + 1, width: 20, height: 20)
            let lw = colW - 28
            let h = resultLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: lw, height: 10_000)).height ?? 20
            resultLabel.frame = NSRect(x: x0 + 28, y: y, width: lw, height: max(22, h))
            y = resultLabel.frame.maxY + 8
            if !historyNote.isHidden {
                let hh = historyNote.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: lw, height: 10_000)).height ?? 18
                historyNote.frame = NSRect(x: x0 + 28, y: y - 4, width: lw, height: hh)
                y = historyNote.frame.maxY + 10
            }
        }
        // 自己判 / 改判 / 让 Agent 批改
        var jx = x0
        for b in [rightButton, wrongButton, flipButton, askAgentButton] where !b.isHidden {
            b.sizeToFit()
            b.frame = NSRect(x: jx, y: y, width: b.frame.width, height: b.frame.height)
            jx = b.frame.maxX + 8
        }
        if jx > x0 { y += 40 }
        if !feedbackView.isHidden {
            feedbackTitle.frame = NSRect(x: x0, y: y, width: colW, height: 20)
            y = feedbackTitle.frame.maxY + 6
            feedbackView.frame = NSRect(x: x0, y: y, width: colW, height: feedbackView.intrinsicContentSize.height)
            y = feedbackView.frame.maxY + 12
        }
        for note in [agentNote, markNote] where !note.isHidden {
            let h = note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: colW, height: 10_000)).height ?? 18
            note.frame = NSRect(x: x0, y: y, width: colW, height: h)
            y = note.frame.maxY + 10
        }
        if !explanationView.isHidden {
            explanationTitle.frame = NSRect(x: x0, y: y + 4, width: colW, height: 20)
            y = explanationTitle.frame.maxY + 6
            explanationView.frame = NSRect(x: x0, y: y, width: colW, height: explanationView.intrinsicContentSize.height)
            y = explanationView.frame.maxY + 12
        }
        if !noteView.isHidden {
            noteView.frame = NSRect(x: x0, y: y + 4, width: colW, height: noteView.height(forWidth: colW))
            y = noteView.frame.maxY + 14
        }
        var ax = x0
        for b in [retryButton, mistakeButton] where !b.isHidden {
            b.sizeToFit()
            b.frame = NSRect(x: ax, y: y, width: b.frame.width, height: b.frame.height)
            ax = b.frame.maxX + 8
        }
        if ax > x0 { y += 40 }

        y += 20

        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.contentSize.height, y))

        // 底部那条：位置只跟视图大小走，与这一题有多高无关；左右与题目那一栏对齐
        let barY = bounds.height - bottomInset - navH
        navLine.frame = NSRect(x: 0, y: barY, width: bounds.width, height: 1)
        prevButton.sizeToFit(); nextButton.sizeToFit()
        let ph = prevButton.frame.height, nh = nextButton.frame.height
        prevButton.frame = NSRect(x: x0, y: barY + (navH - ph) / 2, width: max(100, prevButton.frame.width), height: ph)
        let nw = max(100, nextButton.frame.width)
        nextButton.frame = NSRect(x: x0 + colW - nw, y: barY + (navH - nh) / 2, width: nw, height: nh)
        // 正中：答对自动下一题（太窄放不下就藏起来，不压按钮）
        autoNextBox.sizeToFit()
        let cw = autoNextBox.frame.width, ch = autoNextBox.frame.height
        let room = nextButton.frame.minX - prevButton.frame.maxX - 16
        autoNextBox.frame = NSRect(x: x0 + (colW - cw) / 2, y: barY + (navH - ch) / 2, width: cw, height: ch)
        if navShown { autoNextBox.isHidden = room < cw }
    }
}

/// 滚动视图的内容：翻转坐标（从上往下排）。
final class FlippedDocView: NSView {
    override var isFlipped: Bool { true }
}

/// 一个选项：单选钮 / 复选框（标题就是 A、B…）+ 选项正文（引擎渲染）+ 判完的对错标记。
/// 点整行都算点选（正文区域吞掉点击，不做划选）。
@MainActor
final class ExerciseOptionRow: NSView {
    enum Mark { case none, correct, wrong }

    let key: String
    private let button: NSButton
    private let body: AgentMarkdownView
    private let markView = NSImageView()
    var onToggle: () -> Void = {}
    var onHeightChange: () -> Void = {}

    var isSelected = false { didSet { button.state = isSelected ? .on : .off } }
    var isLocked = false { didSet { button.isEnabled = !isLocked } }
    var mark: Mark = .none {
        didSet {
            switch mark {
            case .none: markView.image = nil
            case .correct:
                markView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: L("Correct"))
                markView.contentTintColor = .systemGreen
            case .wrong:
                markView.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Wrong"))
                markView.contentTintColor = .systemRed
            }
        }
    }

    init(key: String, text: String, multiple: Bool) {
        self.key = key
        button = multiple ? NSButton(checkboxWithTitle: key, target: nil, action: nil)
                          : NSButton(radioButtonWithTitle: key, target: nil, action: nil)
        body = AgentMarkdownView(text: text, fontSize: 15, documentId: "exercise-option-\(key)")
        super.init(frame: .zero)
        button.target = self
        button.action = #selector(clicked)
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        markView.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        body.onHeightChange = { [weak self] in self?.onHeightChange() }
        for v in [button, body, markView] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 不支持") }

    override var isFlipped: Bool { true }

    private static let buttonW: CGFloat = 44
    private static let markW: CGFloat = 26

    func height(forWidth w: CGFloat) -> CGFloat {
        max(24, body.intrinsicContentSize.height) + 6
    }

    override func layout() {
        super.layout()
        button.sizeToFit()
        button.frame = NSRect(x: 0, y: 3, width: Self.buttonW, height: max(18, button.frame.height))
        body.frame = NSRect(x: Self.buttonW, y: 3, width: max(0, bounds.width - Self.buttonW - Self.markW),
                            height: body.intrinsicContentSize.height)
        markView.frame = NSRect(x: bounds.width - Self.markW + 4, y: 3, width: 20, height: 20)
    }

    /// 单选钮自己接点击；其余地方（正文、空白）都归这一行。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if button.frame.contains(p) { return button }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked else { return }
        onToggle()
    }

    @objc private func clicked() {
        // 单选钮 / 复选框已经自己翻了状态；状态以上层为准，交给上层重刷
        button.state = isSelected ? .on : .off
        onToggle()
    }
}
