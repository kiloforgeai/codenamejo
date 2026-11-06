#if targetEnvironment(macCatalyst)
import SwiftUI
import WebKit

struct DesktopBrowserTaskPanel: View {
    @ObservedObject var browser: BackgroundBrowser
    let canResume: Bool
    let control: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Task browser", systemImage: "globe").font(.headline)
                Spacer()
                Text(browser.phase.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            if let url = browser.url {
                Link(url.host ?? "Open page", destination: url).font(.caption)
            }
            Text(browser.message).font(.subheadline)
            if let page = browser.webView {
                TaskBrowserSurface(page: page).frame(height: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                HStack {
                    Button("Pause") { control("pause") }
                        .disabled(browser.needsInput).accessibilityIdentifier("browserPause")
                    Button("Take over") { control("takeover") }
                        .disabled(browser.phase == .unknown || page.isUserInteractionEnabled).accessibilityIdentifier("browserTakeover")
                    Button("Resume Jo") { control("resume") }
                        .disabled(!canResume || browser.phase == .unknown || browser.phase == .approval)
                        .accessibilityIdentifier("browserResume")
                }
                if let approval = browser.approval, browser.phase == .approval {
                    Text("Review the filled form above. Approving will click ‘\(approval.label)’ once and look for: ‘\(approval.receipt)’.")
                        .font(.callout)
                    Button("Approve \(approval.label)") { control("approve") }
                        .buttonStyle(.borderedProminent).disabled(!canResume)
                        .accessibilityIdentifier("browserApproveSubmission")
                }
            } else if !browser.text.isEmpty {
                DisclosureGroup("Last inspected page") {
                    Text(browser.text).font(.system(size: 14)).textSelection(.enabled)
                }
            }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("taskBrowserPanel")
    }
}

private struct TaskBrowserSurface: UIViewRepresentable {
    let page: WKWebView
    func makeUIView(context: Context) -> WKWebView { page }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
