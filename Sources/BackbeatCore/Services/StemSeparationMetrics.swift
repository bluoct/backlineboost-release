import Foundation

/// Numeric metrics for the native-engine parity gate (G1). Pure functions with
/// no I/O, weights, or external tools, so they are exercised by the default
/// `swift test` suite; `BackbeatSepBench` (Task 6) is a thin CLI over them.
///
/// The headline metric is **SI-SDR** (scale-invariant signal-to-distortion
/// ratio, Le Roux et al., 2019). SI-SDR — not plain SDR — is used deliberately:
/// demucs applies a per-stem `--clip-mode rescale`, so a native stem can differ
/// from the oracle by a constant gain and still be a perfect separation; SI-SDR
/// factors that gain out (an optimal scalar projection) while plain SDR would
/// penalise it. Do not "simplify" this to SDR.
public enum StemSeparationMetrics {
    /// Scale-invariant SDR in dB for a single-channel reference/estimate pair.
    ///
    /// `SI-SDR = 10·log10( ||α·s||² / ||α·s − ŝ||² )` where `s` is the reference,
    /// `ŝ` the estimate, and `α = ⟨ŝ,s⟩/⟨s,s⟩` the least-squares scale that
    /// projects the reference onto the estimate (this is what makes it
    /// scale-invariant: `ŝ ↦ c·ŝ` leaves the ratio unchanged).
    ///
    /// Returns `+∞` for an exact (or exactly-scaled) match, `−∞` when the
    /// reference carries energy the estimate cannot explain at all (including a
    /// silent estimate against a non-silent reference). A silent reference is
    /// unscoreable: `+∞` if the estimate is also silent, else `−∞`.
    public static func signalToDistortionRatioDB(reference: [Float], estimate: [Float]) -> Double {
        signalToDistortionRatioDB(referenceChannels: [reference], estimateChannels: [estimate])
    }

    /// Scale-invariant SDR in dB for a multi-channel stem.
    ///
    /// The channels are scored **coherently** with a single shared scale α
    /// (summed inner products / summed powers), not per-channel dB then averaged:
    /// one α matches how a stem is heard, and it avoids the ill-defined average of
    /// a `+∞` channel with a finite one. Channels are compared pairwise; a length
    /// mismatch truncates to the shorter of each pair (demucs and a native engine
    /// can differ by a few boundary samples). A channel-count mismatch compares
    /// the common leading channels.
    public static func signalToDistortionRatioDB(
        referenceChannels: [[Float]],
        estimateChannels: [[Float]]
    ) -> Double {
        let channelCount = min(referenceChannels.count, estimateChannels.count)
        guard channelCount > 0 else { return -.infinity }

        var referenceDotEstimate = 0.0
        var referenceEnergy = 0.0
        var comparedSamples = 0
        for channel in 0..<channelCount {
            let reference = referenceChannels[channel]
            let estimate = estimateChannels[channel]
            let count = min(reference.count, estimate.count)
            for i in 0..<count {
                let r = Double(reference[i])
                let e = Double(estimate[i])
                referenceDotEstimate += r * e
                referenceEnergy += r * r
            }
            comparedSamples += count
        }
        guard comparedSamples > 0 else { return -.infinity }

        // A silent reference has no energy to project onto: the metric is only
        // meaningful if the estimate is silent too (perfect), otherwise the
        // estimate is pure distortion relative to a zero target.
        guard referenceEnergy > 0 else {
            return estimateEnergyIsZero(estimateChannels, channelCount: channelCount) ? .infinity : -.infinity
        }

        let alpha = referenceDotEstimate / referenceEnergy
        // ||α·s||² summed across channels = α²·⟨s,s⟩.
        let targetEnergy = alpha * alpha * referenceEnergy

        var noiseEnergy = 0.0
        for channel in 0..<channelCount {
            let reference = referenceChannels[channel]
            let estimate = estimateChannels[channel]
            let count = min(reference.count, estimate.count)
            for i in 0..<count {
                let residual = Double(estimate[i]) - alpha * Double(reference[i])
                noiseEnergy += residual * residual
            }
        }

        // `estimate == α·reference` exactly. That is a perfect (scaled) match —
        // `+∞` — UNLESS α is 0, which means the estimate carries none of the
        // reference (a silent estimate against a real reference); that is the
        // worst case, `−∞`, not a match. When α≠0 but the residual is non-zero,
        // the log path below already yields `−∞` for a zero target (log10(0)).
        guard noiseEnergy > 0 else { return targetEnergy > 0 ? .infinity : -.infinity }
        return 10 * log10(targetEnergy / noiseEnergy)
    }

    private static func estimateEnergyIsZero(_ channels: [[Float]], channelCount: Int) -> Bool {
        for channel in 0..<channelCount {
            for sample in channels[channel] where sample != 0 {
                return false
            }
        }
        return true
    }
}

/// The SI-SDR thresholds for the machine-checkable half of quality gate G1
/// (architecture §4). Kept as a value with the documented defaults so the gate
/// is defined in one testable place and cannot drift silently; `BackbeatSepBench`
/// and the Task-7 spike apply it.
public struct StemParityThresholds: Equatable, Sendable {
    /// Drums are the product-critical stem (a drummer's practice target), so they
    /// carry the strictest bar.
    public var drumsMinimumDB: Double
    /// Bass / other / vocals — the backing stems.
    public var backingStemMinimumDB: Double
    /// Native per-stem SI-SDR must stay within this margin of the MPS-vs-oracle
    /// calibration band (native ≥ MPS-vs-oracle − margin), so the gate tracks the
    /// achievable accelerated-path fidelity rather than an absolute ideal.
    public var calibrationBandMarginDB: Double

    public init(
        drumsMinimumDB: Double = 25,
        backingStemMinimumDB: Double = 20,
        calibrationBandMarginDB: Double = 3
    ) {
        self.drumsMinimumDB = drumsMinimumDB
        self.backingStemMinimumDB = backingStemMinimumDB
        self.calibrationBandMarginDB = calibrationBandMarginDB
    }

    public static let g1 = StemParityThresholds()

    /// The absolute SI-SDR floor for a stem (before the calibration-band check).
    public func minimumDB(for stem: SeparatedStems.Stem) -> Double {
        stem == .drums ? drumsMinimumDB : backingStemMinimumDB
    }
}
