import Cocoa
import KorporaEngine

/// The sheet shown while corpora are copied or moved (to another disk this takes a while): what is being done,
/// a progress bar, how much is done, an estimate of the time left, and Cancel.
final class TransferProgressSheetController: NSViewController {
    private let headline: String
    private let currentLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "Preparing\u{2026}")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let started = Date()

    /// Called when the user cancels. The sheet stays until the work has stopped; the caller dismisses it.
    var onCancel: (() -> Void)?

    init(headline: String) {
        self.headline = headline
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
        let title = NSTextField(labelWithString: headline)
        title.font = .boldSystemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle
        currentLabel.textColor = .secondaryLabelColor
        currentLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"
        for v in [title, currentLabel, bar, detailLabel, cancelButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            currentLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            currentLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            currentLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: currentLabel.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancelButton.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            cancelButton.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
        preferredContentSize = root.frame.size
    }

    func update(_ progress: CorpusLibrary.TransferProgress) {
        _ = view
        currentLabel.stringValue = "\u{201C}\(progress.name)\u{201D}"
        bar.doubleValue = progress.bytesTotal > 0 ? Double(progress.bytesDone) / Double(progress.bytesTotal) : 0
        detailLabel.stringValue = Self.detail(
            done: progress.bytesDone, total: progress.bytesTotal, elapsed: Date().timeIntervalSince(started))
    }

    @objc private func cancelTapped() {
        cancelButton.isEnabled = false
        detailLabel.stringValue = "Stopping\u{2026}"
        onCancel?()
    }

    // MARK: Wording

    /// "3.2 GB of 11.8 GB \u{2014} about 4 minutes remaining".
    static func detail(done: Int64, total: Int64, elapsed: TimeInterval) -> String {
        let formatter = ByteCountFormatter()
        let amount = "\(formatter.string(fromByteCount: done)) of \(formatter.string(fromByteCount: total))"
        guard let left = remaining(done: done, total: total, elapsed: elapsed) else {
            return amount + " \u{2014} estimating the time remaining\u{2026}"
        }
        return amount + " \u{2014} " + describe(remaining: left)
    }

    /// Seconds left at the speed so far; nil until there is a fair basis for a guess (a few seconds of work).
    static func remaining(done: Int64, total: Int64, elapsed: TimeInterval) -> TimeInterval? {
        guard done > 0, total >= done, elapsed >= 3 else { return nil }
        return Double(total - done) / (Double(done) / elapsed)
    }

    static func describe(remaining seconds: TimeInterval) -> String {
        switch seconds {
        case ..<10: return "almost done"
        case ..<45: return "less than a minute remaining"
        case ..<90: return "about a minute remaining"
        case ..<(90 * 60):
            return "about \(Int((seconds / 60).rounded())) minutes remaining"
        default:
            let hours = Int((seconds / 3600).rounded())
            return "about \(hours) \(hours == 1 ? "hour" : "hours") remaining"
        }
    }
}
