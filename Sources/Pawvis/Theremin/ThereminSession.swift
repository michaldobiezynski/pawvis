import AppKit
import Combine
import Foundation
import PawvisCore
import QuartzCore
import UniformTypeIdentifiers

/// What the stage draws at frame rate: the current reading, the level and
/// the oscilloscope. Its own object so the 30 Hz churn re-renders the
/// stage and the readouts, not the whole window.
@MainActor
final class ThereminLiveState: ObservableObject {
    @Published var reading = ThereminReading()
    /// 0…1 peak since the last frame, decayed for the meter.
    @Published var level: Float = 0
    /// The last `ThereminVoiceBox.scopeLength` samples.
    @Published var scope: [Float] = []
}

/// The theremin: hands in, sound out, takes kept. Owned by
/// `PawvisController` (like voice control) so the menu can read its state
/// and the audio graph survives the window closing; the window's controls
/// call into it, and while it is on it holds the camera through
/// `PawvisController.borrowCamera`, so nothing a hand does reaches the
/// mouse.
///
/// Rules, each deliberate:
///
/// - **Switching on borrows the camera; the window closing switches off.**
///   An instrument that kept the camera (and mouse control parked) with no
///   window in sight would read as Pawvis being broken.
/// - **A take outlives the window.** Closing the window stops a recording
///   in progress but keeps it; the next opening finds it, playable and
///   exportable. A new recording replaces it, and Discard drops it.
/// - **Settings are the player's, and persist.** The tone, range, scale and
///   layout live in `settings.theremin`; power, recording and playback are
///   transient here and never written anywhere.
/// - **The demo feed never opens the camera or the speakers.**
///   `PAWVIS_THEREMIN_DEMO=<playing|recording|take>` synthesizes a
///   two-handed performance and mutes the output (the recording tap sits
///   upstream of the mute, so a demo take is real audio), so a screenshot
///   machine shows the instrument being played without a hand in the room
///   or a note out of the speakers.
@MainActor
final class ThereminSession: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case recording
        /// A finished take, ready to play or export.
        case take
        case playing
    }

    enum ExportFormat: String, CaseIterable {
        case mp3, wav

        var displayName: String {
            switch self {
            case .mp3: return "MP3 (256 kbit/s)"
            case .wav: return "WAV (24-bit)"
            }
        }

        var contentType: UTType {
            switch self {
            case .mp3: return .mp3
            case .wav: return .wav
            }
        }
    }

    enum ExportStatus: Equatable {
        case exporting(Double)
        case saved(URL)
        case failed(String)
    }

    /// The `PAWVIS_THEREMIN_DEMO` states.
    enum Demo: String {
        case playing, recording, take
    }

    @Published private(set) var isOn = false
    @Published private(set) var recordingState: RecordingState = .idle
    /// Seconds recorded so far (while recording) or the take's length.
    @Published private(set) var takeSeconds: TimeInterval = 0
    /// One peak per 20 ms of the take, for the strip.
    @Published private(set) var takePeaks: [Float] = []
    @Published private(set) var exportStatus: ExportStatus?
    /// The gesture trainer holds the camera, so switching on did nothing.
    @Published private(set) var cameraBusy = false
    /// The output device refused to start.
    @Published private(set) var audioFailed = false

    let live = ThereminLiveState()

    private weak var controller: PawvisController?
    private let audio = ThereminAudio()
    private var tracker: ThereminTracker
    private var takeURL: URL?
    private var recorder: ThereminAudio.TakeRecorder?
    private var settingsObservation: AnyCancellable?
    private var frameTimer: Timer?
    private var recordingStartedAt: TimeInterval?
    private var lastFrameTime: TimeInterval = -.greatestFiniteMagnitude
    private(set) var demo: Demo?
    private var demoStartedAt: TimeInterval = 0
    private var demoTakeStopped = false

    init() {
        tracker = ThereminTracker(config: ThereminConfig(), mirror: true)
        demo = ProcessInfo.processInfo.environment["PAWVIS_THEREMIN_DEMO"].flatMap(Demo.init(rawValue:))
        audio.onPlaybackEnded = { [weak self] in self?.playbackEnded() }
    }

    /// The controller wires itself in after its own init.
    func attach(controller: PawvisController) {
        self.controller = controller
        applySettings(controller.settingsStore.settings)
        settingsObservation = controller.settingsStore.$settings
            .removeDuplicates()
            .sink { [weak self] settings in self?.applySettings(settings) }
    }

    private func applySettings(_ settings: PawvisSettings) {
        tracker.config = settings.theremin
        tracker.mirror = settings.gestures.mirrorCamera
        audio.setTone(ThereminVoice.Tone(settings.theremin), reverbMix: settings.theremin.reverb)
    }

    var config: ThereminConfig {
        controller?.settingsStore.settings.theremin ?? ThereminConfig()
    }

    var hasTake: Bool {
        recordingState == .take || recordingState == .playing
    }

    // MARK: - Power

    func setPower(_ on: Bool) {
        on ? powerOn() : powerOff()
    }

    func powerOn() {
        guard !isOn else { return }
        guard let controller else { return }
        tracker.reset()
        audioFailed = !audio.start()
        audio.setOutputMuted(demo != nil)
        if demo == nil {
            cameraBusy = !controller.borrowCamera(for: .theremin)
            controller.thereminFrameTap = { [weak self] hands, time in
                self?.consume(hands: hands, at: time)
            }
        } else {
            cameraBusy = false
            demoStartedAt = CACurrentMediaTime()
            demoTakeStopped = false
        }
        isOn = true
        startFrameTimer()
        Log.app.info("Theremin on")
    }

    func powerOff() {
        guard isOn else { return }
        if recordingState == .recording { stopRecording() }
        isOn = false
        controller?.returnCamera(from: .theremin)
        audio.play(frequency: nil, amplitude: 0)
        if recordingState != .playing { audio.stop() }
        live.reading = ThereminReading()
        live.level = 0
        live.scope = []
        cameraBusy = false
        if recordingState != .playing { frameTimer?.invalidate(); frameTimer = nil }
        Log.app.info("Theremin off")
    }

    /// The window is going away: stop playing and switch off, keeping any take.
    func windowClosed() {
        stopPlayback()
        powerOff()
    }

    /// The window appeared: the demo feed plays itself.
    func windowOpened() {
        if demo != nil, !isOn { powerOn() }
    }

    /// The app is quitting.
    func shutdown() {
        stopPlayback()
        powerOff()
        discardTake()
    }

    // MARK: - Frames

    private func consume(hands: [Hand], at time: TimeInterval) {
        guard isOn else { return }
        lastFrameTime = time
        let reading = tracker.update(hands: hands, at: time)
        audio.play(frequency: reading.frequency, amplitude: reading.amplitude)
        live.reading = reading
    }

    /// 30 Hz: the scope and meter for the stage, the recording clock, and
    /// in demo mode the synthetic hands.
    private func startFrameTimer() {
        frameTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if isOn, demo != nil { synthesizeDemo(at: now) }
        if isOn, demo == nil, now - lastFrameTime > 1.0, live.reading != ThereminReading() {
            // Frames stopped (the camera paused or was lost): silence, and
            // an empty stage rather than a hand frozen in place.
            audio.play(frequency: nil, amplitude: 0)
            live.reading = ThereminReading()
        }
        let (scope, peak) = audio.box.snapshot()
        live.scope = scope
        live.level = max(peak, live.level * 0.85)
        if recordingState == .recording, let recorder {
            takeSeconds = recorder.duration
            let peaks = recorder.snapshotPeaks()
            if peaks.count != takePeaks.count { takePeaks = peaks }
        }
    }

    // MARK: - Recording

    private static let takeDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Pawvis Theremin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var canRecord: Bool { isOn && recordingState != .playing }

    func startRecording() {
        guard canRecord, recordingState != .recording else { return }
        guard audio.isRunning || audio.start() else {
            exportStatus = .failed("The audio engine isn't running.")
            return
        }
        discardTake()
        let url = Self.takeDirectory.appendingPathComponent("Take \(UUID().uuidString).caf")
        do {
            recorder = try audio.startRecording(to: url)
            takeURL = url
            takePeaks = []
            takeSeconds = 0
            recordingStartedAt = CACurrentMediaTime()
            recordingState = .recording
            exportStatus = nil
            Log.app.info("Theremin recording started")
        } catch {
            exportStatus = .failed("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard recordingState == .recording else { return }
        let finished = audio.stopRecording()
        recorder = nil
        takeSeconds = finished?.duration ?? takeSeconds
        takePeaks = finished?.snapshotPeaks() ?? takePeaks
        recordingState = takeSeconds > 0.05 ? .take : .idle
        if recordingState == .idle { discardTake() }
        Log.app.info("Theremin recording stopped: \(self.takeSeconds, format: .fixed(precision: 1)) s")
    }

    func toggleRecording() {
        recordingState == .recording ? stopRecording() : startRecording()
    }

    func discardTake() {
        if recordingState == .playing { stopPlayback() }
        if recordingState == .recording { stopRecording() }
        if let takeURL { try? FileManager.default.removeItem(at: takeURL) }
        takeURL = nil
        if recordingState != .recording {
            recordingState = .idle
            takePeaks = []
            takeSeconds = 0
        }
        if case .exporting = exportStatus {} else { exportStatus = nil }
    }

    // MARK: - Playback

    func play() {
        guard recordingState == .take, let takeURL else { return }
        do {
            try audio.play(take: takeURL)
            recordingState = .playing
            if frameTimer == nil { startFrameTimer() }
        } catch {
            exportStatus = .failed("Couldn't play the take: \(error.localizedDescription)")
        }
    }

    func stopPlayback() {
        guard recordingState == .playing else { return }
        audio.stopPlayback()
        playbackEnded()
    }

    private func playbackEnded() {
        guard recordingState == .playing else { return }
        recordingState = .take
        if !isOn {
            audio.stop()
            frameTimer?.invalidate()
            frameTimer = nil
            live.scope = []
            live.level = 0
        }
    }

    func togglePlayback() {
        recordingState == .playing ? stopPlayback() : play()
    }

    // MARK: - Export

    /// Asks where to save, then encodes off the main thread with progress.
    func export(_ format: ExportFormat) {
        guard hasTake, let takeURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Theremin Take"
        panel.nameFieldStringValue = Self.suggestedName(format: format)
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        // LSUIElement: the panel needs the app in front to be seen at all.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in self?.runExport(format, from: takeURL, to: destination) }
        }
    }

    private static func suggestedName(format: ExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Theremin \(formatter.string(from: Date())).\(format.rawValue)"
    }

    private func runExport(_ format: ExportFormat, from source: URL, to destination: URL) {
        exportStatus = .exporting(0)
        let report: @Sendable (Double) -> Void = { fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = ThereminSession.exporting else { return }
                    if case .exporting = self.exportStatus { self.exportStatus = .exporting(fraction) }
                }
            }
        }
        Self.exporting = self
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error>
            do {
                switch format {
                case .mp3: try ThereminAudio.exportMP3(from: source, to: destination, progress: report)
                case .wav: try ThereminAudio.exportWAV(from: source, to: destination, progress: report)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = ThereminSession.exporting else { return }
                    ThereminSession.exporting = nil
                    switch result {
                    case .success:
                        self.exportStatus = .saved(destination)
                        Log.app.info("Theremin take exported: \(destination.lastPathComponent, privacy: .public)")
                    case .failure(let error):
                        self.exportStatus = .failed(error.localizedDescription)
                        Log.app.error("Theremin export failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// The session with an export in flight (one at a time: the Export
    /// menu is disabled while `exportStatus` is `.exporting`).
    private static weak var exporting: ThereminSession?

    func revealExport() {
        if case .saved(let url) = exportStatus {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func clearExportStatus() {
        if case .exporting = exportStatus { return }
        exportStatus = nil
    }

    // MARK: - The demo feed

    /// Two synthetic hands playing a slow phrase: the pitch hand walks a
    /// little melody across the zone with glides between notes, the volume
    /// hand swells. `recording` starts a take half a second in; `take`
    /// stops it five seconds later so the strip shows a finished take.
    private func synthesizeDemo(at now: TimeInterval) {
        guard let demo else { return }
        let t = now - demoStartedAt
        let mirror = tracker.mirror
        // Melody as pitch-zone positions, one per beat, eased between.
        let melody: [Double] = [0.18, 0.32, 0.45, 0.62, 0.55, 0.72, 0.9, 0.62]
        let beat = 1.1
        let index = Int(t / beat) % melody.count
        let next = (index + 1) % melody.count
        let phase = (t.truncatingRemainder(dividingBy: beat)) / beat
        let eased = phase < 0.75 ? 0 : (phase - 0.75) / 0.25
        let smooth = eased * eased * (3 - 2 * eased)
        let pitchPosition = melody[index] + (melody[next] - melody[index]) * smooth
        let zone = ThereminTracker.pitchZone
        let pitchX = zone.lowerBound + (zone.upperBound - zone.lowerBound) * pitchPosition
        let pitchPalm = Vec2(pitchX, 0.52 + 0.02 * sin(t * 1.7))
        let vzone = ThereminTracker.volumeZone
        let swell = 0.62 + 0.22 * sin(t * 0.9)
        let volumeY = vzone.upperBound - (vzone.upperBound - vzone.lowerBound) * swell
        let volumePalm = Vec2(0.22 + 0.015 * sin(t * 1.3), volumeY)
        // View space → camera space, undoing the mirror the tracker applies.
        func camera(_ view: Vec2) -> Vec2 { mirror ? Vec2(1 - view.x, view.y) : view }
        // A hand-sized hand: the practice mirror's 0.16 fills a small panel,
        // but on the stage it would span a third of the frame.
        let scale = 0.11
        let hands = [
            DemoHand.open(wrist: DemoHand.wrist(forPalm: camera(pitchPalm), scale: scale), scale: scale),
            DemoHand.open(wrist: DemoHand.wrist(forPalm: camera(volumePalm), scale: scale), scale: scale),
        ]
        consume(hands: hands, at: now)

        switch demo {
        case .playing:
            break
        case .recording:
            if t > 0.5, recordingState == .idle, !demoTakeStopped { startRecording() }
        case .take:
            if t > 0.5, recordingState == .idle, !demoTakeStopped { startRecording() }
            if t > 5.5, recordingState == .recording {
                stopRecording()
                demoTakeStopped = true
            }
        }
    }
}
