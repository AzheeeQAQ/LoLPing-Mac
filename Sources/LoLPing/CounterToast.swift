import AppKit
import PingCore

/// "+1 · 今日 13 · 总计 341" bubble that pops at the mouse, rises and fades out.
/// Drawn at the backing scale like the ping effects; click-through.
final class CounterToastView: NSView {
    static let duration = 1.6
    static let rise: CGFloat = 34
    private let deltaText: NSAttributedString, detailText: NSAttributedString, nameText: NSAttributedString?
    private let pill: CGSize
    private var startTime: CFTimeInterval = 0
    private var timer: Timer?
    private var progress = 0.0

    init(delta: Int, counter: DailyCounter, name: String?) {
        func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        }
        let gold = NSColor(srgbRed: 0.83, green: 0.70, blue: 0.44, alpha: 1)
        let cool = NSColor(srgbRed: 0.62, green: 0.78, blue: 0.95, alpha: 1)
        deltaText = NSAttributedString(string: delta > 0 ? "+\(delta)" : "−\(-delta)",
                                       attributes: [.font: rounded(26, .bold), .foregroundColor: delta > 0 ? gold : cool])
        detailText = NSAttributedString(string: "今日 \(counter.today(at: Date())) · 总计 \(counter.total)",
                                        attributes: [.font: rounded(12, .semibold), .foregroundColor: NSColor(white: 0.92, alpha: 1)])
        nameText = name.map { NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                                          .foregroundColor: NSColor(srgbRed: 0.59, green: 0.65, blue: 0.71, alpha: 1)]) }
        let right = max(detailText.size().width, nameText?.size().width ?? 0)
        let rightHeight = detailText.size().height + (nameText.map { $0.size().height + 1 } ?? 0)
        pill = CGSize(width: ceil(14 + deltaText.size().width + 9 + right + 14), height: ceil(max(deltaText.size().height, rightHeight) + 12))
        super.init(frame: CGRect(x: 0, y: 0, width: pill.width + 16, height: pill.height + Self.rise + 12))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    func start() {
        startTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.progress = min(1, (CACurrentMediaTime()-self.startTime)/Self.duration)
            self.needsDisplay = true
            if self.progress >= 1 { self.stop() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    /// For offscreen checks: draw a fixed moment of the animation (0...1).
    func seek(to value: Double) { progress = min(max(value, 0), 1); needsDisplay = true }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let t = progress
        func smooth(_ x: Double) -> Double { let v = min(max(x, 0), 1); return v*v*(3-2*v) }
        let alpha = t < 0.1 ? t/0.1 : (t > 0.62 ? max(0, 1-(t-0.62)/0.38) : 1)
        let pop = t < 0.12 ? 0.82 + 0.18*smooth(t/0.12) : 1
        let rect = CGRect(x: (bounds.width-pill.width)/2, y: 6 + Self.rise*CGFloat(smooth(t/0.9)), width: pill.width, height: pill.height)
        context.saveGState()
        context.setAlpha(CGFloat(alpha))
        context.translateBy(x: rect.midX, y: rect.midY); context.scaleBy(x: CGFloat(pop), y: CGFloat(pop))
        context.translateBy(x: -rect.midX, y: -rect.midY)
        let shape = NSBezierPath(roundedRect: rect, xRadius: rect.height/2, yRadius: rect.height/2)
        NSColor(srgbRed: 0.035, green: 0.055, blue: 0.08, alpha: 0.9).setFill(); shape.fill()
        NSColor(srgbRed: 0.83, green: 0.70, blue: 0.44, alpha: 0.55).setStroke(); shape.lineWidth = 1; shape.stroke()
        let deltaSize = deltaText.size()
        deltaText.draw(at: CGPoint(x: rect.minX+14, y: rect.midY-deltaSize.height/2))
        let x = rect.minX + 14 + deltaSize.width + 9
        if let nameText {
            let total = nameText.size().height + 1 + detailText.size().height
            let base = rect.midY - total/2
            detailText.draw(at: CGPoint(x: x, y: base))
            nameText.draw(at: CGPoint(x: x, y: base + detailText.size().height + 1))
        } else {
            detailText.draw(at: CGPoint(x: x, y: rect.midY-detailText.size().height/2))
        }
        context.restoreGState()
    }
}

extension OverlayController {
    /// Bottom-centered just above the mouse tip, kept on the mouse's screen.
    static func counterToastFrame(size: CGSize, at point: CGPoint) -> CGRect {
        let frames = NSScreen.screens.map(\.frame)
        let screen = LANGeometry.screenIndex(containing: point, in: frames).map { frames[$0] } ?? frames.first ?? CGRect(origin: point, size: size)
        let x = min(max(point.x-size.width/2, screen.minX), screen.maxX-size.width)
        let y = min(max(point.y+4, screen.minY), screen.maxY-size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
