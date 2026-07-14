import Foundation

/// A playback start/engine failure the UI can present. Cases carry no file
/// paths or raw Foundation error text — the copy must stay safe to show (COR-003).
public enum PlaybackFailure: CaseIterable, Equatable, Sendable {
    case playlistEmpty
    case trackNotInPlaylist
    case queueEmpty
    case trackNotInList
    case trackNotPlayable
    /// A rendered Drums/Drumless asset failed in the engine with its files
    /// present on disk (e.g. an incompatible pair) — missing files never get
    /// here; they recover and fall back to Original first.
    case renderUnplayable
    /// The track's Original source file could not be played.
    case originalUnplayable
    /// The track's Original source file is gone from disk (D-107).
    case sourceFileMissing
    /// A render failed, recovery fell back to Original, and that failed too.
    case fallbackFailed

    public var userMessage: String {
        switch self {
        case .playlistEmpty: "Playlist has no playable tracks."
        case .trackNotInPlaylist: "Track is not in this playlist."
        case .queueEmpty: "No playable tracks."
        case .trackNotInList: "Track is not in the current list."
        case .trackNotPlayable: "Track is not playable."
        case .renderUnplayable: "This track's rendered files couldn't be played."
        case .originalUnplayable: "This track's audio file couldn't be played."
        case .sourceFileMissing: "This track's original audio file is missing."
        case .fallbackFailed: "This track couldn't be played — its rendered files and its original audio both failed."
        }
    }
}
