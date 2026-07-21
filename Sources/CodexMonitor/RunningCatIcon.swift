import AppKit
import SwiftUI

struct RunningCatIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> RunningCatAnimationView {
        let view = RunningCatAnimationView()
        view.startAnimating()
        return view
    }

    func updateNSView(_ nsView: RunningCatAnimationView, context: Context) {
        nsView.startAnimating()
    }

    static func dismantleNSView(_ nsView: RunningCatAnimationView, coordinator: ()) {
        nsView.stopAnimating()
    }
}

final class RunningCatAnimationView: NSView {
    private let tintLayer = CALayer()
    private let frameLayer = CALayer()
    private lazy var frames = Self.loadFrames()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(tintLayer)
        tintLayer.mask = frameLayer
        frameLayer.contentsGravity = .resizeAspect
        updateTintColor()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 28, height: 18)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        frameLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTintColor()
    }

    func startAnimating() {
        guard !frames.isEmpty,
              frameLayer.animation(forKey: "running-cat") == nil
        else { return }

        frameLayer.contents = frames[0]
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = 0.5
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        frameLayer.add(animation, forKey: "running-cat")
    }

    func stopAnimating() {
        frameLayer.removeAnimation(forKey: "running-cat")
    }

    private func updateTintColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tintLayer.backgroundColor = NSColor.labelColor.cgColor
            CATransaction.commit()
        }
    }

    private static func loadFrames() -> [CGImage] {
        (0..<5).compactMap { index in
            guard let url = Bundle.module.url(
                forResource: "cat-frame-\(index)",
                withExtension: "png",
                subdirectory: "CatFrames"
            ), let image = NSImage(contentsOf: url) else {
                return nil
            }
            var rect = NSRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }
}
