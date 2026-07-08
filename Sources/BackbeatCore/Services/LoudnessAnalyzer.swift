import Foundation
import AVFoundation
import Accelerate

/// Native, in-process ITU-R BS.1770-4 integrated-loudness (LUFS) + true-peak
/// measurement — the replacement for the ffmpeg `loudnorm` measurement pass. Pure
/// DSP over AVFoundation-decoded float samples; no subprocess, no ffmpeg.
///
/// The algorithm mirrors libebur128 (which ffmpeg's `loudnorm` vendors): a
/// per-channel K-weighting filter (a high-shelf "pre-filter" cascaded with an RLB
/// high-pass, coefficients generated for the actual sample rate), 400 ms /
/// 75 %-overlap gated mean-square blocks with the −70 LKFS absolute gate and the
/// −10 LU relative gate, and a 4× oversampled true peak. Measurement runs at the
/// content's native sample rate (BS.1770's coefficients are rate-dependent);
/// ffmpeg's `loudnorm` instead resamples to 192 kHz internally, which shifts the
/// reported integrated value by only ~0.18 LU — inside this project's ±0.5 dB
/// tolerance (verified against ffmpeg 8.1.1 on 44.1 kHz fixtures).
///
/// Channel weighting follows BS.1770 for mono and stereo (every channel weight
/// 1.0), which is the app's entire input domain; surround weighting (Ls/Rs = 1.41,
/// LFE excluded) is out of scope and higher channel counts fall back to 1.0.
public struct LoudnessAnalyzer: Sendable {
    public struct Measurement: Equatable, Sendable {
        /// Gated integrated loudness in LUFS. `-.infinity` for digital silence
        /// (no block clears the absolute/relative gates).
        public var integratedLUFS: Double
        /// True peak in dBFS (4× oversampled), or nil when the signal is all zero.
        public var truePeakDBFS: Double?

        public init(integratedLUFS: Double, truePeakDBFS: Double?) {
            self.integratedLUFS = integratedLUFS
            self.truePeakDBFS = truePeakDBFS
        }
    }

    public enum Failure: Error, Equatable {
        /// The source could not be decoded to audio (unreadable, undecodable,
        /// zero-frame, or a mid-stream stall).
        case unreadable(URL)
    }

    public init() {}

    /// Decodes `url` at its native rate and measures it. The end-to-end entry the
    /// app uses.
    public func analyze(url: URL) throws -> Measurement {
        let decoded = try Self.decode(url: url)
        return measure(channels: decoded.channels, sampleRate: decoded.sampleRate)
    }

    /// Measures already-decoded per-channel float samples. Hermetic (no I/O); the
    /// tolerance suite targets this against ffmpeg-oracle numbers.
    public func measure(channels: [[Float]], sampleRate: Double) -> Measurement {
        Measurement(
            integratedLUFS: Self.integratedLUFS(channels: channels, sampleRate: sampleRate),
            truePeakDBFS: Self.truePeakDBFS(channels: channels)
        )
    }

    // MARK: - K-weighting

    /// A biquad with `a0` normalized to 1, in the transposed-direct-form-II sense
    /// `y = b0·x + s1 ; s1 = b1·x − a1·y + s2 ; s2 = b2·x − a2·y`.
    struct Biquad: Equatable {
        var b0, b1, b2, a1, a2: Double
    }

    /// Stage 1 — the K-weighting high-shelf "pre-filter". Coefficients are generated
    /// for `sampleRate` with libebur128's parametric constants (they reproduce the
    /// BS.1770-4 published 48 kHz table and interpolate correctly to 44.1 kHz).
    static func kWeightingShelf(sampleRate: Double) -> Biquad {
        let f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10.0, gainDB / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0
        )
    }

    /// Stage 2 — the K-weighting RLB high-pass. Its numerator is exactly `[1, −2, 1]`;
    /// only the poles depend on `sampleRate`.
    static func kWeightingHighpass(sampleRate: Double) -> Biquad {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(Double.pi * f0 / sampleRate)
        let a0 = 1 + k / q + k * k
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
    }

    // MARK: - Integrated loudness (gated BS.1770)

    /// Number of 400 ms gating blocks (100 ms hop) a signal of `frameCount` frames
    /// yields at `sampleRate`: the trailing samples that don't complete another
    /// 100 ms hop never form a block.
    static func blockCount(frameCount: Int, sampleRate: Double) -> Int {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let samplesIn100ms = (Int(sampleRate.rounded()) + 5) / 10
        let blockSamples = 4 * samplesIn100ms
        guard samplesIn100ms > 0, frameCount >= blockSamples else { return 0 }
        return frameCount / samplesIn100ms - 3
    }

    static func integratedLUFS(channels: [[Float]], sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return -.infinity }
        let frameCount = channels.map(\.count).max() ?? 0
        // 100 ms hop / 400 ms block (75 % overlap), sized exactly as libebur128:
        // `samples_in_100ms = (fs + 5) / 10` (integer division).
        let samplesIn100ms = (Int(sampleRate.rounded()) + 5) / 10
        let blockSamples = 4 * samplesIn100ms
        guard samplesIn100ms > 0, frameCount >= blockSamples else { return -.infinity }
        let segmentCount = frameCount / samplesIn100ms // whole 100 ms segments; trailing remainder dropped
        let usableFrames = segmentCount * samplesIn100ms

        let shelf = kWeightingShelf(sampleRate: sampleRate)
        let highpass = kWeightingHighpass(sampleRate: sampleRate)

        // Per-channel sum-of-squares of the K-weighted signal, per 100 ms segment.
        // The biquad state is carried across the whole channel (no per-block reset);
        // squares are folded into the filter loop so the filtered signal is never
        // materialized (memory stays O(segments), not O(frames)).
        var segmentEnergy = [[Double]](repeating: [Double](repeating: 0, count: segmentCount), count: channels.count)
        for channel in 0..<channels.count {
            let samples = channels[channel]
            let count = samples.count
            var shelfS1 = 0.0, shelfS2 = 0.0
            var hpS1 = 0.0, hpS2 = 0.0
            segmentEnergy[channel].withUnsafeMutableBufferPointer { energy in
                for i in 0..<usableFrames {
                    let x = i < count ? Double(samples[i]) : 0.0
                    let y1 = shelf.b0 * x + shelfS1
                    shelfS1 = shelf.b1 * x - shelf.a1 * y1 + shelfS2
                    shelfS2 = shelf.b2 * x - shelf.a2 * y1
                    let y2 = highpass.b0 * y1 + hpS1
                    hpS1 = highpass.b1 * y1 - highpass.a1 * y2 + hpS2
                    hpS2 = highpass.b2 * y1 - highpass.a2 * y2
                    energy[i / samplesIn100ms] += y2 * y2
                }
            }
        }

        // Block energy = Σ_channels weight·(mean square over the 4 segments). A block
        // starts every 100 ms; the last starts 400 ms before the final segment edge.
        var blockEnergies = [Double]()
        blockEnergies.reserveCapacity(max(0, segmentCount - 3))
        var segment = 0
        while segment + 4 <= segmentCount {
            var energy = 0.0
            for channel in 0..<channels.count {
                var sum = 0.0
                for k in 0..<4 { sum += segmentEnergy[channel][segment + k] }
                energy += sum / Double(blockSamples) // channel weight 1.0 (mono/stereo)
            }
            blockEnergies.append(energy)
            segment += 1
        }

        // Absolute gate at −70 LKFS, then relative gate 10 LU below the mean of the
        // absolute-gated blocks. Integrated loudness = 10·log10(mean gated energy) − 0.691.
        let absoluteThreshold = pow(10.0, (-70.0 + 0.691) / 10.0)
        let absoluteGated = blockEnergies.filter { $0 >= absoluteThreshold }
        guard !absoluteGated.isEmpty else { return -.infinity }
        let absoluteMean = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeThreshold = absoluteMean * pow(10.0, -10.0 / 10.0)
        let relativeGated = absoluteGated.filter { $0 >= relativeThreshold }
        guard !relativeGated.isEmpty else { return -.infinity }
        let gatedMean = relativeGated.reduce(0, +) / Double(relativeGated.count)
        return 10.0 * log10(gatedMean) - 0.691
    }

    // MARK: - True peak

    /// 4× oversampled true peak (max over channels). Uses libebur128's canonical
    /// 49-tap Hann-windowed-sinc interpolator, applied as a polyphase FIR so the 4×
    /// signal is never materialized. Exact on tonal content (≤0.01 dB vs ffmpeg);
    /// on full-band noise it reads up to ~1 dB low because ffmpeg's `loudnorm`
    /// measures sample peak after a 192 kHz Kaiser resample that captures more
    /// near-Nyquist inter-sample overshoot — real music sits near the tonal case.
    static func truePeakDBFS(channels: [[Float]]) -> Double? {
        let tapCount = 49
        let factor = 4
        var taps = [Double](repeating: 0, count: tapCount)
        for j in 0..<tapCount {
            let m = Double(j) - Double(tapCount - 1) / 2.0
            var c = 1.0
            if abs(m) > 1e-12 {
                let arg = m * Double.pi / Double(factor)
                c = sin(arg) / arg
            }
            c *= 0.5 * (1.0 - cos(2.0 * Double.pi * Double(j) / Double(tapCount - 1)))
            taps[j] = c
        }
        // Polyphase decomposition: phase p uses taps[p], taps[p+factor], … The phase
        // whose single center tap lands on m=0 passes input samples through unchanged,
        // so it is skipped — the explicit sample-peak floor covers it exactly.
        var subfilters = [[Double]]()
        for phase in 0..<factor {
            var sub = [Double]()
            var idx = phase
            while idx < tapCount { sub.append(taps[idx]); idx += factor }
            let nonZero = sub.filter { abs($0) > 1e-15 }
            if nonZero.count == 1, abs(nonZero[0] - 1.0) < 1e-9 { continue }
            subfilters.append(sub)
        }

        var peak = 0.0
        for samples in channels {
            let count = samples.count
            guard count > 0 else { continue }
            var x = [Double](repeating: 0, count: count)
            vDSP.convertElements(of: samples, to: &x)
            // Sample-peak floor (covers the skipped passthrough phase).
            var channelPeak = 0.0
            vDSP_maxmgvD(x, 1, &channelPeak, vDSP_Length(count))
            if channelPeak > peak { peak = channelPeak }

            for sub in subfilters {
                let subLen = sub.count
                // Full convolution of x with `sub` via vDSP correlation: zero-pad x by
                // (subLen−1) on each side and correlate with the reversed subfilter so
                // out[n] = Σ_k x[n−k]·sub[k] for every valid n (matches the reference).
                let reversed = Array(sub.reversed())
                var padded = [Double](repeating: 0, count: count + 2 * (subLen - 1))
                x.withUnsafeBufferPointer { src in
                    padded.withUnsafeMutableBufferPointer { dst in
                        dst.baseAddress!.advanced(by: subLen - 1).update(from: src.baseAddress!, count: count)
                    }
                }
                let outLen = count + subLen - 1
                var out = [Double](repeating: 0, count: outLen)
                vDSP_convD(padded, 1, reversed, 1, &out, 1, vDSP_Length(outLen), vDSP_Length(subLen))
                var subPeak = 0.0
                vDSP_maxmgvD(out, 1, &subPeak, vDSP_Length(outLen))
                if subPeak > peak { peak = subPeak }
            }
        }
        return peak > 0 ? 20.0 * log10(peak) : nil
    }

    // MARK: - Decode

    /// Decodes `url` to per-channel Float at its native rate (loudness is measured
    /// at the content rate). Throws `Failure.unreadable` for anything that can't be
    /// turned into audio.
    static func decode(url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw Failure.unreadable(url)
        }
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(file.length)
        guard totalFrames > 0, channelCount > 0 else { throw Failure.unreadable(url) }

        var channels = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount { channels[channel].reserveCapacity(totalFrames) }

        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw Failure.unreadable(url)
        }
        do {
            while file.framePosition < file.length {
                try file.read(into: buffer)
                let read = Int(buffer.frameLength)
                // A stall before EOF (corrupt/truncated) must not silently truncate
                // the measurement into a valid-looking short read.
                guard read > 0, let data = buffer.floatChannelData else {
                    throw Failure.unreadable(url)
                }
                for channel in 0..<channelCount {
                    channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: read))
                }
            }
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.unreadable(url)
        }
        return (channels, format.sampleRate)
    }
}
