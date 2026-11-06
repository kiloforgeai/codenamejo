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
                Label(browser.inspectionOnly ? "Website inspection" : "Task browser", systemImage: "globe").font(.headline)
                Spacer()
                Text(browser.phase.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            if let url = browser.url {
                Link(url.host ?? "Open page", destination: url).font(.caption)
            }
            Text(browser.message).font(.subheadline)
            if let page = browser.webView {
                Label(page.isUserInteractionEnabled ? "You control this page" : browser.inspectionOnly ? "Inspecting the previous task" : "Jo controls this page",
                      systemImage: page.isUserInteractionEnabled ? "hand.point.up.left" : "sparkles")
                    .font(.caption.weight(.semibold))
                HStack {
                    Button("Pause") { control("pause") }
                        .disabled(browser.needsInput).accessibilityIdentifier("browserPause")
                    Button("Take over") { control("takeover") }
                        .disabled(browser.phase == .unknown || page.isUserInteractionEnabled).accessibilityIdentifier("browserTakeover")
                    Button(browser.inspectionOnly ? "Check page" : "Resume Jo") { control(browser.inspectionOnly ? "check_page" : "resume") }
                        .disabled(!canResume || browser.phase == .unknown || browser.phase == .approval)
                        .accessibilityIdentifier("browserResume")
                    Button("Close browser") { control("close_browser") }
                        .disabled(!canResume).accessibilityIdentifier("browserClose")
                }
                if let approval = browser.approval, browser.phase == .approval {
                    Text("Review the filled form below. Approving will click ‘\(approval.label)’ once and look for: ‘\(approval.receipt)’.")
                        .font(.callout)
                    Button("Approve \(approval.label)") { control("approve") }
                        .buttonStyle(.borderedProminent).disabled(!canResume)
                        .accessibilityIdentifier("browserApproveSubmission")
                }
                TaskBrowserSurface(page: page).frame(height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            } else if !browser.text.isEmpty {
                DisclosureGroup("Last inspected page") {
                    Text(browser.text).font(.system(size: 14)).textSelection(.enabled)
                }
            }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("taskBrowserPanel")
            .onAppear { browser.recordPresentation(visible: true) }
            .onDisappear { browser.recordPresentation(visible: false) }
            .onChange(of: browser.phase) { _, _ in browser.recordPresentation(visible: true) }
    }
}

private struct TaskBrowserSurface: UIViewRepresentable {
    let page: WKWebView
    // SwiftUI owns a fresh host, never the retained browser itself. When controls
    // appear/disappear, dismantling the previous representable must not detach
    // the same WKWebView after the new representable has mounted it.
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ host: UIView, context: Context) {
        guard page.superview !== host else { return }
        page.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
}
#endif
