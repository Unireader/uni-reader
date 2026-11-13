import AppKit

/// 编辑区里盖在 ```anim 静态图上的实时视图（`ANIM-BLOCK-PLAN.md §1`）：画布 + 底下一行控制条（上一步 / 播放 / 下一步 / 进度 / 步号 / 编辑文字）。
///
/// 尺寸与静态图完全一样（`AnimBlockMetrics`），盖上去看不出接缝。点画布 = 下一步（按住 ⌥ = 上一步），点过之后 ← → 空格可用；
/// 滚轮交还给笔记。步与步之间补间（`AnimPainter.transition`），拖进度条直接跳、不补间。
@MainActor
final class AnimBlockView: NSView {
    var onEditSource: (() -> Void)? {
        didSet { editButton.isHidden = onEditSource == nil }
    }

    private var source: String
    private var run: AnimRun
    private var metrics: AnimBlockMetrics?
    private var palette: AnimPalette
    private var frames: [Int: AnimFrame] = [:]

    private(set) var step = 0
    /// 正在补间：从 `fromStep` 到 `step`，开始时刻。
    private var fromStep: Int?
    private var transitionStart: CFTimeInterval = 0
    private var playing = false
    private var holdUntil: CFTimeInterval = 0
    private var link: CADisplayLink?

    private let canvas = AnimCanvasView()
    private let controls = NSStackView()
    private let prevButton = NSButton()
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let slider = NSSlider()
    private let stepLabel = NSTextField(labelWithString: "")
    private let editButton = NSButton()

    /// 自动播放时每一步停多久（秒，不含补间）。
    static let hold: Double = 1.4

    init(source: String) {
        self.source = source
        self.run = AnimEngine.run(source)
        self.palette = AnimPalette(dark: false)
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        palette = AnimPalette(dark: isDark)
        canvas.owner = self
        addSubview(canvas)
        buildControls()
        refreshControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func setSource(_ text: String) {
        guard text != source else { return }
        source = text
        run = AnimEngine.run(text)
        frames.removeAll()
        metrics = nil
        stopPlayback()
        fromStep = nil
        step = min(step, run.stepCount - 1)
        refreshControls()
        needsLayout = true
        canvas.needsDisplay = true
    }

    /// 离开（光标进块、滚出视口）：停播放。
    func deactivate() {
        stopPlayback()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = AnimPalette(dark: isDark)
        canvas.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink(); playing = false }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        if metrics?.layout.width != width {
            metrics = width > 0 ? AnimBlockMetrics(run: run, width: width) : nil
            frames.removeAll()
        }
        let canvasHeight = metrics?.canvasHeight ?? max(bounds.height - AnimBlockMetrics.controlsHeight, 0)
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: canvasHeight)
        controls.frame = NSRect(x: 0, y: canvasHeight, width: width, height: AnimBlockMetrics.controlsHeight)
    }

    // MARK: 画

    fileprivate func drawCanvas() {
        guard let metrics else { return }
        let target = frame(at: step)
        if let from = fromStep {
            let t = AnimPainter.ease((CACurrentMediaTime() - transitionStart) / AnimPainter.transition)
            AnimPainter.draw(frame(at: from), target, t: t, palette: palette)
        } else {
            AnimPainter.draw(target, nil, t: 0, palette: palette)
        }
        metrics.drawErrors(palette: palette)
    }

    private func frame(at k: Int) -> AnimFrame {
        if let f = frames[k] { return f }
        guard let metrics else { return AnimFrame(size: .zero, items: []) }
        let f = metrics.layout.frame(step: k)
        frames[k] = f
        return f
    }

    // MARK: 走步

    private var lastStep: Int { max(run.stepCount - 1, 0) }

    func go(to k: Int, animated: Bool) {
        let target = min(max(k, 0), lastStep)
        guard target != step || fromStep != nil else { return }
        if animated && target != step {
            // 补间途中又走一步：从「现在显示的目标」接着走（不回头补完）
            fromStep = step
            transitionStart = CACurrentMediaTime()
            startLink()
        } else {
            fromStep = nil
        }
        step = target
        refreshControls()
        canvas.needsDisplay = true
    }

    @objc private func prevTapped() { stopPlayback(); go(to: step - 1, animated: true) }
    @objc private func nextTapped() { stopPlayback(); go(to: step + 1, animated: true) }

    @objc private func playTapped() {
        if playing {
            stopPlayback()
            return
        }
        playing = true
        if step >= lastStep { go(to: 0, animated: false) }
        holdUntil = CACurrentMediaTime() + 0.25
        startLink()
        refreshControls()
    }

    @objc private func sliderMoved() {
        stopPlayback()
        go(to: Int(slider.doubleValue.rounded()), animated: false)
    }

    @objc private func editTapped() {
        stopPlayback()
        onEditSource?()
    }

    private func stopPlayback() {
        guard playing else { return }
        playing = false
        refreshControls()
    }

    // MARK: 逐帧

    private func startLink() {
        guard link == nil, window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        if fromStep != nil {
            canvas.needsDisplay = true
            if now - transitionStart >= AnimPainter.transition {
                fromStep = nil
                holdUntil = now + Self.hold
            }
            return
        }
        if playing {
            if now >= holdUntil {
                if step >= lastStep {
                    playing = false
                    refreshControls()
                } else {
                    go(to: step + 1, animated: true)
                }
            }
            return
        }
        stopLink()
    }

    // MARK: 鼠标与键盘

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard canvas.frame.contains(p) else { return }
        stopPlayback()
        go(to: event.modifierFlags.contains(.option) ? step - 1 : step + 1, animated: true)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: prevTapped()                 // ←
        case 124: nextTapped()                 // →
        case 49: playTapped()                  // 空格
        case 53: window?.makeFirstResponder(nil)   // Esc
        default: super.keyDown(with: event)
        }
    }

    // MARK: 控制条

    private func buildControls() {
        configure(prevButton, symbol: "backward.frame.fill", tip: L("Previous step"), action: #selector(prevTapped))
        configure(playButton, symbol: "play.fill", tip: L("Play"), action: #selector(playTapped))
        configure(nextButton, symbol: "forward.frame.fill", tip: L("Next step"), action: #selector(nextTapped))
        configure(editButton, symbol: "chevron.left.forwardslash.chevron.right", tip: L("Edit the text"), action: #selector(editTapped))
        editButton.isHidden = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.controlSize = .small
        slider.minValue = 0
        stepLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stepLabel.textColor = .labelColor
        stepLabel.alignment = .right
        stepLabel.setContentHuggingPriority(.required, for: .horizontal)
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 4
        controls.edgeInsets = NSEdgeInsets(top: 0, left: AnimMetrics.pad - 4, bottom: 0, right: AnimMetrics.pad - 4)
        controls.setViews([prevButton, playButton, nextButton, slider, stepLabel, editButton], in: .leading)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(controls)
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .labelColor
        button.toolTip = tip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func refreshControls() {
        let last = lastStep
        slider.maxValue = Double(max(last, 1))
        slider.numberOfTickMarks = last >= 1 && last <= 30 ? last + 1 : 0
        slider.allowsTickMarkValuesOnly = slider.numberOfTickMarks > 0
        slider.doubleValue = Double(step)
        slider.isEnabled = last > 0
        prevButton.isEnabled = step > 0
        nextButton.isEnabled = step < last
        playButton.isEnabled = last > 0
        let symbol = playing ? "pause.fill" : "play.fill"
        let tip = playing ? L("Pause") : L("Play")
        playButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        playButton.toolTip = tip
        stepLabel.stringValue = "\(step) / \(last)"
    }
}

/// 画布：只负责把 `AnimBlockView` 当前的帧画出来（点击交给外层）。
private final class AnimCanvasView: NSView {
    weak var owner: AnimBlockView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated { owner?.drawCanvas() }
    }
}
