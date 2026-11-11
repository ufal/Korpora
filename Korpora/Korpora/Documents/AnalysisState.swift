import AppKit
import KorporaEngine

/// An analysis window a concordance had open (frequencies, collocations, dispersion): what is saved with the
/// concordance's draft so that the window comes back, with its results made again, after a quit or a relaunch
/// (docs/project-plan.md, "Document persistence model").
struct AnalysisState: Codable, Equatable {
    enum Kind: String, Codable { case frequency, collocation, dispersion }

    var kind: Kind
    /// Frequencies: what was counted, the order it was asked in, and the lowest frequency kept.
    var fields: [FrequencyField]?
    var sortKeys: [FrequencySortKey]?
    var minFrequency: Int?
    /// Collocations: the form that was filled in.
    var collocation: CollocationSpec?
    /// Where the window was (`NSStringFromRect`), when it was saved.
    var frame: String?

    static func frequency(fields: [FrequencyField], sortKeys: [FrequencySortKey], minFrequency: Int) -> AnalysisState {
        AnalysisState(kind: .frequency, fields: fields, sortKeys: sortKeys, minFrequency: minFrequency)
    }

    static func collocation(_ spec: CollocationSpec) -> AnalysisState {
        AnalysisState(kind: .collocation, collocation: spec)
    }

    static var dispersion: AnalysisState { AnalysisState(kind: .dispersion) }

    /// The frame, if it is a real one that is still on a screen (a window saved on a disk or a display that is not
    /// there now would come back out of sight).
    var visibleFrame: NSRect? {
        guard let frame else { return nil }
        let rect = NSRectFromString(frame)
        guard rect.width > 50, rect.height > 50, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) else { return nil }
        return rect
    }
}
