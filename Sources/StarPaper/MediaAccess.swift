import Foundation

/// 本地媒体的持久访问层。
///
/// `NSOpenPanel` 只给当前进程临时的沙盒扩展；要在重启、登录自启和
/// 定时换片后继续读视频，必须保存 security-scoped bookmark。
enum MediaAccess {

    /// 一次正在使用的沙盒授权。AVAsset 会惰性读文件，所以 lease 必须比
    /// asset / player 活得久，不能在创建 URL 后立刻 stop。
    final class Lease {
        let url: URL
        private let scoped: Bool

        fileprivate init(url: URL, scoped: Bool) {
            self.url = url
            self.scoped = scoped
        }

        deinit {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// 记住用户刚在系统选择器中授权的 URL，对非沙盒直装版也是无害的。
    @discardableResult
    static func remember(_ url: URL) -> String {
        let normalized = url.standardizedFileURL
        do {
            let data = try normalized.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            AppSettings.shared.rememberMediaBookmark(data, forPath: normalized.path)
        } catch {
            let e = error as NSError
            NSLog("[StarPaper] 无法保存媒体授权：%@(%ld)", e.domain, e.code)
        }
        return normalized.path
    }

    /// 解析并开启访问；调用方持有返回值的整个期间都有权读文件。
    static func acquire(path: String) -> Lease? {
        guard !path.isEmpty else { return nil }

        if let data = AppSettings.shared.mediaBookmark(forPath: path) {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                let scoped = url.startAccessingSecurityScopedResource()
                guard FileManager.default.fileExists(atPath: url.path) else {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    return nil
                }
                if stale {
                    do {
                        let refreshed = try url.bookmarkData(
                            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        AppSettings.shared.rememberMediaBookmark(refreshed, forPath: path)
                    } catch {
                        let e = error as NSError
                        NSLog("[StarPaper] 无法刷新媒体授权：%@(%ld)", e.domain, e.code)
                    }
                }
                return Lease(url: url, scoped: scoped)
            } catch {
                let e = error as NSError
                NSLog("[StarPaper] 无法解析媒体授权：%@(%ld)", e.domain, e.code)
            }
        }

        // 直装版、app 容器内文件，以及还在当次 OpenPanel 临时授权里的文件。
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Lease(url: url, scoped: false)
    }

    static func isUsable(path: String) -> Bool {
        acquire(path: path) != nil
    }
}
