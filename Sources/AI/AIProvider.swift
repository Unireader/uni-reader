import Foundation

/// 一个 AI 网页平台的接入描述。**不接 API key**——我们只是在内嵌 webview 里开这家的网页版。
///
/// 配置分两层（`AIPanelModel.loadProviders`）：
///  · **内置**：本文件的 `AIProvider.builtin`，随 app 走，默认就用它；
///  · **外部覆盖**：`~/Library/Application Support/UniReader/ai-providers.json`
///    （存在且能解出至少一项才生效）。站点改版时不用重编译发版就能救。
///
/// ⚠️ `threadPattern` 是 S2「对话绑定」用的会话 URL 正则。**内置那条 DeepSeek 已按真实 URL 核对**
/// （见下方注释）；将来任何新增/改动都必须拿真实会话 URL 对一遍——写错就是「绑定永远不 commit」
/// 这种查不出的静默失效（外部配置正是为此留的）。
/// 平台上那条「模式」分段控件的一档。DeepSeek 的新对话页在输入框上方摆着三档：
/// **快速模式 / 专家模式 / 识图模式**（输入框里那两枚「深度思考 / 智能搜索」是另一组开关，不归这里管）。
///
/// 🔴 `labels` 是**页面上的可见文字**——适配器只按可见文字认，**不猜 class 名**：class 每周都在变，
/// 可见文字变了用户一眼就看得出来，改外部配置即可。多给几条是为了站点改名/换语言时能一并覆盖，
/// 但匹配是**整段文字完全相等**，所以多余的候选不会误伤（宁可切不动，也不能瞎点）。
struct AIMode: Identifiable, Codable, Equatable {
    var id: String          // 稳定标识：fast / pro / vision
    var name: String        // 菜单里显示的名字（站点自己的专有名词，同 provider name，不进 Localizable）
    var labels: [String]    // 页面上那枚按钮的可见文字
}

struct AIProvider: Identifiable, Codable, Equatable {
    var id: String              // 稳定标识，同时是 UserDefaults / 外部配置的键
    var name: String            // 显示名（专有名词，不进 Localizable）
    var icon: String            // SF Symbol
    var colorKey: String        // 复用 `NoteType.palette` 的色板 key，未知回落 gray
    var home: String            // 首页 URL（新开一律落这里）
    var threadPattern: String   // 会话 URL 正则（S2 用）
    var adapter: String         // 发送适配器 id（S3 用）
    var userAgent: String?      // 整条 UA 覆盖；nil = 用面板的 Safari 默认（见 AIPanelModel）
    var dataDomains: [String]?  // 「清除登录数据」要一并清掉的域；nil = 只清 home 的域
    var note: String?           // 备注（如登录风险），显示在平台菜单的说明行
    var modes: [AIMode]?        // 「模式」分段控件的档位；nil/空 = 这家不做模式切换
    var modeForImage: String?   // **有图**时默认切到哪档（`AIMode.id`）
    var modeForText: String?    // **无图**（划字发送）时默认切到哪档

    enum CodingKeys: String, CodingKey {
        case id, name, icon, home, adapter, note, modes
        case colorKey = "color_key"
        case threadPattern = "thread_pattern"
        case userAgent = "user_agent"
        case dataDomains = "data_domains"
        case modeForImage = "mode_for_image"
        case modeForText = "mode_for_text"
    }

    /// 按 id 找一档模式。
    func mode(_ id: String) -> AIMode? { (modes ?? []).first { $0.id == id } }

    var homeURL: URL? { URL(string: home) }

    /// 主机名（清除数据、域匹配用）。
    var host: String { homeURL?.host() ?? "" }

    /// 要清除网站数据的域集合：显式配了就用配的，否则用 home 的主机名。
    var clearDomains: [String] {
        if let d = dataDomains, !d.isEmpty { return d }
        return host.isEmpty ? [] : [host]
    }

    /// 这条 URL 是不是本平台的**一次具体对话**（而不是首页/登录页/设置页）。
    /// 两段式绑定就靠它判定何时 commit（`AIPanelModel.syncFromPage`）；
    /// 放在模型上而不是面板里，是为了让 `spike/ai-thread-store-test.swift` 能直接测这条正则
    /// ——正则写错就是「绑定永远不 commit」这种查不出的静默失效，必须可自动化验证。
    func matchesThread(_ urlString: String) -> Bool {
        guard !urlString.isEmpty, !threadPattern.isEmpty else { return false }
        return urlString.range(of: threadPattern, options: .regularExpression) != nil
    }
}

extension AIProvider {
    /// 内置平台表。**2026-08-25 起只有 DeepSeek**——用户拍板「先只做 deepseek，我目前也只用 deepseek」，
    /// 于是 S2 的会话绑定与 S3 的发送适配器都只对它做，不摊薄在八家上。
    ///
    /// 想加别家：写外部配置 `~/Library/Application Support/UniReader/ai-providers.json`
    /// （面板「更多 → 在访达中显示配置文件…」会先把这份内置表导成模板）。
    /// 其余平台的 home / 会话 URL 形态**作为参考记在 `AI-PLAN.md §7`**，不留在代码里——
    /// 那些形态一条都没实测过，摆在这儿只会被当成「已支持」。
    static let builtin: [AIProvider] = [
        AIProvider(id: "deepseek", name: "DeepSeek", icon: "water.waves",
                   colorKey: "blue", home: "https://chat.deepseek.com/",
                   // ✅ 2026-08-25 用户实测核对：
                   //    首页 https://chat.deepseek.com/
                   //    会话 https://chat.deepseek.com/a/chat/s/66ecab55-6b60-4b56-8e92-39cb9e95c0e5
                   threadPattern: #"^https://chat\.deepseek\.com/a/chat/s/[0-9a-fA-F-]+"#,
                   adapter: "deepseek",
                   dataDomains: ["deepseek.com"],
                   // ✅ 2026-09-06 用户截图核对：新对话页输入框上方一条三段控件。
                   // **只填实际见过的中文可见文字**——英文界面的写法我没见过，猜一个塞进来
                   // 反而可能在别处误匹配（"Pro" 这种短词到处都是）。换语言就改外部配置。
                   modes: [AIMode(id: "fast", name: "快速模式", labels: ["快速模式"]),
                           AIMode(id: "pro", name: "专家模式", labels: ["专家模式"]),
                           AIMode(id: "vision", name: "识图模式", labels: ["识图模式"])],
                   modeForImage: "vision",     // 有图 → 识图模式（用户定）
                   modeForText: "pro"),        // 无图 → 专家模式（用户定）
    ]

    /// 整条 Safari UA。面板默认走 `applicationNameForUserAgent`（见 `AIPanelModel`）拼出等价串，
    /// 这里这条整覆盖只留给需要更彻底伪装的站点（如 Google 系）。
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"
}
