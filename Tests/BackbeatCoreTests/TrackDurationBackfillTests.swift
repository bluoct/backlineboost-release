import XCTest
@testable import BackbeatCore

@MainActor
final class TrackDurationBackfillTests: XCTestCase {
    private struct ProbeFailure: Error {}

    private func item(currentDuration: TimeInterval) -> TrackDurationBackfill.Item {
        TrackDurationBackfill.Item(
            trackID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).m4a"),
            currentDuration: currentDuration
        )
    }

    // MARK: - Threshold boundary

    func testDeltaExactlyAtToleranceKeepsEstimate() async {
        let target = item(currentDuration: 100)
        var outcomes: [TrackDurationBackfill.Outcome] = []

        await TrackDurationBackfill().run(
            items: [target],
            probe: { _ in 100.05 },
            onResolve: { _, outcome in outcomes.append(outcome) }
        )

        XCTAssertEqual(outcomes, [.keptEstimate], "a delta of exactly 0.05 must not count as drift")
    }

    func testDeltaJustAboveToleranceUpdates() async {
        let target = item(currentDuration: 100)
        var outcomes: [TrackDurationBackfill.Outcome] = []

        await TrackDurationBackfill().run(
            items: [target],
            probe: { _ in 100.0501 },
            onResolve: { _, outcome in outcomes.append(outcome) }
        )

        XCTAssertEqual(outcomes, [.updated(100.0501)], "a delta just over 0.05 must resolve as updated")
    }

    // MARK: - Probe failure

    func testProbeThrowKeepsEstimate() async {
        let target = item(currentDuration: 42)
        var outcomes: [TrackDurationBackfill.Outcome] = []

        await TrackDurationBackfill().run(
            items: [target],
            probe: { _ in throw ProbeFailure() },
            onResolve: { _, outcome in outcomes.append(outcome) }
        )

        XCTAssertEqual(outcomes, [.keptEstimate], "a missing/unreadable original must keep its estimate (F7 posture), not fail the sweep")
    }

    // MARK: - Ordering

    func testItemsResolveInInputOrder() async {
        let items = (0..<5).map { _ in item(currentDuration: 0) }
        var resolvedIDs: [UUID] = []

        await TrackDurationBackfill().run(
            items: items,
            probe: { _ in 999 },
            onResolve: { trackID, _ in resolvedIDs.append(trackID) }
        )

        XCTAssertEqual(resolvedIDs, items.map(\.trackID), "items must resolve strictly in the order they were passed in")
    }

    // MARK: - Cancellation

    func testCancellationBetweenItemsStopsTheSweep() async {
        let items = (0..<5).map { _ in item(currentDuration: 0) }
        var resolvedIDs: [UUID] = []

        // The probe sleeps so the polling loop below gets a scheduling window
        // to observe the first resolution and cancel before every item runs.
        let task = Task { @MainActor in
            await TrackDurationBackfill().run(
                items: items,
                probe: { _ in
                    try await Task.sleep(nanoseconds: 5_000_000)
                    return 999
                },
                onResolve: { trackID, _ in resolvedIDs.append(trackID) }
            )
        }

        while resolvedIDs.isEmpty {
            await Task.yield()
        }
        task.cancel()
        await task.value

        XCTAssertLessThan(resolvedIDs.count, items.count, "cancellation between items must stop the sweep before every item resolves")
        XCTAssertEqual(resolvedIDs, Array(items.prefix(resolvedIDs.count)).map(\.trackID), "the resolved items must be an in-order prefix, with nothing resolved after cancellation took effect")
    }
}
