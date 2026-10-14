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
    private let originalButton = NSButton()
    private let sourceButton = NSButton()
    private let stemView = AgentMarkdownView(text: "", fontSize: 16, documentId: "exercise-stem")
    private let originalImage = NSImageView()
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
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = doc
        addSubview(scroll)

        metaLabel.font = .preferredFont(forTextStyle: .subheadline)
        metaLabel.textColor = .labelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        setup(starButton, symbol: "star", title: L("Star"), action: #selector(toggleStar))
        setup(originalButton, symbol: "photo", title: L("Original"), action: #selector(toggleOriginal))
        setup(sourceButton, symbol: "doc.text.magnifyingglass", title: L("Open Page"), action: #selector(openSource))
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
        for v in [metaLabel, starButton, originalButton, sourceButton, stemView, originalImage, freeView, submitButton,
                  resultIcon, resultLabel, historyNote, rightButton, wrongButton, flipButton, askAgentButton,
                  feedbackTitle, feedbackView, agentNote, markNote, explanationTitle, explanationView, retryButton, mistakeButton,
                  prevButton, nextButton, emptyLabel] as [NSView] { doc.addSubview(v) }
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
            for v in doc.subviews { v.isHidden = v !== emptyLabel }
            emptyLabel.stringValue = deck.filter == .unanswered ? L("You’ve done every question here.")
                : L("No exercises here yet. Ask the Agent to recognize the exercises in a PDF.")
            needsLayout = true
            onChange()
            return
        }
        for v in doc.subviews { v.isHidden = false }
        emptyLabel.isHidden = true
        if e.id != shownId {
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
            if !e.kind.isChoice { freeView.begin(e, draft: deck.drafts[e.id]) }
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
        if let p = e.page { meta.append(String(format: L("Page %d"), p + 1)) }
        meta.append(Self.kindName(e.kind))
        if !e.section.isEmpty { meta.append(e.section) }
        if let c = e.chapter.last, c != e.section { meta.append(c) }
        metaLabel.stringValue = meta.joined(separator: " · ")
        metaLabel.toolTip = e.chapter.isEmpty ? nil : ExerciseChapter.display(e.chapter)
        starButton.image = NSImage(systemSymbolName: e.starred ? "star.fill" : "star", accessibilityDescription: nil)
        starButton.title = e.starred ? L("Starred") : L("Star")
        sourceButton.isEnabled = e.documentId != nil && e.page != nil
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
        freeView.isHidden = !free
        // 填空 / 主观题：交过的锁住显示作答（笔迹在库里那条上，统计里不带），没交的照常输入
        let row = free ? answer?.attemptId.flatMap { workspace?.exerciseAttempt(id: $0) } : nil
        if free {
            if let a = answer { freeView.showAnswered(e, answer: a, ink: ExerciseInk.decode(row?.ink)) }
            else if freeView.isLocked { freeView.begin(e, draft: deck.drafts[e.id]) }
        }
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
        guard show else { return }
        let want = "\(e.id)|\(e.documentId ?? "")|\(e.page ?? -1)|\(e.payload.region ?? [])"
        guard originalFor != want, let ws = workspace else { return }
        originalFor = want
        originalImage.image = nil
        let px = Int(min(1600, max(600, columnWidth * 2)))
        ExerciseOriginal.image(for: e, workspace: ws, pixelWidth: px) { [weak self] img in
            guard let self, self.originalFor == want else { return }
            self.originalImage.image = img
            // 渲不出来（文件不在了）就别留一块空框；按钮仍可以再点一次重试
            if img == nil { self.originalImage.isHidden = true; self.originalFor = "" }
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
            deck.submit(picked, elapsedMs: ms)
            picked = []
        } else {
            let r = freeView.response
            guard !r.isEmpty(e.kind) else { return }
            deck.submit(r, elapsedMs: ms)
            takeFocus()   // 交了之后输入框锁住，键盘交回给练习页（← → / Return 下一题）
        }
        refreshState()
    }

    /// 填空 / 主观题输入变了：存草稿（翻走再回来还在），「提交」能不能点跟着变。
    private func freeEdited() {
        guard let e = deck.current, !e.kind.isChoice, deck.answer(for: e) == nil else { return }
        let r = freeView.response
        deck.drafts[e.id] = r.isEmpty(e.kind) ? nil : r
        submitButton.isEnabled = !r.isEmpty(e.kind)
    }

    @objc private func markRight() { judgeCurrent(true) }
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
        let note = "The user wants you to grade their answer. exercise_id \(e.id), attempt_id \(aid). "
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

    @objc private func retry() {
        deck.retry()
        picked = []
        shownAt = Date()
        refreshState()
    }

    /// 批量重做之后（`deck.index` 已由调用方挪好）：当前题从头计时、清掉没交的勾选再重画。
    func restart() {
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
        deck.index = i
        show()
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

    override func layout() {
        super.layout()
        scroll.frame = bounds
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

        // 顶行：题号这些 + 右侧三个按钮
        var bx = x0 + colW
        for b in [sourceButton, originalButton, starButton] {
            b.sizeToFit()
            bx -= b.frame.width
            b.frame = NSRect(x: bx, y: y - 2, width: b.frame.width, height: b.frame.height)
            bx -= 6
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
            y = originalImage.frame.maxY + 16
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
        var ax = x0
        for b in [retryButton, mistakeButton] where !b.isHidden {
            b.sizeToFit()
            b.frame = NSRect(x: ax, y: y, width: b.frame.width, height: b.frame.height)
            ax = b.frame.maxX + 8
        }
        if ax > x0 { y += 40 }

        y += 12
        prevButton.sizeToFit(); nextButton.sizeToFit()
        prevButton.frame = NSRect(x: x0, y: y, width: max(100, prevButton.frame.width), height: prevButton.frame.height)
        let nw = max(100, nextButton.frame.width)
        nextButton.frame = NSRect(x: x0 + colW - nw, y: y, width: nw, height: nextButton.frame.height)
        y = nextButton.frame.maxY + 32

        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.contentSize.height, y))
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
