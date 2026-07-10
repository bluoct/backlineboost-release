import AppKit
import BackbeatCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Transparent AppKit drop target layered over the root view to catch drags
/// from the Apple Music app. Music never puts a plain `public.file-url` on
/// the drag pasteboard the way Finder does — it vends legacy Carbon file
/// promises plus an iTunes metadata plist — so SwiftUI's
/// `.dropDestination(for: URL.self)` never activates for it. This shim
/// registers only for those Music-specific flavors, which keeps Finder drags
/// routed to the existing SwiftUI drop untouched.
struct MusicDropShim: NSViewRepresentable {
    let onTargeted: @MainActor (Bool) -> Void
    let onImport: @MainActor ([URL]) async -> Void
    let onReject: @MainActor (String) -> Void

    func makeNSView(context: Context) -> MusicDropShimNSView {
        let view = MusicDropShimNSView()
        view.onTargeted = onTargeted
        view.onImport = onImport
        view.onReject = onReject
        return view
    }

    func updateNSView(_ view: MusicDropShimNSView, context: Context) {
        view.onTargeted = onTargeted
        view.onImport = onImport
        view.onReject = onReject
    }
}

final class MusicDropShimNSView: NSView {
    var onTargeted: (@MainActor (Bool) -> Void)?
    var onImport: (@MainActor ([URL]) async -> Void)?
    var onReject: (@MainActor (String) -> Void)?

    private static let logger = Logger(subsystem: "com.bluoct.backlineboost", category: "MusicDrop")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let identifiers = MusicPasteboardMetadataParser.filePromiseTypeIdentifiers
            + MusicPasteboardMetadataParser.metadataTypeIdentifiers
        registerForDraggedTypes(identifiers.map { NSPasteboard.PasteboardType($0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MusicDropShimNSView is created in code only")
    }

    // Drag-destination targeting picks the deepest view registered for the
    // dragged types and ignores hitTest, so returning nil here passes every
    // click through to the SwiftUI content while drags still arrive.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        logPasteboard(sender.draggingPasteboard, stage: "draggingEntered")
        guard promisedContentAllowsAudio(sender.draggingPasteboard) else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        logPasteboard(pasteboard, stage: "performDragOperation")

        // Tiers 1+2 merged (2026-07-08): a multi-track drag vends a real
        // `public.file-url` for file-reference tracks only, while EVERY
        // dragged track's `Location` lives in the combined Music metadata
        // plist on the first pasteboard item. Returning early on whichever
        // source hit first swallowed the rest of the drag — one file-backed
        // track made a seven-track drop import a single song. Import the
        // union instead, deduplicated by standardized path.
        let directURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []

        var metadataURLs: [URL] = []
        var unimportable: [MusicPasteboardMetadataParser.UnimportableTrack] = []
        for identifier in MusicPasteboardMetadataParser.metadataTypeIdentifiers {
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(identifier)) else {
                continue
            }
            let located = MusicPasteboardMetadataParser.locationURLs(from: data)
            Self.logger.info(
                "Tier 2 \(identifier, privacy: .public): \(data.count, privacy: .public) bytes, located \(located.count, privacy: .public)"
            )
            metadataURLs.append(contentsOf: located)
            unimportable.append(contentsOf: MusicPasteboardMetadataParser.unimportableTracks(from: data))
        }

        // A candidate whose file is absent is a cloud track that was never
        // downloaded — reported below, never silently dropped.
        let candidates = AudioImportFilter.audioFileURLs(
            from: MusicPasteboardMetadataParser.mergedImportCandidates(
                direct: directURLs,
                metadataLocations: metadataURLs
            )
        )
        var importable: [URL] = []
        var missingFiles: [URL] = []
        for url in candidates {
            if FileManager.default.isReadableFile(atPath: url.path) {
                importable.append(url)
            } else {
                missingFiles.append(url)
            }
        }
        Self.logger.info(
            "Drop candidates: direct \(directURLs.count, privacy: .public), metadata \(metadataURLs.count, privacy: .public), importable \(importable.count, privacy: .public), missing \(missingFiles.count, privacy: .public)"
        )

        if !importable.isEmpty {
            deliver(importable)
            probeLegacyPromise(from: sender, pasteboard: pasteboard)
            // A partial import still explains what it skipped.
            reportUnimportable(unimportable, missingFiles: missingFiles)
            return true
        }

        // Tier 3: legacy Carbon file promises. Deprecated and increasingly
        // unreliable (recent macOS returns an empty HFS promise for Music
        // drags), so it is now the last resort behind the metadata path.
        if fulfillLegacyPromises(from: sender, pasteboard: pasteboard, unimportable: unimportable, missingFiles: missingFiles) {
            return true
        }

        // Nothing imported. If the drag was recognizable protected/unsupported
        // /not-downloaded tracks, say so rather than leaving a silent no-op.
        reportUnimportable(unimportable, missingFiles: missingFiles)
        return false
    }

    /// Tier 3 body. Returns true when it recognized Carbon file promises and
    /// started an async import, false when no usable promise was present. Carries
    /// the drop's `unimportable`/`missingFiles` so that if the promise stabilizes
    /// to no audio, the reasons are still surfaced instead of silently swallowed
    /// by the `return true` (F9).
    private func fulfillLegacyPromises(
        from sender: NSDraggingInfo,
        pasteboard: NSPasteboard,
        unimportable: [MusicPasteboardMetadataParser.UnimportableTrack],
        missingFiles: [URL]
    ) -> Bool {
        let promiseTypes = MusicPasteboardMetadataParser.filePromiseTypeIdentifiers
        let hasPromise = pasteboard.types?.contains { promiseTypes.contains($0.rawValue) } ?? false
        guard hasPromise else { return false }

        let dropDirectory = BackbeatFileLocations.musicDropsDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Could not create promise drop directory: \(error.localizedDescription)")
            return false
        }

        let promisedNames = legacyPromisedFileNames(from: sender, droppedAt: dropDirectory)
        Self.logger.info("Promised file names: \(promisedNames, privacy: .public)")
        guard !promisedNames.isEmpty else {
            try? FileManager.default.removeItem(at: dropDirectory)
            return false
        }

        let importHandler = onImport
        Task { @MainActor in
            // The source writes the promised files after the drop returns;
            // wait for them to stabilize, import, then discard the scratch
            // directory (import copies into the managed library first).
            let stabilized = await PromisedFileAwaiter().stabilizedFiles(
                named: promisedNames,
                in: dropDirectory
            )
            let audioURLs = AudioImportFilter.audioFileURLs(from: stabilized)
            Self.logger.info("Promised files stabilized: \(audioURLs.map(\.lastPathComponent))")
            if !audioURLs.isEmpty {
                await importHandler?(audioURLs)
            } else {
                // The Carbon promise resolved to no audio — explain the dead-end
                // drop instead of leaving a silent no-op (F9).
                self.reportUnimportable(
                    unimportable,
                    missingFiles: missingFiles,
                    fallbackMessage: "Music didn't hand over the dragged track. It may be protected, not downloaded to this Mac, or an unsupported format."
                )
            }
            try? FileManager.default.removeItem(at: dropDirectory)
        }
        return true
    }

    /// Diagnostic only, gated behind Settings ▸ Diagnostics ▸ Write debug log:
    /// after a successful tier-1/2 import, ALSO request the legacy Carbon
    /// promise into a scratch directory and log whether Music still fulfills
    /// it. The 2026-07-05 diagnosis saw empty fulfillment (D-083); if this
    /// probe shows files being delivered again, the promise tier can be
    /// promoted back to primary — Music-exported copies carry embedded
    /// artwork and need no media-library permission. Never runs when tier 3
    /// handles the drop (that path IS the promise) and never affects the
    /// import result. A delivered probe directory is kept for inspection;
    /// an empty one is removed.
    private func probeLegacyPromise(from sender: NSDraggingInfo, pasteboard: NSPasteboard) {
        guard DebugLog.isEnabled() else { return }
        let promiseTypes = MusicPasteboardMetadataParser.filePromiseTypeIdentifiers
        let hasPromise = pasteboard.types?.contains { promiseTypes.contains($0.rawValue) } ?? false
        guard hasPromise else {
            Self.logger.notice("promise.probe skipped=no-promise-flavor")
            return
        }

        let probeDirectory = BackbeatFileLocations.musicDropsDirectory
            .appendingPathComponent("promise-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("promise.probe error=create-dir detail=\(error.localizedDescription, privacy: .public)")
            return
        }

        // The Carbon names call must happen inside performDragOperation while
        // the drag session is alive; only the await happens later.
        let names = legacyPromisedFileNames(from: sender, droppedAt: probeDirectory)
        Self.logger.notice("promise.probe names=\(names.count, privacy: .public) list=\(names, privacy: .public)")
        guard !names.isEmpty else {
            try? FileManager.default.removeItem(at: probeDirectory)
            return
        }

        Task { @MainActor in
            let started = Date()
            let delivered = await PromisedFileAwaiter().stabilizedFiles(named: names, in: probeDirectory)
            let totalBytes = delivered.reduce(Int64(0)) { sum, url in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
                return sum + size
            }
            let tookMs = Int(Date().timeIntervalSince(started) * 1000)
            if delivered.isEmpty {
                try? FileManager.default.removeItem(at: probeDirectory)
            }
            let kept = delivered.isEmpty ? "removed" : probeDirectory.path
            Self.logger.notice(
                "promise.probe delivered=\(delivered.count, privacy: .public) totalBytes=\(totalBytes, privacy: .public) tookMs=\(tookMs, privacy: .public) dir=\(kept, privacy: .public)"
            )
        }
    }

    /// Explains every track a drop could not land: protected Apple Music
    /// downloads (DRM `.m4p` is encrypted, so it can be neither decoded nor
    /// separated into stems), unsupported formats, and tracks whose local
    /// file is missing (cloud tracks never downloaded to this Mac). Runs
    /// after partial imports too — a five-track drop that lands four must
    /// say why the fifth is absent.
    private func reportUnimportable(
        _ tracks: [MusicPasteboardMetadataParser.UnimportableTrack],
        missingFiles: [URL],
        fallbackMessage: String? = nil
    ) {
        guard !tracks.isEmpty || !missingFiles.isEmpty else {
            // Nothing track-specific to report, but the caller may still need to
            // explain a dead-end drop (a legacy promise that delivered no audio)
            // rather than leave a silent no-op (F9).
            if let fallbackMessage {
                let handler = onReject
                Task { @MainActor in handler?(fallbackMessage) }
            }
            return
        }
        var sections: [String] = []
        let protected = tracks.filter(\.isProtected)
        if !protected.isEmpty {
            let titles = protected.map(\.title).joined(separator: "\n")
            sections.append("These are protected Apple Music downloads, which are DRM-encrypted — Backline Boost can't decode or separate them:\n\(titles)\n\nImport a purchased or CD/file copy of the track instead.")
        }
        let unsupported = tracks.filter { !$0.isProtected }
        if !unsupported.isEmpty {
            let titles = unsupported.map(\.title).joined(separator: "\n")
            sections.append("These tracks are an unsupported format and can't be imported:\n\(titles)")
        }
        if !missingFiles.isEmpty {
            let titles = missingFiles
                .map { $0.deletingPathExtension().lastPathComponent }
                .joined(separator: "\n")
            sections.append("These tracks aren't downloaded on this Mac, so there is no audio file to import:\n\(titles)\n\nDownload them in Music first, then drag them again.")
        }
        let message = sections.joined(separator: "\n\n")
        Self.logger.info("Rejected drop: \(tracks.count, privacy: .public) unimportable, \(missingFiles.count, privacy: .public) missing track(s)")
        let handler = onReject
        Task { @MainActor in
            handler?(message)
        }
    }

    /// Invokes the legacy `namesOfPromisedFilesDroppedAtDestination:` via its
    /// selector: the macOS 14 SDK no longer exposes the method to Swift, but
    /// the Objective-C runtime still implements it, and it is the only call
    /// that fulfills Carbon-style promises. If a future macOS drops it, the
    /// responds(to:) guard turns tier 3 into a logged no-op instead of a crash.
    private func legacyPromisedFileNames(from sender: NSDraggingInfo, droppedAt destination: URL) -> [String] {
        let selector = NSSelectorFromString("namesOfPromisedFilesDroppedAtDestination:")
        guard let object = sender as? NSObject, object.responds(to: selector) else {
            Self.logger.error("Dragging info does not respond to namesOfPromisedFilesDroppedAtDestination:")
            return []
        }
        let result = object.perform(selector, with: destination as NSURL)?.takeUnretainedValue()
        return (result as? [String]) ?? []
    }

    private func deliver(_ urls: [URL]) {
        let importHandler = onImport
        Task { @MainActor in
            await importHandler?(urls)
        }
    }

    /// A promise source may declare what it will write via the legacy
    /// content-type flavor. Decline drags that declare only non-audio
    /// content (Photos, browsers); accept when nothing is declared and let
    /// the tiered handlers decide.
    private func promisedContentAllowsAudio(_ pasteboard: NSPasteboard) -> Bool {
        let contentType = NSPasteboard.PasteboardType(
            MusicPasteboardMetadataParser.filePromiseContentTypeIdentifier
        )
        let declared = (pasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: contentType) }
            .filter { !$0.isEmpty }
        guard !declared.isEmpty else { return true }

        return declared.contains { raw in
            guard let utType = UTType(raw) else { return true }
            if utType.conforms(to: .audio) { return true }
            let promisedExtension = utType.preferredFilenameExtension?.lowercased() ?? ""
            return AudioImportFilter.supportedAudioExtensions.contains(promisedExtension)
        }
    }

    /// Permanent payload logging — the exact flavors Music vends drift
    /// across macOS releases, and this is how a failed drag gets diagnosed:
    /// ./script/build_and_run.sh --logs
    private func logPasteboard(_ pasteboard: NSPasteboard, stage: String) {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        Self.logger.info("\(stage, privacy: .public): pasteboard types \(types, privacy: .public)")
        for (index, item) in (pasteboard.pasteboardItems ?? []).enumerated() {
            let itemTypes = item.types.map(\.rawValue)
            Self.logger.info("\(stage, privacy: .public): item[\(index)] types \(itemTypes, privacy: .public)")
        }
    }
}
