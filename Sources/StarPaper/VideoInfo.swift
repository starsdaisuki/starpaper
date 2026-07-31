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
        guard !path.isEmpty else { return nil }
        return await naturalSize(of: AVURLAsset(url: URL(fileURLWithPath: path)))
    }

    /// 取一帧当裁剪预览。取 20% 处而不是第 0 帧 —— 很多视频开头是黑场或淡入。
    static func posterFrame(ofFileAt path: String, maxWidth: CGFloat = 900) async -> NSImage? {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
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
