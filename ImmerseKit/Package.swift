// swift-tools-version: 5.10
import PackageDescription

// Code shared by the macOS and iOS apps. Nothing in here may import AppKit, UIKit or SwiftUI.
let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    // SE-0418: KeyPath literals are inferred as Sendable (SwiftData #Predicate / SortDescriptor)
    .enableUpcomingFeature("InferSendableFromCaptures"),
]

let package = Package(
    name: "ImmerseKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ImmerseCore", targets: ["ImmerseCore"]),
    ],
    targets: [
        .target(name: "ImmerseCore", swiftSettings: swiftSettings),
        .testTarget(name: "ImmerseCoreTests", dependencies: ["ImmerseCore"], swiftSettings: swiftSettings),
    ]
)
