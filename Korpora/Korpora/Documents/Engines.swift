import Foundation
import ManateeKit

/// Which engine the app's corpora are opened with (docs/pando-analysis.md,
/// Phase B). Manatee is the only one so far; a corpus-to-engine mapping comes
/// with a second engine. Documents take an engine as a property so tests can
/// give them a fake, and save its `id` so a document opens with the engine
/// that made it.
enum Engines {
    static let `default`: any CorpusEngine = ManateeEngine()

    private static let all: [any CorpusEngine] = [ManateeEngine()]

    static func engine(withID id: String) -> (any CorpusEngine)? {
        all.first { $0.id == id }
    }
}

/// Why a saved document couldn't be read.
enum DocumentFormatError: LocalizedError {
    case unknownEngine(String)
    case newerFormat(Int)

    var errorDescription: String? {
        switch self {
        case .unknownEngine(let id):
            return "This concordance was made with the \u{201C}\(id)\u{201D} search engine, which this version of Korpora doesn\u{2019}t have."
        case .newerFormat(let version):
            return "This concordance was saved by a newer version of Korpora (document format \(version)). Update Korpora to open it."
        }
    }
}
