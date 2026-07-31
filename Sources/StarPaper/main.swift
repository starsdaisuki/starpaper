import AppKit

// 用显式 NSApplication 启动而不是 @main SwiftUI App：
// SwiftPM 手工组 bundle 时这条路最稳，Info.plist 直接放 bundle 里就生效。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
