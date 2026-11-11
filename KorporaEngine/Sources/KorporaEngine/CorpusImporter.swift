import Foundation

public enum CorpusImportError: Error, CustomStringConvertible {
    case noTool
    case noInput
    case nameTaken(String)
    case failed(String)
    case folderUnavailable(URL)

    public var description: String {
        switch self {
        case .noTool: return "The indexing tool (pando-index) wasn\u{2019}t found."
        case .noInput: return "There is nothing to import."
        case .nameTaken(let name): return "A corpus named \u{201C}\(name)\u{201D} is already in Korpora."
        case .failed(let log): return "Indexing failed.\n\n\(log)"
        case .folderUnavailable(let url):
            return "The folder for corpora (\(url.path)) isn\u{2019}t available. Is its disk connected? "
                + "You can choose another folder in Settings > Corpora."
        }
    }
}

/// Builds a corpus from annotated text by running `pando-index` (docs/pando-gui-plan.md).
///
/// Inputs are CoNLL-U files or folders of them (one corpus from many treebanks
/// is fine), CWB-style vertical files (`.vrt`, `.vert`), or JSONL events.
/// The corpus is built in a hidden temporary folder next to the others and
/// renamed into place only when indexing succeeded, so a failed or cancelled
/// import leaves nothing behind.
public enum CorpusImporter {
    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable { case starting, reading, finishing }
        public var phase: Phase
        /// How far through the input files, 0...1, while reading.
        public var fraction: Double?
        public var currentFile: String?
        public var tokens: Int
        /// The latest line of the tool's output, for a log view.
        public var line: String
    }

    public enum Kind: Sendable { case conllu, vertical, jsonl }

    /// What the files in `inputs` are, by extension; the first recognised one decides.
    public static func kind(of inputs: [URL]) -> Kind {
        for url in inputs {
            switch url.pathExtension.lowercased() {
            case "vrt", "vert": return .vertical
            case "jsonl", "ndjson": return .jsonl
            default: continue
            }
        }
        return .conllu
    }

    /// Indexes `inputs` into a new corpus called `name` and returns where it is.
    /// Cancelling the calling task stops the tool and removes the partial corpus.
    @discardableResult
    public static func importCorpus(
        name: String, inputs: [URL], tool: URL? = nil, library: PandoLibrary? = nil,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> URL {
        guard !inputs.isEmpty else { throw CorpusImportError.noInput }
        guard let tool = tool ?? library?.indexTool ?? (try? PandoLibrary.find().indexTool) ?? nil else {
            throw CorpusImportError.noTool
        }
        let fm = FileManager.default
        let base = CorpusLibrary.baseDirectory
        guard CorpusLibrary.baseDirectoryIsAvailable else { throw CorpusImportError.folderUnavailable(base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path), !CorpusLibrary.names().contains(name) else {
            throw CorpusImportError.nameTaken(name)
        }

        // One input is passed as is; several are linked into a staging folder.
        let work = try CorpusLibrary.unfinishedFolder(in: base, label: "Importing \(name)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: work)
            CorpusLibrary.clearUnfinishedWork(in: base)
        }
        let source: URL
        let udFiles = kind(of: inputs) == .conllu ? UDMetadata.conlluFiles(in: inputs) : []
        let addsUDMetadata = UDMetadata.needsHeaders(udFiles)
        if addsUDMetadata {
            // UD files carry their language and treebank in the file name only: index copies that say it
            // (text.langcode, text.treebank, text.id), as pando's own UD script does. The originals stay as they are.
            let staging = work.appendingPathComponent("input", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try await UDMetadata.stage(udFiles, in: staging) { done, total in
                try Task.checkCancellation()
                onProgress(Progress(phase: .starting, fraction: nil, currentFile: nil, tokens: 0,
                                    line: "Adding the language of each file (\(done)/\(total))"))
            }
            source = staging
        } else if inputs.count == 1 {
            source = inputs[0]
        } else {
            let staging = work.appendingPathComponent("input", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for (index, input) in inputs.enumerated() {
                try fm.createSymbolicLink(
                    at: staging.appendingPathComponent(String(format: "%04d-%@", index, input.lastPathComponent)),
                    withDestinationURL: input)
            }
            source = staging
        }
        let output = work.appendingPathComponent("index", isDirectory: true)

        var arguments: [String] = []
        if addsUDMetadata {
            arguments += ["--multivalue", UDMetadata.multivalueAttributes.joined(separator: ",")]
        }
        switch kind(of: inputs) {
        case .conllu: break
        case .vertical: arguments += ["--format", "vertical"]
        case .jsonl: arguments += ["--format", "jsonl"]
        }
        arguments += [source.path, output.path]

        try await run(tool: tool, arguments: arguments, onProgress: onProgress)
        guard CorpusLibrary.isCorpus(output) else {
            throw CorpusImportError.failed("The tool finished but wrote no corpus.")
        }
        try fm.moveItem(at: output, to: destination)
        return destination
    }

    // MARK: Running the tool

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private(set) var lines: [String] = []
        var tokens = 0
        var fraction: Double?
        var file: String?
        var phase = Progress.Phase.starting

        func append(_ data: Data, report: (Progress) -> Void) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            pending += text
            var parsed: [String] = []
            while let end = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(pending[..<end])
                pending.removeSubrange(...end)
                if !line.isEmpty { parsed.append(line) }
            }
            lock.unlock()
            for line in parsed { consume(line, report: report) }
        }

        private func consume(_ line: String, report: (Progress) -> Void) {
            lock.lock()
            lines.append(line)
            if lines.count > 40 { lines.removeFirst(lines.count - 40) }
            // "[3/712] path/to/file.conllu  (5317 tok, 1329 ktok/s)"
            if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let counts = line[line.index(after: line.startIndex)..<close].split(separator: "/")
                if counts.count == 2, let done = Double(counts[0]), let total = Double(counts[1]), total > 0 {
                    fraction = done / total
                    phase = .reading
                    let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                    file = rest.components(separatedBy: "  (").first.map { ($0 as NSString).lastPathComponent }
                }
            } else if line.hasPrefix("Corpus: "), let number = line.dropFirst(8).split(separator: " ").first {
                tokens = Int(number) ?? tokens
            } else if line.hasPrefix("Finalizing") || line.hasPrefix("Wrote ") {
                phase = .finishing
                fraction = nil
            }
            let progress = Progress(phase: phase, fraction: fraction, currentFile: file, tokens: tokens, line: line)
            lock.unlock()
            report(progress)
        }

        var tail: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.suffix(12).joined(separator: "\n")
        }
    }

    private static func run(tool: URL, arguments: [String],
                            onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = Output()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData, report: onProgress)
        }
        onProgress(Progress(phase: .starting, fraction: nil, currentFile: nil, tokens: 0, line: ""))

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    output.append(pipe.fileHandleForReading.readDataToEndOfFile(), report: onProgress)
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else { throw CorpusImportError.failed(output.tail) }
    }
}
