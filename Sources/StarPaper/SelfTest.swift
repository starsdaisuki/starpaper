import Foundation
import AppKit

/// 设置层自检。
///
///     STARPAPER_SELFTEST=1 ./build/StarPaper.app/Contents/MacOS/StarPaper
///
/// 存在的理由：「点一下设置就弹回去」这个 bug 只有真的去点界面才发现得了，
/// 但它的根因在设置层（写盘期间被自己的通知重入回读），跟界面无关。
/// 有这个自检就能在不碰鼠标的前提下复现和验证。
enum SelfTest {

    private static var failures = 0

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["STARPAPER_SELFTEST"] == "1"
    }

    /// 自检专用的一次性设置域。⚠️ 见 `AppSettings.useDefaultsSuite`
    private static let testSuiteName = "io.github.starsdaisuki.starpaper.selftest"
    private static var testSuite: UserDefaults!
    /// 开测前真实域的快照，跑完要对得上（自检不许改坏用户的配置）
    private static var realDomainBefore: [String: String] = [:]

    private static let managedKeys = [
        "videoPath", "language", "dim", "muted", "scaleMode", "contrast",
        "playlistShuffle", "volume", "fps",
    ]

    private static func snapshotRealDomain() -> [String: String] {
        let d = UserDefaults.standard
        var snap: [String: String] = [:]
        for k in managedKeys { snap[k] = d.object(forKey: k).map { String(describing: $0) } ?? "<不存在>" }
        return snap
    }

    static func run() {
        // ⚠️⚠️ 先把设置层整个搬到一次性 suite 再开测。
        // 直接翻真实设置域再还原并不安全：另一个正在运行的实例可能读到临时值，
        // 并在测试还原磁盘后把临时值再次保存回来。
        realDomainBefore = snapshotRealDomain()
        testSuite = UserDefaults(suiteName: testSuiteName)!
        testSuite.removePersistentDomain(forName: testSuiteName)
        AppSettings.shared.useDefaultsSuite(testSuite)

        testMainMenu()

        let s = AppSettings.shared
        print("=== StarPaper 设置层自检 ===")

        // 原值留底，测完还原，不弄脏用户配置
        let backup = (
            language: s.language, dim: s.dim, muted: s.muted,
            scaleMode: s.scaleMode, contrast: s.contrast, playlistShuffle: s.playlistShuffle
        )

        // 一次改多个，专门覆盖「save() 逐键写、写到一半被通知打断」那条路径
        let targetLang: Lang = s.language == .zh ? .en : .zh
        s.language = targetLang
        s.dim = 0.42
        s.muted = !backup.muted
        s.scaleMode = s.scaleMode == .fill ? .fit : .fill
        s.contrast = 1.37
        s.playlistShuffle = !backup.playlistShuffle

        let expected = (
            language: targetLang, dim: 0.42, muted: !backup.muted,
            scaleMode: s.scaleMode, contrast: 1.37, playlistShuffle: !backup.playlistShuffle
        )

        // 等 debounce(300ms) → save() → didChangeNotification 全部走完
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let d = testSuite!

            check("内存 language",  s.language,        expected.language)
            check("磁盘 language",  d.string(forKey: "language") ?? "", expected.language.rawValue)
            check("内存 dim",       s.dim,             expected.dim)
            check("磁盘 dim",       d.double(forKey: "dim"), expected.dim)
            check("内存 muted",     s.muted,           expected.muted)
            check("磁盘 muted",     d.bool(forKey: "muted"), expected.muted)
            check("内存 scaleMode", s.scaleMode,       expected.scaleMode)
            check("磁盘 scaleMode", d.string(forKey: "scaleMode") ?? "", expected.scaleMode.rawValue)
            check("内存 contrast",  s.contrast,        expected.contrast)
            check("磁盘 contrast",  d.double(forKey: "contrast"), expected.contrast)
            check("内存 shuffle",   s.playlistShuffle, expected.playlistShuffle)
            check("磁盘 shuffle",   d.bool(forKey: "playlistShuffle"), expected.playlistShuffle)

            // 第二轮：验证外部改动仍然能被吃进来（热更新没被两道闸误杀）
            d.set(0.77, forKey: "dim")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                check("外部改动生效 dim", s.dim, 0.77)

                // 还原
                s.language = backup.language
                s.dim = backup.dim
                s.muted = backup.muted
                s.scaleMode = backup.scaleMode
                s.contrast = backup.contrast
                s.playlistShuffle = backup.playlistShuffle

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    s.save()

                    // ⭐ 最后一关：证明这一整轮自检一个字节都没动过用户的真实设置
                    let after = snapshotRealDomain()
                    let changed = managedKeys.filter { realDomainBefore[$0] != after[$0] }
                    check("没碰用户的真实设置（\(managedKeys.count) 项）",
                          changed.joined(separator: ","), "")
                    AppSettings.shared.useDefaultsSuite(.standard)
                    testSuite.removePersistentDomain(forName: testSuiteName)

                    print(failures == 0 ? "\n✅ 全部通过（\(passed) 项）" : "\n❌ \(failures) 项失败")
                    exit(failures == 0 ? 0 : 1)
                }
            }
        }
    }

    /// ⌘W / ⌘A / ⌘V / ⌘X / ⌘Z 全靠 NSApp.mainMenu 的 key equivalent 派发。
    /// 以前这个 app 只建了状态栏菜单（那个不参与派发），所以设置窗口
    /// **只能用鼠标点左上角红点关**，输入框里也没法全选粘贴。
    private static func testMainMenu() {
        let menu = AppDelegate.makeMainMenu(settingsTarget: nil, settingsAction: nil)
        var items: [NSMenuItem] = []
        func walk(_ m: NSMenu) { for i in m.items { items.append(i); if let sub = i.submenu { walk(sub) } } }
        walk(menu)
        func find(_ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods }
        }
        let expected: [(String, String, Selector, NSEvent.ModifierFlags)] = [
            ("关闭窗口 ⌘W", "w", #selector(NSWindow.performClose(_:)), [.command]),
            ("全选 ⌘A",   "a", #selector(NSText.selectAll(_:)), [.command]),
            ("拷贝 ⌘C",   "c", #selector(NSText.copy(_:)),      [.command]),
            ("粘贴 ⌘V",   "v", #selector(NSText.paste(_:)),     [.command]),
            ("剪切 ⌘X",   "x", #selector(NSText.cut(_:)),       [.command]),
            ("撤销 ⌘Z",   "z", NSSelectorFromString("undo:"),   [.command]),
            ("重做 ⌘⇧Z",  "z", NSSelectorFromString("redo:"),   [.command, .shift]),
        ]
        for (label, key, sel, mods) in expected {
            let item = find(key, mods)
            check("主菜单 \(label)", item?.action.map(NSStringFromSelector) ?? "缺这一项",
                  NSStringFromSelector(sel))
            check("主菜单 \(label) 走响应链", item?.target == nil, true)
        }
        // 故意不放 ⌘Q：设置窗口在前台时按 ⌘Q 会把整个壁纸引擎也关掉
        check("主菜单里没有 ⌘Q", find("q", [.command]) == nil, true)
    }

    private static var passed = 0

    private static func check<V: Equatable>(_ name: String, _ actual: V, _ expected: V) {
        // Double 比较留点余量，别被浮点表示坑
        if let a = actual as? Double, let e = expected as? Double {
            if abs(a - e) < 0.0001 { pass(name, a) } else { fail(name, a, e) }
            return
        }
        if actual == expected { pass(name, actual) } else { fail(name, actual, expected) }
    }

    private static func pass(_ name: String, _ v: Any) {
        passed += 1
        print("  ✓ \(name) = \(v)")
    }

    private static func fail(_ name: String, _ actual: Any, _ expected: Any) {
        failures += 1
        print("  ✗ \(name)：期望 \(expected)，实际 \(actual)")
    }
}
