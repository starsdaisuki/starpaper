import Foundation
import AppKit
import IOKit.ps

/// 电源 / 锁屏 / 睡眠状态监控。
///
/// 这个模块存在的唯一理由：**别让壁纸在你看不见的时候继续烧电发热**。
/// 遮挡检测在 WallpaperEngine 里（那是逐窗口的），这里管全局状态。
final class PowerMonitor {

    private(set) var onBattery = false
    private(set) var lowPowerMode = false
    private(set) var systemAsleep = false
    private(set) var displayAsleep = false

    private(set) var lockState = LockState()

    /// 「屏幕前不是你」的两个独立来源。
    ///
    /// ⚠️ **必须分开存再取并集，不能都往同一个 Bool 上写。** 锁着屏的时候被切到别的用户、
    /// 再切回来，系统会发一条 `sessionDidBecomeActive`；如果它直接把同一个 Bool 清零，
    /// 屏幕明明还锁着，壁纸就又开始烧电了。抽成 struct 是为了让 SelfTest 能跑这些事件序列。
    struct LockState: Equatable {
        /// 屏幕真的锁了（Ctrl+Cmd+Q / 屏保加锁）
        var screenIsLocked = false
        /// 会话被切走了（快速用户切换 / 切到登录窗）
        var sessionInactive = false

        var isLocked: Bool { screenIsLocked || sessionInactive }

        enum Event { case screenLocked, screenUnlocked, sessionResigned, sessionActivated }

        mutating func apply(_ event: Event) {
            switch event {
            case .screenLocked:     screenIsLocked = true
            case .screenUnlocked:   screenIsLocked = false
            case .sessionResigned:  sessionInactive = true
            case .sessionActivated: sessionInactive = false
            }
        }
    }

    var screenLocked: Bool { lockState.isLocked }

    /// 任意一项变化时回调，让引擎重新算该不该播
    var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init() {
        refreshPowerSource()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        installPowerSourceWatcher()
        installNotifications()
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        let ws = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { ws.removeObserver(observer) }
        for observer in localObservers { NotificationCenter.default.removeObserver(observer) }
        let dnc = DistributedNotificationCenter.default()
        for observer in distributedObservers { dnc.removeObserver(observer) }
    }

    // MARK: - 电源

    private func refreshPowerSource() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            onBattery = false
            return
        }
        let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeRetainedValue() as String?
        onBattery = (type == kIOPSBatteryPowerValue)
    }

    /// IOKit 的电源状态变化直接挂到 main runloop，不用轮询
    private func installPowerSourceWatcher() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.refreshPowerSource()
            monitor.onChange?()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    // MARK: - 睡眠 / 锁屏

    private func installNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemAsleep = true
            self?.onChange?()
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.systemAsleep = false
            self?.onChange?()
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.displayAsleep = true
            self?.onChange?()
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.displayAsleep = false
            self?.onChange?()
        })

        // ⚠️ 会话通知**不能**代替锁屏通知：sessionDidResignActive 是「快速用户切换 /
        // 切到登录窗」，锁屏时会话并没有离开 console，所以它根本不会发。
        // 只留会话通知的话，界面上「锁屏时暂停」这个开关就是死的 —— 只能等显示器睡着
        // 才停得下来。两个都收，各记各的，见 `screenLocked`。
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lockState.apply(.sessionResigned)
            self?.onChange?()
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lockState.apply(.sessionActivated)
            self?.onChange?()
        })

        // com.apple.screenIsLocked / Unlocked 是未文档化的通知名，但 `DistributedNotificationCenter`
        // 本身是公开 API，只是**监听**一个字符串，不涉及私有符号，沙盒和审核都不拦。
        // 目前没有公开替代品：CGSessionCopyCurrentDictionary 的 kCGSSessionScreenIsLocked
        // 只能轮询，拿不到事件。
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.lockState.apply(.screenLocked)
            self?.onChange?()
        })
        distributedObservers.append(dnc.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.lockState.apply(.screenUnlocked)
            self?.onChange?()
        })

        localObservers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.onChange?()
        })
    }

    /// 按当前设置判断：全局层面该不该让壁纸播
    func shouldPlay(with s: AppSettings) -> Bool {
        if systemAsleep || displayAsleep { return false }
        if s.pauseWhenScreenLocked && screenLocked { return false }
        if s.pauseOnBattery && onBattery { return false }
        if s.pauseOnLowPower && lowPowerMode { return false }
        return true
    }

    /// 给菜单栏显示当前为什么停了
    func pauseReason(with s: AppSettings) -> String? {
        if systemAsleep || displayAsleep { return T("reason.displayAsleep") }
        if s.pauseWhenScreenLocked && screenLocked { return T("reason.locked") }
        if s.pauseOnBattery && onBattery { return T("reason.battery") }
        if s.pauseOnLowPower && lowPowerMode { return T("reason.lowPower") }
        return nil
    }
}
