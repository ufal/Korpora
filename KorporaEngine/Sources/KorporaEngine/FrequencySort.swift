import Foundation

/// One level of the order of a frequency table.
public struct FrequencySortKey: Sendable, Equatable {
    public enum Column: Sendable, Equatable {
        /// The values of field `n` (an index into `FrequencyTable.fields`).
        case field(Int)
        case count
        case percent
        case perMillion
    }

    public var column: Column
    public var ascending: Bool

    public init(_ column: Column, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

extension FrequencyTable {
    /// The rows ordered by `keys`, most important first. Text compares the way the Finder sorts names
    /// (`localizedStandardCompare`: case and accents don't decide, numbers count as numbers, the user's language
    /// orders the letters), which pando's code-point order doesn't. Whatever the keys leave open is ordered by count,
    /// highest first, then as pando gave the rows, so no sort is ever random. No keys: the table as it is.
    public func sorted(by keys: [FrequencySortKey]) -> FrequencyTable {
        guard !keys.isEmpty else { return self }
        // The collation keys are worked out once for each distinct value, not once for each comparison.
        var result = self
        let comparisons: [(Int, Int) -> ComparisonResult] = keys.map { key in
            let ascending = key.ascending
            func direct<T: Comparable>(_ value: @escaping (FrequencyRow) -> T) -> (Int, Int) -> ComparisonResult {
                { a, b in
                    let x = value(self.rows[a]), y = value(self.rows[b])
                    let r: ComparisonResult = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
                    return ascending ? r : (r == .orderedAscending ? .orderedDescending : (r == .orderedDescending ? .orderedAscending : .orderedSame))
                }
            }
            switch key.column {
            case .count: return direct { $0.count }
            case .percent: return direct { $0.percent }
            case .perMillion: return direct { $0.perMillion ?? -1 }
            case .field(let column):
                return { a, b in
                    let x = self.rows[a].values.indices.contains(column) ? self.rows[a].values[column] : ""
                    let y = self.rows[b].values.indices.contains(column) ? self.rows[b].values[column] : ""
                    let r = x.localizedStandardCompare(y)
                    return ascending ? r : (r == .orderedAscending ? .orderedDescending : (r == .orderedDescending ? .orderedAscending : .orderedSame))
                }
            }
        }
        let order = rows.indices.sorted { a, b in
            for compare in comparisons {
                switch compare(a, b) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            if rows[a].count != rows[b].count { return rows[a].count > rows[b].count }
            return a < b
        }
        result.rows = order.map { rows[$0] }
        return result
    }
}
