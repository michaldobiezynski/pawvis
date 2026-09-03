import AppKit
import PawvisCore
import SwiftUI

// MARK: - Opening the window from code

/// Opening the theremin with no SwiftUI environment (the menu's chip, the
/// `PAWVIS_OPEN_THEREMIN` hook), same shape and reason as `GuideWindow`.
@MainActor
enum ThereminWindow {
    static let id = "theremin"

    static var opener: OpenWindowAction?

    static func show() {
        opener?(id: id)
        // LSUIElement, so opening a window doesn't bring the app forward on
        // its own — see SettingsWindow for why activation happens twice.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - The window

/// The theremin window: the instrument on the left (stage, tuner, scope,
/// the recording strip), its controls on the right. Power is the switch in
/// the header; while it is on, the hands play the instrument and the mouse
/// is left alone.
struct ThereminView: View {
    @ObservedObject var controller: PawvisController
    @ObservedObject var session: ThereminSession
    @ObservedObject var store: SettingsStore

    init(controller: PawvisController) {
        self.controller = controller
        session = controller.theremin
        store = controller.settingsStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 16) {
                instrument
                    .frame(minWidth: 620, maxWidth: .infinity)
                controls
                    .frame(width: 312)
            }
        }
        .padding(20)
        .frame(minWidth: 1000, minHeight: 690)
        .tint(PawvisTheme.accentUI)
        .onAppear { session.windowOpened() }
        .onDisappear { session.windowClosed() }
    }

    // MARK: Header

    private static let clawGlyph = PawvisGlyph.claw(size: 26)

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let claw = Self.clawGlyph {
                    Image(nsImage: claw).renderingMode(.template)
                } else {
                    Image(systemName: "pawprint.fill").font(.title)
                }
            }
            .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Theremin").font(.title.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Text(session.isOn ? "On" : "Off")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(session.isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Toggle("", isOn: Binding(
                    get: { session.isOn },
                    set: { session.setPower($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
                    .help("Switch the theremin on: your hands play it, and the mouse is left alone.")
            }
        }
    }

    private var subtitle: String {
        if controller.cameraPermission == .denied {
            return "Camera access is denied, so there is nothing to play with. Enable Pawvis under Privacy & Security → Camera."
        }
        if session.cameraBusy {
            return "The gesture trainer has the camera. Close it, then switch the theremin on again."
        }
        if session.audioFailed {
            return "The sound output couldn't be started. Check your output device, then switch the theremin off and on."
        }
        guard session.isOn else {
            return "Switched off. Your hands are the mouse again; switch on to play."
        }
        return config.layout == .twoHands
            ? "Pitch hand toward the antenna on the right, volume hand over the loop on the left. Mouse control is paused while this is on."
            : "One hand: left to right is pitch, low to high is volume. Mouse control is paused while this is on."
    }

    private var config: ThereminConfig { store.settings.theremin }

    // MARK: The instrument

    private var instrument: some View {
        VStack(alignment: .leading, spacing: 12) {
            ThereminStage(
                live: session.live,
                controller: controller,
                isOn: session.isOn,
                showCamera: config.showCamera && session.demo == nil,
                mirrored: store.settings.gestures.mirrorCamera,
                config: config,
                placard: placard)
            HStack(alignment: .top, spacing: 12) {
                card(title: "Note") {
                    ThereminNoteReadout(live: session.live)
                }
                .frame(width: 250)
                card(title: "Scope") {
                    ThereminOscilloscope(live: session.live)
                        .frame(height: 84)
                }
            }
            recordingCard
        }
    }

    private var placard: String? {
        if !session.isOn { return "Switch the theremin on to play." }
        if session.cameraBusy || controller.cameraPermission == .denied { return nil }
        if session.demo == nil, session.live.reading.hands.isEmpty, !session.live.reading.isSounding {
            return config.layout == .twoHands
                ? "Show your hands to the camera. Right hand: pitch. Left hand: volume."
                : "Show a hand to the camera."
        }
        return nil
    }

    // MARK: Recording

    private var recordingCard: some View {
        card(title: "Recording") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        session.toggleRecording()
                    } label: {
                        Label(session.recordingState == .recording ? "Stop" : "Record",
                              systemImage: session.recordingState == .recording ? "stop.fill" : "record.circle")
                            .frame(minWidth: 74)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(session.recordingState == .recording ? PawvisTheme.attentionUI : PawvisTheme.accentUI)
                    .disabled(!session.canRecord)
                    .help(session.isOn ? "Record what you play, reverb included." : "Switch the theremin on to record.")

                    Text(Self.clock(session.takeSeconds))
                        .font(.title3.monospacedDigit().weight(.medium))
                        .foregroundStyle(session.recordingState == .recording ? PawvisTheme.attentionUI : .primary)
                        .frame(minWidth: 64, alignment: .leading)

                    Button {
                        session.togglePlayback()
                    } label: {
                        Label(session.recordingState == .playing ? "Stop" : "Play",
                              systemImage: session.recordingState == .playing ? "stop.fill" : "play.fill")
                            .frame(minWidth: 60)
                    }
                    .disabled(!session.hasTake)

                    Menu {
                        ForEach(ThereminSession.ExportFormat.allCases, id: \.self) { format in
                            Button("\(format.displayName)…") { session.export(format) }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .fixedSize()
                    .disabled(!session.hasTake || isExporting)

                    Spacer()

                    Button("Discard") { session.discardTake() }
                        .disabled(!session.hasTake || isExporting)
                }
                ThereminTakeStrip(peaks: session.takePeaks, recording: session.recordingState == .recording)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                exportLine
            }
        }
    }

    private var isExporting: Bool {
        if case .exporting = session.exportStatus { return true }
        return false
    }

    @ViewBuilder
    private var exportLine: some View {
        switch session.exportStatus {
        case .exporting(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 140)
                Text("Encoding…").font(.caption).foregroundStyle(.secondary)
            }
        case .saved(let url):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Saved \(url.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Show in Finder") { session.revealExport() }
                    .controlSize(.small)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case nil:
            Text(session.hasTake
                 ? "Export writes the take as MP3 (encoded right here, nothing leaves your Mac) or 24-bit WAV."
                 : "Record captures exactly what you hear, reverb included. A take stays until you record over it or discard it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        let tenths = Int((seconds - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }

    // MARK: Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                soundCard
                pitchCard
                handsCard
                Text("While the theremin is on, hand tracking plays the instrument and never touches the mouse. Switch it off (or close this window) to point again. Recordings and exports never leave your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    private var theremin: Binding<ThereminConfig> { $store.settings.theremin }

    private var soundCard: some View {
        card(title: "Sound") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(title: "Voice") {
                    Picker("", selection: theremin.waveform) {
                        ForEach(ThereminWaveform.allCases, id: \.self) { waveform in
                            Text(waveform.displayName).tag(waveform)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                LabeledSlider(label: "Brightness", caption: nil, value: theremin.brightness, range: 0...1)
                LabeledSlider(
                    label: "Vibrato depth",
                    caption: config.vibratoDepth < 0.005
                        ? "Off. Your own hand adds the natural wobble."
                        : String(format: "±%.0f cents at %.1f Hz.", config.vibratoDepth * 100, config.vibratoRate),
                    value: theremin.vibratoDepth, range: 0...0.5)
                LabeledSlider(label: "Vibrato speed", caption: nil, value: theremin.vibratoRate, range: 2...9)
                LabeledSlider(label: "Reverb", caption: nil, value: theremin.reverb, range: 0...1)
                LabeledSlider(label: "Volume", caption: nil, value: theremin.volume, range: 0...1)
            }
        }
    }

    private var pitchCard: some View {
        card(title: "Pitch") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Range",
                    caption: "\(MusicTheory.noteName(midi: config.lowNote)) at the left edge of the pitch zone, up to \(MusicTheory.noteName(midi: config.highNote)) at the antenna. Fewer octaves means more room per note."
                ) {
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            Text(MusicTheory.noteName(midi: config.lowNote))
                                .font(.callout.monospacedDigit())
                                .frame(minWidth: 34, alignment: .leading)
                            Stepper("", value: theremin.lowNote, in: ThereminConfig.lowNoteRange)
                                .labelsHidden()
                        }
                        HStack(spacing: 6) {
                            Text("\(config.octaves) oct")
                                .font(.callout.monospacedDigit())
                                .frame(minWidth: 40, alignment: .leading)
                            Stepper("", value: theremin.octaves, in: ThereminConfig.octaveRange)
                                .labelsHidden()
                        }
                    }
                }
                SettingRow(
                    title: "Snap to scale",
                    caption: config.scale == .free
                        ? "Off is the real instrument: every pitch in between the notes. A scale pulls the pitch toward its notes, which is how a theremin gets played in tune."
                        : "Notes of the scale act as magnets. Full strength snaps outright; less keeps glides and vibrato alive."
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: theremin.scale) {
                            ForEach(ThereminScale.allCases, id: \.self) { scale in
                                Text(scale.displayName).tag(scale)
                            }
                        }
                        .frame(maxWidth: 170)
                        Picker("", selection: theremin.key) {
                            ForEach(0..<12, id: \.self) { key in
                                Text(MusicTheory.noteNames[key]).tag(key)
                            }
                        }
                        .frame(width: 70)
                        .disabled(config.scale == .free)
                    }
                }
                LabeledSlider(label: "Snap strength", caption: nil, value: theremin.snapStrength, range: 0...1)
                    .disabled(config.scale == .free)
                LabeledSlider(
                    label: "Glide",
                    caption: String(format: "%.0f ms. Left is direct; right slides between pitches like a slow portamento.", config.glide * 1000),
                    value: theremin.glide, range: 0.005...0.5)
            }
        }
    }

    private var handsCard: some View {
        card(title: "Hands") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Layout",
                    caption: config.layout == .twoHands
                        ? "The right-most hand plays pitch, the other volume. With no volume hand the last level holds (full to begin with), so one hand can play alone."
                        : "One hand does both: its position across the zone is pitch, its height is volume."
                ) {
                    Picker("", selection: theremin.layout) {
                        ForEach(ThereminLayout.allCases, id: \.self) { layout in
                            Text(layout.displayName).tag(layout)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                SettingToggle(
                    title: "Close the volume hand to mute",
                    caption: "A fist cuts the sound for staccato, something the real instrument can't do. Off by default so a misread fist can't cut a held note.",
                    isOn: theremin.fistMutes)
                SettingToggle(
                    title: "Show the camera behind the instrument",
                    caption: "Helps find the zones. Mirroring follows Settings → General → Mirror camera.",
                    isOn: theremin.showCamera)
            }
        }
    }

    // MARK: Shared pieces

    private func card(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - The menu's status

/// The theremin row's live text in the menu bar dropdown, observing the
/// 30 Hz state on its own so the rest of the menu does not re-render with it.
struct ThereminMenuStatus: View {
    @ObservedObject var session: ThereminSession
    @ObservedObject var live: ThereminLiveState

    var body: some View {
        Text(text)
            .font(.callout)
            .lineLimit(2)
    }

    private var text: String {
        guard session.isOn else { return "Theremin off" }
        if session.recordingState == .recording {
            return "Theremin recording · \(ThereminView.clock(session.takeSeconds))"
        }
        if live.reading.isSounding, let note = live.reading.note, let frequency = live.reading.frequency {
            return "Theremin · \(note.label) · \(String(format: "%.0f Hz", frequency))"
        }
        return "Theremin on"
    }
}
