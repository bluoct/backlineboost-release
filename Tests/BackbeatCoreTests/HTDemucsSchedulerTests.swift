import XCTest
@testable import BackbeatCore

/// Hermetic pins for the Phase 3 segmentation/overlap-add scheduler — the exact
/// upstream demucs 4.0.1 `apply_model(shifts=0, split=True, overlap=0.1)`
/// semantics, held with hand-computed values (no weights, no MLX, no audio
/// files; architecture §2.4). The load-bearing non-obvious facts pinned here:
/// every model window is exactly 343_980 samples via *centered* padding (real
/// audio pulled from before the final chunk's offset, zeros only past the track
/// edges), a training-length track schedules TWO chunks (offsets are strictly
/// below the length in steps of the stride), and the track normalization uses
/// torch's *unbiased* standard deviation.
final class HTDemucsSchedulerTests: XCTestCase {
    // MARK: - Constants

    func testSegmentAndStrideConstants() {
        XCTAssertEqual(HTDemucsScheduler.segmentLength, 343_980)  // int(44_100 · 39/5)
        XCTAssertEqual(HTDemucsScheduler.stride(), 309_582)  // int(0.9 · 343_980)
        XCTAssertEqual(HTDemucsScheduler.stride(overlap: 0.1), 309_582)
    }

    // MARK: - Transition weights

    func testTransitionWeightsMatchUpstreamConstruction() {
        let weights = HTDemucsScheduler.transitionWeights
        let half = 171_990
        XCTAssertEqual(weights.count, 343_980)
        // torch: cat([arange(1, half+1), arange(half, 0, -1)]) / half in fp32.
        XCTAssertEqual(weights[0], Float(1) / Float(half))
        XCTAssertEqual(weights[1], Float(2) / Float(half))
        XCTAssertEqual(weights[half - 1], 1)  // ascending peak
        XCTAssertEqual(weights[half], 1)  // descending peak (two consecutive maxima)
        XCTAssertEqual(weights[weights.count - 1], Float(1) / Float(half))
        for probe in [7, 123_456, half - 2] {
            XCTAssertEqual(weights[probe], Float(probe + 1) / Float(half))
            XCTAssertEqual(weights[probe], weights[weights.count - 1 - probe], "triangle symmetry")
        }
        XCTAssertEqual(weights.max(), 1)
        XCTAssertEqual(weights.min(), Float(1) / Float(half))
    }

    // MARK: - Plan

    func testPlanRejectsDegenerateInputs() {
        XCTAssertThrowsError(try HTDemucsScheduler.plan(trackLength: 0)) {
            XCTAssertEqual($0 as? HTDemucsSchedulerError, .emptyTrack)
        }
        XCTAssertThrowsError(try HTDemucsScheduler.plan(trackLength: 100, overlap: 1.0)) {
            XCTAssertEqual($0 as? HTDemucsSchedulerError, .invalidOverlap(1.0))
        }
    }

    func testPlanInteriorAndFinalChunkHandComputed() throws {
        // The 184.4 s bench fixture's length: 27 chunks (= ceil(len / stride)).
        let chunks = try HTDemucsScheduler.plan(trackLength: 8_132_040)
        XCTAssertEqual(chunks.count, 27)

        let first = chunks[0]
        XCTAssertEqual(first.offset, 0)
        XCTAssertEqual(first.length, 343_980)  // interior: full window, no padding
        XCTAssertEqual(first.sourceStart, 0)
        XCTAssertEqual(first.sourceEnd, 343_980)
        XCTAssertEqual(first.padLeft, 0)
        XCTAssertEqual(first.padRight, 0)
        XCTAssertEqual(first.trimOffset, 0)

        // Final chunk: delta = 343_980 − 82_908 = 261_072; the window is
        // CENTERED — it reaches delta/2 = 130_536 samples of real audio back
        // before the offset and zero-pads only past the track end.
        let last = chunks[26]
        XCTAssertEqual(last.offset, 26 * 309_582)  // 8_049_132
        XCTAssertEqual(last.length, 82_908)
        XCTAssertEqual(last.trimOffset, 130_536)
        XCTAssertEqual(last.sourceStart, 7_918_596)  // offset − delta/2
        XCTAssertEqual(last.sourceEnd, 8_132_040)  // the track end
        XCTAssertEqual(last.padLeft, 0)
        XCTAssertEqual(last.padRight, 130_536)
    }

    func testPlanTrainingLengthTrackSchedulesTwoChunks() throws {
        // Non-obvious upstream fact: offsets run 0, stride, … strictly below the
        // length, so a track of EXACTLY one training segment gets a second,
        // 34_398-sample chunk — not a single-window pass.
        let chunks = try HTDemucsScheduler.plan(trackLength: 343_980)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[1].offset, 309_582)
        XCTAssertEqual(chunks[1].length, 34_398)
        XCTAssertEqual(chunks[1].trimOffset, 154_791)  // (343_980 − 34_398) / 2
        XCTAssertEqual(chunks[1].sourceStart, 154_791)  // real audio pulled back
        XCTAssertEqual(chunks[1].sourceEnd, 343_980)
        XCTAssertEqual(chunks[1].padLeft, 0)
        XCTAssertEqual(chunks[1].padRight, 154_791)
    }

    func testPlanShortTrackIsSingleCenteredWindow() throws {
        let chunks = try HTDemucsScheduler.plan(trackLength: 100)
        XCTAssertEqual(chunks.count, 1)
        let only = chunks[0]
        XCTAssertEqual(only.offset, 0)
        XCTAssertEqual(only.length, 100)
        XCTAssertEqual(only.trimOffset, 171_940)  // (343_980 − 100) / 2
        XCTAssertEqual(only.sourceStart, 0)
        XCTAssertEqual(only.sourceEnd, 100)
        XCTAssertEqual(only.padLeft, 171_940)
        XCTAssertEqual(only.padRight, 171_940)
    }

    func testPlanInvariantsAcrossLengthSweep() throws {
        let stride = HTDemucsScheduler.stride()
        let segment = HTDemucsScheduler.segmentLength
        for length in [1, 1_023, 1_024, 309_582, 309_583, 343_979, 343_981, 619_164, 700_000] {
            let chunks = try HTDemucsScheduler.plan(trackLength: length)
            XCTAssertEqual(chunks.count, (length + stride - 1) / stride, "count for \(length)")
            for (index, chunk) in chunks.enumerated() {
                XCTAssertEqual(chunk.offset, index * stride)
                XCTAssertEqual(chunk.length, min(length - chunk.offset, segment))
                XCTAssertGreaterThanOrEqual(chunk.sourceStart, 0)
                XCTAssertLessThanOrEqual(chunk.sourceEnd, length)
                XCTAssertGreaterThan(chunk.sourceEnd, chunk.sourceStart)
                // The window is always exactly one training segment…
                XCTAssertEqual(
                    chunk.padLeft + (chunk.sourceEnd - chunk.sourceStart) + chunk.padRight,
                    segment, "window size for \(length)")
                // …and the center-trim aligns the model output with the track:
                // window position trimOffset ↔ track position offset.
                XCTAssertEqual(
                    (chunk.sourceStart - chunk.padLeft) + chunk.trimOffset, chunk.offset,
                    "trim alignment for \(length)")
                XCTAssertLessThanOrEqual(chunk.trimOffset + chunk.length, segment)
            }
            // Full coverage, no gaps: each chunk reaches the next one's offset,
            // and the final chunk ends exactly at the track end.
            for (current, next) in zip(chunks, chunks.dropFirst()) {
                XCTAssertGreaterThanOrEqual(current.offset + current.length, next.offset)
            }
            let last = chunks[chunks.count - 1]
            XCTAssertEqual(last.offset + last.length, length)
        }
    }

    // MARK: - Track normalization

    func testTrackNormalizationMatchesTorchScalars() {
        // ref = mono mean = [2, 3, 4] → mean 3, UNBIASED std = √((1+0+1)/2) = 1.
        let norm = HTDemucsTrackNormalization.measure([[1, 2, 3], [3, 4, 5]])
        XCTAssertEqual(norm.mean, 3)
        XCTAssertEqual(norm.std, 1)

        var channels: [[Float]] = [[1, 2, 3], [3, 4, 5]]
        norm.normalize(&channels)
        XCTAssertEqual(channels, [[-2, -1, 0], [0, 1, 2]])
    }

    func testTrackNormalizationStdIsUnbiased() {
        // [0, 0, 2, 2]: mean 1; unbiased std = √(4/3) ≈ 1.1547 (biased would be 1
        // exactly — this pins torch's default ddof=1).
        let norm = HTDemucsTrackNormalization.measure([[0, 0, 2, 2]])
        XCTAssertEqual(norm.mean, 1)
        XCTAssertEqual(norm.std, Float((4.0 / 3.0).squareRoot()), accuracy: 1e-6)
    }

    func testTrackNormalizationGuardsDegenerateTracks() {
        // Silent track: upstream divides by zero; we clamp the scale to 1 (the
        // recorded deviation) so normalization is a no-op subtract of 0.
        let silent = HTDemucsTrackNormalization.measure([[0, 0, 0, 0], [0, 0, 0, 0]])
        XCTAssertEqual(silent.mean, 0)
        XCTAssertEqual(silent.std, 1)

        // Single-sample track: no unbiased variance exists (N−1 = 0).
        let single = HTDemucsTrackNormalization.measure([[0.5]])
        XCTAssertEqual(single.mean, 0.5)
        XCTAssertEqual(single.std, 1)

        XCTAssertEqual(HTDemucsTrackNormalization.measure([]).std, 1)
    }

    func testTrackNormalizationChunkedAccumulation() {
        // Longer than the 2¹⁸ accumulation chunk, alternating ±1: mean 0,
        // unbiased std = √(N/(N−1)) ≈ 1 + 8.3e-7.
        let length = 300_000
        let signal = (0..<length).map { Float($0 % 2 == 0 ? 1 : -1) }
        let norm = HTDemucsTrackNormalization.measure([signal])
        XCTAssertEqual(norm.mean, 0, accuracy: 1e-7)
        XCTAssertEqual(norm.std, 1, accuracy: 1e-4)
    }

    // MARK: - Overlap-add

    /// Deterministic pseudo-random test signal (cheap integer hash → [−1, 1]).
    private func testSignal(row: Int, length: Int) -> [Float] {
        (0..<length).map { index in
            let hashed = (index &* 1_103_515_245 &+ row &* 12_345) & 0xFFFF
            return Float(hashed) / Float(0x8000) - 1
        }
    }

    /// The fake per-segment "model": identity on the mix — returns exactly the
    /// centered window (pad + slice + pad) the chunk describes, per row.
    private func identityWindow(chunk: HTDemucsScheduler.Chunk, rows: [[Float]]) -> [Float] {
        var window: [Float] = []
        window.reserveCapacity(rows.count * HTDemucsScheduler.segmentLength)
        for row in rows {
            window.append(contentsOf: [Float](repeating: 0, count: chunk.padLeft))
            window.append(contentsOf: row[chunk.sourceStart..<chunk.sourceEnd])
            window.append(contentsOf: [Float](repeating: 0, count: chunk.padRight))
        }
        return window
    }

    func testOverlapAddIdentityModelReconstructsAndDenormalizes() throws {
        // 3 chunks (two overlap boundaries), identity model, non-trivial
        // normalization scalars: the reconstruction must be the input restored
        // through `x·std + mean` to within accumulation noise.
        let length = 700_000
        let chunks = try HTDemucsScheduler.plan(trackLength: length)
        XCTAssertEqual(chunks.count, 3)

        let rows = (0..<8).map { testSignal(row: $0, length: length) }
        var accumulator = HTDemucsOverlapAdd(trackLength: length)
        for chunk in chunks {
            accumulator.add(
                chunk: chunk, batchStems: identityWindow(chunk: chunk, rows: rows), window: 0)
        }
        let norm = HTDemucsTrackNormalization(mean: 0.25, std: 2)
        let stems = accumulator.finalize(denormalizingWith: norm)

        XCTAssertEqual(stems.count, 4)
        XCTAssertEqual(stems[0].count, 2)
        for source in 0..<4 {
            for channel in 0..<2 {
                let output = stems[source][channel]
                let input = rows[source * 2 + channel]
                XCTAssertEqual(output.count, length)
                var worst: Float = 0
                for index in stride(from: 0, to: length, by: 997) {
                    worst = max(worst, abs(output[index] - (input[index] * 2 + 0.25)))
                }
                // Full scan of the overlap boundaries, where accumulation noise lives.
                for boundary in [chunks[1].offset, chunks[2].offset] {
                    for index in max(0, boundary - 512)..<min(length, boundary + 512) {
                        worst = max(worst, abs(output[index] - (input[index] * 2 + 0.25)))
                    }
                }
                XCTAssertLessThanOrEqual(worst, 1e-5, "source \(source) channel \(channel)")
            }
        }
    }

    func testOverlapAddIsInvariantToBatchGrouping() throws {
        // Accumulating window-by-window vs. from one concatenated batch buffer
        // must be BITWISE identical — the scheduler's math cannot depend on how
        // the separator groups windows into GPU batches.
        let length = 700_000
        let chunks = try HTDemucsScheduler.plan(trackLength: length)
        let rows = (0..<8).map { testSignal(row: $0, length: length) }
        let windows = chunks.map { identityWindow(chunk: $0, rows: rows) }
        let norm = HTDemucsTrackNormalization(mean: -0.125, std: 1.5)

        var single = HTDemucsOverlapAdd(trackLength: length)
        for (chunk, window) in zip(chunks, windows) {
            single.add(chunk: chunk, batchStems: window, window: 0)
        }
        let expected = single.finalize(denormalizingWith: norm)

        var batched = HTDemucsOverlapAdd(trackLength: length)
        let batch = Array(windows.joined())
        for (index, chunk) in chunks.enumerated() {
            batched.add(chunk: chunk, batchStems: batch, window: index)
        }
        let got = batched.finalize(denormalizingWith: norm)

        XCTAssertEqual(got, expected)
    }

    func testOverlapAddSilentTrackEndToEndProducesExactSilence() throws {
        // The recorded upstream deviation (silent track: the normalization std
        // clamps to 1 where upstream divides by zero) pinned END-TO-END through
        // the scheduler math: measure → normalize → plan → identity model →
        // overlap-add → finalize must return exact digital silence — no NaN
        // from the normalization divide, none from the weight division.
        let length = 400_000
        let chunks = try HTDemucsScheduler.plan(trackLength: length)
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "must cross an overlap boundary")

        var channels = [[Float]](repeating: [Float](repeating: 0, count: length), count: 2)
        let norm = HTDemucsTrackNormalization.measure(channels)
        XCTAssertEqual(norm.std, 1)
        norm.normalize(&channels)
        XCTAssertTrue(
            channels.allSatisfy { $0.allSatisfy { $0 == 0 } },
            "normalizing silence must leave exact silence")

        let rows = (0..<8).map { _ in channels[0] }
        var accumulator = HTDemucsOverlapAdd(trackLength: length)
        for chunk in chunks {
            accumulator.add(
                chunk: chunk, batchStems: identityWindow(chunk: chunk, rows: rows), window: 0)
        }
        let stems = accumulator.finalize(denormalizingWith: norm)
        XCTAssertEqual(stems.count, 4)
        for source in stems {
            XCTAssertEqual(source.count, 2)
            for channel in source {
                XCTAssertEqual(channel.count, length)
                XCTAssertTrue(channel.allSatisfy { $0 == 0 })
            }
        }
    }

    func testOverlapAddSingleChunkPassesWeightDivisionThrough() throws {
        // Single short chunk: every sample has exactly one weight, so
        // (w·x)/w must return x to within a couple of ulp even at the tiny
        // triangle edges (w[0] = 1/171990).
        let length = 4_096
        let chunks = try HTDemucsScheduler.plan(trackLength: length)
        XCTAssertEqual(chunks.count, 1)
        let rows = (0..<8).map { testSignal(row: $0, length: length) }
        var accumulator = HTDemucsOverlapAdd(trackLength: length)
        accumulator.add(
            chunk: chunks[0], batchStems: identityWindow(chunk: chunks[0], rows: rows), window: 0)
        let stems = accumulator.finalize(
            denormalizingWith: HTDemucsTrackNormalization(mean: 0, std: 1))
        for source in 0..<4 {
            for channel in 0..<2 {
                let output = stems[source][channel]
                let input = rows[source * 2 + channel]
                for index in 0..<length {
                    XCTAssertEqual(output[index], input[index], accuracy: 1e-6)
                }
            }
        }
    }
}
