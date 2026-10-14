import SwiftUI

/// A mercury thread drawn from the live mic level, so the screen shows it is hearing you right now.
/// It reads the level, not `sessionState`, and never shows transcription.
struct SpeechIndicator: View {

    /// Passed in, not observed by `CommandView`, so the 10 Hz redraw stays inside this row.
    @ObservedObject var metering: VoiceMetering

    /// Level history, oldest first, already curved to 0…1. Seeded flat so the thread spans the row from the first frame.
    @State private var samples = [Double](repeating: 0, count: Self.pointCount + 1)
    /// When the newest sample landed. The curve is drawn shifted left as the interval elapses,
    /// so 10 Hz samples slide rather than crossfade in place.
    @State private var arrivedAt: TimeInterval = 0

    /// 3.6 seconds of history at `AudioLevelReader.interval`, one point per sample.
    private static let pointCount = 36
    /// The row's height, and so twice the thread's greatest excursion from the centre.
    private static let rowHeight: CGFloat = 30
    /// The thread's thickness in silence. Not zero: a meter that vanishes looks dead.
    private static let hairline: CGFloat = 2

    /// Below this the thread lies flat. Measured on device: the idle mic reads about 0.029.
    private static let noiseFloor = 0.05
    /// Full excursion. Speech reaches 0.85 on this metric, so the loudest part clips on purpose.
    private static let fullScale = 0.45

    var body: some View {
        // 30 fps: slides the thread between samples and drifts the specular, without which chrome reads as plastic.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            thread(at: t)
        }
        .frame(height: Self.rowHeight)
        // `onReceive`, not `onChange`: a silent room can publish the same level twice, and `onChange` skips repeats.
        .onReceive(metering.$levels) { levels in
            // Fast attack, slow release, so syllables don't spike and a sentence reads as one gesture.
            // `heard`, not `mic`: WebRTC's level reads 0 until the call has an audio send stream.
            let target = Self.amplitude(of: levels.heard)
            let last = samples.last ?? 0
            let smoothed = target > last
                ? last + 0.7 * (target - last)
                : last + 0.3 * (target - last)
            samples.removeFirst()
            samples.append(smoothed)
            arrivedAt = Date.timeIntervalSinceReferenceDate
        }
        // Labelled for VoiceOver and UI tests, with no value: a number changing 10× a second never stops announcing.
        .accessibilityLabel("Microphone level")
        .accessibilityIdentifier("speechIndicator")
    }

    /// The thread at one instant. Lighting is painted edge-to-edge and clipped to the ribbon,
    /// so the outline can change every frame without rebuilding a layer.
    private func thread(at t: TimeInterval) -> some View {
        // How far left the curve has travelled. Clamped, so a stalled publisher parks the thread at the newest shape.
        let progress = min(max((t - arrivedAt) / 0.1, 0), 1)
        let loudest = samples.max() ?? 0
        let shape = MercuryThread(
            amplitudes: samples, hairline: Self.hairline, shift: progress, t: t)
        // Incommensurate frequencies so the highlight never visibly loops.
        let specular = UnitPoint(
            x: 0.42 + 0.18 * sin(t * 0.7),
            y: 0.3 + 0.08 * sin(t * 1.1 + 1.3)
        )
        return Rectangle()
            // A thread is a cylinder, so the horizon runs horizontally: sky on top, dark band below centre, bounce light at the bottom.
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(white: 1.0).opacity(0.95), location: 0),
                        .init(color: Color(white: 0.88).opacity(0.9), location: 0.34),
                        .init(color: Color(white: 0.30).opacity(0.9), location: 0.54),
                        .init(color: Color(white: 0.52).opacity(0.9), location: 0.82),
                        .init(color: Color(white: 0.80).opacity(0.9), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // No tint: gold on this screen means state, which the orb already shows. The wandering specular says the metal is a surface.
            .overlay(
                RadialGradient(
                    colors: [.white.opacity(0.85), .white.opacity(0)],
                    center: specular,
                    startRadius: 0,
                    endRadius: Self.rowHeight * 1.6
                )
            )
            .clipShape(shape)
            // A hair of sky on the upper edge, so the top reads as a rim.
            .overlay(shape.stroke(.white.opacity(0.35), lineWidth: 0.5))
            // The curve has a point past each edge, and a stroke isn't bounded by the fill's rect, so clip.
            .clipped()
            // A cold sheen scaled by loudness, so speech lifts the thread and silence leaves it flat.
            .shadow(
                color: .white.opacity(0.12 + 0.28 * loudest),
                radius: 3 + 8 * loudest)
    }

    /// 0…1, gated at the floor and curved by `pow(_, 0.7)`, since loudness is perceptual.
    private static func amplitude(of sample: Double) -> Double {
        let gated = (sample - noiseFloor) / (fullScale - noiseFloor)
        return pow(min(max(gated, 0), 1), 0.7)
    }
}

/// The thread's outline: one closed ribbon, thick where the mic was loud, newest sample on the right.
/// Not `Animatable`: `SpeechIndicator` does the sliding itself via `shift`.
private struct MercuryThread: Shape {
    /// 0…1 per point, oldest first. One longer than the row, so a point waits past the right edge.
    let amplitudes: [Double]
    /// The thickness that survives silence.
    let hairline: CGFloat
    /// 0…1 through the current sample interval; the curve is drawn this far left of its points.
    let shift: Double
    /// Clock for the standing ripple, so a flat thread doesn't read as a divider line.
    let t: TimeInterval

    func path(in rect: CGRect) -> Path {
        guard amplitudes.count > 1 else { return Path() }
        let mid = rect.midY
        let reach = (rect.height - hairline) / 2
        // One step per sample, sized so that `amplitudes.count - 1` steps span the row —
        // the extra point then sits just off the right edge.
        let step = rect.width / CGFloat(amplitudes.count - 2)
        let offset = CGFloat(shift) * step
        let xs = (0..<amplitudes.count).map { CGFloat($0) * step - offset }

        // Half-thickness plus a slow ripple, phased on x position rather than index, since indices
        // renumber every sample and an index-phased ripple stutters.
        let halves: [CGFloat] = amplitudes.enumerated().map { index, amplitude in
            let x = Double(xs[index])
            let ripple = 0.55 * sin(t * 1.6 - x * 0.05) + 0.3 * sin(t * 2.3 - x * 0.022)
            return hairline / 2 + CGFloat(amplitude) * reach + CGFloat(ripple) * (0.5 + CGFloat(amplitude))
        }

        var path = Path()
        // One ribbon rather than two strokes, so the fill can be lit like a solid.
        let top = (0..<halves.count).map { CGPoint(x: xs[$0], y: mid - halves[$0]) }
        let bottom = (0..<halves.count).reversed().map {
            CGPoint(x: xs[$0], y: mid + halves[$0])
        }
        path.addSmoothLine(through: top)
        path.addSmoothLine(through: bottom, continuing: true)
        path.closeSubpath()
        return path
    }
}

private extension Path {
    /// Midpoint quadratics through `points`: smooth with no overshoot, so the meter never draws a peak that didn't happen.
    mutating func addSmoothLine(through points: [CGPoint], continuing: Bool = false) {
        guard let first = points.first else { return }
        if continuing { addLine(to: first) } else { move(to: first) }
        guard points.count > 2 else {
            points.dropFirst().forEach { addLine(to: $0) }
            return
        }
        for index in 1..<(points.count - 1) {
            let point = points[index]
            let next = points[index + 1]
            let middle = CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2)
            addQuadCurve(to: middle, control: point)
        }
        addLine(to: points[points.count - 1])
    }
}
