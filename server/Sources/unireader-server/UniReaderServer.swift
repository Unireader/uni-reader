import Foundation
import Hummingbird
import UniServerCore
import UniServerHTTP

/// 命令行入口。
///
/// ```
/// unireader-server [serve] [--data <目录>] [--host 127.0.0.1] [--port 8790] [--name <名字>] [--no-discovery]
///                          [--web-dir <目录>]   网页阅读器读这个目录（开发用；默认用编在程序里的那份）
///                          [--no-access-log]    不记请求耗时日志（默认记，`AccessLog.swift`）
/// unireader-server --version           只打印版本号
/// unireader-server pairing-code        显示配对码
/// unireader-server reset-pairing-code  换一个配对码（已配对的设备不受影响）
/// unireader-server devices             列出设备
/// unireader-server revoke <设备 id>    吊销一台设备
/// unireader-server deleted             列出回收站里被删的工作区（App 里「从服务器删除」的，留 90 天）
/// unireader-server restore <工作区 id> 把最近一次删掉的它放回来
/// ```
/// 默认只听本机（127.0.0.1）：服务全程是明文 HTTP，对外要么放在反向代理（负责 HTTPS）后面，
/// 要么只在 Tailscale 里用 `--host 0.0.0.0`。
/// 监听非本机地址时在局域网广播（Bonjour `_unireader-srv._tcp`，方案 §3.7），`--no-discovery` 关掉。
@main
struct UniReaderServerMain {
    static func main() async throws {
        // 标准输出重定向到日志文件时默认整块缓冲：启动信息（含配对码）可能一直不出现。改成按行写出。
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        var dataDir = ServerPaths.defaultRoot
        var host = "127.0.0.1"
        var port = 8790
        var name = defaultName
        var discovery = true
        var webDir: URL?
        var accessLog = true
        var renderCacheMB = 2048
        var positional: [String] = []
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--data": dataDir = URL(fileURLWithPath: try value(&args, a), isDirectory: true)
            case "--host": host = try value(&args, a)
            case "--port":
                guard let p = Int(try value(&args, a)), (1...65535).contains(p) else { fail("--port 要一个端口号") }
                port = p
            case "--name": name = try value(&args, a)
            case "--no-discovery": discovery = false
            case "--web-dir": webDir = URL(fileURLWithPath: try value(&args, a), isDirectory: true)
            case "--no-access-log": accessLog = false
            case "--render-cache-mb":
                guard let v = Int(try value(&args, a)), v > 0 else { fail("--render-cache-mb 要一个正整数（MB）") }
                renderCacheMB = v
            case "-h", "--help": usage(); return
            case "--version": print(ServerInfo.version); return   // 只打印版本号（发布脚本 / CI 冒烟测试、换程序后核对用）
            default: positional.append(a)
            }
        }

        let paths = ServerPaths(root: dataDir)
        let store = try ServerStore(paths: paths)
        switch positional.first ?? "serve" {
        case "serve":
            let workspaces = try WorkspaceHost(paths: paths)
            let web = WebFiles(directory: webDir)
            let images = PageImages(root: paths.renderCache, limitBytes: Int64(renderCacheMB) * 1_048_576)
            print("""
            UniReader 服务器 \(ServerInfo.version)（数据版本 \(ServerInfo.schemaVersion)）
              数据目录：\(dataDir.path)
              监听：    http://\(host):\(port)
              配对码：  \(try store.pairingCode())
              名字：    \(name)
              工作区：  \(workspaces.list().count) 个
              网页：    \(web.sourceDescription)
              请求日志：\(accessLog ? "记（每个 /v1 请求一行耗时；关掉用 --no-access-log）" : "不记")
              服务器出图：\(images.summary)
            """)
            let loopback = ["127.0.0.1", "localhost", "::1"].contains(host)
            if !loopback {
                print("  ⚠️ 正在监听非本机地址，全程明文 HTTP：只在可信网络（如 Tailscale）里这样用，公网请放在 HTTPS 反向代理后面。")
            }
            // 局域网发现：只听本机时广播出去别人也连不上，不广播
            let advertiser = DiscoveryAdvertiser()
            if discovery && !loopback {
                let ok = advertiser.start(name: name, port: port, serverId: try store.serverId(),
                                          version: ServerInfo.version, schema: ServerInfo.schemaVersion)
                print(ok ? "  局域网发现：已广播（\(DiscoveryAdvertiser.serviceType)）"
                         : "  局域网发现：没能广播（本机不支持或注册失败），客户端照样可以手填地址")
            } else if discovery {
                print("  局域网发现：只听本机，不广播（要让别的设备发现它，加 --host 0.0.0.0）")
            }
            // 定时备份：启动时每个工作区备份一次，之后每小时把有改动的再备份一次；顺带清掉 7 天没动的上传残留
            Task.detached {
                while !Task.isCancelled {
                    workspaces.backupChanged()
                    workspaces.pruneUploads()
                    workspaces.pruneDeleted()
                    images.prune()
                    try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                }
            }
            let app = UniServerApp.application(host: workspaces, store: store, name: name, web: web,
                                               accessLog: accessLog, images: images, address: .hostname(host, port: port))
            try await app.runService()
            advertiser.stop()
            workspaces.closeAll()
        case "render":
            // 调试：直接用出图那套代码画一个 PDF 的某一页，看工具能不能用、要多久（临时目录，跑完删掉）
            guard positional.count >= 2 else { fail("用法：unireader-server render <PDF 文件> [页，从 1 起] [宽]") }
            let pdf = URL(fileURLWithPath: positional[1])
            let pageNo = positional.count > 2 ? Int(positional[2]) ?? 1 : 1
            let width = positional.count > 3 ? Int(positional[3]) ?? 1280 : 1280
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("unireader-render-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let images = PageImages(root: tmp, limitBytes: 1 << 30)
            print("出图：\(images.summary)")
            var t = Date()
            let info = try images.info(hash: "probe", pdf: pdf)
            let pages = try images.pageSizes(hash: "probe", pdf: pdf)
            print("页面尺寸与目录：\(pages.count) 页，JSON \(info.count) 字节，\(Int(Date().timeIntervalSince(t) * 1000))ms")
            if pages.indices.contains(pageNo - 1) {
                let p = pages[pageNo - 1]
                let scan = p.count > 2 && p[2] > 0 ? "扫描图约 \(Int(p[2])) 像素宽" : "不是扫描页（不限宽度）"
                print("第 \(pageNo) 页：\(Int(p[0])) × \(Int(p[1])) pt，\(scan)")
            } else {
                print("第 \(pageNo) 页：没有这一页")
            }
            t = Date()
            let out = try images.page(hash: "probe", pdf: pdf, index: pageNo - 1, width: width)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? 0
            print("画第 \(pageNo) 页（\(out.lastPathComponent)）：\(bytes) 字节，\(Int(Date().timeIntervalSince(t) * 1000))ms")
        case "pairing-code":
            print(try store.pairingCode())
        case "reset-pairing-code":
            print(try store.resetPairingCode())
        case "devices":
            for d in try store.devices() {
                print("\(d.id)  \(d.name)  配对于 \(d.createdAt)  最近 \(d.lastSeenAt ?? "—")\(d.revoked ? "  已吊销" : "")")
            }
        case "revoke":
            guard positional.count == 2 else { fail("用法：unireader-server revoke <设备 id>") }
            try store.revoke(deviceId: positional[1])
            print("已吊销 \(positional[1])")
        case "deleted":
            let list = try WorkspaceHost(paths: paths).deletedWorkspaces()
            if list.isEmpty { print("回收站里没有被删的工作区") }
            for d in list {
                print("\(d.id)  \(d.name.isEmpty ? "（未命名）" : d.name)  删于 \(d.deletedAt)  设备 \(d.device.isEmpty ? "—" : d.device)")
            }
        case "restore":
            guard positional.count == 2 else { fail("用法：unireader-server restore <工作区 id>") }
            let d = try WorkspaceHost(paths: paths).restoreDeleted(positional[1])
            print("已放回「\(d.name)」（\(d.id)）。服务器在跑的话不用重启，App 里刷新工作区列表就能看到")
        default:
            usage()
            exit(2)
        }
        store.close()
    }

    /// 默认的服务器名字（局域网发现里显示的那个）。
    static var defaultName: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    static func value(_ args: inout [String], _ flag: String) throws -> String {
        guard !args.isEmpty else { fail("\(flag) 后面要跟一个值") }
        return args.removeFirst()
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }

    static func usage() {
        print("""
        用法：
          unireader-server [serve] [--data <目录>] [--host 127.0.0.1] [--port 8790] [--name <名字>] [--no-discovery]
                           [--web-dir <目录>]（网页阅读器读这个目录，开发用）
                           [--no-access-log]（不记请求耗时日志；默认每个 /v1 请求一行，网页查修订号不记）
                           [--render-cache-mb 2048]（服务器出图的缓存上限）
          unireader-server render <PDF 文件> [页] [宽]（调试：试画一页，看出图工具能不能用、要多久）
          unireader-server pairing-code | reset-pairing-code | devices | revoke <设备 id>
          unireader-server deleted | restore <工作区 id>
          unireader-server --version（只打印版本号）
        默认数据目录：\(ServerPaths.defaultRoot.path)
        """)
    }
}
