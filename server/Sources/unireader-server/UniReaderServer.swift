import Foundation
import Hummingbird
import UniServerCore
import UniServerHTTP

/// 命令行入口。
///
/// ```
/// unireader-server [serve] [--data <目录>] [--host 127.0.0.1] [--port 8790]
/// unireader-server pairing-code        显示配对码
/// unireader-server reset-pairing-code  换一个配对码（已配对的设备不受影响）
/// unireader-server devices             列出设备
/// unireader-server revoke <设备 id>    吊销一台设备
/// ```
/// 默认只听本机（127.0.0.1）：服务全程是明文 HTTP，对外要么放在反向代理（负责 HTTPS）后面，
/// 要么只在 Tailscale 里用 `--host 0.0.0.0`。
@main
struct UniReaderServerMain {
    static func main() async throws {
        // 标准输出重定向到日志文件时默认整块缓冲：启动信息（含配对码）可能一直不出现。改成按行写出。
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        var dataDir = ServerPaths.defaultRoot
        var host = "127.0.0.1"
        var port = 8790
        var positional: [String] = []
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--data": dataDir = URL(fileURLWithPath: try value(&args, a), isDirectory: true)
            case "--host": host = try value(&args, a)
            case "--port":
                guard let p = Int(try value(&args, a)), (1...65535).contains(p) else { fail("--port 要一个端口号") }
                port = p
            case "-h", "--help": usage(); return
            default: positional.append(a)
            }
        }

        let paths = ServerPaths(root: dataDir)
        let store = try ServerStore(paths: paths)
        switch positional.first ?? "serve" {
        case "serve":
            let workspaces = try WorkspaceHost(paths: paths)
            print("""
            UniReader 服务器 \(ServerInfo.version)（数据版本 \(ServerInfo.schemaVersion)）
              数据目录：\(dataDir.path)
              监听：    http://\(host):\(port)
              配对码：  \(try store.pairingCode())
              工作区：  \(workspaces.list().count) 个
            """)
            if host != "127.0.0.1" && host != "localhost" {
                print("  ⚠️ 正在监听非本机地址，全程明文 HTTP：只在可信网络（如 Tailscale）里这样用，公网请放在 HTTPS 反向代理后面。")
            }
            // 定时备份：启动时每个工作区备份一次，之后每小时把有改动的再备份一次；顺带清掉 7 天没动的上传残留
            Task.detached {
                while !Task.isCancelled {
                    workspaces.backupChanged()
                    workspaces.pruneUploads()
                    try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
                }
            }
            let app = UniServerApp.application(host: workspaces, store: store, address: .hostname(host, port: port))
            try await app.runService()
            workspaces.closeAll()
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
        default:
            usage()
            exit(2)
        }
        store.close()
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
          unireader-server [serve] [--data <目录>] [--host 127.0.0.1] [--port 8790]
          unireader-server pairing-code | reset-pairing-code | devices | revoke <设备 id>
        默认数据目录：\(ServerPaths.defaultRoot.path)
        """)
    }
}
