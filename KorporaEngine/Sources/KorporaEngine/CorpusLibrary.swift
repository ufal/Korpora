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
        /// A linked corpus whose index folder is no longer where the link leads (moved, renamed, a disk that is
        /// not there). Only listed with `entries(includingMissing: true)`; it can't be searched until relinked.
        public var isMissing = false

        public var isLinked: Bool {
            if case .linked = origin { return true }
            return false
        }
    }

    public enum LibraryError: Error, CustomStringConvertible, Equatable {
        case nameTaken(String)
        case notACorpus(URL)
        case invalidName(String)

        public var description: String {
            switch self {
            case .nameTaken(let name):
                return "A corpus named \u{201C}\(name)\u{201D} is already in Korpora."
            case .notACorpus(let url):
                return "\u{201C}\(url.lastPathComponent)\u{201D} isn\u{2019}t an indexed corpus (it has no corpus.info)."
            case .invalidName(let reason):
                return reason
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
    /// - Parameter includingMissing: also list linked corpora whose index folder is gone (`isMissing`), so that
    ///   they can be shown and relinked; everything that searches leaves them out.
    public static func entries(includingMissing: Bool = false) -> [Entry] {
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
        if includingMissing {
            for link in brokenLinks() where seen.insert(link.lastPathComponent).inserted {
                result.append(Entry(name: link.lastPathComponent, origin: .linked(target: linkTarget(link)),
                                    directory: link, tokens: nil, isMissing: true))
            }
            result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return result
    }

    /// Where a link leads, whether or not anything is there now.
    private static func linkTarget(_ link: URL) -> URL {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return link }
        return URL(fileURLWithPath: path, relativeTo: link.deletingLastPathComponent()).standardizedFileURL
    }

    /// Links in the linked-corpora folder that lead to no index.
    private static func brokenLinks() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: linkedDirectory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }
            .map { linkedDirectory.appendingPathComponent($0, isDirectory: true) }
            .filter { link in
                (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil && !isCorpus(link)
            }
    }

    public static func names(includingMissing: Bool = false) -> [String] {
        entries(includingMissing: includingMissing).map(\.name)
    }

    /// Where the corpus called `name` is; nil if there is none.
    public static func directory(forName name: String) -> URL? {
        entries().first { $0.name == name }?.directory
    }

    // MARK: Adding

    /// Links an index folder that lives elsewhere, under `name` (else `suggestedName(forIndex:)`).
    /// The folder itself is not renamed or touched.
    /// - Parameter taken: names already in use, refused as `nameTaken`.
    @discardableResult
    public static func link(indexDirectory: URL, name chosen: String? = nil, taken: Set<String>) throws -> Entry {
        let target = indexDirectory.resolvingSymlinksInPath()
        guard isCorpus(target) else { throw LibraryError.notACorpus(target) }
        let name = try validName(chosen ?? suggestedName(forIndex: target))
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

    // MARK: Relinking and bringing in

    /// Points a linked corpus at another index folder (it was moved, or the disk came back elsewhere). The name
    /// stays, so searches, subcorpora and history that refer to it keep working.
    @discardableResult
    public static func relink(_ entry: Entry, to indexDirectory: URL) throws -> Entry {
        guard entry.isLinked else { throw LibraryError.invalidName("\u{201C}\(entry.name)\u{201D} isn\u{2019}t a linked corpus.") }
        let target = indexDirectory.resolvingSymlinksInPath()
        guard isCorpus(target) else { throw LibraryError.notACorpus(target) }
        let fm = FileManager.default
        try fm.removeItem(at: entry.directory)
        try fm.createSymbolicLink(at: entry.directory, withDestinationURL: target)
        return Entry(name: entry.name, origin: .linked(target: target), directory: entry.directory,
                     tokens: tokenCount(of: target))
    }

    /// Makes a linked corpus a built one, kept in Korpora's own folder under the same name: the index is copied
    /// there (the original stays where it was) or moved (it leaves its old place). Names, subcorpora and
    /// history are unaffected, as the name is the same.
    @discardableResult
    public static func bringIn(_ entry: Entry, copy: Bool) throws -> Entry {
        guard case .linked(let target) = entry.origin, !entry.isMissing, isCorpus(target) else {
            throw LibraryError.invalidName("\u{201C}\(entry.name)\u{201D} can\u{2019}t be brought in: its index folder isn\u{2019}t there.")
        }
        let fm = FileManager.default
        let destination = baseDirectory.appendingPathComponent(entry.name, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.nameTaken(entry.name) }
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        // Built beside the final place and moved in whole, so a stopped copy never leaves half a corpus listed.
        let partial = baseDirectory.appendingPathComponent(".bringing-in-\(UUID().uuidString)", isDirectory: true)
        do {
            if copy { try fm.copyItem(at: target, to: partial) } else { try fm.moveItem(at: target, to: partial) }
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        try fm.removeItem(at: entry.directory)
        return Entry(name: entry.name, origin: .built, directory: destination, tokens: tokenCount(of: destination))
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

    // MARK: Naming

    /// Index folders are often called something generic (`idx`, `index`), which says nothing in a list of
    /// corpora; then the folder that holds it is the better name (`~/syn2025/idx` is "syn2025").
    public static func suggestedName(forIndex directory: URL) -> String {
        let folder = directory.resolvingSymlinksInPath()
        let own = folder.lastPathComponent
        let generic: Set<String> = ["idx", "index", "pando", "pando_idx", "pando-idx", "pando_index", "data", "corpus", "build", "output", "out"]
        guard generic.contains(own.lowercased()) else { return own }
        let parent = folder.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty || parent == "/" ? own : parent
    }

    /// `name` trimmed, or why it can't be a corpus name: a name is a file name here.
    public static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw LibraryError.invalidName("A corpus needs a name.") }
        if trimmed.contains("/") || trimmed.contains(":") {
            throw LibraryError.invalidName("A corpus name can\u{2019}t contain \u{201C}/\u{201D} or \u{201C}:\u{201D}.")
        }
        if trimmed.hasPrefix(".") {
            throw LibraryError.invalidName("A corpus name can\u{2019}t start with a dot.")
        }
        return trimmed
    }

    /// Gives a corpus another name. Only Korpora's own handle changes: a built corpus's folder is renamed, a
    /// linked corpus's link is (the folder it leads to is never touched). Names a corpus keeps elsewhere
    /// (saved subcorpora) are moved by `SubcorpusLibrary.rename`; the caller moves the rest (settings).
    /// - Parameter taken: the names in use; a name equal to the corpus's own except for capitals is fine.
    @discardableResult
    public static func rename(_ entry: Entry, to newName: String, taken: Set<String>) throws -> Entry {
        let name = try validName(newName)
        if name == entry.name { return entry }
        let caseOnly = name.compare(entry.name, options: .caseInsensitive) == .orderedSame
        guard caseOnly || !taken.contains(name) else { throw LibraryError.nameTaken(name) }
        let fm = FileManager.default
        let parent = entry.directory.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        // The file system ignores case, so a change of capitals goes through a temporary name.
        if caseOnly {
            let hop = parent.appendingPathComponent(".renaming-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: entry.directory, to: hop)
            try fm.moveItem(at: hop, to: destination)
        } else {
            try fm.moveItem(at: entry.directory, to: destination)
        }
        var renamed = entry
        renamed.name = name
        renamed.directory = destination
        return renamed
    }

    /// A name for a new corpus that isn't taken: `base`, else `base 2`, ...
    public static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
