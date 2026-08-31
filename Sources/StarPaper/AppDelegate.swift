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

        applyDockIconPolicy()          // ⚠️ 要在 installMainMenu() 之前：⌘Q 放不放取决于最终形态
        installMainMenu()

        // ⚠️⚠️ **自检必须在这里跑完就退出，绝不能等到建完引擎。**
        //
        // `WallpaperEngine()` 的 init 末尾会 `rebuildScreens()` —— 那是真的在用户桌面上
        // 建出壁纸窗。而 `SelfTest.run()` 随后会把设置切到一次性空域（videoPath 为空
        // → 回落到内置 demo）、翻 `clockEnabled`、改 `dim` / `contrast`，
        // 这些改动会经 `LiveSettingsRelay` 一路落到那些**真窗**上。
        //
        // 结果就是：每跑一次 `make test`，用户桌面都会闪一下
        // 「黑洞 + 两个时钟 + 忽暗忽亮」，然后随进程退出一起消失。
        // 2026-08-31 用户连报三次「启动有 bug」，录屏后确认根因就是这个 ——
        // 一次误诊成时钟、一次误诊成窗口放置，都是被这个假象带偏的。
        //
        // 自检只用纯函数和设置层，不需要引擎，也不需要状态栏图标。
        if SelfTest.isEnabled {
            SelfTest.run()
            return
        }

        engine = WallpaperEngine()
        engine.onStateChange = { [weak self] in self?.refreshMenu() }
        setupStatusItem()

        // 「只在菜单栏显示」改了就即时生效，不用重启
        settings.$hideDockIcon
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyDockIconPolicy() }
            .store(in: &bag)

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

        if Self.shouldOpenSettingsOnLaunch(
            hasLaunchedBefore: settings.hasLaunchedBefore,
            hasSavedVideo: !settings.videoPath.isEmpty,
            hasLibrary: !settings.playlist.isEmpty,
            nothingPlaying: engine.nowPlayingName.isEmpty) {
            openSettings(nil)
        }
        settings.hasLaunchedBefore = true
    }

    /// 启动时要不要把设置窗口拍脸上。
    ///
    /// 抽成纯函数是因为它有三条很容易搞反的分支，而 `applicationDidFinishLaunching`
    /// 里的版本一条都测不着 —— 上一版就是这么坏掉没人发现的：
    ///
    /// ⚠️ 原判据只是「没有画面在播」。自从内置 demo 进了 bundle（`d53e80e`），
    /// 首启一定有画面（`MediaSelector` 会兜底到 blackhole-demo），条件永远不成立，
    /// **首启弹窗被悄悄弄没了**。对上架审核尤其要命：app 带着 Dock 图标却一个窗都不开，
    /// 审核只看到桌面变了，很容易判成「不知道这 app 是干嘛的」。
    ///
    /// ⚠️ 也不能只看 `hasLaunchedBefore`：这个键是新加的，**老用户升上来一律是 false**，
    /// 会被平白弹一次。所以已经有选好的视频或视频库时，就不算第一次。
    static func shouldOpenSettingsOnLaunch(
        hasLaunchedBefore: Bool, hasSavedVideo: Bool, hasLibrary: Bool, nothingPlaying: Bool
    ) -> Bool {
        // 连内置 demo 都读不到 → 屏幕上什么都没有，必须给一个入口
        if nothingPlaying { return true }
        if hasLaunchedBefore { return false }
        return !hasSavedVideo && !hasLibrary
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
    /// ## ⌘Q 是有条件的
    ///
    /// 原来**故意不放 Quit ⌘Q**：没有 Dock 图标时，用户眼里「设置窗口」就是这个 app 的全部，
    /// 在它前台按 ⌘Q 只想关窗口，结果会把整个壁纸引擎一起关掉。
    ///
    /// 但 2026-08-29 为上架把 Dock 图标改成默认显示之后，这个前提在默认形态下不成立了：
    /// 有 Dock 图标 = 用户知道这是个常驻 app，⌘Q 退出整个 app 是 macOS 的标准语义，
    /// 而且 App Menu 里没有 Quit 反而反常（审核员会拿 Guideline 4 Design 说事）。
    /// 所以按形态给：**显示 Dock 图标时放 ⌘Q，「仅菜单栏」模式下保留原来的保护。**
    private func installMainMenu() {
        NSApp.mainMenu = AppDelegate.makeMainMenu(settingsTarget: self,
                                                  settingsAction: #selector(openSettings(_:)),
                                                  quitTarget: self,
                                                  quitAction: #selector(quit(_:)),
                                                  includeQuit: !settings.hideDockIcon)
    }

    /// 按设置切换 Dock 图标的显示。
    ///
    /// ⚠️ `LSUIElement` 在 Info.plist 里已经是 false（默认显示 Dock 图标，为上架改的，
    /// 理由见 `AppSettings.hideDockIcon`）。用户打开「仅在菜单栏显示」时，
    /// 靠运行时切 activation policy 回到原来那个纯菜单栏形态。
    ///
    /// ⚠️ 切到 `.accessory` 会让 app 失去前台身份，**主菜单要跟着重建**（⌘Q 那一项要去掉），
    /// 否则会留下一个在 accessory 形态下不该存在的 ⌘Q。
    func applyDockIconPolicy() {
        let want: NSApplication.ActivationPolicy = settings.hideDockIcon ? .accessory : .regular
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        installMainMenu()
        // 从 accessory 切回 regular 时 app 不会自动到前台，设置窗口会被别人盖住
        if want == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// 抽成静态方法是为了能在 `make test` 里直接量 —— 「菜单里有没有那几项、键位对不对」
    /// 不用起界面就能验。
    static func makeMainMenu(settingsTarget: AnyObject?, settingsAction: Selector?,
                             quitTarget: AnyObject? = nil, quitAction: Selector? = nil,
                             includeQuit: Bool = false) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()

        // 关于：走响应链交给 NSApp，不用自己造面板
        appMenu.addItem(NSMenuItem(
            title: T("menu.about"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())

        let prefs = NSMenuItem(title: T("menu.settings"), action: settingsAction, keyEquivalent: ",")
        prefs.target = settingsTarget
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())

        // 隐藏三件套是 Dock 图标形态下的标准配置，target 全留 nil 走响应链
        let hide = NSMenuItem(title: T("menu.hide"),
                              action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: T("menu.hideOthers"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: T("menu.showAll"),
            action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))

        // ⚠️ 只在显示 Dock 图标时放 ⌘Q，理由见 installMainMenu() 的注释
        if includeQuit {
            appMenu.addItem(.separator())
            let quit = NSMenuItem(title: T("menu.quit"), action: quitAction, keyEquivalent: "q")
            quit.keyEquivalentModifierMask = [.command]
            quit.target = quitTarget
            appMenu.addItem(quit)
        }

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
            settings.play(MediaAccess.remember(url)) // 顺手进库，见 AppSettings.play
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
