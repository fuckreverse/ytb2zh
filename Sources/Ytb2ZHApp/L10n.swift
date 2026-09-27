import SwiftUI

// MARK: - i18n 基础设施
//
// 方案：SwiftUI 字面量即 key（开发语言 = zh-Hans，key 本身就是中文文案），
// 翻译表随 .app 打包进 Contents/Resources/<lang>.lproj/Localizable.strings
// （由 Makefile bundle 目标拷贝，Support/<lang>.lproj 是仓库内源文件）。
//
//  - 字面量上下文（Text("播放") / Button("关闭") / .help("…") / Section("…")
//    / TextField("…") / navigationTitle("…") / LabeledContent / GroupBox /
//    Toggle / Picker label）：SwiftUI 自动按 LocalizedStringKey 查主 bundle 表，
//    插值自动转 %lld / %@ 格式符，无需改代码。
//  - 动态上下文（变量传入 Text/Label、enum label、String 拼接进度文案）：
//    用 L() 包成 LocalizedStringKey，或 L10n.tr() 直接取译文 String。
//  - 语言切换：写 UserDefaults "AppleLanguages"（跟随系统时移除该键），
//    重启后生效（L10n.relaunch()）。

/// 把动态 String 变成可本地化的 LocalizedStringKey（查主 bundle 的 Localizable 表）。
/// 表中无此 key 时 SwiftUI 原样显示 key（即中文），与无 i18n 时行为一致。
func L(_ key: String) -> LocalizedStringKey { LocalizedStringKey(key) }

enum L10n {
    /// 动态 String 上下文取译文（进度文案 / 日志 / 计数单位等）。
    /// 无参数时直接返回译文（查不到返回 key 本身）。
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let fmt = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        return args.isEmpty ? fmt : String(format: fmt, locale: Locale.current, arguments: args)
    }

    /// 界面语言偏好存储键（UserDefaults AppleLanguages，数组）
    static let languageKey = "AppleLanguages"

    /// 当前语言设置："system"（跟随系统）/ "zh-Hans" / "en"
    static var currentLanguage: String {
        guard let list = UserDefaults.standard.stringArray(forKey: languageKey),
              let first = list.first else { return "system" }
        return first
    }

    /// 设置界面语言；跟随系统时移除覆盖。
    /// 返回设置后进程实际生效语言是否已变化（变化才需要重启）。
    @discardableResult
    static func setLanguage(_ lang: String) -> Bool {
        let before = effectiveLanguage
        if lang == "system" {
            UserDefaults.standard.removeObject(forKey: languageKey)
        } else {
            UserDefaults.standard.set([lang], forKey: languageKey)
        }
        return effectiveLanguage != before
    }

    /// 设置后进程实际生效的语言（Bundle 首选本地化）
    static var effectiveLanguage: String {
        Bundle.preferredLocalizations(from: ["zh-Hans", "en"]).first ?? "zh-Hans"
    }

    /// 当前是否英文界面（数字单位等无法用格式串表达的场景用）
    static var isEnglish: Bool { effectiveLanguage == "en" }

    /// 以新语言重启 app（替换当前进程，供语言切换后立即生效）
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [bundle.path]
            try? p.run()
        } else if let exe = Bundle.main.executableURL {
            let p = Process()
            p.executableURL = exe
            p.arguments = []
            try? p.run()
        }
        exit(0)
    }
}
