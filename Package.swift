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
        .package(url: "https://github.com/jectivex/Kanji.git", from: "0.2.1"),
        .package(url: "https://github.com/marcprux/Gryphon.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "Skiff",
            dependencies: [
                .product(name: "GryphonLib", package: "Gryphon"),
                .product(name: "KotlinKanji", package: "Kanji"),
            ]),
        .testTarget(
            name: "SkiffTests",
            dependencies: ["Skiff"]),
    ]
)
