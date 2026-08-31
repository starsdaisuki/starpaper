import AppKit

/// 「每个桌面一扇窗」所需要的最小私有 API 面。
///
/// ## 为什么需要它
///
/// 开着「辅助功能 → 显示 → 减弱动态效果」时用 `⌃←` / `⌃→` 横切桌面，
/// 目标桌面会先露出系统静态壁纸约 0.9 秒，视频才顶上来。
///
/// 实测把变量一个个钉死之后，根因只有一个 —— **`collectionBehavior`**：
///
/// | collectionBehavior | 切进去那 0.9 秒里，这扇窗 |
/// |---|---|
/// | `.managed`（每个桌面各一扇） | 全程被实时合成，露出 0.03 秒 |
/// | `.canJoinAllSpaces`（一扇窗跟着人跑） | 被换成系统静态壁纸 0.95 秒 |
///
/// 同一个二进制、同一个窗口层级、同一个桌面、同一次转换，只翻这一个标志位。
/// 已经排除的因素：窗口层级、重绘频率（画一次就不再画的窗口同样不露）、
/// `.stationary`、放置方式（直接建 / 私有 API 搬过去都一样）、离开时长（90 秒后仍不露）。
///
/// 顺带解释了两个老现象：只有「最后一个桌面」进出不露，是 sticky 窗口的通用例外，
/// 换成 `.managed` 之后所有桌面都不露，也就不需要那个例外了。
///
/// ## 为什么只能用私有 API
///
/// 公开 API 里没有「枚举桌面」，也没有「把窗口放到指定桌面」——
/// `NSWindow` 只能落在创建它的那一个桌面上。所以这两件事走 SkyLight 的私有符号。
///
/// 它们不需要关 SIP（在自己进程里 `dlsym` 不受限制），但**系统升级可能变**。
/// 所以这整块是可降级的：`isAvailable == false` 时调用方退回原来的单扇 sticky 窗口，
/// 行为和以前完全一致，只是那 0.9 秒会回来。
enum SpaceBridge {

    // MARK: - 数据

    struct Desktop {
        let id: UInt64
        let uuid: String
    }

    struct DisplayLayout {
        /// 显示器 UUID 字符串；单显示器时系统有时给的是 "Main"
        let displayIdentifier: String
        let currentSpaceID: UInt64
        /// 只含普通桌面（type == 0）。全屏 app 的桌面（type == 4）没有壁纸，不需要窗口。
        let desktops: [Desktop]
    }

    // MARK: - 符号

#if STARPAPER_APPSTORE
    /// Mac App Store 构建不能包含 SkyLight / CGS 私有 API，因此在编译期就整块裁掉。
    /// 这里不是“默认关闭”，而是让最终 Mach-O 里根本没有私有框架路径和符号名。
    static let isAvailable = false

    static func layout() -> [DisplayLayout] { [] }
    static func spaces(ofWindow windowNumber: Int) -> [UInt64] { [] }
    static func currentSpaceIsDesktop() -> Bool? { nil }

    @discardableResult
    static func move(windowNumber: Int, to spaceID: UInt64) -> Bool { false }
#else
    private typealias CID = UInt32
    private typealias MainConnectionFn = @convention(c) () -> CID
    private typealias CopyDisplaySpacesFn = @convention(c) (CID) -> Unmanaged<CFArray>?
    private typealias MoveWindowsFn = @convention(c) (CID, CFArray, UInt64) -> Void
    private typealias CopySpacesForWindowsFn = @convention(c) (CID, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static let mainConnectionID = sym("CGSMainConnectionID", MainConnectionFn.self)
    private static let copyDisplaySpaces = sym("CGSCopyManagedDisplaySpaces", CopyDisplaySpacesFn.self)
    private static let moveWindowsToSpace = sym("CGSMoveWindowsToManagedSpace", MoveWindowsFn.self)
    private static let copySpacesForWindows = sym("CGSCopySpacesForWindows", CopySpacesForWindowsFn.self)

    /// 四个符号缺任何一个都不启用 —— 宁可退回老行为，也不要半残状态
    static var isAvailable: Bool {
        mainConnectionID != nil && copyDisplaySpaces != nil
            && moveWindowsToSpace != nil && copySpacesForWindows != nil
    }

    private static var connection: CID? { mainConnectionID?() }

    // MARK: - 枚举

    /// 当前的显示器 / 桌面布局。取不到时返回空数组，调用方据此降级。
    static func layout() -> [DisplayLayout] {
        guard let cid = connection,
              let raw = copyDisplaySpaces?(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        return raw.compactMap { display in
            guard let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
            let identifier = (display["Display Identifier"] as? String) ?? ""
            let current = (display["Current Space"] as? [String: Any])?["id64"] as? Int ?? 0
            let desktops = spaces.compactMap { s -> Desktop? in
                guard (s["type"] as? Int) == 0, let id = s["id64"] as? Int else { return nil }
                return Desktop(id: UInt64(id), uuid: (s["uuid"] as? String) ?? "")
            }
            guard !desktops.isEmpty else { return nil }
            return DisplayLayout(
                displayIdentifier: identifier,
                currentSpaceID: UInt64(current),
                desktops: desktops
            )
        }
    }

    /// **当前激活的 Space 是不是「有壁纸的普通桌面」。**
    ///
    /// ⭐ 这是「该不该出声」的**唯一可靠判据**，2026-08-30 实测确立。
    ///
    /// 为什么不能用别的：
    ///
    /// - `occlusionState`：Space 转换一开始系统就把壁纸窗标成可见（**故意提前约 0.9 秒**，
    ///   画面需要这个提前量），所以「看得见」≠「人回到桌面了」。
    /// - 定时兜底（0.7s / 2s / 0.5s 都试过）：交互式手势可以悬停任意久，
    ///   **任何固定时长都会被跨过去**，只是把「响一下」推迟成「晚点响」。
    /// - 量前台窗尺寸（旧 `ForegroundCoverage`）：真实全屏窗**根本不等于屏幕尺寸** ——
    ///   实测同一台机器 Finder 1512×945、Ghostty 1512×907、Chrome 1512×857，屏幕是 1512×982。
    ///   带标题栏 / 标签栏的 app 会把那部分拆成独立窗口，主窗只剩下面那块。
    ///
    /// 而系统自己一直知道当前 Space 是什么类型（`type == 0` 才是普通桌面），
    /// 全屏 app 的 Space 是 `type == 4`，转换途中读到的仍是源或目标 Space 之一，
    /// **两个全屏 Space 之间无论怎么拖，都不会变成普通桌面**。
    ///
    /// - Returns: 取不到时返回 `nil`（调用方退回保守兜底），不要把 nil 当成 false。
    static func currentSpaceIsDesktop() -> Bool? {
        let displays = layout()
        guard !displays.isEmpty else { return nil }
        return displays.contains { display in
            display.desktops.contains { $0.id == display.currentSpaceID }
        }
    }

    /// 这扇窗现在属于哪些桌面（诊断 / 校验用）
    static func spaces(ofWindow windowNumber: Int) -> [UInt64] {
        guard let cid = connection, windowNumber > 0 else { return [] }
        let ids = [NSNumber(value: windowNumber)] as CFArray
        // mask 7 = 全部（当前 + 其它 + 用户）
        let got = copySpacesForWindows?(cid, 7, ids)?.takeRetainedValue() as? [Int]
        return (got ?? []).map(UInt64.init)
    }

    // MARK: - 放置

    /// 把窗口挪到指定桌面，并**回读校验**。
    ///
    /// 校验不是多余的：跨进程写窗口属性被静默拒绝是这套 API 的常见行为，
    /// 没有返回值可看。放不成功就得让调用方知道，否则会得到一扇看不见的窗。
    @discardableResult
    static func move(windowNumber: Int, to spaceID: UInt64) -> Bool {
        guard let cid = connection, let move = moveWindowsToSpace, windowNumber > 0
        else { return false }

        // 已经在目标桌面上就不用动（窗口就建在当前桌面时的常见情况）
        if spaces(ofWindow: windowNumber) == [spaceID] { return true }

        move(cid, [NSNumber(value: windowNumber)] as CFArray, spaceID)
        return spaces(ofWindow: windowNumber) == [spaceID]
    }
#endif

    // MARK: - 显示器对应关系

    /// `NSScreen` → 显示器 UUID 字符串，用来和 `layout()` 里的 `displayIdentifier` 对上。
    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuidRef) as String
    }

    /// 把 `layout()` 里的一条显示器记录对到具体 `NSScreen`。
    ///
    /// `displayIdentifier` 可能是 UUID，也可能是 "Main"（单显示器时系统就这么给）——
    /// 两种都要认，不然单屏用户直接落不到任何一块屏上。
    static func screen(for identifier: String, among screens: [NSScreen]) -> NSScreen? {
        if identifier.caseInsensitiveCompare("Main") == .orderedSame {
            return NSScreen.main ?? screens.first
        }
        if let hit = screens.first(where: { uuid(of: $0) == identifier }) {
            return hit
        }
        // 认不出来的显示器：只有一块屏时按它算，多屏时宁可放弃这条记录
        return screens.count == 1 ? screens.first : nil
    }
}
