import SwiftUI

/// Third-party work the app ships, with the notices its licences ask to be shown.
struct AcknowledgementsView: View {
    struct Credit: Identifiable {
        let name: String
        let use: String
        let notice: String
        var id: String { name }
    }

    /// Smart Turn's BSD-2-Clause notice is read from the copy bundled beside the model.
    static let credits: [Credit] = [
        Credit(name: "Smart Turn v3.2",
               use: "Hears when you have finished speaking on a local call. By Daily (pipecat-ai/smart-turn-v3).",
               notice: bundledText("SmartTurn-LICENSE", in: "SmartTurn")
                   ?? "BSD 2-Clause License. Copyright (c) 2024-2025, Daily."),
    ]

    var body: some View {
        List(Self.credits) { credit in
            Section {
                Text(credit.use)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
                Text(credit.notice)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .listRowBackground(Theme.surface)
            } header: {
                SettingsRow.header(credit.name)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            Text("Acknowledgements")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
        }
    }

    private static func bundledText(_ name: String, in folder: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: folder) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
