// udp-client-test.js 的 LANServer 依赖桩（仅 harness 编译用，勿进 App target）：
// 真实 Pairing/NetInfo/CapturePage 依赖 AppKit/Bundle 资源，spike 里换成确定性最小实现。
import Foundation

enum Pairing {
    static func makeToken() -> String { "testtoken" }   // 确定性 token，node 端写死同款
    // 真实实现存 UserDefaults（面板可「重置配对码」）；harness 里要的是确定性，不落盘。
    static func persistentToken() -> String { makeToken() }
    static func resetToken() -> String { makeToken() }
}

enum NetInfo {
    static func wifiIPv4() -> String? { nil }
}

enum CapturePage {
    static func html(token: String, wsPort: UInt16) -> String { "" }
}
