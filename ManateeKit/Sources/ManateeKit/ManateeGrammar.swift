import CorpusEngine

// The Manatee-specific renderings of engine-neutral operation values.

extension SortCriteria {
    /// Builds Manatee's own criteria string (conccrit.cc's `prepare_criteria`
    /// grammar) directly - that's already a well-defined format, not
    /// something worth reinventing a parallel representation for.
    var criteriaString: String {
        levels.map { level -> String in
            var flags = ""
            if level.caseInsensitive { flags += "i" }
            if level.reverse { flags += "r" }
            let attrs = flags.isEmpty ? level.attribute : "\(level.attribute)/\(flags)"
            let ctx: String
            switch level.anchor {
            case .kwic: ctx = "0<0~0>0"
            case .left: ctx = "-1<0~-\(level.span)<0"
            case .right: ctx = "1>0~\(level.span)>0"
            }
            return "\(attrs) \(ctx)"
        }.joined(separator: " ")
    }
}

extension MatchRank {
    var rank: Int32 {
        switch self {
        case .first: return 1
        case .last: return -1
        }
    }
}

extension FrequencyCriterion {
    var criteriaFragment: String {
        let attrs = caseInsensitive ? "\(attribute)/i" : attribute
        return "\(attrs) \(contextOffset)"
    }
}
