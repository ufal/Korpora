import Foundation
import XCTest
@testable import KorporaEngine

final class StructureOrderTests: XCTestCase {
    func testTextAndDocumentComeFirstThenTheRestAlphabetically() {
        let given = ["contr", "doc", "par", "s", "text", "zone", "align"].map { StructureInfo(name: $0, attributes: []) }
        XCTAssertEqual(StructureInfo.ordered(given).map(\.name), ["text", "doc", "par", "s", "align", "contr", "zone"])
    }

    func testAttributesAreInNaturalOrderAndSentenceTranslationsGoLast() {
        let s = StructureInfo(name: "s", attributes: [
            "text_es", "tuid", "text_cmn", "sent_id", "text_en", "type", "24_sent_id", "text_alt", "prominence", "text_url"])
        let ordered = StructureInfo.ordered([s])[0].attributes
        XCTAssertEqual(ordered, ["24_sent_id", "prominence", "sent_id", "text_url", "tuid", "type",
                                 "text_alt", "text_cmn", "text_en", "text_es"])
    }

    func testOnlyTheSentenceHasTranslationsSoTheTextRegionIsPlainAlphabetical() {
        let text = StructureInfo(name: "text", attributes: ["lang", "text_x", "id", "treebank", "langcode"])
        XCTAssertEqual(StructureInfo.ordered([text])[0].attributes, ["id", "lang", "langcode", "text_x", "treebank"])
        XCTAssertTrue(StructureInfo.isSentenceTranslation("text_en"))
        XCTAssertTrue(StructureInfo.isSentenceTranslation("text_got"))
        XCTAssertFalse(StructureInfo.isSentenceTranslation("text_url"))
        XCTAssertFalse(StructureInfo.isSentenceTranslation("text_id"))
        XCTAssertFalse(StructureInfo.isSentenceTranslation("sent_id"))
    }
}
