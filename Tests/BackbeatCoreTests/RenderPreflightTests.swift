import os
import XCTest
@testable import BackbeatCore

final class RenderPreflightTests: XCTestCase {
    func testReturnsMissingDemucsWhenCommandCannotBeFound() async {
        let preflight = RenderPreflight(commandResolver: { _ in nil })

        let result = await preflight.check()

        XCTAssertEqual(result, .missingDemucs)
        XCTAssertEqual(result.message, "Demucs is not installed. Install or configure Demucs before rendering boosted-drums tracks.")
    }

    func testReturnsReadyWhenDemucsCommandExists() async {
        let preflight = RenderPreflight(commandResolver: { command in "/opt/homebrew/bin/\(command)" })

        let result = await preflight.check()

        XCTAssertEqual(result, .ready(demucsPath: "/opt/homebrew/bin/demucs"))
    }

    func testResolveCommandPrefersProjectLocalVirtualEnvironment() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let binDirectory = projectRoot
            .appendingPathComponent(".venv", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let demucsURL = binDirectory.appendingPathComponent("demucs")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: demucsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: demucsURL.path)
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
        }

        let resolved = RenderPreflight.resolveCommand(
            "demucs",
            projectRoot: projectRoot,
            pathResolver: { _ in nil }
        )

        XCTAssertEqual(resolved, demucsURL.path)
    }

    func testResolveCommandFallsBackToStandardToolDirectoryWhenPathIsLimited() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ffmpegURL = toolDirectory.appendingPathComponent("ffmpeg")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: ffmpegURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpegURL.path)
        defer {
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: toolDirectory)
        }

        let resolved = RenderPreflight.resolveCommand(
            "ffmpeg",
            projectRoot: projectRoot,
            pathResolver: { _ in nil },
            standardSearchDirectories: [toolDirectory]
        )

        XCTAssertEqual(resolved, ffmpegURL.path)
    }

    func testResolveCommandPrefersExecutableOverrideOverAllProbes() throws {
        let toolDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let overrideURL = toolDirectory.appendingPathComponent("demucs-custom")
        try FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: overrideURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: overrideURL.path)
        defer {
            try? FileManager.default.removeItem(at: toolDirectory)
        }

        let resolved = RenderPreflight.resolveCommand(
            "demucs",
            projectRoot: URL(fileURLWithPath: "/nonexistent"),
            pathResolver: { _ in "/should/not/win/demucs" },
            standardSearchDirectories: [],
            overridePath: overrideURL.path
        )

        XCTAssertEqual(resolved, overrideURL.path)
    }

    func testResolveCommandIgnoresStaleOverrideAndFallsThrough() {
        let resolved = RenderPreflight.resolveCommand(
            "demucs",
            projectRoot: URL(fileURLWithPath: "/nonexistent"),
            pathResolver: { _ in "/from/path/demucs" },
            standardSearchDirectories: [],
            overridePath: "/nonexistent/override/demucs"
        )

        XCTAssertEqual(resolved, "/from/path/demucs")
    }

    func testResolveCommandProbesManagedToolsDirectoryBeforeVenv() throws {
        let managedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let managedURL = managedDirectory.appendingPathComponent("demucs")
        try FileManager.default.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: managedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedURL.path)
        defer {
            try? FileManager.default.removeItem(at: managedDirectory)
        }

        let resolved = RenderPreflight.resolveCommand(
            "demucs",
            projectRoot: URL(fileURLWithPath: "/nonexistent"),
            pathResolver: { _ in nil },
            standardSearchDirectories: [],
            managedToolsDirectory: managedDirectory
        )

        XCTAssertEqual(resolved, managedURL.path)
    }

    func testResolveCommandFallsBackToLoginShellResolver() {
        let resolved = RenderPreflight.resolveCommand(
            "demucs",
            projectRoot: URL(fileURLWithPath: "/nonexistent"),
            pathResolver: { _ in nil },
            standardSearchDirectories: [],
            loginShellResolver: { _ in "/from/login/shell/demucs" }
        )

        XCTAssertEqual(resolved, "/from/login/shell/demucs")
    }

    func testAugmentedPATHValueDeduplicatesAndPreservesOrder() {
        let path = RenderPreflight.augmentedPATHValue(
            directories: ["/tools/bin", "/opt/homebrew/bin", "/tools/bin"],
            existingPATH: "/usr/bin:/opt/homebrew/bin:/bin"
        )

        XCTAssertEqual(path, "/tools/bin:/opt/homebrew/bin:/usr/bin:/bin")
    }

    func testAugmentedPATHValueHandlesMissingExistingPATH() {
        let path = RenderPreflight.augmentedPATHValue(
            directories: ["/tools/bin", ""],
            existingPATH: nil
        )

        XCTAssertEqual(path, "/tools/bin")
    }

    func testSubprocessEnvironmentPutsToolDirectoriesOnPATH() {
        let environment = RenderPreflight.subprocessEnvironment(executablePath: "/custom/venv/bin/demucs")

        let path = environment["PATH"] ?? ""
        let entries = path.components(separatedBy: ":")
        XCTAssertEqual(entries.first, "/custom/venv/bin")
        XCTAssertTrue(entries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(entries.contains(RenderPreflight.managedToolsBinDirectory.path))
    }

    func testLoginShellResolverRejectsUnsafeCommandNames() {
        XCTAssertNil(RenderPreflight.resolveLoginShellCommand("demucs; rm -rf /"))
        XCTAssertNil(RenderPreflight.resolveLoginShellCommand("$(whoami)"))
    }

    func testMemoizedResolveCommandProbesOnceForSuccessfulResolution() {
        let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        var callCount = 0

        let first = RenderPreflight.memoizedResolveCommand("demucs", cache: cache) { _ in
            callCount += 1
            return "/opt/homebrew/bin/demucs"
        }
        let second = RenderPreflight.memoizedResolveCommand("demucs", cache: cache) { _ in
            callCount += 1
            return "/opt/homebrew/bin/demucs"
        }

        XCTAssertEqual(first, "/opt/homebrew/bin/demucs")
        XCTAssertEqual(second, "/opt/homebrew/bin/demucs")
        XCTAssertEqual(callCount, 1)
    }

    func testMemoizedResolveCommandDoesNotCacheFailedResolution() {
        let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        var callCount = 0
        var resolvedPath: String?
        let resolve: (String) -> String? = { _ in
            callCount += 1
            return resolvedPath
        }

        XCTAssertNil(RenderPreflight.memoizedResolveCommand("demucs", cache: cache, resolve: resolve))
        XCTAssertNil(RenderPreflight.memoizedResolveCommand("demucs", cache: cache, resolve: resolve))
        XCTAssertEqual(callCount, 2)

        resolvedPath = "/opt/homebrew/bin/demucs"
        XCTAssertEqual(
            RenderPreflight.memoizedResolveCommand("demucs", cache: cache, resolve: resolve),
            "/opt/homebrew/bin/demucs"
        )
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(
            RenderPreflight.memoizedResolveCommand("demucs", cache: cache, resolve: resolve),
            "/opt/homebrew/bin/demucs"
        )
        XCTAssertEqual(callCount, 3)
    }
}
