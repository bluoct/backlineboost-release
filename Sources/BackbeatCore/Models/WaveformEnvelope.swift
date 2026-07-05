import Accelerate
import Foundation

public struct WaveformEnvelope: Equatable, Sendable {
    public struct Bin: Equatable, Sendable {
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        public let amplitude: Double

        public init(startTime: TimeInterval, endTime: TimeInterval, amplitude: Double) {
            self.startTime = startTime
            self.endTime = endTime
            self.amplitude = min(1, max(0, amplitude.isFinite ? amplitude : 0))
        }
    }

    public let duration: TimeInterval
    public let bins: [Bin]

    public init(duration: TimeInterval, bins: [Bin]) {
        self.duration = max(0, duration.isFinite ? duration : 0)
        self.bins = bins
    }

    public static func make(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        binCount: Int
    ) -> WaveformEnvelope {
        guard binCount > 0 else {
            return WaveformEnvelope(duration: 0, bins: [])
        }
        let channelCount = max(1, channelCount)
        let frameCount = samples.count / channelCount
        let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0
        guard frameCount > 0 else {
            return zero(duration: duration, binCount: binCount)
        }

        let peaks = bucketPeaks(
            frameCount: frameCount,
            binCount: binCount,
            peakOfFrames: { frameRange in
                samples.withUnsafeBufferPointer { buffer in
                    var peak: Float = 0
                    for channelIndex in 0..<channelCount {
                        var channelPeak: Float = 0
                        vDSP_maxmgv(
                            buffer.baseAddress! + frameRange.lowerBound * channelCount + channelIndex,
                            vDSP_Stride(channelCount),
                            &channelPeak,
                            vDSP_Length(frameRange.count)
                        )
                        // Checked per channel: folding with max() would swallow
                        // NaN (max(x, .nan) == x), never reaching a post-fold guard.
                        guard channelPeak.isFinite else {
                            // NaN/inf in the range: fall back to the scalar walk that
                            // skips non-finite samples, matching historical behavior.
                            return finitePeak(in: buffer, frameRange: frameRange, channelCount: channelCount)
                        }
                        peak = max(peak, channelPeak)
                    }
                    return Double(peak)
                }
            }
        )

        return WaveformEnvelope(duration: duration, bins: bins(from: peaks, duration: duration))
    }

    public static func make(
        channelSamples: [[Float]],
        sampleRate: Double,
        binCount: Int
    ) -> WaveformEnvelope {
        guard binCount > 0 else {
            return WaveformEnvelope(duration: 0, bins: [])
        }
        let frameCount = channelSamples.map(\.count).min() ?? 0
        let duration = sampleRate > 0 ? Double(frameCount) / sampleRate : 0
        guard frameCount > 0, !channelSamples.isEmpty else {
            return zero(duration: duration, binCount: binCount)
        }

        let peaks = bucketPeaks(
            frameCount: frameCount,
            binCount: binCount,
            peakOfFrames: { frameRange in
                var peak = 0.0
                for channel in channelSamples {
                    var channelPeak: Float = 0
                    channel.withUnsafeBufferPointer { buffer in
                        vDSP_maxmgv(
                            buffer.baseAddress! + frameRange.lowerBound,
                            1,
                            &channelPeak,
                            vDSP_Length(frameRange.count)
                        )
                    }
                    if channelPeak.isFinite {
                        peak = max(peak, Double(channelPeak))
                    } else {
                        // NaN/inf in this channel's range: scalar walk that skips
                        // non-finite samples, matching historical behavior.
                        peak = max(peak, finitePeak(in: channel, frameRange: frameRange))
                    }
                }
                return peak
            }
        )

        return WaveformEnvelope(duration: duration, bins: bins(from: peaks, duration: duration))
    }

    private static func zero(duration: TimeInterval, binCount: Int) -> WaveformEnvelope {
        WaveformEnvelope(
            duration: duration,
            bins: (0..<binCount).map { index in
                let start = binCount > 0 ? duration * Double(index) / Double(binCount) : 0
                let end = binCount > 0 ? duration * Double(index + 1) / Double(binCount) : 0
                return Bin(startTime: start, endTime: end, amplitude: 0)
            }
        )
    }

    private static func bucketPeaks(
        frameCount: Int,
        binCount: Int,
        peakOfFrames: (Range<Int>) -> Double
    ) -> [Double] {
        var peaks = [Double](repeating: 0, count: binCount)
        for bin in 0..<binCount {
            let start = binStartFrame(bin, frameCount: frameCount, binCount: binCount)
            let end = binStartFrame(bin + 1, frameCount: frameCount, binCount: binCount)
            guard end > start else { continue }
            peaks[bin] = peakOfFrames(start..<end)
        }
        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks }
        return peaks.map { min(1, max(0, $0 / maximum)) }
    }

    // The historical frame-to-bin mapping; bin boundaries are derived from it
    // so the per-bin partition is provably unchanged.
    private static func mappedBin(_ frameIndex: Int, frameCount: Int, binCount: Int) -> Int {
        min(binCount - 1, Int(Double(frameIndex) * Double(binCount) / Double(frameCount)))
    }

    private static func binStartFrame(_ bin: Int, frameCount: Int, binCount: Int) -> Int {
        guard bin > 0 else { return 0 }
        guard bin < binCount else { return frameCount }
        // Integer estimate, then nudge until it agrees with the Double-rounded
        // mapping in boundary edge cases.
        var frame = min(frameCount, (bin * frameCount + binCount - 1) / binCount)
        while frame > 0, mappedBin(frame - 1, frameCount: frameCount, binCount: binCount) >= bin {
            frame -= 1
        }
        while frame < frameCount, mappedBin(frame, frameCount: frameCount, binCount: binCount) < bin {
            frame += 1
        }
        return frame
    }

    private static func finitePeak(
        in samples: UnsafeBufferPointer<Float>,
        frameRange: Range<Int>,
        channelCount: Int
    ) -> Double {
        var peak = 0.0
        for frameIndex in frameRange {
            let offset = frameIndex * channelCount
            for channelIndex in 0..<channelCount {
                let sample = Double(samples[offset + channelIndex])
                guard sample.isFinite else { continue }
                peak = max(peak, abs(sample))
            }
        }
        return peak
    }

    private static func finitePeak(in channel: [Float], frameRange: Range<Int>) -> Double {
        var peak = 0.0
        for frameIndex in frameRange {
            let sample = Double(channel[frameIndex])
            guard sample.isFinite else { continue }
            peak = max(peak, abs(sample))
        }
        return peak
    }

    private static func bins(from peaks: [Double], duration: TimeInterval) -> [Bin] {
        guard !peaks.isEmpty else { return [] }
        return peaks.indices.map { index in
            Bin(
                startTime: duration * Double(index) / Double(peaks.count),
                endTime: duration * Double(index + 1) / Double(peaks.count),
                amplitude: peaks[index]
            )
        }
    }
}
