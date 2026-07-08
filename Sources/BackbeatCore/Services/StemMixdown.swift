import Foundation
import AVFoundation
import Accelerate

/// The native, in-process replacement for the two LIVE render ffmpeg mix
/// builders. It reads the demucs-produced stem WAVs, mixes/encodes with
/// AVFoundation + Accelerate, and writes durable `.m4a` outputs — no subprocess,
/// no ffmpeg.
///
///  - **Drumless**: unity float sum of bass + other + vocals (no normalization,
///    longest-duration), then a look-ahead peak limiter at 0.98, then AAC. This
///    reproduces the old drumless mix filtergraph (three-input mix with no
///    normalization and a 0.98 limiter).
///  - **Drums**: a straight AAC re-encode of the drums stem — no gain, no
///    limiter — reproducing the old drums-stem re-encode.
///
/// The renderer injects this behind the `StemMixing` seam so its orchestration
/// (progress order, non-empty-output validation, supersession) is unit-testable
/// without touching real audio. The seam is **buffer-based**: it consumes the
/// in-memory `SeparatedStems` the native engine returns, with no WAV round-trip
/// (architecture §2.2, amendment A3). `StemMixdown` also keeps the file-based
/// (demucs-era) entry points as concrete methods — still directly tested — until
/// Task 9 removes the last file-stem consumer.
public protocol StemMixing: Sendable {
    func writeDrums(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws
    func writeDrumless(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws
}

public struct StemMixdown: StemMixing {
    /// The output true-peak ceiling, matching ffmpeg's `alimiter=limit=0.98`.
    public static let limiterCeiling: Float = 0.98

    public init() {}

    // MARK: - File entry points (demucs-era)

    public func writeDrums(stems: FourStemURLs, outputURL: URL, bitrate: RenderBitrate) async throws {
        let drums = try decode(stems.drums)
        // Straight passthrough re-encode: no gain, no limiter.
        try encode(channels: drums.channels, sampleRate: drums.sampleRate, bitrate: bitrate, to: outputURL)
    }

    public func writeDrumless(stems: FourStemURLs, outputURL: URL, bitrate: RenderBitrate) async throws {
        // The whole track is buffered in memory (a few float copies of each stem)
        // rather than streamed like the ffmpeg amix it replaces. That is acceptable
        // for a serial background render on the target machines; chunked streaming
        // is a D5 (memory & scaling) follow-up. The three stem decodes are scoped so
        // they free before the limiter/encoder run, and the sum is limited in place.
        let sampleRate: Double
        var summed: [[Float]]
        do {
            let bass = try decode(stems.bass)
            let other = try decode(stems.other)
            let vocals = try decode(stems.vocals)

            // The stems come from a single demucs run, so their format is identical;
            // guard rather than silently mixing mismatched rates.
            sampleRate = bass.sampleRate
            guard other.sampleRate == sampleRate, vocals.sampleRate == sampleRate else {
                throw BoostedDrumsRenderError.invalidOutput(outputURL)
            }
            summed = try Self.unitySumBacking(
                [bass.channels, other.channels, vocals.channels],
                outputURL: outputURL
            )
        }
        Self.peakLimitInPlace(&summed, sampleRate: sampleRate, ceiling: Self.limiterCeiling)
        try encode(channels: summed, sampleRate: sampleRate, bitrate: bitrate, to: outputURL)
    }

    // MARK: - Buffer entry points (MLX-era)

    /// Encodes the in-memory drums stem straight to AAC — no gain, no limiter, no
    /// WAV round-trip. The buffer analogue of the file-based `writeDrums`, consuming
    /// the `SeparatedStems` the native engine returns (architecture §2.2, A3).
    public func writeDrums(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws {
        try encode(channels: stems.drums, sampleRate: stems.sampleRate, bitrate: bitrate, to: outputURL)
    }

    /// Unity-sums the in-memory bass+other+vocals stems, limits to 0.98, and encodes
    /// — the buffer analogue of the file-based `writeDrumless` with no WAV round-trip.
    /// `SeparatedStems` carries a single `sampleRate` for every stem, so there is no
    /// per-stem rate check (the engine emits one coherent rate); the shared summation
    /// still guards the channel counts.
    public func writeDrumless(stems: SeparatedStems, outputURL: URL, bitrate: RenderBitrate) async throws {
        var summed = try Self.unitySumBacking(
            [stems.bass, stems.other, stems.vocals],
            outputURL: outputURL
        )
        Self.peakLimitInPlace(&summed, sampleRate: stems.sampleRate, ceiling: Self.limiterCeiling)
        try encode(channels: summed, sampleRate: stems.sampleRate, bitrate: bitrate, to: outputURL)
    }

    /// Per-channel unity sum of the backing stems (bass/other/vocals), shared by the
    /// file and buffer drumless paths. Every stem must carry the same channel count;
    /// an empty or ragged set is rejected as `invalidOutput` rather than silently
    /// producing a partial mix. Isolated as a pure helper so the file path can free
    /// its decoded stems immediately after summing (peak-memory scoping).
    static func unitySumBacking(_ backingStems: [[[Float]]], outputURL: URL) throws -> [[Float]] {
        let channelCount = backingStems.first?.count ?? 0
        guard channelCount > 0, backingStems.allSatisfy({ $0.count == channelCount }) else {
            throw BoostedDrumsRenderError.invalidOutput(outputURL)
        }
        var summed = [[Float]]()
        summed.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            summed.append(unitySum(backingStems.map { $0[channel] }))
        }
        return summed
    }

    // MARK: - Pure DSP (hermetically testable, no file I/O)

    /// Sample-wise unity sum with no normalization. Buffers may differ in length;
    /// the result is sized to the longest and shorter buffers pad with silence
    /// (ffmpeg `amix` `duration=longest`).
    public static func unitySum(_ buffers: [[Float]]) -> [Float] {
        let count = buffers.map(\.count).max() ?? 0
        guard count > 0 else { return [] }
        var accumulator = [Float](repeating: 0, count: count)
        accumulator.withUnsafeMutableBufferPointer { dst in
            for buffer in buffers where !buffer.isEmpty {
                buffer.withUnsafeBufferPointer { src in
                    vDSP_vadd(dst.baseAddress!, 1, src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(buffer.count))
                }
            }
        }
        return accumulator
    }

    /// A deterministic look-ahead peak limiter.
    ///
    /// The gain reduction is derived from the peak taken across ALL channels, so
    /// every channel receives the same gain at each sample (no stereo image
    /// shift). A look-ahead sliding minimum lets the reduction ramp in before a
    /// transient arrives, and an exponential release recovers afterwards.
    ///
    /// The output is guaranteed to satisfy `|out| <= ceiling`: the applied gain
    /// `g[i]` never exceeds `gLA[i] = min(required[i..i+lookAhead])`, and
    /// `required[i] = min(1, ceiling / peak[i])`, so
    /// `|out[i]| = |x[i]| * g[i] <= peak[i] * (ceiling / peak[i]) = ceiling`.
    /// Channels may differ in length — the envelope spans the LONGEST channel so
    /// every sample of every channel is limited — and a final clamp absorbs the
    /// sub-1e-7 Float rounding of `ceiling / peak`, so the bound is exact.
    public static func peakLimited(_ channels: [[Float]], sampleRate: Double, ceiling: Float) -> [[Float]] {
        var result = channels
        peakLimitInPlace(&result, sampleRate: sampleRate, ceiling: ceiling)
        return result
    }

    /// In-place form used by the file mixer: it mutates the summed buffer instead
    /// of duplicating the whole track (the value-returning `peakLimited` wrapper
    /// exists for the pure tests). See `peakLimited` for the guarantee.
    static func peakLimitInPlace(_ channels: inout [[Float]], sampleRate: Double, ceiling: Float) {
        let frameCount = channels.map(\.count).max() ?? 0
        guard frameCount > 0 else { return }

        // Per-sample peak across channels (channels may differ in length).
        var peak = [Float](repeating: 0, count: frameCount)
        for channel in channels {
            for i in 0..<channel.count {
                peak[i] = max(peak[i], abs(channel[i]))
            }
        }

        // Required instantaneous gain to hold the ceiling.
        var required = [Float](repeating: 1, count: frameCount)
        for i in 0..<frameCount where peak[i] > ceiling {
            required[i] = ceiling / peak[i]
        }

        // Look-ahead (attack anticipation) + hard guarantee via sliding minimum.
        let lookAhead = max(1, Int(sampleRate * 0.0015)) // ~1.5 ms
        let anticipated = slidingMinimumForward(required, window: lookAhead)

        // Exponential release: gain rises back toward the anticipated envelope but
        // never above it, preserving the ceiling guarantee.
        let releaseSamples = max(1.0, sampleRate * 0.08) // ~80 ms
        let releaseCoefficient = Float(exp(-1.0 / releaseSamples))

        var gain: Float = 1
        for i in 0..<frameCount {
            let target = anticipated[i]
            if target < gain {
                gain = target // attack: snap down (already anticipated by look-ahead)
            } else {
                gain = target - (target - gain) * releaseCoefficient // release toward target from below
            }
            for channel in 0..<channels.count where i < channels[channel].count {
                // The clamp makes |out| <= ceiling exact despite Float rounding of
                // ceiling/peak; it only ever trims sub-1e-7 overshoot at the ceiling.
                channels[channel][i] = min(ceiling, max(-ceiling, channels[channel][i] * gain))
            }
        }
    }

    /// `result[i] = min(values[i ..< min(i + window, count)])` in O(n) via a
    /// monotonic deque (front holds the window minimum). `window` is small
    /// (a few ms), so the deque stays short in practice.
    static func slidingMinimumForward(_ values: [Float], window: Int) -> [Float] {
        let count = values.count
        guard count > 0 else { return [] }
        let win = max(1, window)
        var result = [Float](repeating: 0, count: count)
        var indices = [Int]() // monotonically increasing values, front = current minimum
        indices.reserveCapacity(win + 1)
        var head = 0
        var pushed = 0
        for i in 0..<count {
            let upper = min(i + win - 1, count - 1)
            while pushed <= upper {
                while indices.count > head, values[indices[indices.count - 1]] >= values[pushed] {
                    indices.removeLast()
                }
                indices.append(pushed)
                pushed += 1
            }
            while head < indices.count, indices[head] < i {
                head += 1
            }
            result[i] = values[indices[head]]
        }
        return result
    }

    // MARK: - Decode / encode

    private struct DecodedAudio {
        let channels: [[Float]]
        let sampleRate: Double
    }

    private func decode(_ url: URL) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw BoostedDrumsRenderError.missingStem(url)
        }
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        let totalFrames = Int(file.length)
        // A stem that exists but carries no audio (empty/zero-length) is unusable;
        // treat it as a missing stem rather than letting an empty decode flow
        // through to a header-only "successful" output.
        guard totalFrames > 0, channelCount > 0 else {
            throw BoostedDrumsRenderError.missingStem(url)
        }
        var channels = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            channels[channel].reserveCapacity(totalFrames)
        }

        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw BoostedDrumsRenderError.missingStem(url)
        }
        do {
            while file.framePosition < file.length {
                try file.read(into: buffer)
                let read = Int(buffer.frameLength)
                // A read that stalls before EOF (corrupt/truncated file) must not
                // silently truncate the decode into a valid-looking short output.
                guard read > 0, let data = buffer.floatChannelData else {
                    throw BoostedDrumsRenderError.missingStem(url)
                }
                for channel in 0..<channelCount {
                    channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: read))
                }
            }
        } catch let error as BoostedDrumsRenderError {
            throw error
        } catch {
            throw BoostedDrumsRenderError.missingStem(url)
        }
        return DecodedAudio(channels: channels, sampleRate: format.sampleRate)
    }

    private func encode(channels: [[Float]], sampleRate: Double, bitrate: RenderBitrate, to outputURL: URL) throws {
        let channelCount = channels.count
        let frameCount = channels.map(\.count).max() ?? 0
        // Refuse to write a header-only file for an empty mix; an output with no
        // audio frames is invalid, not a success (it would still pass the
        // renderer's non-empty byte check).
        guard channelCount > 0, frameCount > 0 else {
            throw BoostedDrumsRenderError.invalidOutput(outputURL)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitrate.encoderBitRate,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: outputURL, settings: settings)
        } catch {
            throw BoostedDrumsRenderError.invalidOutput(outputURL)
        }
        let format = file.processingFormat

        let chunkFrames = 65_536
        var offset = 0
        do {
            while offset < frameCount {
                let thisChunk = min(chunkFrames, frameCount - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(thisChunk)),
                      let destination = buffer.floatChannelData
                else {
                    throw BoostedDrumsRenderError.invalidOutput(outputURL)
                }
                buffer.frameLength = AVAudioFrameCount(thisChunk)
                for channel in 0..<channelCount {
                    let source = channels[channel]
                    let out = destination[channel]
                    for i in 0..<thisChunk {
                        let index = offset + i
                        out[i] = index < source.count ? source[index] : 0
                    }
                }
                try file.write(from: buffer)
                offset += thisChunk
            }
        } catch let error as BoostedDrumsRenderError {
            throw error
        } catch {
            throw BoostedDrumsRenderError.invalidOutput(outputURL)
        }
        // `file` closes/flushes on deinit as this function returns.
    }
}
