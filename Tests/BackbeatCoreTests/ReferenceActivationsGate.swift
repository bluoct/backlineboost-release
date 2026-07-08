import XCTest
import BackbeatParityKit

/// XCTest-side gate for the Phase 0 reference activations (the kit itself must not
/// depend on XCTest). Mirrors the `TorchCheckpointReaderParityTests` convention:
/// unset env → the test SKIPS (the default suite stays artifact-free); set-but-broken
/// → hard failure with the regeneration hint.
extension ReferenceActivations {
    static func loadOrSkip() throws -> ReferenceActivations {
        guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty else {
            throw XCTSkip("""
                Set \(environmentKey) to the reference-activations directory \
                (.build/reference-activations/htdemucs-v1) to run the gated DSP parity tests.
                """)
        }
        return try load(directory: URL(fileURLWithPath: path))
    }
}
