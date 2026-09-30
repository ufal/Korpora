import ManateeKit

/// Which engine the app's corpora are opened with (docs/pando-analysis.md,
/// Phase B). Manatee is the only one so far; a corpus-to-engine mapping comes
/// with a second engine. Documents take an engine as a property so tests can
/// give them a fake.
enum Engines {
    static let `default`: any CorpusEngine = ManateeEngine()
}
