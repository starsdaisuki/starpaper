import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var engine: WallpaperEngine!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let settings = AppSettings.shared
    private let hotkeys = HotkeyManager()
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 只待在菜单栏，不占 Dock

        engine = WallpaperEngine()
        engine.onStateChange = { [weak self] in self?.refreshMenu() }

        installMainMenu()
        setupStatusItem()

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.reload(from: settings)
        // 快捷键改了就整体重注册（改一个和改一批走同一条路，不追增量状态）
        settings.$hotkeys
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hotkeys.reload(from: self.settings)
            }
            .store(in: &bag)

        // 命令行发来的一次性动作
        settings.$command
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] cmd in
                guard let self, !cmd.isEmpty else { return }
                if cmd.hasPrefix("next:") { self.nextVideo(nil) }
                self.settings.command = ""      // 用完清掉，免得重启时重放
            }
            .store(in: &bag)

        // 切语言时菜单栏和窗口标题要跟着换（SwiftUI 那边靠 @Published 自己重绘）
        settings.$language
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMenu()
                self?.settingsWindow?.title = T("settings.title")
            }
            .store(in: &bag)

        if SelfTest.isEnabled {
            SelfTest.run()
            return
        }

        // 第一次跑、还没选视频 → 直接把设置窗口拍脸上
        if settings.videoPath.isEmpty {
            openSettings(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        settings.save()
    }

    // MARK: - 主菜单（⌘W / ⌘A / ⌘V / ⌘X / ⌘Z 全靠它）

    /// ⚠️ **这些快捷键不是窗口和文本框自带的**，是主菜单里那几项的 key equivalent ——
    /// `NSApplication.sendEvent` 拿到带 ⌘ 的 keyDown 时，先问
    /// `NSApp.mainMenu.performKeyEquivalent(_:)`，才轮到窗口和响应链。
    ///
    /// 这个 app 一直只建了状态栏的 `statusItem.menu`，**那个不参与 key equivalent 派发**，
    /// `NSApp.mainMenu` 是 nil，所以设置窗口**只能用鼠标点左上角红点关**（⌘W 没反应），
    /// 里面的输入框也没法 ⌘A 全选、⌘V 粘贴、⌘Z 撤销。
    ///
    /// LSUIElement（accessory）app 永远不显示菜单栏，但 key equivalent 照样派发，
    /// 所以补一个「看不见的主菜单」就够了，界面上不会多出任何东西。
    ///
    /// **故意不放 Quit ⌘Q**：设置窗口在前台时按 ⌘Q 会把整个壁纸引擎也关掉。
    /// 退出走菜单栏图标那一项。
    private func installMainMenu() {
        NSApp.mainMenu = AppDelegate.makeMainMenu(settingsTarget: self,
                                                  settingsAction: #selector(openSettings(_:)))
    }

    /// 抽成静态方法是为了能在 `make test` 里直接量 —— 「菜单里有没有那几项、键位对不对」
    /// 不用起界面就能验。
    static func makeMainMenu(settingsTarget: AnyObject?, settingsAction: Selector?) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: T("menu.settings"), action: settingsAction, keyEquivalent: ",")
        prefs.target = settingsTarget
        appMenu.addItem(prefs)
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: T("menu.file"))
        let close = NSMenuItem(title: T("menu.close"),
                               action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(close)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: T("menu.edit"))
        // target 全留 nil = 走响应链，谁是 firstResponder 谁接
        for (title, action, key, mods) in editEntries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }

    static var editEntries: [(String, Selector, String, NSEvent.ModifierFlags)] {
        [
            // undo: / redo: 在 AppKit 里没有公开的 Swift 符号（UndoManager.undo() 不带冒号，
            // 不是菜单要的那个 action），只能按名字取
            (T("menu.undo"),      NSSelectorFromString("undo:"),   "z", [.command]),
            (T("menu.redo"),      NSSelectorFromString("redo:"),   "z", [.command, .shift]),
            (T("menu.cut"),       #selector(NSText.cut(_:)),       "x", [.command]),
            (T("menu.copy"),      #selector(NSText.copy(_:)),      "c", [.command]),
            (T("menu.paste"),     #selector(NSText.paste(_:)),     "v", [.command]),
            (T("menu.selectAll"), #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles.tv", accessibilityDescription: "StarPaper")
            button.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: engine.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: settings.isPaused ? T("menu.resume") : T("menu.pause"),
            action: #selector(togglePause(_:)), keyEquivalent: "p"
        )
        toggle.target = self
        menu.addItem(toggle)

        let next = NSMenuItem(title: T("playlist.next"), action: #selector(nextVideo(_:)), keyEquivalent: "]")
        next.target = self
        menu.addItem(next)

        let pick = NSMenuItem(title: T("menu.choose"), action: #selector(pickVideo(_:)), keyEquivalent: "o")
        pick.target = self
        menu.addItem(pick)

        let mute = NSMenuItem(
            title: settings.muted ? T("menu.unmute") : T("menu.mute"),
            action: #selector(toggleMute(_:)), keyEquivalent: "m"
        )
        mute.target = self
        menu.addItem(mute)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: T("menu.settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let reload = NSMenuItem(title: T("menu.rebuild"), action: #selector(rebuild(_:)), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: T("menu.quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    // MARK: - 动作

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .togglePause: togglePause(nil)
        case .next: nextVideo(nil)
        case .toggleMute: toggleMute(nil)
        case .openSettings: openSettings(nil)
        }
    }

    @objc private func nextVideo(_ sender: Any?) {
        engine.next()
        refreshMenu()
    }

    @objc private func togglePause(_ sender: Any?) {
        engine.togglePause()
        refreshMenu()
    }

    @objc private func toggleMute(_ sender: Any?) {
        settings.muted.toggle()
        settings.save()
        engine.applySettings()
        refreshMenu()
    }

    @objc private func rebuild(_ sender: Any?) {
        engine.rebuildScreens()
        refreshMenu()
    }

    @objc private func pickVideo(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video]
        panel.message = T("panel.message")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.videoPath = url.path
            settings.save()
            engine.reloadVideo(force: true)
            refreshMenu()
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(engine: engine))
        let window = NSWindow(contentViewController: hosting)
        window.title = T("settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
