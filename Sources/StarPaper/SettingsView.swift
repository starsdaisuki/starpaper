import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    var engine: WallpaperEngine?

    @State private var poster: NSImage?
    @State private var videoSize: CGSize = .zero
    @State private var playlistSelection: Set<String> = []
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        TabView {
            contentTab.tabItem { Label(T("tab.content"), systemImage: "film") }
            cropTab.tabItem { Label(T("tab.crop"), systemImage: "crop") }
            imageTab.tabItem { Label(T("tab.image"), systemImage: "slider.horizontal.3") }
            playbackTab.tabItem { Label(T("tab.playback"), systemImage: "list.and.film") }
            audioTab.tabItem { Label(T("tab.audio"), systemImage: "speaker.wave.2") }
            powerTab.tabItem { Label(T("tab.power"), systemImage: "bolt") }
            hotkeyTab.tabItem { Label(T("tab.hotkeys"), systemImage: "command") }
            generalTab.tabItem { Label(T("tab.general"), systemImage: "gearshape") }
        }
        .frame(width: 620, height: 540)
        .padding(.top, 8)
        .task(id: settings.videoPath) { await loadPreview() }
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
            }

            Section {
                Picker(T("content.scale"), selection: $settings.scaleMode) {
                    ForEach(ScaleMode.allCases) { Text($0.localizedLabel).tag($0) }
                }
                Picker(T("content.iconLayer"), selection: $settings.iconLayer) {
                    ForEach(IconLayerMode.allCases) { Text($0.localizedLabel).tag($0) }
                }
                LabeledSlider(title: T("content.speed"), value: $settings.playbackRate,
                              range: 0.25...2.0, defaultValue: 1.0,
                              format: { String(format: "%.2fx", $0) })
            } header: {
                Text(T("content.display"))
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
                    .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .font(.caption).foregroundStyle(.secondary)
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
                Text(T("general.externalHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(T("general.external"))
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
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(T("playlist.enable"), isOn: $settings.playlistEnabled)
                    .disabled(settings.scheduleEnabled)

                if settings.scheduleEnabled {
                    Text(T("playlist.overridden"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if settings.playlist.isEmpty {
                    Text(T("playlist.empty"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    List(selection: $playlistSelection) {
                        ForEach(settings.playlist, id: \.self) { path in
                            Text((path as NSString).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                                .tag(path)
                        }
                        .onMove { from, to in
                            settings.playlist.move(fromOffsets: from, toOffset: to)
                        }
                    }
                    .frame(height: 110)
                }

                HStack {
                    Button(T("playlist.add")) { addToPlaylist() }
                    Button(T("playlist.remove")) {
                        settings.playlist.removeAll { playlistSelection.contains($0) }
                        playlistSelection.removeAll()
                    }
                    .disabled(playlistSelection.isEmpty)
                    Button(T("playlist.clear")) { settings.playlist.removeAll() }
                        .disabled(settings.playlist.isEmpty)
                    Spacer()
                }

                Toggle(T("playlist.shuffle"), isOn: $settings.playlistShuffle)
                Picker(T("playlist.advance"), selection: $settings.playlistAdvance) {
                    ForEach(AdvanceMode.allCases) { Text($0.localizedLabel).tag($0) }
                }
                if settings.playlistAdvance == .interval {
                    LabeledSlider(title: T("playlist.every"),
                                  value: $settings.playlistIntervalMinutes,
                                  range: 1...240, defaultValue: 30,
                                  format: { String(format: T("playlist.minutesFmt"), $0) })
                }
            } header: {
                Text(T("playlist.section"))
            }
        }
        .formStyle(.grouped)
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
        return panel.urls.map(\.path)
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
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            settings.videoPath = url.path
            settings.save()
            engine?.reloadVideo(force: true)
        }
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
