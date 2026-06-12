// swift-tools-version: 6.2

import PackageDescription

var products: [Product] = [
    .library(
        name: "PummelchenCore",
        targets: ["PummelchenCore"]
    ),
    .library(
        name: "PummelchenClientCore",
        targets: ["PummelchenClientCore"]
    ),
    .executable(
        name: "pummelchen-contracts",
        targets: ["pummelchen-contracts"]
    ),
    .executable(
        name: "pummelchen-duckdb",
        targets: ["PummelchenDuckDB"]
    ),
    .executable(
        name: "pummelchen-server",
        targets: ["PummelchenServer"]
    ),
    .executable(
        name: "pummelchen-client-sync",
        targets: ["PummelchenClientSync"]
    )
]

var targets: [Target] = [
    .target(
        name: "PummelchenCore"
    ),
    .target(
        name: "PummelchenServerCore",
        dependencies: ["PummelchenCore"]
    ),
    .target(
        name: "PummelchenClientCore",
        dependencies: ["PummelchenCore"]
    ),
    .executableTarget(
        name: "pummelchen-contracts",
        dependencies: ["PummelchenCore"]
    ),
    .executableTarget(
        name: "PummelchenDuckDB",
        dependencies: ["PummelchenCore"]
    ),
    .executableTarget(
        name: "PummelchenServer",
        dependencies: ["PummelchenServerCore"]
    ),
    .executableTarget(
        name: "PummelchenClientSync",
        dependencies: ["PummelchenClientCore"]
    ),
    .testTarget(
        name: "PummelchenCoreTests",
        dependencies: [
            "PummelchenCore",
            "PummelchenClientCore",
            "PummelchenServerCore"
        ],
        resources: [
            .copy("Fixtures")
        ]
    )
]

#if os(macOS)
products.append(
    .executable(
        name: "PummelchenClient",
        targets: ["PummelchenClient"]
    )
)
targets.append(
    .executableTarget(
        name: "PummelchenClient",
        dependencies: ["PummelchenClientCore"]
    )
)
#endif

let package = Package(
    name: "PummelchenSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)
