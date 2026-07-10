import XCTest

final class MusicDropShimSourceTests: XCTestCase {
    func testRootViewKeepsFinderDropAndAddsMusicShim() throws {
        let source = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")

        XCTAssertTrue(
            source.contains(".dropDestination(for: URL.self)"),
            "Finder drags must keep flowing through the SwiftUI dropDestination; the Music shim is additive."
        )
        XCTAssertTrue(source.contains("MusicDropShim("))
        XCTAssertTrue(
            source.contains("await pipeline.enqueue(urls: urls, managesSecurityScope: false, useArtworkFallback: true).value"),
            "The shim must await through the shared import chain so its promise scratch directory outlives the copy into the managed library — and only Music drags may enable the artwork fallback."
        )
    }

    func testShimUsesLegacyCarbonPromiseProtocol() throws {
        let source = try readSource("Sources/Backbeat/Views/MusicDropShimView.swift")

        XCTAssertTrue(
            source.contains("namesOfPromisedFilesDroppedAtDestination:"),
            "Music only implements the legacy Carbon promise protocol; the selector-invoked legacy receiver call is the one that works."
        )
        XCTAssertTrue(
            source.contains("responds(to: selector)"),
            "The legacy selector is absent from the Swift SDK — the runtime call must stay guarded so a future macOS removal degrades to a logged no-op."
        )
        XCTAssertFalse(
            source.contains("NSFilePromiseReceiver"),
            "NSFilePromiseReceiver needs com.apple.NSFilePromiseItemMetaData, which Music never writes — this exact mistake caused the reverted 2026-07-01 attempt."
        )
        XCTAssertTrue(
            source.contains("MusicPasteboardMetadataParser.filePromiseTypeIdentifiers"),
            "The shim must register the shared promise-type constants so the vocabulary stays in the testable Core parser."
        )
        XCTAssertTrue(source.contains("registerForDraggedTypes"))
    }

    func testShimPrefersMetadataLocationOverDeadCarbonPromise() throws {
        let source = try readSource("Sources/Backbeat/Views/MusicDropShimView.swift")

        XCTAssertTrue(
            source.contains("MusicPasteboardMetadataParser.metadataTypeIdentifiers"),
            "Tier 2 reads the Music/TV metadata plist Locations — the durable path now that the Carbon promise (tier 3) no longer resolves on current macOS."
        )
        XCTAssertTrue(
            source.contains("fulfillLegacyPromises"),
            "The Carbon promise path stays as a guarded last resort behind the metadata path."
        )
    }

    func testShimProbesLegacyPromiseOnlyWhenDebugLogEnabled() throws {
        let source = try readSource("Sources/Backbeat/Views/MusicDropShimView.swift")

        XCTAssertTrue(
            source.contains("private func probeLegacyPromise"),
            "The promise probe records whether Music still fulfills Carbon promises — the evidence needed to decide if the promise tier (embedded artwork, no media-library permission) can be promoted back to primary."
        )
        XCTAssertTrue(
            source.contains("guard DebugLog.isEnabled() else { return }"),
            "The probe is diagnostic-only and must stay behind the debug-log setting; every drop would otherwise ask Music to export files nobody uses."
        )
        XCTAssertTrue(
            source.contains("promise.probe delivered="),
            "The probe's structured delivered= marker is what the diagnosis greps for in debug.log."
        )
    }

    func testShimImportsUnionOfDirectURLsAndMetadataLocations() throws {
        let source = try readSource("Sources/Backbeat/Views/MusicDropShimView.swift")

        XCTAssertTrue(
            source.contains("MusicPasteboardMetadataParser.mergedImportCandidates"),
            "A multi-track Music drag vends a file URL for SOME tracks and metadata Locations for all of them — the 2026-07-08 bug imported one song from a seven-track drop because the direct-URL tier returned early. The shim must import the union."
        )
        XCTAssertFalse(
            source.contains("if !usableDirect.isEmpty"),
            "The direct-URL early return is the exact shape that swallowed multi-track drags; direct and metadata candidates must flow into one merged import."
        )

        let pipeline = try readSource("Sources/BackbeatCore/Services/TrackImportPipeline.swift")
        XCTAssertTrue(
            pipeline.contains("failures.append"),
            "One failing file must not abort the rest of a multi-file import batch."
        )
    }

    func testShimExplainsDeadEndDropsInsteadOfFailingSilently() throws {
        let shim = try readSource("Sources/Backbeat/Views/MusicDropShimView.swift")
        XCTAssertTrue(
            shim.contains("MusicPasteboardMetadataParser.unimportableTracks"),
            "A drop that lands no audio must detect protected/unsupported tracks so it can explain itself."
        )
        XCTAssertTrue(shim.contains("reportUnimportable"))
        XCTAssertTrue(
            shim.contains("missingFiles:"),
            "Partial imports must explain skipped tracks (missing local file / DRM) instead of dropping them silently."
        )

        let root = try readSource("Sources/Backbeat/Views/BackbeatRootView.swift")
        XCTAssertTrue(
            root.contains("onReject:"),
            "The root view must wire the shim's rejection callback so DRM/unsupported drops surface a message."
        )
        XCTAssertTrue(root.contains("Can't import this track"))
    }

    func testShimPassesClicksThroughAndLogsPayloads() throws {
        let source = try readSource("Sources/Backbeat/Views/MusicDropShimView.swift")

        XCTAssertTrue(
            source.contains("override func hitTest"),
            "The shim must stay click-transparent; drag targeting ignores hitTest but mouse events do not."
        )
        XCTAssertTrue(
            source.contains("Logger(subsystem: \"com.bluoct.backlineboost\", category: \"MusicDrop\")"),
            "Permanent payload logging is the documented diagnostic path for Music pasteboard drift across macOS releases."
        )
        XCTAssertTrue(source.contains("PromisedFileAwaiter"))
    }

    func testDeadEndLegacyPromiseStillExplainsTheDrop() throws {
        let source = try readSource("Sources/Backbeat/Views/MusicDropShimView.swift")

        XCTAssertTrue(
            source.contains("fulfillLegacyPromises(from: sender, pasteboard: pasteboard, unimportable: unimportable, missingFiles: missingFiles)"),
            "The tier-3 path must carry the collected reasons so a promise that delivers nothing can still explain itself (F9)."
        )
        XCTAssertTrue(
            source.contains("fallbackMessage"),
            "A legacy promise that stabilizes zero audio must surface a message, not return true and silently swallow the drop (F9)."
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
