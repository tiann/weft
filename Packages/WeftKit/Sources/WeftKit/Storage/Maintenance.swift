import Foundation
import SwiftData

/// Idempotent upkeep of stored data, run at launch.
@MainActor
public enum Maintenance {
    public static func run(modelContext: ModelContext, classifier: ClassificationService) {
        // A rule that appeared after the model answered or Weft guessed (e.g. a built-in rule
        // shipped in a newer version) takes precedence over the old answer.
        let ai = ClassificationSource.ai.rawValue
        let guess = ClassificationSource.guess.rawValue
        let answered = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationSourceRaw == ai || $0.classificationSourceRaw == guess }
        ))) ?? []
        for segment in answered {
            let (key, source) = classifier.classify(segment.context)
            guard source == .builtin || source == .rule || (source == .ai && segment.classificationSource == .guess)
            else { continue }
            segment.categoryKey = key
            segment.classificationSource = source
        }

        // Built-in browser rules used to cover every tab, so sites no rule knows were all
        // filed as browsing. Classify them like new activity.
        let builtin = ClassificationSource.builtin.rawValue
        let browsing = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.classificationSourceRaw == builtin && $0.categoryKey == "browsing" && $0.domain != nil }
        ))) ?? []
        for segment in browsing {
            let (key, source) = classifier.classify(segment.context)
            segment.categoryKey = key
            segment.classificationSource = source
        }
        try? modelContext.save()

        // Sessions from before projects, while their folders are still there.
        Projects.assign(modelContext: modelContext)
    }
}
