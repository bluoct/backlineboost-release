import Foundation

public enum BackbeatFormat {
    public static func duration(_ seconds: TimeInterval) -> String {
        let roundedSeconds = max(0, Int(seconds.rounded()))
        let minutes = roundedSeconds / 60
        let secondsPart = roundedSeconds % 60
        return "\(minutes):" + String(format: "%02d", secondsPart)
    }

    public static func boost(_ db: Double) -> String {
        if abs(db) < 0.05 {
            return "0.0 dB"
        }
        let rounded = (db * 10).rounded(.toNearestOrAwayFromZero) / 10
        return String(format: "%+.1f dB", rounded)
    }
}
