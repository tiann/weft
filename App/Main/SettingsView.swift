import WeftKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The standard macOS settings window (⌘,), one tab per area.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Model", systemImage: "sparkles") { ModelSettings() }
            Tab("Tracking", systemImage: "record.circle") { TrackingSettings() }
            Tab("Sessions", systemImage: "timer") { SessionSettings() }
            Tab("Agents", systemImage: "cpu") { AgentSettings() }
            Tab("Blocker", systemImage: "hand.raised") { BlockerSettings() }
            Tab("Data", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
        .onAppear { model.refreshPermissions() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var language = AppLanguage.current

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("Launch Weft at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
                Toggle("Pause tracking", isOn: $prefs.trackingPaused)
            }
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: language) { _, value in value.apply() }
                if language != AppLanguage.atLaunch {
                    LabeledContent {
                        Button("Relaunch") { AppLanguage.relaunch() }
                    } label: {
                        Text("Weft uses the new language after it relaunches.")
                    }
                }
            }
            Section("Work hours") {
                Picker("Daily target", selection: $prefs.workHoursTarget) {
                    ForEach([4.0, 5, 6, 7, 7.5, 8, 8.5, 9, 10, 12], id: \.self) { hours in
                        Text(Format.duration(hours * 3600)).tag(hours)
                    }
                }
                Toggle("Notify when I reach the target and when I'm overworking", isOn: $prefs.workHoursNotifications)
                if prefs.workHoursNotifications { NotificationsOffNote() }
            }
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed to read window titles.",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    switch model.notificationPermission {
                    case .allowed?: Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .notDetermined?: Button("Allow", action: model.enableNotifications)
                    case .denied?: Button("Open Settings", action: model.enableNotifications)
                    case nil: EmptyView()
                    }
                } label: {
                    Text("Notifications")
                    Text("Needed for break reminders, work-hours alerts and session endings.")
                }
                LabeledContent {
                    Button("Open Settings") { SystemSettings.openAutomation() }
                } label: {
                    Text("Browsers")
                    Text("Each browser asks once whether Weft may read the active tab's URL.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shown next to settings that rely on notifications macOS won't deliver.
private struct NotificationsOffNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let permission = model.notificationPermission, permission != .allowed {
            LabeledContent {
                Button(permission == .notDetermined ? "Allow" : "Open Settings", action: model.enableNotifications)
            } label: {
                Label("Notifications are off for Weft, so these can't reach you.", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant Access", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Model

private struct ModelSettings: View {
    @Environment(AppModel.self) private var model
    @State private var baseURL = ""
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var loaded = false
    /// The category the server gave Xcode, or why it couldn't answer.
    @State private var check: Result<String, any Error>?
    @State private var isChecking = false
    /// Bumped to check the server again.
    @State private var checks = 0

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("Categorize with", selection: $prefs.modelProvider) {
                    Text("Apple Intelligence").tag(ModelProvider.appleIntelligence)
                    Text("OpenAI-compatible API").tag(ModelProvider.openAICompatible)
                }
                LabeledContent {
                    switch (model.classifier.aiAvailability, prefs.modelProvider) {
                    case (.available, .appleIntelligence):
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case (.unavailable, .appleIntelligence):
                        Button("Open Settings") { SystemSettings.openAppleIntelligence() }
                    case (.unavailable, .openAICompatible):
                        Label("Not set up", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case (.available, .openAICompatible):
                        if isChecking {
                            ProgressView().controlSize(.small)
                        } else if case .success = check {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if case .failure = check {
                            Label("Can't connect", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                } label: {
                    Text("Status")
                    switch (model.classifier.aiAvailability, prefs.modelProvider) {
                    case (.available, .appleIntelligence):
                        Text("Runs on this Mac.")
                    case (.unavailable(let reason), _):
                        Text("\(reason) Until a model is available, Weft guesses from each app's App Store category and each site's name.")
                    case (.available, .openAICompatible):
                        switch check {
                        case _ where isChecking: Text("Checking \(host)…")
                        case .success(let category)?: Text("Requests go to \(host), which put Xcode in \(category).")
                        case .failure(let error)?: Text("\(error.localizedDescription) Until it answers, Weft guesses instead.")
                        case nil: Text("Requests go to \(host).")
                        }
                    }
                }
            } footer: {
                Text("The model categorizes apps and sites no rule knows, describes your work streams and writes daily reviews.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if prefs.modelProvider == .openAICompatible {
                Section {
                    TextField("Base URL", text: $baseURL, prompt: Text(RemoteModelConfig.defaultBaseURL))
                    TextField("Model", text: $modelName, prompt: Text("gpt-5-mini"))
                    SecureField("API key", text: $apiKey, prompt: Text("Not needed for local servers"))
                    HStack {
                        Spacer()
                        Button("Save", action: save).disabled(isChecking)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Works with OpenAI and any server with a compatible Chat Completions API, such as OpenRouter, DeepSeek, Ollama or LM Studio. Weft sends it the apps and sites it doesn't know with their window titles, the apps, sites and window titles behind each work stream, and your daily totals. The API key is kept in your keychain.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadServer)
        .task(id: checks) { await checkServer() }
        .onChange(of: prefs.modelProvider) {
            model.applyModelChoice()
            loadServer()
            checks += 1
        }
    }

    private var host: String {
        RemoteModelConfig(baseURL: model.preferences.remoteBaseURL, model: "", apiKey: "").endpoint?.host() ?? String(localized: "the server")
    }

    /// Fills in the saved server, reading the keychain only once a remote model is chosen.
    private func loadServer() {
        guard !loaded, model.preferences.modelProvider == .openAICompatible else { return }
        baseURL = model.preferences.remoteBaseURL
        modelName = model.preferences.remoteModel
        apiKey = Keychain.string(for: AppModel.apiKeyAccount) ?? ""
        loaded = true
    }

    /// Saves the server, switches to it and checks that it answers.
    private func save() {
        model.preferences.remoteBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model.preferences.remoteModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: AppModel.apiKeyAccount)
        model.applyModelChoice()
        checks += 1
    }

    /// Asks the server about Xcode, so Status says whether it really answers rather than
    /// only whether it's filled in. Runs when the tab opens, the model changes or on Save.
    private func checkServer() async {
        check = nil
        isChecking = false
        guard model.preferences.modelProvider == .openAICompatible, model.classifier.aiAvailability == .available
        else { return }
        isChecking = true
        let outcome: Result<String, any Error>
        do {
            let xcode = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
            let result = try await model.ai.classify(xcode, categories: model.classifier.categories)
            outcome = .success(model.classifier.category(result.categoryKey).displayName)
        } catch {
            outcome = .failure(error)
        }
        // A newer check replaced this one.
        guard !Task.isCancelled else { return }
        check = outcome
        isChecking = false
    }
}

// MARK: - Tracking

private struct TrackingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newDomain = ""

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("Count as away after", selection: $prefs.idleThresholdMinutes) {
                    ForEach([1, 2, 3, 5, 10, 15, 30], id: \.self) { Text("\($0) min without input").tag($0) }
                }
            } footer: {
                Text("Meetings and video calls are never counted as away.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Don't record window titles", isOn: $prefs.stripTitles)
                Toggle("Only record the domain of URLs", isOn: $prefs.urlHostOnly)
            }
            Section {
                ForEach(prefs.excludedBundleIDs, id: \.self) { bundleID in
                    RemovableRow {
                        AppLabel(bundleID: bundleID)
                    } onRemove: {
                        prefs.excludedBundleIDs.removeAll { $0 == bundleID }
                    }
                }
                AppPicker(excluding: Set(prefs.excludedBundleIDs)) { bundleID in
                    prefs.excludedBundleIDs.append(bundleID)
                }
            } header: {
                Text("Never track these apps")
            }
            Section("Never track these websites") {
                ForEach(prefs.excludedDomains, id: \.self) { domain in
                    RemovableRow {
                        Label(domain, systemImage: "globe")
                    } onRemove: {
                        prefs.excludedDomains.removeAll { $0 == domain }
                    }
                }
                HStack {
                    TextField("Domain", text: $newDomain, prompt: Text("bank.example.com"))
                        .labelsHidden()
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        var value = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let domain = ActivityContext.domain(from: value.contains("://") ? value : "https://\(value)") { value = domain }
        guard !value.isEmpty, !model.preferences.excludedDomains.contains(value) else { return }
        model.preferences.excludedDomains.append(value)
        newDomain = ""
    }
}

/// Adds an app from the ones currently running, or any app chosen in an open panel.
private struct AppPicker: View {
    let excluding: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
                .filter { !excluding.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            Section("Running apps") {
                ForEach(running, id: \.0) { bundleID, name in
                    Button {
                        onPick(bundleID)
                    } label: {
                        Label { Text(name) } icon: { Image(nsImage: AppIcons.icon(for: bundleID)) }
                    }
                }
            }
            Divider()
            Button("Choose Another App…", action: chooseApp)
        } label: {
            Label("Add App", systemImage: "plus")
        }
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !excluding.contains(bundleID) else { return }
        onPick(bundleID)
    }
}

struct AppLabel: View {
    let bundleID: String

    var body: some View {
        Label {
            Text(Self.name(for: bundleID))
        } icon: {
            Image(nsImage: AppIcons.icon(for: bundleID)).resizable().frame(width: 18, height: 18)
        }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct RemovableRow<Content: View>: View {
    @ViewBuilder let content: Content
    let onRemove: () -> Void

    var body: some View {
        HStack {
            content
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}

// MARK: - Sessions

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section("Default durations") {
                durationPicker("Focus", $prefs.defaultFocusMinutes, options: [15, 20, 25, 30, 45, 50, 60, 90, 120])
                durationPicker("Meeting", $prefs.defaultMeetingMinutes, options: [15, 20, 25, 30, 45, 60, 90, 120])
                durationPicker("Break", $prefs.defaultBreakMinutes, options: [1, 3, 5, 10, 15, 20, 30])
                Toggle("Show breaks full screen", isOn: $prefs.fullScreenBreak)
            }
            Section {
                Toggle("Remind me to take breaks", isOn: $prefs.breakRemindersEnabled)
                durationPicker("After working for", $prefs.breakReminderMinutes, options: [20, 30, 45, 60, 75, 90, 120])
                    .disabled(!prefs.breakRemindersEnabled)
                durationPicker("Snooze for", $prefs.snoozeMinutes, options: [5, 10, 15, 20, 30])
                    .disabled(!prefs.breakRemindersEnabled)
                if prefs.breakRemindersEnabled { NotificationsOffNote() }
            } header: {
                Text("Break reminders")
            } footer: {
                Text("Only active time counts; being away from the Mac for 5 minutes or more resets the timer.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func durationPicker(_ title: LocalizedStringKey, _ value: Binding<Int>, options: [Int]) -> some View {
        Picker(title, selection: value) {
            ForEach(Array(Set(options + [value.wrappedValue])).sorted(), id: \.self) { minutes in
                Text(Format.minutesLabel(minutes)).tag(minutes)
            }
        }
    }
}

// MARK: - Agents

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    @Query private var sessions: [AgentSession]

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("Show when coding agents work for me", isOn: $prefs.agentTrackingEnabled)
            } footer: {
                Text("Weft uses HAPI history when available, otherwise reads the session logs Claude Code, Codex and pi keep on this Mac. It keeps only session titles, project folders and times; prompts and replies are never stored or sent anywhere.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Agents") {
                source("Claude Code", flavor: "claude", folder: AgentLogRoots.standard.claudeProjects, isOn: $prefs.agentClaudeEnabled)
                source("Codex", flavor: "codex", folder: AgentLogRoots.standard.codexSessions, isOn: $prefs.agentCodexEnabled)
                source("pi", flavor: "pi", folder: AgentLogRoots.standard.piSessions, isOn: $prefs.agentPiEnabled)
            }
            .disabled(!prefs.agentTrackingEnabled)
            Section {
                Toggle("Include agents from HAPI", isOn: $prefs.agentHAPIEnabled)
                if prefs.agentHAPIEnabled {
                    LabeledContent {
                        if model.hapi.status == .syncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Sync Now") { Task { await model.hapi.sync() } }
                        }
                    } label: {
                        Text("Status")
                        Text(hapiStatus)
                    }
                    LabeledContent {
                        HStack {
                            if !prefs.agentHAPIPath.isEmpty {
                                Button("Find Automatically") { prefs.agentHAPIPath = "" }
                            }
                            Button("Choose…", action: chooseHAPI)
                        }
                    } label: {
                        Text("hapi")
                        Text(model.hapi.binary.map { ($0.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath } ?? String(localized: "Not found"))
                    }
                }
            } header: {
                Text("HAPI")
            } footer: {
                Text("For sessions recorded by your HAPI hub, Weft uses only HAPI history and skips local logs. Saved HAPI history stays authoritative when syncing is off or unavailable; other sessions use local logs.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!prefs.agentTrackingEnabled)
            Section {
                Toggle("Count time waiting on agents as work", isOn: $prefs.countAgentWaiting)
                Picker("Count time away for up to", selection: $prefs.agentWaitingCapMinutes) {
                    ForEach(Array(Set([15, 30, 60, 90, 120, prefs.agentWaitingCapMinutes])).sorted(), id: \.self) {
                        Text(Format.minutesLabel($0)).tag($0)
                    }
                }
                .disabled(!prefs.countAgentWaiting)
            } header: {
                Text("Waiting")
            } footer: {
                Text("While an agent works for you, time away from the Mac adds to tracked time, up to this long after you leave, and time in distracting categories shows as waiting instead of distracted. The Focus Score only ever looks at your own activity.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!prefs.agentTrackingEnabled)
            Section {
                Picker("Leave out silences longer than", selection: $prefs.agentSilentGapMinutes) {
                    ForEach(Array(Set([10, 15, 30, 60, 120, prefs.agentSilentGapMinutes])).sorted(), id: \.self) {
                        Text(Format.minutesLabel($0)).tag($0)
                    }
                }
                .onChange(of: prefs.agentSilentGapMinutes) { model.agents.reimport() }
                Picker("Read history from the last", selection: $prefs.agentBackfillDays) {
                    ForEach(Array(Set([7, 30, 90, 365, prefs.agentBackfillDays])).sorted(), id: \.self) {
                        Text("\($0) days").tag($0)
                    }
                }
                .onChange(of: prefs.agentBackfillDays) { model.agents.requestScan() }
                LabeledContent {
                    if model.agents.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Read Again") { model.agents.reimport() }
                    }
                } label: {
                    Text("Agent history")
                    Text(status)
                }
            } header: {
                Text("History")
            } footer: {
                Text("HAPI history follows the turns and waits reported by your hub. For local-log sessions, work runs from your prompt until the answer, excluding permission waits and long silences. Read Again rebuilds only local-log history.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(!prefs.agentTrackingEnabled)
        }
        .formStyle(.grouped)
    }

    private func source(_ name: String, flavor: String, folder: URL, isOn: Binding<Bool>) -> some View {
        let path = folder.path(percentEncoded: false)
        let found = FileManager.default.fileExists(atPath: path)
        let imported = Set(sessions.filter { $0.source == .hapi }.map(\.key))
        let count = sessions.filter { session in
            guard session.flavor == flavor else { return false }
            if session.source != .hapi, let id = session.hapiSessionID, imported.contains("hapi:\(id)") { return false }
            return true
        }.count
        return Toggle(isOn: isOn) {
            Label {
                Text(name)
                Text(!found ? String(localized: "Not found on this Mac") : count == 1 ? String(localized: "\((path as NSString).abbreviatingWithTildeInPath) · 1 session") : String(localized: "\((path as NSString).abbreviatingWithTildeInPath) · \(count) sessions"))
            } icon: {
                Image(systemName: AgentStyle.symbol(flavor)).foregroundStyle(AgentStyle.color(flavor)).frame(width: 22)
            }
        }
        .disabled(!found && !isOn.wrappedValue)
    }

    private var hapiStatus: String {
        switch model.hapi.status {
        case .off: String(localized: "Off")
        case .notInstalled: String(localized: "hapi isn't installed, or isn't anywhere Weft looks. Choose it below.")
        case .cliTooOld(let version): String(localized: "This hapi\(version.map { " (\($0))" } ?? "") can't report agent activity yet. Update HAPI.")
        case .hubTooOld: String(localized: "Your HAPI hub doesn't report agent activity yet. Update the hub.")
        case .notSignedIn: String(localized: "hapi isn't signed in to a hub. Run `hapi auth login`.")
        case .syncing: String(localized: "Syncing…")
        case .synced(let date):
            String(localized: "Synced \(date.formatted(.relative(presentation: .named)))\(model.hapi.hubURL.flatMap { URL(string: $0)?.host() }.map { String(localized: " from \($0)") } ?? "")")
        case .failed(let message): message
        }
    }

    private func chooseHAPI() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the hapi executable")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".bun/bin")
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.preferences.agentHAPIPath = url.path(percentEncoded: false)
    }

    private var status: String {
        let agents = model.agents
        if agents.isScanning { return String(localized: "Reading logs… \(agents.progress.done) of \(agents.progress.total)") }
        guard let last = agents.lastScan else { return String(localized: "Not read yet") }
        let read = last.formatted(.relative(presentation: .named))
        return sessions.count == 1 ? String(localized: "1 session, last read \(read)") : String(localized: "\(sessions.count) sessions, last read \(read)")
    }
}

// MARK: - Blocker

private struct BlockerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("Block distractions during focus sessions", isOn: $prefs.blockerEnabled)
                Picker("Style", selection: $prefs.blockerStyle) {
                    Text("Full-screen overlay").tag(BlockerStyle.overlay)
                    Text("Notification").tag(BlockerStyle.notification)
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.blockerEnabled)
                Picker("Interrupt after", selection: $prefs.refocusThresholdSeconds) {
                    ForEach(Array(Set([0, 5, 10, 15, 30, 60, prefs.refocusThresholdSeconds])).sorted(), id: \.self) { seconds in
                        Text(seconds == 0 ? "Immediately" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .disabled(!prefs.blockerEnabled)
            } footer: {
                Text("Categories marked as distracting trigger the blocker. Change them under Categories.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Never block") {
                if prefs.blockerAllowList.isEmpty {
                    Text("Apps and sites you mark as “not a distraction” appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(prefs.blockerAllowList, id: \.self) { key in
                    RemovableRow {
                        AllowListLabel(key: key)
                    } onRemove: {
                        prefs.blockerAllowList.removeAll { $0 == key }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Allow-list keys are classification keys: `bundleID` or `bundleID|domain`.
private struct AllowListLabel: View {
    let key: String

    var body: some View {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            Label(parts[1], systemImage: "globe")
        } else {
            AppLabel(bundleID: parts[0])
        }
    }
}

// MARK: - Data

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @State private var exportMessage: String?

    private var dataFolder: URL { WeftSchema.dataFolder }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Export CSV…", action: exportCSV)
                } label: {
                    Text("Export all activity")
                    Text("Every tracked entry with app, title, URL and category.")
                }
                if let exportMessage {
                    Text(exportMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dataFolder]) }
                } label: {
                    Text("Data folder")
                    Text("Everything stays on this Mac, in \(dataFolder.path(percentEncoded: false)).")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "weft-activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(sortBy: [SortDescriptor(\.start)]))) ?? []
        let iso = ISO8601DateFormatter()
        var csv = "start,end,duration_seconds,app,bundle_id,domain,title,url,category,classification\n"
        for segment in segments {
            let fields: [String] = [
                iso.string(from: segment.start), iso.string(from: segment.end), String(Int(segment.duration)),
                segment.appName, segment.bundleID, segment.domain ?? "", segment.title ?? "", segment.url ?? "",
                model.classifier.category(segment.categoryKey).name, segment.classificationSourceRaw,
            ]
            csv += fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = String(localized: "Exported \(segments.count) entries.")
        } catch {
            exportMessage = String(localized: "Export failed: \(error.localizedDescription)")
        }
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
