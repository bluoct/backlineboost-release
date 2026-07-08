import Accelerate
import BackbeatCore
import BackbeatParityKit
import BackbeatSeparationMLX
import Foundation
import MLX

// BackbeatLayerParity — custom-engine Phase 2 layer-parity harness (charter
// gate 2). Dev-only CLI beside BackbeatSepBench: it needs MLX + the reference
// activations + the htdemucs checkpoint, so it lives outside the test target
// (architecture §2.4 — the default `swift test` stays MLX/weights-free at
// runtime).
//
// It feeds the Phase 0 contract input (`input.npy` — the saved samples ARE the
// contract) through Phase 1's `HTDemucsDSP` into the custom `CustomHTDemucs`
// graph, taps every block, and compares each against its same-named reference
// activation (demucs 4.0.1 `named_modules()` names; SHA-256-verified via the
// manifest before use). Exit 0 iff every one of the 63 contract entries is
// covered and inside its gate.
//
//   swift run BackbeatLayerParity [--activations <dir>] [--weights <path>]
//                                 [--cache <dir>] [--block <prefix>]
//
// Defaults: $BACKBEAT_REFERENCE_ACTIVATIONS or .build/reference-activations/
// htdemucs-v1; $BACKBEAT_WEIGHTS or the machine-local weights cache the build
// script populates (same resolution as BackbeatSepBench); conversion cache
// under .build/custom-engine-cache. `--block` filters the report to a name
// prefix — every block is still computed and enforced.

struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Per-block tolerance gates (stated up front — charter Phase 2)
//
// CPU-fp32 torch vs GPU-fp32 MLX means reduction-order noise, so the bar is a
// max-abs-difference gate per block, not bit-exactness. Drift beyond a gate is
// investigated, never silently loosened (Phase 1 rule). Achieved values are
// recorded in docs/status.md at the checkpoint.
//
//   _magnitude                                    exact (pure permute)
//   _spec                                         1e-4 (Phase 1 DSP self-check)
//   encoders/tencoders (+ .dconv), freq_emb,
//   channel_upsampler[_t]                         1e-4
//   crosstransformer.*, channel_downsampler[_t],
//   decoder/tdecoder (.out0/.out1/.dconv)         5e-4  (pre-denormalization)
//   _mask                                         2e-3  (denormalized spectral out)
//   _ispec, output                                1e-3

func gate(for name: String) -> Float {
    if name == "_magnitude" { return 0 }
    if name == "_mask" { return 2e-3 }
    if name == "_ispec" || name == "output" { return 1e-3 }
    if name.hasPrefix("crosstransformer") || name.hasPrefix("channel_downsampler")
        || name.hasPrefix("decoder") || name.hasPrefix("tdecoder") {
        return 5e-4
    }
    return 1e-4
}

// MARK: - Options

struct Options {
    var activationsDirectory: URL
    var weightsURL: URL
    var cacheDirectory: URL
    var blockFilter: String?

    static func parse(_ arguments: [String]) throws -> Options {
        var activations = ProcessInfo.processInfo.environment[ReferenceActivations.environmentKey]
            ?? ".build/reference-activations/htdemucs-v1"
        var weights: String? = ProcessInfo.processInfo.environment["BACKBEAT_WEIGHTS"]
        var cache = ".build/custom-engine-cache"
        var blockFilter: String?

        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else {
                throw HarnessFailure(description: "\(flag) needs a value")
            }
            let value = arguments[index + 1]
            switch flag {
            case "--activations": activations = value
            case "--weights": weights = value
            case "--cache": cache = value
            case "--block": blockFilter = value
            default: throw HarnessFailure(description: "unknown option \(flag)")
            }
            index += 2
        }

        // Same resolution as BackbeatSepBench: explicit override, else the
        // machine-local cache script/build_and_run.sh populates and verifies.
        let weightsURL: URL
        if let weights, !weights.isEmpty {
            weightsURL = URL(fileURLWithPath: weights)
        } else {
            weightsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches/backline-boost/weights/\(WeightsIdentity.htdemucs.filename)")
        }
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw HarnessFailure(description: """
                htdemucs weights not found at \(weightsURL.path). Build the app once \
                (./script/build_and_run.sh populates the cache) or set BACKBEAT_WEIGHTS.
                """)
        }
        return Options(
            activationsDirectory: URL(fileURLWithPath: activations),
            weightsURL: weightsURL,
            cacheDirectory: URL(fileURLWithPath: cache)
                .appendingPathComponent(HTDemucsConversion.customEngineCacheSubdirectoryName),
            blockFilter: blockFilter)
    }
}

// MARK: - Comparison

struct Verdict {
    let name: String
    let maxAbsDiff: Float
    let relativeL2: Float
    let gate: Float
    var passed: Bool {
        gate == 0 ? maxAbsDiff == 0 : maxAbsDiff <= gate
    }
}

func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count)
    var diff = [Float](repeating: 0, count: a.count)
    vDSP.subtract(a, b, result: &diff)
    return vDSP.maximumMagnitude(diff)
}

func relativeL2(_ got: [Float], reference: [Float]) -> Float {
    var diff = [Float](repeating: 0, count: got.count)
    vDSP.subtract(got, reference, result: &diff)
    let referenceNorm = vDSP.sumOfSquares(reference).squareRoot()
    guard referenceNorm > 0 else { return 0 }
    return vDSP.sumOfSquares(diff).squareRoot() / referenceNorm
}

final class ParityReport {
    private(set) var verdicts: [Verdict] = []
    private(set) var errors: [String] = []
    let references: ReferenceActivations
    let blockFilter: String?

    init(references: ReferenceActivations, blockFilter: String?) {
        self.references = references
        self.blockFilter = blockFilter
    }

    /// Compare `values` (torch-layout flat floats) against the same-named
    /// reference entry; record and print the verdict.
    func compare(_ name: String, shape: [Int], values: [Float]) {
        do {
            let reference = try references.tensor(name)
            guard reference.shape == shape else {
                throw HarnessFailure(
                    description: "'\(name)' produced shape \(shape), reference is \(reference.shape)")
            }
            let verdict = Verdict(
                name: name,
                maxAbsDiff: maxAbsDifference(values, reference.data),
                relativeL2: relativeL2(values, reference: reference.data),
                gate: gate(for: name))
            verdicts.append(verdict)
            if blockFilter == nil || name.hasPrefix(blockFilter!) {
                let status = verdict.passed ? "PASS" : "FAIL"
                let paddedName = name.padding(toLength: max(name.count, 32), withPad: " ", startingAt: 0)
                print(String(
                    format: "%@ %@ max|Δ|=%.3e relL2=%.3e (gate %.0e)",
                    status, paddedName, verdict.maxAbsDiff, verdict.relativeL2, verdict.gate))
            }
        } catch {
            errors.append("\(name): \(error)")
            print("FAIL \(name) — \(error)")
        }
    }

    func compare(_ name: String, tensor: MLXArray) {
        compare(name, shape: tensor.shape, values: tensor.asArray(Float.self))
    }
}

// MARK: - Run

let startedAt = Date()
do {
    let options = try Options.parse(CommandLine.arguments)
    let references = try ReferenceActivations.load(directory: options.activationsDirectory)
    let report = ParityReport(references: references, blockFilter: options.blockFilter)

    // 1. Convert the checkpoint through the real schema-v3 path (idempotent,
    //    actor-gated), then build the graph from the cache.
    print("weights: \(options.weightsURL.path)")
    print("cache:   \(options.cacheDirectory.path)")
    try await HTDemucsConversion.ensureCustomEngineConverted(
        weightsURL: options.weightsURL, cacheDirectory: options.cacheDirectory)
    let converted = try MLX.loadArrays(
        url: options.cacheDirectory.appendingPathComponent("htdemucs.safetensors"))
    let model = try CustomHTDemucs(weights: converted)
    print("graph built: \(converted.count) tensors consumed\n")

    // 2. The contract input → Phase 1 DSP. `_spec`/`_magnitude` re-verify the
    //    (already Phase-1-proven) DSP as a harness self-check.
    let input = try references.tensor("input")  // [1, C, L]
    guard input.shape.count == 3, input.shape[0] == 1 else {
        throw HarnessFailure(description: "input.npy must be [1, C, L], got \(input.shape)")
    }
    let (channelCount, sampleLength) = (input.shape[1], input.shape[2])
    let inputChannels = (0..<channelCount).map {
        Array(input.data[($0 * sampleLength)..<(($0 + 1) * sampleLength)])
    }
    let z = try HTDemucsDSP.spectrogram(inputChannels)
    report.compare("_spec", shape: [1, z.channels, z.bins, z.frames, 2], values: z.data)
    // The pack direction is pinned EXACTLY against the reference `_spec` (the
    // Phase 1 convention), and the graph is fed the reference `_magnitude`
    // itself — per-block graph parity is then isolated from DSP fp-noise,
    // which the `_spec` self-check above already bounds.
    let referenceSpec = try references.tensor("_spec")
    let packed = HTDemucsDSP.packCaC(.init(
        channels: referenceSpec.shape[1], bins: referenceSpec.shape[2],
        frames: referenceSpec.shape[3], data: referenceSpec.data))
    report.compare("_magnitude", shape: [1, 2 * z.channels, z.bins, z.frames], values: packed)

    // 3.+4. The graph + output seam, through the PRODUCTION window pipeline
    //    (Phase 3): `CustomHTDemucsPipeline` runs forward with every module
    //    tapped, then the mask → unpackCaC (`_mask`) → iSTFT (`_ispec`) →
    //    + time branch (`output`) composition — the same code path the
    //    `CustomHTDemucsSeparator` segment loop executes.
    let sources = CustomHTDemucs.sources
    let pipeline = try CustomHTDemucsPipeline(model: model)
    let combined = try pipeline.separateWindow(
        packedMagnitude: packed, frames: z.frames,
        waveform: input.data, sampleLength: sampleLength,
        graphTap: { name, tensor in report.compare(name, tensor: tensor) },
        seamTap: { name, shape, values in report.compare(name, shape: shape, values: values) })
    report.compare(
        "output", shape: [1, sources, channelCount, sampleLength], values: combined)

    // 4b. Phase 6 full-production check: the segment loop ships the
    //     MLX-compiled GPU-spectrogram + forward + GPU epilogue, which the
    //     tapped eager path above cannot exercise (taps cannot cross a compile
    //     boundary) — run the contract input waveform through the ACTUAL
    //     production path end to end and hold its final output to the same
    //     `output` gate. This is the 63rd comparison; it reuses the `output`
    //     reference entry.
    let productionCombined = try pipeline.productionWindow(
        waveform: input.data, sampleLength: sampleLength)
    report.compare(
        "output", shape: [1, sources, channelCount, sampleLength], values: productionCombined)

    // 5. Coverage: every manifest entry must have been compared (`input` is
    //    consumed as the contract input, not compared).
    let compared = Set(report.verdicts.map(\.name) + ["input"])
    let missing = references.activationNames.filter { !compared.contains($0) }.sorted()

    let failed = report.verdicts.filter { !$0.passed }
    let elapsed = Date().timeIntervalSince(startedAt)
    print("\n\(report.verdicts.count) blocks compared in \(String(format: "%.1f", elapsed))s")
    if !missing.isEmpty {
        print("FAIL — \(missing.count) contract entries never compared: \(missing.joined(separator: ", "))")
    }
    if !report.errors.isEmpty {
        print("FAIL — \(report.errors.count) comparison errors")
    }
    if !failed.isEmpty {
        let worst = failed.max { $0.maxAbsDiff / max($0.gate, 1e-9) < $1.maxAbsDiff / max($1.gate, 1e-9) }!
        print("FAIL — \(failed.count) blocks over gate; worst: \(worst.name) max|Δ|=\(worst.maxAbsDiff) (gate \(worst.gate))")
    }
    if failed.isEmpty && missing.isEmpty && report.errors.isEmpty {
        let worst = report.verdicts.max { $0.maxAbsDiff < $1.maxAbsDiff }!
        print("PASS — all \(report.verdicts.count) blocks inside their gates (worst max|Δ|=\(worst.maxAbsDiff) at \(worst.name))")
        exit(0)
    }
    exit(1)
} catch {
    FileHandle.standardError.write(Data("BackbeatLayerParity: \(error)\n".utf8))
    exit(2)
}
