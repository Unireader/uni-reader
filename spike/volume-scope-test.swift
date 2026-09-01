// 「这个路径在不在那个卷上」（`VolumeScope`）。运行：
//   cp spike/volume-scope-test.swift /tmp/main.swift && swiftc Sources/Support/VolumeScope.swift /tmp/main.swift -o /tmp/vst && /tmp/vst
//
// 为什么这么小一个判断值得单独一份用例：卷要弹出时，我们按它把「开在这块盘上的工作区」
// 挑出来当场撤离（关连接、关窗口）。判错的后果是**用户弹一块盘，另一块盘上的窗口被莫名关掉**，
// 而且现场不留任何线索。裸 `hasPrefix` 就正好会犯这个错。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

print("① 命中")
check(VolumeScope.contains("/Volumes/备份/书/高数.unrd", volume: "/Volumes/备份"), "盘上的工作区")
check(VolumeScope.contains("/Volumes/备份", volume: "/Volumes/备份"), "卷根自己也算")
check(VolumeScope.contains("/Volumes/备份/", volume: "/Volumes/备份"), "尾斜杠不影响")
check(VolumeScope.contains("/Volumes/备份/x.unrd", volume: "/Volumes/备份/"), "卷带尾斜杠也一样")

print("② 不命中 —— 这几条正是裸 hasPrefix 会栽的地方")
check(!VolumeScope.contains("/Volumes/备份2/书.unrd", volume: "/Volumes/备份"),
      "🔴 同前缀的**另一块盘**不算（弹「备份」不该关掉「备份2」上的窗口）")
check(!VolumeScope.contains("/Volumes/备份-旧/书.unrd", volume: "/Volumes/备份"),
      "🔴 带后缀的另一块盘同理")
check(!VolumeScope.contains("/Users/x/书.unrd", volume: "/Volumes/备份"), "本机路径不算")
check(!VolumeScope.contains("/Volumes", volume: "/Volumes/备份"), "上级目录不算（比卷还短）")

print("③ 本机副本不该被任何外置卷牵连")
let mirror = "/Users/x/Library/Application Support/UniReader/Mirrors/高数.unrd"
check(!VolumeScope.contains(mirror, volume: "/Volumes/备份"),
      "🔴 副本在内置盘上 —— 弹源盘绝不能把副本也撤了，那就等于「拔盘即失明」")
check(VolumeScope.contains(mirror, volume: "/"), "但它确实在根卷上（判据本身没歪）")

print("④ 路径规整")
check(VolumeScope.contains("/Volumes/备份/./书.unrd", volume: "/Volumes/备份"), "./ 被规整掉")
check(VolumeScope.contains("/Volumes/备份/a/../书.unrd", volume: "/Volumes/备份"), "../ 被规整掉")
check(!VolumeScope.contains("/Volumes/备份/../别的/书.unrd", volume: "/Volumes/备份"),
      "🔴 用 ../ 爬出卷外的**不算**（规整之后才比，不是比字面）")

print("\n通过 \(pass) / 失败 \(fail)")
exit(fail == 0 ? 0 : 1)
