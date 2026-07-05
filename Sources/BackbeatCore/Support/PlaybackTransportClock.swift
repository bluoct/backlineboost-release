import Foundation

public struct PlaybackTransportClock: Equatable, Sendable {
    public private(set) var speed: Double = 1

    private var duration: TimeInterval = 0
    private var scheduledStartElapsed: TimeInterval = 0
    private var wallAnchorElapsed: TimeInterval = 0
    private var startedAt: Date?

    public init() {}

    public mutating func start(fromElapsed elapsed: TimeInterval, duration: TimeInterval, at date: Date = Date()) {
        self.duration = duration
        scheduledStartElapsed = bounded(elapsed)
        wallAnchorElapsed = scheduledStartElapsed
        startedAt = date
    }

    public mutating func prepare(atElapsed elapsed: TimeInterval, duration: TimeInterval) {
        self.duration = duration
        scheduledStartElapsed = bounded(elapsed)
        wallAnchorElapsed = scheduledStartElapsed
        startedAt = nil
    }

    public mutating func pause(committing elapsed: TimeInterval? = nil, at date: Date = Date()) {
        let committed = bounded(elapsed ?? wallElapsed(at: date))
        scheduledStartElapsed = committed
        wallAnchorElapsed = committed
        startedAt = nil
    }

    public mutating func stop() {
        scheduledStartElapsed = 0
        wallAnchorElapsed = 0
        startedAt = nil
    }

    public mutating func setSpeed(_ newSpeed: Double, committing elapsed: TimeInterval? = nil, at date: Date = Date()) {
        // Re-anchor only the wall fallback; scheduledStartElapsed must stay fixed
        // because the player node's sample position keeps counting from the
        // scheduled segment start across rate changes.
        if startedAt != nil {
            wallAnchorElapsed = bounded(elapsed ?? wallElapsed(at: date))
            startedAt = date
        }
        speed = min(1.5, max(0.5, newSpeed.isFinite ? newSpeed : 1))
    }

    public func elapsed(renderedSeconds: TimeInterval? = nil, at date: Date = Date()) -> TimeInterval {
        if let renderedSeconds, startedAt != nil {
            // No speed multiply: the time-pitch unit downstream pulls content at
            // rate x, so the node's sample position already advances scaled.
            return bounded(scheduledStartElapsed + max(0, renderedSeconds))
        }
        return bounded(wallElapsed(at: date))
    }

    private func wallElapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return wallAnchorElapsed }
        return wallAnchorElapsed + max(0, date.timeIntervalSince(startedAt)) * speed
    }

    private func bounded(_ elapsed: TimeInterval) -> TimeInterval {
        duration > 0 ? min(max(0, elapsed), duration) : max(0, elapsed)
    }
}
