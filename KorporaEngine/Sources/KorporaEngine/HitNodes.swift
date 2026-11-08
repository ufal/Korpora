import Foundation

/// One hit shown as words, with the words each token of the query matched (docs/frequency-composer.md).
public struct HitNodes: Sendable, Equatable {
    /// The words of the left context, the hit and the right context, in text order.
    public var words: [String]
    /// The words of the hit itself (from its first to its last matched token).
    public var matchRange: Range<Int>
    /// One entry for each token of the query, in the query's order, whatever their order in the sentence.
    public var tokens: [Token]

    public struct Token: Sendable, Equatable {
        /// Index into `words`.
        public var wordIndex: Int
        /// The values of the attributes asked for.
        public var attributes: [String: String]

        public init(wordIndex: Int, attributes: [String: String]) {
            self.wordIndex = wordIndex
            self.attributes = attributes
        }
    }

    public init(words: [String], matchRange: Range<Int>, tokens: [Token]) {
        self.words = words
        self.matchRange = matchRange
        self.tokens = tokens
    }
}

extension ConcordanceHandle {
    /// For engines that can't tell which words the query's tokens matched.
    public func hitNodes(forViewRow row: Int, context: Int, attributes: [String]) async throws -> HitNodes {
        throw PandoError.unsupported("Showing the words a node matched")
    }
}
