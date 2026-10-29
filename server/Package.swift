// swift-tools-version:6.0
import PackageDescription

// UniReader 服务器（`../SERVER-MODE-PLAN.md`，规则见 `AGENTS.md`）。
//
// `UniServerCore` 里有三个**符号链接**，指回 App 的源文件，与服务器自己的代码编成同一个模块：
//   Store                 -> ../../../Sources/Store                （工作区库：建表 / 迁移 / 指纹 / 三方判定 / 行写入）
//   Sync                  -> ../../../Sources/Sync                 （同步线格式 / 行工具 / 客户端算法）
//   BackupRetention.swift -> ../../../Sources/App/BackupRetention.swift（备份保留策略，纯函数）
// 不挪文件、不给 App 代码加 `public`：同一个模块里 internal 就够用（方案 §9）。
//
// 🔴 第三方包由用户执行 `swift package resolve` 拉取（项目规矩：不代用户安装依赖）。
let package = Package(
    name: "UniReaderServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "unireader-server", targets: ["unireader-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        // 只在 Linux 上用（macOS 有 CryptoKit）。上 Linux 时再接到目标上。
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(name: "UniServerCore", path: "Sources/UniServerCore"),
        .target(name: "UniServerHTTP", dependencies: [
            "UniServerCore",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ], path: "Sources/UniServerHTTP"),
        .executableTarget(name: "unireader-server", dependencies: [
            "UniServerCore", "UniServerHTTP",
            .product(name: "Hummingbird", package: "hummingbird"),
        ], path: "Sources/unireader-server"),
        .testTarget(name: "UniServerCoreTests", dependencies: ["UniServerCore"], path: "Tests/UniServerCoreTests"),
        .testTarget(name: "UniServerHTTPTests", dependencies: [
            "UniServerCore", "UniServerHTTP",
            .product(name: "HummingbirdTesting", package: "hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ], path: "Tests/UniServerHTTPTests"),
    ],
    swiftLanguageModes: [.v5]
)
