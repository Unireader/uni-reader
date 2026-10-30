import Foundation
import PackagePlugin

/// 构建插件：把网页阅读器的构建产物（`web/dist`，`scripts/build-web.sh` 出）编进服务器程序，部署照旧是单个文件
/// （方案 `WEB-READER-PLAN.md §2`）。没有 `web/dist` 也能编，只是程序里不带网页（`GET /` 回一句说明）。
///
/// 🔴 输入只登记 `web/dist/index.html` 一个文件，**别把 dist 里的文件逐个列成输入**：
/// SwiftPM（Linux 交叉编译用的 6.2.3）在各目标的源文件清单没变时沿用上次的构建计划、不重新运行本插件，
/// 逐个列的话清单还是上次的文件名，网页重新构建后（文件名里带内容哈希，全换了）报「missing inputs」（2026-10-30 踩到）。
/// index.html 每次构建都重写（脚本、样式的文件名都在里面），用它判断「网页变了」就够；生成器运行时自己读整个目录。
/// 没有 dist 时没有输入，命令只在生成文件不存在时运行——所以 `build-web.sh` 构建完会删掉生成文件，下次编译必定重新生成。
@main
struct EmbedWebAssets: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let dist = context.package.directoryURL.appending(path: "web/dist")
        let out = context.pluginWorkDirectoryURL.appending(path: "EmbeddedWeb.swift")
        let index = dist.appending(path: "index.html")
        let inputs = FileManager.default.fileExists(atPath: index.path) ? [index] : []
        return [.buildCommand(displayName: "Embedding web reader",
                              executable: try context.tool(named: "web-embed").url,
                              arguments: [dist.path, out.path],
                              inputFiles: inputs, outputFiles: [out])]
    }
}
