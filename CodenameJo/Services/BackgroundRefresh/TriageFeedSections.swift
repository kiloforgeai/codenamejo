import Foundation

struct TriageFeedSections {
    struct Prepared: Codable, Sendable {
        let stage: TriageNavigation.Stage
        let band: String?
        let score: Int?
        let beforeID: String?
        let preparedAt: Date
    }
    struct Progress: Codable {
        let day: String
        let section: FeedSection?
        let page: Prepared?
        let completed: Set<String>
    }
    var progressLoaded = false
    var plan: [FeedSection]?
    var profileID: String?
    var active: FeedSection?
    var completed = Set<String>()
    var filter: FeedSection.Kind?
    var prepared: [String: Prepared] = [:]
    var preparation: Task<Void, Never>?
    var preparationID = UUID()
    var loads: [String: Task<Prepared, Never>] = [:]

    mutating func cancelPreparation() {
        preparationID = UUID()
        preparation?.cancel()
        preparation = nil
        prepared = [:]
        for task in loads.values { task.cancel() }
        loads = [:]
    }

    var upcoming: [FeedSection] {
        (plan ?? []).filter {
            $0.enabled && $0.id != active?.id && !completed.contains($0.id)
        }
    }

}
