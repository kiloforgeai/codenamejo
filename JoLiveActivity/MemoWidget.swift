import SwiftUI
import WidgetKit

/// "Leave a note" on the Home Screen. The tap is a `widgetURL`: a widget's `Button(intent:)` runs
/// in the extension without opening the app. Colours are literals; the asset catalog is app-only.
struct MemoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.kiloforge.codenamejo.memo-widget",
            provider: MemoWidgetProvider()
        ) { _ in
            MemoWidgetView()
        }
        .configurationDisplayName("Leave a Note")
        .description("One tap to record a note. Transcribed on your phone, sent as a task when there's a connection.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Timeline

/// The date is the only required field and nothing reads it — see the type note
/// on why this widget carries no state.
private struct MemoWidgetEntry: TimelineEntry {
    let date: Date
}

private struct MemoWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoWidgetEntry {
        MemoWidgetEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoWidgetEntry) -> Void) {
        completion(MemoWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoWidgetEntry>) -> Void) {
        completion(Timeline(entries: [MemoWidgetEntry(date: .now)], policy: .never))
    }
}

// MARK: - Face

private struct MemoWidgetView: View {
    /// `VoicePalette.gold`, by value — the record light the app uses for a live mic.
    private static let gold = Color(red: 0.910, green: 0.780, blue: 0.400)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Self.gold)
            Spacer(minLength: 0)
            Text("Leave a note")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("Works with no signal")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.62))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(MemoDeepLink.url)
        // The obsidian ground the app screen sits on, as two literals; one look in both
        // appearances.
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(white: 0.13), Color(white: 0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
