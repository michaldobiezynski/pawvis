import Foundation

/// An MPEG-1 Audio Layer III encoder in plain Swift: 32, 44.1 or 48 kHz,
/// mono or stereo, constant bitrate, long blocks only, no bit reservoir and
/// no psychoacoustic model. It exists because macOS ships no MP3 *encoder*
/// (measured on macOS 26.5: `AudioConverterNew` from LPCM to
/// `kAudioFormatMPEGLayer3` fails with `fmt?`, and `afconvert -f MPG3` says
/// the same), and the theremin's recordings are asked for as MP3.
///
/// The structure is the ISO reference encoder's, in the order the standard
/// lays it out (Annex C): a 32-band polyphase analysis filterbank (C.1.3,
/// window table C.1), an 18-point MDCT per band with the alias-reduction
/// butterflies (B.9), a global-gain quantizer searched until the granule's
/// Huffman bits fit its share of the frame, and Huffman coding with the
/// normative tables (B.7). Every scalefactor is zero, so the quantization
/// noise is spread flat and set by one gain per granule: at 192 kbps and up
/// this is transparent for tonal material like a theremin, and audibly
/// coarser than LAME on dense mixes — which is not what it is for.
///
/// Pure Swift, no Foundation audio: encoding is deterministic, so the
/// bitstream structure is unit-tested here, and the app's self-test decodes
/// the output back through AVFoundation (an independent decoder) to prove
/// the frames are real audio, not merely well-formed.
public final class MP3Encoder {
    public enum EncodingError: Error, Equatable {
        /// MPEG-1 Layer III supports exactly 32000, 44100 and 48000 Hz.
        case unsupportedSampleRate(Int)
        case unsupportedChannelCount(Int)
        case unsupportedBitrate(Int)
    }

    /// MPEG-1 sampling frequencies, in header index order.
    public static let supportedSampleRates = [44100, 48000, 32000]
    /// MPEG-1 Layer III bitrates (kbit/s), in header index order (index 1…14).
    public static let supportedBitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    /// PCM samples per channel per frame (two granules of 576).
    public static let samplesPerFrame = 1152

    public let sampleRate: Int
    public let channels: Int
    /// kbit/s.
    public let bitrate: Int

    /// Frames written so far, for progress reporting.
    public private(set) var framesEncoded = 0
    /// PCM frames (per channel) accepted so far.
    public private(set) var samplesAccepted = 0

    private let sampleRateIndex: Int
    private let bitrateIndex: Int
    private let scalefactorBands: [Int]
    private let sideInfoBytes: Int

    // Frame-size bookkeeping (C.1.5.2): the exact rate is kept by padding
    // some frames with one extra slot.
    private let wholeSlots: Int
    private let fractionalSlots: Double
    private var slotLag: Double

    // Filterbank state: a 512-sample window per channel (X in C.1.3), kept
    // as a ring so shifting is an offset change, and the previous granule's
    // subband samples (18 × 32) for the MDCT overlap.
    private var ring: [[Double]]
    private var ringOffset: [Int]
    private var previousSubbands: [[Double]]

    /// PCM waiting for a full frame, per channel.
    private var pending: [[Float]]
    private var output: [UInt8] = []

    private var writer = BitWriter()

    public init(sampleRate: Int, channels: Int, bitrate: Int = 256) throws {
        guard let sampleRateIndex = Self.supportedSampleRates.firstIndex(of: sampleRate) else {
            throw EncodingError.unsupportedSampleRate(sampleRate)
        }
        guard channels == 1 || channels == 2 else {
            throw EncodingError.unsupportedChannelCount(channels)
        }
        guard let bitrateIndex = Self.supportedBitrates.firstIndex(of: bitrate) else {
            throw EncodingError.unsupportedBitrate(bitrate)
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitrate = bitrate
        self.sampleRateIndex = sampleRateIndex
        self.bitrateIndex = bitrateIndex + 1
        scalefactorBands = MP3Tables.scalefactorBands[sampleRateIndex]
        sideInfoBytes = channels == 1 ? 17 : 32

        // 1152 samples at `bitrate` kbit/s is 144000 · kbps / rate bytes.
        let slots = Double(144_000 * bitrate) / Double(sampleRate)
        wholeSlots = Int(slots)
        fractionalSlots = slots - Double(wholeSlots)
        slotLag = -fractionalSlots

        ring = Array(repeating: Array(repeating: 0, count: 512), count: channels)
        ringOffset = Array(repeating: 0, count: channels)
        previousSubbands = Array(repeating: Array(repeating: 0, count: 576), count: channels)
        pending = Array(repeating: [], count: channels)
    }

    // MARK: - Public API

    /// Feed PCM: one array per channel, equal lengths, nominally in −1…1
    /// (anything beyond is clipped). Every complete frame is encoded at
    /// once; the remainder waits for the next call or `finish()`.
    public func append(_ pcm: [[Float]]) {
        precondition(pcm.count == channels, "MP3Encoder: expected \(channels) channel(s)")
        let count = pcm[0].count
        for ch in 0..<channels {
            precondition(pcm[ch].count == count, "MP3Encoder: channels must be the same length")
            pending[ch].append(contentsOf: pcm[ch])
        }
        samplesAccepted += count
        encodePendingFrames()
    }

    /// Encoded bytes produced so far, handed over once (the internal buffer
    /// is drained). Call as often as you like while streaming.
    public func takeOutput() -> Data {
        let data = Data(output)
        output.removeAll(keepingCapacity: true)
        return data
    }

    /// Pads the last partial frame with silence, appends one further frame
    /// of silence so a decoder's filterbank delay flushes the real tail,
    /// and returns everything not yet taken. The encoder is reset after.
    public func finish() -> Data {
        let remainder = pending[0].count
        if remainder > 0 {
            let pad = Self.samplesPerFrame - remainder
            for ch in 0..<channels {
                pending[ch].append(contentsOf: repeatElement(0, count: pad))
            }
        }
        for ch in 0..<channels {
            pending[ch].append(contentsOf: repeatElement(0, count: Self.samplesPerFrame))
        }
        encodePendingFrames()
        let data = takeOutput()
        for ch in 0..<channels {
            ring[ch] = Array(repeating: 0, count: 512)
            ringOffset[ch] = 0
            previousSubbands[ch] = Array(repeating: 0, count: 576)
            pending[ch] = []
        }
        slotLag = -fractionalSlots
        return data
    }

    /// Bytes per frame for this configuration, without padding: what a
    /// frame header's fields work out to.
    public var unpaddedFrameBytes: Int { wholeSlots }

    // MARK: - Frames

    private func encodePendingFrames() {
        while pending[0].count >= Self.samplesPerFrame {
            var frame: [[Float]] = []
            for ch in 0..<channels {
                frame.append(Array(pending[ch][0..<Self.samplesPerFrame]))
                pending[ch].removeFirst(Self.samplesPerFrame)
            }
            encodeFrame(frame)
        }
    }

    /// Per-granule, per-channel side information (2.4.1.7).
    struct GranuleInfo {
        var part23Length = 0
        var bigValues = 0
        var count1 = 0
        var globalGain = 210
        var tableSelect = [0, 0, 0]
        var region0Count = 0
        var region1Count = 0
        var count1Table = 0
        /// Line indices where regions 1 and 2 start (clamped to the big
        /// values region), derived from the region counts exactly the way
        /// a decoder derives them.
        var region1Start = 0
        var region2Start = 0
    }

    private func encodeFrame(_ pcm: [[Float]]) {
        // Padding keeps the mean frame size exact for rates like 44.1 kHz,
        // where 1152 samples is not a whole number of bytes.
        var padding = 0
        if fractionalSlots > 0 {
            padding = slotLag <= fractionalSlots - 1 ? 1 : 0
            slotLag += Double(padding) - fractionalSlots
        }
        let frameBytes = wholeSlots + padding
        let mainDataBits = frameBytes * 8 - 32 - sideInfoBytes * 8

        // Analysis: 2 granules × channels × 576 spectral lines.
        let slots = 2 * channels
        var spectrum = [Double](repeating: 0, count: slots * 576)
        var subbands = [Double](repeating: 0, count: 576)
        for ch in 0..<channels {
            for gr in 0..<2 {
                analyzeGranule(pcm[ch], offset: gr * 576, channel: ch, into: &subbands)
                let slot = gr * channels + ch
                spectrum.withUnsafeMutableBufferPointer { all in
                    let xr = UnsafeMutableBufferPointer(rebasing: all[(slot * 576)..<(slot * 576 + 576)])
                    mdct(previous: previousSubbands[ch], current: subbands, into: xr)
                    reduceAliasing(xr)
                }
                previousSubbands[ch] = subbands
            }
        }

        // Quantize each granule/channel against its share of the frame,
        // handing anything a granule leaves unused to the ones after it (a
        // reservoir confined to the frame, so main_data_begin stays 0).
        var infos = [GranuleInfo](repeating: GranuleInfo(), count: slots)
        var quantized = [Int32](repeating: 0, count: slots * 576)
        var remaining = mainDataBits
        for slot in 0..<slots {
            let budget = min(4095, remaining / (slots - slot))
            spectrum.withUnsafeBufferPointer { all in
                quantized.withUnsafeMutableBufferPointer { allIx in
                    let xr = UnsafeBufferPointer(rebasing: all[(slot * 576)..<(slot * 576 + 576)])
                    let ix = UnsafeMutableBufferPointer(rebasing: allIx[(slot * 576)..<(slot * 576 + 576)])
                    infos[slot] = quantizeGranule(xr: xr, budget: budget, ix: ix)
                }
            }
            remaining -= infos[slot].part23Length
        }

        // The frame: header, side info, main data, zero padding.
        writer.reset(capacity: frameBytes)
        writeHeader(padding: padding)
        writeSideInfo(infos)
        for slot in 0..<slots {
            let before = writer.bitCount
            quantized.withUnsafeBufferPointer { allIx in
                let ix = UnsafeBufferPointer(rebasing: allIx[(slot * 576)..<(slot * 576 + 576)])
                writeGranule(ix: ix, info: infos[slot])
            }
            assert(writer.bitCount - before == infos[slot].part23Length,
                   "Huffman bit count disagreed with part2_3_length")
        }
        writer.padToByte()
        var bytes = writer.bytes
        assert(bytes.count <= frameBytes, "frame overran its slot count")
        if bytes.count < frameBytes {
            bytes.append(contentsOf: repeatElement(0, count: frameBytes - bytes.count))
        }
        output.append(contentsOf: bytes)
        framesEncoded += 1
    }

    // MARK: - Analysis filterbank (C.1.3)

    /// M[k][i] = cos((2k + 1)(i − 16)π / 64), the 32 × 64 matrixing step.
    private static let analysisMatrix: [Double] = {
        var m = [Double](repeating: 0, count: 32 * 64)
        for k in 0..<32 {
            for i in 0..<64 {
                m[k * 64 + i] = cos(Double((2 * k + 1) * (i - 16)) * .pi / 64)
            }
        }
        return m
    }()

    /// Runs the 18 subband blocks of one granule (18 × 32 PCM samples) and
    /// leaves the subband samples in `subbands[k * 32 + band]`, with the
    /// odd-index sign compensation the reference encoder applies before
    /// the MDCT ("inversion in the analysis filter").
    private func analyzeGranule(_ pcm: [Float], offset: Int, channel ch: Int, into subbands: inout [Double]) {
        let window = MP3Tables.analysisWindow
        let matrix = Self.analysisMatrix
        var y = [Double](repeating: 0, count: 64)
        ring[ch].withUnsafeMutableBufferPointer { x in
            for k in 0..<18 {
                // Shift 32 new samples in, newest first: X[0] is the newest.
                var off = ringOffset[ch]
                let base = offset + k * 32
                for i in 0..<32 {
                    let sample = Double(pcm[base + i])
                    x[(off + 31 - i) & 511] = min(max(sample, -1), 1)
                }
                // Window and fold: Y[i] = Σ_j C[i + 64j] · X[i + 64j].
                window.withUnsafeBufferPointer { c in
                    for i in 0..<64 {
                        var sum = 0.0
                        for j in 0..<8 {
                            let idx = i + 64 * j
                            sum += c[idx] * x[(off + idx) & 511]
                        }
                        y[i] = sum
                    }
                }
                // Matrix to 32 subbands.
                matrix.withUnsafeBufferPointer { m in
                    for band in 0..<32 {
                        var sum = 0.0
                        let row = band * 64
                        for i in 0..<64 { sum += m[row + i] * y[i] }
                        // Odd time index and odd band: the sign flip.
                        if (k & 1) == 1 && (band & 1) == 1 { sum = -sum }
                        subbands[k * 32 + band] = sum
                    }
                }
                off = (off + 480) & 511 // 480 ≡ −32 (mod 512): the next block lands below
                ringOffset[ch] = off
            }
        }
    }

    // MARK: - MDCT and alias reduction (2.4.3.4.10, B.9)

    /// Window and MDCT folded into one 18 × 36 table for long blocks:
    /// W[m][n] = sin(π/36 (n + ½)) · cos(π/72 (2n + 19)(2m + 1)).
    private static let mdctTable: [Double] = {
        var t = [Double](repeating: 0, count: 18 * 36)
        for m in 0..<18 {
            for n in 0..<36 {
                let window = sin(.pi / 36 * (Double(n) + 0.5))
                let basis = cos(.pi / 72 * Double((2 * n + 19) * (2 * m + 1)))
                t[m * 36 + n] = window * basis
            }
        }
        return t
    }()

    /// Table B.9's coefficients, as the (cs, ca) pair each butterfly uses.
    private static let butterfly: [(cs: Double, ca: Double)] = {
        [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037].map { c in
            let norm = 1 / (1 + c * c).squareRoot()
            return (cs: norm, ca: c * norm)
        }
    }()

    /// The scale a decoder reconstructs at, relative to the unnormalized
    /// analysis chain above. The standard writes both halves of each
    /// transform pair without a normalization factor. The polyphase
    /// analysis (window C) into the decoder's synthesis (window D = 32·C)
    /// comes back at unity, but the 36-point MDCT into the decoder's
    /// unscaled IMDCT comes back at 9× (N/4), so the plain window–matrix–
    /// MDCT sums must be divided by nine for a decoder to reproduce the
    /// input level. Both ratios were computed numerically from the
    /// standard's own decoder formulas, and the product was measured end to
    /// end: encoded −6 dBFS tones came back through ffmpeg and through
    /// AVFoundation 9× too loud unscaled, and exactly right with this.
    private static let analysisGain = 1.0 / 9

    /// 36 subband samples per band (the previous granule's 18, then this
    /// one's) become 18 spectral lines: xr[band · 18 + m].
    private func mdct(previous: [Double], current: [Double], into xr: UnsafeMutableBufferPointer<Double>) {
        let table = Self.mdctTable
        let gain = Self.analysisGain
        var input = [Double](repeating: 0, count: 36)
        table.withUnsafeBufferPointer { w in
            for band in 0..<32 {
                for k in 0..<18 {
                    input[k] = previous[k * 32 + band]
                    input[k + 18] = current[k * 32 + band]
                }
                for m in 0..<18 {
                    var sum = 0.0
                    let row = m * 36
                    for n in 0..<36 { sum += input[n] * w[row + n] }
                    xr[band * 18 + m] = sum * gain
                }
            }
        }
    }

    /// The alias-reduction butterflies between neighbouring bands, the
    /// inverse of the rotation the decoder applies (`III_antialias`).
    private func reduceAliasing(_ xr: UnsafeMutableBufferPointer<Double>) {
        for band in 1..<32 {
            for i in 0..<8 {
                let (cs, ca) = Self.butterfly[i]
                let upper = xr[band * 18 + i]
                let lower = xr[(band - 1) * 18 + 17 - i]
                xr[band * 18 + i] = upper * cs - lower * ca
                xr[(band - 1) * 18 + 17 - i] = lower * cs + upper * ca
            }
        }
    }

    // MARK: - Quantization (C.1.5.4)

    /// Finds the finest quantizer step whose Huffman-coded granule fits
    /// `budget` bits, and leaves the signed quantized lines in `ix`.
    private func quantizeGranule(xr: UnsafeBufferPointer<Double>, budget: Int,
                                 ix: UnsafeMutableBufferPointer<Int32>) -> GranuleInfo {
        var peak = 0.0
        for i in 0..<576 { peak = max(peak, abs(xr[i])) }
        var info = GranuleInfo()
        guard peak > 0, budget > 0 else {
            for i in 0..<576 { ix[i] = 0 }
            return info
        }

        // The step size is the exponent in xr / 2^(step/4); coarser steps
        // (larger) cost fewer bits, so the search is a monotone bisection
        // for the smallest step that fits. global_gain = step + 210 must
        // stay within its 8 bits.
        var low = -120
        var high = 45
        while low < high {
            let mid = low + (high - low) / 2
            if fits(step: mid, xr: xr, peak: peak, budget: budget, ix: ix) != nil {
                high = mid
            } else {
                low = mid + 1
            }
        }
        if let found = fits(step: high, xr: xr, peak: peak, budget: budget, ix: ix) {
            info = found
        } else {
            // Unreachable for sane input (|pcm| ≤ 1); keep the stream valid.
            _ = quantize(xr: xr, step: high, into: ix)
            info = layOut(ix: UnsafeBufferPointer(ix))
            if info.part23Length > budget { info = GranuleInfo(); for i in 0..<576 { ix[i] = 0 } }
        }
        info.globalGain = high + 210
        // Signs ride along with the magnitudes from here on.
        for i in 0..<576 where xr[i] < 0 && ix[i] > 0 { ix[i] = -ix[i] }
        return info
    }

    /// Quantizes at `step` and lays the granule out; nil when the result
    /// cannot be coded (a line past the Huffman range) or does not fit.
    private func fits(step: Int, xr: UnsafeBufferPointer<Double>, peak: Double, budget: Int,
                      ix: UnsafeMutableBufferPointer<Int32>) -> GranuleInfo? {
        let scale = pow(2.0, -Double(step) / 4)
        // 8191 is the largest value the escape tables carry (15 + 13 linbits).
        guard peak * scale <= 165_140 else { return nil } // 8192^(4/3)
        let maximum = quantize(xr: xr, step: step, into: ix)
        guard maximum <= 8191 else { return nil }
        let info = layOut(ix: UnsafeBufferPointer(ix))
        return info.part23Length <= budget ? info : nil
    }

    /// ix = nint((|xr| / 2^(step/4))^(3/4) − 0.0946), the standard's
    /// quantizer. Returns the largest magnitude.
    private func quantize(xr: UnsafeBufferPointer<Double>, step: Int,
                          into ix: UnsafeMutableBufferPointer<Int32>) -> Int32 {
        let scale = pow(2.0, -Double(step) / 4)
        var maximum: Int32 = 0
        for i in 0..<576 {
            let v = abs(xr[i]) * scale
            // v^(3/4) as sqrt(sqrt(v) · v), the standard's own shortcut.
            let q = Int32((v.squareRoot() * v).squareRoot() - 0.0946 + 0.5)
            ix[i] = q
            if q > maximum { maximum = q }
        }
        return maximum
    }

    // MARK: - Laying a granule out (2.4.2.7)

    /// The bit-allocation table the reference encoder uses to split the big
    /// values region into its three Huffman regions, by how many
    /// scalefactor bands the region spans.
    private static let regionSplit: [(r0: Int, r1: Int)] = [
        (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 1), (1, 1), (1, 1), (1, 2), (2, 2), (2, 3), (2, 3),
        (3, 4), (3, 4), (3, 4), (4, 5), (4, 5), (4, 6), (5, 6), (5, 6), (5, 7), (6, 7), (6, 7),
    ]

    /// Partitions the quantized lines into the zero run, the count1 quads
    /// and the big values, splits the big values into regions, picks a
    /// Huffman table per region and counts the bits — exactly the bits
    /// `writeGranule` then writes.
    private func layOut(ix: UnsafeBufferPointer<Int32>) -> GranuleInfo {
        var info = GranuleInfo()
        // Trailing zero pairs, then quads of |v| ≤ 1, then the rest.
        var end = 576
        while end > 1, ix[end - 1] == 0, ix[end - 2] == 0 { end -= 2 }
        var count1 = 0
        while end > 3, abs(ix[end - 1]) <= 1, abs(ix[end - 2]) <= 1,
              abs(ix[end - 3]) <= 1, abs(ix[end - 4]) <= 1 {
            count1 += 1
            end -= 4
        }
        info.bigValues = end / 2
        info.count1 = count1

        var bits = 0
        // count1: whichever quad table is cheaper.
        let quadStart = info.bigValues * 2
        var bitsA = 0, bitsB = 0
        for q in 0..<count1 {
            let i = quadStart + q * 4
            let v = abs(ix[i]), w = abs(ix[i + 1]), x = abs(ix[i + 2]), y = abs(ix[i + 3])
            let p = Int(v) | Int(w) << 1 | Int(x) << 2 | Int(y) << 3
            let signs = Int(v) + Int(w) + Int(x) + Int(y)
            bitsA += Int(MP3Tables.lengths32[p]) + signs
            bitsB += Int(MP3Tables.lengths33[p]) + signs
        }
        info.count1Table = bitsB < bitsA ? 1 : 0
        bits += min(bitsA, bitsB)

        // Region division, in scalefactor bands.
        let bigEnd = info.bigValues * 2
        if bigEnd > 0 {
            let sfb = scalefactorBands
            var bandCount = 0
            while sfb[bandCount] < bigEnd { bandCount += 1 }
            var r0 = Self.regionSplit[bandCount].r0
            while r0 > 0, sfb[r0 + 1] > bigEnd { r0 -= 1 }
            info.region0Count = r0
            let base = r0 + 1
            var r1 = Self.regionSplit[bandCount].r1
            while r1 > 0, sfb[base + r1 + 1] > bigEnd { r1 -= 1 }
            info.region1Count = r1
            info.region1Start = min(sfb[base], bigEnd)
            info.region2Start = min(sfb[base + r1 + 1], bigEnd)

            let regions = [(0, info.region1Start), (info.region1Start, info.region2Start),
                           (info.region2Start, bigEnd)]
            for (r, (start, stop)) in regions.enumerated() where stop > start {
                let table = chooseTable(ix: ix, start: start, end: stop)
                info.tableSelect[r] = table
                bits += Self.bitCount(table: table, ix: ix, start: start, end: stop)
            }
        }
        info.part23Length = bits
        return info
    }

    /// The Huffman table that codes `ix[start..<end]` in the fewest bits.
    private func chooseTable(ix: UnsafeBufferPointer<Int32>, start: Int, end: Int) -> Int {
        var maximum: Int32 = 0
        for i in start..<end { maximum = max(maximum, abs(ix[i])) }
        guard maximum > 0 else { return 0 }
        var best = 0
        var bestBits = Int.max
        if maximum < 15 {
            for candidate in [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15] {
                guard let table = HuffmanTable.all[candidate], table.xlen > Int(maximum) else { continue }
                let bits = Self.bitCount(table: candidate, ix: ix, start: start, end: end)
                if bits < bestBits { bestBits = bits; best = candidate }
            }
        } else {
            let escape = Int(maximum) - 15
            for family in [16..<24, 24..<32] {
                guard let candidate = family.first(where: { HuffmanTable.all[$0]!.linmax >= escape }) else { continue }
                let bits = Self.bitCount(table: candidate, ix: ix, start: start, end: end)
                if bits < bestBits { bestBits = bits; best = candidate }
            }
        }
        return best
    }

    /// Bits to code the pairs in `ix[start..<end]` with `table`.
    private static func bitCount(table: Int, ix: UnsafeBufferPointer<Int32>, start: Int, end: Int) -> Int {
        guard table > 0, let h = HuffmanTable.all[table] else { return 0 }
        var bits = 0
        let ylen = h.xlen
        var i = start
        while i < end {
            var x = Int(abs(ix[i])), y = Int(abs(ix[i + 1]))
            if h.linbits > 0 {
                if x > 14 { x = 15; bits += h.linbits }
                if y > 14 { y = 15; bits += h.linbits }
            }
            bits += Int(h.lengths[x * ylen + y])
            if x != 0 { bits += 1 }
            if y != 0 { bits += 1 }
            i += 2
        }
        return bits
    }

    // MARK: - Bitstream (2.4.1)

    private func writeHeader(padding: Int) {
        writer.put(0x7FF, 11)             // sync
        writer.put(0b11, 2)               // MPEG-1
        writer.put(0b01, 2)               // Layer III
        writer.put(1, 1)                  // no CRC
        writer.put(UInt32(bitrateIndex), 4)
        writer.put(UInt32(sampleRateIndex), 2)
        writer.put(UInt32(padding), 1)
        writer.put(0, 1)                  // private
        writer.put(channels == 1 ? 0b11 : 0b00, 2) // mono, or stereo (independent channels)
        writer.put(0, 2)                  // mode extension
        writer.put(0, 1)                  // copyright
        writer.put(1, 1)                  // original
        writer.put(0, 2)                  // no emphasis
    }

    private func writeSideInfo(_ infos: [GranuleInfo]) {
        writer.put(0, 9)                          // main_data_begin: no reservoir
        writer.put(0, channels == 1 ? 5 : 3)      // private bits
        for _ in 0..<channels { writer.put(0, 4) } // scfsi: scalefactors are never shared (there are none)
        for info in infos {
            writer.put(UInt32(info.part23Length), 12)
            writer.put(UInt32(info.bigValues), 9)
            writer.put(UInt32(info.globalGain), 8)
            writer.put(0, 4)                      // scalefac_compress
            writer.put(0, 1)                      // window_switching_flag: long blocks
            for table in info.tableSelect { writer.put(UInt32(table), 5) }
            writer.put(UInt32(info.region0Count), 4)
            writer.put(UInt32(info.region1Count), 3)
            writer.put(0, 1)                      // preflag
            writer.put(0, 1)                      // scalefac_scale
            writer.put(UInt32(info.count1Table), 1)
        }
    }

    /// The main data of one granule/channel: no scalefactors, then the
    /// Huffman-coded big values by region, then the count1 quads.
    private func writeGranule(ix: UnsafeBufferPointer<Int32>, info: GranuleInfo) {
        let bigEnd = info.bigValues * 2
        let regions = [(0, info.region1Start, info.tableSelect[0]),
                       (info.region1Start, info.region2Start, info.tableSelect[1]),
                       (info.region2Start, bigEnd, info.tableSelect[2])]
        for (start, stop, table) in regions where stop > start && table > 0 {
            let h = HuffmanTable.all[table]!
            var i = start
            while i < stop {
                writePair(x: ix[i], y: ix[i + 1], table: h)
                i += 2
            }
        }
        let quad = info.count1Table == 0
            ? (codes: MP3Tables.codes32, lengths: MP3Tables.lengths32)
            : (codes: MP3Tables.codes33, lengths: MP3Tables.lengths33)
        for q in 0..<info.count1 {
            let i = bigEnd + q * 4
            let values = [ix[i], ix[i + 1], ix[i + 2], ix[i + 3]]
            var p = 0
            for (n, v) in values.enumerated() where v != 0 { p |= 1 << n }
            writer.put(UInt32(quad.codes[p]), Int(quad.lengths[p]))
            for v in values where v != 0 { writer.put(v < 0 ? 1 : 0, 1) }
        }
    }

    /// hcod, then (for escape tables) linbits and sign of x, then of y.
    private func writePair(x sx: Int32, y sy: Int32, table h: HuffmanTable) {
        var x = Int(abs(sx)), y = Int(abs(sy))
        var escapeX = 0, escapeY = 0
        if h.linbits > 0 {
            if x > 14 { escapeX = x - 15; x = 15 }
            if y > 14 { escapeY = y - 15; y = 15 }
        }
        let idx = x * h.xlen + y
        writer.put(UInt32(h.codes[idx]), Int(h.lengths[idx]))
        if x == 15, h.linbits > 0 { writer.put(UInt32(escapeX), h.linbits) }
        if x != 0 { writer.put(sx < 0 ? 1 : 0, 1) }
        if y == 15, h.linbits > 0 { writer.put(UInt32(escapeY), h.linbits) }
        if y != 0 { writer.put(sy < 0 ? 1 : 0, 1) }
    }
}

// MARK: - Huffman tables (B.7)

/// One of the standard's 32 big-value tables (or the two quad tables), as
/// the encoder needs it: square (`xlen` × `xlen`) code and length arrays,
/// plus the escape width for tables 16–31.
struct HuffmanTable {
    let xlen: Int
    let linbits: Int
    let codes: [UInt16]
    let lengths: [UInt8]

    var linmax: Int { (1 << linbits) - 1 }

    /// Indexed by the `table_select` value; nil for table 0 (all zeros)
    /// and the two indices the standard leaves unused.
    static let all: [HuffmanTable?] = {
        var t = [HuffmanTable?](repeating: nil, count: 34)
        t[1] = HuffmanTable(xlen: 2, linbits: 0, codes: MP3Tables.codes1, lengths: MP3Tables.lengths1)
        t[2] = HuffmanTable(xlen: 3, linbits: 0, codes: MP3Tables.codes2, lengths: MP3Tables.lengths2)
        t[3] = HuffmanTable(xlen: 3, linbits: 0, codes: MP3Tables.codes3, lengths: MP3Tables.lengths3)
        t[5] = HuffmanTable(xlen: 4, linbits: 0, codes: MP3Tables.codes5, lengths: MP3Tables.lengths5)
        t[6] = HuffmanTable(xlen: 4, linbits: 0, codes: MP3Tables.codes6, lengths: MP3Tables.lengths6)
        t[7] = HuffmanTable(xlen: 6, linbits: 0, codes: MP3Tables.codes7, lengths: MP3Tables.lengths7)
        t[8] = HuffmanTable(xlen: 6, linbits: 0, codes: MP3Tables.codes8, lengths: MP3Tables.lengths8)
        t[9] = HuffmanTable(xlen: 6, linbits: 0, codes: MP3Tables.codes9, lengths: MP3Tables.lengths9)
        t[10] = HuffmanTable(xlen: 8, linbits: 0, codes: MP3Tables.codes10, lengths: MP3Tables.lengths10)
        t[11] = HuffmanTable(xlen: 8, linbits: 0, codes: MP3Tables.codes11, lengths: MP3Tables.lengths11)
        t[12] = HuffmanTable(xlen: 8, linbits: 0, codes: MP3Tables.codes12, lengths: MP3Tables.lengths12)
        t[13] = HuffmanTable(xlen: 16, linbits: 0, codes: MP3Tables.codes13, lengths: MP3Tables.lengths13)
        t[15] = HuffmanTable(xlen: 16, linbits: 0, codes: MP3Tables.codes15, lengths: MP3Tables.lengths15)
        for (offset, linbits) in [1, 2, 3, 4, 6, 8, 10, 13].enumerated() {
            t[16 + offset] = HuffmanTable(xlen: 16, linbits: linbits,
                                          codes: MP3Tables.codes16, lengths: MP3Tables.lengths16)
        }
        for (offset, linbits) in [4, 5, 6, 7, 8, 9, 11, 13].enumerated() {
            t[24 + offset] = HuffmanTable(xlen: 16, linbits: linbits,
                                          codes: MP3Tables.codes24, lengths: MP3Tables.lengths24)
        }
        t[32] = HuffmanTable(xlen: 4, linbits: 0, codes: MP3Tables.codes32, lengths: MP3Tables.lengths32)
        t[33] = HuffmanTable(xlen: 4, linbits: 0, codes: MP3Tables.codes33, lengths: MP3Tables.lengths33)
        return t
    }()
}

// MARK: - Bit writer

/// MSB-first bit packing into bytes.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var current: UInt32 = 0
    private var filled = 0
    private(set) var bitCount = 0

    mutating func reset(capacity: Int) {
        bytes.removeAll(keepingCapacity: true)
        bytes.reserveCapacity(capacity)
        current = 0
        filled = 0
        bitCount = 0
    }

    /// Appends the low `count` bits of `value` (count ≤ 32).
    mutating func put(_ value: UInt32, _ count: Int) {
        guard count > 0 else { return }
        var remaining = count
        var v = count == 32 ? value : (value & ((1 << UInt32(count)) - 1))
        while remaining > 0 {
            let room = 8 - filled
            if remaining >= room {
                let shift = remaining - room
                current = (current << UInt32(room)) | (v >> UInt32(shift))
                bytes.append(UInt8(truncatingIfNeeded: current))
                v &= shift == 0 ? 0 : (1 << UInt32(shift)) - 1
                remaining -= room
                current = 0
                filled = 0
            } else {
                current = (current << UInt32(remaining)) | v
                filled += remaining
                remaining = 0
            }
        }
        bitCount += count
    }

    /// Flushes a partial byte with zero bits.
    mutating func padToByte() {
        if filled > 0 { put(0, 8 - filled) }
    }
}

// MARK: - Frame header inspection

extension MP3Encoder {
    /// The fields of one frame header, for tests and self-checks that walk
    /// an encoded stream frame by frame.
    public struct FrameHeader: Equatable, Sendable {
        public let bitrate: Int
        public let sampleRate: Int
        public let channels: Int
        public let padding: Bool
        /// The whole frame, header included, in bytes.
        public let frameBytes: Int

        /// Parses an MPEG-1 Layer III header at `offset`; nil for anything
        /// else (no sync, a reserved field, another layer or version).
        public static func parse(_ data: Data, at offset: Int) -> FrameHeader? {
            guard offset + 4 <= data.count else { return nil }
            let b = data[data.startIndex + offset..<data.startIndex + offset + 4].map { UInt32($0) }
            let word = b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
            guard word >> 21 == 0x7FF,              // sync
                  (word >> 19) & 0b11 == 0b11,      // MPEG-1
                  (word >> 17) & 0b11 == 0b01       // Layer III
            else { return nil }
            let bitrateIndex = Int((word >> 12) & 0xF)
            let rateIndex = Int((word >> 10) & 0b11)
            guard (1...14).contains(bitrateIndex), rateIndex < 3 else { return nil }
            let padding = (word >> 9) & 1 == 1
            let mode = (word >> 6) & 0b11
            let bitrate = MP3Encoder.supportedBitrates[bitrateIndex - 1]
            let sampleRate = MP3Encoder.supportedSampleRates[rateIndex]
            let frameBytes = 144_000 * bitrate / sampleRate + (padding ? 1 : 0)
            return FrameHeader(bitrate: bitrate, sampleRate: sampleRate,
                               channels: mode == 0b11 ? 1 : 2, padding: padding, frameBytes: frameBytes)
        }
    }

    /// Every frame header in `data`, walked from the first byte; stops at
    /// the first byte that isn't a valid header.
    public static func frames(in data: Data) -> [FrameHeader] {
        var headers: [FrameHeader] = []
        var offset = 0
        while let header = FrameHeader.parse(data, at: offset) {
            headers.append(header)
            offset += header.frameBytes
        }
        return headers
    }
}
