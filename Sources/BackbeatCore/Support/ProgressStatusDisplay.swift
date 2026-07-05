import Foundation

public struct ProgressStatusDisplay: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case active
        case ready
        case failed
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let actionTitle: String?

    public init(kind: Kind, title: String, detail: String, actionTitle: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
    }
}

public enum RenderProgressState: Equatable, Sendable {
    case idle
    case separatingStems
    case mixingDrumsTrack
    case mixingDrumlessTrack
    case finalizingOutput
    case complete
    case failed(String)

    public var display: ProgressStatusDisplay? {
        switch self {
        case .idle, .complete:
            nil
        case .separatingStems:
            ProgressStatusDisplay(
                kind: .active,
                title: "Separating stems",
                detail: "Extracting drums, bass, vocals, and other parts."
            )
        case .mixingDrumsTrack:
            ProgressStatusDisplay(
                kind: .active,
                title: "Creating drums track",
                detail: "Exporting the isolated drum stem for live mixing."
            )
        case .mixingDrumlessTrack:
            ProgressStatusDisplay(
                kind: .active,
                title: "Creating drumless track",
                detail: "Combining the backing stems without the drum stem."
            )
        case .finalizingOutput:
            ProgressStatusDisplay(
                kind: .active,
                title: "Finalizing render",
                detail: "Validating the rendered files and clearing temporary stems."
            )
        case .failed(let message):
            ProgressStatusDisplay(
                kind: .failed,
                title: "Render failed",
                detail: message,
                actionTitle: "Retry render"
            )
        }
    }
}
