import Foundation

public enum LibrarySortField: String, CaseIterable, Codable, Sendable {
    case dateAdded
    case title
    case artist
    case album
    case duration

    public var displayLabel: String {
        switch self {
        case .dateAdded:
            "Date Added"
        case .title:
            "Title"
        case .artist:
            "Artist"
        case .album:
            "Album"
        case .duration:
            "Duration"
        }
    }
}

public struct LibrarySortOrder: Equatable, Codable, Sendable {
    public var field: LibrarySortField
    public var ascending: Bool

    public static let `default` = LibrarySortOrder(field: .dateAdded, ascending: true)

    private enum CodingKeys: String, CodingKey {
        case field
        case ascending
    }

    public init(field: LibrarySortField, ascending: Bool) {
        self.field = field
        self.ascending = ascending
    }

    // Decoding never throws on unknown values: a preference written by a
    // future build (say, a new sort field) read by this build must degrade to
    // the default sort WITHOUT reaching the snapshot's lossy-load diagnostics —
    // a sort preference must never raise the corruption banner or trigger a
    // .corrupt backup of the library file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawField = (try? container.decodeIfPresent(String.self, forKey: .field)) ?? nil
        field = rawField.flatMap(LibrarySortField.init(rawValue:)) ?? LibrarySortOrder.default.field
        ascending = ((try? container.decodeIfPresent(Bool.self, forKey: .ascending)) ?? nil) ?? LibrarySortOrder.default.ascending
    }
}

/// The library's single filter → sort pipeline. Both the library view and the
/// sidebar render exactly this function's output, and the D-102 hybrid
/// double-click queues it verbatim — nothing else may re-derive the visible
/// order.
public enum LibraryTrackQuery {
    public static func visibleTracks(
        in tracks: [BackbeatTrack],
        sort: LibrarySortOrder,
        searchText: String
    ) -> [BackbeatTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? tracks : tracks.filter { matches($0, query: query) }
        return sorted(filtered, by: sort)
    }

    /// The artist string the library row displays: the tag when present,
    /// otherwise the source filename. Search matches what the user sees, so
    /// the filter goes through the same fallback.
    public static func displayedArtist(for track: BackbeatTrack) -> String {
        track.artist ?? track.sourceURL.deletingPathExtension().lastPathComponent
    }

    private static func matches(_ track: BackbeatTrack, query: String) -> Bool {
        if track.title.localizedStandardContains(query) { return true }
        if displayedArtist(for: track).localizedStandardContains(query) { return true }
        if let album = track.album, album.localizedStandardContains(query) { return true }
        return false
    }

    private static func sorted(_ tracks: [BackbeatTrack], by sort: LibrarySortOrder) -> [BackbeatTrack] {
        Array(tracks.enumerated())
            .sorted { lhs, rhs in
                areInOrder(lhs, rhs, sort: sort)
            }
            .map(\.element)
    }

    // Comparison levels: (1) missing-metadata bucket, (2) the sort key,
    // (3) title within equal artist/album keys, (4) original position.
    // `ascending` flips level 2 only — unknowns always sink to the bottom,
    // and equal keys always keep their persisted order. The level-4 tie-break
    // is the upgrade-identity mechanism: an all-legacy library (every
    // `dateAdded` nil) under the default sort compares entirely equal and
    // comes back in exactly the order it was persisted in.
    private static func areInOrder(
        _ lhs: (offset: Int, element: BackbeatTrack),
        _ rhs: (offset: Int, element: BackbeatTrack),
        sort: LibrarySortOrder
    ) -> Bool {
        if let bucketDecision = missingMetadataOrder(lhs.element, rhs.element, field: sort.field) {
            return bucketDecision
        }
        switch primaryComparison(lhs.element, rhs.element, field: sort.field) {
        case .orderedAscending:
            return sort.ascending
        case .orderedDescending:
            return !sort.ascending
        case .orderedSame:
            break
        }
        if sort.field == .artist || sort.field == .album {
            switch lhs.element.title.localizedStandardCompare(rhs.element.title) {
            case .orderedAscending:
                return true
            case .orderedDescending:
                return false
            case .orderedSame:
                break
            }
        }
        return lhs.offset < rhs.offset
    }

    /// nil = same bucket (compare keys); true/false = decided by the bucket.
    private static func missingMetadataOrder(
        _ lhs: BackbeatTrack,
        _ rhs: BackbeatTrack,
        field: LibrarySortField
    ) -> Bool? {
        let lhsMissing: Bool
        let rhsMissing: Bool
        switch field {
        case .artist:
            lhsMissing = lhs.artist == nil
            rhsMissing = rhs.artist == nil
        case .album:
            lhsMissing = lhs.album == nil
            rhsMissing = rhs.album == nil
        case .dateAdded, .title, .duration:
            return nil
        }
        guard lhsMissing != rhsMissing else { return nil }
        return rhsMissing
    }

    private static func primaryComparison(
        _ lhs: BackbeatTrack,
        _ rhs: BackbeatTrack,
        field: LibrarySortField
    ) -> ComparisonResult {
        switch field {
        case .dateAdded:
            return comparableOrder(lhs.dateAdded ?? .distantPast, rhs.dateAdded ?? .distantPast)
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .artist:
            return (lhs.artist ?? "").localizedStandardCompare(rhs.artist ?? "")
        case .album:
            return (lhs.album ?? "").localizedStandardCompare(rhs.album ?? "")
        case .duration:
            return comparableOrder(totalOrderDuration(lhs.duration), totalOrderDuration(rhs.duration))
        }
    }

    // A NaN duration would break sorted(by:)'s strict-weak-ordering contract:
    // NaN compares .orderedSame against everything (falling to the index
    // tie-break) while numeric pairs still differ, which permits ordering
    // cycles — documented undefined behavior in sorted(by:). Coalescing to
    // -infinity restores a total order.
    private static func totalOrderDuration(_ value: TimeInterval) -> TimeInterval {
        value.isNaN ? -.infinity : value
    }

    private static func comparableOrder<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
