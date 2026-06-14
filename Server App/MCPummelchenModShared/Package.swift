// swift-tools-version: 6.2

import PackageDescription

#if os(macOS)
let defaultDuckDBLibraryDirectory = "/opt/homebrew/lib"
#else
let defaultDuckDBLibraryDirectory = "/usr/local/lib"
#endif
let duckDBLibraryDirectory = Context.environment["PUMMELCHEN_DUCKDB_LIB_DIR"] ?? defaultDuckDBLibraryDirectory

let package = Package(
    name: "MCPummelchenModShared",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "MCPummelchenModShared",
            targets: ["MCPummelchenModShared"]
        )
    ],
    targets: [
        .target(
            name: "MCPummelchenModShared",
            dependencies: ["CDuckDB"],
            linkerSettings: [
                .unsafeFlags(["-L", duckDBLibraryDirectory]),
                .linkedLibrary("duckdb")
            ]
        ),
        .target(
            name: "CDuckDB",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "MCPummelchenModSharedTests",
            dependencies: ["MCPummelchenModShared"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
