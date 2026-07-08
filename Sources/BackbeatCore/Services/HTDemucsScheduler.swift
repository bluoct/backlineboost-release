import Accelerate
import Foundation

/// Errors thrown by the pure `HTDemucsScheduler` functions. `LocalizedError` from
/// day one (review finding R4): scheduler errors surface through the render-failed
/// banner, which renders `errorDescription`.
public enum HTDemucsSchedulerError: Error, LocalizedError, Equatable {
    case emptyTrack
    case invalidOverlap(Double)

    public var errorDescription: String? {
        switch self {
        case .emptyTrack:
            return "Stem separation received a track with no samples."
        case .invalidOverlap(let overlap):
            return "Stem separation was configured with an invalid segment overlap (\(overlap))."
        }
    }
}

/// The segmentation/overlap-add scheduler of the custom HTDemucs engine (charter
/// Phase 3): the exact `apply_model(shifts=0, split=True, overlap=0.1)` semantics
/// of upstream demucs 4.0.1 `apply.py`, as pure functions on `[Float]` buffers —
/// written from the `.venv` Python reference (G6), never from the vendored port.
///
/// Pinned semantics (verified against the reference source and the shipped
/// checkpoint's kwargs; the hermetic `HTDemucsSchedulerTests` hold them):
///
/// - **Every model call is exactly `segmentLength` samples.** The checkpoint has
///   `use_train_segment = true` (constructor default; absent from its kwargs), so
///   the per-chunk recursive `apply_model` call pads each chunk to
///   `HTDemucs.valid_length(...) = int(segment · samplerate) = 343_980` via
///   `TensorChunk.padded` — **centered**: a short final chunk pulls real audio
///   from *before* its offset on the left and zero-pads on the right, and the
///   model output is `center_trim`ed back to the chunk span (`delta // 2` off the
///   left, the remainder off the right). It is *not* a right-zero-pad, and
///   `HTDemucs.forward`'s internal pre-pad never fires in this pipeline.
/// - **Chunking**: `stride = int((1 − overlap) · segmentLength)` (= 309_582 at
///   the pinned overlap 0.1); chunk offsets are `0, stride, 2·stride, …` strictly
///   below the track length, so the final chunk can be as short as one sample. A
///   track shorter than one segment is a single centered-zero-padded window.
/// - **Transition weights**: the triangle `[1…half, half…1] / half` with
///   `half = segmentLength / 2`, computed in fp32 exactly like torch's
///   int-tensor true division (`transition_power = 1` is an exact no-op).
///   Accumulation is `out[offset…] += weight[:len] · trimmedChunk` and
///   `sumWeight[offset…] += weight[:len]`, then one final `out /= sumWeight` —
///   fp32 throughout, matching the CPU oracle's arithmetic.
/// - **Track-level normalization** (`separate.py`): `ref` = per-sample mono mean
///   of the mix; subtract the scalar `ref.mean()`, divide by the scalar
///   `ref.std()` (torch default — **unbiased**, no epsilon); stems are
///   denormalized with the same two scalars, in the same op order (`*=` then
///   `+=`). One recorded deviation: a silent track (`std ≈ 0`) clamps the scale
///   to 1 instead of dividing by zero — upstream would produce non-finite output.
/// - The CLI's bag-of-models wrapper is a bag of ONE model with unit weights for
///   this checkpoint — arithmetic identity — so it is deliberately not modeled.
public enum HTDemucsScheduler {
    /// `int(model.segment · model.samplerate)` = `44_100 · 39/5`, exact.
    public static let segmentLength = 343_980
    /// The pinned separation overlap (`--overlap 0.1`, hardcoded app-wide).
    public static let defaultOverlap = 0.1

    /// `stride = int((1 − overlap) · segment_length)` — Python `int()` truncates,
    /// as does `Int(_: Double)`. 309_582 at the default overlap.
    public static func stride(overlap: Double = defaultOverlap) -> Int {
        Int((1.0 - overlap) * Double(segmentLength))
    }

    /// One scheduled segment: the chunk of the track it is responsible for, plus
    /// the centered `segmentLength`-sample model window that produces it.
    ///
    /// The window is `padLeft` zeros + `track[sourceStart..<sourceEnd]` +
    /// `padRight` zeros (always exactly `segmentLength` samples), and the model
    /// output samples `[trimOffset, trimOffset + length)` line up with track
    /// positions `[offset, offset + length)` — the `center_trim` alignment.
    public struct Chunk: Sendable, Equatable {
        /// Track position this chunk is responsible for.
        public let offset: Int
        /// Chunk length: `min(trackLength − offset, segmentLength)`.
        public let length: Int
        /// First real-audio sample of the model window (clamped to the track).
        public let sourceStart: Int
        /// One past the last real-audio sample of the model window.
        public let sourceEnd: Int
        /// Zeros prepended to the window (only when the track start clips it).
        public let padLeft: Int
        /// Zeros appended to the window (only when the track end clips it).
        public let padRight: Int
        /// `delta // 2` — where the chunk starts inside the model output.
        public let trimOffset: Int
    }

    /// Schedule a track: the `TensorChunk`/`padded`/`center_trim` math of
    /// upstream `apply_model`, one `Chunk` per segment in offset order.
    public static func plan(
        trackLength: Int, overlap: Double = defaultOverlap
    ) throws -> [Chunk] {
        guard trackLength > 0 else { throw HTDemucsSchedulerError.emptyTrack }
        let strideLength = stride(overlap: overlap)
        guard strideLength > 0, strideLength <= segmentLength else {
            throw HTDemucsSchedulerError.invalidOverlap(overlap)
        }

        var chunks: [Chunk] = []
        chunks.reserveCapacity((trackLength + strideLength - 1) / strideLength)
        var offset = 0
        while offset < trackLength {
            let length = min(trackLength - offset, segmentLength)
            let delta = segmentLength - length
            // `TensorChunk.padded(segmentLength)`: extend `delta // 2` to the
            // left and the remainder to the right, clamping to the real track
            // and zero-filling whatever the clamp cut off.
            let start = offset - delta / 2
            let end = start + segmentLength
            let sourceStart = max(0, start)
            let sourceEnd = min(trackLength, end)
            chunks.append(Chunk(
                offset: offset,
                length: length,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                padLeft: sourceStart - start,
                padRight: end - sourceEnd,
                trimOffset: delta / 2))
            offset += strideLength
        }
        return chunks
    }

    /// The overlap-add transition weights, `segmentLength` long: torch's
    /// `cat([arange(1, half+1), arange(half, 0, -1)]) / half` computed in fp32
    /// (integer values ≤ 2²⁴ are exact in `Float`, and the division matches
    /// torch's int-tensor true division). Peak value 1 at the two middle samples.
    public static let transitionWeights: [Float] = {
        let half = segmentLength / 2
        var weights = [Float](repeating: 0, count: segmentLength)
        var rampStart = Float(1)
        var rampStep = Float(1)
        weights.withUnsafeMutableBufferPointer { buffer in
            vDSP_vramp(&rampStart, &rampStep, buffer.baseAddress!, 1, vDSP_Length(half))
            rampStart = Float(segmentLength - half)
            rampStep = -1
            vDSP_vramp(
                &rampStart, &rampStep, buffer.baseAddress! + half, 1,
                vDSP_Length(segmentLength - half))
        }
        var maximum = Float(half)
        vDSP_vsdiv(weights, 1, &maximum, &weights, 1, vDSP_Length(segmentLength))
        return weights
    }()
}

/// The track-level normalization scalars of upstream `separate.py`: the mean and
/// **unbiased** standard deviation of the per-sample mono mean of the mix,
/// measured before normalization and reused verbatim for denormalization.
public struct HTDemucsTrackNormalization: Sendable, Equatable {
    public let mean: Float
    public let std: Float

    public init(mean: Float, std: Float) {
        self.mean = mean
        self.std = std
    }

    /// Measure the scalars from channel-major audio. Chunked vDSP passes with
    /// double accumulators (O(chunk) memory — the P6 lesson); two-pass variance
    /// so a DC-heavy signal can't cancel catastrophically. A silent/degenerate
    /// track clamps `std` to 1 (the recorded deviation from upstream, which
    /// would divide by zero).
    public static func measure(_ channels: [[Float]]) -> HTDemucsTrackNormalization {
        guard let length = channels.first?.count, length > 0 else {
            return HTDemucsTrackNormalization(mean: 0, std: 1)
        }
        let channelScale = Float(1) / Float(channels.count)
        let chunkCapacity = min(length, 1 << 18)
        var monoScratch = [Float](repeating: 0, count: chunkCapacity)

        func accumulate(_ body: (UnsafeBufferPointer<Float>) -> Double) -> Double {
            var total = 0.0
            var position = 0
            while position < length {
                let count = min(chunkCapacity, length - position)
                monoScratch.withUnsafeMutableBufferPointer { mono in
                    channels[0].withUnsafeBufferPointer { first in
                        var scale = channelScale
                        vDSP_vsmul(
                            first.baseAddress! + position, 1, &scale,
                            mono.baseAddress!, 1, vDSP_Length(count))
                    }
                    for channel in channels.dropFirst() {
                        channel.withUnsafeBufferPointer { other in
                            var scale = channelScale
                            vDSP_vsma(
                                other.baseAddress! + position, 1, &scale,
                                mono.baseAddress!, 1,
                                mono.baseAddress!, 1, vDSP_Length(count))
                        }
                    }
                    total += body(UnsafeBufferPointer(rebasing: mono[0..<count]))
                }
                position += count
            }
            return total
        }

        let sum = accumulate { mono in
            var chunkSum: Float = 0
            vDSP_sve(mono.baseAddress!, 1, &chunkSum, vDSP_Length(mono.count))
            return Double(chunkSum)
        }
        let mean = Float(sum / Double(length))

        guard length > 1 else { return HTDemucsTrackNormalization(mean: mean, std: 1) }
        var negativeMean = -mean
        var deviationScratch = [Float](repeating: 0, count: chunkCapacity)
        let squaredSum = deviationScratch.withUnsafeMutableBufferPointer { deviations in
            accumulate { mono in
                vDSP_vsadd(
                    mono.baseAddress!, 1, &negativeMean,
                    deviations.baseAddress!, 1, vDSP_Length(mono.count))
                var chunkSquares: Float = 0
                vDSP_svesq(deviations.baseAddress!, 1, &chunkSquares, vDSP_Length(mono.count))
                return Double(chunkSquares)
            }
        }
        let std = Float((squaredSum / Double(length - 1)).squareRoot())
        guard std.isFinite, std > 0 else { return HTDemucsTrackNormalization(mean: mean, std: 1) }
        return HTDemucsTrackNormalization(mean: mean, std: std)
    }

    /// `wav -= ref.mean(); wav /= ref.std()` — the upstream op order (subtract,
    /// then divide, two rounding steps), applied in place.
    public func normalize(_ channels: inout [[Float]]) {
        var negativeMean = -mean
        var divisor = std
        for index in channels.indices {
            let count = vDSP_Length(channels[index].count)
            channels[index].withUnsafeMutableBufferPointer { buffer in
                vDSP_vsadd(buffer.baseAddress!, 1, &negativeMean, buffer.baseAddress!, 1, count)
                vDSP_vsdiv(buffer.baseAddress!, 1, &divisor, buffer.baseAddress!, 1, count)
            }
        }
    }
}

/// The overlap-add accumulator: pre-reserved per-(source, channel) track rows
/// that the trimmed, transition-weighted model windows are added into, plus the
/// summed-weight divisor. `finalize` hands the rows over **without copying** —
/// they become the `SeparatedStems` buffers directly (the charter's single-copy
/// requirement, beaten to zero copies).
public struct HTDemucsOverlapAdd {
    public let trackLength: Int
    public let sources: Int
    public let channels: Int

    private var rows: [[Float]]
    private var sumWeight: [Float]
    private var finalized = false

    public init(trackLength: Int, sources: Int = 4, channels: Int = 2) {
        precondition(trackLength > 0 && sources > 0 && channels > 0)
        self.trackLength = trackLength
        self.sources = sources
        self.channels = channels
        self.rows = (0..<(sources * channels)).map { _ in
            [Float](repeating: 0, count: trackLength)
        }
        self.sumWeight = [Float](repeating: 0, count: trackLength)
    }

    /// Accumulate one scheduled window's model output. `batchStems` is the flat
    /// `[windows][sources][channels][segmentLength]` output of a (possibly
    /// batched) model call; `window` selects the window belonging to `chunk`.
    /// Applies the `center_trim` (via `chunk.trimOffset`) and the transition
    /// weights in one fused multiply-add per row.
    public mutating func add(
        chunk: HTDemucsScheduler.Chunk, batchStems: [Float], window: Int
    ) {
        batchStems.withUnsafeBufferPointer { add(chunk: chunk, batchStems: $0, window: window) }
    }

    /// Pointer-based `add` entry: accumulates straight from caller-owned
    /// storage (Phase 6: the engine hands a zero-copy view of the evaluated
    /// GPU output — unified memory — so a window's stems are never copied into
    /// an intermediate `[Float]`). The `[Float]` entry above forwards here.
    public mutating func add(
        chunk: HTDemucsScheduler.Chunk, batchStems: UnsafeBufferPointer<Float>, window: Int
    ) {
        precondition(!finalized)
        let segment = HTDemucsScheduler.segmentLength
        let rowCount = sources * channels
        precondition(window >= 0 && (window + 1) * rowCount * segment <= batchStems.count)
        precondition(chunk.offset + chunk.length <= trackLength)
        let count = vDSP_Length(chunk.length)

        HTDemucsScheduler.transitionWeights.withUnsafeBufferPointer { weights in
            let windowBase = batchStems.baseAddress! + window * rowCount * segment
            for row in 0..<rowCount {
                let source = windowBase + row * segment + chunk.trimOffset
                rows[row].withUnsafeMutableBufferPointer { destination in
                    let region = destination.baseAddress! + chunk.offset
                    vDSP_vma(
                        source, 1, weights.baseAddress!, 1,
                        region, 1, region, 1, count)
                }
            }
            sumWeight.withUnsafeMutableBufferPointer { destination in
                let region = destination.baseAddress! + chunk.offset
                vDSP_vadd(weights.baseAddress!, 1, region, 1, region, 1, count)
            }
        }
    }

    /// Divide by the summed weights (`out /= sum_weight`), then denormalize with
    /// the track scalars (`sources *= std; sources += mean` — upstream op order),
    /// and hand the rows over as `[source][channel][samples]`. Consumes the
    /// accumulator's storage; every sample must have been covered by a chunk.
    public mutating func finalize(
        denormalizingWith normalization: HTDemucsTrackNormalization
    ) -> [[[Float]]] {
        precondition(!finalized)
        finalized = true

        var minimumWeight: Float = 0
        vDSP_minv(sumWeight, 1, &minimumWeight, vDSP_Length(trackLength))
        precondition(minimumWeight > 0, "overlap-add left uncovered samples")

        var scale = normalization.std
        var offset = normalization.mean
        let count = vDSP_Length(trackLength)
        for row in rows.indices {
            rows[row].withUnsafeMutableBufferPointer { buffer in
                sumWeight.withUnsafeBufferPointer { weights in
                    vDSP_vdiv(
                        weights.baseAddress!, 1, buffer.baseAddress!, 1,
                        buffer.baseAddress!, 1, count)
                }
                vDSP_vsmul(buffer.baseAddress!, 1, &scale, buffer.baseAddress!, 1, count)
                vDSP_vsadd(buffer.baseAddress!, 1, &offset, buffer.baseAddress!, 1, count)
            }
        }

        var stems: [[[Float]]] = []
        stems.reserveCapacity(sources)
        for source in 0..<sources {
            var stemChannels: [[Float]] = []
            stemChannels.reserveCapacity(channels)
            for channel in 0..<channels {
                stemChannels.append(rows[source * channels + channel])
            }
            stems.append(stemChannels)
        }
        rows = []
        sumWeight = []
        return stems
    }
}
