// swift-tools-version: 6.2

import PackageDescription

// Small libraries, one package. Each is its own product, and a consumer
// compiles only the targets behind the products it names, so an unused
// library costs a clone and nothing more. Each library is documented in
// docs/<Library>.md; README.md is the index.
//
// No library has dependencies outside this package. Keep it that way: a
// dependency here would be resolved by every consumer of every library.
//
// Every target: Swift 6 language mode, and default actor isolation `nil`
// (nonisolated) — `@MainActor` is marked where it is needed.
let shared: [SwiftSetting] = [.swiftLanguageMode(.v6), .defaultIsolation(nil)]

let package = Package(
    name: "app-utils", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BooleanRules", targets: ["BooleanRules"]),
        .library(name: "BooleanRulesUI", targets: ["BooleanRulesUI"]),
    ],
    targets: [
        // BooleanRules — docs/BooleanRules.md
        .target(name: "BooleanRules", swiftSettings: shared),
        .target(name: "BooleanRulesUI", dependencies: ["BooleanRules"], swiftSettings: shared),
        .testTarget(
            name: "BooleanRulesTests", dependencies: ["BooleanRules"], swiftSettings: shared),
    ])
