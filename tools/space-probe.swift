// 采样 Space 转换过程中的窗口真相：前台 app 是谁、屏上有没有覆盖整屏的窗。
// 用途：验证 ForegroundCoverage 只看 frontmostApplication 是否够用。
import AppKit
import CoreGraphics

let screens = NSScreen.screens.map(\.frame.size)
let fmt = DateFormatter()
fmt.dateFormat = "HH:mm:ss.SSS"

func matches(_ w: CGSize, _ d: CGSize) -> Bool {
    abs(w.width - d.width) <= 2 && abs(w.height - d.height) <= 2
}

while true {
    let front = NSWorkspace.shared.frontmostApplication
    let pid = front?.processIdentifier ?? -1
    let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                          kCGNullWindowID) as? [[String: Any]] ?? []
    var frontKind = "none"
    var fullScreenOwners: [String] = []
    for row in rows {
        guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let dict = row[kCGWindowBounds as String] as? NSDictionary,
              let b = CGRect(dictionaryRepresentation: dict) else { continue }
        let owner = (row[kCGWindowOwnerName as String] as? String) ?? "?"
        let isFull = screens.contains { matches(b.size, $0) }
        let ownerPID = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
        if ownerPID == pid {
            if isFull { frontKind = "fullScreen" }
            else if frontKind == "none" { frontKind = "windowed" }
        }
        if isFull {
            fullScreenOwners.append("\(owner)@\(Int(b.origin.x)),\(Int(b.origin.y))")
        }
    }
    print("\(fmt.string(from: Date()))  前台=\(front?.localizedName ?? "?") "
        + "frontmostWindowKind=\(frontKind)  屏上整屏窗=[\(fullScreenOwners.joined(separator: " "))]")
    fflush(stdout)
    usleep(120_000)
}
