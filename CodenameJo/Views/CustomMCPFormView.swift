import SwiftUI

/// The sheet behind "Add MCP server" and a bearer server's Reconnect. It edits `ProfileViewModel`'s
/// draft fields so the Connections screen owns one source of truth.
struct CustomMCPFormView<Interactor: ViewWithModelLifecycleObserver<ProfileViewModel> & ProfileViewHandler>: View {
    @ObservedObject var viewModel: ProfileViewModel
    @ObservedObject var interactor: Interactor

    private var reconnecting: Bool { viewModel.customMCPReconnecting != nil }

    private var canSubmit: Bool {
        guard !viewModel.isConnectionBusy else { return false }
        if reconnecting { return !viewModel.customMCPDraftToken.trimmingCharacters(in: .whitespaces).isEmpty }
        let named = !viewModel.customMCPDraftName.trimmingCharacters(in: .whitespaces).isEmpty
        let addressed = CustomMCPConnector.endpoint(from: viewModel.customMCPDraftURL) != nil
        let credentialed = viewModel.customMCPDraftAuth != .bearer
            || !viewModel.customMCPDraftToken.trimmingCharacters(in: .whitespaces).isEmpty
        return named && addressed && credentialed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(reconnecting ? "Reconnect \(viewModel.customMCPDraftName)" : "Add an MCP server")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .listRowBackground(Theme.surface)
                }

                Section {
                    TextField("Name, e.g. MVP", text: $viewModel.customMCPDraftName)
                        .disabled(reconnecting)
                        .accessibilityIdentifier("customMCPNameField")
                    TextField("https://example.com/mcp", text: $viewModel.customMCPDraftURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(reconnecting)
                        .accessibilityIdentifier("customMCPURLField")
                } header: {
                    Text("Server")
                } footer: {
                    Text("The streamable-HTTP endpoint, over https. Jo calls it directly from this phone.")
                        .font(ConnectionLayout.footer)
                        .foregroundStyle(Theme.textTertiary)
                }
                .listRowBackground(Theme.surface)

                Section {
                    if !reconnecting {
                        Picker("Sign-in", selection: $viewModel.customMCPDraftAuth) {
                            ForEach(CustomMCPServer.Auth.allCases) { auth in
                                Text(auth.title).tag(auth)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("customMCPAuthPicker")
                    }
                    if viewModel.customMCPDraftAuth == .bearer {
                        SecureField("Token", text: $viewModel.customMCPDraftToken)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("customMCPTokenField")
                    }
                } header: {
                    Text("Credential")
                } footer: {
                    Text(authFooter)
                        .font(ConnectionLayout.footer)
                        .foregroundStyle(Theme.textTertiary)
                }
                .listRowBackground(Theme.surface)

                if let error = viewModel.connectionError, viewModel.connectionErrorConnector == "custom-mcp" {
                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                            Text(error)
                                .font(ConnectionLayout.footer)
                        }
                        .foregroundStyle(Theme.error)
                        .accessibilityIdentifier("connectionError_custom-mcp-form")
                    }
                    .listRowBackground(Theme.surface)
                }

                Section {
                    Button {
                        interactor.submitCustomMCPForm(viewModel: viewModel)
                    } label: {
                        HStack(spacing: ConnectionLayout.rowSpacing) {
                            if viewModel.busyConnector == "custom-mcp" {
                                ProgressView().frame(width: ConnectionLayout.iconColumn)
                            }
                            Text(submitTitle)
                                .font(ConnectionLayout.action)
                                .foregroundStyle(canSubmit ? Theme.accent : Theme.textTertiary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("customMCPSubmitButton")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { interactor.cancelCustomMCPForm(viewModel: viewModel) }
                        .disabled(viewModel.isConnectionBusy)
                        .accessibilityIdentifier("customMCPCancelButton")
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isConnectionBusy)
    }

    private var submitTitle: String {
        if viewModel.busyConnector == "custom-mcp" { return reconnecting ? "Reconnecting…" : "Checking the server…" }
        if reconnecting { return "Save token" }
        return viewModel.customMCPDraftAuth == .oauth ? "Sign in and add" : "Add server"
    }

    private var authFooter: String {
        switch viewModel.customMCPDraftAuth {
        case .oauth:
            "Jo discovers the server's sign-in page and opens it. The server has to support OAuth with dynamic client registration."
        case .bearer:
            "Sent as the Authorization header on every call. It stays in this phone's Keychain."
        case .none:
            "For a server that needs no credential. Jo sends no Authorization header."
        }
    }
}
