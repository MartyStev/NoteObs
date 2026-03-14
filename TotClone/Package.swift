// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TotClone",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "TotClone",
            path: "TotClone",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "TotCloneTests",
            dependencies: ["TotClone"]
        )
    ]
)
