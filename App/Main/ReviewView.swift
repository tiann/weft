import WeftKit
import SwiftData
import SwiftUI

/// Apps and sites no rule knew: still waiting for the model, guessed without one, or
/// classified by it and not yet looked at. Keeping the model's answer marks it reviewed;
/// keeping a guess or changing a category creates a rule. Either takes it off this list.
/// Apps and sites used only briefly are listed apart and left out of the badge.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.liveness) private var liveness
    @Query private var segments: [ActivitySegment]
    /// Shown unchanged while not live (see `Liveness`).
    @State private var shown = Memo<[ReviewItem]>()
    @State private var showsBrief = false

    init() {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let pending = ClassificationSource.pending.rawValue
        let guess = ClassificationSource.guess.rawValue
        let ai = ClassificationSource.ai.rawValue
        _segments = Query(filter: #Predicate<ActivitySegment> {
            $0.end > since && ($0.classificationSourceRaw == pending || $0.classificationSourceRaw == guess
                || $0.classificationSourceRaw == ai)
        })
    }

    var body: some View {
        let items = shown.value(liveness) {
            ReviewList.items(segments, reviewed: model.classifier.reviewedKeys, confidence: model.classifier.confidence(forKey:))
        }
        let main = items.filter(\.needsLook)
        let brief = items.filter { !$0.needsLook }
        let listed = showsBrief ? main + brief : main
        VStack(spacing: 0) {
            statusBar
            Divider()
            if items.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle",
                                       description: Text("Every app and site from the last 30 days is covered by a rule or has been reviewed."))
                    .frame(maxHeight: .infinity)
            } else if listed.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to review", systemImage: "checkmark.circle")
                } description: {
                    Text("Only apps and sites used for less than 5 minutes in the last 30 days are left.")
                } actions: {
                    Button("Show Them") { showsBrief = true }
                }
                .frame(maxHeight: .infinity)
            } else {
                table(main: main, brief: showsBrief ? brief : [])
                if !brief.isEmpty {
                    Divider()
                    briefBar(brief)
                }
            }
        }
        .navigationTitle("Review")
        .toolbar {
            let answered = listed.filter { $0.source == .ai }
            Button {
                model.classifier.markReviewed(answered.map(\.key))
            } label: {
                Label("Mark \(answered.count) as Reviewed", systemImage: "checkmark.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(answered.isEmpty)
            .help("Keep the model's category for every app and site listed, and take them off this list")
        }
    }

    private func table(main: [ReviewItem], brief: [ReviewItem]) -> some View {
        Table(of: ReviewItem.self) {
            TableColumn("App / Site") { item in
                HStack {
                    Image(nsImage: AppIcons.icon(for: item.bundleID)).resizable().frame(width: 16, height: 16)
                    VStack(alignment: .leading) {
                        Text(item.domain ?? item.appName)
                        if !item.titles.isEmpty {
                            Text(item.titles.prefix(2).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if item.domain != nil {
                            Text(item.appName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(item.titles.joined(separator: "\n"))
                }
            }
            TableColumn("Time (30 days)") { item in
                Text(Format.duration(item.duration)).monospacedDigit()
            }
            .width(110)
            TableColumn("Status") { item in
                switch item.source {
                case .pending: Label("Waiting", systemImage: "hourglass").foregroundStyle(.secondary)
                case .guess: Label("Guess", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                default: Text("AI · \(item.confidence.map { String(localized: String.LocalizationValue($0.rawValue)) } ?? "?") confidence").foregroundStyle(.secondary)
                }
            }
            .width(160)
            TableColumn("Category") { item in
                Picker("", selection: Binding(
                    get: { item.categoryKey },
                    set: { assign(item, to: $0) }
                )) {
                    ForEach(model.classifier.categories) { category in
                        Text(category.displayName).tag(category.key)
                    }
                }
                .labelsHidden()
            }
            .width(180)
            TableColumn("") { item in
                let category = model.classifier.category(item.categoryKey).displayName
                Button {
                    if item.source == .ai {
                        model.classifier.markReviewed([item.key])
                    } else {
                        assign(item, to: item.categoryKey)
                    }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(item.source == .pending)
                .help(item.source == .ai ? "Looks right — keep \(category) and take it off this list"
                                         : "Looks right — keep \(category) for this app/site")
            }
            .width(30)
        } rows: {
            ForEach(main) { TableRow($0) }
            if !brief.isEmpty {
                Section("Used for less than 5 minutes") {
                    ForEach(brief) { TableRow($0) }
                }
            }
        }
    }

    private func briefBar(_ brief: [ReviewItem]) -> some View {
        HStack {
            Text("\(brief.count) app(s)/site(s) used for less than 5 minutes each, \(Format.duration(brief.reduce(0) { $0 + $1.duration })) in all.")
                .foregroundStyle(.secondary)
            Spacer()
            Button(showsBrief ? "Hide" : "Show") { showsBrief.toggle() }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack {
            switch model.classifier.aiAvailability {
            case .available:
                let queued = model.classifier.queuedCount
                Image(systemName: "sparkles")
                Text(queued > 0
                     ? "Classifying \(queued) app(s)/site(s) \(model.modelPlace)…"
                     : "Unknown apps and sites are classified \(model.modelPlace).")
                if queued > 0 { ProgressView().controlSize(.small) }
            case .unavailable(let reason):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("\(reason) Weft guesses from each app's App Store category and each site's name until a model is available.")
                SettingsLink { Text("Model Settings…") }
            }
            Spacer()
            Button("Retry") { model.classifier.retryPending() }
                .help("Ask the model again about everything still waiting or guessed")
        }
        .font(.callout)
        .padding(12)
    }

    private func assign(_ item: ReviewItem, to categoryKey: String) {
        if let domain = item.domain {
            model.classifier.addRule(field: .domain, pattern: domain, categoryKey: categoryKey)
        } else {
            model.classifier.addRule(field: .bundleID, pattern: item.bundleID, categoryKey: categoryKey)
        }
    }
}
