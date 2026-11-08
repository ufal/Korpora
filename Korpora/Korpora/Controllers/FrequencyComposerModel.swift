import Foundation
import KorporaEngine

/// One row of the composer's table: an attribute of a node, a text or document property, or the count.
struct ComposerRow: Equatable, Identifiable {
    enum Kind: Equatable {
        /// An attribute of the query's node `node` (its name in the query).
        case node(String, attribute: String)
        /// A property of the text or document the hit is in (`doc.genre`).
        case property(attribute: String)
        /// The number of hits, which can be put in the order too.
        case count
    }

    enum Sort: Equatable {
        case none, ascending, descending

        /// none, then ascending, then descending, then none again.
        var next: Sort {
            switch self {
            case .none: return .ascending
            case .ascending: return .descending
            case .descending: return .none
            }
        }
    }

    let id: UUID
    var kind: Kind
    var ignoreCase = false
    var sort: Sort = .none

    init(id: UUID = UUID(), kind: Kind, ignoreCase: Bool = false, sort: Sort = .none) {
        self.id = id
        self.kind = kind
        self.ignoreCase = ignoreCase
        self.sort = sort
    }

    var isCount: Bool { kind == .count }
    var attribute: String? {
        switch kind {
        case .node(_, let attribute), .property(let attribute): return attribute
        case .count: return nil
        }
    }
}

/// What the user has composed: the rows of the table, in order (docs/frequency-composer.md). Pure, so the
/// rules for adding, moving and sorting are tested without a window.
struct FrequencyComposerModel: Equatable {
    /// The fields and the count, in the order the user set. The count is always there and can't be removed.
    private(set) var rows: [ComposerRow] = [ComposerRow(kind: .count)]

    /// The rows that are columns of the table (everything but the count), in order.
    var fieldRows: [ComposerRow] { rows.filter { !$0.isCount } }
    var isEmpty: Bool { fieldRows.isEmpty }

    /// Adds a field unless the same one is already there. The new row goes before the count while the count is
    /// last, so the count stays at the bottom unless the user moved it. Returns whether it was added.
    @discardableResult
    mutating func add(_ kind: ComposerRow.Kind, ignoreCase: Bool = false) -> Bool {
        guard kind != .count, !rows.contains(where: { $0.kind == kind }) else { return false }
        let row = ComposerRow(kind: kind, ignoreCase: ignoreCase)
        if let last = rows.indices.last, rows[last].isCount { rows.insert(row, at: last) } else { rows.append(row) }
        return true
    }

    mutating func remove(_ id: UUID) {
        rows.removeAll { $0.id == id && !$0.isCount }
    }

    /// Moves the row at `source` to the gap `destination` (the gap above row `destination`, as a table's drag reports it).
    mutating func move(from source: Int, toGap destination: Int) {
        guard rows.indices.contains(source), (0...rows.count).contains(destination) else { return }
        let row = rows.remove(at: source)
        rows.insert(row, at: destination > source ? destination - 1 : destination)
    }

    mutating func setAttribute(_ attribute: String, for id: UUID) {
        guard let at = rows.firstIndex(where: { $0.id == id }) else { return }
        let replaced: ComposerRow.Kind
        switch rows[at].kind {
        case .node(let node, _): replaced = .node(node, attribute: attribute)
        case .property: replaced = .property(attribute: attribute)
        case .count: return
        }
        // Two rows may not ask for the same thing.
        guard !rows.contains(where: { $0.kind == replaced }) else { return }
        rows[at].kind = replaced
    }

    mutating func setIgnoreCase(_ on: Bool, for id: UUID) {
        guard let at = rows.firstIndex(where: { $0.id == id }), !rows[at].isCount else { return }
        rows[at].ignoreCase = on
    }

    mutating func cycleSort(for id: UUID) {
        guard let at = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[at].sort = rows[at].sort.next
    }

    /// Drops every row asking about a node the query no longer has.
    mutating func keepOnly(nodes names: Set<String>) {
        rows.removeAll { row in
            if case .node(let node, _) = row.kind { return !names.contains(node) }
            return false
        }
    }

    // MARK: What the engine is asked

    var fields: [FrequencyField] {
        fieldRows.map { row in
            switch row.kind {
            case .node(let node, let attribute): return FrequencyField(node: node, attribute: attribute, ignoreCase: row.ignoreCase)
            case .property(let attribute): return FrequencyField(node: nil, attribute: attribute, ignoreCase: row.ignoreCase)
            case .count: preconditionFailure("the count is not a field")
            }
        }
    }

    /// The order the rows have asked for: the rows with a sort set, in the table's order. None set: no keys (the
    /// table stays by count, highest first).
    var sortKeys: [FrequencySortKey] {
        var keys: [FrequencySortKey] = []
        var column = 0
        for row in rows {
            let key: FrequencySortKey.Column = row.isCount ? .count : .field(column)
            if !row.isCount { column += 1 }
            switch row.sort {
            case .none: continue
            case .ascending: keys.append(FrequencySortKey(key, ascending: true))
            case .descending: keys.append(FrequencySortKey(key, ascending: false))
            }
        }
        return keys
    }
}
