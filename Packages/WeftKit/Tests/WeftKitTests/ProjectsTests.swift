import Foundation
import SwiftData
import Testing
@testable import WeftKit

struct ProjectResolverTests {
    let root: String
    let resolver: ProjectResolver

    init() throws {
        // Standardized, so it compares equal to the paths that come out.
        root = ((NSTemporaryDirectory() as NSString).appendingPathComponent("weft-projects-\(UUID().uuidString)") as NSString)
            .standardizingPath
        // These folders are in the temporary folder, which would make them scratch.
        resolver = ProjectResolver(home: root + "/home", temporaryFolders: ["/tmp", "/private/tmp"])
        try FileManager.default.createDirectory(atPath: root + "/home", withIntermediateDirectories: true)
    }

    private func folder(_ path: String) throws -> String {
        let full = root + "/" + path
        try FileManager.default.createDirectory(atPath: full, withIntermediateDirectories: true)
        return full
    }

    private func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// A repository at `path`, with `remote` as its origin.
    @discardableResult
    private func repository(_ path: String, remote: String? = nil) throws -> String {
        let folder = try folder(path)
        var config = "[core]\n\tbare = false\n"
        if let remote { config += "[remote \"origin\"]\n\turl = \(remote)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" }
        try write(config, to: folder + "/.git/config")
        return folder
    }

    private func resolve(_ path: String) -> ProjectIdentity? {
        resolver.resolve(path: path, host: nil)
    }

    @Test func aSubfolderBelongsToItsRepositoryKnownByItsRemote() throws {
        let repo = try repository("home/dev/weft", remote: "git@github.com:tiann/weft.git")
        let sub = try folder("home/dev/weft/Packages/WeftKit")
        let identity = try #require(resolve(sub))
        #expect(identity.key == "git:github.com/tiann/weft")
        #expect(identity.name == "weft")
        #expect(identity.path == repo)
        #expect(identity.remote == "github.com/tiann/weft")
        #expect(resolve(repo) == identity)
    }

    @Test func clonesWithTheSameRemoteAreOneProject() throws {
        let ssh = try repository("home/dev/hapi", remote: "git@github.com:tiann/hapi.git")
        let https = try repository("home/elsewhere/hapi-copy", remote: "https://github.com/Tiann/hapi")
        #expect(resolve(ssh)?.key == resolve(https)?.key)
    }

    @Test func aWorktreeBelongsToItsMainCheckout() throws {
        let main = try repository("home/dev/weft", remote: "git@github.com:tiann/weft.git")
        let tree = try folder("home/dev/weft/.claude/worktrees/feature")
        try write("gitdir: \(main)/.git/worktrees/feature\n", to: tree + "/.git")
        try write("../..\n", to: main + "/.git/worktrees/feature/commondir")
        // Codex keeps its worktrees outside the repository, with a relative gitdir.
        let codex = try folder("home/.codex/worktrees/1a2b/weft")
        try write("gitdir: ../../../../dev/weft/.git/worktrees/codex\n", to: codex + "/.git")
        try write("../..\n", to: main + "/.git/worktrees/codex/commondir")

        #expect(resolve(tree)?.path == main)
        #expect(resolve(tree)?.key == "git:github.com/tiann/weft")
        #expect(resolve(codex)?.path == main)

        // Once removed, the folder is still inside the repository.
        try FileManager.default.removeItem(atPath: tree)
        #expect(resolve(tree)?.path == main)
    }

    @Test func aSubmoduleIsItsOwnProject() throws {
        let outer = try repository("home/dev/app", remote: "git@github.com:me/app.git")
        let module = try folder("home/dev/app/vendor/lib")
        try write("gitdir: ../../.git/modules/lib\n", to: module + "/.git")
        try write("[remote \"origin\"]\n\turl = https://gitlab.com/them/lib.git\n", to: outer + "/.git/modules/lib/config")
        #expect(resolve(module)?.key == "git:gitlab.com/them/lib")
        #expect(resolve(module)?.path == module)
    }

    @Test func withoutARemoteTheRepositoryOrFolderIsTheProject() throws {
        let repo = try repository("home/dev/local-only")
        let sub = try folder("home/dev/local-only/src")
        #expect(resolve(sub)?.key == "folder:\(repo)")
        #expect(resolve(sub)?.name == "local-only")
        let plain = try folder("home/notes")
        #expect(resolve(plain)?.key == "folder:\(plain)")
        // A folder that's gone is still known by its path.
        #expect(resolve(root + "/home/dev/deleted")?.key == "folder:\(root)/home/dev/deleted")
    }

    @Test func homeTemporaryFoldersAndDotfilesArentProjects() throws {
        // Dotfiles kept in a repository at home don't make every folder there one project.
        try repository("home", remote: "git@github.com:me/dotfiles.git")
        let notes = try folder("home/notes")
        #expect(resolve(notes)?.key == "folder:\(notes)")
        #expect(resolve(root + "/home") == nil)
        #expect(resolve("/private/tmp") == nil)
        #expect(resolve("/tmp/scratch") == nil)
        #expect(resolve("/") == nil)
    }

    @Test func otherMachinesFoldersAreKnownByPath() {
        let identity = resolver.resolve(path: "/data/github/freedrop/", host: "debian")
        #expect(identity?.key == "folder:debian:/data/github/freedrop")
        #expect(identity?.name == "freedrop")
        #expect(identity?.host == "debian")
        #expect(resolver.resolve(path: "/tmp", host: "debian") == nil)
        #expect(resolver.resolve(path: "/home/me", host: "debian") == nil)
        #expect(resolver.resolve(path: "/root", host: "debian") == nil)
        #expect(resolver.resolve(path: "/home/me/code", host: "debian")?.name == "code")
    }

    @Test func remotesAreNormalizedWithoutCredentials() {
        #expect(ProjectResolver.normalizedRemote("git@github.com:tiann/weft.git") == "github.com/tiann/weft")
        #expect(ProjectResolver.normalizedRemote("https://x-access-token:ghp_secret@github.com/tiann/weft.git/") == "github.com/tiann/weft")
        #expect(ProjectResolver.normalizedRemote("ssh://git@GitHub.com:22/tiann/weft") == "github.com/tiann/weft")
        #expect(ProjectResolver.normalizedRemote("https://gitlab.example.com/group/sub/repo") == "gitlab.example.com/group/sub/repo")
        #expect(ProjectResolver.normalizedRemote("/Users/me/repos/weft.git") == nil)
        #expect(ProjectResolver.normalizedRemote("file:///Users/me/repos/weft") == nil)
        #expect(ProjectResolver.normalizedRemote("../weft") == nil)
    }

    @Test func originWinsOverOtherRemotes() throws {
        let repo = try folder("home/dev/fork")
        try write("""
            [remote "upstream"]
            \turl = git@github.com:them/fork.git
            [branch "main"]
            \tremote = origin
            [remote "origin"]
            \turl = git@github.com:me/fork.git
            """, to: repo + "/.git/config")
        #expect(resolve(repo)?.remote == "github.com/me/fork")
    }
}

@MainActor
struct ProjectAssignmentTests {
    @Test func sessionsGetTheirProjectOnceAndKeepIt() throws {
        let container = try WeftSchema.makeContainer(inMemory: true)
        let context = container.mainContext
        let resolver = ProjectResolver(home: "/Users/me")
        func session(_ key: String, path: String?, host: String? = nil) -> AgentSession {
            let session = AgentSession(key: key, source: .claudeCode, flavor: "claude", agentSessionID: key, lastActivity: .now)
            session.projectPath = path
            session.host = host
            context.insert(session)
            return session
        }
        let a = session("claude:a", path: "/Users/me/dev/gone-project")
        let b = session("claude:b", path: "/Users/me/dev/gone-project/")
        let tmp = session("claude:c", path: "/private/tmp")
        let remote = session("hapi:d", path: "/data/twoyi", host: "debian")
        let unknown = session("codex:e", path: nil)

        Projects.assign(modelContext: context, resolver: resolver)

        #expect(a.projectKey == "folder:/Users/me/dev/gone-project")
        #expect(b.projectKey == a.projectKey)
        #expect(tmp.projectKey == Project.none)
        #expect(remote.projectKey == "folder:debian:/data/twoyi")
        #expect(unknown.projectKey == nil)
        let projects = try context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.colorSlot)]))
        #expect(projects.map(\.colorSlot) == [0, 1])
        #expect(projects.first { $0.host == "debian" }?.name == "twoyi")

        // A later session joins the existing project; nothing is worked out again.
        a.projectKey = "kept"
        let f = session("claude:f", path: "/Users/me/dev/gone-project")
        Projects.assign(modelContext: context, resolver: resolver)
        #expect(a.projectKey == "kept")
        #expect(f.projectKey == "folder:/Users/me/dev/gone-project")
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 2)
    }
}

struct ProjectMetricsTests {
    private func sample(_ session: String, _ turn: String, _ start: Int, _ end: Int, subagent: Bool = false) -> AgentSample {
        AgentSample(sessionKey: session, turnID: turn, start: Fixture.date(Double(start)), end: Fixture.date(Double(end)), isSubagent: subagent)
    }

    @Test func parallelSessionsInAProjectCountOnce() {
        let samples = [
            sample("s1", "t1", 0, 600),
            sample("s2", "t2", 300, 900),
            sample("s2", "t2", 1200, 1500),
            sample("s1", "sub", 100, 200, subagent: true),
            sample("s3", "t3", 0, 60),
        ]
        let project = ["s1": "weft", "s2": "weft", "s3": "hapi"]
        let summaries = ProjectMetrics.summaries(samples) { project[$0] ?? Project.none }
        #expect(summaries.map(\.key) == ["weft", "hapi"])
        let weft = summaries[0]
        #expect(weft.time == 1200)
        #expect(weft.agentHours == 600 + 900)
        #expect(weft.sessions == 2)
        #expect(weft.turns == 2)
        #expect(weft.lastActive == Fixture.date(1500))
    }

    @Test func timeIsSplitIntoBuckets() {
        let samples = [sample("s1", "t1", 0, 600), sample("s2", "t2", 300, 1500)]
        let buckets = [
            DateInterval(start: Fixture.date(0), end: Fixture.date(1000)),
            DateInterval(start: Fixture.date(1000), end: Fixture.date(2000)),
        ]
        let time = ProjectMetrics.time(samples, by: { _ in "weft" }, in: buckets)
        #expect(time == [["weft": 1000], ["weft": 500]])
        let bySession = ProjectMetrics.time(samples, by: \.sessionKey, in: buckets)
        #expect(bySession[0] == ["s1": 600, "s2": 700])
    }
}

struct ReportPeriodTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ text: String) -> Date {
        var components = DateComponents()
        let parts = text.split(separator: "-").map { Int($0)! }
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        return calendar.date(from: components)!
    }

    @Test func periodsAndTheirBars() {
        let today = date("2026-10-29").addingTimeInterval(15 * 3600)
        let week = ReportPeriod.week.interval(containing: today, calendar: calendar)
        #expect(week.start == date("2026-10-26"))
        #expect(ReportPeriod.week.buckets(week, calendar: calendar).count == 7)

        let month = ReportPeriod.month.interval(containing: today, calendar: calendar)
        #expect(month == DateInterval(start: date("2026-10-01"), end: date("2026-11-01")))
        #expect(ReportPeriod.month.buckets(month, calendar: calendar).count == 31)
        #expect(ReportPeriod.month.previous(month, calendar: calendar) == DateInterval(start: date("2026-09-01"), end: date("2026-10-01")))

        let year = ReportPeriod.year.interval(containing: today, calendar: calendar)
        #expect(ReportPeriod.year.buckets(year, calendar: calendar).count == 12)

        let all = ReportPeriod.all.interval(containing: today, first: date("2025-11-20"), calendar: calendar)
        #expect(all == DateInterval(start: date("2025-11-01"), end: date("2026-11-01")))
        #expect(ReportPeriod.all.buckets(all, calendar: calendar).count == 12)
        #expect(ReportPeriod.all.previous(all, calendar: calendar) == nil)
        #expect(ReportPeriod.all.interval(containing: today, calendar: calendar) == month)

        let weeks = ReportPeriod.steps(of: .weekOfYear, covering: DateInterval(start: date("2026-10-01"), end: today), calendar: calendar)
        #expect(weeks.first?.start == date("2026-09-28"))
        #expect(weeks.last?.end == date("2026-11-02"))
        #expect(weeks.count == 5)
    }
}
