import Foundation

public struct PracticeLoopRange: Equatable, Sendable {
    public static let minimumDuration: TimeInterval = 0.05

    public let start: TimeInterval
    public let end: TimeInterval

    public var duration: TimeInterval {
        max(0, end - start)
    }

    public init(
        start: TimeInterval,
        end: TimeInterval,
        duration trackDuration: TimeInterval,
        minimumDuration: TimeInterval = PracticeLoopRange.minimumDuration
    ) {
        let trackDuration = max(0, trackDuration)
        let minimumDuration = min(max(0, minimumDuration), trackDuration)
        var lower = Self.clamp(min(start, end), to: 0...trackDuration)
        var upper = Self.clamp(max(start, end), to: 0...trackDuration)

        if upper - lower < minimumDuration {
            let midpoint = Self.clamp((lower + upper) / 2, to: 0...trackDuration)
            lower = Self.clamp(midpoint - minimumDuration / 2, to: 0...max(0, trackDuration - minimumDuration))
            upper = min(trackDuration, lower + minimumDuration)
        }

        self.start = lower
        self.end = upper
    }

    public func movingStart(to elapsed: TimeInterval, trackDuration: TimeInterval) -> PracticeLoopRange {
        PracticeLoopRange(start: elapsed, end: end, duration: trackDuration)
    }

    public func movingEnd(to elapsed: TimeInterval, trackDuration: TimeInterval) -> PracticeLoopRange {
        PracticeLoopRange(start: start, end: elapsed, duration: trackDuration)
    }

    private static func clamp(_ value: TimeInterval, to range: ClosedRange<TimeInterval>) -> TimeInterval {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
