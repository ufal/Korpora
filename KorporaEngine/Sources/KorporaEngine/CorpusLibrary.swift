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
    /// Built corpora, one folder each. Finder-visible. The folder the user chose in Settings
    /// (`customBaseDirectory`), else `defaultBaseDirectory`; `KORPORA_CORPORA_DIRECTORY` overrides both
    /// (tests, development).
    public static var baseDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KORPORA_CORPORA_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return customBaseDirectory ?? defaultBaseDirectory
    }

    /// Where built corpora go unless the user chose another folder.
    public static var defaultBaseDirectory: URL {
        directory(environment: "KORPORA_DEFAULT_CORPORA_DIRECTORY", default: "Korpora/Corpora")
    }

    private static let customLock = NSLock()
    private static var customStorage: URL?

    /// The folder the user chose for built corpora (for example on an external disk); nil for the default.
    /// The app sets it from its settings at launch and whenever the choice changes.
    public static var customBaseDirectory: URL? {
        get { customLock.withLock { customStorage } }
        set { customLock.withLock { customStorage = newValue } }
    }

    private static var orderStorage: [String] = []

    /// The order the user put the corpora in (names, first first). The app sets it from its settings, at launch and
    /// on every change. Corpora not named here (new ones) follow the named ones, in the usual order.
    public static var customOrder: [String] {
        get { customLock.withLock { orderStorage } }
        set { customLock.withLock { orderStorage = newValue } }
    }

    /// `entries` with the user's order applied: the named ones first, in that order, the rest after them as they were.
    static func ordered(_ entries: [Entry], by order: [String]) -> [Entry] {
        guard !order.isEmpty else { return entries }
        var rank: [String: Int] = [:]
        for (index, name) in order.enumerated() where rank[name] == nil { rank[name] = index }
        return entries.enumerated().sorted { a, b in
            switch (rank[a.element.name], rank[b.element.name]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Whether built corpora are kept in a folder the user chose.
    public static var baseDirectoryIsChosen: Bool { customBaseDirectory != nil }

    /// A folder the user chose can be on a disk that is not connected; the default is made when needed.
    public static var baseDirectoryIsAvailable: Bool {
        guard baseDirectoryIsChosen else { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: baseDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Symlinks to index folders kept elsewhere.
    /// `KORPORA_LINKED_CORPORA_DIRECTORY` overrides it.
    public static var linkedDirectory: URL {
        directory(environment: "KORPORA_LINKED_CORPORA_DIRECTORY", default: "Korpora/LinkedCorpora")
    }

    /// Where a built corpus goes when it is removed but its data kept. A visible folder, like everything Korpora
    /// makes: these can be gigabytes.
    public static let removedFolderName = "Removed Corpora"
    public static var removedDirectory: URL {
        baseDirectory.appendingPathComponent(removedFolderName, isDirectory: true)
    }

    /// Where work in progress (an import being indexed, a corpus being copied) is kept until it is complete, in
    /// the corpora folder so that it is on the same disk, and visible, so that nothing big is ever hidden. Not a
    /// corpus itself, so it is never listed; it is removed again when empty.
    public static let unfinishedFolderName = "Unfinished Work"

    /// A fresh folder for `label` inside the unfinished-work folder of `base` (not yet created itself).
    static func unfinishedFolder(in base: URL, label: String) throws -> URL {
        let fm = FileManager.default
        let parent = base.appendingPathComponent(unfinishedFolderName, isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var folder = parent.appendingPathComponent(label, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(label) \(n)", isDirectory: true)
            n += 1
        }
        return folder
    }

    /// Removes the unfinished-work folder of `base` if nothing is left in it.
    static func clearUnfinishedWork(in base: URL) {
        let parent = base.appendingPathComponent(unfinishedFolderName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        if names.filter({ $0 != ".DS_Store" }).isEmpty { try? FileManager.default.removeItem(at: parent) }
    }

    /// Early versions kept removed corpora in a hidden `.Removed` folder and work in progress in hidden
    /// `.importing-…` style folders next to the corpora. Makes them visible: `.Removed` becomes
    /// "Removed Corpora" (merged into it if that exists), anything else goes into "Unfinished Work" under a
    /// plain name. Nothing is deleted. Returns what was moved.
    @discardableResult
    public static func makeHiddenFoldersVisible(in base: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        var surfaced: [String] = []
        for name in names where name.hasPrefix(".") && name != ".DS_Store" && name != "." && name != ".." {
            let hidden = base.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: hidden.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            do {
                if name == ".Removed" {
                    let visible = base.appendingPathComponent(removedFolderName, isDirectory: true)
                    if fm.fileExists(atPath: visible.path) {
                        for child in (try? fm.contentsOfDirectory(atPath: hidden.path)) ?? [] {
                            var target = visible.appendingPathComponent(child, isDirectory: true)
                            var n = 2
                            while fm.fileExists(atPath: target.path) {
                                target = visible.appendingPathComponent("\(child) \(n)", isDirectory: true)
                                n += 1
                            }
                            try fm.moveItem(at: hidden.appendingPathComponent(child), to: target)
                        }
                        try fm.removeItem(at: hidden)
                    } else {
                        try fm.moveItem(at: hidden, to: visible)
                    }
                } else {
                    let label = "Left over " + String(name.dropFirst())
                    try fm.moveItem(at: hidden, to: try unfinishedFolder(in: base, label: label))
                }
                surfaced.append(name)
            } catch {
                continue
            }
        }
        return surfaced
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
        case unusableFolder(String)

        public var description: String {
            switch self {
            case .unusableFolder(let reason):
                return reason
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
        return ordered(result, by: customOrder)
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

    // MARK: Moving the corpora folder

    /// Why `folder` can't be the place for built corpora, if it can't: not a folder, not writable, or inside the
    /// current one (it would have to hold itself).
    public static func validateNewBaseDirectory(_ folder: URL, replacing current: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LibraryError.unusableFolder("\u{201C}\(folder.lastPathComponent)\u{201D} isn\u{2019}t a folder.")
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            throw LibraryError.unusableFolder("Korpora can\u{2019}t write to \u{201C}\(folder.lastPathComponent)\u{201D}.")
        }
        let new = folder.resolvingSymlinksInPath().path, old = current.resolvingSymlinksInPath().path
        if new.hasPrefix(old + "/") {
            throw LibraryError.unusableFolder("The new folder can\u{2019}t be inside the current one.")
        }
    }

    /// The corpora Korpora built that sit in `folder`.
    public static func builtCorpora(in folder: URL) -> [Entry] {
        corpusFolders(in: folder).map {
            Entry(name: $0.lastPathComponent, origin: .built, directory: $0, tokens: tokenCount(of: $0))
        }
    }

    /// What `moveBuiltCorpora` did, corpus by corpus.
    public struct MoveResult: Sendable {
        public var moved: [String] = []
        /// Left where they were: the new folder already has a corpus of that name.
        public var skipped: [String] = []
        public var failed: [(name: String, reason: String)] = []
        /// The task was cancelled: what is in `moved` was moved, the rest was left alone.
        public var cancelled = false
    }

    /// Moves every built corpus from `old` to `new`, one at a time, reporting how many bytes are done (to another
    /// disk every index is copied, which takes a while). Each goes through a hidden name first and is renamed into
    /// place at the end, so a stopped copy never leaves half a corpus listed. An existing corpus of the same name
    /// in `new` is never overwritten. Cancelling the calling task stops it between two chunks; the corpus being
    /// copied is left where it was.
    public static func moveBuiltCorpora(
        from old: URL, to new: URL, onProgress: (TransferProgress) -> Void = { _ in }
    ) -> MoveResult {
        let fm = FileManager.default
        var result = MoveResult()
        var todo: [(folder: URL, destination: URL)] = []
        for folder in corpusFolders(in: old) {
            let destination = new.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                result.skipped.append(folder.lastPathComponent)
            } else {
                todo.append((folder, destination))
            }
        }
        let total = todo.reduce(Int64(0)) { $0 + treeSize($1.folder) }
        var base: Int64 = 0
        for (folder, destination) in todo {
            let name = folder.lastPathComponent
            let size = treeSize(folder)
            do {
                let staging = try unfinishedFolder(in: new, label: "Moving \(name)")
                do {
                    try transfer(from: folder, to: staging, move: true, name: name, base: base, total: total, report: onProgress)
                    try fm.moveItem(at: staging, to: destination)
                    base += size
                    result.moved.append(name)
                } catch {
                    try? fm.removeItem(at: staging)
                    throw error
                }
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failed.append((name, error.localizedDescription))
            }
        }
        clearUnfinishedWork(in: new)
        return result
    }

    // MARK: Copying with progress

    /// How far a copy or move of corpora has come.
    public struct TransferProgress: Sendable, Equatable {
        public var bytesDone: Int64
        public var bytesTotal: Int64
        /// The corpus being copied.
        public var name: String
    }

    /// Tests: copy file by file even within one disk, as a move to an external disk does.
    static var alwaysCopyFiles = false

    /// The bytes in the files under `url`.
    static func treeSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let first = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let second = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let first, let second else { return false }
        return first.isEqual(second)
    }

    /// Puts the folder `source` at `destination` (which must not exist), as a copy or a move. Within one disk that
    /// is one rename (or a clone), reported as done at once; to another disk the files are copied in chunks and
    /// the progress reported (at most ten times a second), and a cancelled task stops it and removes what was
    /// copied. `base` and `total` place this folder in a bigger job.
    static func transfer(
        from source: URL, to destination: URL, move: Bool, name: String, base: Int64, total: Int64,
        report: (TransferProgress) -> Void
    ) throws {
        let fm = FileManager.default
        let size = treeSize(source)
        if !alwaysCopyFiles, sameVolume(source, destination.deletingLastPathComponent()) {
            try Task.checkCancellation()
            if move { try fm.moveItem(at: source, to: destination) } else { try fm.copyItem(at: source, to: destination) }
            report(TransferProgress(bytesDone: base + size, bytesTotal: total, name: name))
            return
        }
        var done: Int64 = 0
        var lastReport = Date.distantPast
        report(TransferProgress(bytesDone: base, bytesTotal: total, name: name))
        do {
            try copyTree(from: source, to: destination) { bytes in
                done += bytes
                if Date().timeIntervalSince(lastReport) >= 0.1 {
                    lastReport = Date()
                    report(TransferProgress(bytesDone: base + done, bytesTotal: total, name: name))
                }
            }
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        if move { try fm.removeItem(at: source) }
        report(TransferProgress(bytesDone: base + size, bytesTotal: total, name: name))
    }

    /// Copies a folder's files in chunks, calling `copied` with the size of each; throws `CancellationError`
    /// when the calling task is cancelled.
    static func copyTree(from source: URL, to destination: URL, copied: (Int64) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: keys) else { return }
        let prefix = source.resolvingSymlinksInPath().path + "/"
        for case let item as URL in walker {
            try Task.checkCancellation()
            let path = item.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : item.lastPathComponent
            let target = destination.appendingPathComponent(relative)
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: item.path))
            } else if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try copyFile(from: item, to: target, copied: copied)
            }
        }
    }

    private static func copyFile(from source: URL, to destination: URL, copied: (Int64) -> Void) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try input.read(upToCount: 4 << 20) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied(Int64(chunk.count))
        }
        if let attributes = try? fm.attributesOfItem(atPath: source.path) {
            try? fm.setAttributes(
                [.posixPermissions: attributes[.posixPermissions] as Any, .modificationDate: attributes[.modificationDate] as Any],
                ofItemAtPath: destination.path)
        }
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
    public static func bringIn(
        _ entry: Entry, copy: Bool, onProgress: (TransferProgress) -> Void = { _ in }
    ) throws -> Entry {
        guard case .linked(let target) = entry.origin, !entry.isMissing, isCorpus(target) else {
            throw LibraryError.invalidName("\u{201C}\(entry.name)\u{201D} can\u{2019}t be brought in: its index folder isn\u{2019}t there.")
        }
        let fm = FileManager.default
        let destination = baseDirectory.appendingPathComponent(entry.name, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.nameTaken(entry.name) }
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        // Built beside the final place and moved in whole, so a stopped copy never leaves half a corpus listed.
        let partial = try unfinishedFolder(in: baseDirectory, label: "Bringing in \(entry.name)")
        let total = treeSize(target)
        defer { clearUnfinishedWork(in: baseDirectory) }
        do {
            try transfer(from: target, to: partial, move: !copy, name: entry.name, base: 0, total: total, report: onProgress)
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
            // Only for a moment, and visible all the same: a corpus is never hidden, even if the app stops here.
            let hop = parent.appendingPathComponent("\(entry.name) (being renamed)", isDirectory: true)
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
