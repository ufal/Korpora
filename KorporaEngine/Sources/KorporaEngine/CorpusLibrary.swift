import Foundation

/// Every corpus the app can open: pando index folders. The file-level half of
/// Settings > Corpora (docs/pando-gui-plan.md).
///
/// A corpus is a folder with a `corpus.info` (what `pando-index` writes); its
/// name is the folder name. Two places provide them:
/// - **built**: corpora Korpora indexed itself, in `baseDirectory`;
/// - **linked**: index folders that live elsewhere (built with `pando-index`
///   on a server, a shared drive, a download), each a symlink in
///   `linkedDirectory`, so Korpora never copies or owns their data.
public enum CorpusLibrary {
    /// Built corpora, one folder each. Finder-visible.
    /// `KORPORA_CORPORA_DIRECTORY` overrides it (tests, development).
    public static var baseDirectory: URL {
        directory(environment: "KORPORA_CORPORA_DIRECTORY", default: "Korpora/Corpora")
    }

    /// Symlinks to index folders kept elsewhere.
    /// `KORPORA_LINKED_CORPORA_DIRECTORY` overrides it.
    public static var linkedDirectory: URL {
        directory(environment: "KORPORA_LINKED_CORPORA_DIRECTORY", default: "Korpora/LinkedCorpora")
    }

    /// Where a built corpus goes when it is removed but its data kept.
    public static var removedDirectory: URL {
        baseDirectory.appendingPathComponent(".Removed", isDirectory: true)
    }

    private static func directory(environment: String, default fallback: String) -> URL {
        if let override = ProcessInfo.processInfo.environment[environment], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(fallback, isDirectory: true)
    }

    public enum Origin: Sendable, Equatable {
        case built
        /// The index folder the symlink points at.
        case linked(target: URL)
    }

    public struct Entry: Sendable, Equatable {
        public var name: String
        public var origin: Origin
        /// The index folder as pando opens it (for a linked corpus, the link).
        public var directory: URL
        /// Tokens in the corpus, from `corpus.info`; nil if unreadable.
        public var tokens: Int?

        public var isLinked: Bool {
            if case .linked = origin { return true }
            return false
        }
    }

    public enum LibraryError: Error, CustomStringConvertible, Equatable {
        case nameTaken(String)
        case notACorpus(URL)

        public var description: String {
            switch self {
            case .nameTaken(let name):
                return "A corpus named \u{201C}\(name)\u{201D} is already in Korpora."
            case .notACorpus(let url):
                return "\u{201C}\(url.lastPathComponent)\u{201D} isn\u{2019}t an indexed corpus (it has no corpus.info)."
            }
        }
    }

    // MARK: Listing

    /// Whether `directory` is a pando index folder.
    public static func isCorpus(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("corpus.info").path)
    }

    /// The token count recorded in a corpus' `corpus.info` (`size=N`).
    public static func tokenCount(of directory: URL) -> Int? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("corpus.info"), encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") where line.hasPrefix("size=") {
            return Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func corpusFolders(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { !$0.hasPrefix(".") }
            .map { directory.appendingPathComponent($0, isDirectory: true) }
            .filter { isCorpus($0) }
    }

    /// Every corpus: built first, then linked; a name found twice is listed once (built wins).
    public static func entries() -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for folder in corpusFolders(in: baseDirectory) where seen.insert(folder.lastPathComponent).inserted {
            result.append(Entry(name: folder.lastPathComponent, origin: .built, directory: folder,
                                tokens: tokenCount(of: folder)))
        }
        for link in corpusFolders(in: linkedDirectory) where seen.insert(link.lastPathComponent).inserted {
            result.append(Entry(name: link.lastPathComponent,
                                origin: .linked(target: link.resolvingSymlinksInPath()),
                                directory: link, tokens: tokenCount(of: link)))
        }
        return result
    }

    public static func names() -> [String] { entries().map(\.name) }

    /// Where the corpus called `name` is; nil if there is none.
    public static func directory(forName name: String) -> URL? {
        entries().first { $0.name == name }?.directory
    }

    // MARK: Adding

    /// Links an index folder that lives elsewhere. The name is the folder name.
    /// - Parameter taken: names already in use, refused as `nameTaken`.
    @discardableResult
    public static func link(indexDirectory: URL, taken: Set<String>) throws -> Entry {
        let target = indexDirectory.resolvingSymlinksInPath()
        guard isCorpus(target) else { throw LibraryError.notACorpus(target) }
        let name = target.lastPathComponent
        guard !taken.contains(name) else { throw LibraryError.nameTaken(name) }
        try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        let link = linkedDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return Entry(name: name, origin: .linked(target: target), directory: link, tokens: tokenCount(of: target))
    }

    /// Links every index folder directly inside `folder`. Returns what was
    /// added and what was skipped (name taken).
    public static func linkAll(inDirectory folder: URL, taken: Set<String>)
        -> (added: [Entry], skipped: [(name: String, reason: LibraryError)]) {
        var taken = taken
        var added: [Entry] = []
        var skipped: [(String, LibraryError)] = []
        for candidate in corpusFolders(in: folder) {
            do {
                let entry = try link(indexDirectory: candidate, taken: taken)
                added.append(entry)
                taken.insert(entry.name)
            } catch let error as LibraryError {
                skipped.append((candidate.lastPathComponent, error))
            } catch {
                skipped.append((candidate.lastPathComponent, .notACorpus(candidate)))
            }
        }
        return (added, skipped)
    }

    // MARK: Removing

    /// Removes a corpus from Korpora.
    /// - `deleteData: true` deletes the index (for a linked corpus, the folder
    ///   the link leads to, too).
    /// - `deleteData: false` keeps it: a linked corpus loses only its link; a
    ///   built one moves to `removedDirectory/<name>/`, from where it can be
    ///   linked again.
    /// - Returns: for a kept built corpus, its new place.
    @discardableResult
    public static func remove(_ entry: Entry, deleteData: Bool) throws -> URL? {
        let fm = FileManager.default
        switch entry.origin {
        case .linked(let target):
            try fm.removeItem(at: entry.directory)
            if deleteData { try? fm.removeItem(at: target) }
            return nil
        case .built:
            if deleteData {
                try fm.removeItem(at: entry.directory)
                return nil
            }
            try fm.createDirectory(at: removedDirectory, withIntermediateDirectories: true)
            var destination = removedDirectory.appendingPathComponent(entry.name, isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: destination.path) {
                destination = removedDirectory.appendingPathComponent("\(entry.name) \(n)", isDirectory: true)
                n += 1
            }
            try fm.moveItem(at: entry.directory, to: destination)
            return destination
        }
    }

    /// A name for a new corpus that isn't taken: `base`, else `base 2`, ...
    public static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
