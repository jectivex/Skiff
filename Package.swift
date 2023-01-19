// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Skiff",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "Skiff", targets: ["Skiff"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jectivex/Kanji.git", from: "1.1.3"),
        .package(url: "https://github.com/jectivex/Gryphon.git", branch: "main"),
        //.package(url: "https://github.com/jectivex/Gryphon.git", from: "0.2.2"), // 'gryphon' >= 0.2.0 cannot be used because no versions of 'gryphon' match the requirement 0.2.1..<1.0.0 and package 'gryphon' is required using a stable-version but 'gryphon' depends on an unstable-version package 'swift-syntax'.
    ],
    targets: [
        .target(name: "Skiff", dependencies: [.product(name: "GryphonLib", package: "Gryphon")]),
        .testTarget(name: "SkiffTests", dependencies: ["Skiff", .product(name: "KotlinKanji", package: "Kanji")]),
    ]
)
