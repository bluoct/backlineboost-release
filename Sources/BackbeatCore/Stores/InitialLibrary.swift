import Foundation

@MainActor
public enum InitialLibrary {
    public static func makeDevelopmentStore(renderRootURL: URL = BackbeatFileLocations.renderRootDirectory) -> LibraryStore {
        LibraryStore(
            tracks: [],
            selectedTrackID: nil,
            nowPlayingTrackID: nil,
            playbackProgress: 0
        )
    }
}
