import Foundation
import Accelerate

/// Errors thrown by the pure `HTDemucsDSP` functions. Conforms to `LocalizedError`
/// from day one: these errors eventually surface through the render-failed banner,
/// which renders `errorDescription` (review finding R4 — an error type without it
/// degrades to a useless generic message).
public enum HTDemucsDSPError: Error, LocalizedError, Equatable {
    case emptyInput
    case mismatchedChannelLengths
    case invalidShape(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Stem separation received audio with no samples."
        case .mismatchedChannelLengths:
            return "Stem separation received audio channels of different lengths."
        case .invalidShape(let detail):
            return "Stem separation received data with an unexpected shape (\(detail))."
        }
    }
}

/// The spectral substrate of the custom HTDemucs engine (charter Phase 1): the exact
/// `_spec` / `_ispec` / `_magnitude` / `_mask` transforms of upstream demucs 4.0.1
/// `HTDemucs`, as pure functions on `[Float]` buffers. Pinned to the model constants
/// recorded in the Phase 0 reference manifest (nfft 4096, hop 1024 = nfft/4) and
/// verified against the per-block PyTorch reference activations by the env-gated
/// `HTDemucsDSPParityTests`.
///
/// Numeric contract (must not drift — the model graph in Phase 2 assumes it):
/// - `spectrogram` = demucs `_spec`: outer reflect pad `(1536, 1536 + le·hop − len)`
///   with the upstream `pad1d` zero-extend fallback for tiny inputs, then an STFT with
///   a periodic Hann window (4096), hop 1024, `center=true` (reflect), `normalized=true`
///   (ortho, 1/√nfft), onesided; the Nyquist bin is dropped (2049 → 2048) and the
///   frame axis is center-trimmed to `[2, 2 + le)` where `le = ceil(len / hop)`.
/// - `inverseSpectrogram` = demucs `_ispec`: re-append a zero Nyquist bin, zero-pad
///   two frames on each side of the time axis, `torch.istft`-equivalent overlap-add
///   with window-envelope normalization, then trim `[1536, 1536 + length)`.
/// - `packCaC` / `unpackCaC` = the cac=true `_magnitude` / `_mask`: complex-as-channels,
///   real/imag planes interleaved into the channel axis (`c0.re, c0.im, c1.re, c1.im`).
///
/// Complex data is stored interleaved with a trailing `[re, im]` pair — the layout of
/// `torch.view_as_real`, byte-compatible with the reference `.npy` tensors.
public enum HTDemucsDSP {
    /// FFT size of the htdemucs spectral branch (`nfft` in the reference manifest).
    public static let nfft = 4096
    /// STFT hop (`hop_length` in the reference manifest); the contract fixes it at nfft/4.
    public static let hopLength = nfft / 4
    /// Frequency bins per frame after the Nyquist drop.
    public static let bins = nfft / 2
    /// The `_spec`/`_ispec` outer padding: `hop_length // 2 * 3`.
    static let outerPad = hopLength / 2 * 3

    /// A complex spectrogram stored row-major as `[channels][bins][frames][2]`
    /// (trailing dim = interleaved re/im, i.e. `torch.view_as_real` layout).
    public struct ComplexSpectrogram: Sendable, Equatable {
        public let channels: Int
        public let bins: Int
        public let frames: Int
        public let data: [Float]

        public init(channels: Int, bins: Int, frames: Int, data: [Float]) {
            precondition(data.count == channels * bins * frames * 2, "data count must be channels·bins·frames·2")
            self.channels = channels
            self.bins = bins
            self.frames = frames
            self.data = data
        }
    }

    // MARK: - spec (demucs `_spec`)

    /// Computes the htdemucs spectrogram of channel-major audio. All channels must be
    /// the same nonzero length. Output: `bins = 2048`, `frames = ceil(len / hop)`.
    public static func spectrogram(_ channels: [[Float]]) throws -> ComplexSpectrogram {
        guard !channels.isEmpty, let length = channels.first?.count, length > 0 else {
            throw HTDemucsDSPError.emptyInput
        }
        guard channels.allSatisfy({ $0.count == length }) else {
            throw HTDemucsDSPError.mismatchedChannelLengths
        }

        let hop = hopLength
        let le = (length + hop - 1) / hop
        let half = nfft / 2

        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nfft), .FORWARD) else {
            throw HTDemucsDSPError.invalidShape("DFT setup failed for nfft \(nfft)")
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        let window = periodicHannWindow(nfft)
        // Forward scale: vDSP's real DFT is 2× the mathematical DFT, and
        // torch.stft(normalized=true) divides by √nfft → one uniform 1/(2·√nfft).
        var forwardScale = Float(1.0 / (2.0 * Double(nfft).squareRoot()))

        // Per-frame scratch, reused across frames and channels.
        var windowed = [Float](repeating: 0, count: nfft)
        var packedRe = [Float](repeating: 0, count: half)
        var packedIm = [Float](repeating: 0, count: half)
        var outRe = [Float](repeating: 0, count: half)
        var outIm = [Float](repeating: 0, count: half)
        // Per-channel planes (time-major, then transposed to bin-major), reused.
        var rePlane = [Float](repeating: 0, count: le * bins)
        var imPlane = [Float](repeating: 0, count: le * bins)
        var reT = [Float](repeating: 0, count: le * bins)
        var imT = [Float](repeating: 0, count: le * bins)

        var output = [Float](repeating: 0, count: channels.count * bins * le * 2)

        for (channelIndex, channel) in channels.enumerated() {
            // Outer `_spec` pad (upstream pad1d semantics), then torch.stft's own
            // center pad — two sequential reflections, exactly as upstream composes them.
            let outer = pad1dReflect(channel, left: outerPad, right: outerPad + le * hop - length)
            let padded = reflectPad(outer, left: half, right: half)

            for frame in 0..<le {
                // Kept torch frames are [2, 2+le): frame `t` starts at (t+2)·hop.
                let start = (frame + 2) * hop
                padded.withUnsafeBufferPointer { p in
                    vDSP_vmul(p.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(nfft))
                }
                // Real signal → packed split-complex (even/odd) → forward real DFT.
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
                        packedRe.withUnsafeMutableBufferPointer { rp in
                            packedIm.withUnsafeMutableBufferPointer { ip in
                                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                    }
                }
                vDSP_DFT_Execute(setup, packedRe, packedIm, &outRe, &outIm)
                // Packed output: outRe[0] = DC, outIm[0] = Nyquist (dropped), bins 1..2047.
                // The kept row is therefore outRe as-is and outIm with slot 0 zeroed.
                rePlane.replaceSubrange(frame * bins..<(frame + 1) * bins, with: outRe)
                imPlane.replaceSubrange(frame * bins..<(frame + 1) * bins, with: outIm)
                imPlane[frame * bins] = 0
            }

            // Scale once, transpose [le][bins] → [bins][le], interleave re/im pairs.
            vDSP_vsmul(rePlane, 1, &forwardScale, &rePlane, 1, vDSP_Length(le * bins))
            vDSP_vsmul(imPlane, 1, &forwardScale, &imPlane, 1, vDSP_Length(le * bins))
            vDSP_mtrans(rePlane, 1, &reT, 1, vDSP_Length(bins), vDSP_Length(le))
            vDSP_mtrans(imPlane, 1, &imT, 1, vDSP_Length(bins), vDSP_Length(le))
            let channelBase = channelIndex * bins * le * 2
            output.withUnsafeMutableBufferPointer { out in
                (out.baseAddress! + channelBase).withMemoryRebound(to: DSPComplex.self, capacity: bins * le) { pairs in
                    reT.withUnsafeMutableBufferPointer { rp in
                        imT.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(bins * le))
                        }
                    }
                }
            }
        }

        return ComplexSpectrogram(channels: channels.count, bins: bins, frames: le, data: output)
    }

    // MARK: - ispec (demucs `_ispec`)

    /// Inverts a masked htdemucs spectrogram back to `length` samples per channel.
    /// `z.frames` must equal `ceil(length / hop)` — the framing `spectrogram` produced
    /// for a `length`-sample input (the upstream `_ispec` contract).
    public static func inverseSpectrogram(_ z: ComplexSpectrogram, length: Int) throws -> [[Float]] {
        guard z.bins == bins else {
            throw HTDemucsDSPError.invalidShape("expected \(bins) bins, got \(z.bins)")
        }
        guard length > 0, z.frames > 0, z.channels > 0 else {
            throw HTDemucsDSPError.emptyInput
        }
        let hop = hopLength
        let le = (length + hop - 1) / hop
        guard z.frames == le else {
            throw HTDemucsDSPError.invalidShape("expected ceil(\(length)/\(hop)) = \(le) frames, got \(z.frames)")
        }

        let half = nfft / 2
        let frames = z.frames
        let totalFrames = frames + 4 // two zero frames padded on each side (upstream F.pad(z, (2, 2)))
        let olaLength = (totalFrames - 1) * hop + nfft
        // Final trim: istft center-trims nfft/2, then `_ispec` takes [outerPad, outerPad+length).
        let outputStart = half + outerPad

        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nfft), .INVERSE) else {
            throw HTDemucsDSPError.invalidShape("DFT setup failed for nfft \(nfft)")
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        let window = periodicHannWindow(nfft)
        // Inverse scale: vDSP's packed inverse real DFT computes the full Hermitian
        // sum Σ Zₖe^{+2πikn/N} (the ×2 of the FORWARD packing does not recur), so the
        // ortho inverse needs only 1/√nfft, folded into the synthesis window.
        var inverseScale = Float(1.0 / Double(nfft).squareRoot())
        var scaledWindow = [Float](repeating: 0, count: nfft)
        vDSP_vsmul(window, 1, &inverseScale, &scaledWindow, 1, vDSP_Length(nfft))

        // Window-squared envelope over ALL frames — including the four zero-padded
        // ones, which contribute window energy but no signal (torch.istft semantics).
        var windowSq = [Float](repeating: 0, count: nfft)
        vDSP_vsq(window, 1, &windowSq, 1, vDSP_Length(nfft))
        var envelope = [Float](repeating: 0, count: olaLength)
        envelope.withUnsafeMutableBufferPointer { env in
            for frame in 0..<totalFrames {
                let base = env.baseAddress! + frame * hop
                vDSP_vadd(base, 1, windowSq, 1, base, 1, vDSP_Length(nfft))
            }
        }

        // Per-channel scratch, reused.
        var binMajorRe = [Float](repeating: 0, count: bins * frames)
        var binMajorIm = [Float](repeating: 0, count: bins * frames)
        var timeRe = [Float](repeating: 0, count: frames * bins)
        var timeIm = [Float](repeating: 0, count: frames * bins)
        var outEven = [Float](repeating: 0, count: half)
        var outOdd = [Float](repeating: 0, count: half)
        var timeFrame = [Float](repeating: 0, count: nfft)
        var ola = [Float](repeating: 0, count: olaLength)

        var outputs: [[Float]] = []
        outputs.reserveCapacity(z.channels)

        for channelIndex in 0..<z.channels {
            // Deinterleave the channel's [bins][frames][2] block into planes, then
            // transpose to time-major rows so each frame's spectrum is contiguous.
            z.data.withUnsafeBufferPointer { src in
                (src.baseAddress! + channelIndex * bins * frames * 2)
                    .withMemoryRebound(to: DSPComplex.self, capacity: bins * frames) { pairs in
                        binMajorRe.withUnsafeMutableBufferPointer { rp in
                            binMajorIm.withUnsafeMutableBufferPointer { ip in
                                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(bins * frames))
                            }
                        }
                    }
            }
            vDSP_mtrans(binMajorRe, 1, &timeRe, 1, vDSP_Length(frames), vDSP_Length(bins))
            vDSP_mtrans(binMajorIm, 1, &timeIm, 1, vDSP_Length(frames), vDSP_Length(bins))

            vDSP_vclr(&ola, 1, vDSP_Length(olaLength))
            for frame in 0..<frames {
                // Packed inverse input: slot 0 of the real row already holds DC.re;
                // slot 0 of the imag row must hold the (re-appended, zero) Nyquist bin.
                // DC.im is dropped — torch's c2r ignores it (it has no slot in the
                // Hermitian packing), and so does vDSP's.
                timeIm[frame * bins] = 0
                timeRe.withUnsafeBufferPointer { rp in
                    timeIm.withUnsafeBufferPointer { ip in
                        vDSP_DFT_Execute(setup, rp.baseAddress! + frame * bins, ip.baseAddress! + frame * bins, &outEven, &outOdd)
                    }
                }
                // Even/odd split → interleaved real time samples.
                timeFrame.withUnsafeMutableBufferPointer { t in
                    t.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { pairs in
                        outEven.withUnsafeMutableBufferPointer { ep in
                            outOdd.withUnsafeMutableBufferPointer { op in
                                var split = DSPSplitComplex(realp: ep.baseAddress!, imagp: op.baseAddress!)
                                vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(half))
                            }
                        }
                    }
                }
                // Synthesis-window multiply (scale folded in) + overlap-add, one fused op.
                // Source frame `frame` is padded frame `frame + 2`.
                ola.withUnsafeMutableBufferPointer { o in
                    let base = o.baseAddress! + (frame + 2) * hop
                    vDSP_vma(timeFrame, 1, scaledWindow, 1, base, 1, base, 1, vDSP_Length(nfft))
                }
            }

            var channelOut = [Float](repeating: 0, count: length)
            ola.withUnsafeBufferPointer { o in
                envelope.withUnsafeBufferPointer { env in
                    vDSP_vdiv(env.baseAddress! + outputStart, 1, o.baseAddress! + outputStart, 1, &channelOut, 1, vDSP_Length(length))
                }
            }
            outputs.append(channelOut)
        }

        return outputs
    }

    /// The overlap-add normalization divisor `inverseSpectrogram` applies,
    /// pre-sliced to the emitted `[outputStart, outputStart + length)` range:
    /// the window-squared envelope over all frames (including the four
    /// zero-padded ones — torch.istft semantics). Pure function of
    /// (frames, length) — the engine's GPU epilogue (Phase 6) uploads it once
    /// per window shape so its iSTFT divides by EXACTLY the values the CPU
    /// path divides by; the numeric knowledge stays in this file.
    public static func inverseEnvelope(frames: Int, length: Int) -> [Float] {
        let hop = hopLength
        let totalFrames = frames + 4
        let olaLength = (totalFrames - 1) * hop + nfft
        let outputStart = nfft / 2 + outerPad
        let window = periodicHannWindow(nfft)
        var windowSq = [Float](repeating: 0, count: nfft)
        vDSP_vsq(window, 1, &windowSq, 1, vDSP_Length(nfft))
        var envelope = [Float](repeating: 0, count: olaLength)
        envelope.withUnsafeMutableBufferPointer { env in
            for frame in 0..<totalFrames {
                let base = env.baseAddress! + frame * hop
                vDSP_vadd(base, 1, windowSq, 1, base, 1, vDSP_Length(nfft))
            }
        }
        return Array(envelope[outputStart ..< outputStart + length])
    }

    /// The trim `inverseSpectrogram` applies before emitting samples (istft's
    /// nfft/2 center trim + `_ispec`'s outer pad) — the GPU epilogue slices its
    /// overlap-add buffer at the same offset.
    public static var inverseOutputStart: Int { nfft / 2 + outerPad }

    /// Gather indices reproducing `spectrogram`'s exact framing (the Phase 6
    /// GPU input path): entry `t·nfft + n` holds the SOURCE sample index that
    /// analysis frame `t`'s sample `n` reads — the composition of the outer
    /// `pad1d` reflect, torch.stft's center reflect (two SEQUENTIAL
    /// reflections, exactly as `spectrogram` composes them), the `[2, 2+le)`
    /// frame trim, and hop framing. One `take()` with these indices frames a
    /// `length`-sample channel exactly as the CPU path does. Requires
    /// `length > nfft` (production windows are training-length; the
    /// tiny-signal zero-extend fallback has no gather form).
    public static func spectrogramGatherIndices(length: Int) -> [Int32] {
        precondition(length > nfft, "gather framing requires length > nfft")
        let hop = hopLength
        let le = (length + hop - 1) / hop
        let half = nfft / 2
        let outerLength = 2 * outerPad + le * hop
        // Strict torch reflect (edge sample excluded), single reflection —
        // sufficient because every pad is shorter than the padded signal here.
        func reflectOuter(_ index: Int) -> Int {  // outer-padded position → source
            var q = index
            if q < 0 { q = -q }
            if q >= length { q = 2 * length - 2 - q }
            return q
        }
        func reflectCenter(_ index: Int) -> Int {  // stft-padded position → outer-padded
            var q = index
            if q < 0 { q = -q }
            if q >= outerLength { q = 2 * outerLength - 2 - q }
            return q
        }
        var indices = [Int32](repeating: 0, count: le * nfft)
        for frame in 0..<le {
            let base = (frame + 2) * hop
            for n in 0..<nfft {
                let outerIndex = reflectCenter(base + n - half)
                indices[frame * nfft + n] = Int32(reflectOuter(outerIndex - outerPad))
            }
        }
        return indices
    }

    // MARK: - CaC pack/unpack (demucs `_magnitude` / `_mask`, cac = true)

    /// Complex-as-channels packing: `[C][Fr][T]` complex → `[2C][Fr][T]` real with
    /// channel order `c0.re, c0.im, c1.re, c1.im` (torch
    /// `view_as_real(z).permute(0,1,4,2,3).reshape(B, C*2, Fr, T)`).
    public static func packCaC(_ z: ComplexSpectrogram) -> [Float] {
        let plane = z.bins * z.frames
        var output = [Float](repeating: 0, count: z.channels * 2 * plane)
        z.data.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                for channel in 0..<z.channels {
                    (src.baseAddress! + channel * plane * 2)
                        .withMemoryRebound(to: DSPComplex.self, capacity: plane) { pairs in
                            var split = DSPSplitComplex(
                                realp: dst.baseAddress! + (2 * channel) * plane,
                                imagp: dst.baseAddress! + (2 * channel + 1) * plane
                            )
                            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(plane))
                        }
                }
            }
        }
        return output
    }

    /// Inverse of `packCaC` across a source axis: flat `[S][2C][Fr][T]` real (the
    /// model's mask output) → one complex spectrogram per source (torch
    /// `m.view(B,S,-1,2,Fr,T).permute(0,1,2,4,5,3)` + `view_as_complex`).
    public static func unpackCaC(
        _ m: [Float], sources: Int, channels: Int, bins: Int, frames: Int
    ) throws -> [ComplexSpectrogram] {
        try m.withUnsafeBufferPointer {
            try unpackCaC($0, sources: sources, channels: channels, bins: bins, frames: frames)
        }
    }

    /// Pointer-based `unpackCaC` entry: reads the packed CaC planes directly from
    /// caller-owned storage. Phase 6: the engine passes a zero-copy view of the
    /// evaluated GPU output buffer (unified memory) instead of first materializing
    /// a `[Float]` copy; the `[Float]` entry above forwards here.
    public static func unpackCaC(
        _ m: UnsafeBufferPointer<Float>, sources: Int, channels: Int, bins: Int, frames: Int
    ) throws -> [ComplexSpectrogram] {
        let plane = bins * frames
        guard sources > 0, channels > 0, plane > 0,
              m.count == sources * channels * 2 * plane else {
            throw HTDemucsDSPError.invalidShape(
                "expected \(sources)·\(channels * 2)·\(bins)·\(frames) values, got \(m.count)")
        }
        var outputs: [ComplexSpectrogram] = []
        outputs.reserveCapacity(sources)
        for source in 0..<sources {
            var data = [Float](repeating: 0, count: channels * plane * 2)
            data.withUnsafeMutableBufferPointer { dst in
                for channel in 0..<channels {
                    let planeBase = m.baseAddress! + (source * channels * 2 + 2 * channel) * plane
                    var split = DSPSplitComplex(
                        realp: UnsafeMutablePointer(mutating: planeBase),
                        imagp: UnsafeMutablePointer(mutating: planeBase + plane)
                    )
                    (dst.baseAddress! + channel * plane * 2)
                        .withMemoryRebound(to: DSPComplex.self, capacity: plane) { pairs in
                            vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(plane))
                        }
                }
            }
            outputs.append(ComplexSpectrogram(channels: channels, bins: bins, frames: frames, data: data))
        }
        return outputs
    }

    // MARK: - Windows and padding

    /// `torch.hann_window(n)` — the PERIODIC Hann window (denominator `n`, not `n−1`).
    /// vDSP's `vDSP_hann_window` builds the symmetric variant, so build it directly.
    /// Computed in Double and rounded once: `0.5 − 0.5·cos(θ)` in fp32 loses most of
    /// its significand to cancellation where the window approaches zero.
    public static func periodicHannWindow(_ n: Int) -> [Float] {
        var phases = [Double](repeating: 0, count: n)
        var start = 0.0
        var step = 2.0 * Double.pi / Double(n)
        vDSP_vrampD(&start, &step, &phases, 1, vDSP_Length(n))
        var cosines = [Double](repeating: 0, count: n)
        var count = Int32(n)
        vvcos(&cosines, phases, &count)
        var negHalf = -0.5
        var half = 0.5
        vDSP_vsmsaD(cosines, 1, &negHalf, &half, &cosines, 1, vDSP_Length(n))
        var window = [Float](repeating: 0, count: n)
        vDSP_vdpsp(cosines, 1, &window, 1, vDSP_Length(n))
        return window
    }

    /// Upstream demucs `pad1d(..., mode="reflect")`: reflect padding, with the
    /// small-input fallback — a signal too short to reflect is first zero-extended
    /// (right side first, mirroring upstream) and the reflect amounts reduced.
    static func pad1dReflect(_ signal: [Float], left: Int, right: Int) -> [Float] {
        precondition(left >= 0 && right >= 0, "negative padding")
        let maxPad = max(left, right)
        if signal.count <= maxPad {
            let extra = maxPad - signal.count + 1
            let extraRight = min(right, extra)
            let extraLeft = extra - extraRight
            var extended = [Float](repeating: 0, count: extraLeft + signal.count + extraRight)
            extended.replaceSubrange(extraLeft..<(extraLeft + signal.count), with: signal)
            return reflectPad(extended, left: left - extraLeft, right: right - extraRight)
        }
        return reflectPad(signal, left: left, right: right)
    }

    /// Strict reflect padding (torch `F.pad(mode="reflect")`): mirrors around the
    /// edge sample, excluding it — `out[left−1−j] = x[1+j]`, `out[left+n+j] = x[n−2−j]`.
    /// Requires `left < n` and `right < n`.
    static func reflectPad(_ signal: [Float], left: Int, right: Int) -> [Float] {
        let count = signal.count
        precondition(left >= 0 && right >= 0 && left < count && right < count, "reflect pad exceeds signal length")
        var output = [Float](repeating: 0, count: left + count + right)
        output.replaceSubrange(left..<(left + count), with: signal)
        if left > 0 {
            output.replaceSubrange(0..<left, with: signal[1...left])
            output.withUnsafeMutableBufferPointer { buf in
                vDSP_vrvrs(buf.baseAddress!, 1, vDSP_Length(left))
            }
        }
        if right > 0 {
            output.replaceSubrange((left + count)..., with: signal[(count - 1 - right)...(count - 2)])
            output.withUnsafeMutableBufferPointer { buf in
                vDSP_vrvrs(buf.baseAddress! + left + count, 1, vDSP_Length(right))
            }
        }
        return output
    }
}
