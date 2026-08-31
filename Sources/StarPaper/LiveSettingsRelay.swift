import Foundation
import Combine

/// 把 `AppSettings` 的改动实时喂给引擎的中继。
///
/// ## 为什么调度器必须是 `DispatchQueue.main`
///
/// Combine 的 `RunLoop` 调度器底下走 `RunLoop.perform`，**只往 runloop 的 default 模式投递**。
/// 而拖动滑杆（以及拖窗口、拉菜单）时，AppKit 的跟踪循环把主 runloop 切进
/// `NSEventTrackingRunLoopMode` —— 于是整个拖动过程中订阅方一次都收不到，
/// 直到松手回到 default 模式才一次性补上。用户看到的就是
/// 「拖的时候壁纸完全没反应，松手才一下跳到位」，音量、播放速度、影调滑杆全中招。
///
/// 主队列那条 source 注册在 common modes 里，事件跟踪期间照样被排空，所以换成
/// `DispatchQueue.main`。回归测试见 `SelfTest.liveSettingsRelaySelfTest()` ——
/// 它就是在事件跟踪模式下跑 runloop，换回 `RunLoop.main` 会直接红。
///
/// ## 为什么要合并
///
/// 拖动时改动是逐帧来的，而 `AppSettings.load()` 一次能连发几十条 `@Published`。
/// 不合并的话每一条都要重建整条 CIFilter 链、遍历所有窗（每个桌面还有几扇衬窗），
/// 白做的量随桌面数 × 层数相乘。合并到「一轮 runloop 一次」，肉眼看不出延迟。
final class LiveSettingsRelay {

    private var bag = Set<AnyCancellable>()
    private var scheduled = false
    private let apply: () -> Void

    /// - Parameter apply: 落地设置的动作，保证在主线程、且能读到改动后的新值。
    init(_ settings: AppSettings, apply: @escaping () -> Void) {
        self.apply = apply
        // ⚠️ 别改成 RunLoop.main，理由见上面的文档注释。
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.schedule() }
            .store(in: &bag)
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        // objectWillChange 是**改之前**发的，这一跳保证 apply 里读到的是新值。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.apply()
        }
    }
}
