import SwiftUI

/// Where the user adds, replaces or removes their own OpenAI key, in onboarding (`onContinue`) and Settings.
/// Calls cannot start without a key: the backend refuses them with 409.
struct OpenAIKeyView: View {
    var onContinue: (() -> Void)?

    @State private var status: OpenAIKeyService.Status?
    @State private var draft = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your OpenAI key")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(OnboardingTheme.textPrimary)
            Text("Jo runs on your own OpenAI account, so calls are billed to you. "
                + "Create a key at platform.openai.com/api-keys and paste it here. "
                + "It stays in this phone's Keychain; Jo's server uses it for your requests and never stores it.")
                .font(.system(size: 16))
                .foregroundStyle(OnboardingTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let last4 = status?.last4, status?.set == true {
                HStack {
                    Image(systemName: "key.fill")
                    Text("sk-…\(last4)").font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Remove", role: .destructive) { run { try await OpenAIKeyService.remove() } }
                        .disabled(busy)
                }
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 14).fill(OnboardingTheme.surface))
            }

            SecureField(status?.set == true ? "Replace with a new key" : "sk-…", text: $draft)
                .font(.system(size: 17, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(RoundedRectangle(cornerRadius: 14).fill(OnboardingTheme.surface))
                .accessibilityIdentifier("openai_key_field")

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Spacer()

            if !draft.isEmpty {
                OnboardingPrimaryButton(title: busy ? "Checking…" : "Save key", isEnabled: !busy,
                                        accessibilityID: "openai_key_save") {
                    let key = draft
                    run({ try await OpenAIKeyService.save(key) }, then: onContinue)
                }
            } else if let onContinue {
                OnboardingPrimaryButton(title: "Continue", isEnabled: status?.set == true,
                                        accessibilityID: "openai_key_continue", action: onContinue)
            }
        }
        .padding(24)
        .background(OnboardingTheme.background.ignoresSafeArea())
        .task { run { try await OpenAIKeyService.status() } }
    }

    private func run(_ work: @escaping () async throws -> OpenAIKeyService.Status,
                     then onSaved: (() -> Void)? = nil) {
        busy = true
        error = nil
        Task {
            do {
                status = try await work()
                draft = ""
                if status?.set == true { onSaved?() }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
