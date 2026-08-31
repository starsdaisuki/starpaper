import Foundation

enum Lang: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// 极简本地化：一张表，两列。
///
/// 没用 .lproj / NSLocalizedString，因为 SwiftPM 手工组 bundle 时资源路径很容易踩坑，
/// 而且这个 app 的字符串量根本不值得引入那套机制。切语言要即时生效，
/// 所以 T() 直接读 AppSettings.shared.language —— SettingsView 观察着 AppSettings，
/// 语言一变整个界面自然重绘。
func T(_ key: String) -> String {
    let lang = AppSettings.shared.language
    guard let pair = strings[key] else {
        assertionFailure("缺翻译: \(key)")
        return key
    }
    return lang == .zh ? pair.0 : pair.1
}

private let strings: [String: (String, String)] = [
    // 通用
    "app.name":            ("StarPaper", "StarPaper"),
    "settings.title":      ("StarPaper 设置", "StarPaper Settings"),

    // 标签页
    "tab.content":         ("内容", "Content"),
    "tab.clock":           ("时钟", "Clock"),
    "tab.crop":            ("裁剪", "Crop"),
    "tab.image":           ("画面", "Image"),
    "tab.audio":           ("声音", "Audio"),
    "tab.power":           ("省电", "Power"),
    "tab.general":         ("通用", "General"),

    // 内容页
    "content.file":        ("当前视频", "Now Playing"),
    "content.none":        ("还没有选视频", "No video selected"),
    "content.choose":      ("选择视频…", "Choose Video…"),
    "content.display":     ("显示", "Display"),
    "content.scale":       ("缩放方式", "Scale Mode"),
    "content.iconLayer":   ("桌面图标", "Desktop Icons"),
    "content.speed":       ("播放速度", "Playback Speed"),
    "content.libraryHint": ("这里就是正在播的那个。挑过的视频会自动收进「播放」页的视频库，轮播换片时这里也跟着变。",
                            "This is whatever is playing right now. Videos you pick are kept in the library on the Playback tab, and this follows along when it switches."),

    "scale.fill":          ("填充（裁边）", "Fill (crop edges)"),
    "scale.fit":           ("适应（留黑边）", "Fit (letterbox)"),
    "scale.stretch":       ("拉伸（会变形）", "Stretch (distorts)"),

    "content.playDemo":    ("内置示例", "Built-in sample"),
    "content.perSpace":    ("每个桌面单独一扇壁纸窗", "One wallpaper window per desktop"),
    "perSpace.auto":       ("自动 · 跟随「减弱动态效果」", "Auto · follow Reduce Motion"),
    "perSpace.on":         ("一直开", "Always on"),
    "perSpace.off":        ("一直关（老行为）", "Always off (classic)"),
    "content.perSpaceHint": (
        "切桌面的那一瞬间，如果你开着「辅助功能 → 显示 → 减弱动态效果」，新桌面会先露出系统壁纸约 1 秒才出现视频；打开这一项就没有了。系统那个开关关着的时候本来就不会露，这时再开只会多占一点内存、在 Mission Control 里多出几张壁纸缩略图。所以默认「自动」跟着系统那个开关走，不用管它。",
        "While \"Accessibility → Display → Reduce motion\" is on, switching desktops shows the system wallpaper for about a second before your video appears; turning this on removes that. With Reduce motion off nothing is ever revealed, so turning this on only costs a little memory and adds extra wallpaper thumbnails to Mission Control. That is why the default is \"Auto\": it follows the system setting, so you can leave it alone."),
    "content.perSpaceNow": ("当前生效：", "Currently in effect: "),
    "perSpace.nowPerDesktop": ("每桌面一扇壁纸窗", "one window per desktop"),
    "perSpace.nowSingle":     ("单扇壁纸窗跟随你", "a single window following you"),
    "content.backingLayers": ("每个桌面叠几扇壁纸窗", "Wallpaper windows stacked per desktop"),
    "content.backingLayersHint": (
        "切桌面的那一下，系统一定会让桌面壁纸透出来一点，画面会闪一下 —— 这一点挡不住。在壁纸下面多垫几扇一样的窗，透出来的就还是这段视频，闪的感觉就没了。3 扇是实测最不容易看出来的一档，不是越多越好。垫出来的窗不解码也不重绘，实测 CPU 和内存没有可测的增加；如果你介意多出来的窗，调成 1 就等于关掉。",
        "The moment you switch desktops, the system always lets the desktop wallpaper bleed through, so the picture flickers — that cannot be blocked. Stacking a few identical windows underneath means what bleeds through is your video instead, and the flicker goes away. 3 is the least noticeable setting in testing; more is not better. The stacked windows never decode or redraw, and the measured CPU and memory cost is within noise. If you would rather not have the extra windows, set this to 1 to turn it off."),
    "content.appStoreDisplayHint":
        ("App Store 版使用公开的单窗跨桌面模式，并始终保留 Finder 桌面图标。",
         "The App Store build uses the public single-window mode across desktops and always preserves Finder desktop icons."),
    "iconLayer.below":     ("图标显示在壁纸上方", "Icons above wallpaper"),
    "iconLayer.above":     ("壁纸盖住桌面图标", "Wallpaper covers icons"),

    // 裁剪页
    "crop.title":          ("裁剪区域", "Crop Region"),
    "crop.hint":           ("拖动方框选你想留在屏幕上的部分。方框比例 = 你的显示器比例，所以框住的就是最终看到的。",
                            "Drag the box to pick what stays on screen. The box matches your display's aspect ratio, so what you frame is what you get."),
    "crop.zoom":           ("缩放", "Zoom"),
    "crop.focusX":         ("水平位置", "Horizontal"),
    "crop.focusY":         ("垂直位置", "Vertical"),
    "crop.reset":          ("居中并复位缩放", "Center & reset zoom"),
    "crop.multiScreen":    ("多显示器时每块屏按各自比例算裁剪区，这一套参数通吃，不用分别调。",
                            "With multiple displays each screen computes its own crop from these same values — no per-screen tweaking."),
    "crop.onlyFill":       ("裁剪只在「填充」模式下有意义，当前缩放方式是「适应 / 拉伸」。",
                            "Cropping only applies in Fill mode; the current scale mode is Fit / Stretch."),
    "crop.loading":        ("正在取预览帧…", "Loading preview frame…"),
    "crop.noVideo":        ("先在「内容」页选一个视频", "Pick a video on the Content tab first"),

    // 画面页
    "image.tone":          ("影调", "Tone"),
    "image.color":         ("色彩", "Color"),
    "image.effect":        ("效果", "Effects"),
    "image.exposure":      ("曝光", "Exposure"),
    "image.brightness":    ("亮度", "Brightness"),
    "image.contrast":      ("对比度", "Contrast"),
    "image.highlights":    ("高光", "Highlights"),
    "image.shadows":       ("阴影", "Shadows"),
    "image.gamma":         ("伽马", "Gamma"),
    "image.saturation":    ("饱和度", "Saturation"),
    "image.vibrance":      ("鲜艳度", "Vibrance"),
    "image.temperature":   ("色温", "Temperature"),
    "image.tint":          ("色调", "Tint"),
    "image.blur":          ("模糊", "Blur"),
    "image.sharpen":       ("锐化", "Sharpen"),
    "image.dim":           ("变暗", "Dim"),
    "image.reset":         ("恢复默认画面设置", "Reset image adjustments"),
    "image.highlightsHint":("「高光」只压最亮的那部分，暗部不动 —— 画面某块太刺眼就调它，别调对比度。",
                            "Highlights only pulls down the brightest areas and leaves shadows alone — use it when one spot is too glaring, not contrast."),
    "image.vibranceHint":  ("「鲜艳度」比饱和度聪明：只提本来不鲜艳的颜色，已经很艳的不动，不容易过曝成色块。",
                            "Vibrance is smarter than saturation: it boosts muted colors and leaves already-saturated ones alone, so skin tones don't blow out."),
    "image.dimHint":       ("「变暗」是叠一层黑遮罩，比调亮度更适合让桌面图标看清楚。",
                            "Dim overlays a black layer — better than lowering brightness if you want desktop icons to stay readable."),

    // 声音页
    "audio.section":       ("音频", "Audio"),
    "audio.mute":          ("静音", "Mute"),
    "audio.volume":        ("音量", "Volume"),
    "audio.hint":          ("多显示器时只有主屏那份会出声，避免回声。",
                            "Only the main display's player is audible, to avoid echo."),

    // 省电页
    "power.section":       ("自动暂停", "Auto-pause"),
    "power.occluded":      ("被窗口遮挡时暂停", "Pause when covered"),
    "power.locked":        ("锁屏时暂停", "Pause when screen locked"),
    "power.lowPower":      ("低电量模式时暂停", "Pause in Low Power Mode"),
    "power.battery":       ("使用电池时暂停", "Pause on battery"),
    "power.hint":          ("「被窗口遮挡时暂停」建议一直开着 —— 你开全屏 app 的时候壁纸根本看不见，继续解码纯粹是白烧电、白发热。开了声音的话它还兼管 BGM：开着＝进全屏 app 音频一起停，关着＝壁纸看不见也继续响。",
                            "Keep \"pause when covered\" on — when a fullscreen app hides the wallpaper, decoding it anyway just burns battery and heat for nothing. With sound on it also governs the BGM: on = audio stops too inside a fullscreen app, off = it keeps playing even when the wallpaper is hidden."),

    // 通用页
    "general.language":    ("语言", "Language"),
    "general.langHint":    ("切换后立即生效，菜单栏也会跟着变。",
                            "Applies immediately, including the menu bar."),

    // 菜单栏
    "menu.pause":          ("暂停", "Pause"),
    "menu.resume":         ("继续播放", "Resume"),
    "menu.choose":         ("选择视频…", "Choose Video…"),
    "menu.mute":           ("静音", "Mute"),
    "menu.unmute":         ("取消静音", "Unmute"),
    "menu.settings":       ("设置…", "Settings…"),
    "menu.rebuild":        ("重建壁纸窗口", "Rebuild Wallpaper Windows"),
    "menu.quit":           ("退出 StarPaper", "Quit StarPaper"),
    "menu.about":          ("关于 StarPaper", "About StarPaper"),
    "menu.hide":           ("隐藏 StarPaper", "Hide StarPaper"),
    "menu.hideOthers":     ("隐藏其他", "Hide Others"),
    "menu.showAll":        ("全部显示", "Show All"),
    "general.hideDock":    ("只在菜单栏显示（不占程序坞）", "Menu bar only (hide Dock icon)"),
    "general.hideDockHint": ("关闭后程序坞里会有 StarPaper 图标，⌘Q 可退出；打开则只保留右上角菜单栏图标。",
                            "When off, StarPaper shows a Dock icon and ⌘Q quits it. When on, only the menu bar icon remains."),
    "general.appearance":  ("外观", "Appearance"),

    // 主菜单里的「文件 / 编辑」。菜单栏上看不见（accessory app 不显示菜单栏），
    // 但 ⌘W 关窗口、⌘A / ⌘V / ⌘X / ⌘Z 全靠它派发。
    "menu.file":           ("文件", "File"),
    "menu.close":          ("关闭窗口", "Close Window"),
    "menu.edit":           ("编辑", "Edit"),
    "menu.undo":           ("撤销", "Undo"),
    "menu.redo":           ("重做", "Redo"),
    "menu.cut":            ("剪切", "Cut"),
    "menu.copy":           ("拷贝", "Copy"),
    "menu.paste":          ("粘贴", "Paste"),
    "menu.selectAll":      ("全选", "Select All"),

    // 状态
    "status.noVideo":      ("未选择视频", "No video selected"),
    "status.manualPause":  ("已手动暂停", "Paused manually"),
    "status.occluded":     ("暂停中 · 被窗口遮挡", "Paused · covered by a window"),
    "status.playingFmt":   ("播放中 · %d 块屏幕", "Playing · %d display(s)"),
    "status.playingDesktopsFmt": ("播放中 · %d 块屏幕 / %d 个桌面",
                                  "Playing · %d display(s) / %d desktop(s)"),
    "status.pausedFmt":    ("暂停中 · %@", "Paused · %@"),
    "reason.displayAsleep":("屏幕已休眠", "display asleep"),
    "reason.locked":       ("已锁屏", "screen locked"),
    "reason.battery":      ("正在用电池", "on battery"),
    "reason.lowPower":     ("低电量模式", "Low Power Mode"),


    // 暗角
    "image.vignette":      ("暗角", "Vignette"),
    "image.vignetteRadius":("暗角范围", "Vignette Size"),
    "image.vignetteHint":  ("「暗角」把画面四周压暗，中间保持亮 —— 桌面图标一般在边上，压暗边缘反而更好认。",
                            "Vignette darkens the edges while keeping the center bright — desktop icons usually sit near the edges, so this actually helps readability."),

    // 播放列表
    "tab.playback":        ("播放", "Playback"),
    "playlist.auto":       ("自动轮播", "Auto-advance"),
    "playlist.section":    ("视频库", "Video Library"),
    "playlist.add":        ("添加视频…", "Add Videos…"),
    "playlist.remove":     ("移除选中", "Remove Selected"),
    "playlist.clear":      ("清空", "Clear"),
    "playlist.empty":      ("库是空的，先添加视频", "The library is empty — add some videos"),
    "playlist.hint":       ("点一下就切过去播。自动轮播只管「要不要自己换」，关着照样能点。",
                            "Click one to play it. Auto-advance only controls whether it switches on its own — the list works either way."),
    "playlist.shuffle":    ("随机顺序", "Shuffle"),
    "playlist.advance":    ("切换时机", "Advance"),
    "playlist.onEnd":      ("播完一遍就切下一个", "When the video ends"),
    "playlist.interval":   ("每隔一段时间切", "On a timer"),
    "playlist.every":      ("间隔", "Every"),
    "playlist.minutesFmt": ("%.0f 分钟", "%.0f min"),
    "playlist.nowPlaying": ("正在播放", "Now playing"),
    "playlist.next":       ("下一个", "Next"),
    "playlist.overridden": ("日程功能开着，它的优先级更高 —— 自动轮播现在不生效。",
                            "The schedule is on and takes priority — auto-advance is inactive right now."),

    // 日程
    "tab.schedule":        ("日程", "Schedule"),
    "schedule.enable":     ("按时间自动换壁纸", "Switch wallpaper by time of day"),
    "schedule.section":    ("白天 / 夜间", "Day / Night"),
    "schedule.dayVideo":   ("白天视频", "Daytime video"),
    "schedule.nightVideo": ("夜间视频", "Nighttime video"),
    "schedule.dayStart":   ("白天开始", "Day starts"),
    "schedule.nightStart": ("夜间开始", "Night starts"),
    "schedule.choose":     ("选择…", "Choose…"),
    "schedule.current":    ("当前时段", "Right now"),
    "schedule.day":        ("白天", "Daytime"),
    "schedule.night":      ("夜间", "Nighttime"),
    "schedule.hint":       ("开着的时候日程优先于视频库和当前视频。没设视频的那个时段会沿用另一个。",
                            "While on, the schedule overrides the library and the current video. A period with no video falls back to the other one."),

    // 快捷键
    "tab.hotkeys":         ("快捷键", "Hotkeys"),
    "hotkey.section":      ("全局快捷键", "Global Hotkeys"),
    "hotkey.togglePause":  ("暂停 / 继续", "Pause / Resume"),
    "hotkey.next":         ("下一个视频", "Next video"),
    "hotkey.toggleMute":   ("静音开关", "Toggle mute"),
    "hotkey.openSettings": ("打开设置", "Open settings"),
    "hotkey.record":       ("点击设置", "Click to set"),
    "hotkey.recording":    ("按下组合键…", "Press keys…"),
    "hotkey.clear":        ("清除", "Clear"),
    "hotkey.hint":         ("默认全部为空。全局快捷键在任何 app 里都能触发，所以别选跟常用操作冲突的组合。",
                            "All empty by default. Global hotkeys fire from any app, so avoid combos that clash with things you use."),
    "hotkey.taken":        ("这个组合被别的 app 占了，换一个", "Another app already owns this combo — pick a different one"),
    "hotkey.needsMod":     ("至少要带一个修饰键（⌘ ⌥ ⌃ ⇧）", "Needs at least one modifier (⌘ ⌥ ⌃ ⇧)"),

    // 开机自启
    "general.startup":     ("开机自启", "Launch at Login"),
    "general.launchAtLogin":("登录时自动启动 StarPaper", "Start StarPaper when you log in"),
    "general.loginHint":   ("建议先跑 make install 把 app 装到 ~/Applications —— 自启记录的是当前路径，从 build/ 目录注册的话，清理构建产物就失效了。",
                            "Run `make install` first so the app lives in ~/Applications — the login item records the current path, so registering from build/ breaks when you clean."),
    "general.loginPending":("系统需要你在「系统设置 → 通用 → 登录项」里批准", "macOS needs your approval in System Settings → General → Login Items"),
    "general.loginFailed": ("注册失败：%@", "Registration failed: %@"),

    // 外部配置
    "general.external":    ("外部配置", "External Config"),
    "general.externalHint":("用 defaults write com.starsdaisuki.starpaper … 改配置会即时生效，不用重启 app。",
                            "Changes made with `defaults write com.starsdaisuki.starpaper …` apply immediately — no restart needed."),
    "general.privacy":     ("隐私", "Privacy"),
    "general.privacyPolicy":("查看隐私政策…", "View Privacy Policy…"),
    "general.privacyHint": ("视频只在本机读取和播放；StarPaper 不联网，不收集或上传数据。",
                            "Videos are read and played only on this Mac. StarPaper makes no network requests and collects or uploads no data."),

    // 文件选择
    "panel.message":       ("选一个视频当壁纸", "Pick a video to use as wallpaper"),

    // 时钟
    "clock.enabled":       ("显示桌面时钟", "Show desktop clock"),
    "clock.why":           ("在壁纸上叠一层实时时钟。矢量渲染，按屏幕像素密度光栅化，任何分辨率都清晰。",
                            "Overlays a live clock on the wallpaper. Vector-rendered at the screen's pixel density, so it stays sharp at any resolution."),
    "clock.style":         ("样式", "Style"),
    "clock.format":        ("格式", "Format"),
    "clock.line1":         ("主行", "Line 1"),
    "clock.line2":         ("第二行", "Line 2"),
    "clock.line3":         ("第三行", "Line 3"),
    "clock.formatHint":    ("yyyy/yy 年 · MM 月 · dd 日 · HH 时(24) · hh 时(12) · mm 分 · ss 秒 · [W] 星期 · [P] 时段。其余字符原样输出，留空则不显示该行。",
                            "yyyy/yy year · MM month · dd day · HH hour (24) · hh hour (12) · mm minute · ss second · [W] weekday · [P] period. Anything else is printed as-is; leave a line empty to hide it."),
    "clock.lang":          ("[W] / [P] 语言", "[W] / [P] language"),
    "clockLang.auto":      ("跟随界面", "Match interface"),
    "clock.subScale":      ("副行大小", "Sub size"),
    "clock.glow":          ("发光", "Glow"),
    "clock.glowOff":       ("关", "Off"),
    "clock.color":         ("颜色", "Colour"),
    "clock.color2":        ("目标颜色", "Target colour"),
    "clock.colorCycle":    ("双色循环", "Cycle between two colours"),
    "clock.layout":        ("位置与格式", "Position and format"),
    "clock.font":          ("字体", "Font"),
    "clock.size":          ("字号", "Size"),
    "clock.opacity":       ("不透明度", "Opacity"),
    "clock.x":             ("水平位置", "Horizontal"),
    "clock.y":             ("垂直位置", "Vertical"),
    "clock.anchor":        ("锚点", "Anchor"),
    "clockAnchor.screen":  ("相对屏幕", "Screen"),
    "clockAnchor.video":   ("相对画面", "Video"),
    "clock.anchorHint":    ("相对画面：时钟跟着视频一起被裁剪缩放，与画面元素的相对位置在任何屏幕比例下都不变（推荐）。相对屏幕：时钟固定在屏幕上，像一层独立的 UI。",
                            "Video: the clock is cropped and scaled together with the footage, so it keeps the same position relative to the artwork on any display. Screen: the clock stays put like a separate UI layer."),
    "clock.align":         ("对齐", "Align"),
    "clockAlign.left":     ("左", "Left"),
    "clockAlign.center":   ("中", "Center"),
    "clockAlign.right":    ("右", "Right"),
    "clock.alignHint":     ("锚点落在「基线 × 对齐边」上：右对齐时锚的是行尾，所以 09:59 跳到 10:00 不会左右抖。",
                            "The anchor sits on the baseline at the aligned edge, so a right-aligned clock will not jitter when 09:59 becomes 10:00."),
    "clock.subScale3":     ("末行比例", "Line 3 scale"),
    "clock.glowColor":     ("光晕颜色", "Glow color"),
    "clock.glowFollows":   ("光晕跟随文字色", "Glow follows text color"),
    "clock.perLine":       ("逐行定位", "Per-line anchors"),
    "clock.perLineHint":   ("默认各行自动往下堆叠。开启后第 2、3 行可以各自定位 —— 有些排版里各行并不共用一条对齐线。",
                            "By default the lines stack downwards. Turn this on to anchor lines 2 and 3 independently, for layouts where the lines do not share one alignment line."),
    "clock.line2Pos":      ("第 2 行", "Line 2"),
    "clock.line3Pos":      ("第 3 行", "Line 3"),
    "clock.reset":         ("恢复默认位置", "Reset position"),
    "clock.hint":          ("字号以 1920 宽为基准，会按屏幕宽度等比缩放。双击左侧标签可复位单项。",
                            "Size is calibrated for a 1920-wide screen and scales with the display. Double-click a label to reset that one value."),
]
