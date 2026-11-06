#if targetEnvironment(macCatalyst)
import SwiftUI
import WebKit

struct SupervisedBrowserExperimentView: View {
    @StateObject var browser: SupervisedBrowserExperiment
    let returnResult: (SupervisedBrowserExperiment.Context, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Browser experiment").font(.title2.bold())
                    Text(browser.context.origin.subject).font(.headline)
                    Text("Isolated fixture • no real websites, credentials or booking").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { browser.stop() }.accessibilityIdentifier("browserTaskStop")
                Button("Return result to feed") {
                    let result = browser.resultSummary
                    let state = browser.resultState
                    browser.stop()
                    returnResult(browser.context, result, state)
                    dismiss()
                }.accessibilityIdentifier("browserReturnResult")
            }
            Text(browser.context.request).font(.subheadline)
            HStack(alignment: .top, spacing: 20) {
                BrowserExperimentWebView(webView: browser.webView).frame(minWidth: 600, minHeight: 460)
                VStack(alignment: .leading, spacing: 14) {
                    Text(browser.phase.rawValue.capitalized).font(.headline)
                    Text(browser.message)
                    if let approval = browser.pendingApproval {
                        Text(approval.details).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        Button("Approve this fixture request") { Task { await browser.approve(approval.id) } }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("browserExactApproval")
                    } else if browser.phase == .ready, let snapshot = browser.snapshot {
                        ForEach(Array(snapshot.buttons.enumerated()), id: \.offset) { _, button in
                            Button(button.label) { Task { await browser.choose(button.id) } }
                        }
                        Button("Inspect page again") { Task { await browser.refresh() } }
                    }
                    Spacer()
                    Text("Page text is evidence to inspect, never permission to act.").font(.caption).foregroundStyle(.secondary)
                }.frame(width: 280)
            }
        }.padding(24).frame(minWidth: 980, minHeight: 640)
            .task { await browser.start() }
            .onDisappear { browser.stop() }
    }
}

private struct BrowserExperimentWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
