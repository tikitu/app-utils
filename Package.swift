// swift-tools-version: 6.2

import PackageDescription

// A small library, meant to leave this repo one day: boolean expressions over
// terms the caller defines, a text syntax for them, and a rule editor. No
// dependencies, so taking it elsewhere is copying a directory. See README.md.
let shared: [SwiftSetting] = [.swiftLanguageMode(.v6), .defaultIsolation(nil)]

let package = Package(
    name: "BooleanRules", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BooleanRules", targets: ["BooleanRules"]),
        .library(name: "BooleanRulesUI", targets: ["BooleanRulesUI"]),
    ],
    targets: [
        .target(name: "BooleanRules", swiftSettings: shared),
        .target(name: "BooleanRulesUI", dependencies: ["BooleanRules"], swiftSettings: shared),
        .testTarget(
            name: "BooleanRulesTests", dependencies: ["BooleanRules"], swiftSettings: shared),
    ])
