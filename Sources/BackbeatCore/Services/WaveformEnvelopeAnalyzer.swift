import Foundation

public protocol WaveformEnvelopeAnalyzing: Sendable {
    func analyze(url: URL, binCount: Int) async throws -> WaveformEnvelope
}

public struct WaveformEnvelopeAnalyzer: WaveformEnvelopeAnalyzing {
    private let analysisSampleRate: Double
    private let decoder: AudioPCMDecoder

    public init(
        analysisSampleRate: Double = 22_050
    ) {
        self.analysisSampleRate = analysisSampleRate
        self.decoder = AudioPCMDecoder(sampleRate: analysisSampleRate)
    }

    public func analyze(url: URL, binCount: Int = 240) async throws -> WaveformEnvelope {
        let samples = try await decoder.decodeSamples(url: url)
        return WaveformEnvelope.make(
            samples: samples,
            sampleRate: analysisSampleRate,
            channelCount: 1,
            binCount: binCount
        )
    }
}
