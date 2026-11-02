// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "inkpane-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InkpaneKit", targets: ["InkpaneKit"]),
        // The MCP server itself, so an app can build and embed its own copy of the executable
        // (the Inkpane app compiles `Sources/inkpane-mcp/main.swift` against it).
        .library(name: "InkpaneMCP", targets: ["InkpaneMCP"]),
        .executable(name: "inkpane-mcp", targets: ["inkpane-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        // Screen capture, OCR and window enumeration. No MCP dependency.
        .target(name: "InkpaneKit"),
        // MCP tool/resource definitions and handlers on top of InkpaneKit.
        .target(
            name: "InkpaneMCP",
            dependencies: [
                "InkpaneKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "inkpane-mcp",
            dependencies: ["InkpaneMCP"]
        ),
        .testTarget(
            name: "InkpaneKitTests",
            dependencies: ["InkpaneKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "InkpaneMCPTests",
            dependencies: [
                "InkpaneMCP",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
