import Foundation

/// 轻量本地化 helper —— UI 文案一律走它，禁止硬编码字符串字面量。
/// key 用英文原文本身，翻译放在各 `*.lproj/Localizable.strings`。
@inline(__always)
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
