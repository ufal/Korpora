import Cocoa
import KorporaEngine

/// The sheet behind Corpora settings' "Import Annotated Text…": takes the files or folders the
/// caller picked (CoNLL-U, or CWB-style verticals), asks for a name, and builds the corpus with
/// `CorpusImporter` (docs/pando-gui-plan.md). One screen of choices, then one of progress.
final class CorpusImportSheetController: NSViewController {
    private let inputs: [URL]
    var onImported: (() -> Void)?

    private let nameField = NSTextField(string: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private let formView = NSView()
    private let progressView = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Starting\u{2026}")
    private let tokensLabel = NSTextField(labelWithString: "")
    private let disclosureButton = NSButton(title: "Show Log", target: nil, action: nil)
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var logHeight: NSLayoutConstraint!
    private var importTask: Task<Void, Never>?
    private let log = ImportLog()

    init(inputs: [URL]) {
        self.inputs = inputs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: What is being imported

    /// How many input files there are (a folder counts the files inside) and their size.
    static func describe(_ inputs: [URL]) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        var files = 0
        var bytes: Int64 = 0
        let wanted: Set<String> = ["conllu", "conll", "vrt", "vert", "jsonl", "ndjson", "txt"]
        func add(_ url: URL) {
            guard wanted.contains(url.pathExtension.lowercased()) else { return }
            files += 1
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        for input in inputs {
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: input.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let walker = fm.enumerator(at: input, includingPropertiesForKeys: [.fileSizeKey],
                                           options: [.skipsHiddenFiles])
                while let url = walker?.nextObject() as? URL { add(url) }
            } else {
                files += 1
                bytes += Int64((try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return (files, bytes)
    }

    /// A first name for the corpus: the folder or file name; for several files, their folder's.
    static func suggestedName(for inputs: [URL]) -> String {
        guard let first = inputs.first else { return "Corpus" }
        let base = inputs.count == 1 ? first.deletingPathExtension().lastPathComponent
            : first.deletingLastPathComponent().lastPathComponent
        let cleaned = base.trimmingCharacters(in: .whitespaces)
        return CorpusLibrary.uniqueName(cleaned.isEmpty ? "Corpus" : cleaned, taken: Set(CorpusLibrary.names()))
    }

    // MARK: View

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 230))

        let title = NSTextField(labelWithString: "Import Corpus")
        title.font = .boldSystemFont(ofSize: 13)

        let (count, bytes) = Self.describe(inputs)
        let kind: String
        switch CorpusImporter.kind(of: inputs) {
        case .conllu: kind = "CoNLL-U"
        case .vertical: kind = "vertical"
        case .jsonl: kind = "JSONL"
        }
        let size = ByteCountFormatter().string(fromByteCount: bytes)
        summaryLabel.stringValue = "\(count.formatted()) \(kind) file\(count == 1 ? "" : "s") (\(size)) will be indexed into one "
            + "corpus you can search. A large corpus takes a few minutes."
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameField.stringValue = Self.suggestedName(for: inputs)
        nameField.delegate = self

        importButton.target = self
        importButton.action = #selector(importTapped)
        importButton.keyEquivalent = "\r"
        importButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        for v in [nameLabel, nameField, summaryLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            formView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: formView.topAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: formView.leadingAnchor),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: formView.trailingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 14),
            summaryLabel.leadingAnchor.constraint(equalTo: formView.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: formView.trailingAnchor),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: formView.bottomAnchor),
        ])

        buildProgressView()
        progressView.isHidden = true

        for v in [title, formView, progressView, cancelButton, importButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            formView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            formView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            formView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            progressView.topAnchor.constraint(equalTo: formView.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: formView.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: formView.trailingAnchor),

            formView.bottomAnchor.constraint(lessThanOrEqualTo: importButton.topAnchor, constant: -12),
            progressView.bottomAnchor.constraint(lessThanOrEqualTo: importButton.topAnchor, constant: -12),

            importButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            importButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -8),
        ])
        view = root
        preferredContentSize = NSSize(width: 480, height: 230)
        updateImportEnabled()
    }

    private func buildProgressView() {
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        statusLabel.lineBreakMode = .byTruncatingMiddle
        tokensLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tokensLabel.textColor = .secondaryLabelColor
        disclosureButton.bezelStyle = .inline
        disclosureButton.controlSize = .small
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleLog)
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textContainerInset = NSSize(width: 4, height: 4)
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.isHidden = true
        for v in [progressIndicator, statusLabel, tokensLabel, disclosureButton, logScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            progressView.addSubview(v)
        }
        logHeight = logScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            progressIndicator.topAnchor.constraint(equalTo: progressView.topAnchor),
            progressIndicator.leadingAnchor.constraint(equalTo: progressView.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: progressView.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: progressView.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: progressView.trailingAnchor),
            tokensLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),
            tokensLabel.leadingAnchor.constraint(equalTo: progressView.leadingAnchor),
            disclosureButton.topAnchor.constraint(equalTo: tokensLabel.bottomAnchor, constant: 8),
            disclosureButton.leadingAnchor.constraint(equalTo: progressView.leadingAnchor),
            logScroll.topAnchor.constraint(equalTo: disclosureButton.bottomAnchor, constant: 6),
            logScroll.leadingAnchor.constraint(equalTo: progressView.leadingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: progressView.trailingAnchor),
            logScroll.bottomAnchor.constraint(equalTo: progressView.bottomAnchor),
            logHeight,
        ])
    }

    private var name: String { nameField.stringValue.trimmingCharacters(in: .whitespaces) }

    private func updateImportEnabled() {
        let taken = CorpusLibrary.names().contains(name)
        importButton.isEnabled = !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !taken
        nameField.textColor = taken ? .systemRed : .labelColor
        nameField.toolTip = taken ? "A corpus with this name is already in Korpora." : nil
    }

    // MARK: Importing

    @objc private func importTapped() {
        let name = self.name
        formView.isHidden = true
        progressView.isHidden = false
        importButton.isHidden = true
        cancelButton.title = "Cancel Import"
        progressIndicator.startAnimation(nil)
        let log = log
        let inputs = inputs
        importTask = Task { @MainActor [weak self] in
            // The tool's output arrives off the main thread; a short timer applies it to the views.
            let ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.apply(log.snapshot())
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            defer { ticker.cancel() }
            do {
                try await CorpusImporter.importCorpus(name: name, inputs: inputs) { progress in log.update(progress) }
                self?.apply(log.snapshot())
                self?.onImported?()
                self?.dismiss(nil)
            } catch is CancellationError {
                self?.dismiss(nil)
            } catch {
                self?.showFailure(error)
            }
        }
    }

    private func apply(_ snapshot: ImportLog.Snapshot) {
        guard let progress = snapshot.progress else { return }
        switch progress.phase {
        case .starting:
            statusLabel.stringValue = "Starting\u{2026}"
        case .reading:
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = progress.fraction ?? 0
            statusLabel.stringValue = "Reading \(progress.currentFile ?? "")"
        case .finishing:
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            statusLabel.stringValue = "Finishing the index\u{2026}"
        }
        tokensLabel.stringValue = progress.tokens > 0 ? "\(progress.tokens.formatted()) tokens indexed so far" : ""
        if !logScroll.isHidden, logView.string != snapshot.text {
            logView.string = snapshot.text
            logView.scrollToEndOfDocument(nil)
        }
    }

    private func showFailure(_ error: Error) {
        importTask = nil
        formView.isHidden = false
        progressView.isHidden = true
        importButton.isHidden = false
        cancelButton.title = "Cancel"
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "The corpus couldn\u{2019}t be imported"
        alert.informativeText = "\(error)"
        alert.beginSheetModal(for: window)
    }

    @objc private func toggleLog() {
        let show = logScroll.isHidden
        logScroll.isHidden = !show
        logHeight.constant = show ? 110 : 0
        disclosureButton.title = show ? "Hide Log" : "Show Log"
        preferredContentSize = NSSize(width: 480, height: show ? 340 : 230)
        if show { logView.string = log.snapshot().text }
    }

    @objc private func cancelTapped() {
        if let importTask {
            importTask.cancel()   // the importer stops the tool and removes the partial corpus
        } else {
            dismiss(nil)
        }
    }
}

extension CorpusImportSheetController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { updateImportEnabled() }
}

/// Where the importer's progress (reported from another thread) is kept until the UI asks for it.
private final class ImportLog: @unchecked Sendable {
    struct Snapshot { var progress: CorpusImporter.Progress?; var text: String }

    private let lock = NSLock()
    private var latest: CorpusImporter.Progress?
    private var lines: [String] = []

    func update(_ progress: CorpusImporter.Progress) {
        lock.lock()
        latest = progress
        if !progress.line.isEmpty { lines.append(progress.line) }
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(progress: latest, text: lines.joined(separator: "\n"))
    }
}
