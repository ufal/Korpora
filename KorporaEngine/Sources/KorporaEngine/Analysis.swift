import Foundation

/// Manatee's collocation association measures (`corp/bgrstat.hh`'s `bgr_*`
/// functions, selected by a single-char code). This is a curated subset -
/// the ones with real KonText UI usage - not the full code alphabet
/// (`bgr_known_fun_codes` in the engine also has 'p'/'r'/'f'/'F'/'C'/'1',
/// more obscure/less commonly surfaced measures); the shim accepts any
/// valid code, so this can grow later without a shim change.
public enum AssociationMeasure: Character, Sendable, Codable, CaseIterable {
    /// `14 + log2(2*f_AB/(f_A+f_B))` - Manatee/KonText's own conventional
    /// default collocation measure.
    case logDice = "d"
    /// Pointwise mutual information: `log2(f_AB*N/(f_A*f_B))`.
    case mutualInformation = "m"
    /// MI³: like MI but weighted toward higher-frequency collocates.
    case mi3 = "3"
    /// T-score: `(f_AB - f_A*f_B/N) / sqrt(f_AB)`.
    case tScore = "t"
    /// Log-likelihood (Dunning).
    case logLikelihood = "l"
    /// Dice coefficient, 0-100 scale.
    case dice = "D"
}

/// Parameters for `LiveConcordance.collocations(_:)` - mirrors KonText's own
/// collocation form (`cattr`/`csortfn`/`cfromw`/`ctow`), plus the two
/// frequency thresholds Manatee's `CollocItems` itself requires.
public struct CollocationSpec: Sendable, Codable {
    /// Positional attribute the collocate candidates are drawn from and
    /// reported in (e.g. "word", "lemma") - not necessarily the attribute
    /// the query itself matched on.
    public var attribute: String
    public var measure: AssociationMeasure
    /// Context window in tokens relative to each hit - negative scans left,
    /// positive scans right (e.g. -5/5 for 5 tokens on each side).
    public var leftWindow: Int
    public var rightWindow: Int
    /// Minimum corpus-wide frequency a candidate word needs to be
    /// considered at all.
    public var minFrequency: Int
    /// Minimum number of concordance lines a candidate must co-occur in to
    /// be kept ("min. collocation frequency" in KonText UI terms).
    public var minCollocateFrequency: Int
    /// Hard cap on how many top-scoring collocates are returned.
    public var maxItems: Int

    public init(attribute: String, measure: AssociationMeasure = .logDice,
                leftWindow: Int = -5, rightWindow: Int = 5,
                minFrequency: Int = 5, minCollocateFrequency: Int = 3, maxItems: Int = 50) {
        self.attribute = attribute
        self.measure = measure
        self.leftWindow = leftWindow
        self.rightWindow = rightWindow
        self.minFrequency = minFrequency
        self.minCollocateFrequency = minCollocateFrequency
        self.maxItems = maxItems
    }
}

/// One collocate returned by `LiveConcordance.collocations(_:)`, best-scoring
/// first.
public struct CollocationItem: Sendable, Equatable {
    public let word: String
    /// Corpus-wide frequency of the collocate word (independent of `score`).
    public let freq: Int
    /// Number of concordance lines this word co-occurred in with the node.
    public let cnt: Int
    /// The requested `CollocationSpec.measure`'s value for this row.
    public let score: Double

    public init(word: String, freq: Int, cnt: Int, score: Double) {
        self.word = word
        self.freq = freq
        self.cnt = cnt
        self.score = score
    }
}

/// One grouping key for `LiveConcordance.frequencyDistribution(_:minFrequency:)`.
/// Manatee's own criteria-string grammar (see `SortCriteria.criteriaString`)
/// supports joining several of these into one multi-level key, though the
/// first UI surface built on this only ever passes one.
public struct FrequencyCriterion: Sendable, Codable {
    /// A positional attribute (e.g. "lemma") or a structural one written
    /// "struct.attr" (e.g. "doc.author") - the latter is what makes `norm`
    /// meaningful on the resulting `FrequencyItem`s.
    public var attribute: String
    /// Token offset relative to each hit (0 = the hit itself).
    public var contextOffset: Int
    public var caseInsensitive: Bool

    public init(attribute: String, contextOffset: Int = 0, caseInsensitive: Bool = false) {
        self.attribute = attribute
        self.contextOffset = contextOffset
        self.caseInsensitive = caseInsensitive
    }
}

/// One bin from `ConcordanceHandle.frequencyDistribution(_:minFrequency:)`,
/// sorted by `freq` descending.
public struct FrequencyItem: Sendable, Equatable {
    /// The (possibly multi-level, tab-joined) key this bin was grouped by.
    public let word: String
    public let freq: Int
    /// For a document property (`doc.genre`): how many tokens the documents with this value have in all,
    /// the size the frequency is relative to. `nil` for an ordinary attribute.
    public let norm: Int?
    /// Instances per million tokens: `freq` relative to the tokens of the value's documents when there is
    /// a `norm`, else to the whole corpus. `nil` if the engine didn't say.
    public let perMillion: Double?

    public init(word: String, freq: Int, norm: Int? = nil, perMillion: Double? = nil) {
        self.word = word
        self.freq = freq
        self.norm = norm
        self.perMillion = perMillion
    }
}
