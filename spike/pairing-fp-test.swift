// 配对码指纹（Pairing.fingerprint）跨端向量——Bonjour 广播的 TXT `tk`（PROTOCOL.md §8）。
// 编译运行（项目根目录）：
//   swiftc spike/pairing-fp-test.swift Sources/Server/Pairing.swift -o /tmp/pfp && /tmp/pfp
// 安卓 `MacDiscoveryTest.fingerprintVectors` 是同两条，改算法两边一起改。
import Foundation

@main
struct PairingFingerprintTest {
    static func main() {
        var pass = 0, fail = 0
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want { pass += 1 } else { print("✗ \(name)：得到 \(got)，应为 \(want)"); fail += 1 }
        }
        check("向量 1", Pairing.fingerprint("0123456789abcdef0123456789abcdef"), "3eb1bd43")
        check("向量 2", Pairing.fingerprint("ffffffffffffffffffffffffffffffff"), "35230248")
        check("长度恒 8", String(Pairing.fingerprint(Pairing.makeToken()).count), "8")
        print("pairing-fp: \(pass) 通过 / \(fail) 失败")
        exit(fail == 0 ? 0 : 1)
    }
}
