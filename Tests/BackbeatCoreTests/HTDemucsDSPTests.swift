import XCTest
@testable import BackbeatCore

/// Hermetic pins for the custom engine's DSP substrate (charter Phase 1) — no
/// weights, no reference artifacts, runs in the default suite. Exact numeric parity
/// against the PyTorch reference activations is covered separately by the env-gated
/// `HTDemucsDSPParityTests`.
final class HTDemucsDSPTests: XCTestCase {

    // MARK: - Shape contract

    func testSpectrogramFrameCountMatchesCeilLengthOverHop() throws {
        for length in [1, 5, 100, 1023, 1024, 1025, 4096, 10_000, 44_100, 65_537] {
            let z = try HTDemucsDSP.spectrogram([sine(length: length, bin: 100)])
            let expectedFrames = (length + HTDemucsDSP.hopLength - 1) / HTDemucsDSP.hopLength
            XCTAssertEqual(z.frames, expectedFrames, "length \(length)")
            XCTAssertEqual(z.bins, 2048, "the Nyquist bin must be dropped (2049 → 2048)")
            XCTAssertEqual(z.channels, 1)
            XCTAssertEqual(z.data.count, 2048 * expectedFrames * 2)
            XCTAssertTrue(z.data.allSatisfy(\.isFinite), "length \(length) produced non-finite bins")
        }
    }

    // MARK: - Known tone

    func testKnownToneConcentratesEnergyAtItsBin() throws {
        // A sine at exactly bin 100 of the 4096-point FFT: every interior analysis
        // frame sees a coherent integer-bin tone, so the peak bin is exact.
        let bin = 100
        let z = try HTDemucsDSP.spectrogram([sine(length: 32_768, bin: bin)])
        let middleFrame = z.frames / 2
        var peakBin = -1
        var peakMagnitude: Float = -1
        for b in 0..<z.bins {
            let index = (b * z.frames + middleFrame) * 2
            let magnitude = z.data[index] * z.data[index] + z.data[index + 1] * z.data[index + 1]
            if magnitude > peakMagnitude {
                peakMagnitude = magnitude
                peakBin = b
            }
        }
        XCTAssertEqual(peakBin, bin)
    }

    // MARK: - Round trip

    func testRoundTripReconstructsInterior() throws {
        // spec→ispec is exact (up to fp32) for band-limited signals, except within
        // `outerPad` samples of the edges: `_ispec` re-pads the two trimmed frames on
        // each side as ZEROS, so the outermost ~1536 samples lose those frames'
        // overlap-add contribution while the window envelope still counts them
        // (attenuation, by upstream construction — the Phase 3 scheduler's segment
        // overlap covers exactly this region).
        var generator = SplitMix64(seed: 0x1234_5678)
        let length = 50_123 // deliberately not a hop multiple
        // Noise-like but band-limited: random-phase sines strictly below the dropped
        // Nyquist bin (the round trip is only exact for such signals — see below).
        var left = [Float](repeating: 0, count: length)
        for _ in 0..<64 {
            let bin = Int.random(in: 1..<2040, using: &generator)
            let phase = Double.random(in: 0..<(2 * Double.pi), using: &generator)
            let step = 2.0 * Double.pi * Double(bin) / Double(HTDemucsDSP.nfft)
            for i in 0..<length {
                left[i] += Float(sin(Double(i) * step + phase) / 8)
            }
        }
        let right = sine(length: length, bin: 517)

        let z = try HTDemucsDSP.spectrogram([left, right])
        let y = try HTDemucsDSP.inverseSpectrogram(z, length: length)

        XCTAssertEqual(y.count, 2)
        // Exactness additionally requires every covering analysis frame to be free of
        // reflected content: a frame straddling the pad boundary sees a time-reversal
        // kink whose leakage into the dropped Nyquist bin cannot round-trip. Boundary
        // frames reach ~nfft into the signal, so measure strictly inside that.
        let interior = HTDemucsDSP.nfft..<(length - HTDemucsDSP.nfft)
        for (original, reconstructed) in zip([left, right], y) {
            XCTAssertEqual(reconstructed.count, length)
            var maxInteriorError: Float = 0
            for i in interior {
                maxInteriorError = max(maxInteriorError, abs(original[i] - reconstructed[i]))
            }
            XCTAssertLessThanOrEqual(maxInteriorError, 1e-4)
            // Edges are attenuated, never amplified.
            let peak = reconstructed.map(abs).max() ?? 0
            XCTAssertLessThanOrEqual(peak, (original.map(abs).max() ?? 0) + 0.01)
        }
    }

    func testRoundTripOnWideBandNoiseIsApproximateByContract() throws {
        // The htdemucs contract DROPS the Nyquist bin in `_spec` and re-adds it as
        // zeros in `_ispec` (upstream behaves identically), so signals with energy at
        // bin 2048 — like white noise — round-trip only approximately. Pin the error
        // as small-but-nonzero so a future "fix" that silently changes the contract
        // (keeping Nyquist) or a real regression (error blowing up) both surface.
        var generator = SplitMix64(seed: 0xFEED_FACE)
        let length = 30_000
        let x = (0..<length).map { _ in Float.random(in: -1...1, using: &generator) }
        let y = try HTDemucsDSP.inverseSpectrogram(try HTDemucsDSP.spectrogram([x]), length: length)[0]
        var maxInteriorError: Float = 0
        for i in HTDemucsDSP.outerPad..<(length - HTDemucsDSP.outerPad) {
            maxInteriorError = max(maxInteriorError, abs(x[i] - y[i]))
        }
        XCTAssertGreaterThan(maxInteriorError, 1e-4, "white noise should NOT round-trip exactly (Nyquist is dropped)")
        XCTAssertLessThanOrEqual(maxInteriorError, 0.05, "Nyquist-drop error should stay proportionally small")
    }

    func testTinyInputsSurviveThePadFallback() throws {
        // Lengths at or below the reflect-pad amounts exercise upstream `pad1d`'s
        // zero-extend fallback; the shape contract and invertibility bookkeeping must hold.
        for length in [1, 5, 1024, 1536, 2000, 2559] {
            let x = sine(length: length, bin: 32)
            let z = try HTDemucsDSP.spectrogram([x])
            XCTAssertEqual(z.frames, (length + HTDemucsDSP.hopLength - 1) / HTDemucsDSP.hopLength, "length \(length)")
            let y = try HTDemucsDSP.inverseSpectrogram(z, length: length)
            XCTAssertEqual(y[0].count, length)
            XCTAssertTrue(y[0].allSatisfy(\.isFinite), "length \(length) produced non-finite samples")
        }
    }

    // MARK: - CaC pack/unpack

    func testPackCaCLayoutIsIndexExact() throws {
        // Hand-built [C=2][Fr=2][T=3] complex tensor with position-encoded values:
        // value(c,f,t,part) = 1000c + 100f + 10t + (part+1).
        var data = [Float]()
        for c in 0..<2 {
            for f in 0..<2 {
                for t in 0..<3 {
                    let base = Float(1000 * c + 100 * f + 10 * t)
                    data.append(base + 1) // re
                    data.append(base + 2) // im
                }
            }
        }
        let z = HTDemucsDSP.ComplexSpectrogram(channels: 2, bins: 2, frames: 3, data: data)

        // Expected CaC layout: [2C][Fr][T] with channel order c0.re, c0.im, c1.re, c1.im.
        var expected = [Float]()
        for c in 0..<2 {
            for part in 0..<2 {
                for f in 0..<2 {
                    for t in 0..<3 {
                        expected.append(Float(1000 * c + 100 * f + 10 * t) + Float(part + 1))
                    }
                }
            }
        }
        let packed = HTDemucsDSP.packCaC(z)
        XCTAssertEqual(packed, expected)

        // unpack is the exact inverse, across a source axis.
        let shifted = packed.map { $0 + 5000 }
        let unpacked = try HTDemucsDSP.unpackCaC(packed + shifted, sources: 2, channels: 2, bins: 2, frames: 3)
        XCTAssertEqual(unpacked.count, 2)
        XCTAssertEqual(unpacked[0], z)
        XCTAssertEqual(unpacked[1].data, z.data.map { $0 + 5000 })
    }

    // MARK: - Rejection of invalid input

    func testInvalidInputsThrow() {
        XCTAssertThrowsError(try HTDemucsDSP.spectrogram([])) {
            XCTAssertEqual($0 as? HTDemucsDSPError, .emptyInput)
        }
        XCTAssertThrowsError(try HTDemucsDSP.spectrogram([[]])) {
            XCTAssertEqual($0 as? HTDemucsDSPError, .emptyInput)
        }
        XCTAssertThrowsError(try HTDemucsDSP.spectrogram([[1, 2, 3], [1, 2]])) {
            XCTAssertEqual($0 as? HTDemucsDSPError, .mismatchedChannelLengths)
        }
        XCTAssertThrowsError(try HTDemucsDSP.unpackCaC([1, 2, 3], sources: 4, channels: 2, bins: 2048, frames: 3)) {
            guard case .invalidShape = $0 as? HTDemucsDSPError else { return XCTFail("expected invalidShape") }
        }

        // ispec rejects a bins count other than the htdemucs contract's 2048…
        let wrongBins = HTDemucsDSP.ComplexSpectrogram(
            channels: 1, bins: 4, frames: 2, data: [Float](repeating: 0, count: 16))
        XCTAssertThrowsError(try HTDemucsDSP.inverseSpectrogram(wrongBins, length: 2048)) {
            guard case .invalidShape = $0 as? HTDemucsDSPError else { return XCTFail("expected invalidShape") }
        }
        // …and a frame count that does not match ceil(length/hop).
        let wrongFrames = HTDemucsDSP.ComplexSpectrogram(
            channels: 1, bins: 2048, frames: 3, data: [Float](repeating: 0, count: 2048 * 3 * 2))
        XCTAssertThrowsError(try HTDemucsDSP.inverseSpectrogram(wrongFrames, length: 1024)) {
            guard case .invalidShape = $0 as? HTDemucsDSPError else { return XCTFail("expected invalidShape") }
        }
    }

    // MARK: - Padding + window internals (contract-bearing helpers)

    func testReflectPadMatchesTorchSemantics() {
        // torch: F.pad([1,2,3,4,5], (3,2), 'reflect') == [4,3,2,1,2,3,4,5,4,3]
        XCTAssertEqual(
            HTDemucsDSP.reflectPad([1, 2, 3, 4, 5], left: 3, right: 2),
            [4, 3, 2, 1, 2, 3, 4, 5, 4, 3])
        XCTAssertEqual(HTDemucsDSP.reflectPad([1, 2], left: 0, right: 0), [1, 2])
    }

    func testPad1dZeroExtendFallbackMatchesUpstream() {
        // Upstream pad1d on [7] with (2,3): too short to reflect → zero-extend right
        // by 3 (extra = maxPad − len + 1), reflect the remainder: [0,0,7,0,0,0].
        XCTAssertEqual(
            HTDemucsDSP.pad1dReflect([7], left: 2, right: 3),
            [0, 0, 7, 0, 0, 0])
        // Long enough → plain reflect.
        XCTAssertEqual(
            HTDemucsDSP.pad1dReflect([1, 2, 3, 4, 5], left: 2, right: 2),
            [3, 2, 1, 2, 3, 4, 5, 4, 3])
    }

    func testInverseEnvelopeMatchesScalarDerivation() {
        // The GPU epilogue divides by exactly this envelope (Phase 6), so pin it
        // against an independent scalar derivation of torch.istft's window²
        // overlap-add divisor: frames padded 2 per side at hop spacing, sliced
        // to inverseSpectrogram's emitted range.
        let nfft = HTDemucsDSP.nfft
        let hop = HTDemucsDSP.hopLength
        let frames = 3
        let length = 2500
        let window = HTDemucsDSP.periodicHannWindow(nfft)
        let totalFrames = frames + 4
        var full = [Float](repeating: 0, count: (totalFrames - 1) * hop + nfft)
        for frame in 0..<totalFrames {
            for n in 0..<nfft {
                full[frame * hop + n] += window[n] * window[n]
            }
        }
        let start = HTDemucsDSP.inverseOutputStart
        let expected = Array(full[start ..< start + length])
        let envelope = HTDemucsDSP.inverseEnvelope(frames: frames, length: length)
        XCTAssertEqual(envelope.count, length)
        for index in stride(from: 0, to: length, by: 7) {
            XCTAssertEqual(envelope[index], expected[index], accuracy: 1e-6)
        }
        // Interior sanity: 75% overlap of a periodic Hann sums window² to 1.5.
        XCTAssertEqual(envelope[length / 2], 1.5, accuracy: 1e-4)
    }

    func testSpectrogramGatherIndicesMatchComposedReflectPads() {
        // The GPU input path frames with one take() over these indices (Phase 6);
        // pin them against the CPU path's actual double-reflection: the outer
        // `pad1d` reflect then torch.stft's center reflect, framed at
        // (t+2)·hop per kept frame.
        let nfft = HTDemucsDSP.nfft
        let hop = HTDemucsDSP.hopLength
        let length = 6000
        let le = (length + hop - 1) / hop
        let outerPad = HTDemucsDSP.inverseOutputStart - nfft / 2  // hop/2·3, via the public sum
        let signal = (0..<length).map { Float($0) }  // a ramp makes indices readable
        let outer = HTDemucsDSP.pad1dReflect(
            signal, left: outerPad, right: outerPad + le * hop - length)
        let padded = HTDemucsDSP.reflectPad(outer, left: nfft / 2, right: nfft / 2)
        let indices = HTDemucsDSP.spectrogramGatherIndices(length: length)
        XCTAssertEqual(indices.count, le * nfft)
        for frame in 0..<le {
            for n in stride(from: 0, to: nfft, by: 97) {
                XCTAssertEqual(
                    signal[Int(indices[frame * nfft + n])],
                    padded[(frame + 2) * hop + n],
                    "frame \(frame) sample \(n)")
            }
        }
    }

    func testPeriodicHannWindowMatchesTorch() {
        // torch.hann_window(n) is PERIODIC: w[0] == 0, w[n/2] == 1, w[k] == w[n−k].
        let n = 4096
        let w = HTDemucsDSP.periodicHannWindow(n)
        XCTAssertEqual(w.count, n)
        XCTAssertEqual(w[0], 0, accuracy: 1e-7)
        XCTAssertEqual(w[n / 2], 1, accuracy: 1e-6)
        for k in [1, 17, 512, 1024, 2000] {
            XCTAssertEqual(w[k], w[n - k], accuracy: 1e-6, "periodic symmetry at k=\(k)")
        }
        // Periodic-vs-symmetric discriminator: at n/4 the periodic window is exactly
        // 0.5, while the symmetric (n−1 denominator) variant gives ≈ 0.500392 —
        // 400× this tolerance.
        XCTAssertEqual(w[n / 4], 0.5, accuracy: 1e-6)
        // The window is computed in Double and rounded once (fp32 cancellation near
        // zero would otherwise cost most of the significand).
        let expected = Float(0.5 - 0.5 * cos(2.0 * Double.pi / Double(n)))
        XCTAssertEqual(w[1], expected, accuracy: 1e-10)
    }

    // MARK: - Helpers

    /// A sine sitting exactly on `bin` of the 4096-point FFT (period divides nfft).
    private func sine(length: Int, bin: Int) -> [Float] {
        let step = 2.0 * Double.pi * Double(bin) / Double(HTDemucsDSP.nfft)
        return (0..<length).map { Float(sin(Double($0) * step)) }
    }
}

/// Deterministic seeded RNG for reproducible noise fixtures.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
