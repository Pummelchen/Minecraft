// swift-tools-version: 6.2

import PackageDescription

var products: [Product] = [
    .library(
        name: "PummelchenClientCore",
        targets: ["PummelchenClientCore"]
    ),
    .executable(
        name: "pummelchen-client-sync",
        targets: ["PummelchenClientSync"]
    )
]

var targets: [Target] = [
    .target(
        name: "PummelchenClientCore",
        dependencies: [
            .product(name: "PummelchenCore", package: "PummelchenShared"),
            .product(name: "HTTP3", package: "Quiver"),
            .product(name: "QUIC", package: "Quiver"),
            .product(name: "QUICCore", package: "Quiver"),
            .product(name: "QUICCrypto", package: "Quiver")
        ]
    ),
    .executableTarget(
        name: "PummelchenClientSync",
        dependencies: ["PummelchenClientCore"]
    ),
    .testTarget(
        name: "PummelchenClientTests",
        dependencies: [
            "PummelchenClientCore",
            .product(name: "PummelchenCore", package: "PummelchenShared")
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
    name: "PummelchenClient",
    platforms: [
        .macOS(.v15)
    ],
    products: products,
    dependencies: [
        .package(path: "../../Server App/PummelchenShared"),
        .package(path: "../../Server App/Vendor/Quiver")
    ],
    targets: targets
)
