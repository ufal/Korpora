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
        /// The corpora to keep in memory, by name.
        static let keepResidentCorpora = "keepResidentCorpora"
        static let resultsFontName = "resultsFontName"
        static let resultsFontSize = "resultsFontSize"
        static let maxConcordanceLines = "maxConcordanceLines"
        static let minimumFreeMemoryAfterResidency = "minimumFreeMemoryAfterResidency"
        static let defaultLeftContext = "defaultLeftContext"
        static let defaultRightContext = "defaultRightContext"
        static let defaultViewMode = "defaultViewMode"
        static let defaultExtendedContextTokens = "defaultExtendedContextTokens"
        static let scriptFontOverrides = "scriptFontOverrides"
        static let scriptFonts = "scriptFonts"
        static let positionalAttributeColor = "positionalAttributeColor"
        static let structuralAttributeColor = "structuralAttributeColor"
        static let matchColor = "matchColor"
        static let corpusOrder = "corpusOrder"
        static let usesAlternatingRowBackground = "usesAlternatingRowBackground"
        static let extendedContextDisplayMode = "extendedContextDisplayMode"
        static let allowMultipleExtendedContexts = "allowMultipleExtendedContexts"
        static let corporaDirectory = "corporaDirectory"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every corpus in the library (built and linked).
    /// The folder the user chose for the corpora Korpora builds (an external disk, say); nil for the default one.
    /// The library follows it (`CorpusLibrary.customBaseDirectory`) once `applyCorporaDirectory()` has run.
    var corporaDirectory: URL? {
        get { defaults.string(forKey: Key.corporaDirectory).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set {
            if let newValue {
                defaults.set(newValue.path, forKey: Key.corporaDirectory)
            } else {
                defaults.removeObject(forKey: Key.corporaDirectory)
            }
            applyCorporaDirectory()
            NotificationCenter.default.post(name: Self.corporaDidChangeNotification, object: nil)
        }
    }

    /// Tells the corpus library where the user keeps built corpora. Done at launch and on every change; only for
    /// the app's own settings, so that tests with their own defaults leave the library alone.
    func applyCorporaDirectory() {
        guard self === AppSettings.shared else { return }
        CorpusLibrary.customBaseDirectory = corporaDirectory
        applyCorpusOrder()
    }

    /// The order the user put the corpora in, in the list and so in the New Concordance pop-up, whose first is the
    /// one a new concordance starts with. Empty until the user reorders: then built corpora first, linked after,
    /// each alphabetical. Given to the corpus library (here, at launch and on every change).
    var corpusOrder: [String] {
        get { defaults.stringArray(forKey: Key.corpusOrder) ?? [] }
        set {
            defaults.set(newValue, forKey: Key.corpusOrder)
            applyCorpusOrder()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    func applyCorpusOrder() {
        guard self === AppSettings.shared else { return }
        CorpusLibrary.customOrder = corpusOrder
    }

    /// A corpus was renamed: it keeps its place.
    func renameInCorpusOrder(from old: String, to new: String) {
        var order = corpusOrder
        guard let index = order.firstIndex(of: old) else { return }
        order[index] = new
        corpusOrder = order
    }

    /// - Parameter includingMissing: also the linked corpora whose index folder is gone (the list shows them with
    ///   a warning); anything that searches leaves them out.
    func corpusLibraryEntries(includingMissing: Bool = false) -> [CorpusLibrary.Entry] {
        CorpusLibrary.entries(includingMissing: includingMissing)
    }

    /// Names of corpora to keep warm in memory - any corpus, built, linked or imported.
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

    /// The font and size for each script (`ScriptFonts`); there is no global font. A table saved by an older
    /// version (one results font and a font name per coarse script) becomes this one the first time it is read.
    var scriptFonts: [String: ScriptFont] {
        get {
            if let data = defaults.data(forKey: Key.scriptFonts),
               let table = try? JSONDecoder().decode([String: ScriptFont].self, from: data) { return table }
            return ScriptFonts.migrated(
                resultsFontName: defaults.string(forKey: Key.resultsFontName),
                resultsFontSize: defaults.object(forKey: Key.resultsFontSize) as? Double,
                overrides: defaults.dictionary(forKey: Key.scriptFontOverrides) as? [String: String] ?? [:])
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.scriptFonts)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// The Latin font: what labels the app draws in the results style (secondary attributes, extended context) use.
    var resultsFont: NSFont {
        ScriptFontResolver.shared.font(for: .latin).font
    }

    /// Minimum free memory (bytes) a corpus's "Keep in Memory" toggle must
    /// leave available - see `CorpusMemoryResidency.
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
    var defaultViewMode: ConcordanceViewMode {
        get { defaults.string(forKey: Key.defaultViewMode).flatMap(ConcordanceViewMode.init(rawValue:)) ?? .kwic }
        set {
            defaults.set(newValue.rawValue, forKey: Key.defaultViewMode)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Up to how many hits a result is sorted, shuffled and grouped in memory, with every option. Searches
    /// show every hit; on a bigger result pando sorts one key, shuffles and samples, and what it can't do
    /// (several keys, line groups, ...) works on the first hits only (the status line says so).
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

    /// The color the matched words render in (bold), in the Match column and in an extended context. Red, so it
    /// doesn't blend with the selection, which is drawn in the accent color (blue unless the user changed it).
    var matchColor: NSColor {
        get { color(forKey: Key.matchColor) ?? .systemRed }
        set { setColor(newValue, forKey: Key.matchColor) }
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
