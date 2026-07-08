import Foundation
import AVFoundation
import Accelerate

/// The native, in-process replacement for the old ffmpeg mono-PCM decode path
/// (downmix to one channel, resample to the caller's rate, emit little-endian
/// Float32). It decodes any audio file to mono Float32 at a requested sample rate
/// using `AVAudioFile` + `AVAudioConverter` — no subprocess, no ffmpeg, no scratch
/// file on disk.
///
/// The sole consumer is `WaveformEnvelopeAnalyzer`, which only needs per-bin
/// peaks. The downmix averages ALL source channels (like ffmpeg `-ac 1`) rather
/// than keeping one, so content panned into any channel still shows in the
/// waveform: `AVAudioConverter` reduced directly to a mono output keeps only
/// channel 0, so this resamples every channel and averages them here instead.
public struct AudioPCMDecoder: Sendable {
    private let sampleRate: Double

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Decodes `url` to mono Float32 samples at `sampleRate`.
    ///
    /// Throws `BoostedDrumsRenderError.invalidOutput(url)` for any input that can't
    /// be turned into audio: an unreadable/undecodable/missing file, a well-formed
    /// but zero-frame file, a mid-stream decode failure, or a conversion that yields
    /// no samples. The old ffmpeg path distinguished `missingCommand`/`commandFailed`
    /// (no native analog — there is no subprocess, exit code, or captured output) and
    /// `invalidOutput` (empty result); in-process, every failure collapses to the
    /// surviving `invalidOutput` case, which is exactly the failure signal the
    /// waveform cache already treats as "analysis failed, do not cache".
    public func decodeSamples(url: URL) async throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw BoostedDrumsRenderError.invalidOutput(url)
        }

        let inputFormat = file.processingFormat
        let channelCount = Int(inputFormat.channelCount)
        // A file that opens but carries no audio can't be decoded to samples.
        guard file.length > 0, channelCount > 0 else {
            throw BoostedDrumsRenderError.invalidOutput(url)
        }

        // Resample every source channel to the requested rate (keeping the channel
        // count), then average them to mono below. Converting straight to a mono
        // output would instead keep only channel 0 and silently drop the rest.
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw BoostedDrumsRenderError.invalidOutput(url)
        }

        let inputChunkFrames: AVAudioFrameCount = 65_536
        let outputChunkFrames: AVAudioFrameCount = 65_536

        // Surfaced from inside the pull block so a mid-stream read failure becomes a
        // hard error rather than a silently-truncated decode. The block is `@Sendable`
        // but `convert(...)` invokes it synchronously on this thread, so a reference
        // box carries the flag out (no real concurrency; hence `@unchecked Sendable`).
        let readState = ReadState()
        let inputBlock: AVAudioConverterInputBlock = { _, inputStatus in
            if file.framePosition >= file.length {
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputChunkFrames) else {
                readState.failed = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: inputBuffer)
            } catch {
                readState.failed = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            if inputBuffer.frameLength == 0 {
                // The `framePosition >= length` guard above already handles a clean
                // end, so a zero-length read HERE means the file stalled before its
                // declared length. AVAudioFile clamps a truncated WAV's length to the
                // decodable bytes (so that path never reaches here), but a compressed
                // container — an m4a/mp3 whose metadata frame count exceeds the actual
                // decodable audio — can stall mid-stream; fail rather than silently
                // caching a short waveform (mirrors `StemMixdown.decode`'s `guard read > 0`).
                readState.failed = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        let reserve = Int(Double(file.length) * sampleRate / inputFormat.sampleRate) + Int(outputChunkFrames)
        var channels = [[Float]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            channels[channel].reserveCapacity(reserve)
        }

        loop: while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputChunkFrames) else {
                throw BoostedDrumsRenderError.invalidOutput(url)
            }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)

            switch status {
            case .haveData, .endOfStream, .inputRanDry:
                if let channelData = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                    let read = Int(outputBuffer.frameLength)
                    for channel in 0..<channelCount {
                        channels[channel].append(contentsOf: UnsafeBufferPointer(start: channelData[channel], count: read))
                    }
                }
                // `.endOfStream` = fully drained; `.inputRanDry` cannot recur since the
                // input block only ever signals `.haveData`/`.endOfStream` (never
                // `.noDataNow`); a `.haveData`/empty result would otherwise spin forever.
                if status == .endOfStream || status == .inputRanDry { break loop }
                if outputBuffer.frameLength == 0 { break loop }
            case .error:
                throw BoostedDrumsRenderError.invalidOutput(url)
            @unknown default:
                throw BoostedDrumsRenderError.invalidOutput(url)
            }

            if readState.failed { throw BoostedDrumsRenderError.invalidOutput(url) }
        }

        if readState.failed { throw BoostedDrumsRenderError.invalidOutput(url) }

        let frameCount = channels.map(\.count).max() ?? 0
        guard frameCount > 0 else { throw BoostedDrumsRenderError.invalidOutput(url) }
        if channelCount == 1 { return channels[0] }

        // Downmix: mean of all channels (matches ffmpeg `-ac 1`; channels are equal
        // length here, so the sum needs no per-sample length guard).
        var mono = [Float](repeating: 0, count: frameCount)
        mono.withUnsafeMutableBufferPointer { dst in
            for channel in channels where !channel.isEmpty {
                channel.withUnsafeBufferPointer { src in
                    vDSP_vadd(dst.baseAddress!, 1, src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(min(channel.count, frameCount)))
                }
            }
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frameCount))
        return mono
    }

    /// Reference box that carries a mid-stream read failure out of the `@Sendable`
    /// input block. `convert(...)` calls the block synchronously on the current
    /// thread, so the mutation is never concurrent (`@unchecked Sendable`).
    private final class ReadState: @unchecked Sendable {
        var failed = false
    }
}
