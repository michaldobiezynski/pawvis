import Foundation
import XCTest
@testable import PawvisCore

/// The MP3 encoder's bitstream, checked structurally: the frames it writes
/// are the size the header claims, the headers say what was asked for, and
/// the side information inside is self-consistent. Whether the frames
/// *decode to the right sound* is the app self-test's job (`mp3.*` rows),
/// which runs them through AVFoundation — an independent decoder this
/// pure target deliberately does not link.
final class MP3EncoderTests: XCTestCase {
    private func sine(seconds: Double, frequency: Double, sampleRate: Int, amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        return (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / Double(sampleRate))) }
    }

    // MARK: Huffman tables

    /// Every code table must be prefix-free — a code that is the prefix of
    /// another would make the stream undecodable — and Kraft's inequality
    /// must hold. A single mistyped table entry fails this.
    func testHuffmanTablesArePrefixFreeAndComplete() {
        for (index, table) in HuffmanTable.all.enumerated() {
            guard let table else { continue }
            let entries = zip(table.codes, table.lengths).map { (code: UInt32($0), length: Int($1)) }
            XCTAssertEqual(entries.count, table.xlen * table.xlen, "table \(index) is not square")
            var kraft = 0.0
            for (i, a) in entries.enumerated() {
                XCTAssertTrue((1...19).contains(a.length), "table \(index) entry \(i) has length \(a.length)")
                XCTAssertLessThan(a.code, 1 << UInt32(a.length), "table \(index) entry \(i) overflows its length")
                kraft += pow(2, -Double(a.length))
                for (j, b) in entries.enumerated() where i != j && a.length <= b.length {
                    XCTAssertNotEqual(b.code >> UInt32(b.length - a.length), a.code,
                                      "table \(index): entry \(i) is a prefix of entry \(j)")
                }
            }
            XCTAssertLessThanOrEqual(kraft, 1.0000001, "table \(index) violates Kraft")
        }
    }

    /// The escape tables share two code trees with different linbits, in
    /// the standard's order.
    func testEscapeTableLinbits() {
        XCTAssertEqual((16..<24).map { HuffmanTable.all[$0]!.linbits }, [1, 2, 3, 4, 6, 8, 10, 13])
        XCTAssertEqual((24..<32).map { HuffmanTable.all[$0]!.linbits }, [4, 5, 6, 7, 8, 9, 11, 13])
        XCTAssertNil(HuffmanTable.all[0])
        XCTAssertNil(HuffmanTable.all[4])
        XCTAssertNil(HuffmanTable.all[14])
    }

    /// The analysis window is the standard's: 512 taps, peaking at the
    /// documented maximum in the middle.
    func testAnalysisWindowShape() {
        let window = MP3Tables.analysisWindow
        XCTAssertEqual(window.count, 512)
        XCTAssertEqual(window.max()!, 0.035781, accuracy: 1e-9)
        XCTAssertEqual(window.firstIndex(of: 0.035781), 256)
        XCTAssertEqual(MP3Tables.scalefactorBands.count, 3)
        for bands in MP3Tables.scalefactorBands {
            XCTAssertEqual(bands.first, 0)
            XCTAssertEqual(bands.last, 576)
            XCTAssertEqual(bands, bands.sorted())
        }
    }

    // MARK: Bit packing

    func testBitWriterPacksMostSignificantBitFirst() {
        var writer = BitWriter()
        writer.reset(capacity: 4)
        writer.put(0b101, 3)
        writer.put(0b1, 1)
        writer.put(0xFF, 8)
        writer.put(0x7FF, 11)
        XCTAssertEqual(writer.bitCount, 23)
        writer.padToByte()
        XCTAssertEqual(writer.bytes, [0b1011_1111, 0b1111_1111, 0b1111_1110])
        writer.reset(capacity: 4)
        writer.put(0xDEAD_BEEF, 32)
        XCTAssertEqual(writer.bytes, [0xDE, 0xAD, 0xBE, 0xEF])
    }

    // MARK: Configuration

    func testRejectsWhatMPEG1CannotCarry() {
        XCTAssertThrowsError(try MP3Encoder(sampleRate: 96_000, channels: 2)) { error in
            XCTAssertEqual(error as? MP3Encoder.EncodingError, .unsupportedSampleRate(96_000))
        }
        XCTAssertThrowsError(try MP3Encoder(sampleRate: 44_100, channels: 3)) { error in
            XCTAssertEqual(error as? MP3Encoder.EncodingError, .unsupportedChannelCount(3))
        }
        XCTAssertThrowsError(try MP3Encoder(sampleRate: 44_100, channels: 2, bitrate: 200)) { error in
            XCTAssertEqual(error as? MP3Encoder.EncodingError, .unsupportedBitrate(200))
        }
        XCTAssertNoThrow(try MP3Encoder(sampleRate: 32_000, channels: 1, bitrate: 320))
    }

    // MARK: Frames

    /// One second of stereo at 44.1 kHz is 38.28 frames: 39 with the last
    /// one padded, plus the flush frame. Every frame parses, back to back,
    /// with the header fields that were asked for.
    func testFramesParseBackToBackWithTheRequestedHeader() throws {
        let encoder = try MP3Encoder(sampleRate: 44_100, channels: 2, bitrate: 256)
        let left = sine(seconds: 1, frequency: 440, sampleRate: 44_100)
        let right = sine(seconds: 1, frequency: 660, sampleRate: 44_100, amplitude: 0.3)
        encoder.append([left, right])
        let data = encoder.finish()
        let frames = MP3Encoder.frames(in: data)
        XCTAssertEqual(frames.count, 40)
        XCTAssertEqual(encoder.framesEncoded, 40)
        XCTAssertEqual(frames.map(\.frameBytes).reduce(0, +), data.count, "frames must tile the stream exactly")
        for frame in frames {
            XCTAssertEqual(frame.bitrate, 256)
            XCTAssertEqual(frame.sampleRate, 44_100)
            XCTAssertEqual(frame.channels, 2)
        }
    }

    /// Feeding the same audio in odd-sized chunks must produce the same bytes.
    func testChunkingDoesNotChangeTheStream() throws {
        let pcm = sine(seconds: 0.5, frequency: 300, sampleRate: 48_000)
        let whole = try MP3Encoder(sampleRate: 48_000, channels: 1, bitrate: 128)
        whole.append([pcm])
        let reference = whole.finish()

        let chunked = try MP3Encoder(sampleRate: 48_000, channels: 1, bitrate: 128)
        var offset = 0
        var step = 7
        while offset < pcm.count {
            let end = min(offset + step, pcm.count)
            chunked.append([Array(pcm[offset..<end])])
            offset = end
            step = step * 3 % 1000 + 1
        }
        XCTAssertEqual(chunked.finish(), reference)
    }

    /// 48 kHz at 128 kbit/s is exactly 384 bytes a frame: no padding ever.
    /// 44.1 kHz at 128 kbit/s is 417.96: padding must keep the mean there.
    func testPaddingKeepsTheMeanFrameSize() throws {
        let clean = try MP3Encoder(sampleRate: 48_000, channels: 1, bitrate: 128)
        clean.append([sine(seconds: 2, frequency: 500, sampleRate: 48_000)])
        let cleanFrames = MP3Encoder.frames(in: clean.finish())
        XCTAssertFalse(cleanFrames.isEmpty)
        XCTAssertTrue(cleanFrames.allSatisfy { $0.frameBytes == 384 && !$0.padding })

        let padded = try MP3Encoder(sampleRate: 44_100, channels: 1, bitrate: 128)
        padded.append([sine(seconds: 5, frequency: 500, sampleRate: 44_100)])
        let paddedFrames = MP3Encoder.frames(in: padded.finish())
        let mean = Double(paddedFrames.map(\.frameBytes).reduce(0, +)) / Double(paddedFrames.count)
        XCTAssertEqual(mean, 144_000.0 * 128 / 44_100, accuracy: 0.02)
        XCTAssertTrue(paddedFrames.contains { $0.padding })
        XCTAssertTrue(paddedFrames.contains { !$0.padding })
    }

    /// Silence is a valid stream of frames whose granules carry no bits.
    func testSilenceEncodesToEmptyGranules() throws {
        let encoder = try MP3Encoder(sampleRate: 44_100, channels: 1, bitrate: 128)
        encoder.append([[Float](repeating: 0, count: 1152 * 3)])
        let data = encoder.finish()
        let frames = MP3Encoder.frames(in: data)
        XCTAssertEqual(frames.count, 4)
        var offset = 0
        for frame in frames {
            let side = SideInfo.parse(data, at: offset + 4, channels: 1)
            XCTAssertEqual(side.mainDataBegin, 0)
            XCTAssertTrue(side.granules.allSatisfy { $0.part23Length == 0 && $0.bigValues == 0 })
            offset += frame.frameBytes
        }
    }

    /// Real audio: every granule's side information is internally
    /// consistent, and the main data never overruns the frame.
    func testSideInformationIsConsistent() throws {
        for (channels, rate, bitrate) in [(1, 44_100, 64), (2, 48_000, 192), (2, 32_000, 320), (1, 44_100, 320)] {
            let encoder = try MP3Encoder(sampleRate: rate, channels: channels, bitrate: bitrate)
            let seconds = 0.6
            var pcm = [sine(seconds: seconds, frequency: 220, sampleRate: rate, amplitude: 0.9)]
            if channels == 2 {
                // A dense second channel: white-ish noise pushes every
                // region and the escape tables into use.
                var seed: UInt32 = 12345
                pcm.append((0..<pcm[0].count).map { _ in
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    return Float(seed) / Float(UInt32.max) * 1.6 - 0.8
                })
            }
            encoder.append(pcm)
            let data = encoder.finish()
            let frames = MP3Encoder.frames(in: data)
            XCTAssertGreaterThan(frames.count, 10)
            var offset = 0
            var usedTables = Set<Int>()
            var sawBigValues = false
            for frame in frames {
                XCTAssertEqual(frame.channels, channels)
                let sideBytes = channels == 1 ? 17 : 32
                let side = SideInfo.parse(data, at: offset + 4, channels: channels)
                XCTAssertEqual(side.mainDataBegin, 0)
                XCTAssertEqual(side.granules.count, 2 * channels)
                let mainBits = (frame.frameBytes - 4 - sideBytes) * 8
                XCTAssertLessThanOrEqual(side.granules.map(\.part23Length).reduce(0, +), mainBits)
                for g in side.granules {
                    XCTAssertLessThanOrEqual(g.bigValues, 288)
                    XCTAssertLessThanOrEqual(g.part23Length, 4095)
                    XCTAssertEqual(g.windowSwitching, 0)
                    XCTAssertLessThanOrEqual(g.region0Count + g.region1Count + 2, 22)
                    for t in g.tableSelect {
                        XCTAssertFalse([4, 14].contains(t), "reserved Huffman table \(t) selected")
                        usedTables.insert(t)
                    }
                    if g.bigValues > 0 { sawBigValues = true }
                }
                offset += frame.frameBytes
            }
            XCTAssertEqual(offset, data.count)
            XCTAssertTrue(sawBigValues)
            if channels == 2 {
                XCTAssertTrue(usedTables.contains { $0 >= 16 }, "noise should need an escape table")
            }
        }
    }

    /// The tail of the audio survives `finish()`: a partial frame is padded
    /// and one more frame flushes the decoder delay.
    func testFinishPadsThePartialFrameAndFlushes() throws {
        let encoder = try MP3Encoder(sampleRate: 48_000, channels: 1, bitrate: 96)
        encoder.append([sine(seconds: 0.1, frequency: 1000, sampleRate: 48_000)]) // 4800 samples: 4 frames + 192
        XCTAssertEqual(encoder.framesEncoded, 4)
        _ = encoder.finish()
        XCTAssertEqual(encoder.framesEncoded, 6)
        // Reset: a second recording starts from silence again.
        encoder.append([sine(seconds: 0.1, frequency: 1000, sampleRate: 48_000)])
        XCTAssertEqual(encoder.framesEncoded, 10)
    }

    /// Loud tonal input drives the quantizer to its finest usable step,
    /// which is where the escape tables' 13 linbits get used, and the
    /// coder must still land inside every budget.
    func testFullScaleToneStaysWithinBudget() throws {
        let encoder = try MP3Encoder(sampleRate: 44_100, channels: 1, bitrate: 32)
        encoder.append([sine(seconds: 0.5, frequency: 1200, sampleRate: 44_100, amplitude: 1.0)])
        let data = encoder.finish()
        var offset = 0
        for frame in MP3Encoder.frames(in: data) {
            let side = SideInfo.parse(data, at: offset + 4, channels: 1)
            let mainBits = (frame.frameBytes - 4 - 17) * 8
            XCTAssertLessThanOrEqual(side.granules.map(\.part23Length).reduce(0, +), mainBits)
            offset += frame.frameBytes
        }
        XCTAssertEqual(offset, data.count)
    }
}

// MARK: - A side-information reader

/// Reads MPEG-1 Layer III side information the way a decoder does, so the
/// tests judge the encoder's frames by the standard's layout rather than
/// by the encoder's own bookkeeping.
private struct SideInfo {
    struct Granule {
        var part23Length: Int
        var bigValues: Int
        var globalGain: Int
        var scalefacCompress: Int
        var windowSwitching: Int
        var tableSelect: [Int]
        var region0Count: Int
        var region1Count: Int
    }

    var mainDataBegin: Int
    var granules: [Granule]

    static func parse(_ data: Data, at offset: Int, channels: Int) -> SideInfo {
        var reader = BitReader(data: data, byteOffset: offset)
        let mainDataBegin = reader.read(9)
        _ = reader.read(channels == 1 ? 5 : 3)
        for _ in 0..<channels { _ = reader.read(4) } // scfsi
        var granules: [Granule] = []
        for _ in 0..<(2 * channels) {
            let part23 = reader.read(12)
            let big = reader.read(9)
            let gain = reader.read(8)
            let compress = reader.read(4)
            let switching = reader.read(1)
            precondition(switching == 0, "the encoder writes long blocks only")
            let tables = [reader.read(5), reader.read(5), reader.read(5)]
            let r0 = reader.read(4)
            let r1 = reader.read(3)
            _ = reader.read(1) // preflag
            _ = reader.read(1) // scalefac_scale
            _ = reader.read(1) // count1table_select
            granules.append(Granule(part23Length: part23, bigValues: big, globalGain: gain,
                                    scalefacCompress: compress, windowSwitching: switching,
                                    tableSelect: tables, region0Count: r0, region1Count: r1))
        }
        return SideInfo(mainDataBegin: mainDataBegin, granules: granules)
    }
}

private struct BitReader {
    let data: Data
    var bit: Int

    init(data: Data, byteOffset: Int) {
        self.data = data
        bit = byteOffset * 8
    }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = data[data.startIndex + bit / 8]
            value = value << 1 | Int((byte >> (7 - UInt8(bit % 8))) & 1)
            bit += 1
        }
        return value
    }
}
