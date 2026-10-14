import Foundation

/// Pending intent to open History on a tab, set by views (droplets, notification taps) that can't scroll the pager.
/// `ContentView` consumes `pendingPane`; `HistoryView` consumes `pendingTab` and `pendingEntryId`, so neither swallows the other's.
@MainActor
final class HistoryRouter: ObservableObject {
    /// Set when something wants the pager moved to History.
    @Published var pendingPane = false
    /// Which tab History should land on. Nil keeps the user's last selection.
    @Published var pendingTab: HistoryViewModel.Grouping?
    /// A row to open and scroll to, set by a notification tap. Separate from `pendingTab`
    /// because the list can only scroll after the tab changes and rows load.
    @Published var pendingEntryId: UUID?

    /// Ask for History, on a given tab, optionally opened at one row.
    func open(tab: HistoryViewModel.Grouping? = nil, entry: UUID? = nil) {
        pendingTab = tab
        pendingEntryId = entry
        pendingPane = true
    }

    /// The pager has moved.
    func consumePane() {
        pendingPane = false
    }

    /// The picker has been set.
    func consumeTab() {
        pendingTab = nil
    }

    /// The list has scrolled to the row.
    func consumeEntry() {
        pendingEntryId = nil
    }
}
