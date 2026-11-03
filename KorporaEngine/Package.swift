// swift-tools-version:5.9
import PackageDescription

// The engine layer of Korpora: the protocols the app talks to (`CorpusEngine`
// and friends), the pando implementation (loaded at run time with dlopen, so
// nothing links against it), the corpus library, import, and subcorpora.
let package = Package(
    name: "KorporaEngine",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KorporaEngine", targets: ["KorporaEngine"]),
    ],
    targets: [
        .target(name: "KorporaEngine"),
        .testTarget(name: "KorporaEngineTests", dependencies: ["KorporaEngine"]),
    ]
)
