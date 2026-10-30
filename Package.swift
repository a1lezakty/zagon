// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "zagon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZagonCore", targets: ["ZagonCore"]),
        .executable(name: "zagon", targets: ["zagon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CSQLite", cSettings: [
            .define("SQLITE_ENABLE_FTS5"), .define("SQLITE_THREADSAFE", to: "2"),
            .define("SQLITE_OMIT_LOAD_EXTENSION"), .define("SQLITE_DQS", to: "0"),
            .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"), .define("SQLITE_OMIT_DEPRECATED"),
            .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
        ]),
        .target(name: "CSys"),
        // zstd 1.5.7 single file (see the header of zstd.c); levels above 6 are not used, so the binary-tree
        // compressors are left out.
        .target(name: "CZstd", exclude: ["LICENSE"], cSettings: [
            .define("ZSTD_EXCLUDE_BTLAZY2_BLOCK_COMPRESSOR"), .define("ZSTD_EXCLUDE_BTOPT_BLOCK_COMPRESSOR"),
            .define("ZSTD_EXCLUDE_BTULTRA_BLOCK_COMPRESSOR"),
        ]),
        .target(name: "ZagonCore", dependencies: ["CSQLite", "CSys", "CZstd"]),
        .executableTarget(name: "zagon", dependencies: [
            "ZagonCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "ZagonCoreTests", dependencies: ["ZagonCore", "CSQLite"], resources: [.copy("Fixtures")]),
    ]
)
