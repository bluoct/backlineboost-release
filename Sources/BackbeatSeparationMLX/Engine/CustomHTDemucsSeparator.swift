import BackbeatCore
import Foundation
import MLX

/// The custom engine's `StemSeparating` conformance (charter Phase 3, D1-A):
/// full-track separation through the purpose-written stack —
/// `SeparationInputLoader` (Phase 1) → `HTDemucsScheduler` (the upstream
/// demucs 4.0.1 `apply_model`/`separate.py` semantics, written from the Python
/// reference — G6) → batched `CustomHTDemucsPipeline` windows (Phase 2 graph)
/// → `HTDemucsOverlapAdd` → `SeparatedStems`.
///
/// This is the app's shipping engine (Phase 5 cut-over: it superseded the
/// vendored port's `MLXStemSeparator`, which was deleted with the port);
/// `BackbeatSepBench --engine custom` drives it for benches.
///
/// Confinement (§2.2 / amendment A3): MLX arrays and the built pipeline never
/// leave this actor; only `[Float]` crosses the seam.
///
/// Efficiency (charter requirements): the overlap-add accumulates directly into
/// the eight per-(stem, channel) track buffers that BECOME the returned
/// `SeparatedStems` (zero-copy hand-off — the review's P1 double-copy shape is
/// structurally impossible); windows move by bulk `memcpy`/vDSP only; the MLX
/// buffer cache is bounded by physical memory (D5) and released before the
/// stems take their final form.
///
/// Cancellation (G4, review R8): cooperative checkpoints before/after every
/// GPU batch AND between the conversion/build phases, so cancel latency is
/// bounded by one batch — one SEGMENT at the default batch size of 1 — during
/// inference, and one conversion phase during the first-run build. The model
/// build is single-flight (review R9): a reentrant caller waits for the
/// in-flight build instead of double-building.
public actor CustomHTDemucsSeparator: StemSeparating {
    private let weightsURL: URL
    private let cacheDirectory: URL
    private let batchSize: Int
    private let overlap: Double
    private let gpuCacheLimitBytes: Int

    /// Built once on first `separate` and reused across the serial render jobs.
    private var pipeline: CustomHTDemucsPipeline?
    private var buildInProgress = false
    private var buildWaiters: [CheckedContinuation<Void, Never>] = []

    /// Release the MLX GPU buffer cache (gate G3, "memory after"). Static so
    /// `BackbeatSepBench` can probe post-completion RSS without importing MLX.
    public static func releaseGPUMemory() {
        MLX.Memory.clearCache()
    }

    /// `batchSize` defaults to 1 — a recorded Phase 3 measurement, not an
    /// oversight: on the M5 Pro the compensated-GEMM graph already saturates
    /// the GPU per window, so batch 4 (the vendored engine's default) was
    /// MEASURED slower (10.33 s vs 9.81 s on the 105 s fixture), +100 MB peak
    /// RSS, and 4× the cancel latency. The knob stays for A/B and Phase 6
    /// re-evaluation; SI-SDR is bit-identical across batch sizes.
    public init(
        weightsURL: URL? = nil,
        cacheDirectory: URL? = nil,
        modelsDirectory: URL = BackbeatFileLocations.modelsDirectory,
        batchSize: Int = 1,
        overlap: Double = HTDemucsScheduler.defaultOverlap
    ) {
        // Weights resolution: explicit override → BACKBEAT_WEIGHTS (dev/bench —
        // the parity harness and BackbeatSepBench set it; the CLI executables
        // have no bundled resource) → the checkpoint bundled in the app.
        self.weightsURL = weightsURL
            ?? ProcessInfo.processInfo.environment["BACKBEAT_WEIGHTS"].map { URL(fileURLWithPath: $0) }
            ?? WeightsIdentity.htdemucs.bundledURL()
        // The v3 (custom-layout) conversion cache — the only schema since the
        // Phase 5 cut-over (writes serialized by the conversion actor gate).
        self.cacheDirectory = cacheDirectory
            ?? HTDemucsConversion.customEngineCacheDirectory(inModelsDirectory: modelsDirectory)
        self.batchSize = max(1, batchSize)
        self.overlap = overlap
        // Pin the exact-fp32 GEMM substrate before any MLX dispatch can latch
        // the default (see CustomHTDemucsSubstrate; the pipeline build re-pins
        // and canary-verifies).
        CustomHTDemucsSubstrate.pinExactFP32()
        // D5: bound the MLX buffer cache, scaled to physical memory, capped.
        // BACKBEAT_MLX_CACHE_MB is the Phase 6 A/B knob for the cap.
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        if let override = ProcessInfo.processInfo.environment["BACKBEAT_MLX_CACHE_MB"]
            .flatMap(Int.init), override > 0 {
            self.gpuCacheLimitBytes = override << 20
        } else {
            self.gpuCacheLimitBytes = min(2 << 30, max(512 << 20, physical / 16))
        }
    }

    public func separate(
        source: URL,
        progress: StemSeparationProgress?
    ) async throws -> SeparatedStems {
        try Task.checkCancellation()
        MLX.Memory.cacheLimit = gpuCacheLimitBytes
        defer { MLX.Memory.clearCache() }

        let pipeline = try await ensurePipeline()
        try Task.checkCancellation()

        // Phase 6 dev-only stage profile (`BACKBEAT_PROFILE_STAGES=1`):
        // cumulative per-stage seconds + footprint milestones, to stderr.
        let profiling = ProcessInfo.processInfo.environment["BACKBEAT_PROFILE_STAGES"] == "1"
        var stageTotals: [String: Double] = [:]
        var stageOrder: [String] = []
        let clock = ContinuousClock()
        func addStage(_ stage: String, _ seconds: Double) {
            if stageTotals[stage] == nil { stageOrder.append(stage) }
            stageTotals[stage, default: 0] += seconds
        }
        func timedStage<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
            guard profiling else { return try body() }
            let start = clock.now
            let result = try body()
            let elapsed = clock.now - start
            addStage(
                stage,
                Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            return result
        }
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return Double(info.phys_footprint) / (1024 * 1024)
        }
        var footprints: [(String, Double)] = []
        pipeline.profileSink = profiling ? { addStage($0, $1) } : nil
        defer { pipeline.profileSink = nil }

        // Decode + channel layout + anti-aliased SRC (the Phase 1 loader —
        // review findings R1/R2/D2 fixed by construction, never ported). The
        // scoped `do` releases the loader's copy so the normalized channels are
        // the ONLY full-track input buffers alive (no retained dead input — P1).
        var channels: [[Float]]
        let sampleRate: Double
        do {
            let input = try timedStage("input-load") { try SeparationInputLoader().load(url: source) }
            channels = input.channels
            sampleRate = input.sampleRate
        }
        try Task.checkCancellation()
        if profiling { footprints.append(("post-load", footprintMB())) }

        // Track-level normalization (`separate.py`): measure the mono-mean
        // scalars, normalize in place; `finalize` denormalizes with the same
        // scalars after the weight division.
        let trackLength = channels[0].count
        let normalization = HTDemucsTrackNormalization.measure(channels)
        normalization.normalize(&channels)

        // The batched segment loop: uniform training-length windows (the
        // centered-padding pin) → one GPU batch per `batchSize` windows →
        // trim + transition-weight accumulate. Cancellation is checked at
        // every batch boundary; progress is per completed segment.
        let chunks = try HTDemucsScheduler.plan(trackLength: trackLength, overlap: overlap)
        var accumulator = HTDemucsOverlapAdd(
            trackLength: trackLength,
            sources: CustomHTDemucs.sources,
            channels: channels.count)
        var completed = 0
        // Sequential segment loop. Phase 6 note (recorded measurement,
        // 2026-07-07): an asyncEval double-buffer variant — post-process batch
        // N−1 on the CPU while the GPU crunches batch N — was prototyped and
        // MEASURED SLOWER (105 s fixture: 3.23 s vs 2.80 s median). On unified
        // memory the CPU post-processing pass competes with the saturated GPU
        // for bandwidth, costing the GPU more than the hidden CPU time saves.
        var loopFootprintMax = 0.0
        while completed < chunks.count {
            try Task.checkCancellation()
            let batch = chunks[completed ..< min(completed + batchSize, chunks.count)]
            let flat = timedStage("extract") { Self.extractWindows(batch, channels: channels) }
            // Accumulate each window straight from the zero-copy view of the
            // GPU output — no intermediate [Float] per window.
            try pipeline.separateWindows(
                flat: flat, windowCount: batch.count, channels: channels.count,
                sampleLength: HTDemucsScheduler.segmentLength
            ) { index, combined in
                accumulator.add(
                    chunk: batch[batch.startIndex + index], batchStems: combined, window: 0)
            }
            completed += batch.count
            progress?(Double(completed) / Double(chunks.count))
            if profiling { loopFootprintMax = max(loopFootprintMax, footprintMB()) }
        }
        try Task.checkCancellation()
        if profiling { footprints.append(("loop-max", loopFootprintMax)) }

        // The last window has been extracted — drop the normalized full-track
        // input NOW so it never coexists with the finalized stems (P1's shape:
        // no retained dead input).
        channels = []

        // Release the GPU cache BEFORE the stems take their final form, so the
        // cache never coexists with the finished CPU stem set (P1's aggravator).
        MLX.Memory.clearCache()
        if profiling { footprints.append(("pre-finalize", footprintMB())) }
        let stems = timedStage("finalize") { accumulator.finalize(denormalizingWith: normalization) }
        if profiling {
            footprints.append(("post-finalize", footprintMB()))
            var report = "[custom][profile]"
            for stage in stageOrder {
                report += " \(stage)=\(String(format: "%.3f", stageTotals[stage] ?? 0))s"
            }
            for (name, mb) in footprints {
                report += " \(name)=\(String(format: "%.0f", mb))MB"
            }
            FileHandle.standardError.write(Data((report + "\n").utf8))
        }
        return SeparatedStems(
            sampleRate: sampleRate,
            drums: stems[0], bass: stems[1], other: stems[2], vocals: stems[3])
    }

    // MARK: - Window extraction

    /// Materialize a batch of scheduled model windows as ONE flat
    /// `[window][channel][sample]` staging buffer — `padLeft` zeros + the
    /// real-audio span + `padRight` zeros per channel, one bulk copy each (the
    /// buffer is zero-initialized, so only the audio spans are written). The
    /// pipeline uploads this buffer directly.
    private static func extractWindows(
        _ batch: ArraySlice<HTDemucsScheduler.Chunk>, channels: [[Float]]
    ) -> [Float] {
        let segment = HTDemucsScheduler.segmentLength
        var flat = [Float](repeating: 0, count: batch.count * channels.count * segment)
        flat.withUnsafeMutableBufferPointer { destination in
            for (windowIndex, chunk) in batch.enumerated() {
                for (channelIndex, channel) in channels.enumerated() {
                    channel.withUnsafeBufferPointer { source in
                        let base = (windowIndex * channels.count + channelIndex) * segment
                        (destination.baseAddress! + base + chunk.padLeft).update(
                            from: source.baseAddress! + chunk.sourceStart,
                            count: chunk.sourceEnd - chunk.sourceStart)
                    }
                }
            }
        }
        return flat
    }

    // MARK: - Model construction (single-flight, cancellable)

    /// Build the pipeline once: v3 conversion (idempotent, actor-gated, with
    /// cooperative checkpoints between its phases — R8) → weight load → graph
    /// build. Single-flight by construction (R9): the build runs in the FIRST
    /// caller's task (so its cancellation propagates structurally through the
    /// checkpoints), and any reentrant caller parks on a continuation, then
    /// re-reads the state — taking over the build itself if the first caller
    /// failed or was cancelled.
    private func ensurePipeline() async throws -> CustomHTDemucsPipeline {
        while true {
            if let pipeline { return pipeline }
            if buildInProgress {
                await withCheckedContinuation { buildWaiters.append($0) }
                continue
            }
            buildInProgress = true
            defer {
                buildInProgress = false
                let waiters = buildWaiters
                buildWaiters = []
                for waiter in waiters { waiter.resume() }
            }

            let clock = ContinuousClock()
            let start = clock.now
            try await HTDemucsConversion.ensureCustomEngineConverted(
                weightsURL: weightsURL, cacheDirectory: cacheDirectory)
            try Task.checkCancellation()
            let weights = try MLX.loadArrays(
                url: cacheDirectory.appendingPathComponent("htdemucs.safetensors"))
            try Task.checkCancellation()
            let built = try CustomHTDemucsPipeline(model: try CustomHTDemucs(weights: weights))
            pipeline = built

            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            FileHandle.standardError.write(Data(
                "[custom] model_load_s=\(String(format: "%.2f", seconds))\n".utf8))
            return built
        }
    }
}
