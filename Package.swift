// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mdx2dict",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CXML2",
            path: "Sources/CXML2",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("xml2")]
        ),
        .executableTarget(
            name: "mdx2dict",
            dependencies: ["CXML2"],
            path: "Sources/mdx2dict"
        ),
        .testTarget(
            name: "mdx2dictTests",
            dependencies: ["mdx2dict"],
            path: "Tests/mdx2dictTests"
        )
    ]
)
