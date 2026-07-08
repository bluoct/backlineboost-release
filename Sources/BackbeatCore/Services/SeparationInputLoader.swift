import Foundation
import AVFoundation

/// Errors from the separation-input decode path. `LocalizedError` from day one —
/// these surface through the render-failed banner (review finding R4).
public enum SeparationInputError: Error, LocalizedError, Equatable {
    case unreadable(URL)
    case emptyAudio(URL)
    case truncatedDecode(URL)
    case conversionFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "The audio file could not be opened for stem separation: \(url.lastPathComponent)."
        case .emptyAudio(let url):
            return "The audio file contains no audio to separate: \(url.lastPathComponent)."
        case .truncatedDecode(let url):
            return "The audio file could not be fully decoded — it may be corrupted or truncated: \(url.lastPathComponent)."
        case .conversionFailed(let url):
            return "The audio could not be converted for stem separation: \(url.lastPathComponent)."
        }
    }
}

/// The custom engine's separation input: exactly two equal-length channels at the
/// engine sample rate (htdemucs: 44.1 kHz).
public struct SeparationInput: Sendable {
    public let channels: [[Float]]
    public let sampleRate: Double

    public var frameCount: Int { channels.first?.count ?? 0 }
}

/// Decodes any importable audio file into the custom engine's input contract
/// (charter Phase 1). Replaces — never ports — the vendored `AudioIO`/`AudioDSP`
/// load path, fixing the review's decode-seam findings by construction:
///
/// - R1: chunked read-until-EOF with a stall guard (`read > 0`), mirroring
///   `StemMixdown.decode` — a decoder that stalls before its declared length throws
///   instead of silently separating a truncated prefix. `file.length` is never
///   force-converted to `AVAudioFrameCount` (the vendored port's trapping
///   `Int64 → UInt32`); chunks use a fixed capacity.
/// - R2: zero-frame input is rejected up front (`emptyAudio`), so no downstream
///   math ever sees an empty buffer.
/// - D2: sample-rate conversion is `AVAudioConverter` at mastering quality — a
///   proper anti-aliased polyphase resampler, not 2-tap linear interpolation.
///
/// Channel layout mirrors upstream demucs `convert_audio_channels(…, channels=2)`:
/// stereo passes through, mono is duplicated, more-than-stereo keeps the first two
/// channels.
public struct SeparationInputLoader: Sendable {
    public let targetSampleRate: Double

    public init(targetSampleRate: Double = 44_100) {
        self.targetSampleRate = targetSampleRate
    }

    public func load(url: URL) throws -> SeparationInput {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SeparationInputError.unreadable(url)
        }
        let format = file.processingFormat
        let sourceChannelCount = Int(format.channelCount)
        // A file that opens but declares no audio is unusable — reject rather than
        // let a zero-frame buffer reach the DSP (the vendored path crashed here).
        guard file.length > 0, sourceChannelCount > 0 else {
            throw SeparationInputError.emptyAudio(url)
        }

        // demucs convert_audio_channels: keep at most the first two channels.
        let keptChannelCount = min(sourceChannelCount, 2)
        var channels = [[Float]](repeating: [], count: keptChannelCount)
        let estimatedFrames = Int(clamping: file.length)
        for channel in 0..<keptChannelCount {
            channels[channel].reserveCapacity(estimatedFrames)
        }

        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw SeparationInputError.conversionFailed(url)
        }
        do {
            while file.framePosition < file.length {
                try file.read(into: buffer)
                let read = Int(buffer.frameLength)
                // A read that stalls before EOF (corrupt/truncated container) must not
                // silently truncate the decode into a valid-looking short separation.
                guard read > 0, let data = buffer.floatChannelData else {
                    throw SeparationInputError.truncatedDecode(url)
                }
                for channel in 0..<keptChannelCount {
                    channels[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: read))
                }
            }
        } catch let error as SeparationInputError {
            throw error
        } catch {
            throw SeparationInputError.truncatedDecode(url)
        }
        guard let decodedFrames = channels.first?.count, decodedFrames > 0 else {
            throw SeparationInputError.emptyAudio(url)
        }

        if format.sampleRate != targetSampleRate {
            channels = try resample(channels, from: format.sampleRate, url: url)
        }
        guard let frames = channels.first?.count, frames > 0 else {
            throw SeparationInputError.conversionFailed(url)
        }

        // demucs convert_audio_channels: mono expands to both channels. Duplicating
        // AFTER the resample does the SRC work once; the array copy is CoW-free.
        if channels.count == 1 {
            channels = [channels[0], channels[0]]
        }
        return SeparationInput(channels: channels, sampleRate: targetSampleRate)
    }

    /// Anti-aliased SRC via `AVAudioConverter` at mastering quality. Follows the
    /// hardened pull-converter shape of `AudioPCMDecoder.decodeSamples` (mid-stream
    /// failure is carried out of the input block and becomes a hard error).
    private func resample(_ channels: [[Float]], from sourceRate: Double, url: URL) throws -> [[Float]] {
        let channelCount = channels.count
        let sourceFrames = channels[0].count
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: AVAudioChannelCount(channelCount),
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw SeparationInputError.conversionFailed(url)
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let chunkFrames = 65_536
        let cursor = ResampleCursor()
        let inputBlock: AVAudioConverterInputBlock = { _, inputStatus in
            if cursor.position >= sourceFrames {
                inputStatus.pointee = .endOfStream
                return nil
            }
            let count = min(chunkFrames, sourceFrames - cursor.position)
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)),
                  let data = inputBuffer.floatChannelData else {
                cursor.failed = true
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputBuffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<channelCount {
                channels[channel].withUnsafeBufferPointer { source in
                    data[channel].update(from: source.baseAddress! + cursor.position, count: count)
                }
            }
            cursor.position += count
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        var output = [[Float]](repeating: [], count: channelCount)
        let reserve = Int((Double(sourceFrames) * targetSampleRate / sourceRate).rounded(.up)) + chunkFrames
        for channel in 0..<channelCount {
            output[channel].reserveCapacity(reserve)
        }

        drain: while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
                throw SeparationInputError.conversionFailed(url)
            }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: inputBlock)
            switch status {
            case .haveData, .endOfStream, .inputRanDry:
                if let data = outputBuffer.floatChannelData, outputBuffer.frameLength > 0 {
                    let read = Int(outputBuffer.frameLength)
                    for channel in 0..<channelCount {
                        output[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: read))
                    }
                }
                if status == .endOfStream || status == .inputRanDry { break drain }
                if outputBuffer.frameLength == 0 { break drain }
            case .error:
                throw SeparationInputError.conversionFailed(url)
            @unknown default:
                throw SeparationInputError.conversionFailed(url)
            }
            if cursor.failed { throw SeparationInputError.conversionFailed(url) }
        }
        if cursor.failed { throw SeparationInputError.conversionFailed(url) }
        return output
    }

    /// Reference box carrying the input-block cursor and failure flag out of the
    /// `@Sendable` block. `convert(...)` invokes the block synchronously on the
    /// calling thread, so the mutation is never concurrent (same pattern and
    /// justification as `AudioPCMDecoder.ReadState`).
    private final class ResampleCursor: @unchecked Sendable {
        var position = 0
        var failed = false
    }
}
