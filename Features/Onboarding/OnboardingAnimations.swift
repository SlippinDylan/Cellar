import AppKit
import QuartzCore
import SwiftUI

struct OnboardingIntroAnimationView: NSViewRepresentable {
    let onComplete: @MainActor () -> Void

    func makeNSView(context: Context) -> OnboardingIntroHostView {
        let view = OnboardingIntroHostView(image: NSApp.applicationIconImage)
        view.play(completion: onComplete)
        return view
    }

    func updateNSView(_ nsView: OnboardingIntroHostView, context: Context) {}

    static func dismantleNSView(_ nsView: OnboardingIntroHostView, coordinator: ()) {
        nsView.cancel()
    }
}

@MainActor
final class OnboardingIntroHostView: NSView {
    private var task: Task<Void, Never>?
    private var didStartAnimation = false
    private var pendingCompletion: (@MainActor () -> Void)?
    private let icon = CALayer()
    private let particles = CALayer()
    private let appIcon: NSImage

    init(image: NSImage) {
        appIcon = image
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    isolated deinit { task?.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        startTimelineIfReady()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if icon.superlayer == nil {
            setupLayers()
        }
        startTimelineIfReady()
    }

    private func setupLayers() {
        let size: CGFloat = 136
        let origin = CGPoint(x: (bounds.width - size) / 2, y: bounds.height * 0.61 - size / 2)
        icon.frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        icon.contentsScale = 2
        icon.contents = appIcon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        icon.contentsGravity = .resizeAspect
        particles.frame = bounds
        layer?.addSublayer(icon)
        layer?.addSublayer(particles)
    }

    func play(completion: @escaping @MainActor () -> Void) {
        guard !didStartAnimation, pendingCompletion == nil else { return }
        pendingCompletion = completion
        startTimelineIfReady()
    }

    private func startTimelineIfReady() {
        guard !didStartAnimation, let completion = pendingCompletion, window != nil else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            didStartAnimation = true
            pendingCompletion = nil
            task = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                completion()
            }
            return
        }

        guard bounds.width > 0, bounds.height > 0 else { return }
        if icon.superlayer == nil { setupLayers() }
        didStartAnimation = true
        pendingCompletion = nil
        startEntranceAnimation()
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1180))
                guard let self, !Task.isCancelled else { return }
                self.burst()
                try await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                completion()
            } catch is CancellationError {
                // Closing or leaving the view cancels the opening timeline.
            } catch {}
        }
    }

    private func startEntranceAnimation() {
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.12, 1.09, 1, 1.06, 0.96, 1.12]
        scale.keyTimes = [0, 0.44, 0.58, 0.87, 0.94, 1]
        let shake = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        shake.values = [0, 0, -0.087, 0.087, -0.122, 0.122, -0.052, 0]
        shake.keyTimes = [0, 0.58, 0.66, 0.73, 0.80, 0.87, 0.94, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, shake]
        group.duration = 1.18
        icon.add(group, forKey: "entrance")
    }

    func cancel() {
        pendingCompletion = nil
        task?.cancel()
        task = nil
        icon.removeAllAnimations()
        for shard in particles.sublayers ?? [] { shard.removeAllAnimations() }
    }

    private func burst() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        icon.isHidden = true
        for y in 0..<4 {
            for x in 0..<4 {
                let shard = CALayer()
                shard.contents = icon.contents
                shard.contentsRect = CGRect(x: CGFloat(x) / 4, y: CGFloat(y) / 4, width: 0.25, height: 0.25)
                shard.frame = CGRect(
                    x: icon.frame.minX + CGFloat(x) * 34,
                    y: icon.frame.maxY - CGFloat(y + 1) * 34,
                    width: 34,
                    height: 34
                )
                particles.addSublayer(shard)
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = shard.position
                move.toValue = CGPoint(
                    x: shard.position.x + (CGFloat(x) - 1.5) * 98,
                    y: shard.position.y - (CGFloat(y) - 1.5) * 92
                )
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0
                spin.toValue = Double(x - y) * 0.28
                let group = CAAnimationGroup()
                group.animations = [move, fade, spin]
                group.duration = 0.5
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shard.opacity = 0
                shard.add(group, forKey: "scatter")
            }
        }
        CATransaction.commit()
    }
}

struct OnboardingCelebrationIconView: NSViewRepresentable {
    func makeNSView(context: Context) -> OnboardingCelebrationHostView {
        OnboardingCelebrationHostView()
    }

    func updateNSView(_ nsView: OnboardingCelebrationHostView, context: Context) {}
}

@MainActor
final class OnboardingCelebrationHostView: NSView {
    private let iconView = NSImageView()
    private var didCelebrate = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        iconView.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        iconView.contentTintColor = .systemGreen
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.clipsToBounds = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didCelebrate else { return }
        didCelebrate = true
        layoutSubtreeIfNeeded()
        celebrate()
    }

    private func celebrate() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = iconView.layer else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6
        pop.toValue = 1
        pop.damping = 12
        pop.stiffness = 180
        pop.duration = 0.6
        layer.add(pop, forKey: "success")

        let colors: [NSColor] = [.systemPink, .systemYellow, .systemBlue, .systemGreen, .systemOrange]
        for index in 0..<24 {
            let particle = CALayer()
            particle.bounds = CGRect(x: 0, y: 0, width: 5, height: 8)
            particle.position = CGPoint(x: 40, y: 40)
            particle.cornerRadius = 1
            iconView.effectiveAppearance.performAsCurrentDrawingAppearance {
                particle.backgroundColor = colors[index % colors.count].cgColor
            }
            particle.opacity = 0
            layer.addSublayer(particle)
            let angle = CGFloat(index) * .pi * 2 / 24
            let distance = CGFloat(75 + (index % 4) * 16)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = particle.position
            move.toValue = CGPoint(x: 40 + cos(angle) * distance, y: 40 + sin(angle) * distance)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.toValue = angle * 2
            let group = CAAnimationGroup()
            group.animations = [move, fade, spin]
            group.duration = 0.8
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            particle.add(group, forKey: "confetti")
        }
    }
}

struct OnboardingWindowConfigurator: NSViewRepresentable {
    let restoresMainWindowOnTeardown: Bool
    let shouldClose: @MainActor () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(restoresMainWindowOnTeardown: restoresMainWindowOnTeardown, shouldClose: shouldClose)
    }

    func makeNSView(context: Context) -> OnboardingWindowObserverView {
        let view = OnboardingWindowObserverView()
        view.onAttachToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.configure(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: OnboardingWindowObserverView, context: Context) {
        context.coordinator.restoresMainWindowOnTeardown = restoresMainWindowOnTeardown
        context.coordinator.shouldClose = shouldClose
        if let window = nsView.window {
            context.coordinator.configure(window: window)
        }
    }

    static func dismantleNSView(_ nsView: OnboardingWindowObserverView, coordinator: Coordinator) {
        nsView.onAttachToWindow = nil
        coordinator.teardown()
    }

    @MainActor
    final class OnboardingWindowObserverView: NSView {
        var onAttachToWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onAttachToWindow?(window)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var restoresMainWindowOnTeardown: Bool
        var shouldClose: @MainActor () -> Bool
        private weak var configuredWindow: NSWindow?
        // AppKit invokes NSWindowDelegate selector queries on the main thread.
        nonisolated(unsafe) private weak var originalDelegate: (any NSWindowDelegate)?

        init(restoresMainWindowOnTeardown: Bool = false, shouldClose: @escaping @MainActor () -> Bool) {
            self.restoresMainWindowOnTeardown = restoresMainWindowOnTeardown
            self.shouldClose = shouldClose
        }

        func configure(window: NSWindow) {
            if configuredWindow === window {
                if window.delegate !== self {
                    originalDelegate = window.delegate
                    window.delegate = self
                }
                return
            }
            teardown()
            configuredWindow = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.remove([.resizable, .miniaturizable])
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.setContentSize(NSSize(width: 460, height: 560))
            window.center()

            if window.delegate !== self {
                originalDelegate = window.delegate
                window.delegate = self
            }
        }

        func teardown() {
            if let window = configuredWindow {
                if window.delegate === self {
                    window.delegate = originalDelegate
                }
                if restoresMainWindowOnTeardown {
                    window.styleMask.insert([.resizable, .miniaturizable])
                    window.titleVisibility = .visible
                    window.titlebarAppearsTransparent = false
                    window.setContentSize(NSSize(width: 1080, height: 720))
                    window.center()
                }
            }
            configuredWindow = nil
            originalDelegate = nil
        }

        // Intercept close button, Command-W, and File -> Close uniformly while preserving SwiftUI's delegate.
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return (originalDelegate as? NSObjectProtocol)?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let delegate = originalDelegate as? NSObjectProtocol, delegate.responds(to: aSelector) {
                return delegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
