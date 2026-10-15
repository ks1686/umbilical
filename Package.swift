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
        .library(name: "UmbilicalUI", targets: ["UmbilicalUI"]),
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
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("proc", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "UmbilicalEngine",
            dependencies: ["CXAttr", "CProc"],
            path: "Sources/UmbilicalEngine"
        ),
        .target(
            name: "UmbilicalUI",
            dependencies: ["UmbilicalEngine"],
            path: "App/Session"
        ),
        .testTarget(
            name: "UmbilicalEngineTests",
            dependencies: ["UmbilicalEngine"],
            path: "Tests/UmbilicalEngineTests"
        ),
        .testTarget(
            name: "UmbilicalUITests",
            dependencies: ["UmbilicalUI", "UmbilicalEngine"],
            path: "Tests/UmbilicalUITests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
