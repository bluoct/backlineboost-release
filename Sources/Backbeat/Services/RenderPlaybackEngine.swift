import Foundation

@MainActor
protocol RenderPlaybackEngine: AnyObject {
    func currentElapsed() -> TimeInterval
    func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws
}

extension SingleFilePlaybackEngine: RenderPlaybackEngine {}
extension TwoTrackMixPlaybackEngine: RenderPlaybackEngine {}
