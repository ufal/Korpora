import Foundation

/// The text-level metadata of a Universal Dependencies file, from its name, the way pando's
/// `scripts/build_ud_corpus.py` writes it: a UD file is called `{language}_{treebank}-ud-{split}.conllu`
/// (`cs_pdt-ud-train.conllu`), and the language, the treebank and the file name become the attributes
/// `text.langcode`, `text.treebank` and `text.id`, so a search or a subcorpus can say "Czech" or "the PDT".
/// `pando-index` itself only records what the comments of a file say, and UD files don't say it.
/// The files the user picked are never changed: the import indexes copies with the lines put in front.
enum UDMetadata {
    /// (language code, treebank code), lower case, or nil when `name` isn't a UD file name.
    static func parse(fileName name: String) -> (language: String, treebank: String)? {
        guard name.hasSuffix(".conllu") else { return nil }
        let base = String(name.dropLast(".conllu".count))
        guard let split = base.range(of: "-ud-", options: .backwards) else { return nil }
        let head = base[..<split.lowerBound]
        guard let underscore = head.lastIndex(of: "_") else { return nil }
        let language = head[..<underscore], treebank = head[head.index(after: underscore)...]
        guard !language.isEmpty, !treebank.isEmpty else { return nil }
        return (language.lowercased(), treebank.lowercased())
    }

    /// The lines to put at the top of the file called `name`: a `text` region and its attributes. nil for a name
    /// that isn't a UD one. Same keys, same order as pando's script.
    static func header(forFileName name: String) -> String? {
        guard let parsed = parse(fileName: name) else { return nil }
        return "# newregion text\n# text_id = \(name)\n# text_langcode = \(parsed.language)\n# text_treebank = \(parsed.treebank)\n"
    }

    /// Whether the file already opens a `text` region (it has been prepared, by pando's script or by hand).
    static func hasTextHeader(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024), let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(120) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#") { return false }
            if trimmed.dropFirst().trimmingCharacters(in: .whitespaces) == "newregion text" { return true }
        }
        return false
    }

    /// The CoNLL-U files of `inputs`: a file as it is, a folder's (and its subfolders') in path order; hidden ones skipped.
    static func conlluFiles(in inputs: [URL]) -> [URL] {
        var result: [URL] = []
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                result.append(input)
                continue
            }
            let found = FileManager.default.enumerator(
                at: input, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?
                .compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "conllu" } ?? []
            result += found.sorted { $0.path < $1.path }
        }
        return result
    }

    /// Whether at least one of `files` would get a header.
    static func needsHeaders(_ files: [URL]) -> Bool {
        files.contains { parse(fileName: $0.lastPathComponent) != nil && !hasTextHeader($0) }
    }

    /// Puts `files` in `folder`, in this order (a number in front of each name keeps it): a copy with the header
    /// first for a UD-named file without one, a link for any other. Calls `step(done, total)` after each file,
    /// which may throw to stop (cancelling the import).
    static func stage(_ files: [URL], in folder: URL, step: (Int, Int) async throws -> Void) async throws {
        let fm = FileManager.default
        for (index, file) in files.enumerated() {
            let target = folder.appendingPathComponent(String(format: "%05d-%@", index, file.lastPathComponent))
            if let header = header(forFileName: file.lastPathComponent), !hasTextHeader(file) {
                try copy(file, to: target, after: header)
            } else {
                try fm.createSymbolicLink(at: target, withDestinationURL: file)
            }
            try await step(index + 1, files.count)
        }
    }

    private static func copy(_ file: URL, to target: URL, after header: String) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: target.path, contents: Data(header.utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: file)
        let output = try FileHandle(forWritingTo: target)
        defer { try? input.close(); try? output.close() }
        try output.seekToEnd()
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }
}
