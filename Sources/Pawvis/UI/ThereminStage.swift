import AVFoundation
import PawvisCore
import SwiftUI

// MARK: - The stage

/// The instrument: the camera (mirrored, dimmed) with the theremin drawn
/// over it in view space — the pitch antenna standing at the right, the
/// volume loop lying at the bottom left, a ruler of notes across the pitch
/// zone, and the player's hands as the trainer draws them (a colour per
/// fingertip, a ring on the palm). Dark in both appearances on purpose: it
/// is a stage, and the camera behind it is dark anyway.
struct ThereminStage: View {
    @ObservedObject var live: ThereminLiveState
    let controller: PawvisController
    let isOn: Bool
    let showCamera: Bool
    let mirrored: Bool
    let config: ThereminConfig
    let placard: String?

    var body: some View {
        GeometryReader { geometry in
            let frame = CGRect(origin: .zero, size: geometry.size)
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.07, blue: 0.14), Color(red: 0.04, green: 0.03, blue: 0.07)],
                    startPoint: .top, endPoint: .bottom)
                if isOn, showCamera {
                    ThereminCameraPreview(controller: controller)
                        .scaleEffect(x: mirrored ? -1 : 1)
                        .opacity(0.5)
                        .saturation(0.25)
                }
                StageDrawing(reading: live.reading, level: live.level, config: config, isOn: isOn, frame: frame)
                if let placard {
                    VStack(spacing: 8) {
                        Image(systemName: isOn ? "hand.raised.fill" : "power")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                        Text(placard)
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 320)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.5)))
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// The drawn instrument. A plain `Canvas` over the whole stage: the camera
/// is aspect-fit at 16:9 and so is the stage, so view space maps straight
/// onto the frame.
private struct StageDrawing: View {
    let reading: ThereminReading
    let level: Float
    let config: ThereminConfig
    let isOn: Bool
    let frame: CGRect

    private static let volumeColor = Color(nsColor: PawvisTheme.blueLight)
    private static let volumeLoopX = 0.16

    var body: some View {
        Canvas { context, _ in
            drawPitchRuler(&context)
            drawAntenna(&context)
            drawVolumeLoop(&context)
            drawHands(&context)
        }
        .allowsHitTesting(false)
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: frame.minX + CGFloat(x) * frame.width, y: frame.minY + CGFloat(y) * frame.height)
    }

    private func point(_ v: Vec2) -> CGPoint { point(v.x, v.y) }

    // MARK: The pitch antenna and ruler

    private var antennaX: Double { ThereminTracker.pitchZone.upperBound + 0.035 }

    private func drawAntenna(_ context: inout GraphicsContext) {
        let top = point(antennaX, 0.1)
        let bottom = point(antennaX, 0.97)
        // The field: a glow that brightens as the pitch hand nears.
        let nearness = reading.pitchPosition ?? 0
        if isOn {
            var glow = Path()
            glow.move(to: top)
            glow.addLine(to: bottom)
            context.stroke(glow, with: .color(PawvisTheme.accentUI.opacity(0.08 + 0.35 * nearness)),
                           style: StrokeStyle(lineWidth: 18 + 30 * nearness, lineCap: .round))
        }
        var rod = Path()
        rod.move(to: top)
        rod.addLine(to: bottom)
        context.stroke(rod, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.95), Color(white: 0.7), Color(white: 0.5)]),
            startPoint: CGPoint(x: top.x - 2, y: top.y), endPoint: CGPoint(x: top.x + 2, y: top.y)),
                       style: StrokeStyle(lineWidth: 4, lineCap: .round))
        let knob = CGRect(x: top.x - 5, y: top.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: knob), with: .color(.white.opacity(0.9)))
        // The base plate.
        let base = CGRect(x: bottom.x - 14, y: bottom.y - 3, width: 28, height: 6)
        context.fill(Path(roundedRect: base, cornerRadius: 3), with: .color(Color(white: 0.55)))
    }

    private func drawPitchRuler(_ context: inout GraphicsContext) {
        let zone = ThereminTracker.pitchZone
        let low = config.lowNote
        let high = config.highNote
        let span = Double(high - low)
        let y = 0.085
        func x(forNote note: Int) -> Double {
            zone.lowerBound + (zone.upperBound - zone.lowerBound) * Double(note - low) / span
        }
        // The rail.
        var rail = Path()
        rail.move(to: point(zone.lowerBound, y))
        rail.addLine(to: point(zone.upperBound, y))
        context.stroke(rail, with: .color(.white.opacity(0.28)), lineWidth: 1)

        let scaleDegrees = config.scale.intervals.map { intervals -> Set<Int> in
            Set(intervals.map { ($0 + config.key) % 12 })
        }
        for note in low...high {
            let degree = ((note % 12) + 12) % 12
            let isC = degree == 0
            let inScale = scaleDegrees?.contains(degree) ?? true
            let height: Double = isC ? 0.05 : (inScale ? 0.028 : 0.015)
            let alpha = inScale ? (isC ? 0.9 : 0.55) : 0.2
            var tick = Path()
            tick.move(to: point(x(forNote: note), y))
            tick.addLine(to: point(x(forNote: note), y + height))
            context.stroke(tick, with: .color(.white.opacity(alpha)), lineWidth: isC ? 1.5 : 1)
            if isC || (span <= 24 && inScale && degree % 12 == 7) {
                let label = Text(MusicTheory.noteName(midi: note))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
                context.draw(context.resolve(label), at: point(x(forNote: note), y - 0.03), anchor: .center)
            }
        }
        // The played pitch, as a marker on the rail.
        if let midi = reading.midi, reading.isSounding {
            let fraction = min(max((midi - Double(low)) / span, 0), 1)
            let mx = zone.lowerBound + (zone.upperBound - zone.lowerBound) * fraction
            let marker = point(mx, y)
            context.fill(Path(ellipseIn: CGRect(x: marker.x - 9, y: marker.y - 9, width: 18, height: 18)),
                         with: .color(PawvisTheme.accentUI.opacity(0.35)))
            context.fill(Path(ellipseIn: CGRect(x: marker.x - 4.5, y: marker.y - 4.5, width: 9, height: 9)),
                         with: .color(PawvisTheme.accentUI))
        }
    }

    // MARK: The volume loop

    private func drawVolumeLoop(_ context: inout GraphicsContext) {
        let zone = ThereminTracker.volumeZone
        let loopCenter = point(Self.volumeLoopX, zone.upperBound + 0.05)
        let loopRect = CGRect(x: loopCenter.x - frame.width * 0.085, y: loopCenter.y - frame.height * 0.028,
                              width: frame.width * 0.17, height: frame.height * 0.056)
        if isOn {
            let glow = CGFloat(max(0, 1 - (reading.volumePosition ?? 1)))
            context.stroke(Path(ellipseIn: loopRect.insetBy(dx: -4, dy: -4)),
                           with: .color(Self.volumeColor.opacity(0.1 + 0.3 * glow)), lineWidth: 10)
        }
        context.stroke(Path(ellipseIn: loopRect), with: .linearGradient(
            Gradient(colors: [.white.opacity(0.9), Color(white: 0.55)]),
            startPoint: CGPoint(x: loopRect.minX, y: loopRect.minY), endPoint: CGPoint(x: loopRect.maxX, y: loopRect.maxY)),
                       lineWidth: 3)
        // The height guide, with the level filled up to the hand.
        let guideX = Self.volumeLoopX
        var guide = Path()
        guide.move(to: point(guideX, zone.lowerBound))
        guide.addLine(to: point(guideX, zone.upperBound))
        context.stroke(guide, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        if isOn, let position = reading.volumePosition ?? (reading.isSounding ? reading.amplitude.squareRoot() : nil) {
            let top = point(guideX, zone.upperBound - (zone.upperBound - zone.lowerBound) * position)
            var fill = Path()
            fill.move(to: top)
            fill.addLine(to: point(guideX, zone.upperBound))
            context.stroke(fill, with: .color(Self.volumeColor.opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        // The live level beside it.
        if isOn {
            let meterHeight = CGFloat(min(1, Double(level) * 1.6)) * frame.height * (zone.upperBound - zone.lowerBound)
            let meter = CGRect(x: point(guideX, 0).x - 16, y: point(0, zone.upperBound).y - meterHeight,
                               width: 4, height: meterHeight)
            context.fill(Path(roundedRect: meter, cornerRadius: 2), with: .color(PawvisTheme.attentionUI.opacity(0.85)))
        }
    }

    // MARK: Hands

    private func drawHands(_ context: inout GraphicsContext) {
        for hand in reading.hands {
            let palm = point(hand.palm)
            let ringColor = hand.role == .pitch ? PawvisTheme.accentUI : Self.volumeColor
            if hand.role == .pitch, isOn {
                // The field line to the antenna.
                var line = Path()
                line.move(to: palm)
                line.addLine(to: point(antennaX, hand.palm.y))
                context.stroke(line, with: .color(PawvisTheme.accentUI.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
            }
            for (index, tip) in hand.fingertips.enumerated() {
                let p = point(tip)
                let color = PawvisTheme.fingerDotsUI[min(index, PawvisTheme.fingerDotsUI.count - 1)]
                // A bone from the palm, so the dots read as one hand.
                var bone = Path()
                bone.move(to: palm)
                bone.addLine(to: p)
                context.stroke(bone, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(color))
            }
            let radius: CGFloat = hand.closed ? 10 : 8
            context.stroke(Path(ellipseIn: CGRect(x: palm.x - radius, y: palm.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(ringColor), lineWidth: 3)
            if hand.closed {
                context.fill(Path(ellipseIn: CGRect(x: palm.x - 4, y: palm.y - 4, width: 8, height: 8)), with: .color(ringColor))
            }
            let label = Text(hand.role == .pitch ? "pitch" : "volume")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(ringColor.opacity(0.9))
            context.draw(context.resolve(label), at: CGPoint(x: palm.x, y: palm.y + 22), anchor: .center)
        }
    }
}

// MARK: - The camera behind the stage

/// The AVCaptureVideoPreviewLayer host, unmirrored: the stage flips it (and
/// only it) when the camera is mirrored, since the drawn marks are already
/// in view space.
private struct ThereminCameraPreview: NSViewRepresentable {
    let controller: PawvisController

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(layer: controller.makeCameraPreviewLayer())
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {}

    final class PreviewHostView: NSView {
        private var previewLayer: AVCaptureVideoPreviewLayer?

        func attach(layer: AVCaptureVideoPreviewLayer) {
            wantsLayer = true
            self.layer = CALayer()
            self.layer?.addSublayer(layer)
            previewLayer = layer
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - The tuner

/// The note being played, large, with how far off it the pitch sits and the
/// frequency: what a player tuning by ear wants at a glance.
struct ThereminNoteReadout: View {
    @ObservedObject var live: ThereminLiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(live.reading.isSounding ? (live.reading.note?.label ?? "–") : "–")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(live.reading.isSounding ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(minWidth: 84, alignment: .leading)
                if let frequency = live.reading.frequency, live.reading.isSounding {
                    Text(String(format: "%.1f Hz", frequency))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            centsNeedle
        }
    }

    private var centsNeedle: some View {
        let cents = live.reading.isSounding ? (live.reading.note?.cents ?? 0) : 0
        let inTune = abs(cents) <= 5
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let center = width / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 6)
                    Rectangle().fill(.secondary).frame(width: 1, height: 12).offset(x: center)
                    if live.reading.isSounding {
                        Circle()
                            .fill(inTune ? Color.green : PawvisTheme.accentUI)
                            .frame(width: 12, height: 12)
                            .offset(x: center - 6 + CGFloat(cents) / 50 * (center - 6))
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)
            HStack {
                Text("−50¢").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(live.reading.isSounding ? String(format: "%+d¢", cents) : "cents")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(inTune && live.reading.isSounding ? .green : .secondary)
                Spacer()
                Text("+50¢").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - The oscilloscope

/// The last thousand samples of the instrument, as a scope trace.
struct ThereminOscilloscope: View {
    @ObservedObject var live: ThereminLiveState

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.white.opacity(0.12)), lineWidth: 1)
            let samples = live.scope
            guard samples.count > 1 else { return }
            var trace = Path()
            let step = size.width / CGFloat(samples.count - 1)
            for (i, s) in samples.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: midY - CGFloat(s) * (size.height * 0.46) / 0.6)
                if i == 0 { trace.move(to: p) } else { trace.addLine(to: p) }
            }
            context.stroke(trace, with: .linearGradient(
                Gradient(colors: [PawvisTheme.accentUI, Color(nsColor: PawvisTheme.blueLight)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                           style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.07, blue: 0.14), Color(red: 0.05, green: 0.04, blue: 0.08)],
                                     startPoint: .top, endPoint: .bottom)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - The take strip

/// A recording's peaks as a waveform: grows while recording, stays as the
/// finished take.
struct ThereminTakeStrip: View {
    let peaks: [Float]
    let recording: Bool

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: midY))
            baseline.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            guard !peaks.isEmpty else { return }
            // The whole take spans the strip: as many bars as fit at the
            // minimum width, each bucketing its share of the peaks, and
            // wider bars when there are fewer peaks than that.
            let minimumBar: CGFloat = 2
            let gap: CGFloat = 1
            let maxBars = max(1, Int(size.width / (minimumBar + gap)))
            let bars = min(maxBars, peaks.count)
            let perBar = Double(peaks.count) / Double(bars)
            let slot = size.width / CGFloat(bars)
            let barWidth = max(1, slot - gap)
            let color = recording ? PawvisTheme.attentionUI : PawvisTheme.accentUI
            for bar in 0..<bars {
                let start = Int(Double(bar) * perBar)
                let end = max(start + 1, Int(Double(bar + 1) * perBar))
                let peak = CGFloat(peaks[start..<min(end, peaks.count)].max() ?? 0)
                let height = max(2, peak * size.height * 0.9)
                let rect = CGRect(x: CGFloat(bar) * slot, y: midY - height / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(0.9)))
            }
        }
    }
}
