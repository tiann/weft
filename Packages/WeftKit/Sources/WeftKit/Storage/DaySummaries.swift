import Foundation
import Observation
import SwiftData

/// Hands out `DayRollup`s for reports over months and years without reading every segment
/// again: finished days are added up once in the background and kept as `DaySummary`s. A day is
/// added up again when SwiftData's history says one of its segments changed (a rule, the
/// model's answer, an edit), or when the categories differ from the ones it was added up with.
/// The day still going is always worked out from its segments.
@MainActor
@Observable
public final class DaySummaries {
    /// Days still being added up, for a progress note.
    public private(set) var remaining = 0
    /// Goes up whenever more days are ready, so views showing them work their numbers out again.
    public private(set) var generation = 0

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let builder: DaySummaryBuilder
    @ObservationIgnored private let defaults: UserDefaults
    /// Rollups handed out before, by day, for `readyInputs`. A day that changed keeps its old
    /// one until the new one is ready, so totals don't dip meanwhile.
    @ObservationIgnored private var ready: [Date: DayRollup] = [:]
    @ObservationIgnored private var readyInputs = ""
    @ObservationIgnored private var wanted: [DateInterval] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastCheck = Date.distantPast

    private static let tokenKey = "daySummaryHistoryToken"
    /// How often to look for changed days while someone is asking.
    private let checkInterval: TimeInterval = 10

    public init(container: ModelContainer, defaults: UserDefaults = .standard) {
        modelContext = container.mainContext
        builder = DaySummaryBuilder(modelContainer: container)
        self.defaults = defaults
    }

    /// What a day is added up with besides its segments: what each category counts as, the
    /// time zone hours are counted in, and this version of the sums.
    public static func inputs(_ categories: [String: CategoryDefinition], calendar: Calendar = .current) -> String {
        let flags = categories.values.sorted { $0.key < $1.key }.map { category in
            "\(category.key):\(category.isFocusTime ? 1 : 0)\(category.isMeeting ? 1 : 0)\(category.isDistracting ? 1 : 0)"
        }
        return "2|\(calendar.timeZone.identifier)|" + flags.joined(separator: ",")
    }

    /// The rollups of `days` that are ready, by start. The day going on at `now` is worked out
    /// on the spot, days after it are empty, and the rest are added up in the background,
    /// newest first; `generation` goes up as they're ready.
    public func rollups(for days: [DateInterval], categories: [String: CategoryDefinition], now: Date = .now) -> [Date: DayRollup] {
        let inputs = Self.inputs(categories)
        if inputs != readyInputs {
            ready = [:]
            readyInputs = inputs
        }
        var result: [Date: DayRollup] = [:]
        var missing: [DateInterval] = []
        for day in days {
            if day.start >= now {
                result[day.start] = .empty
            } else if day.end > now {
                result[day.start] = live(day, categories: categories)
            } else if let rollup = ready[day.start] {
                result[day.start] = rollup
            } else {
                missing.append(day)
            }
        }
        // Old days change too, so look for changes now and then even when nothing is missing.
        if !missing.isEmpty || now.timeIntervalSince(lastCheck) >= checkInterval {
            lastCheck = now
            for day in missing where !wanted.contains(day) { wanted.append(day) }
            if task == nil {
                task = Task { [weak self] in await self?.run(categories: categories, inputs: inputs) }
            }
        }
        return result
    }

    /// The first day with any activity, for reports over all of it.
    public func firstActivity() -> Date? {
        var descriptor = FetchDescriptor<ActivitySegment>(sortBy: [SortDescriptor(\.start)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.start
    }

    /// Waits for the days asked for so far; for tests.
    public func settle() async {
        while let task { await task.value }
    }

    private func live(_ day: DateInterval, categories: [String: CategoryDefinition]) -> DayRollup {
        let start = day.start
        let end = day.end
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.end > start && $0.start < end }))) ?? []
        return DayRollup(segments.map(SegmentSample.init), day: day, categories: categories)
    }

    private func run(categories: [String: CategoryDefinition], inputs: String) async {
        defer {
            remaining = 0
            task = nil
        }
        // First what changed since last time, so a changed day is added up again with the rest.
        let token = (defaults.data(forKey: Self.tokenKey)).flatMap { try? JSONDecoder().decode(DefaultHistoryToken.self, from: $0) }
        let (changes, latest) = await builder.changes(since: token)
        if let latest, let data = try? JSONEncoder().encode(latest) { defaults.set(data, forKey: Self.tokenKey) }
        switch changes {
        case .everything:
            if !ready.isEmpty {
                wanted += ready.keys.compactMap { start in
                    Calendar.current.dateInterval(of: .day, for: start)
                }.filter { !wanted.contains($0) }
            }
        case .days(let days):
            for start in days where ready[start] != nil {
                if let day = Calendar.current.dateInterval(of: .day, for: start), !wanted.contains(day) { wanted.append(day) }
            }
        }

        while !wanted.isEmpty {
            wanted.sort { $0.start > $1.start }
            let batch = Array(wanted.prefix(31))
            wanted.removeFirst(batch.count)
            remaining = wanted.count + batch.count
            let built = await builder.rollups(batch, categories: categories, inputs: inputs)
            // The categories changed meanwhile; what's built is for the old ones.
            guard inputs == readyInputs else { return }
            ready.merge(built) { _, new in new }
            generation += 1
        }
    }
}

/// Reads segments and writes `DaySummary`s off the main actor.
@ModelActor
actor DaySummaryBuilder {
    enum Changes: Sendable {
        case days(Set<Date>)
        /// What changed can't be told, so every day is added up again.
        case everything
    }

    /// The days whose segments changed since `token`, by start, with their summaries removed,
    /// and the newest token.
    func changes(since token: DefaultHistoryToken?) -> (Changes, DefaultHistoryToken?) {
        guard let token else { return forgetEverything() }
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try modelContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate { $0.token > token }))
        } catch {
            // The history was cut short, and with it what changed.
            return forgetEverything()
        }
        let entity = String(describing: ActivitySegment.self)
        var ids: Set<PersistentIdentifier> = []
        var ranges: [DateInterval] = []
        for transaction in transactions {
            for change in transaction.changes where change.changedPersistentIdentifier.entityName == entity {
                switch change {
                case .insert, .update:
                    ids.insert(change.changedPersistentIdentifier)
                case .delete(let delete):
                    // Only segments shorter than a second are removed; they count for nothing,
                    // but go by what history kept of them anyway.
                    if let delete = delete as? DefaultHistoryDelete<ActivitySegment>,
                       let start = delete.tombstone[\.start] as? Date, let end = delete.tombstone[\.end] as? Date {
                        ranges.append(DateInterval(start: start, end: max(start, end)))
                    }
                @unknown default:
                    return forgetEverything()
                }
            }
        }
        let list = Array(ids)
        for offset in stride(from: 0, to: list.count, by: 500) {
            let part = Array(list[offset..<min(offset + 500, list.count)])
            let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
                predicate: #Predicate { part.contains($0.persistentModelID) }))) ?? []
            ranges += segments.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        }
        let calendar = Calendar.current
        var days: Set<Date> = []
        for range in ranges {
            var day = calendar.startOfDay(for: range.start)
            repeat {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            } while day < range.end
        }
        if !days.isEmpty {
            let starts = Array(days)
            try? modelContext.delete(model: DaySummary.self, where: #Predicate { starts.contains($0.start) })
            try? modelContext.save()
        }
        return (.days(days), transactions.last?.token ?? token)
    }

    private func forgetEverything() -> (Changes, DefaultHistoryToken?) {
        try? modelContext.delete(model: DaySummary.self)
        try? modelContext.save()
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
        descriptor.fetchLimit = 1
        return (.everything, (try? modelContext.fetchHistory(descriptor))?.first?.token)
    }

    /// Rollups of `days`: kept ones still added up with `inputs`, the rest added up and kept.
    func rollups(_ days: [DateInterval], categories: [String: CategoryDefinition], inputs: String) -> [Date: DayRollup] {
        let starts = days.map(\.start)
        let stored = (try? modelContext.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { starts.contains($0.start) }))) ?? []
        let byStart = Dictionary(stored.map { ($0.start, $0) }, uniquingKeysWith: { first, _ in first })
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var result: [Date: DayRollup] = [:]
        for day in days {
            let summary = byStart[day.start]
            if let summary, summary.end == day.end, summary.inputs == inputs,
               let rollup = try? decoder.decode(DayRollup.self, from: summary.data) {
                result[day.start] = rollup
                continue
            }
            let start = day.start
            let end = day.end
            let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
                predicate: #Predicate { $0.end > start && $0.start < end }))) ?? []
            let rollup = DayRollup(segments.map(SegmentSample.init), day: day, categories: categories)
            guard let data = try? encoder.encode(rollup) else { continue }
            if let summary {
                summary.end = day.end
                summary.inputs = inputs
                summary.data = data
            } else {
                modelContext.insert(DaySummary(day: day, inputs: inputs, data: data))
            }
            result[day.start] = rollup
        }
        try? modelContext.save()
        return result
    }
}
