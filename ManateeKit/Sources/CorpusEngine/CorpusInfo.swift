import Foundation

// Both of these carry `public let`s but had only their synthesized
// *internal* initializers, so a client could read one but never build one -
// which also meant a client couldn't unit-test anything taking a
// `CorpusInfo` without opening a real corpus. They're plain value types
// describing a schema, so being constructible is the intended shape.

public struct StructureInfo: Sendable {
    public let name: String
    public let attributes: [String]

    public init(name: String, attributes: [String]) {
        self.name = name
        self.attributes = attributes
    }
}

public struct CorpusInfo: Sendable {
    public let name: String
    public let sizeTokens: Int
    public let attributes: [String]
    public let structures: [StructureInfo]

    public init(name: String, sizeTokens: Int, attributes: [String], structures: [StructureInfo]) {
        self.name = name
        self.sizeTokens = sizeTokens
        self.attributes = attributes
        self.structures = structures
    }
}
