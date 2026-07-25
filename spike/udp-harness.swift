// UDP 端到端集成测试的 Mac 侧 harness：起真 LANServer（WS+UDP+NACK 全链路），
// 把应用到的 RT 帧逐行打到 stdout（`EV ...`），供 spike/udp-client-test.js 断言帧序。
// 不要直接跑——由 udp-client-test.js 编译并拉起。
import Foundation

/// stdout 被管道时是块缓冲，必须裸写保证 node 端实时读到。
func emit(_ s: String) {
    FileHandle.standardOutput.write(Data((s + "\n").utf8))
}

@main
struct UDPHarness {
    static func main() {
        let server = LANServer()
        server.onScroll = { page, frac, _ in
            emit("EV scroll page=\(page) frac=\(String(format: "%.3f", frac))")
        }
        server.onMessage = { obj in
            let type = obj["type"] as? String ?? "?"
            var line = "EV \(type)"
            if let ph = obj["phase"] as? String { line += " \(ph)" }
            if let page = obj["page"] as? NSNumber { line += " page=\(page.intValue)" }
            if let pts = obj["pts"] as? [Any] { line += " pts=\(pts.count)" }
            emit(line)
        }
        server.start()
        emit("READY ws=\(server.wsPort) udp=\(server.udpPort) token=\(server.token)")
        RunLoop.main.run()
    }
}
