import Cocoa
import KorporaEngine

/// Backs the Settings window; persisted via `UserDefaults`.
final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("AppSettingsDidChange")
    /// Posted when the set of corpora may have changed (Settings > Corpora added, imported or removed one),
    /// so open windows (the New Concordance sheet) can refresh their lists.
    static let corporaDidChangeNotification = Notification.Name("AppCorporaDidChange")

    private enum Key {
        /// Retired: Settings once had a separate list of registry
        /// directories. Read once by `migrateCorpusList()`, then removed.
        static let keepResidentCorpora = "keepResidentCorpora"
        static let resultsFontName = "resultsFontName"
        static let resultsFontSize = "resultsFontSize"
        static let maxConcordanceLines = "maxConcordanceLines"
        static let minimumFreeMemoryAfterResidency = "minimumFreeMemoryAfterResidency"
        static let defaultLeftContext = "defaultLeftContext"
        static let defaultRightContext = "defaultRightContext"
        static let defaultExtendedContextTokens = "defaultExtendedContextTokens"
        static let scriptFontOverrides = "scriptFontOverrides"
        static let positionalAttributeColor = "positionalAttributeColor"
        static let structuralAttributeColor = "structuralAttributeColor"
        static let usesAlternatingRowBackground = "usesAlternatingRowBackground"
        static let extendedContextDisplayMode = "extendedContextDisplayMode"
        static let allowMultipleExtendedContexts = "allowMultipleExtendedContexts"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every corpus in the library (built and linked).
    /// - Parameter includingMissing: also the linked corpora whose index folder is gone (the list shows them with
    ///   a warning); anything that searches leaves them out.
    func corpusLibraryEntries(includingMissing: Bool = false) -> [CorpusLibrary.Entry] {
        CorpusLibrary.entries(includingMissing: includingMissing)
    }

    /// Names of corpora to keep warm in memory - any corpus, whoever built
    /// it (the data directory comes from its registry file's `PATH`).
    var keepResidentCorpora: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.keepResidentCorpora) ?? []) }
        set {
            defaults.set(newValue.sorted(), forKey: Key.keepResidentCorpora)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    func isKeepResident(_ name: String) -> Bool {
        keepResidentCorpora.contains(name)
    }

    /// A corpus was renamed: its "Keep in Memory" choice follows it.
    func renameKeepResident(from old: String, to new: String) {
        var names = keepResidentCorpora
        guard names.remove(old) != nil else { return }
        names.insert(new)
        keepResidentCorpora = names
    }

    func setKeepResident(_ keep: Bool, for name: String) {
        var names = keepResidentCorpora
        if keep { names.insert(name) } else { names.remove(name) }
        keepResidentCorpora = names
    }

    var resultsFontName: String {
        get { defaults.string(forKey: Key.resultsFontName) ?? "Menlo" }
        set {
            defaults.set(newValue, forKey: Key.resultsFontName)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var resultsFontSize: Double {
        get {
            let value = defaults.double(forKey: Key.resultsFontSize)
            return value > 0 ? value : 12
        }
        set {
            defaults.set(newValue, forKey: Key.resultsFontSize)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var resultsFont: NSFont {
        NSFont(name: resultsFontName, size: CGFloat(resultsFontSize))
            ?? .monospacedSystemFont(ofSize: CGFloat(resultsFontSize), weight: .regular)
    }

    /// Minimum free memory (bytes) a corpus's "Keep in Memory" toggle must
    /// leave available - see `ManateeKit.CorpusMemoryResidency.
    /// canKeepResident`. Defaults to 10 GB.
    var minimumFreeMemoryAfterResidency: UInt64 {
        get {
            let value = defaults.integer(forKey: Key.minimumFreeMemoryAfterResidency)
            return value > 0 ? UInt64(value) : 10_000_000_000
        }
        set {
            defaults.set(Int(newValue), forKey: Key.minimumFreeMemoryAfterResidency)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Seeds `ConcordanceDocument.leftContext`/`rightContext` for a
    /// brand-new document - see `ConcordanceDocument`'s property
    /// declarations, which read these at instance-creation time.
    var defaultLeftContext: Int {
        get {
            let value = defaults.integer(forKey: Key.defaultLeftContext)
            return value > 0 ? value : 10
        }
        set {
            defaults.set(newValue, forKey: Key.defaultLeftContext)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var defaultRightContext: Int {
        get {
            let value = defaults.integer(forKey: Key.defaultRightContext)
            return value > 0 ? value : 10
        }
        set {
            defaults.set(newValue, forKey: Key.defaultRightContext)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Seeds `ConcordanceDocument.viewMode` for a brand-new document -
    /// see `ConcordanceViewMode`.
    /// How many hits a search loads at most. A search with more hits shows the first ones and says
    /// how many there are in all; sorting and sampling work on the loaded ones.
    var maxConcordanceLines: Int {
        get {
            let value = defaults.integer(forKey: Key.maxConcordanceLines)
            return value > 0 ? value : ConcordanceLimit.defaultLimit
        }
        set {
            defaults.set(newValue, forKey: Key.maxConcordanceLines)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var defaultExtendedContextTokens: Int {
        get {
            let value = defaults.integer(forKey: Key.defaultExtendedContextTokens)
            return value > 0 ? value : 50
        }
        set {
            defaults.set(newValue, forKey: Key.defaultExtendedContextTokens)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// How "Extended Context…" presents itself - see
    /// `ExtendedContextDisplayMode`. Defaults to `.sheet`, the original
    /// 6.6 behavior.
    var extendedContextDisplayMode: ExtendedContextDisplayMode {
        get {
            defaults.string(forKey: Key.extendedContextDisplayMode)
                .flatMap(ExtendedContextDisplayMode.init(rawValue:)) ?? .sheet
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.extendedContextDisplayMode)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Whether more than one Extended Context can be visible at once
    /// (Phase 6.6a) - governs *both* presentations from this single
    /// switch: several rows expanded simultaneously in `.inline` mode, and
    /// several stacked windows in `.sheet` (labelled "Window") mode.
    ///
    /// Defaults to `false`, which is exactly 6.6's shipped behavior:
    /// expanding one row collapses whichever was open, and opening a
    /// window for another row replaces the previous one. Turning it on is
    /// also what puts the per-row disclosure triangle in the concordance
    /// table - with one-at-a-time expansion there's little to disclose,
    /// and the triangle would only add a column of chrome.
    var allowMultipleExtendedContexts: Bool {
        get { defaults.bool(forKey: Key.allowMultipleExtendedContexts) }
        set {
            defaults.set(newValue, forKey: Key.allowMultipleExtendedContexts)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Per-script concordance font overrides (Unicode script `rawValue` →
    /// font name - see `UnicodeScript`), for a corpus mixing scripts where
    /// `resultsFont` alone isn't ideal for all of them. A script with no
    /// entry here just keeps using `resultsFont`.
    var scriptFontOverrides: [String: String] {
        get { defaults.dictionary(forKey: Key.scriptFontOverrides) as? [String: String] ?? [:] }
        set {
            defaults.set(newValue, forKey: Key.scriptFontOverrides)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The color inline/hover positional attributes (e.g. "tag", "lemma")
    /// render in - see `KWICCellView`. Was hardcoded `.secondaryLabelColor`
    /// before this setting existed; that's still the default.
    var positionalAttributeColor: NSColor {
        get { color(forKey: Key.positionalAttributeColor) ?? .secondaryLabelColor }
        set { setColor(newValue, forKey: Key.positionalAttributeColor) }
    }

    /// The color the structural-attribute ("Doc") column renders in - see
    /// `KWICCellView.configureStructuralInfo`. Same default as
    /// `positionalAttributeColor` before this setting existed.
    var structuralAttributeColor: NSColor {
        get { color(forKey: Key.structuralAttributeColor) ?? .secondaryLabelColor }
        set { setColor(newValue, forKey: Key.structuralAttributeColor) }
    }

    /// Whether the concordance table stripes alternating rows - see
    /// `ConcordanceViewController.setUpTableView`. Defaults to `true`
    /// (unchanged from before this setting existed). A custom tint color
    /// for the stripe itself was considered and dropped - that needs
    /// custom row drawing (`NSTableView`'s own alternating colors aren't
    /// independently recolorable), not just a setting, and no native Mac
    /// app actually lets you customize this, so it wasn't worth the
    /// custom-drawing complexity for a look nobody else offers either.
    var usesAlternatingRowBackground: Bool {
        get {
            defaults.object(forKey: Key.usesAlternatingRowBackground) == nil
                ? true : defaults.bool(forKey: Key.usesAlternatingRowBackground)
        }
        set {
            defaults.set(newValue, forKey: Key.usesAlternatingRowBackground)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// `UserDefaults` has no native `NSColor` support - archives via
    /// `NSKeyedArchiver`/`Unarchiver` (`NSColor` conforms to
    /// `NSSecureCoding`), same general shape as every other property here,
    /// just with an extra encode/decode step. Returns nil (rather than a
    /// hardcoded fallback) when nothing's been set, so each color
    /// property above can supply its own semantically-meaningful default.
    private func color(forKey key: String) -> NSColor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private func setColor(_ color: NSColor, forKey key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
