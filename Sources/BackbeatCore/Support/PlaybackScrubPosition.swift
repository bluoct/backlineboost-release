import Foundation

public enum PlaybackScrubPosition {
    public static func progress(locationX: Double, width: Double) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, locationX / width))
    }

    public static func elapsed(progress: Double, duration: TimeInterval) -> TimeInterval {
        min(1, max(0, progress)) * max(0, duration)
    }
}
