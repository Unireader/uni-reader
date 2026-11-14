// swift-tools-version: 6.1
// 嵌入模型对比测试（SEARCH-PLAN.md §5）：用 MLX 在本机跑 Qwen3-Embedding / bge-m3，
// 对着真实搜索索引的块，用 spike/semantic-eval.swift 同一套问题比命中率、速度、内存。
// 准备：bash spike/embed-bench/setup.sh（拉依赖 + 从 hf-mirror 下模型，用户自己跑）
// 编译（MLX 的 Metal 着色器要 xcodebuild 编，swift build 不行）：
//   cd spike/embed-bench && xcodebuild -scheme EmbedBench -destination 'platform=macOS' \
//     -derivedDataPath ../../build/dev/embed-bench build
// 运行：见 run.sh
import PackageDescription

let package = Package(
    name: "EmbedBench",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "EmbedBench",
            dependencies: [
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageModes: [.v5]   // 一次性测试程序：顶层全局变量多，不跟 Swift 6 严格并发较劲
)
