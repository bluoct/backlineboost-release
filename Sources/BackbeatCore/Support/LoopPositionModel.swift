import Foundation

/// Maps cumulative rendered file-domain frames to a song position, piecewise-
/// modularly around a chain anchor, for the gapless A/B section-loop chain
/// (D-094): a pre-scheduled `scheduleSegment` queue plays `head→[A→B][A→B]…`
/// sample-contiguously, and this model turns "how many frames has the node
/// rendered since the chain was built" into "where is that in the song."
///
/// Content-domain contract: under a downstream `AVAudioUnitTimePitch` the
/// player node's sample position advances in song-time units (D-010/D-011),
/// so playback speed never appears in this model and speed changes never
/// invalidate a chain.
///
/// Generation stamping exists because AVFoundation fires completion handlers
/// for flushed segments on `node.stop()` — stale completions must be
/// droppable (the loop-off/seek/stop race).
public struct LoopPositionModel: Equatable, Sendable {
    public let loopStartFrame: Int64
    public let loopEndFrame: Int64
    public let anchorFrame: Int64
    public let generation: UInt64

    private init(loopStartFrame: Int64, loopEndFrame: Int64, anchorFrame: Int64, generation: UInt64) {
        self.loopStartFrame = loopStartFrame
        self.loopEndFrame = loopEndFrame
        self.anchorFrame = anchorFrame
        self.generation = generation
    }

    /// The only public way to construct a model. Validation order matters:
    /// (1) clamp `loopStartFrame` to non-negative; (2) require the loop to
    /// hold at least `minimumFrameCount` frames, else fail (degenerate or
    /// micro loops degrade to linear playback upstream); (3) clamp
    /// `anchorFrame` to non-negative, then snap it to `loopStartFrame` if it
    /// is at or past `loopEndFrame` (immediate-wrap semantics). An anchor
    /// below `loopStartFrame` is legal and kept as-is — a pre-roll head that
    /// plays anchor→B before the first full A→B iteration.
    public static func validated(
        loopStartFrame: Int64,
        loopEndFrame: Int64,
        anchorFrame: Int64,
        generation: UInt64,
        minimumFrameCount: Int64 = 1
    ) -> LoopPositionModel? {
        let clampedStart = max(0, loopStartFrame)
        guard loopEndFrame - clampedStart >= max(1, minimumFrameCount) else { return nil }

        var clampedAnchor = max(0, anchorFrame)
        if clampedAnchor >= loopEndFrame {
            clampedAnchor = clampedStart
        }

        return LoopPositionModel(
            loopStartFrame: clampedStart,
            loopEndFrame: loopEndFrame,
            anchorFrame: clampedAnchor,
            generation: generation
        )
    }

    public var loopFrameCount: Int64 { loopEndFrame - loopStartFrame }

    /// The pre-roll/lead-in segment: anchor→B. `count` is always > 0 by
    /// construction (the anchor is always strictly below `loopEndFrame`).
    public var headFrames: (start: Int64, count: Int64) {
        (anchorFrame, loopEndFrame - anchorFrame)
    }

    /// The steady-state A→B segment scheduled repeatedly once the head has
    /// played.
    public var iterationFrames: (start: Int64, count: Int64) {
        (loopStartFrame, loopFrameCount)
    }

    /// `rendered` is cumulative frames rendered since the chain was built.
    /// The result is always `< loopEndFrame` — that invariant is what keeps
    /// the controller's `.wrap` branch unreachable while a chain is active.
    public func positionFrame(forRenderedFrames rendered: Int64) -> Int64 {
        let r = max(0, rendered)
        let head = headFrames.count
        if r < head {
            return anchorFrame + r
        }
        return loopStartFrame + (r - head) % loopFrameCount
    }

    public func positionSeconds(forRenderedFrames rendered: Int64, sampleRate: Double) -> TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        return Double(positionFrame(forRenderedFrames: rendered)) / sampleRate
    }

    /// The one seconds→frames rounding rule both playback engines must
    /// share, so they never disagree about a frame boundary.
    public static func frame(forSeconds seconds: TimeInterval, sampleRate: Double) -> Int64 {
        guard seconds.isFinite, sampleRate.isFinite else { return 0 }
        return Int64((max(0, seconds) * sampleRate).rounded())
    }

    /// How many loop iterations an engine should keep scheduled ahead of
    /// playback so the queue never runs dry: enough iterations to cover
    /// `minimumQueuedSeconds` of content, floored at 2 and capped at 64.
    public func iterationsToKeepQueued(sampleRate: Double, minimumQueuedSeconds: TimeInterval = 2.0) -> Int {
        guard sampleRate.isFinite, sampleRate > 0, minimumQueuedSeconds.isFinite, minimumQueuedSeconds > 0 else {
            return 2
        }
        let target = (minimumQueuedSeconds * sampleRate / Double(loopFrameCount)).rounded(.up)
        return min(64, max(2, Int(target)))
    }

    /// The named stale-completion predicate: a completion handler captures
    /// the generation it was scheduled under, and drops itself once this
    /// returns false.
    public func isCurrent(inGeneration generation: UInt64) -> Bool {
        self.generation == generation
    }
}
