import Foundation

public protocol WaveformEnvelopeAnalyzing: Sendable {
    func analyze(url: URL, binCount: Int) async throws -> WaveformEnvelope
}

public struct WaveformEnvelopeAnalyzer: WaveformEnvelopeAnalyzing {
    private let analysisSampleRate: Double
    private let decoder: MonoPCMDecoder

    public init(
        analysisSampleRate: Double = 22_050,
        temporaryRootURL: URL = BackbeatFileLocations.temporaryDirectory
            .appendingPathComponent("waveforms", isDirectory: true),
        commandResolver: @escaping RenderPreflight.CommandResolver = RenderPreflight.resolveCommand(_:),
        commandExecutor: any RenderCommandExecuting = ProcessRenderCommandExecutor()
    ) {
        self.analysisSampleRate = analysisSampleRate
        self.decoder = MonoPCMDecoder(
            sampleRate: analysisSampleRate,
            temporaryRootURL: temporaryRootURL,
            commandResolver: commandResolver,
            commandExecutor: commandExecutor
        )
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
