import Foundation

public struct ManagedAudioLibrary: Sendable {
    public let sourceDirectory: URL

    public init(sourceDirectory: URL = BackbeatFileLocations.managedSourceDirectory) {
        self.sourceDirectory = sourceDirectory
    }

    public func storeSourceFile(_ sourceURL: URL) throws -> URL {
        let trackDirectory = sourceDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: trackDirectory, withIntermediateDirectories: true)

        let destinationURL = trackDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}
