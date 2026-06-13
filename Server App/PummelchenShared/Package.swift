// swift-tools-version: 6.2

import PackageDescription

#if os(macOS)
let defaultDuckDBLibraryDirectory = "/opt/homebrew/lib"
#else
let defaultDuckDBLibraryDirectory = "/usr/local/lib"
#endif
let duckDBLibraryDirectory = Context.environment["PUMMELCHEN_DUCKDB_LIB_DIR"] ?? defaultDuckDBLibraryDirectory

let package = Package(
    name: "PummelchenShared",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "PummelchenCore",
            targets: ["PummelchenCore"]
        )
    ],
    targets: [
        .target(
            name: "PummelchenCore",
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
            name: "PummelchenCoreTests",
            dependencies: ["PummelchenCore"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
