import Foundation

public struct PracticePlaybackSchedule: Equatable, Sendable {
    public let duration: TimeInterval
    public let loopMode: PracticeLoopMode
    public let loopRange: PracticeLoopRange?
    public let speed: Double

    public init(
        duration: TimeInterval,
        loopMode: PracticeLoopMode,
        loopRange: PracticeLoopRange?,
        speed: Double
    ) {
        self.duration = max(0, duration)
        self.loopMode = loopMode
        self.loopRange = loopRange
        self.speed = speed.isFinite ? min(1.5, max(0.5, speed)) : 1
    }

    public func advancedElapsed(from elapsed: TimeInterval, by realTimeDelta: TimeInterval) -> TimeInterval {
        let candidate = max(0, elapsed) + max(0, realTimeDelta) * speed
        switch loopMode {
        case .off:
            return min(duration, candidate)
        case .song:
            guard duration > 0 else { return 0 }
            return candidate.truncatingRemainder(dividingBy: duration)
        case .section:
            guard let loopRange, loopRange.duration > 0 else {
                return min(duration, candidate)
            }
            if candidate < loopRange.start {
                return loopRange.start
            }
            let offset = candidate - loopRange.start
            return loopRange.start + offset.truncatingRemainder(dividingBy: loopRange.duration)
        }
    }

    public func wrapTarget(forElapsed elapsed: TimeInterval) -> TimeInterval? {
        switch loopMode {
        case .off:
            return nil
        case .song:
            return duration > 0 && elapsed >= duration ? 0 : nil
        case .section:
            guard let loopRange, loopRange.duration > 0 else { return nil }
            return elapsed >= loopRange.end ? loopRange.start : nil
        }
    }
}

public enum PlaybackTickAction: Equatable, Sendable {
    case wrap(to: TimeInterval)
    case finished
    case progress(TimeInterval)
}

extension PracticePlaybackSchedule {
    public func tickAction(forElapsed elapsed: TimeInterval) -> PlaybackTickAction {
        // Wrap is checked before finished: a section loop whose end equals the
        // track duration must wrap, not advance the queue.
        if let target = wrapTarget(forElapsed: elapsed) {
            return .wrap(to: target)
        }
        if elapsed >= duration {
            return .finished
        }
        return .progress(elapsed)
    }
}
