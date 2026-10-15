import FactoryKit
import SwiftUI

/// What happens to someone's mail once they connect it, opened from the fine print under each
/// Google consent button. Every line is a claim at consent: keep it true to the code.
struct PrivacyDisclosureSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The default must match `MailHeadersOnly.isOn`'s and the broker's `headersOnlyFrom`.
    @AppStorage(MailHeadersOnly.storageKey) private var headersOnly = false
    /// The rows' height, so the card hugs them when they fit and scrolls when they don't.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 16) {
            // The same header as the Select-all sheet, the app's other modal.
            VStack(spacing: 6) {
                Text("Privacy")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textTertiary)
                Text("Your data, and what we do with it")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Text("The short version. The full policy is linked below.")
                    .font(.system(size: 14))
                    .foregroundStyle(OnboardingTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            ScrollView {
                VStack(spacing: 0) {
                    // First because it is the one row that does something; the rest describe.
                    HeadersOnlyRow(isOn: $headersOnly)
                    Divider()
                    let points = PrivacyPoint.all(headersOnly: headersOnly)
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        PrivacyRow(point: point)
                        if index < points.count - 1 { Divider() }
                    }
                }
            }
            // The card holds the scroll view, not the reverse: glass inside a ScrollView gets its
            // shadow and ends clipped.
            .scrollIndicators(.hidden)
            .scrollEdgeEffectHidden(true, for: .all)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                rowsHeight = height
            }
            .frame(maxHeight: rowsHeight > 0 ? rowsHeight : nil)
            .clipShape(.rect(cornerRadius: 22))
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .padding(.horizontal, PrivacyLayout.gutter)

            Spacer(minLength: 0)

            Link(destination: PrivacyLayout.policyURL) {
                Text("Read the full privacy policy")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OnboardingTheme.textSecondary)
                    .underline()
            }
            .accessibilityIdentifier("privacy_disclosure_policy_link")

            OnboardingPrimaryButton(
                title: "Got it",
                accessibilityID: "privacy_disclosure_done"
            ) {
                dismiss()
            }
            .padding(.horizontal, PrivacyLayout.gutter)
            .padding(.bottom, 8)
        }
        .background(OnboardingTheme.background.ignoresSafeArea())
        // Awaited rather than left to the store's 1.5 s debounce: the broker reads this row when it
        // resolves the mailbox, and the sync that caches snippets is one tap away.
        .onChange(of: headersOnly) { _, on in
            Task {
                let saved = await Container.shared.userProfile().flush()
            }
        }
    }
}

// MARK: - The choice

/// The one interactive row, in the shape of the rows under it. Copy kept in step with
/// `ProfileView`'s Settings toggle, which binds the same key.
private struct HeadersOnlyRow: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 12) {
                // The same pair as the Settings row, which is the proven spelling.
                Image(systemName: isOn ? "lock.doc" : "doc.text")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PrivacyLayout.silver)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Headers only")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.textPrimary)
                    Text(isOn
                        ? "Jo sees who a message is from, its subject and its date — never "
                            + "what it says. She can still triage, file, archive, label and forward."
                        : "Jo can read the body of a message when you ask. Turn this on and she "
                            + "never fetches one at all.")
                        .font(.system(size: 13))
                        .foregroundStyle(OnboardingTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Theme.toggleOn)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityIdentifier("privacy_disclosure_headers_only")
    }
}

// MARK: - The points

private struct PrivacyPoint: Identifiable {
    let symbol: String
    let label: String
    let detail: String

    var id: String { label }

    /// Every line is a representation made at the consent moment, so the first one has to
    /// track the switch above it: headers-only stops the preview being fetched at all.
    static func all(headersOnly: Bool) -> [PrivacyPoint] { [
        PrivacyPoint(
            symbol: "iphone",
            label: "Your phone keeps the least it can",
            detail: headersOnly
                ? "Only the sender, subject and date are cached on this device — no preview "
                    + "and never the full message."
                : "Only the sender, subject and a one-line preview are cached on this "
                    + "device — never the full message."
        ),
        PrivacyPoint(
            symbol: "lock.fill",
            label: "Everything we store is encrypted",
            detail: "Encrypted in transit with TLS, and encrypted at rest with AES-256."
        ),
        PrivacyPoint(
            symbol: "person.crop.circle",
            label: "We keep your email address",
            detail: "When you sign in, our sign-in server records your Google account's email "
                + "and the date. Never your mail or your tokens."
        ),
        PrivacyPoint(
            symbol: "hand.raised.fill",
            label: "Never sold, never trained on",
            detail: "We don't sell your data. The AI models that power Jo process your "
                + "mail under contract and never train on it."
        ),
        PrivacyPoint(
            symbol: "envelope.fill",
            label: "Jo acts on your mail only when you ask",
            detail: "It reads your inbox to triage, draft and answer, and tells you the "
                + "address before it sends to someone new."
        ),
        PrivacyPoint(
            symbol: "arrow.uturn.left",
            label: "Disconnect whenever you want",
            detail: "Disconnecting stops Jo reading the mailbox, deletes the cache on this "
                + "phone, and revokes our access at Google."
        ),
        PrivacyPoint(
            symbol: "trash.fill",
            label: "Delete your account and it's gone",
            detail: "Deleting your account removes everything on this phone. It can't be "
                + "undone. Ask us and we'll remove your email from our records too."
        )
    ] }
}

// MARK: - Row

/// One line of the card, in the preparing screen's row shape.
private struct PrivacyRow: View {
    let point: PrivacyPoint

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: point.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PrivacyLayout.silver)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(point.label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.textPrimary)
                Text(point.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Teaser

/// The row that opens the sheet, sized to sit in a connect screen's fine print.
struct PrivacyDisclosureTeaser: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Your data, and what we do with it")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(OnboardingTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("privacy_disclosure_teaser")
    }
}

private enum PrivacyLayout {
    static let gutter: CGFloat = 24

    /// The onboarding silver, as on the preparing screen's ticks; each screen keeps its own.
    static let silver = LinearGradient(
        stops: [
            .init(color: Color(white: 0.82), location: 0),
            .init(color: Color(white: 0.72), location: 0.30),
            .init(color: Color(white: 0.60), location: 0.55),
            .init(color: Color(white: 0.48), location: 0.78),
            .init(color: Color(white: 0.56), location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    // Force-unwrapped on a literal: a malformed constant here is a build-time
    // mistake, not a runtime condition to handle.
    static let policyURL = URL(string: "https://codenamejo.com/privacy")!
}

#if DEBUG
import Prefire

// `.prefireIgnored()`, not `.snapshot`: every snapshot preview becomes an App Store
// screenshot and a privacy disclosure should not be one.
#Preview("PrivacyDisclosureSheet") {
    PrivacyDisclosureSheet()
        .prefireIgnored()
}
#endif
