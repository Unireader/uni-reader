import AppKit

// 🔴 **本 app 的入口是 AppKit，不是 SwiftUI 的 `App`/`Scene`**（2026-09-01 迁移，
// 方案见 `APPKIT-WINDOW-PLAN.md`）。一句话理由：窗口的生命周期、身份、菜单、工具栏必须归我们，
// 否则就是「SwiftUI 凭空开空窗 / onDisappear 空放 / ⌘W 抢不过菜单 / 工具栏开关被反复拍回」
// 那一串账（方案 §1 有完整账本）。**内容仍然全是 SwiftUI**，装在 NSHostingController 里。
//
// ⚠️ 两处细节：
// ① 顶层代码只允许写在 `main.swift`，且它与 `@main` 互斥——所以 `AppDelegate` 上没有
//    `@NSApplicationDelegateAdaptor`，是这里手工装的；
// ② **delegate 必须由全局变量强持有**（`NSApplication.delegate` 是 weak），放进闭包里当场就没了。
// ③ 顶层是 nonisolated 而 AppKit 全是 `@MainActor`，故用 `assumeIsolated` —— 这里本来就是主线程。
let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = appDelegate
    app.setActivationPolicy(.regular)
    app.run()
}
