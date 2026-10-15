// swift-tools-version: 5.9
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "UmbilicalEngine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "UmbilicalEngine", targets: ["UmbilicalEngine"]),
        .executable(name: "umb-watch", targets: ["umb-watch"]),
    ],
    targets: [
        .executableTarget(
            name: "umb-watch",
            path: "Sources/umb-watch",
            sources: ["main.c"],
            cSettings: [
                .define("_GNU_SOURCE"),
            ]
        ),
        .target(
            name: "CXAttr",
            path: "Sources/CXAttr",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CProc",
            path: "Sources/CProc",
            publicHeadersPath: "include"
        ),
        .target(
            name: "UmbilicalEngine",
            dependencies: ["CXAttr", "CProc"],
            path: "Sources/UmbilicalEngine"
        ),
        .testTarget(
            name: "UmbilicalEngineTests",
            dependencies: ["UmbilicalEngine"],
            path: "Tests/UmbilicalEngineTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
