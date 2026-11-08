import Foundation

/// One column of a frequency over the nodes of a query (docs/frequency-composer.md): an attribute of one
/// node (`a.lemma`), or a text or document property that belongs to no token (`doc.genre`).
public struct FrequencyField: Sendable, Equatable, Hashable {
    /// The node's name in the query (the user's, or the one `QueryNodes` chose); nil for a text or document
    /// property.
    public var node: String?
    /// A positional attribute (`lemma`), or a structural one written `structure.attribute` (`doc.genre`).
    public var attribute: String
    /// Count `The` and `the` as one value. pando's `freq by` has no case folding, so the table folds it.
    public var ignoreCase: Bool

    public init(node: String? = nil, attribute: String, ignoreCase: Bool = false) {
        self.node = node
        self.attribute = attribute
        self.ignoreCase = ignoreCase
    }

    /// The field as `freq by` writes it: `a.lemma`, `doc_genre`.
    var pandoField: String {
        let attribute = PandoNames.attribute(attribute)
        return node.map { "\($0).\(attribute)" } ?? attribute
    }
}

/// One combination of values and how often it occurs.
public struct FrequencyRow: Sendable, Equatable {
    /// One value for each field of the table, in its order.
    public var values: [String]
    public var count: Int
    /// `count` as a percentage of the hits counted.
    public var percent: Double
    /// Instances per million tokens, when pando says (see `FrequencyItem.perMillion`).
    public var perMillion: Double?
    /// For a document property: how many tokens the documents with this value have.
    public var norm: Int?

    public init(values: [String], count: Int, percent: Double, perMillion: Double? = nil, norm: Int? = nil) {
        self.values = values
        self.count = count
        self.percent = percent
        self.perMillion = perMillion
        self.norm = norm
    }
}

/// The answer to a frequency over several fields.
public struct FrequencyTable: Sendable, Equatable {
    public var fields: [FrequencyField]
    /// By count, descending: the order pando gives.
    public var rows: [FrequencyRow]
    /// The hits that were counted.
    public var totalMatches: Int
    /// True when rows were left out because there were more than the table keeps (the ones with the lowest counts).
    public var isCut: Bool

    public init(fields: [FrequencyField], rows: [FrequencyRow], totalMatches: Int, isCut: Bool = false) {
        self.fields = fields
        self.rows = rows
        self.totalMatches = totalMatches
        self.isCut = isCut
    }

    /// The hits the rows account for. Less than `totalMatches` when the table is cut (or `minFrequency`
    /// dropped rows): "these rows cover X of the Y hits" is how to say what is missing.
    public var shownMatches: Int { rows.reduce(0) { $0 + $1.count } }

    /// The table with `ignoreCase` applied: rows whose values differ only in case become one row (counts and
    /// percentages added, shown in lower case), and the rows stay in count order.
    public func folded() -> FrequencyTable {
        let columns = fields.enumerated().filter { $0.element.ignoreCase }.map(\.offset)
        guard !columns.isEmpty else { return self }
        var merged: [[String]: Int] = [:]
        var result: [FrequencyRow] = []
        for row in rows {
            var values = row.values
            for column in columns where column < values.count { values[column] = values[column].lowercased() }
            if let at = merged[values] {
                result[at].count += row.count
                result[at].percent += row.percent
                if let more = row.perMillion { result[at].perMillion = (result[at].perMillion ?? 0) + more }
                if result[at].norm != row.norm { result[at].norm = nil }
            } else {
                merged[values] = result.count
                var copy = row
                copy.values = values
                result.append(copy)
            }
        }
        // Stable: equal counts keep the order pando gave them.
        let ordered = result.enumerated().sorted { ($0.element.count, $1.offset) > ($1.element.count, $0.offset) }
        return FrequencyTable(fields: fields, rows: ordered.map(\.element), totalMatches: totalMatches, isCut: isCut)
    }
}

/// Why an analysis around the nodes of a query (a frequency, a collocation) could not be asked for.
public enum QueryNodeError: Error, LocalizedError, Equatable {
    case noFields
    case unsupportedQuery(String)
    case unknownNode(String)
    case notPickable(String)

    public var errorDescription: String? {
        switch self {
        case .noFields: return "Pick at least one attribute."
        case .unsupportedQuery(let reason): return reason
        case .unknownNode(let name): return "The query has no node called \u{201C}\(name)\u{201D}."
        case .notPickable(let name):
            return "Node \u{201C}\(name)\u{201D} can match several words or none, so a frequency can\u{2019}t be taken from it."
        }
    }
}

extension QueryNodes {
    /// The `freq by` program for `fields`: the query with every token named, then the fields. Throws when
    /// a field names a node the query doesn't have, or one that may repeat.
    public func frequencyProgram(for fields: [FrequencyField]) throws -> String {
        guard !fields.isEmpty else { throw QueryNodeError.noFields }
        if let reason = unsupportedReason, fields.contains(where: { $0.node != nil }) {
            throw QueryNodeError.unsupportedQuery(reason)
        }
        for field in fields {
            if let name = field.node { try checkNode(named: name) }
        }
        let query = fields.contains { $0.node != nil } ? textWithNames() : text
        return "\(query); freq by \(fields.map(\.pandoField).joined(separator: ", "))"
    }
}

extension QueryNodes {
    /// Throws unless the query has a node called `name` that is one token, always there.
    func checkNode(named name: String) throws {
        guard let node = nodes.first(where: { $0.name == name }) else { throw QueryNodeError.unknownNode(name) }
        guard node.isPickable else { throw QueryNodeError.notPickable(name) }
    }

    /// The `coll` program: the query, then `coll by <attribute>` around the whole match, or with `anchor` (a node's
    /// name) `coll on <node> by <attribute>`, around that token only (the query's tokens are named first).
    public func collocationProgram(attribute: String, anchor: String?) throws -> String {
        guard let anchor else { return "\(text); coll by \(attribute)" }
        if let reason = unsupportedReason { throw QueryNodeError.unsupportedQuery(reason) }
        try checkNode(named: anchor)
        return "\(textWithNames()); coll on \(anchor) by \(attribute)"
    }
}
