/// Distinguishes bounded cold-launch waiting from losing a previously visible window.
struct SettingsWindowTrackingState {
    private enum Phase {
        case stopped
        case awaitingWindow(deadline: ContinuousClock.Instant)
        case following(consecutiveMisses: Int)
    }

    private let missingWindowThreshold: Int
    private let startupTimeout: Duration
    private var phase = Phase.stopped

    init(missingWindowThreshold: Int = 12, startupTimeout: Duration = .seconds(10)) {
        precondition(missingWindowThreshold > 0 && startupTimeout > .zero)
        self.missingWindowThreshold = missingWindowThreshold
        self.startupTimeout = startupTimeout
    }

    mutating func start(at instant: ContinuousClock.Instant) {
        phase = .awaitingWindow(deadline: instant.advanced(by: startupTimeout))
    }

    /// Returns true once when either startup times out or the visible target stays absent.
    mutating func observe(isVisible: Bool, at instant: ContinuousClock.Instant) -> Bool {
        switch phase {
        case .stopped:
            return false
        case .awaitingWindow(let deadline):
            if isVisible {
                phase = .following(consecutiveMisses: 0)
                return false
            }
            guard instant >= deadline else { return false }
            phase = .stopped
            return true
        case .following(let consecutiveMisses):
            let misses = isVisible ? 0 : consecutiveMisses + 1
            guard misses >= missingWindowThreshold else {
                phase = .following(consecutiveMisses: misses)
                return false
            }
            phase = .stopped
            return true
        }
    }

    mutating func reset() { phase = .stopped }
}
