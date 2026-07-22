import AppKit
import SwiftUI

enum CatActivityState: String, Equatable {
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

struct CatStatusIcon: NSViewRepresentable {
    let state: CatActivityState

    func makeNSView(context: Context) -> CatStatusAnimationView {
        let view = CatStatusAnimationView()
        view.setState(state)
        return view
    }

    func updateNSView(_ nsView: CatStatusAnimationView, context: Context) {
        nsView.setState(state)
    }

    static func dismantleNSView(_ nsView: CatStatusAnimationView, coordinator: ()) {
        nsView.stopAnimating()
    }
}

final class CatStatusAnimationView: NSView {
    private static let transitionDuration: TimeInterval = 0.22
    private let tintLayer = CALayer()
    private let frameLayer = CALayer()
    private var state: CatActivityState?
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

    func setState(_ newState: CatActivityState) {
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
        frameLayer.removeAnimation(forKey: "cat-status")
        transitionTask?.cancel()

        guard !isInitialState,
              let previousFrame,
              let nextFrame = frames.first
        else {
            startAnimating(duration: newState.animationDuration)
            return
        }

        playTransition(from: previousFrame, to: nextFrame)
        let expectedState = newState
        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.transitionDuration))
            guard !Task.isCancelled, self?.state == expectedState else { return }
            self?.startAnimating(duration: expectedState.animationDuration)
        }
    }

    private func startAnimating(duration: TimeInterval) {
        guard !frames.isEmpty, frameLayer.animation(forKey: "cat-status") == nil else { return }

        frameLayer.contents = frames[0]
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        frameLayer.add(animation, forKey: "cat-status")
    }

    func stopAnimating() {
        transitionTask?.cancel()
        transitionTask = nil
        frameLayer.removeAnimation(forKey: "cat-status")
        frameLayer.removeAnimation(forKey: "cat-transition")
    }

    private func playTransition(from previousFrame: CGImage, to nextFrame: CGImage) {
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
        transition.duration = Self.transitionDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        frameLayer.add(transition, forKey: "cat-transition")
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
