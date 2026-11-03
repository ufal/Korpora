import Foundation
import KorporaEngine

/// Which engine the app's corpora are opened with: pando (docs/pando-gui-plan.md).
/// Documents take an engine as a property so tests can give them a fake, and save
/// its `id` so a document says which engine made it.
enum Engines {
    /// pando, loaded from the app bundle (or `$KORPORA_PANDO_LIB` in development). If it can't be
    /// loaded the app still starts, and every attempt to open a corpus says why.
    static let `default`: any CorpusEngine = {
        do {
            return PandoEngine(library: try PandoLibrary.find())
        } catch {
            return UnavailableEngine(reason: "\(error)")
        }
    }()

    static func engine(withID id: String) -> (any CorpusEngine)? {
        id == "pando" ? Engines.default : nil
    }

    /// Whether the search engine itself loaded (Settings and the library show a notice if not).
    static var unavailableReason: String? {
        (Engines.default as? UnavailableEngine)?.reason
    }
}

/// Stands in for pando when its library can't be loaded.
struct UnavailableEngine: CorpusEngine {
    let reason: String
    var id: String { "pando" }

    func openCorpus(name: String) async throws -> any CorpusHandle {
        throw PandoError.libraryUnavailable(reason)
    }

    func openConcordance(query: String, in corpus: any CorpusHandle, limit: Int) async throws -> any ConcordanceHandle {
        throw PandoError.libraryUnavailable(reason)
    }
}

/// Why a saved document couldn't be read.
enum DocumentFormatError: LocalizedError {
    case unknownEngine(String)
    case formerEngine
    case newerFormat(Int)

    var errorDescription: String? {
        switch self {
        case .unknownEngine(let id):
            return "This concordance was made with the \u{201C}\(id)\u{201D} search engine, which this version of Korpora doesn\u{2019}t have."
        case .formerEngine:
            return "This concordance was made with Korpora\u{2019}s former search engine (Manatee). Its corpora and "
                + "queries don\u{2019}t carry over: import the corpus again, then run the search again."
        case .newerFormat(let version):
            return "This concordance was saved by a newer version of Korpora (document format \(version)). Update Korpora to open it."
        }
    }
}
