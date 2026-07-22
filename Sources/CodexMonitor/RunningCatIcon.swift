import AppKit
import SwiftUI

enum DogActivityState: String, Equatable {
    case idle
    case thinking
    case working
    case waiting

    var framePrefix: String {
        switch self {
        case .idle: "idle-frame"
        case .thinking: "thinking-frame"
        case .working: "cat-frame"
        case .waiting: "waiting-frame"
        }
    }

    var animationDuration: TimeInterval {
        switch self {
        case .idle: 1.4
        case .thinking: 1.0
        case .working: 0.5
        case .waiting: 1.2
        }
    }

    var accessibilityName: String {
        switch self {
        case .idle: "空闲"
        case .thinking: "思考中"
        case .working: "工作中"
        case .waiting: "等待操作"
        }
    }
}

enum DogStatusImage {
    static func image(for state: DogActivityState) -> NSImage? {
        let preferredPrefix = "elthen-\(state.rawValue)-frame"
        let fallbackPrefix = state.framePrefix
        guard let url = CatFrameResourceLocator.frameURL(prefix: preferredPrefix, index: 0)
            ?? CatFrameResourceLocator.frameURL(prefix: fallbackPrefix, index: 0),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.size = NSSize(width: 28, height: 18)
        image.isTemplate = true
        return image
    }
}

struct DogStatusIcon: NSViewRepresentable {
    let state: DogActivityState

    func makeNSView(context: Context) -> DogStatusAnimationView {
        let view = DogStatusAnimationView()
        view.setState(state)
        return view
    }

    func updateNSView(_ nsView: DogStatusAnimationView, context: Context) {
        nsView.setState(state)
    }

    static func dismantleNSView(_ nsView: DogStatusAnimationView, coordinator: ()) {
        nsView.stopAnimating()
    }
}

final class DogStatusAnimationView: NSView {
    private static let fallbackTransitionDuration: TimeInterval = 0.22
    private static let transitionFrameDuration: TimeInterval = 0.055
    private let tintLayer = CALayer()
    private let frameLayer = CALayer()
    private var state: DogActivityState?
    private var frames: [CGImage] = []
    private var transitionTask: Task<Void, Never>?

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

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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

    func setState(_ newState: DogActivityState) {
        guard state != newState else {
            startAnimating(duration: newState.animationDuration)
            return
        }

        let previousFrame = frames.first
        let isInitialState = state == nil
        state = newState
        let personalFrames = Self.loadFrames(prefix: "elthen-\(newState.rawValue)-frame")
        frames = personalFrames.isEmpty
            ? Self.loadFrames(prefix: newState.framePrefix)
            : personalFrames
        frameLayer.removeAnimation(forKey: "dog-status")
        transitionTask?.cancel()

        guard !isInitialState,
              let previousFrame,
              let nextFrame = frames.first
        else {
            startAnimating(duration: newState.animationDuration)
            return
        }

        let transitionFrames = Self.loadFrames(prefix: "elthen-transition-\(newState.rawValue)-frame")
        let duration = playTransition(from: previousFrame, to: nextFrame, transitionFrames: transitionFrames)
        let expectedState = newState
        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.state == expectedState else { return }
            self?.startAnimating(duration: expectedState.animationDuration)
        }
    }

    private func startAnimating(duration: TimeInterval) {
        guard !frames.isEmpty, frameLayer.animation(forKey: "dog-status") == nil else { return }

        frameLayer.contents = frames[0]
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        frameLayer.add(animation, forKey: "dog-status")
    }

    func stopAnimating() {
        transitionTask?.cancel()
        transitionTask = nil
        frameLayer.removeAnimation(forKey: "dog-status")
        frameLayer.removeAnimation(forKey: "dog-transition")
    }

    @discardableResult
    private func playTransition(
        from previousFrame: CGImage,
        to nextFrame: CGImage,
        transitionFrames: [CGImage]
    ) -> TimeInterval {
        guard !transitionFrames.isEmpty else {
            playFallbackTransition(from: previousFrame, to: nextFrame)
            return Self.fallbackTransitionDuration
        }

        let transitionValues = [previousFrame] + transitionFrames + [nextFrame]
        frameLayer.contents = nextFrame

        let contents = CAKeyframeAnimation(keyPath: "contents")
        contents.values = transitionValues
        contents.calculationMode = .discrete
        contents.duration = TimeInterval(transitionValues.count) * Self.transitionFrameDuration
        contents.timingFunction = CAMediaTimingFunction(name: .linear)
        frameLayer.add(contents, forKey: "dog-transition")
        return contents.duration
    }

    private func playFallbackTransition(from previousFrame: CGImage, to nextFrame: CGImage) {
        frameLayer.contents = nextFrame

        let contents = CAKeyframeAnimation(keyPath: "contents")
        contents.values = [previousFrame, nextFrame]
        contents.keyTimes = [0, 0.5]
        contents.calculationMode = .discrete

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 0.78, 0.78, 1.0]
        scale.keyTimes = [0, 0.42, 0.58, 1]
        scale.calculationMode = .linear

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1.0, 0.72, 0.72, 1.0]
        opacity.keyTimes = [0, 0.42, 0.58, 1]
        opacity.calculationMode = .linear

        let transition = CAAnimationGroup()
        transition.animations = [contents, scale, opacity]
        transition.duration = Self.fallbackTransitionDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        frameLayer.add(transition, forKey: "dog-transition")
    }

    private func updateTintColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tintLayer.backgroundColor = NSColor.labelColor.cgColor
            CATransaction.commit()
        }
    }

    private static func loadFrames(prefix: String) -> [CGImage] {
        var frames: [CGImage] = []
        for index in 0..<16 {
            guard let url = CatFrameResourceLocator.frameURL(prefix: prefix, index: index),
                  let image = NSImage(contentsOf: url) else {
                break
            }
            var rect = NSRect(origin: .zero, size: image.size)
            if let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                frames.append(cgImage)
            }
        }
        return frames
    }
}
