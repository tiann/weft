import Foundation
import SwiftData

/// The project a folder belongs to, as `ProjectResolver` works it out.
public struct ProjectIdentity: Sendable, Hashable {
    public var key: String
    public var name: String
    public var path: String
    public var remote: String?
    public var host: String?
}

/// Works out which project an agent's folder belongs to. Inside a git repository that's the
/// repository, so subfolders and worktrees count as its main checkout, and it's known by its
/// remote, so clones and other machines' checkouts match. Otherwise it's the folder itself.
/// Temporary folders and the home folder aren't projects. Reads a few small files under
/// `.git`; never runs git.
public struct ProjectResolver: Sendable {
    public static let temporaryFolders = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"]

    public var home: String
    /// Folders on this Mac whose contents are scratch work.
    public var temporaryFolders: [String]

    public init(home: String = NSHomeDirectory(), temporaryFolders: [String] = Self.temporaryFolders) {
        self.home = Self.trimmed(home)
        self.temporaryFolders = temporaryFolders
    }

    /// Nil for a folder that isn't a project. `host` is nil for this Mac; folders on other
    /// machines can't be looked into, so they're only known by their path.
    public func resolve(path: String, host: String?) -> ProjectIdentity? {
        if let host {
            let folder = Self.trimmed(path)
            guard !Self.isScratch(folder, home: nil, temporary: Self.temporaryFolders) else { return nil }
            return ProjectIdentity(key: "folder:\(host):\(folder)", name: Self.name(folder), path: folder, host: host)
        }
        let folder = Self.trimmed((path as NSString).standardizingPath)
        if let repository = repository(containing: folder) {
            if let remote = repository.remote {
                return ProjectIdentity(key: "git:\(remote.lowercased())", name: Self.name(remote), path: repository.root,
                                       remote: remote)
            }
            // `git init` in a temporary folder is still scratch work.
            guard !isScratch(repository.root) else { return nil }
            return ProjectIdentity(key: "folder:\(repository.root)", name: Self.name(repository.root), path: repository.root)
        }
        guard !isScratch(folder) else { return nil }
        return ProjectIdentity(key: "folder:\(folder)", name: Self.name(folder), path: folder)
    }

    // MARK: Git

    private struct Repository {
        /// The main checkout.
        var root: String
        var remote: String?
    }

    /// The repository `folder` is in. Also works for folders that are gone, such as a removed
    /// worktree inside the repository, by looking further up. Never looks at the home folder
    /// itself, which is often a repository of dotfiles.
    private func repository(containing folder: String) -> Repository? {
        let manager = FileManager.default
        var current = folder
        while current != "/", current != home, !current.isEmpty {
            let dotGit = current + "/.git"
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return Repository(root: current, remote: Self.remote(inConfig: dotGit + "/config"))
                }
                // A worktree or a submodule: the file says where its git folder is.
                if let gitDir = Self.gitDir(fromFile: dotGit, in: current) {
                    // Only a worktree's git folder points at the repository it belongs to.
                    if let common = Self.commonDir(of: gitDir) {
                        let root = (common as NSString).lastPathComponent == ".git"
                            ? (common as NSString).deletingLastPathComponent : common
                        return Repository(root: root, remote: Self.remote(inConfig: common + "/config"))
                    }
                    return Repository(root: current, remote: Self.remote(inConfig: gitDir + "/config"))
                }
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `gitdir: <path>` in a worktree's or submodule's `.git` file.
    private static func gitDir(fromFile path: String, in folder: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return absolute(target, relativeTo: folder)
    }

    private static func commonDir(of gitDir: String) -> String? {
        guard let text = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8) else { return nil }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : absolute(target, relativeTo: gitDir)
    }

    private static func absolute(_ path: String, relativeTo folder: String) -> String {
        trimmed(((path.hasPrefix("/") ? path : folder + "/" + path) as NSString).standardizingPath)
    }

    /// The `origin` remote, or else the first one, normalized.
    static func remote(inConfig path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var remotes: [(name: String, url: String)] = []
        var section: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // [remote "origin"]
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                section = header.hasPrefix("remote ")
                    ? header.dropFirst("remote ".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) : nil
            } else if let name = section, let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" {
                remotes.append((name, line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        let chosen = remotes.first { $0.name == "origin" } ?? remotes.first
        return chosen.flatMap { normalizedRemote($0.url) }
    }

    /// `git@github.com:owner/repo.git`, `https://token@github.com/owner/repo` and
    /// `ssh://git@github.com:22/owner/repo` all become `github.com/owner/repo`. Nil for a
    /// remote that's a folder on disk.
    static func normalizedRemote(_ url: String) -> String? {
        var rest = url.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let host: Substring
        var path: Substring
        if let scheme = rest.range(of: "://") {
            guard rest[..<scheme.lowerBound].lowercased() != "file" else { return nil }
            rest = String(rest[scheme.upperBound...])
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = rest[..<slash]
            // Credentials go before the host.
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            host = authority.split(separator: ":", maxSplits: 1).first ?? ""
            path = rest[slash...]
        } else if let colon = rest.firstIndex(of: ":"), !rest[..<colon].contains("/") {
            // scp-like: [user@]host:path
            var authority = rest[..<colon]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            host = authority
            path = rest[rest.index(after: colon)...]
        } else {
            return nil
        }
        path = path.drop { $0 == "/" }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return "\(host.lowercased())/\(path)"
    }

    // MARK: Folders

    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func name(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".git") && last.count > 4 ? String(last.dropLast(4)) : last
    }

    private func isScratch(_ path: String) -> Bool {
        Self.isScratch(path, home: home, temporary: temporaryFolders)
    }

    /// Temporary folders, the root and a home folder, where agents run for a quick question
    /// rather than on something. `home` is nil on another machine, where any home folder counts.
    private static func isScratch(_ path: String, home: String?, temporary: [String]) -> Bool {
        if path.isEmpty || path == "/" || path == "~" || path == home { return true }
        if temporary.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
        guard home == nil else { return false }
        let parts = path.split(separator: "/")
        return parts == ["root"] || (parts.count == 2 && (parts[0] == "home" || parts[0] == "Users"))
    }
}

@MainActor
public enum Projects {
    /// Works out the project of every session that has a folder but no project yet. Done
    /// once per session, so a project stays the same after its folder is removed.
    public static func assign(modelContext: ModelContext, resolver: ProjectResolver = ProjectResolver()) {
        let sessions = (try? modelContext.fetch(FetchDescriptor<AgentSession>(
            predicate: #Predicate { $0.projectKey == nil && $0.projectPath != nil }))) ?? []
        guard !sessions.isEmpty else { return }
        let existing = (try? modelContext.fetch(FetchDescriptor<Project>())) ?? []
        var projects = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved: [String: ProjectIdentity?] = [:]
        for session in sessions {
            guard let path = session.projectPath, !path.isEmpty else { continue }
            let lookup = "\(session.host ?? "")\u{0}\(path)"
            let identity = resolved[lookup] ?? {
                let identity = resolver.resolve(path: path, host: session.host)
                resolved[lookup] = identity
                return identity
            }()
            guard let identity else {
                session.projectKey = Project.none
                continue
            }
            if projects[identity.key] == nil {
                let project = Project(identity, colorSlot: projects.count)
                modelContext.insert(project)
                projects[identity.key] = project
            }
            session.projectKey = identity.key
        }
        try? modelContext.save()
    }
}
