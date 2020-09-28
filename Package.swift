// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "watchanalyze",
    platforms: [.macOS("10.15")],   // or any Linux supporting Swift 5.2 or newer
    products: [
        .executable(name: "watchanalyze", targets: ["watchanalyze"])
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/NobodyNada/mysql-nio", .branch("master")),
        .package(url: "https://github.com/apple/swift-se-0282-experimental", .branch("master")) // Atomics API
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "watchanalyze",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "SE0282_Experimental", package: "swift-se-0282-experimental")
            ]),
    ]
)
