import ActivityKit
import SwiftUI
import WidgetKit

/// Jo's Lock Screen / Dynamic Island surface for a hands-free call with the app off-screen. Colours
/// are literals, not `Theme`, because the asset catalog lives in the app bundle.
struct VoiceLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            LockScreenContent(state: context.state, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 9) {
                        VoiceBead(state: context.state, diameter: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            StatusText(state: context.state)
                            ElapsedTime(startedAt: context.attributes.startedAt)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Mute joins End here only when the bottom region is spoken for.
                    // Without a card the layout is exactly what it was.
                    if context.state.card == nil {
                        EndButton()
                    } else {
                        HStack(spacing: 4) {
                            MuteButton(state: context.state, wide: false)
                            EndButton()
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let card = context.state.card {
                        CardView(card: card)
                            .padding(.top, 2)
                    } else {
                        // Wide here: the bottom region is full width and has no
                        // orb competing with it, so the button can say its word.
                        MuteButton(state: context.state, wide: true)
                            .padding(.top, 2)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isMuted ? "mic.slash.fill" : "waveform")
                    .foregroundStyle(VoicePalette.tint(for: context.state))
            } compactTrailing: {
                // The compact presentation is ~launch-icon sized: one word, whether you are being
                // heard.
                Text(context.state.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(VoicePalette.tint(for: context.state))
                    .lineLimit(1)
            } minimal: {
                Image(systemName: context.state.isMuted ? "mic.slash.fill" : "waveform")
                    .foregroundStyle(VoicePalette.tint(for: context.state))
            }
            // Tapping anywhere that isn't a button opens the app to the orb.
            .widgetURL(URL(string: "aurex://session"))
            .keylineTint(VoicePalette.tint(for: context.state))
        }
        // Opting into `.small` gives the watch's Smart Stack a designed card instead of the
        // system's default built from the compact views.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Lock Screen

/// One content closure, two rooms. `.small` is the watch Smart Stack; the
/// default branch is the phone Lock Screen (and CarPlay), unchanged.
private struct LockScreenContent: View {
    @Environment(\.activityFamily) private var family
    let state: VoiceActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        switch family {
        case .small: WatchSmallView(state: state, startedAt: startedAt)
        default: LockScreenView(state: state, startedAt: startedAt)
        }
    }
}

/// The wrist card: bead, status, elapsed time, no buttons. A `Button(intent:)` in the mirrored
/// Smart Stack card has no supported path back into the iPhone process.
private struct WatchSmallView: View {
    let state: VoiceActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        HStack(spacing: 10) {
            VoiceBead(state: state, diameter: 30)
            VStack(alignment: .leading, spacing: 1) {
                StatusText(state: state)
                ElapsedTime(startedAt: startedAt)
                // One line, not the card: the wrist is more public and narrower.
                if let card = state.card {
                    CardSummary(card: card)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

/// How long the call has been up, from the dial. `Text(timerInterval:)` animates without a push;
/// the range is capped at eight hours because the API wants a closed one.
private struct ElapsedTime: View {
    let startedAt: Date

    var body: some View {
        Text(
            timerInterval: startedAt...startedAt.addingTimeInterval(8 * 3600),
            countsDown: false
        )
        .monospacedDigit()
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct LockScreenView: View {
    let state: VoiceActivityAttributes.ContentState
    let startedAt: Date

    /// One row: bead, status (with elapsed time under it), controls. No transcript: the Lock Screen
    /// is a public surface.
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                VoiceBead(state: state, diameter: 52)
                VStack(alignment: .leading, spacing: 1) {
                    StatusText(state: state)
                    ElapsedTime(startedAt: startedAt)
                }
                Spacer(minLength: 4)
                MuteButton(state: state, wide: false)
                EndButton()
            }
            if let card = state.card {
                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(height: 1)
                    .padding(.top, 13)
                CardView(card: card)
                    .padding(.top, 11)
            }
        }
        .padding(16)
    }
}

// MARK: - Pieces

/// The bead, static because the system renders a Live Activity on its own schedule: gold while the
/// mic is open, bare silver when muted. A 2D drawing; the in-app orb is 3D (`MercuryOrb3D`).
private struct VoiceBead: View {
    let state: VoiceActivityAttributes.ContentState
    var diameter: CGFloat

    /// Gold whenever the mic is open, silver when it isn't.
    private var metal: Color { VoicePalette.tint(for: state) }

    var body: some View {
        ZStack {
            Circle().fill(baseMetal)
            horizon
            metalWash
            specular
            underglint
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        // Rim: a dark outer edge and a faint bright line just inside it.
        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1.5))
        .overlay(
            Circle()
                .stroke(.white.opacity(0.3), lineWidth: 1)
                .padding(diameter * 0.02)
        )
        .shadow(color: .black.opacity(0.35), radius: diameter * 0.12, y: diameter * 0.06)
        // Lit from within while live; muted is unlit, which reads as "off" across a room.
        .shadow(color: state.isMuted ? .clear : metal.opacity(0.35), radius: diameter * 0.22)
        .accessibilityHidden(true)
    }

    private var baseMetal: RadialGradient {
        RadialGradient(
            stops: [
                .init(color: Color(white: 1.0), location: 0),
                .init(color: Color(white: 0.92), location: 0.32),
                .init(color: Color(white: 0.72), location: 0.6),
                .init(color: Color(white: 0.42), location: 0.88),
                .init(color: Color(white: 0.68), location: 1),
            ],
            center: UnitPoint(x: 0.32, y: 0.26),
            startRadius: 0,
            endRadius: diameter * 0.85
        )
    }

    /// The tight 0.47 → 0.53 transition is the point: a soft blend reads as
    /// shading, a hard band reads as a reflection of something.
    private var horizon: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.85), location: 0),
                .init(color: .white.opacity(0.15), location: 0.4),
                .init(color: .black.opacity(0.05), location: 0.47),
                .init(color: .black.opacity(0.55), location: 0.53),
                .init(color: .black.opacity(0.32), location: 0.75),
                .init(color: .white.opacity(0.4), location: 0.96),
                .init(color: .black.opacity(0.25), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// What turns the chrome to gold. Overlay blend, so the specular and horizon still read as
    /// metal. Muted washes with nothing.
    private var metalWash: some View {
        LinearGradient(
            colors: [metal.opacity(0.85), metal.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .blendMode(.overlay)
        .opacity(state.isMuted ? 0 : 1)
    }

    private var specular: some View {
        RadialGradient(
            colors: [.white.opacity(0.95), .white.opacity(0)],
            center: UnitPoint(x: 0.3, y: 0.24),
            startRadius: 0,
            endRadius: diameter * 0.3
        )
    }

    /// Without it the bottom half is just dark and the bead goes flat.
    private var underglint: some View {
        RadialGradient(
            colors: [.white.opacity(0.4), .clear],
            center: UnitPoint(x: 0.7, y: 0.82),
            startRadius: 0,
            endRadius: diameter * 0.2
        )
    }
}

/// The status word.
private struct StatusText: View {
    let state: VoiceActivityAttributes.ContentState

    var body: some View {
        Text(state.statusLabel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Close the microphone without leaving the call. Round beside the bead, a labelled capsule in the
/// Dynamic Island's bottom region; same intent either way.
private struct MuteButton: View {
    let state: VoiceActivityAttributes.ContentState
    var wide: Bool

    var body: some View {
        Button(intent: ToggleBackgroundMuteIntent()) {
            Group {
                if wide {
                    HStack(spacing: 7) {
                        Image(systemName: state.muteSymbol)
                            .font(.system(size: 15, weight: .bold))
                        Text(state.muteLabel)
                            .font(.subheadline.weight(.bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                } else {
                    Image(systemName: state.muteSymbol)
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                }
            }
            .foregroundStyle(.white)
            .background(VoicePalette.buttonFill(for: state), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.muteLabel)
    }
}

/// Deliberately the quiet one: hanging up is a decision, and a red X the size of
/// the Mute button invites the wrong tap in the dark.
private struct EndButton: View {
    var body: some View {
        Button(intent: EndBackgroundVoiceSessionIntent()) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: Circle())
                // A widget button's hit area is exactly its label's frame, so the 36 pt disc gets a
                // 44 pt target; a miss lands on the card and opens the app.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End call")
    }
}

// MARK: - The card

/// The display-only row under the status row. Nothing tappable, and nothing sensitive: no sender
/// names, so nothing for iOS to redact.
private struct CardView: View {
    let card: VoiceActivityAttributes.Card

    var body: some View {
        switch card {
        case .triage(let position, let total):
            TriageCard(position: position, total: total)
        }
    }
}

/// How far into the pile the user is: two numbers and a bar, naming nobody.
private struct TriageCard: View {
    let position: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CardIcon("envelope.fill")
                Text("Mail queue")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text("\(position) of \(total)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            CardBar(value: Double(position), total: Double(max(total, position)))
        }
    }
}

/// One line of the card, for the wrist — where there is room for a headline and nothing
/// under it, and where a name is even less welcome than it is on a phone.
private struct CardSummary: View {
    let card: VoiceActivityAttributes.Card

    var body: some View {
        Group {
            switch card {
            case .triage(let position, let total):
                Text("Mail \(position) of \(total)")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(VoicePalette.gold)
        .lineLimit(1)
    }
}

/// A filled proportion. Static: a Live Activity interpolates only `Text(timerInterval:)` and a
/// linear `ProgressView(timerInterval:)`, so this steps on each push.
private struct CardBar: View {
    let value: Double
    let total: Double

    var body: some View {
        ProgressView(value: min(max(value, 0), total), total: max(total, 1))
            .progressViewStyle(.linear)
            .tint(VoicePalette.gold)
            .scaleEffect(x: 1, y: 0.6, anchor: .center)
            .frame(height: 4)
            .accessibilityHidden(true)
    }
}

/// The card's glyph.
private struct CardIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(VoicePalette.gold)
    }
}

// MARK: - Palette


private enum VoicePalette {
    /// `Theme.conversing` in its dark form. A Live Activity draws on the Lock Screen's dark
    /// material in either appearance, so the light variant never applies.
    static let gold = Color(red: 0.910, green: 0.780, blue: 0.400)
    /// Muted: bare chrome, and the one state that must not read as live.
    static let silver = Color(red: 0.72, green: 0.74, blue: 0.78)

    /// Gold whenever the mic is open, silver the moment it closes. The phase shows in the word
    /// beside the bead.
    static func tint(for state: VoiceActivityAttributes.ContentState) -> Color {
        state.isMuted ? silver : gold
    }

    /// Black while the mic is live, grey once it is closed; the icon's slash carries the meaning.
    static func buttonFill(for state: VoiceActivityAttributes.ContentState) -> Color {
        state.isMuted ? mutedButton : .black
    }

    /// Light enough to read as "this is the off state" against the black the
    /// live button uses, without competing with the silver bead beside it.
    static let mutedButton = Color(white: 0.55)
}
