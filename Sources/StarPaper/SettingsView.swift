import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    var engine: WallpaperEngine?

    @State private var poster: NSImage?
    @State private var videoSize: CGSize = .zero
    @State private var playlistSelection: Set<String> = []
    @State private var selectionAnchor: String?          // ⇧ 连选的起点
    @State private var draggingPath: String?             // 正在被拖动排序的那一行
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    /// 系统「减弱动态效果」此刻的状态。auto 档的解析结果依赖它，
    /// 而它可以在设置窗口开着的时候被改，所以要跟着通知刷新。
    @State private var reduceMotionNow = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    /// 这一刻实际生效的放置方式。
    ///
    /// ⚠️ UI 必须跟着**解析结果**走，不能只看用户选的那一档：
    /// `auto` 在系统 Reduce Motion 关着时同样退回单扇跟随，那时
    /// `SpaceStrategy.resolve` 会把叠窗层数强制成 1，而控件却还能调 ——
    /// 用户改了完全没效果（2026-08-31 实测：设置里存着 3，实际只有 1 扇窗）。
    private var resolvedPlacement: SpacePlacement {
        SpaceStrategy.resolve(mode: settings.perSpaceMode,
                              reduceMotion: reduceMotionNow,
                              bridgeAvailable: SpaceBridge.isAvailable,
                              requestedLayers: settings.backingLayers,
                              maxLayers: AppSettings.maxBackingLayers).placement
    }

    var body: some View {
        TabView {
            contentTab.tabItem { Label(T("tab.content"), systemImage: "film") }
            cropTab.tabItem { Label(T("tab.crop"), systemImage: "crop") }
            imageTab.tabItem { Label(T("tab.image"), systemImage: "slider.horizontal.3") }
            clockTab.tabItem { Label(T("tab.clock"), systemImage: "clock") }
            playbackTab.tabItem { Label(T("tab.playback"), systemImage: "list.and.film") }
            audioTab.tabItem { Label(T("tab.audio"), systemImage: "speaker.wave.2") }
            powerTab.tabItem { Label(T("tab.power"), systemImage: "bolt") }
            hotkeyTab.tabItem { Label(T("tab.hotkeys"), systemImage: "command") }
            generalTab.tabItem { Label(T("tab.general"), systemImage: "gearshape") }
        }
        .frame(width: 620, height: 540)
        .padding(.top, 8)
        .task(id: settings.videoPath) { await loadPreview() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotionNow = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private func loadPreview() async {
        poster = nil
        videoSize = .zero
        let path = settings.videoPath
        guard !path.isEmpty else { return }
        async let img = VideoInfo.posterFrame(ofFileAt: path)
        async let size = VideoInfo.naturalSize(ofFileAt: path)
        poster = await img
        videoSize = await size ?? .zero
    }

    // MARK: - 内容

    private var contentTab: some View {
        Form {
            Section {
                HStack {
                    Text(settings.videoPath.isEmpty
                         ? T("content.none")
                         : (settings.videoPath as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(settings.videoPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button(T("content.playDemo")) { settings.playBuiltInDemo() }
                    Button(T("content.choose")) { pickVideo() }
                }
                if !settings.videoPath.isEmpty {
                    Text(settings.videoPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if videoSize.width > 1 {
                        Text("\(Int(videoSize.width)) × \(Int(videoSize.height))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(T("content.file"))
            } footer: {
                Text(T("content.libraryHint"))
                    .settingsFooter()
            }

            Section {
                Picker(T("content.scale"), selection: $settings.scaleMode) {
                    ForEach(ScaleMode.allCases) { Text($0.localizedLabel).tag($0) }
                }
#if !STARPAPER_APPSTORE
                Picker(T("content.iconLayer"), selection: $settings.iconLayer) {
                    ForEach(IconLayerMode.allCases) { Text($0.localizedLabel).tag($0) }
                }
#endif
                LabeledSlider(title: T("content.speed"), value: $settings.playbackRate,
                              range: 0.25...2.0, defaultValue: 1.0,
                              format: { String(format: "%.2fx", $0) })
#if !STARPAPER_APPSTORE
                Picker(T("content.perSpace"), selection: $settings.perSpaceMode) {
                    ForEach(PerSpaceMode.allCases) { Text($0.localizedLabel).tag($0) }
                }
                Picker(T("content.backingLayers"), selection: $settings.backingLayers) {
                    ForEach(1...AppSettings.maxBackingLayers, id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                .disabled(resolvedPlacement != .singleDesktop)
#endif
            } header: {
                Text(T("content.display"))
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
#if !STARPAPER_APPSTORE
                    // 把 auto 档「现在到底解析成了什么」直接摆出来 ——
                    // 否则用户只能靠听 BGM 断没断来猜（2026-08-31）。
                    Text(T("content.perSpaceNow")
                         + (resolvedPlacement == .singleDesktop
                            ? T("perSpace.nowPerDesktop") : T("perSpace.nowSingle")))
                        .fontWeight(.medium)
                    Text(T("content.perSpaceHint"))
                    Text(T("content.backingLayersHint"))
#else
                    Text(T("content.appStoreDisplayHint"))
#endif
                }
                .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 裁剪

    private var cropTab: some View {
        VStack(spacing: 12) {
            if settings.videoPath.isEmpty {
                placeholder(T("crop.noVideo"))
            } else if settings.scaleMode != .fill {
                placeholder(T("crop.onlyFill"))
            } else if let poster, videoSize.width > 1 {
                CropPicker(poster: poster, videoSize: videoSize, screenAspect: mainScreenAspect)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)

                Text(T("crop.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)

                Form {
                    LabeledSlider(title: T("crop.zoom"), value: $settings.zoom,
                                  range: 1.0...3.0, defaultValue: 1.0,
                                  format: { String(format: "%.2fx", $0) })
                    LabeledSlider(title: T("crop.focusX"), value: $settings.focusX,
                                  range: 0...1, defaultValue: 0.5,
                                  format: { String(format: "%.0f%%", $0 * 100) })
                    LabeledSlider(title: T("crop.focusY"), value: $settings.focusY,
                                  range: 0...1, defaultValue: 0.5,
                                  format: { String(format: "%.0f%%", $0 * 100) })
                    HStack {
                        Button(T("crop.reset")) { settings.resetCrop() }
                        Spacer()
                    }
                    Text(T("crop.multiScreen"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .formStyle(.grouped)
                .frame(height: 230)
            } else {
                placeholder(T("crop.loading"))
            }
        }
        .padding(.vertical, 12)
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private var mainScreenAspect: CGFloat {
        guard let f = NSScreen.main?.frame, f.height > 1 else { return 16.0 / 9.0 }
        return f.width / f.height
    }

    // MARK: - 时钟

    /// 桌面时钟。存在意义见 ClockOverlay 的文档注释：
    /// 视频里烘焙的时钟是死的，想要活的只能在播放侧重叠一层。
    private var clockTab: some View {
        Form {
            Section {
                Toggle(T("clock.enabled"), isOn: $settings.clockEnabled)
                Text(T("clock.why"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                TextField(T("clock.line1"), text: $settings.clockFormat1)
                TextField(T("clock.line2"), text: $settings.clockFormat2)
                TextField(T("clock.line3"), text: $settings.clockFormat3)
                Picker(T("clock.lang"), selection: $settings.clockLang) {
                    ForEach(ClockLang.allCases) { l in Text(l.localizedLabel).tag(l) }
                }
                Text(T("clock.formatHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("clock.format"))
            }
            .disabled(!settings.clockEnabled)

            Section {
                Picker(T("clock.font"), selection: $settings.clockFontName) {
                    ForEach(ClockOverlay.availableFonts, id: \.id) { f in
                        Text(f.label).tag(f.id)
                    }
                }
                LabeledSlider(title: T("clock.size"), value: $settings.clockSize,
                              range: 24...160, defaultValue: 74,
                              format: { String(format: "%.0f", $0) })
                LabeledSlider(title: T("clock.subScale"), value: $settings.clockSubScale,
                              range: 0.2...0.8, defaultValue: 0.38,
                              format: { String(format: "%.0f%%", $0 * 100) })
                if !settings.clockFormat3.isEmpty {
                    LabeledSlider(title: T("clock.subScale3"), value: $settings.clockSubScale3,
                                  range: 0.2...0.8, defaultValue: 0.38,
                                  format: { String(format: "%.0f%%", $0 * 100) })
                }
                LabeledSlider(title: T("clock.glow"), value: $settings.clockGlow,
                              range: 0...2, defaultValue: 1.0,
                              format: { $0 < 0.01 ? T("clock.glowOff") : String(format: "%.2f", $0) })
                if settings.clockGlow > 0.01 {
                    Toggle(T("clock.glowFollows"), isOn: Binding(
                        get: { settings.clockGlowColorHex.isEmpty },
                        set: { settings.clockGlowColorHex = $0 ? "" : settings.clockColorHex }
                    ))
                    if !settings.clockGlowColorHex.isEmpty {
                        ColorPicker(T("clock.glowColor"), selection: Binding(
                            get: { Color(NSColor.fromClockHex(settings.clockGlowColorHex) ?? .white) },
                            set: { settings.clockGlowColorHex = NSColor($0).clockHex }
                        ), supportsOpacity: false)
                    }
                }
                LabeledSlider(title: T("clock.opacity"), value: $settings.clockOpacity,
                              range: 0.15...1.0, defaultValue: 0.95,
                              format: { String(format: "%.0f%%", $0 * 100) })
                ColorPicker(T("clock.color"), selection: Binding(
                    get: { Color(NSColor.fromClockHex(settings.clockColorHex) ?? .white) },
                    set: { settings.clockColorHex = NSColor($0).clockHex }
                ), supportsOpacity: false)
                Toggle(T("clock.colorCycle"), isOn: $settings.clockColorCycle)
                if settings.clockColorCycle {
                    ColorPicker(T("clock.color2"), selection: Binding(
                        get: { Color(NSColor.fromClockHex(settings.clockColor2Hex) ?? .white) },
                        set: { settings.clockColor2Hex = NSColor($0).clockHex }
                    ), supportsOpacity: false)
                }
            } header: {
                Text(T("clock.style"))
            }
            .disabled(!settings.clockEnabled)

            Section {
                Picker(T("clock.anchor"), selection: $settings.clockAnchor) {
                    ForEach(ClockAnchor.allCases) { a in
                        Text(a.localizedLabel).tag(a)
                    }
                }
                .pickerStyle(.segmented)
                Text(T("clock.anchorHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledSlider(title: T("clock.x"), value: $settings.clockX,
                              range: 0...1, defaultValue: 415.0 / 1920.0,
                              format: { String(format: "%.0f%%", $0 * 100) })
                LabeledSlider(title: T("clock.y"), value: $settings.clockY,
                              range: 0...1, defaultValue: 710.0 / 1080.0,
                              format: { String(format: "%.0f%%", $0 * 100) })
                Picker(T("clock.align"), selection: $settings.clockAlign) {
                    ForEach(ClockAlign.allCases) { a in Text(a.localizedLabel).tag(a) }
                }
                .pickerStyle(.segmented)
                Text(T("clock.alignHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(T("clock.perLine"), isOn: Binding(
                    get: { settings.clockLine2Y >= 0 || settings.clockLine3Y >= 0 },
                    set: { on in
                        // 打开时把当前自动堆叠的位置当起点，而不是从 0 开始 ——
                        // 否则一勾选时钟就飞到左上角，谁也不知道刚才在哪儿。
                        if on {
                            settings.clockLine2X = settings.clockX
                            settings.clockLine2Y = min(1, settings.clockY + 0.05)
                            if !settings.clockFormat3.isEmpty {
                                settings.clockLine3X = settings.clockX
                                settings.clockLine3Y = min(1, settings.clockY + 0.09)
                            }
                        } else {
                            settings.clockLine2X = -1; settings.clockLine2Y = -1
                            settings.clockLine3X = -1; settings.clockLine3Y = -1
                        }
                    }
                ))
                if settings.clockLine2Y >= 0 || settings.clockLine3Y >= 0 {
                    Text(T("clock.perLineHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledSlider(title: "\(T("clock.line2Pos")) · \(T("clock.x"))",
                                  value: $settings.clockLine2X, range: 0...1, defaultValue: settings.clockX,
                                  format: { String(format: "%.1f%%", $0 * 100) })
                    LabeledSlider(title: "\(T("clock.line2Pos")) · \(T("clock.y"))",
                                  value: $settings.clockLine2Y, range: 0...1, defaultValue: settings.clockY,
                                  format: { String(format: "%.1f%%", $0 * 100) })
                    if !settings.clockFormat3.isEmpty {
                        LabeledSlider(title: "\(T("clock.line3Pos")) · \(T("clock.x"))",
                                      value: $settings.clockLine3X, range: 0...1, defaultValue: settings.clockX,
                                      format: { String(format: "%.1f%%", $0 * 100) })
                        LabeledSlider(title: "\(T("clock.line3Pos")) · \(T("clock.y"))",
                                      value: $settings.clockLine3Y, range: 0...1, defaultValue: settings.clockY,
                                      format: { String(format: "%.1f%%", $0 * 100) })
                    }
                }
                HStack {
                    Button(T("clock.reset")) { settings.resetClock() }
                    Spacer()
                }
                Text(T("clock.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("clock.layout"))
            }
            .disabled(!settings.clockEnabled)
        }
        .formStyle(.grouped)
    }

    // MARK: - 画面

    private var imageTab: some View {
        Form {
            Section {
                LabeledSlider(title: T("image.exposure"), value: $settings.exposure,
                              range: -2...2, defaultValue: 0,
                              format: { String(format: "%+.2f EV", $0) })
                LabeledSlider(title: T("image.brightness"), value: $settings.brightness,
                              range: -0.6...0.6, defaultValue: 0,
                              format: { String(format: "%+.2f", $0) })
                LabeledSlider(title: T("image.contrast"), value: $settings.contrast,
                              range: 0.4...2.0, defaultValue: 1,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: T("image.highlights"), value: $settings.highlights,
                              range: 0...1, defaultValue: 1,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: T("image.shadows"), value: $settings.shadows,
                              range: -1...1, defaultValue: 0,
                              format: { String(format: "%+.2f", $0) })
                LabeledSlider(title: T("image.gamma"), value: $settings.gamma,
                              range: 0.4...2.0, defaultValue: 1,
                              format: { String(format: "%.2f", $0) })
                Text(T("image.highlightsHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("image.tone"))
            }

            Section {
                LabeledSlider(title: T("image.saturation"), value: $settings.saturation,
                              range: 0...2, defaultValue: 1,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: T("image.vibrance"), value: $settings.vibrance,
                              range: -1...1, defaultValue: 0,
                              format: { String(format: "%+.2f", $0) })
                LabeledSlider(title: T("image.temperature"), value: $settings.temperature,
                              range: 2500...10000, defaultValue: 6500,
                              format: { String(format: "%.0fK", $0) })
                LabeledSlider(title: T("image.tint"), value: $settings.tint,
                              range: -100...100, defaultValue: 0,
                              format: { String(format: "%+.0f", $0) })
                Text(T("image.vibranceHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("image.color"))
            }

            Section {
                LabeledSlider(title: T("image.blur"), value: $settings.blurRadius,
                              range: 0...60, defaultValue: 0,
                              format: { String(format: "%.0f", $0) })
                LabeledSlider(title: T("image.sharpen"), value: $settings.sharpen,
                              range: 0...2, defaultValue: 0,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: T("image.vignette"), value: $settings.vignette,
                              range: 0...2, defaultValue: 0,
                              format: { String(format: "%.2f", $0) })
                LabeledSlider(title: T("image.vignetteRadius"), value: $settings.vignetteRadius,
                              range: 0.3...3.0, defaultValue: 1.0,
                              format: { String(format: "%.2f", $0) })
                    .disabled(settings.vignette <= 0.01)
                Text(T("image.vignetteHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledSlider(title: T("image.dim"), value: $settings.dim,
                              range: 0...0.9, defaultValue: 0,
                              format: { String(format: "%.0f%%", $0 * 100) })
                Text(T("image.dimHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("image.effect"))
            }

            Section {
                Button(T("image.reset")) { settings.resetImageAdjustments() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 声音

    private var audioTab: some View {
        Form {
            Section {
                Toggle(T("audio.mute"), isOn: $settings.muted)
                LabeledSlider(title: T("audio.volume"), value: $settings.volume,
                              range: 0...1, defaultValue: 0.5,
                              format: { String(format: "%.0f%%", $0 * 100) })
                    .disabled(settings.muted)
            } header: {
                Text(T("audio.section"))
            } footer: {
                Text(T("audio.hint"))
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 省电

    private var powerTab: some View {
        Form {
            Section {
                Toggle(T("power.occluded"), isOn: $settings.pauseWhenOccluded)
                Toggle(T("power.locked"), isOn: $settings.pauseWhenScreenLocked)
                Toggle(T("power.lowPower"), isOn: $settings.pauseOnLowPower)
                Toggle(T("power.battery"), isOn: $settings.pauseOnBattery)
            } header: {
                Text(T("power.section"))
            } footer: {
                Text(T("power.hint"))
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section {
                Picker(T("general.language"), selection: $settings.language) {
                    ForEach(Lang.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(T("general.language"))
            } footer: {
                Text(T("general.langHint"))
                    .settingsFooter()
            }

            Section {
                Toggle(T("general.launchAtLogin"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        loginError = LoginItem.set(on)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                if let loginError {
                    Text(String(format: T("general.loginFailed"), loginError))
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if LoginItem.state == .requiresApproval {
                    HStack {
                        Text(T("general.loginPending"))
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("→") { LoginItem.openLoginItemsSettings() }
                    }
                }
                if !LoginItem.isInStableLocation {
                    Text(T("general.loginHint"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(T("general.startup"))
            }

            Section {
                // 打开 = 运行时切 .accessory，回到原来那个纯菜单栏形态。
                // 默认关（＝显示 Dock 图标）是为上架，理由见 AppSettings.hideDockIcon
                Toggle(T("general.hideDock"), isOn: $settings.hideDockIcon)
                Text(T("general.hideDockHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("general.appearance"))
            }

#if !STARPAPER_APPSTORE
            Section {
                Text(T("general.externalHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("general.external"))
            }
#endif

            Section {
                Button(T("general.privacyPolicy")) {
                    NSWorkspace.shared.open(URL(string:
                        "https://github.com/starsdaisuki/starpaper/blob/main/PRIVACY.md")!)
                }
            } header: {
                Text(T("general.privacy"))
            } footer: {
                Text(T("general.privacyHint"))
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    // MARK: - 播放（列表 + 日程）

    private var playbackTab: some View {
        Form {
            Section {
                Toggle(T("schedule.enable"), isOn: $settings.scheduleEnabled)
                if settings.scheduleEnabled {
                    videoRow(T("schedule.dayVideo"), path: $settings.dayVideoPath)
                    videoRow(T("schedule.nightVideo"), path: $settings.nightVideoPath)
                    DatePicker(T("schedule.dayStart"),
                               selection: minutesBinding($settings.dayStartMinutes),
                               displayedComponents: .hourAndMinute)
                    DatePicker(T("schedule.nightStart"),
                               selection: minutesBinding($settings.nightStartMinutes),
                               displayedComponents: .hourAndMinute)
                    HStack {
                        Text(T("schedule.current"))
                        Spacer()
                        Text(isDaytime ? T("schedule.day") : T("schedule.night"))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(T("tab.schedule"))
            } footer: {
                Text(T("schedule.hint"))
                    .settingsFooter()
            }

            Section {
                if settings.playlist.isEmpty {
                    Text(T("playlist.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    libraryList
                }

                HStack {
                    Button(T("playlist.add")) { addToPlaylist() }
                    Button(T("playlist.remove")) { removeFromLibrary() }
                        .disabled(playlistSelection.isEmpty)
                    Button(T("playlist.clear")) {
                        for path in settings.playlist { thumbnails.forget(path) }
                        settings.playlist.removeAll()
                        playlistSelection.removeAll()
                    }
                    .disabled(settings.playlist.isEmpty)
                    Spacer()
                }

                Toggle(T("playlist.auto"), isOn: $settings.playlistEnabled)
                    .disabled(settings.scheduleEnabled)

                if settings.scheduleEnabled {
                    Text(T("playlist.overridden"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(T("playlist.shuffle"), isOn: $settings.playlistShuffle)
                    .disabled(!autoAdvanceUsable)
                Picker(T("playlist.advance"), selection: $settings.playlistAdvance) {
                    ForEach(AdvanceMode.allCases) { Text($0.localizedLabel).tag($0) }
                }
                .disabled(!autoAdvanceUsable)
                if settings.playlistAdvance == .interval {
                    LabeledSlider(title: T("playlist.every"),
                                  value: $settings.playlistIntervalMinutes,
                                  range: 1...240, defaultValue: 30,
                                  format: { String(format: T("playlist.minutesFmt"), $0) })
                        .disabled(!autoAdvanceUsable)
                }
            } header: {
                Text(T("playlist.section"))
            } footer: {
                Text(T("playlist.hint"))
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    /// 视频库列表。
    ///
    /// ⚠️ 这里**不能用 `List`**：SwiftUI 的 `Form(.formStyle(.grouped))` 本身就是一个 List，
    /// 嵌在里面的 `List` 拿到滚轮事件后既不滚自己也不上抛，库里视频一多就永远看不到下面几个。
    /// 实测（macOS 15.7.4）：内层 `ListCoreScrollView` 装着 797pt 内容、可视区只有 150pt，
    /// 滚轮命中它之后位移恒为 0；换成 `ScrollView` 同一测法位移 320pt。
    /// 所以选中、多选、拖动排序这些原本 List 白送的行为，下面都是手写的。
    private var libraryList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(settings.playlist.enumerated()), id: \.element) { index, path in
                    libraryRow(path, selected: playlistSelection.contains(path))
                        .frame(height: libraryRowHeight)
                        .padding(.horizontal, 8)
                        .background(playlistSelection.contains(path)
                                    ? Color.accentColor : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { clickLibraryRow(path) }
                        .onDrag {
                            draggingPath = path
                            return NSItemProvider(object: path as NSString)
                        }
                        .onDrop(of: [.text],
                                delegate: LibraryReorderDrop(target: path,
                                                             dragging: $draggingPath,
                                                             playlist: $settings.playlist))
                    if index < settings.playlist.count - 1 {
                        Divider().padding(.leading, 64)     // 跟缩略图右边对齐
                    }
                }
            }
        }
        .frame(height: libraryVisibleHeight)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private var libraryRowHeight: CGFloat { 39 }

    /// 少于满屏就贴着内容长，多了就固定住让它自己滚 —— 免得库小时下面留一块空白。
    /// 上限按「整 6 行 + 中间 5 条分隔线」算，不然刚好 6 个视频时会多出 5pt 的假滚动。
    private var libraryVisibleHeight: CGFloat {
        let n = CGFloat(settings.playlist.count)
        let content = n * libraryRowHeight + max(0, n - 1)   // 分隔线也占 1pt
        return min(content, libraryRowHeight * 6 + 5)
    }

    /// 单击 = 选中并立刻播它（库本来就要选中才能删，再要求双击就多一次操作）；
    /// ⌘ 点加选、⇧ 点选一段，这两种是冲着「删掉几个」去的，所以不触发播放。
    private func clickLibraryRow(_ path: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if playlistSelection.contains(path) {
                playlistSelection.remove(path)
            } else {
                playlistSelection.insert(path)
                selectionAnchor = path
            }
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor,
                  let a = settings.playlist.firstIndex(of: anchor),
                  let b = settings.playlist.firstIndex(of: path) {
            playlistSelection = Set(settings.playlist[min(a, b)...max(a, b)])
        } else {
            playlistSelection = [path]
            selectionAnchor = path
            if path != settings.videoPath { playFromLibrary(path) }
        }
    }

    /// 库里的一行：缩略图 + 文件名 + 「正在播」标记。
    private func libraryRow(_ path: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Group {
                if let image = thumbnails.image(for: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 48, height: 27)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            Text((path as NSString).lastPathComponent)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(selected ? Color.white : Color.primary)

            Spacer()

            if path == settings.videoPath {
                Image(systemName: "play.fill")
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .help(T("playlist.nowPlaying"))
            }
        }
        .contentShape(Rectangle())
    }

    /// 点库里的一项 = 立刻播它。跟自动轮播开没开无关。
    private func playFromLibrary(_ path: String) {
        settings.play(path)
        engine?.reloadVideo(force: true)
    }

    private func removeFromLibrary() {
        for path in playlistSelection { thumbnails.forget(path) }
        settings.playlist.removeAll { playlistSelection.contains($0) }
        playlistSelection.removeAll()
    }


    /// 自动轮播那几个选项此刻有没有意义：日程盖过它，库里少于两个也没得轮。
    private var autoAdvanceUsable: Bool {
        settings.playlistEnabled && !settings.scheduleEnabled && settings.playlist.count > 1
    }

    private var isDaytime: Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let ds = settings.dayStartMinutes, ns = settings.nightStartMinutes
        if ds == ns { return true }
        return ds < ns ? (m >= ds && m < ns) : !(m >= ns && m < ds)
    }

    /// 「当天几点几分」跟 DatePicker 之间的桥。只取时分，日期部分固定不用。
    private func minutesBinding(_ source: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                let base = Calendar.current.startOfDay(for: Date())
                return base.addingTimeInterval(TimeInterval(source.wrappedValue * 60))
            },
            set: { newDate in
                let c = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                source.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    private func videoRow(_ label: String, path: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(path.wrappedValue.isEmpty
                 ? T("content.none")
                 : (path.wrappedValue as NSString).lastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .trailing)
            Button(T("schedule.choose")) {
                if let picked = runVideoPanel(multiple: false).first {
                    path.wrappedValue = picked
                }
            }
        }
    }

    private func addToPlaylist() {
        let picked = runVideoPanel(multiple: true)
        guard !picked.isEmpty else { return }
        for p in picked where !settings.playlist.contains(p) {
            settings.playlist.append(p)
        }
        // 之前什么都没播（比如刚装上）：添加完直接播第一个，
        // 不然界面上多了一列视频，桌面还是空的
        if settings.videoPath.isEmpty, let first = picked.first {
            playFromLibrary(first)
        }
    }

    private func runVideoPanel(multiple: Bool) -> [String] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = T("panel.message")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(MediaAccess.remember)
    }

    // MARK: - 快捷键

    private var hotkeyTab: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action)
                }
            } header: {
                Text(T("hotkey.section"))
            } footer: {
                Text(T("hotkey.hint"))
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 选文件

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = T("panel.message")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.play(MediaAccess.remember(url)) // 顺手进库，见 AppSettings.play
            engine?.reloadVideo(force: true)
        }
    }
}

// MARK: - 视频库拖动排序

/// 拖着某一行经过另一行时就地换位（`List.onMove` 的手写版）。
/// 拖过就换、松手只是收尾，所以拖动过程中就能看到最终顺序。
private struct LibraryReorderDrop: DropDelegate {
    let target: String
    @Binding var dragging: String?
    @Binding var playlist: [String]

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = playlist.firstIndex(of: dragging),
              let to = playlist.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            playlist.move(fromOffsets: IndexSet(integer: from),
                          toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - 裁剪取景器

/// 拖框选构图。框的宽高比 = 显示器宽高比，所以框住什么最后就看到什么。
///
/// 存的不是「一个裁剪矩形」而是「焦点 + 缩放」—— 这样换一块比例不同的显示器，
/// 同一套参数还能算出合理的裁剪区，不用为每块屏各存一份。
private struct CropPicker: View {
    @ObservedObject var settings = AppSettings.shared
    let poster: NSImage
    let videoSize: CGSize
    let screenAspect: CGFloat

    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let box = geometry(in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: poster)
                    .resizable()
                    .frame(width: box.imageW, height: box.imageH)
                    .offset(x: box.imageX, y: box.imageY)

                // 框外压暗
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: box.imageW, height: box.imageH)
                    .offset(x: box.imageX, y: box.imageY)
                    .overlay(alignment: .topLeading) {
                        Rectangle()
                            .frame(width: box.rectW, height: box.rectH)
                            .offset(x: box.rectX - box.imageX, y: box.rectY - box.imageY)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Rectangle().fill(Color.white.opacity(0.001)))
                    .frame(width: box.rectW, height: box.rectH)
                    .offset(x: box.rectX, y: box.rectY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragOrigin == nil {
                                    dragOrigin = CGPoint(x: settings.focusX, y: settings.focusY)
                                }
                                guard let start = dragOrigin else { return }
                                let spanX = box.imageW - box.rectW
                                let spanY = box.imageH - box.rectH
                                if spanX > 0.5 {
                                    settings.focusX = clamp(start.x + value.translation.width / spanX)
                                }
                                if spanY > 0.5 {
                                    settings.focusY = clamp(start.y + value.translation.height / spanY)
                                }
                            }
                            .onEnded { _ in dragOrigin = nil }
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(videoSize.width / videoSize.height, contentMode: .fit)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private struct Geo {
        var imageX: CGFloat, imageY: CGFloat, imageW: CGFloat, imageH: CGFloat
        var rectX: CGFloat, rectY: CGFloat, rectW: CGFloat, rectH: CGFloat
    }

    private func geometry(in container: CGSize) -> Geo {
        let videoAspect = videoSize.width / videoSize.height

        // 预览图按 aspect fit 摆进容器
        var iw = container.width
        var ih = iw / videoAspect
        if ih > container.height {
            ih = container.height
            iw = ih * videoAspect
        }
        let ix = (container.width - iw) / 2
        let iy = (container.height - ih) / 2

        // 取景框的归一化尺寸 —— 跟 VideoWallpaperView 的裁剪几何是同一套公式
        var fracW: CGFloat = 1, fracH: CGFloat = 1
        if screenAspect >= videoAspect {
            fracH = videoAspect / screenAspect      // 屏比视频更宽 → 宽度用满，切上下
        } else {
            fracW = screenAspect / videoAspect      // 屏比视频更窄 → 高度用满，切左右
        }
        let z = CGFloat(settings.zoom)
        fracW = min(fracW / z, 1)
        fracH = min(fracH / z, 1)

        let rw = iw * fracW
        let rh = ih * fracH
        return Geo(
            imageX: ix, imageY: iy, imageW: iw, imageH: ih,
            rectX: ix + CGFloat(settings.focusX) * (iw - rw),
            rectY: iy + CGFloat(settings.focusY) * (ih - rh),
            rectW: rw, rectH: rh
        )
    }
}

// MARK: - 页脚文字

private extension View {
    /// Section 页脚里说明文字的统一样式。
    ///
    /// ⚠️ **`multilineTextAlignment` 和 `frame(maxWidth:)` 少一个都不行。**
    /// macOS 的 `Form(.formStyle(.grouped))` 把 Section 页脚放进「值」那一列的排版环境，
    /// 里面的 `Text` 于是默认**右对齐** —— 多行时右端齐、左端参差，最后一行贴着右边，
    /// 读起来就像排版坏了。只加 `multilineTextAlignment(.leading)` 也不够：
    /// 文字块本身仍然靠右摆，得再用 `maxWidth: .infinity` 把容器撑满、按 leading 落位。
    ///
    /// 2026-08-31 由用户截图发现；在那之前所有页脚都是右对齐的。
    func settingsFooter() -> some View {
        self
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 滑杆

/// 带数值显示的滑杆。双击标签复位到默认值 —— 调坏了不用记原值是多少。
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double?
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 72, alignment: .leading)
                .onTapGesture(count: 2) {
                    if let d = defaultValue { value = d }
                }
            Slider(value: $value, in: range)
            Text(format(value))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isDefault ? .secondary : .primary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private var isDefault: Bool {
        guard let d = defaultValue else { return true }
        return abs(value - d) < 0.0001
    }
}

// MARK: - 快捷键录制行

/// 点一下开始录，按下组合键就存。
///
/// 用 NSEvent 的**局部**监听（只在本 app 有焦点时收事件），不是全局监听 ——
/// 录制阶段不需要全局权限。真正的全局触发在 HotkeyManager 里走 Carbon，同样免权限。
private struct HotkeyRow: View {
    @ObservedObject var settings = AppSettings.shared
    let action: HotkeyAction

    @State private var recording = false
    @State private var monitor: Any?
    @State private var warning: String?

    private var current: HotkeySpec? { settings.hotkeys[action.rawValue] }

    var body: some View {
        HStack {
            Text(action.localizedLabel)
            Spacer()
            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Button(buttonTitle) {
                recording ? stopRecording() : startRecording()
            }
            .frame(minWidth: 130)
            .buttonStyle(.bordered)

            Button(T("hotkey.clear")) {
                settings.hotkeys[action.rawValue] = nil
                warning = nil
            }
            .disabled(current == nil)
        }
        .onDisappear { stopRecording() }
    }

    private var buttonTitle: String {
        if recording { return T("hotkey.recording") }
        return current?.displayString ?? T("hotkey.record")
    }

    private func startRecording() {
        warning = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil          // 吞掉事件，别让它跑去触发别的东西
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Esc 取消
        if event.keyCode == 53, HotkeySpec.cleanModifiers(event.modifierFlags) == 0 {
            stopRecording()
            return
        }
        let mods = HotkeySpec.cleanModifiers(event.modifierFlags)
        guard HotkeySpec.isValid(keyCode: event.keyCode, modifiers: mods) else {
            warning = T("hotkey.needsMod")
            return
        }
        settings.hotkeys[action.rawValue] = HotkeySpec(keyCode: event.keyCode, modifiers: mods)
        warning = nil
        stopRecording()
    }
}
