import Foundation

/// 首次启动时的内置 demo。只在用户没有可用的日程、当前视频或视频库时兜底；
/// 不写入设置，也不会把它混进用户的播放列表。
enum BuiltInMedia {
    static let defaultVideoName = "blackhole-demo"
    static let defaultVideoExtension = "mp4"

    static var defaultVideoPath: String {
        Bundle.main.url(forResource: defaultVideoName,
                        withExtension: defaultVideoExtension)?.path ?? ""
    }
}
