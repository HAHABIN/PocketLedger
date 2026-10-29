// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "LedgerCore", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "LedgerCore", targets: ["LedgerCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3")],
    targets: [
        .target(name: "LedgerCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")], path: "Core"),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore", .product(name: "GRDB", package: "GRDB.swift")], path: "Tests")
    ])
