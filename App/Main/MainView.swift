import WeftKit
import SwiftData
import SwiftUI

struct MainView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(\.liveness) private var liveness
    @State private var showOnboarding = false
    @Query private var unconfirmed: [ActivitySegment]
    @State private var badge = Memo<Int>()

    init() {
        let since = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let pending = ClassificationSource.pending.rawValue
        let guess = ClassificationSource.guess.rawValue
        let ai = ClassificationSource.ai.rawValue
        _unconfirmed = Query(filter: #Predicate<ActivitySegment> {
            $0.end > since && ($0.classificationSourceRaw == pending || $0.classificationSourceRaw == guess
                || $0.classificationSourceRaw == ai)
        })
    }

    var body: some View {
        // Apps and sites waiting in Review, apart from the briefly used ones.
        let reviewCount = badge.value(liveness) { ReviewList.count(unconfirmed, reviewed: model.classifier.reviewedKeys) }
        NavigationSplitView {
            List(Page.allCases, id: \.self, selection: Binding<Page?>(
                get: { model.page },
                set: { if let page = $0 { model.page = page } }
            )) { page in
                Label(page.title, systemImage: page.symbol)
                    .badge(page == .review ? reviewCount : 0)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.page {
            case .today: DayView()
            case .reports: ReportsView()
            case .review: ReviewView()
            case .categories: CategoriesView()
            case .rules: RulesView()
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
                .environment(model)
        }
        .onAppear {
            // Show in the Dock and Cmd-Tab while the window is open.
            NSApp.setActivationPolicy(.regular)
            showOnboarding = !model.preferences.hasCompletedOnboarding
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}
