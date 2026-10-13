import AppKit
import QuartzCore

func drawEmoteImage(_ image: NSImage, in rect: CGRect) {
    let factor = min(rect.width/max(image.size.width, 1), rect.height/max(image.size.height, 1))
    let size = CGSize(width: image.size.width*factor, height: image.size.height*factor)
    image.draw(in: CGRect(x: rect.midX-size.width/2, y: rect.midY-size.height/2, width: size.width, height: size.height),
               from: .zero, operation: .sourceOver, fraction: 1)
}

final class EmoteEffectView: NSView {
    let image: NSImage
    let label: String?
    private var timer: Timer?
    private var started: CFTimeInterval = 0
    private(set) var elapsed: Double = 3
    init(frame: CGRect, image: NSImage, label: String?) { self.image = image; self.label = label; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    override var isOpaque: Bool { false }
    func start() {
        started = CACurrentMediaTime(); seek(0)
        let next = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.seek(CACurrentMediaTime()-self.started)
            if self.elapsed >= 3 { self.stop() }
        }
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
    func seek(_ time: Double) { elapsed = time; needsDisplay = true }
    func stop() { timer?.invalidate(); timer = nil; seek(3) }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds); guard elapsed < 3 else { return }
        let fade = min(1, elapsed/0.12)*min(1, max(0, (3-elapsed)/0.35))
        let pop = elapsed < 0.2 ? 0.7+0.3*sin(elapsed/0.2 * .pi/2) : 1
        let side = bounds.width*0.68*CGFloat(pop)
        context.saveGState(); context.setAlpha(fade)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 9, color: NSColor.black.withAlphaComponent(0.65).cgColor)
        drawEmoteImage(image, in: CGRect(x: bounds.midX-side/2, y: bounds.midY-side/2+8, width: side, height: side))
        if let label, !label.isEmpty {
            let title = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
            let box = CGRect(x: bounds.midX-title.size().width/2-7, y: 10, width: title.size().width+14, height: title.size().height+6)
            NSColor.black.withAlphaComponent(0.65).setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            title.draw(at: CGPoint(x: box.minX+7, y: box.minY+3))
        }
        context.restoreGState()
    }
}
