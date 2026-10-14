import SwiftUI

@MainActor
protocol ConnectorDetailViewHandler {}

struct ConnectorDetailView<
    Interactor: ViewWithModelLifecycleObserver<ConnectorDetailViewModel> & ConnectorDetailViewHandler
>: View {
    @StateObject var viewModel: ConnectorDetailViewModel
    @StateObject var interactor: Interactor

    var body: some View {
        List {
            Text(viewModel.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .listRowBackground(Theme.surface)
            if let summary = viewModel.summary {
                Section {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Theme.surface)
                }
            }

            Section {
                ForEach(viewModel.capabilities) { capability in
                    HStack(alignment: .top, spacing: ConnectionLayout.rowSpacing) {
                        Image(systemName: capability.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.serviceColor(for: viewModel.service))
                            .frame(width: ConnectionLayout.iconColumn, alignment: .leading)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(capability.label)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text(capability.detail)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Theme.surface)
                    // One element per capability, so VoiceOver reads the label and its
                    // sentence together rather than as two stops.
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("What it can do")
                    .font(ConnectionLayout.header)
                    .foregroundStyle(Theme.textPrimary)
                    .textCase(nil)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .bind(observer: interactor, viewModel: viewModel)
    }
}

@MainActor
final class ConnectorDetailViewModel: ViewModel {
    let name: String
    let service: String
    let capabilities: [ConnectorCapability]
    let summary: String?

    init(name: String, service: String, capabilities: [ConnectorCapability], summary: String?) {
        self.name = name
        self.service = service
        self.capabilities = capabilities
        self.summary = summary
    }
}

@MainActor
final class ConnectorDetailViewInteractor: ViewModelInteractor<ConnectorDetailViewModel>,
    ConnectorDetailViewHandler {}

@MainActor
struct ConnectorDetailViewComponent {
    static func make(
        name: String, service: String, capabilities: [ConnectorCapability], summary: String? = nil
    ) -> some View {
        ConnectorDetailView(
            viewModel: ConnectorDetailViewModel(
                name: name, service: service, capabilities: capabilities, summary: summary
            ),
            interactor: ConnectorDetailViewInteractor()
        )
    }
}

#if DEBUG
import Prefire

#Preview("ConnectorDetailView") {
    NavigationStack {
        ConnectorDetailViewComponent.make(
            name: "Notion", service: "Notion", capabilities: .notion
        )
    }
    .snapshot(delay: 0.5)
}
#endif
