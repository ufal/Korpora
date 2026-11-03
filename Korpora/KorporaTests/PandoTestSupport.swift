import Foundation
import KorporaEngine
import Testing

/// Test setup for anything that needs a real pando: finds the build `scripts/pando-spike.sh build`
/// makes (or `KORPORA_PANDO_LIB`), keeps the corpus library in a temporary folder, and builds small
/// corpora with the real indexer. Tests that need pando are skipped when there is none.
enum TestPando {
    static var libraryPath: String? {
        if let explicit = ProcessInfo.processInfo.environment["KORPORA_PANDO_LIB"], !explicit.isEmpty { return explicit }
        let fallback = NSHomeDirectory() + "/Developer/pando-work/pando/build/libpando.dylib"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    /// nil without a pando build: the caller returns early (`guard let ... else { return }`).
    static func engine() -> PandoEngine? {
        guard let path = libraryPath, let library = try? PandoLibrary(path: path) else { return nil }
        return PandoEngine(library: library)
    }

    static var indexTool: URL? {
        guard let path = libraryPath else { return nil }
        let tool = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("pando-index")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    /// Three hits of "cat" in two documents with metadata.
    static let catsConllu = """
        # newdoc id = d1
        # meta::genre = fiction
        # meta::title = Alpha book
        # sent_id = s1
        1\tthe\tthe\tDET\t_\t_\t3\tdet\t_\t_
        2\tbig\tbig\tADJ\t_\t_\t3\tamod\t_\t_
        3\tcat\tcat\tNOUN\t_\t_\t4\tnsubj\t_\t_
        4\tsleeps\tsleep\tVERB\t_\t_\t0\troot\t_\t_

        # sent_id = s2
        1\ta\ta\tDET\t_\t_\t3\tdet\t_\t_
        2\tsmall\tsmall\tADJ\t_\t_\t3\tamod\t_\t_
        3\tcat\tcat\tNOUN\t_\t_\t4\tnsubj\t_\t_
        4\teats\teat\tVERB\t_\t_\t0\troot\t_\t_

        # newdoc id = d2
        # meta::genre = news report
        # meta::title = Beta
        # sent_id = s3
        1\tmy\tmy\tPRON\t_\t_\t2\tnmod\t_\t_
        2\tcat\tcat\tNOUN\t_\t_\t3\tnsubj\t_\t_
        3\tSleeps\tsleep\tVERB\t_\t_\t0\troot\t_\t_


        """

    /// Points the library at fresh temporary folders for as long as the object lives.
    final class Sandbox {
        let root: URL
        private let saved: [(String, String?)]
        static let keys = ["KORPORA_CORPORA_DIRECTORY", "KORPORA_LINKED_CORPORA_DIRECTORY", "KORPORA_SUBCORPORA_DIRECTORY"]

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KorporaTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            saved = Self.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            setenv("KORPORA_CORPORA_DIRECTORY", corpora.path, 1)
            setenv("KORPORA_LINKED_CORPORA_DIRECTORY", root.appendingPathComponent("Linked").path, 1)
            setenv("KORPORA_SUBCORPORA_DIRECTORY", root.appendingPathComponent("Subcorpora").path, 1)
        }

        deinit {
            for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: root)
        }

        var corpora: URL { root.appendingPathComponent("Corpora") }

        /// A folder that looks like an index (a `corpus.info` with a size), for tests of lists.
        @discardableResult
        func fakeIndex(named name: String, tokens: Int = 100) throws -> URL {
            let folder = corpora.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "size=\(tokens)\n".write(to: folder.appendingPathComponent("corpus.info"), atomically: true, encoding: .utf8)
            return folder
        }

        /// Indexes `conllu` into the library as `name`. Returns false when there is no pando build.
        func buildCorpus(_ name: String, conllu: String) async throws -> Bool {
            guard let tool = TestPando.indexTool else { return false }
            let input = root.appendingPathComponent("in-\(name)")
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            try conllu.write(to: input.appendingPathComponent("t.conllu"), atomically: true, encoding: .utf8)
            _ = try await CorpusImporter.importCorpus(name: name, inputs: [input], tool: tool)
            return true
        }
    }
}
