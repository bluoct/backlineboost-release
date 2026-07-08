import XCTest
@testable import BackbeatCore

final class RenderSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RenderSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBitrateDefaultsTo256WhenUnset() {
        XCTAssertEqual(RenderSettings.bitrate(defaults: defaults), .kbps256)
        XCTAssertEqual(RenderBitrate.default, .kbps256)
    }

    func testBitrateRoundTripsAllPresets() {
        for bitrate in RenderBitrate.allCases {
            RenderSettings.setBitrate(bitrate, defaults: defaults)
            XCTAssertEqual(RenderSettings.bitrate(defaults: defaults), bitrate)
        }
    }

    func testBitrateFallsBackToDefaultForUnknownStoredValue() {
        defaults.set(999, forKey: RenderSettings.bitrateDefaultsKey)
        XCTAssertEqual(RenderSettings.bitrate(defaults: defaults), .default)
    }

    func testBitrateEncoderBitRateValues() {
        // The native AAC encoder takes bits per second (AVEncoderBitRateKey),
        // replacing ffmpeg's "<n>k" argument now that the ffmpeg builders are gone.
        XCTAssertEqual(RenderBitrate.kbps128.encoderBitRate, 128_000)
        XCTAssertEqual(RenderBitrate.kbps192.encoderBitRate, 192_000)
        XCTAssertEqual(RenderBitrate.kbps256.encoderBitRate, 256_000)
        XCTAssertEqual(RenderBitrate.kbps320.encoderBitRate, 320_000)
    }

    func testConfiguredRendersFolderRoundTripAndReset() {
        XCTAssertNil(RenderSettings.configuredRendersFolder(defaults: defaults))

        let url = URL(fileURLWithPath: "/tmp/backbeat-renders", isDirectory: true)
        RenderSettings.setConfiguredRendersFolder(url, defaults: defaults)
        XCTAssertEqual(RenderSettings.configuredRendersFolder(defaults: defaults)?.path, url.path)

        RenderSettings.setConfiguredRendersFolder(nil, defaults: defaults)
        XCTAssertNil(RenderSettings.configuredRendersFolder(defaults: defaults))
        XCTAssertNil(defaults.string(forKey: RenderSettings.rendersFolderDefaultsKey))
    }

    func testEffectiveRootUsesDefaultWhenNothingConfigured() {
        let defaultURL = URL(fileURLWithPath: "/default/renders", isDirectory: true)
        XCTAssertEqual(
            RenderSettings.effectiveRendersRootURL(configured: nil, defaultURL: defaultURL),
            defaultURL
        )
    }

    func testEffectiveRootUsesExistingWritableConfiguredFolder() throws {
        let configured = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configured) }

        let defaultURL = URL(fileURLWithPath: "/default/renders", isDirectory: true)
        XCTAssertEqual(
            RenderSettings.effectiveRendersRootURL(configured: configured, defaultURL: defaultURL).path,
            configured.path
        )
    }

    func testEffectiveRootRecreatesMissingConfiguredFolder() {
        let configured = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configured.deletingLastPathComponent()) }

        let defaultURL = URL(fileURLWithPath: "/default/renders", isDirectory: true)
        let effective = RenderSettings.effectiveRendersRootURL(configured: configured, defaultURL: defaultURL)

        XCTAssertEqual(effective.path, configured.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: configured.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testEffectiveRootFallsBackWhenConfiguredPathIsAFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a folder".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let defaultURL = URL(fileURLWithPath: "/default/renders", isDirectory: true)
        XCTAssertEqual(
            RenderSettings.effectiveRendersRootURL(configured: fileURL, defaultURL: defaultURL),
            defaultURL
        )
    }

    func testEffectiveRootFallsBackWhenConfiguredFolderCannotBeCreated() throws {
        // Parent is a regular file, so creating the child directory must fail.
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("blocker".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let configured = parentFile.appendingPathComponent("renders", isDirectory: true)

        let defaultURL = URL(fileURLWithPath: "/default/renders", isDirectory: true)
        XCTAssertEqual(
            RenderSettings.effectiveRendersRootURL(configured: configured, defaultURL: defaultURL),
            defaultURL
        )
    }

    func testEffectiveRootFallsBackWhenConfiguredFolderIsUnwritable() throws {
        let configured = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: configured.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configured.path)
            try? FileManager.default.removeItem(at: configured)
        }

        let defaultURL = URL(fileURLWithPath: "/default/renders", isDirectory: true)
        XCTAssertEqual(
            RenderSettings.effectiveRendersRootURL(configured: configured, defaultURL: defaultURL),
            defaultURL
        )
    }
}
