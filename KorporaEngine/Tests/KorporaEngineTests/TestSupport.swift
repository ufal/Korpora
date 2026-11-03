import Foundation
import XCTest
@testable import KorporaEngine

/// Finds the pando build the tests run against: `$KORPORA_PANDO_LIB`, else the
/// development location `scripts/pando-spike.sh build` uses.
enum TestPando {
    static var libraryPath: String? {
        if let explicit = ProcessInfo.processInfo.environment["KORPORA_PANDO_LIB"], !explicit.isEmpty { return explicit }
        let fallback = NSHomeDirectory() + "/Developer/pando-work/pando/build/libpando.dylib"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    static func library() throws -> PandoLibrary {
        guard let path = libraryPath, let library = try? PandoLibrary(path: path) else {
            throw XCTSkip("no pando build: run scripts/pando-spike.sh build (or set KORPORA_PANDO_LIB)")
        }
        return library
    }

    /// A tiny two-sentence CoNLL-U text with real heads.
    static let tinyConllu = """
        # sent_id = s1
        1\tthe\tthe\tDET\t_\t_\t2\tdet\t_\t_
        2\tcat\tcat\tNOUN\t_\t_\t3\tnsubj\t_\t_
        3\teats\teat\tVERB\t_\t_\t0\troot\t_\t_
        4\tfish\tfish\tNOUN\t_\t_\t3\tobj\t_\t_

        # sent_id = s2
        1\ta\ta\tDET\t_\t_\t2\tdet\t_\t_
        2\tdog\tdog\tNOUN\t_\t_\t3\tnsubj\t_\t_
        3\teats\teat\tVERB\t_\t_\t0\troot\t_\t_
        4\tmeat\tmeat\tNOUN\t_\t_\t3\tobj\t_\t_


        """

    /// Points the library at fresh temporary folders for the duration of a test.
    final class Sandbox {
        let root: URL
        private let saved: [(String, String?)]
        static let keys = ["KORPORA_CORPORA_DIRECTORY", "KORPORA_LINKED_CORPORA_DIRECTORY", "KORPORA_SUBCORPORA_DIRECTORY"]

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("KorporaEngineTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            saved = Self.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            setenv("KORPORA_CORPORA_DIRECTORY", root.appendingPathComponent("Corpora").path, 1)
            setenv("KORPORA_LINKED_CORPORA_DIRECTORY", root.appendingPathComponent("Linked").path, 1)
            setenv("KORPORA_SUBCORPORA_DIRECTORY", root.appendingPathComponent("Subcorpora").path, 1)
        }

        deinit {
            for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } }
            try? FileManager.default.removeItem(at: root)
        }

        /// A folder that looks like an index (a `corpus.info` with a size).
        @discardableResult
        func fakeIndex(named name: String, in parent: URL, tokens: Int = 100) throws -> URL {
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "size=\(tokens)\nindexed_with=0.4.1\n".write(
                to: folder.appendingPathComponent("corpus.info"), atomically: true, encoding: .utf8)
            return folder
        }

        var corpora: URL { root.appendingPathComponent("Corpora") }
        var elsewhere: URL { root.appendingPathComponent("Elsewhere") }
    }
}
