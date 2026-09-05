// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LocalVoiceKeyboard",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "VoiceKeyboardCore", targets: ["VoiceKeyboardCore"]),
        .executable(name: "core-smoke", targets: ["CoreSmoke"]),
    ],
    targets: [
        .target(
            name: "VoiceKeyboardCore",
            path: "Sources/VoiceKeyboardCore"
        ),
        .testTarget(
            name: "VoiceKeyboardCoreTests",
            dependencies: ["VoiceKeyboardCore"],
            path: "Tests/VoiceKeyboardCoreTests"
        ),
        .executableTarget(
            name: "CoreSmoke",
            dependencies: ["VoiceKeyboardCore"],
            path: "Tests/CoreSmoke"
        ),
    ]
)
