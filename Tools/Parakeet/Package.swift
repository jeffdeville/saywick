// swift-tools-version: 5.9
import PackageDescription

// Copied into .build/Parakeet/SwiftPackage by bootstrap.sh.
let package = Package(
    name: "SaywickTranscribeCpp",
    platforms: [.iOS(.v16)],
    products: [.library(name: "TranscribeCpp", targets: ["TranscribeCpp"])],
    targets: [
        .binaryTarget(name: "CTranscribe", path: "TranscribeCpp.xcframework"),
        .target(name: "TranscribeCpp", dependencies: ["CTranscribe"], linkerSettings: [
            .linkedLibrary("c++"), .linkedLibrary("z"),
            .linkedFramework("Accelerate"), .linkedFramework("Foundation"),
            .linkedFramework("Metal"), .linkedFramework("MetalKit")
        ])
    ]
)
