import Foundation
import Observation
import SwiftData

/// Rules first, cached model answers second, the model last. Model calls run one at a time
/// in the background; segments stay `pending` until their answer arrives. Without a model,
/// or when it fails, segments get a `guess` instead, which the model replaces later.
@MainActor
@Observable
public final class ClassificationService {
    public private(set) var categories: [CategoryDefinition] = []
    public private(set) var userRules: [UserRule] = []
    public private(set) var aiAvailability: AIAvailability
    /// Number of distinct apps/sites waiting for the model.
    public private(set) var queuedCount = 0
    /// Classification keys whose model answer the user kept in Review.
    public private(set) var reviewedKeys: Set<String> = []

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let ai: any AIClassifying
    @ObservationIgnored private var engine = RuleEngine(rules: BuiltinRules.all)
    @ObservationIgnored private var cache: [String: AIClassification] = [:]
    @ObservationIgnored private var queue: [(key: String, context: ActivityContext)] = []
    @ObservationIgnored private var failedKeys: Set<String> = []
    @ObservationIgnored private var guesses: [String: String] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var categoryIndex: [String: CategoryDefinition] = [:]

    public init(modelContext: ModelContext, ai: any AIClassifying = FoundationModelsClassifier()) {
        self.modelContext = modelContext
        self.ai = ai
        aiAvailability = ai.availability()
        seedCategoriesIfNeeded()
        reloadCategories()
        reloadRules()
        loadCache()
    }

    // MARK: Categories

    public func category(_ key: String) -> CategoryDefinition {
        categoryIndex[key] ?? categoryIndex[CategoryDefinition.uncategorizedKey]
            ?? CategoryDefinition.defaults.last!
    }

    public var categoryLookup: [String: CategoryDefinition] { categoryIndex }

    public func reloadCategories() {
        let records = (try? modelContext.fetch(FetchDescriptor<CategoryRecord>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        categories = records.map(\.definition)
        categoryIndex = Dictionary(categories.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func updateCategory(_ definition: CategoryDefinition) {
        let key = definition.key
        guard let record = try? modelContext.fetch(FetchDescriptor<CategoryRecord>(predicate: #Predicate { $0.key == key })).first
        else { return }
        record.name = definition.name
        record.colorHex = definition.colorHex
        record.isFocusTime = definition.isFocusTime
        record.isMeeting = definition.isMeeting
        record.blockInFocus = definition.blockInFocus
        record.isDoNotTrack = definition.isDoNotTrack
        record.hint = definition.hint
        try? modelContext.save()
        reloadCategories()
    }

    private func seedCategoriesIfNeeded() {
        let existing = Set(((try? modelContext.fetch(FetchDescriptor<CategoryRecord>())) ?? []).map(\.key))
        for (index, definition) in CategoryDefinition.defaults.enumerated() where !existing.contains(definition.key) {
            modelContext.insert(CategoryRecord(definition, sortOrder: index))
        }
        try? modelContext.save()
    }

    // MARK: Classification

    public func classify(_ context: ActivityContext) -> (categoryKey: String, source: ClassificationSource) {
        if let rule = engine.match(context) {
            return (rule.categoryKey, rule.source == .user ? .rule : .builtin)
        }
        if let cached = cache[context.classificationKey] {
            return (cached.categoryKey, .ai)
        }
        if enqueue(context) {
            return (CategoryDefinition.uncategorizedKey, .pending)
        }
        return (guess(context), .guess)
    }

    public func confidence(forKey key: String) -> AIConfidence? {
        cache[key]?.confidence
    }

    /// Keeps the model's answers for `keys` without making rules, which would crowd the
    /// Rules page, and takes them off Review. Keys without an answer are skipped.
    public func markReviewed(_ keys: some Sequence<String>) {
        let keys = Array(Set(keys).filter { cache[$0] != nil && !reviewedKeys.contains($0) })
        guard !keys.isEmpty else { return }
        let records = (try? modelContext.fetch(FetchDescriptor<AIClassificationRecord>(
            predicate: #Predicate { keys.contains($0.key) }
        ))) ?? []
        for record in records { record.reviewed = true }
        try? modelContext.save()
        reviewedKeys.formUnion(records.map(\.key))
    }

    /// Picks up the model becoming available or unavailable, e.g. Apple Intelligence being
    /// turned on in System Settings.
    public func refreshAvailability() {
        let previous = aiAvailability
        aiAvailability = ai.availability()
        if aiAvailability != previous { retryPending() }
    }

    /// Asks the model again about every app/site that is waiting or was only guessed. Without
    /// a model, waiting ones get a guess instead.
    public func retryPending() {
        aiAvailability = ai.availability()
        failedKeys.removeAll()
        let pending = ClassificationSource.pending.rawValue
        let guess = ClassificationSource.guess.rawValue
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationSourceRaw == pending || $0.classificationSourceRaw == guess }
        ))) ?? []
        for segment in segments where !enqueue(segment.context) && segment.classificationSource == .pending {
            segment.categoryKey = self.guess(segment.context)
            segment.classificationSource = .guess
        }
        try? modelContext.save()
    }

    /// Queues `context` for the model; false when there's no model or it already failed on it.
    @discardableResult
    private func enqueue(_ context: ActivityContext) -> Bool {
        let key = context.classificationKey
        guard aiAvailability == .available, !failedKeys.contains(key) else { return false }
        guard !queue.contains(where: { $0.key == key }) else { return true }
        queue.append((key, context))
        queuedCount = queue.count
        if worker == nil {
            worker = Task { [weak self] in await self?.drain() }
        }
        return true
    }

    private func drain() async {
        while let next = queue.first {
            do {
                let result = try await ai.classify(next.context, titles: titles(forKey: next.key, context: next.context),
                                                  categories: categories)
                store(result, forKey: next.key)
            } catch {
                failedKeys.insert(next.key)
                fallBackToGuess(next.context)
            }
            queue.removeFirst()
            queuedCount = queue.count
        }
        worker = nil
    }

    /// Up to five titles seen for the app or site, most time first, so the model doesn't have
    /// to judge a site by a login page or a tab that hadn't loaded yet.
    private func titles(forKey key: String, context: ActivityContext) -> [String] {
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationKey == key }
        ))) ?? []
        var samples: [(title: String?, duration: TimeInterval)] = segments.map { ($0.title, $0.duration) }
        samples.append((context.title, 0))
        return TitleSummary.mostUsed(samples, appName: context.appName, limit: 5)
    }

    /// Asks the model again about the sites it filed under `categoryKey` that nobody has
    /// confirmed yet, e.g. after it started getting more than one page title per site.
    public func reaskSites(filedAs categoryKey: String) {
        let ai = ClassificationSource.ai.rawValue
        let segments = ((try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationSourceRaw == ai && $0.categoryKey == categoryKey && $0.domain != nil }
        ))) ?? []).filter { !reviewedKeys.contains($0.classificationKey) }
        for key in Set(segments.map(\.classificationKey)) {
            cache[key] = nil
            for record in (try? modelContext.fetch(FetchDescriptor<AIClassificationRecord>(predicate: #Predicate { $0.key == key }))) ?? [] {
                modelContext.delete(record)
            }
        }
        for segment in segments {
            segment.categoryKey = CategoryDefinition.uncategorizedKey
            segment.classificationSource = .pending
        }
        try? modelContext.save()
        retryPending()
    }

    private func guess(_ context: ActivityContext) -> String {
        let key = context.classificationKey
        if let cached = guesses[key] { return cached }
        let appStoreCategory = context.domain == nil ? CategoryGuess.appStoreCategory(bundleID: context.bundleID) : nil
        var category = CategoryGuess.category(for: context, appStoreCategory: appStoreCategory)
        if categoryIndex[category] == nil { category = CategoryDefinition.uncategorizedKey }
        guesses[key] = category
        return category
    }

    private func fallBackToGuess(_ context: ActivityContext) {
        let key = context.classificationKey
        let pending = ClassificationSource.pending.rawValue
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationKey == key && $0.classificationSourceRaw == pending }
        ))) ?? []
        for segment in segments {
            segment.categoryKey = guess(context)
            segment.classificationSource = .guess
        }
        try? modelContext.save()
    }

    private func store(_ result: AIClassification, forKey key: String) {
        cache[key] = result
        if let existing = try? modelContext.fetch(FetchDescriptor<AIClassificationRecord>(predicate: #Predicate { $0.key == key })).first {
            // The user kept the old answer, not this one.
            if existing.categoryKey != result.categoryKey {
                existing.reviewed = false
                reviewedKeys.remove(key)
            }
            existing.categoryKey = result.categoryKey
            existing.confidenceRaw = result.confidence.rawValue
        } else {
            modelContext.insert(AIClassificationRecord(key: key, categoryKey: result.categoryKey, confidence: result.confidence))
        }
        let pending = ClassificationSource.pending.rawValue
        let guess = ClassificationSource.guess.rawValue
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate {
                $0.classificationKey == key && ($0.classificationSourceRaw == pending || $0.classificationSourceRaw == guess)
            }
        ))) ?? []
        for segment in segments {
            segment.categoryKey = result.categoryKey
            segment.classificationSource = .ai
        }
        try? modelContext.save()
    }

    private func loadCache() {
        let records = (try? modelContext.fetch(FetchDescriptor<AIClassificationRecord>())) ?? []
        cache = Dictionary(records.map { ($0.key, AIClassification(categoryKey: $0.categoryKey, confidence: $0.confidence)) },
                           uniquingKeysWith: { a, _ in a })
        reviewedKeys = Set(records.filter(\.reviewed).map(\.key))
    }

    // MARK: User corrections

    public func reloadRules() {
        userRules = (try? modelContext.fetch(FetchDescriptor<UserRule>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        engine = RuleEngine(rules: BuiltinRules.all + userRules.map(\.rule))
    }

    /// Creates (or replaces) a user rule and reapplies classification to past activity it covers.
    public func addRule(field: RuleField, pattern: String, categoryKey: String) {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        for existing in userRules where existing.field == field && existing.pattern.lowercased() == pattern.lowercased() {
            modelContext.delete(existing)
        }
        let rule = UserRule(field: field, pattern: pattern, categoryKey: categoryKey)
        modelContext.insert(rule)
        try? modelContext.save()
        reloadRules()
        reclassify(affectedBy: rule.rule)
    }

    public func deleteRule(_ rule: UserRule) {
        let matcher = rule.rule
        modelContext.delete(rule)
        try? modelContext.save()
        reloadRules()
        reclassify(affectedBy: matcher)
    }

    /// Changes a single segment without creating a rule.
    public func setManualCategory(_ categoryKey: String, for segment: ActivitySegment) {
        segment.categoryKey = categoryKey
        segment.classificationSource = .manual
        try? modelContext.save()
    }

    /// Reapplies classification to the segments `rule` could match. The predicate narrows the
    /// fetch in the store so this stays cheap with months of history; `matches` makes it exact.
    private func reclassify(affectedBy rule: Rule) {
        let manual = ClassificationSource.manual.rawValue
        let pattern = rule.pattern
        let predicate: Predicate<ActivitySegment>
        switch rule.field {
        case .bundleID:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.bundleID.localizedStandardContains(pattern) }
        case .domain:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.domain.flatMap { $0.localizedStandardContains(pattern) } == true }
        case .titleContains:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.title.flatMap { $0.localizedStandardContains(pattern) } == true }
        case .urlContains:
            predicate = #Predicate { $0.classificationSourceRaw != manual && $0.url.flatMap { $0.localizedStandardContains(pattern) } == true }
        }
        let candidates = (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? []
        for segment in candidates where rule.matches(segment.context) {
            let (key, source) = classify(segment.context)
            segment.categoryKey = key
            segment.classificationSource = source
        }
        try? modelContext.save()
    }
}
