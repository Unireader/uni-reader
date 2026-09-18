import Foundation
import Combine
import Sparkle

/// Sparkle 2 的 SwiftUI-friendly 薄封装（参考同作者 Perch 项目的 `UpdaterService`，简化版）。
/// 整条更新流程（拉 appcast、EdDSA 校验、下载、out-of-process 安装、重启）全交给
/// `SPUStandardUpdaterController` 跑 Sparkle 自己的标准 UI——UniReader 是常规窗口 App
/// （非 Perch 那种 `LSUIElement` 菜单栏 App），不需要 Perch 那套「后台发现更新先压住、
/// 菜单栏角标提示、用户点了才弹」的 gentle-reminder 自定义 delegate：后台静默检查、
/// 真有更新才弹 Sparkle 自己的标准更新窗口，本身就是「macOS 规范」的默认行为。
///
/// 这层封装只负责：
/// 1. controller 的生命周期（单例，App 启动到退出一直活着）。
/// 2. KVO 把 `canCheckForUpdates` / `lastUpdateCheckDate` / `updateCheckInterval` 镜像到
///    `@Published` 属性，Settings › General 的「更新」区块能跟着自动刷新。
///
/// **不在 main thread 之外用**。`SPUStandardUpdaterController` 内部假设主线程驱动，跨线程会 deadlock。
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"

    let currentBuild: String =
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"

    /// 镜像 `controller.updater.canCheckForUpdates`。「立即检查」按钮拿这个禁用/启用
    /// （检查进行中时变成 false）。
    @Published private(set) var canCheck: Bool = true

    /// 镜像 `controller.updater.lastUpdateCheckDate`。
    @Published private(set) var lastChecked: Date?

    /// 镜像 `controller.updater.updateCheckInterval`（秒）。设置页的频率选择器读它显示当前选项。
    @Published private(set) var checkInterval: TimeInterval = 86400

    /// 底层 controller。设置页直接通过它调 `checkForUpdates(_:)`，Sparkle 会显示自带的
    /// "checking..." / "up to date" / "update available" 三态 UI。
    let controller: SPUStandardUpdaterController

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        canCheck = updater.canCheckForUpdates
        lastChecked = updater.lastUpdateCheckDate
        checkInterval = updater.updateCheckInterval

        // Sparkle 把这几个属性标了 KVO-compliant，镜像到 @Published 让 SwiftUI Form 订阅得上。
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastChecked = $0 }
            .store(in: &cancellables)
        updater.publisher(for: \.updateCheckInterval)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.checkInterval = $0 }
            .store(in: &cancellables)
    }

    /// 是否启用自动检查。Sparkle 自己把这个值持久化到它的 defaults domain，这里不另存一份。
    var autoCheck: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 定期检查间隔（秒）。同样由 Sparkle 自己持久化，改了之后它自动重排下一次检查。
    /// 下限 1 小时，低于会被 Sparkle 夹住。
    func setUpdateInterval(_ seconds: TimeInterval) {
        controller.updater.updateCheckInterval = seconds
    }

    /// 用户点「检查更新…」菜单项或设置页「立即检查」。Sparkle 全程接管 UI，包括「已是最新」提示。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
