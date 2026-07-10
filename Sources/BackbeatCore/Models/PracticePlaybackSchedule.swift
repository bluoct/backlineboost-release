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
        let clampedDuration = max(0, duration)
        self.duration = clampedDuration
        self.loopMode = loopMode
        // A range starting at or past the file-derived duration can never be
        // reached, so it degrades to nil (plain run-to-end) instead of being
        // round-tripped through PracticeLoopRange.init, whose 0.05s minimum-length
        // re-centering would otherwise manufacture a "valid" micro-loop at EOF —
        // the exact silent stall this clamp exists to close.
        if let loopRange, loopRange.start < clampedDuration {
            self.loopRange = PracticeLoopRange(
                start: loopRange.start,
                end: min(loopRange.end, clampedDuration),
                duration: clampedDuration
            )
        } else {
            self.loopRange = nil
        }
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
