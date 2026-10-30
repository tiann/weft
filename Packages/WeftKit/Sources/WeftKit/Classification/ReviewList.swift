import Foundation

/// An app or site no rule covers, as Review lists it.
public struct ReviewItem: Identifiable, Sendable {
    public var key: String
    public var bundleID: String
    public var appName: String
    public var domain: String?
    public var categoryKey: String
    public var source: ClassificationSource
    public var confidence: AIConfidence?
    public var duration: TimeInterval
    /// The most used window or page titles, so it's clear what the app or site was used for.
    public var titles: [String]
    public var id: String { key }

    /// Used long enough that a wrong category would show in a report.
    public var needsLook: Bool { duration >= ReviewList.minimumDuration }
}

/// What Review lists. The model's answers already count everywhere, so Review is for catching
/// the wrong ones, and only apps and sites used long enough to matter ask for a look. The
/// many used for a few seconds, a sign-in or a link followed, are kept apart.
public enum ReviewList {
    /// Over the segments given, which in the app are the last 30 days'.
    public static let minimumDuration: TimeInterval = 5 * 60

    /// One item per app or site in `segments`, leaving out the `reviewed` ones. Waiting first,
    /// then the least confident, then the most used.
    public static func items(_ segments: [ActivitySegment], reviewed: Set<String>,
                             confidence: (String) -> AIConfidence?) -> [ReviewItem] {
        var byKey: [String: ReviewItem] = [:]
        var titles: [String: [(title: String?, duration: TimeInterval)]] = [:]
        for segment in segments {
            let key = segment.classificationKey
            guard !reviewed.contains(key) else { continue }
            let duration = segment.duration
            titles[key, default: []].append((segment.title, duration))
            if byKey[key] != nil {
                byKey[key]?.duration += duration
            } else {
                byKey[key] = ReviewItem(key: key, bundleID: segment.bundleID, appName: segment.appName, domain: segment.domain,
                                        categoryKey: segment.categoryKey, source: segment.classificationSource,
                                        confidence: confidence(key), duration: duration, titles: [])
            }
        }
        for (key, samples) in titles {
            guard let appName = byKey[key]?.appName else { continue }
            byKey[key]?.titles = TitleSummary.mostUsed(samples, appName: appName, limit: 3)
        }
        func rank(_ item: ReviewItem) -> Int {
            switch (item.source, item.confidence) {
            case (.pending, _): 0
            case (_, .low?), (_, nil): 1
            case (_, .medium?): 2
            case (_, .high?): 3
            }
        }
        return byKey.values.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.duration > b.duration
        }
    }

    /// How many apps and sites in `segments` need a look, for the sidebar badge.
    public static func count(_ segments: [ActivitySegment], reviewed: Set<String>) -> Int {
        var durations: [String: TimeInterval] = [:]
        for segment in segments {
            let key = segment.classificationKey
            guard !reviewed.contains(key) else { continue }
            durations[key, default: 0] += segment.duration
        }
        return durations.values.count { $0 >= minimumDuration }
    }
}
