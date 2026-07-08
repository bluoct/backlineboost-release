import XCTest
@testable import BackbeatCore
import BackbeatParityKit

/// Gated numeric parity: prove `HTDemucsDSP` reproduces upstream demucs 4.0.1's
/// `_spec` / `_magnitude` / `_mask` / `_ispec` on the Phase 0 PyTorch reference
/// activations (the charter's layer-parity methodology — drift is localized to the
/// transform that introduced it, not discovered at the Phase 4 SI-SDR gate).
///
/// Opt-in (skipped by default, so `swift test` stays artifact-free):
///
///   BACKBEAT_REFERENCE_ACTIVATIONS=.build/reference-activations/htdemucs-v1 \
///     swift test --filter HTDemucsDSPParityTests
///
/// The saved `input.npy` IS the contract input — these tests feed those exact
/// samples, so generator/torch-version drift cannot desynchronize the two sides.
/// Regeneration: docs/native-engine/baseline-2026-07-07.md §Regeneration.
final class HTDemucsDSPParityTests: XCTestCase {

    /// fp32 tolerance for the two arithmetic transforms (STFT/iSTFT). The achieved
    /// values are recorded in docs/status.md at each checkpoint; drift beyond this
    /// bound is investigated, never silently loosened.
    private let arithmeticTolerance: Float = 1e-4

    func testSpectrogramMatchesReference() throws {
        let refs = try ReferenceActivations.loadOrSkip()
        let input = try refs.tensor("input") // [B=1, C=2, length]
        XCTAssertEqual(input.shape.count, 3)
        XCTAssertEqual(input.shape[0], 1)
        let channelCount = input.shape[1]
        let length = input.shape[2]
        let channels = (0..<channelCount).map {
            Array(input.data[($0 * length)..<(($0 + 1) * length)])
        }

        let z = try HTDemucsDSP.spectrogram(channels)

        let reference = try refs.tensor("_spec") // [1, C, 2048, le, 2] (view_as_real)
        XCTAssertEqual([1, z.channels, z.bins, z.frames, 2], reference.shape)
        let maxDiff = maxAbsDifference(z.data, reference.data)
        print("HTDemucsDSPParity: spec max|Δ| vs _spec = \(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, arithmeticTolerance)
    }

    func testPackCaCMatchesMagnitudeExactly() throws {
        let refs = try ReferenceActivations.loadOrSkip()
        let spec = try refs.tensor("_spec")           // [1, C, Fr, T, 2]
        let magnitude = try refs.tensor("_magnitude") // [1, 2C, Fr, T]
        let z = HTDemucsDSP.ComplexSpectrogram(
            channels: spec.shape[1], bins: spec.shape[2], frames: spec.shape[3], data: spec.data)
        XCTAssertEqual([1, 2 * z.channels, z.bins, z.frames], magnitude.shape)
        // A pure permute performs no arithmetic — equality is exact, not tolerance-based.
        XCTAssertEqual(HTDemucsDSP.packCaC(z), magnitude.data)
    }

    func testUnpackCaCRoundTripsMaskExactly() throws {
        let refs = try ReferenceActivations.loadOrSkip()
        let mask = try refs.tensor("_mask") // [1, S, C, Fr, T, 2] — the complex OUTPUT of _mask
        XCTAssertEqual(mask.shape.count, 6)
        let (sources, channels, bins, frames) = (mask.shape[1], mask.shape[2], mask.shape[3], mask.shape[4])
        let plane = channels * bins * frames * 2

        // Rebuild the model-side packed tensor m = [S][2C][Fr][T] with the pack
        // direction pinned by testPackCaCMatchesMagnitudeExactly, then require
        // unpack(m) to reproduce the reference complex output bit-for-bit.
        var packed = [Float]()
        packed.reserveCapacity(mask.data.count)
        for source in 0..<sources {
            let slice = Array(mask.data[(source * plane)..<((source + 1) * plane)])
            packed += HTDemucsDSP.packCaC(
                .init(channels: channels, bins: bins, frames: frames, data: slice))
        }

        let unpacked = try HTDemucsDSP.unpackCaC(
            packed, sources: sources, channels: channels, bins: bins, frames: frames)
        XCTAssertEqual(unpacked.count, sources)
        for source in 0..<sources {
            XCTAssertEqual(
                unpacked[source].data,
                Array(mask.data[(source * plane)..<((source + 1) * plane)]),
                "source \(source)")
        }
    }

    func testInverseSpectrogramMatchesReference() throws {
        let refs = try ReferenceActivations.loadOrSkip()
        let mask = try refs.tensor("_mask")   // [1, S, C, Fr, T, 2]
        let reference = try refs.tensor("_ispec") // [1, S, C, length]
        let (sources, channels, bins, frames) = (mask.shape[1], mask.shape[2], mask.shape[3], mask.shape[4])
        XCTAssertEqual(reference.shape[0], 1)
        XCTAssertEqual(reference.shape[1], sources)
        XCTAssertEqual(reference.shape[2], channels)
        let length = reference.shape[3]
        let plane = channels * bins * frames * 2

        var maxDiff: Float = 0
        for source in 0..<sources {
            let z = HTDemucsDSP.ComplexSpectrogram(
                channels: channels, bins: bins, frames: frames,
                data: Array(mask.data[(source * plane)..<((source + 1) * plane)]))
            let y = try HTDemucsDSP.inverseSpectrogram(z, length: length)
            for channel in 0..<channels {
                let base = (source * channels + channel) * length
                let refSlice = Array(reference.data[base..<(base + length)])
                maxDiff = max(maxDiff, maxAbsDifference(y[channel], refSlice))
            }
        }
        print("HTDemucsDSPParity: ispec max|Δ| vs _ispec = \(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, arithmeticTolerance)
    }

    private func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
        XCTAssertEqual(a.count, b.count)
        var worst: Float = 0
        for i in 0..<min(a.count, b.count) {
            worst = max(worst, abs(a[i] - b[i]))
        }
        return worst
    }
}
