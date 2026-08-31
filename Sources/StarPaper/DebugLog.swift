import Foundation

/// 可开关的文件日志。
///
/// ## 为什么不用 NSLog
///
/// 2026-08-29 实测：项目里那 15 条 `NSLog` **从 `log show` 里一条都读不出来**
/// （`processImagePath CONTAINS`、`process ==`、全量 grep 三种方式都试过，全空）。
/// 而且它们全在异常分支上，正常运行时「谁在播、为什么停」没有任何记录 ——
/// 出了问题只能靠读代码猜，那天就猜错过一次。
///
/// 所以改成自己写文件：路径固定、随时能 `tail`、不依赖 unified logging 的过滤规则。
///
/// ## 怎么开
///
/// ```
/// defaults write com.starsdaisuki.starpaper debugLog -bool true   # 然后重启 app
/// STARPAPER_DEBUGLOG=1 open -n ~/Applications/StarPaper.app             # 或者只开这一次
/// tail -f ~/Library/Logs/StarPaper.log
/// ```
///
/// ⚠️ **默认关闭**，关闭时 `log()` 直接 return，不做字符串拼接（`@autoclosure` 保证
/// 参数根本不求值），所以在 `updatePlayback()` 这种每次遮挡通知都跑的热路径上放心用。
///
/// ⚠️ 沙盒（App Store）变体下 `~/Library/Logs` 会被重定向到容器内，
/// 路径变成 `~/Library/Containers/<bundleid>/Data/Library/Logs/StarPaper.log`。
enum DebugLog {

    /// 开关只在启动时读一次 —— 热路径上不能每次都去问 UserDefaults
    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["STARPAPER_DEBUGLOG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "debugLog")
    }()

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return dir.appendingPathComponent("StarPaper.log")
    }()

    private static let queue = DispatchQueue(label: "dev.stars.starpaper.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static var handle: FileHandle?

    /// - Parameter message: `@autoclosure` —— 关着的时候连字符串都不会拼。
    ///
    /// ⚠️ **不能加 `@escaping`**：加了之后调用点里的 `self.xxx` 全要写成显式 `self.`，
    /// 而且闭包会被 `queue.async` 持有。所以在调用线程先求值成 String 再入队 ——
    /// 关闭时不求值这个优化仍然成立，只是拼接发生在调用线程（几微秒）。
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        let stamp = formatter.string(from: Date())
        queue.async {
            let line = "\(stamp)  \(text)\n"
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil { handle = openFile() }
            try? handle?.write(contentsOf: data)
        }
    }

    private static func openFile() -> FileHandle? {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 每次启动清空重来 —— 要的是「这一次运行发生了什么」，
        // 不是攒一个越滚越大、还得自己做轮转的历史文件
        fm.createFile(atPath: fileURL.path, contents: nil)
        let h = try? FileHandle(forWritingTo: fileURL)
        let header = "=== StarPaper 调试日志 \(Date()) ===\n"
        if let d = header.data(using: .utf8) { try? h?.write(contentsOf: d) }
        return h
    }
}
