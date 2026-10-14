import AVFoundation
import SwiftUI
import UIKit

// HARD RULE: no `.onAppear`-driven entrance animations in onboarding. `.onAppear` doesn't fire in
// the Prefire snapshot render, so hide-then-show leaves a blank PNG.

// MARK: - Theme
enum OnboardingTheme {
    static let accent: Color = Theme.accent

    // MARK: - Surfaces & text (delegate to the app's adaptive `Theme`)
    // Delegates to `Theme` so onboarding matches the rest of the app in light and dark.
    /// `.primary`: full black in light and full white in dark, the exact inverse of `background`.
    static let cta = Color.primary
    static let onCTA = Color(uiColor: .systemBackground)

    /// The system background, not `Theme.background`: plain white in light and plain black in dark.
    static let background = Color(uiColor: .systemBackground)
    /// Kept as the app's surface: it now has an actual white or black ground to sit on,
    /// which is what makes a selected row or a tile read as raised at all.
    static let surface = Theme.surface
    static let textPrimary = Theme.textPrimary
    static let textSecondary = Theme.textSecondary
}

// MARK: - Primary CTA

/// The full-width accent call-to-action used at the bottom of every onboarding
/// screen.
struct OnboardingPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    var accessibilityID: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OnboardingTheme.onCTA)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(OnboardingTheme.cta.opacity(isEnabled ? 1 : 0.4))
                )
        }
        .disabled(!isEnabled)
        .accessibilityIdentifier(accessibilityID)
    }
}

// MARK: - Scaffold

/// Standard chrome for the form-like onboarding screens: an optional left-aligned
/// title/subtitle header, a flexible content region, and a pinned footer.
struct OnboardingScaffold<Content: View, Footer: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer()
        }
        .frame(maxWidth: .infinity)
        .background(OnboardingTheme.background.ignoresSafeArea())
    }

    @ViewBuilder private var header: some View {
        if title != nil || subtitle != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let title {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(OnboardingTheme.textPrimary)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Jo's clip meter

/// Mirrors an onboarding clip onto a `VoiceMetering` so a `SpeechIndicator` can draw Jo talking, at
/// 10 Hz. Average power, not peak, which reads as shouting.
@MainActor
enum JoClipMeter {
    /// Feeds levels while `player` plays and flips `speaking` around the clip, draining at the end
    /// so no standing wave is left. Cancel the returned task to take over.
    static func feed(
        _ player: AVAudioPlayer,
        into metering: VoiceMetering,
        speaking: @escaping (Bool) -> Void
    ) -> Task<Void, Never> {
        player.isMeteringEnabled = true
        speaking(true)
        return Task {
            while !Task.isCancelled, player.isPlaying {
                player.updateMeters()
                metering.levels.capture = pow(10, Double(player.averagePower(forChannel: 0)) / 20)
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            speaking(false)
            await drainOut(metering)
        }
    }

    /// Zeros for a few seconds after a manual stop, so the thread falls flat.
    static func drain(_ metering: VoiceMetering) -> Task<Void, Never> {
        Task { await drainOut(metering) }
    }

    private static func drainOut(_ metering: VoiceMetering) async {
        for _ in 0..<40 {
            if Task.isCancelled { return }
            metering.levels = AudioLevels()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

#if DEBUG
import Prefire

#Preview("OnboardingComponents") {
    OnboardingScaffold(
        title: "A sample screen",
        subtitle: "Shared scaffold with a pinned CTA."
    ) {
        Image(systemName: "sparkles")
            .font(.system(size: 52, weight: .medium))
            .foregroundStyle(OnboardingTheme.accent)
            .padding(.top, 24)
    } footer: {
        OnboardingPrimaryButton(title: "Continue") {}
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
    }
    .snapshot(delay: 0.5)
}
#endif
