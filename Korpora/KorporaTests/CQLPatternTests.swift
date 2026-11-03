import Cocoa
import KorporaEngine
import Testing
@testable import Korpora

/// The "Insert pattern" menu: every template is real pando-CQL, the caret lands where the template
/// says, and patterns that need attributes a corpus lacks are greyed out. Serialized: the corpus
/// library is pointed at a temporary folder through the process environment. The pando-backed test
/// passes silently when there is no pando build.
@MainActor @Suite(.serialized) final class CQLPatternTests {
    private let box: TestPando.Sandbox
    private let engine: PandoEngine?
    private static let corpus = "korporapatterns"

    private static let text = """
        # newdoc id = 1
        # sent_id = a
        1\tthe\tthe\tDET\t_\t_\t3\tdet\t_\t_
        2\tquick\tquick\tADJ\t_\t_\t3\tamod\t_\t_
        3\tfox\tfox\tNOUN\t_\t_\t4\tnsubj\t_\t_
        4\tjumps\tjump\tVERB\t_\t_\t0\troot\t_\t_

        # sent_id = b
        1\ta\ta\tDET\t_\t_\t2\tdet\t_\t_
        2\tcat\tcat\tNOUN\t_\t_\t3\tnsubj\t_\t_
        3\tsleeps\tsleep\tVERB\t_\t_\t0\troot\t_\t_


        """

    init() async throws {
        box = try TestPando.Sandbox()
        engine = try await box.buildCorpus(Self.corpus, conllu: Self.text) ? TestPando.engine() : nil
    }

    private var allPatterns: [CQLPattern] { CQLPatterns.sections.flatMap(\.patterns) }

    /// Each template, with the caret marker removed, is accepted by pando.
    @Test func everyTemplateIsValidPandoCQL() async throws {
        guard let engine else { return }
        let corpus = try await engine.openCorpus(name: Self.corpus)
        for pattern in allPatterns {
            let query = pattern.insertion.text
            do {
                _ = try await engine.openConcordance(query: query, in: corpus, limit: 100)
            } catch {
                Issue.record("\(pattern.title): \(query): \(error)")
            }
        }
    }

    @Test func theCaretGoesWhereTheTemplateMarksIt() {
        let pattern = CQLPattern(title: "", template: "[child [\(CQLPattern.caret)]]", detail: "")
        #expect(pattern.insertion.text == "[child []]" && pattern.insertion.caretOffset == 8)
        let none = CQLPattern(title: "", template: #"[upos="NOUN"]"#, detail: "")
        #expect(none.insertion.caretOffset == 13, "no marker: at the end")
        #expect(allPatterns.allSatisfy { !$0.insertion.text.contains(CQLPattern.caret) })
    }

    @Test func insertingPutsTheTextAtTheCaretAndTheCursorInsideTheBrackets() {
        let field = CQLQueryField(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        field.text = #"[upos="NOUN"] "#
        field.textView.setSelectedRange(NSRange(location: 14, length: 0))
        field.insertPattern("[\(CQLPattern.caret)] > []")
        #expect(field.text == #"[upos="NOUN"] [] > []"#)
        #expect(field.textView.selectedRange() == NSRange(location: 15, length: 0))
    }

    @Test func aSelectionIsReplaced() {
        let field = CQLQueryField(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        field.text = "old"
        field.textView.setSelectedRange(NSRange(location: 0, length: 3))
        field.insertPattern("[child [\(CQLPattern.caret)]]")
        #expect(field.text == "[child []]")
    }

    @Test func patternsThatNeedMissingAttributesAreGreyedOut() {
        func item(_ title: String, _ available: Set<String>?) -> NSMenuItem? {
            CQLPatterns.makeMenu(target: self, action: #selector(noop(_:)), availableAttributes: available)
                .items.first { $0.title == title }
        }
        #expect(item("Verb without a subject", ["upos", "deprel", "form"])?.action != nil)
        #expect(item("Verb without a subject", ["form", "lemma"])?.action == nil)
        #expect(item("Verb without a subject", nil)?.action != nil, "no corpus information: nothing is greyed out")
        #expect(item("Word with a dependent", ["form"])?.action != nil, "the general patterns need no particular attribute")
        #expect(item("Noun with a determiner", ["form"])?.toolTip?.contains("no upos") == true)
    }

    @objc private func noop(_ sender: Any?) {}
}
