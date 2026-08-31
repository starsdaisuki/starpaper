import AVFoundation
import AppKit

/// 视频元信息 + 预览帧。裁剪 UI 和裁剪几何都要用。
enum VideoInfo {

    /// 视频显示尺寸。注意要套 preferredTransform —— 手机竖拍的视频 naturalSize 是横的，
    /// 只有乘上变换矩阵才是实际显示出来的宽高。
    static func naturalSize(of asset: AVAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let displayed = natural.applying(transform)
        let size = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        return (size.width > 1 && size.height > 1) ? size : natural
    }

    static func naturalSize(ofFileAt path: String) async -> CGSize? {
        guard let lease = MediaAccess.acquire(path: path) else { return nil }
        defer { withExtendedLifetime(lease) {} }
        return await naturalSize(of: AVURLAsset(url: lease.url))
    }

    /// 取一帧当裁剪预览。取 20% 处而不是第 0 帧 —— 很多视频开头是黑场或淡入。
    static func posterFrame(ofFileAt path: String, maxWidth: CGFloat = 900) async -> NSImage? {
        guard let lease = MediaAccess.acquire(path: path) else { return nil }
        defer { withExtendedLifetime(lease) {} }
        let asset = AVURLAsset(url: lease.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let duration = (try? await asset.load(.duration)) ?? .zero
        let seconds = duration.isNumeric ? duration.seconds * 0.2 : 0
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)

        guard let (cg, _) = try? await generator.image(at: time) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

/// 视频库列表里那些小缩略图。
///
/// 单独一个 store 而不是每行自己 `.task` 抓帧：SwiftUI 的 List 会因为任何一个
/// 无关开关重建行视图，每次都去解一帧的话，切个「随机顺序」整列表都要闪一下。
/// 抓到的帧按路径缓存，一个视频这辈子只解一次。
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    @Published private(set) var images: [String: NSImage] = [:]
    /// 路径 → 这一次请求的代次。删除库项时撤销代次，旧任务回来就不能把图塞回缓存。
    private var inFlight: [String: UUID] = [:]

    func image(for path: String) -> NSImage? {
        if let hit = images[path] { return hit }
        guard inFlight[path] == nil else { return nil }
        let requestID = UUID()
        inFlight[path] = requestID
        Task { @MainActor in
            defer {
                if inFlight[path] == requestID { inFlight[path] = nil }
            }
            // 96 宽够 48pt @2x 了，再大就是白解码
            guard let img = await VideoInfo.posterFrame(ofFileAt: path, maxWidth: 160) else { return }
            guard inFlight[path] == requestID else { return }
            images[path] = img
        }
        return nil
    }

    /// 视频被移出库时顺手扔掉，免得改一次列表就多留一份位图
    func forget(_ path: String) {
        inFlight[path] = nil
        images.removeValue(forKey: path)
    }
}
