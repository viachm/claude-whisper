import AppKit
import AVFoundation

/// The small dark capsule near the bottom of the screen that shows what dictation is doing:
/// bars that follow your voice while listening, a travelling wave while Claude transcribes,
/// and a short line of text for messages. A sparkle sits next to the bars when Claude will clean
/// the dictation up, and pulses while it does. It never takes focus, so text still goes to the
/// app you were typing in.
final class Overlay {
    enum Mode { case waiting, listening, locked, transcribing, message(String) }

    private let panel: NSPanel
    private let capsule = CapsuleView()
    private let meter = LevelMeter()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CapsuleView.barsWidth, height: CapsuleView.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = capsule
        meter.onLevel = { [weak self] level in self?.capsule.push(level: level) }
    }

    func show(_ mode: Mode) {
        hideWork?.cancel()
        switch mode {
        case .listening, .locked: meter.start()
        default: meter.stop()
        }
        switch mode {
        case .waiting: capsule.style = .idle
        case .listening: capsule.style = .voice
        case .locked: capsule.style = .locked
        case .transcribing: capsule.style = .wave
        case .message(let text):
            capsule.style = .text(text)
            hide(after: 2.2)
        }
        let size = capsule.fittingSize
        position(size: size)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    /// Shows or hides the sparkle badge; the capsule grows to make room for it.
    func setImprove(_ on: Bool) {
        capsule.improve = on
        if panel.isVisible { position(size: capsule.fittingSize) }
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.meter.stop()
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self.panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Just above the Dock, centred on the screen the mouse is on.
    private func position(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: (frame.midX - size.width / 2).rounded(), y: frame.minY + 14,
                              width: size.width, height: size.height), display: true)
    }
}

/// Near-black capsule with the content in the middle.
private final class CapsuleView: NSView {
    enum Style: Equatable { case idle, voice, locked, wave, text(String) }

    static let height: CGFloat = 30
    static let barsWidth: CGFloat = 80
    private static let barCount = 13

    var style: Style = .idle { didSet { if style != oldValue { restyle() } } }
    var improve = false { didSet { if improve != oldValue { needsDisplay = true } } }

    private var levels = [CGFloat](repeating: 0, count: barCount)
    /// Bar heights on screen, eased towards their targets each frame so the motion is smooth.
    private var shown = [CGFloat](repeating: 0, count: barCount)
    private var phase: CGFloat = 0
    private var timer: Timer?
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.85)
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Draw at the screen's Retina scale; a layer created before the view joins a window
    /// otherwise stays at 1x and the bars look pixelated.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    /// Extra width on the left for the lock symbol while locked.
    private static let lockWidth: CGFloat = 16

    override var fittingSize: NSSize {
        if case .text = style {
            return NSSize(width: ceil(label.intrinsicContentSize.width) + 36, height: Self.height)
        }
        let lock = style == .locked ? Self.lockWidth : 0
        return NSSize(width: Self.barsWidth + lock + (improve ? Self.sparkleWidth : 0), height: Self.height)
    }

    /// Claude's coral, so the sparkle reads as "Claude is involved".
    private static let sparkleColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    private static let sparkleWidth: CGFloat = 22

    private var pending: CGFloat = 0
    private var lastShift = Date.distantPast

    /// Audio buffers arrive ~40 times a second; shifting the bars that often makes them race,
    /// so take the loudest level of each ~120 ms and shift once.
    func push(level: CGFloat) {
        pending = max(pending, level)
        guard Date().timeIntervalSince(lastShift) >= 0.12 else { return }
        lastShift = Date()
        levels.removeFirst()
        levels.append(pending)
        pending = 0
    }

    private func restyle() {
        timer?.invalidate()
        timer = nil
        if case .text(let text) = style {
            label.stringValue = text
            label.isHidden = false
        } else {
            label.isHidden = true
            if style != .locked { levels = levels.map { _ in 0 } }
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
                self?.phase += 0.05
                self?.needsDisplay = true
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: (bounds.width - label.frame.width) / 2, y: (bounds.height - label.frame.height) / 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = rect.height / 2
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.94).setFill()
        shape.fill()

        if case .text = style { return }
        var content = rect
        if improve {
            content.size.width -= Self.sparkleWidth
            drawSparkle(in: NSRect(x: content.maxX - 4, y: rect.minY, width: Self.sparkleWidth, height: rect.height))
        }
        guard style == .locked else { return drawBars(in: content) }
        drawLock(in: NSRect(x: content.minX + 12, y: content.minY, width: Self.lockWidth - 2, height: content.height))
        drawBars(in: NSRect(x: content.minX + Self.lockWidth, y: content.minY, width: content.width - Self.lockWidth,
                            height: content.height))
    }

    /// Steady while listening; pulses while Claude is cleaning the text up.
    private func drawSparkle(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [Self.sparkleColor]))
        guard let sparkle = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Improve")?
            .withSymbolConfiguration(config) else { return }
        let alpha = style == .wave ? 0.45 + 0.55 * (sin(phase * 2.5) + 1) / 2 : 1
        let size = sparkle.size
        sparkle.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: alpha)
    }

    /// The lock shown while dictation keeps listening without the key held.
    private func drawLock(in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.9)]))
        guard let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(config) else { return }
        let size = lock.size
        lock.draw(in: NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func drawBars(in rect: NSRect) {
        let count = Self.barCount
        let barWidth: CGFloat = 2, gap: CGFloat = 2.4
        let total = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        var x = rect.midX - total / 2
        let maxHeight = rect.height - 10, minHeight: CGFloat = 2.5
        for i in 0..<count {
            let centre = 1 - abs(CGFloat(i) - CGFloat(count - 1) / 2) / CGFloat(count) // taller in the middle
            var amount: CGFloat
            var color = NSColor.white
            switch style {
            case .voice, .locked:
                amount = min(1, levels[i] * (0.55 + centre))
            case .wave:
                amount = 0.25 + 0.3 * (sin(phase - CGFloat(i) * 0.45) + 1) / 2
                color = NSColor.white.withAlphaComponent(0.55)
            default:
                amount = 0
                color = NSColor.white.withAlphaComponent(0.35)
            }
            shown[i] += (amount - shown[i]) * 0.3
            let h = minHeight + (maxHeight - minHeight) * shown[i]
            let bar = NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
            color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}

/// Reads the microphone level while listening, only to animate the bars. Claude Code does the
/// actual recording; this starts after Claude has already opened the microphone.
private final class LevelMeter {
    var onLevel: ((CGFloat) -> Void)?
    private var engine: AVAudioEngine?

    func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(max(n, 1)))
            let db = 20 * log10(max(rms, 1e-6))
            let level = CGFloat(max(0, min(1, (db + 50) / 40))) // -50 dB … -10 dB
            DispatchQueue.main.async { self?.onLevel?(level) }
        }
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
