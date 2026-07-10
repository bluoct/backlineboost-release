import BackbeatCore
import Foundation

@MainActor
protocol RenderPlaybackEngine: AnyObject {
    var transportDuration: TimeInterval { get }
    var isSectionLoopChainActive: Bool { get }
    func currentElapsed() -> TimeInterval
    func seek(to elapsed: TimeInterval, autoplay: Bool, volume: Double, speed: Double, normalizationGainDB: Double) throws
    func setSectionLoop(_ range: PracticeLoopRange?)
}

extension SingleFilePlaybackEngine: RenderPlaybackEngine {}
extension TwoTrackMixPlaybackEngine: RenderPlaybackEngine {}
