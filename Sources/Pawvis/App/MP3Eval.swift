import AVFoundation
import Foundation
import PawvisCore

/// `Pawvis --mp3-encode <audio file> <out.mp3> [bitrate]`: encodes any audio
/// file AVFoundation can read (WAV, CAF, AIFF, M4A, …) with the app's own
/// `MP3Encoder`, at 256 kbit/s unless told otherwise.
///
/// The ground-truth harness for the encoder: the unit tests prove the
/// bitstream is well-formed and the self-test proves Apple's decoder reads
/// it back as the same tone, but "does it play everywhere" is a question
/// for decoders that share nothing with either — ffmpeg, a browser, a
/// phone. Encode a known signal here and decode it there.
func runMP3Encode(_ args: [String]) -> Int32 {
    guard args.count >= 2 else {
        print("usage: Pawvis --mp3-encode <audio file> <out.mp3> [bitrate kbit/s]")
        print("bitrates: \(MP3Encoder.supportedBitrates.map(String.init).joined(separator: " "))")
        return 2
    }
    let source = URL(fileURLWithPath: args[0])
    let destination = URL(fileURLWithPath: args[1])
    let bitrate = args.count > 2 ? (Int(args[2]) ?? ThereminAudio.mp3Bitrate) : ThereminAudio.mp3Bitrate
    let started = Date()
    do {
        try ThereminAudio.exportMP3(from: source, to: destination, bitrate: bitrate) { _ in }
    } catch {
        print("FAIL \(error.localizedDescription)")
        return 1
    }
    guard let data = try? Data(contentsOf: destination) else {
        print("FAIL wrote nothing")
        return 1
    }
    let frames = MP3Encoder.frames(in: data)
    guard let first = frames.first else {
        print("FAIL no frames")
        return 1
    }
    let seconds = Double(frames.count * MP3Encoder.samplesPerFrame) / Double(first.sampleRate)
    print(String(format: "OK %@: %d frames, %d bytes, %.2f s, %d kbit/s, %d Hz, %d ch, encoded in %.2f s",
                 destination.lastPathComponent, frames.count, data.count, seconds,
                 first.bitrate, first.sampleRate, first.channels, Date().timeIntervalSince(started)))
    return frames.map(\.frameBytes).reduce(0, +) == data.count ? 0 : 1
}
