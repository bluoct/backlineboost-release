import Foundation

public enum RenderBitrate: Int, CaseIterable, Codable, Sendable, Identifiable {
    case kbps128 = 128
    case kbps192 = 192
    case kbps256 = 256
    case kbps320 = 320

    public static let `default`: RenderBitrate = .kbps256

    public var id: Int { rawValue }

    /// Bits per second for the native AAC encoder (`AVEncoderBitRateKey`).
    public var encoderBitRate: Int { rawValue * 1_000 }

    public var displayLabel: String { "\(rawValue) kbps" }
}

/// Machine-local render preferences. Stored in UserDefaults, not library.json:
/// the renders folder is an absolute per-machine path that must not travel
/// with the library document, and bitrate has to be readable synchronously at
/// render time, off the store's debounced save path.
public enum RenderSettings {
    static let rendersFolderDefaultsKey = "BackbeatRenderSettings.rendersFolderPath"
    static let bitrateDefaultsKey = "BackbeatRenderSettings.bitrateKbps"

    public static func bitrate(defaults: UserDefaults = .standard) -> RenderBitrate {
        RenderBitrate(rawValue: defaults.integer(forKey: bitrateDefaultsKey)) ?? .default
    }

    public static func setBitrate(_ bitrate: RenderBitrate, defaults: UserDefaults = .standard) {
        defaults.set(bitrate.rawValue, forKey: bitrateDefaultsKey)
    }

    public static func configuredRendersFolder(defaults: UserDefaults = .standard) -> URL? {
        guard
            let path = defaults.string(forKey: rendersFolderDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// nil clears the override (Reset to Default). Future sandboxing: swap the
    /// stored path for security-scoped bookmark data — every read/write already
    /// funnels through this accessor pair.
    public static func setConfiguredRendersFolder(_ url: URL?, defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.path, forKey: rendersFolderDefaultsKey)
        } else {
            defaults.removeObject(forKey: rendersFolderDefaultsKey)
        }
    }

    /// The folder renders write to right now. Never fails: an unusable
    /// configured folder degrades to the app-managed default so a render can
    /// never break because of a settings problem.
    public static func effectiveRendersRootURL(defaults: UserDefaults = .standard) -> URL {
        effectiveRendersRootURL(
            configured: configuredRendersFolder(defaults: defaults),
            defaultURL: BackbeatFileLocations.renderRootDirectory
        )
    }

    static func effectiveRendersRootURL(
        configured: URL?,
        defaultURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        guard let configured else { return defaultURL }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: configured.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue, fileManager.isWritableFile(atPath: configured.path) {
                return configured
            }
            print("Backbeat: configured renders folder is not a writable directory; using the default location. (\(configured.path))")
            return defaultURL
        }

        do {
            try fileManager.createDirectory(at: configured, withIntermediateDirectories: true)
            return configured
        } catch {
            print("Backbeat: configured renders folder could not be created; using the default location. (\(configured.path))")
            return defaultURL
        }
    }
}
