import Foundation

/// Reconnect delays: one second doubling to thirty, with up to a quarter
/// extra so a hub that restarts does not see every client return in step.
/// The jitter source is passed in so the schedule is testable.
public struct HubBackoff: Sendable, Equatable {
    public var initial: TimeInterval
    public var maximum: TimeInterval
    public var jitterFraction: Double

    public init(initial: TimeInterval = 1, maximum: TimeInterval = 30, jitterFraction: Double = 0.25) {
        self.initial = initial
        self.maximum = maximum
        self.jitterFraction = jitterFraction
    }

    /// `attempt` counts consecutive failures from zero; `jitter` is in 0...1.
    public func delay(attempt: Int, jitter: Double) -> TimeInterval {
        // Clamped so a long outage cannot overflow the exponent.
        let exponent = Double(min(max(attempt, 0), 16))
        let base = min(maximum, initial * pow(2, exponent))
        let spread = min(max(jitter, 0), 1)
        return min(maximum, base * (1 + jitterFraction * spread))
    }
}
