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
    private(set) var screenLocked = false
    private(set) var systemAsleep = false

    /// 任意一项变化时回调，让引擎重新算该不该播
    var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?

    init() {
        refreshPowerSource()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        installPowerSourceWatcher()
        installNotifications()
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
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = true
            self?.onChange?()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = false
            self?.onChange?()
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = true
            self?.onChange?()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemAsleep = false
            self?.onChange?()
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true
            self?.onChange?()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false
            self?.onChange?()
        }

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.onChange?()
        }
    }

    /// 按当前设置判断：全局层面该不该让壁纸播
    func shouldPlay(with s: AppSettings) -> Bool {
        if systemAsleep { return false }
        if s.pauseWhenScreenLocked && screenLocked { return false }
        if s.pauseOnBattery && onBattery { return false }
        if s.pauseOnLowPower && lowPowerMode { return false }
        return true
    }

    /// 给菜单栏显示当前为什么停了
    func pauseReason(with s: AppSettings) -> String? {
        if systemAsleep { return T("reason.displayAsleep") }
        if s.pauseWhenScreenLocked && screenLocked { return T("reason.locked") }
        if s.pauseOnBattery && onBattery { return T("reason.battery") }
        if s.pauseOnLowPower && lowPowerMode { return T("reason.lowPower") }
        return nil
    }
}
