import Foundation

/// The four htdemucs stems returned in-memory by a `StemSeparating` engine.
///
/// Float-throughout (the native-engine D4 principle) and `Sendable`: only plain
/// `[Float]` copies cross the actor boundary from the engine, never the engine's
/// non-`Sendable` backend arrays (MLX/MPSGraph). Each stem is stored as
/// non-interleaved channel buffers at `sampleRate` — htdemucs is stereo, and the
/// downstream consumers both need channels + rate:
///
///  - `StemMixdown`'s buffer entry (Task 8) mixes `[[Float]]` channels at a known
///    rate with no WAV round-trip;
///  - `BackbeatSepBench` (Task 6) compares the engine's per-channel output against
///    the demucs oracle WAVs for the SI-SDR parity gate (G1).
///
/// The architecture diagram's `{drums,bass,other,vocals: [Float]}` shorthand
/// elides the channel/rate detail this concrete type carries; that detail is
/// load-bearing, so it lives here rather than being rediscovered per consumer.
public struct SeparatedStems: Sendable, Equatable {
    public var sampleRate: Double
    public var drums: [[Float]]
    public var bass: [[Float]]
    public var other: [[Float]]
    public var vocals: [[Float]]

    public init(
        sampleRate: Double,
        drums: [[Float]],
        bass: [[Float]],
        other: [[Float]],
        vocals: [[Float]]
    ) {
        self.sampleRate = sampleRate
        self.drums = drums
        self.bass = bass
        self.other = other
        self.vocals = vocals
    }

    /// The stem identities, in the htdemucs stem order.
    public enum Stem: String, CaseIterable, Sendable {
        case drums
        case bass
        case other
        case vocals
    }

    public subscript(stem: Stem) -> [[Float]] {
        get {
            switch stem {
            case .drums: drums
            case .bass: bass
            case .other: other
            case .vocals: vocals
            }
        }
        set {
            switch stem {
            case .drums: drums = newValue
            case .bass: bass = newValue
            case .other: other = newValue
            case .vocals: vocals = newValue
            }
        }
    }

    /// The stem buffers in htdemucs order, paired with their identity.
    public var byStem: [(stem: Stem, channels: [[Float]])] {
        Stem.allCases.map { (stem: $0, channels: self[$0]) }
    }
}

/// A fractional (0...1) progress callback emitted per inference segment. It is
/// synchronous and `@Sendable` so an engine confined to a background actor can
/// report progress without hopping actors; the render layer maps it onto the
/// pinned `RenderProgressState` stages.
public typealias StemSeparationProgress = @Sendable (Double) -> Void

/// The seam the native (MLX/MPSGraph) engine implements and the render queue
/// injects — the single replacement point for the demucs subprocess.
///
/// `separate(source:progress:)` is `async` and cancellable *between* inference
/// segments (quality gate G4): an implementation checks `Task.isCancelled` at
/// each segment boundary and throws `CancellationError` cooperatively, so cancel
/// latency is ≤ one segment. It returns the stems in memory (`SeparatedStems`)
/// rather than writing WAVs, so the buffer-based mix path has no disk round-trip.
public protocol StemSeparating: Sendable {
    func separate(
        source: URL,
        progress: StemSeparationProgress?
    ) async throws -> SeparatedStems
}

public extension StemSeparating {
    /// Convenience overload for callers that do not observe progress.
    func separate(source: URL) async throws -> SeparatedStems {
        try await separate(source: source, progress: nil)
    }
}

/// The null engine used where BackbeatCore must name a `StemSeparating` but has no
/// backend to offer: the real engine (`CustomHTDemucsSeparator`) lives in the MLX target,
/// which BackbeatCore cannot depend on (keeping `swift test` MLX/weights-free). It
/// is passed *explicitly* at those sites — the `RenderQueueCoordinator` default
/// closure (overridden by the app with the real engine) and previews/fallbacks —
/// so a missing real injection is a visible, deliberate choice rather than a silent
/// default. Invoked, it fails loudly rather than producing nothing.
public struct UnavailableStemSeparator: StemSeparating {
    public init() {}

    public func separate(
        source: URL,
        progress: StemSeparationProgress?
    ) async throws -> SeparatedStems {
        throw BoostedDrumsRenderError.missingCommand("separation engine")
    }
}
