import BackbeatCore
import Foundation
import iTunesLibrary

/// Recovers album artwork from the local Music library database for files
/// imported straight off disk. Apple Music keeps a track's artwork in its
/// database, not in the audio file, so a Music-drag import — which byte-copies
/// the on-disk library file (D-083) — arrives artless even though Music
/// displays art for it. Matching the imported file's on-disk location against
/// `ITLibMediaItem.location` recovers exactly the image Music shows; location
/// is the same URL the drag's metadata plist carried, and it disambiguates
/// same-titled tracks (e.g. Anthrax's and Nine Inch Nails' "Only").
///
/// Reading the library is gated by the "Media & Apple Music" permission
/// (`kTCCServiceMediaLibrary`): the first lookup triggers the system consent
/// prompt, which is why this runs only during a user-initiated Music-drag
/// import (D-087) and never at launch or for Finder/panel imports. A fresh
/// `ITLibrary` per lookup keeps the snapshot current — a track added to Music
/// moments before the drag is visible to its own import — and costs little
/// next to the import's file copy and render queueing.
struct MusicLibraryArtworkProvider {
    /// Artwork bytes for the media item whose on-disk file is `url`, or nil
    /// when the track is not in the Music library, has no artwork there, or
    /// the library is unreadable (permission denied, no Music installation).
    func artworkData(forFileAt url: URL) async -> Data? {
        let targetPath = url.standardizedFileURL.path
        return await Task.detached(priority: .userInitiated) {
            guard let library = try? ITLibrary(apiVersion: "1.0") else {
                DebugLog.importing.notice("import.artworkLookup library=unavailable")
                return nil
            }
            guard let item = library.allMediaItems.first(where: {
                $0.location?.standardizedFileURL.path == targetPath
            }) else {
                DebugLog.importing.notice("import.artworkLookup match=none")
                return nil
            }
            let data = item.artwork?.imageData
            DebugLog.importing.notice("import.artworkLookup match=location artworkBytes=\(data?.count ?? 0)")
            return data
        }.value
    }
}
