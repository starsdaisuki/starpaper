# 桌面、显示器与遮挡 —— 哪些信号能信，哪些不能

这个项目里难缠的 bug 基本都不是逻辑写错，而是**用错了判据**：macOS 提供了好几种
方式回答「用户此刻看不看得见壁纸」，每一种都只在很窄的范围内成立。选错那一个，
你会得到一个看起来正确、测试全绿、真机全错的实现。

动播放、遮挡、音频门或每桌面窗口之前，先读这份。

## 1. 判据可信度表

| 信号 | 能信吗 | 说明 |
|---|---|---|
| `window.occlusionState`（**每桌面一扇**窗） | ✅ | 每个桌面有真实窗，系统会真的合成它 |
| `window.occlusionState`（**单扇 sticky** 窗） | ❌ | 切 Space 后会卡在「不可见」**约 16 秒**，见 §3 |
| 拿 `occlusionState` 当「人回到桌面了」 | ❌ | 它**故意提前约 0.9 秒**翻转 —— 画面需要这个提前量 |
| 「窗口尺寸 == 屏幕尺寸」⇒ 全屏窗 | ❌ | 没有一个真实全屏窗满足，见 §2 |
| `CGSCopyManagedDisplaySpaces` 的当前 Space 类型 | ✅ | `type == 0` 桌面、`type == 4` 全屏 app。**唯一可靠的答案** |
| sticky 窗的 `isOnActiveSpace` | ❌ | 恒为 `true` —— 它按定义就跟着人跑 |
| 用 `NSEvent` 全局 `.scrollWheel` / `.swipe` 捕获四指切 Space | ❌ | 手势被 WindowServer 直接吃掉，app 收不到 |
| 任何固定时长的兜底 | ❌ | 交互式手势可以悬停**任意久**，见 §4 |

这个项目里最有用的一行代码：

```swift
SpaceBridge.currentSpaceIsDesktop()   // Bool?，私有 API 不可用时返回 nil
```

`nil` 是「不知道」，**永远不要当成 `false`**。

## 2. 真实全屏窗根本不等于屏幕尺寸

某台机器实测，屏幕 `1512×982`：

| 全屏 app | 主窗 bounds | 尺寸相等判据 |
|---|---|---|
| Finder | `1512×945 @0,37` | ❌ 认不出 |
| Ghostty | `1512×907 @0,75` | ❌ 认不出 |
| Google Chrome | `1512×857 @0,125` | ❌ 认不出 |

带标题栏或标签栏的 app 会把那部分拆成**独立的 layer-0 窗口**，主窗只剩下面那块。
TextEdit 和「系统设置」恰好铺满整屏 —— 所以一条只拿它们验过的判据能通过复核，
然后在用户真正使用的每一个 app 上失败。

⚠️ 没有私有 API 时的近似判据用「宽度铺满 **且** 高度 ≥ 屏幕的 80%」
（`ForegroundCoverage.covers`）。另外记住 **Dock 常驻一扇 `1512×982` 的 layer-0
整屏窗** —— 「屏上有整屏窗就压住壁纸」这种天真写法会让 app 永远不出声。

## 3. sticky 窗的遮挡状态在切 Space 后会卡死

单扇窗模式下，在两个**相邻的普通桌面**之间按一次 `⌃→`：

```
00:03:55.271  遮挡=Y 停      切换一开始就被标成不可见
00:04:11.599  遮挡=N 播      16.3 秒后才翻回来，还是被下一次切换带回来的
```

转换过程中，sticky 窗整扇被换成系统的静态壁纸快照。真窗从未被合成，
所以系统如实报告「不可见」—— 而用户正盯着壁纸看。

**去抖救不了这个。** 阈值要设到 16 秒以上，那等于把「遮挡时暂停」关掉。
正确做法是换一个信号做二次确认（`SpaceStrategy.stickyOccluded`），
而且只在系统声称不可见时才确认，正常播放路径零开销。

每桌面一扇窗的模式免疫：每个桌面都有真实窗，不走快照替换。

## 4. 反复出现的三种形状

**a. 判据被复用了，语义没有被复用。**
`occlusionState` 故意提前，是为了让**画面**恢复时不卡顿；音频跟着它走就变成划一下响一声。
`isOnActiveSpace` 对每桌面窗有意义、对 sticky 窗恒为真；一个公式吃两种模式，
必然无声地弄坏其中一种。**同一个字段在两种模式下含义不同时，下游不能共用公式。**

**b. 任何固定时长都会被跨过去。**
三版兜底连续失败 —— 0.7 秒、2 秒、0.5 秒 —— 因为交互式手势想悬停多久就多久。
超时只是把「现在响」变成「等会儿响」。写下「等 X 秒就放行」之前，
先问用户能不能让这个状态持续 X+1 秒。

**c. 恰好挑中唯一能通过的样本，比没有测试更糟。**
尺寸相等那条判据是拿 TextEdit 验的，自检里还有一条断言
`1512×907 不算全屏` —— 而 907 正是 Ghostty 全屏窗的真实高度。
这条测试不只是漏掉了 bug，它**把 bug 认证成了正确行为**。

另外：只会「开」的闸门，迟早会永远开着。这里的状态机必须能重新关上。

## 5. 调试手册

**开日志**（默认关闭，关闭时零开销）：

```bash
STARPAPER_DEBUGLOG=1 open -n ~/Applications/StarPaper.app
tail -f ~/Library/Logs/StarPaper.log
```

每次 `updatePlayback` 会打印完整决策：放置方式、窗数、每扇窗的播/停及其判据、
音频门状态、以及 Space 检查返回了什么。

**看窗口真相**，用仓库自带的探针：

```bash
swiftc -O tools/space-probe.swift -o /tmp/space-probe && /tmp/space-probe
```

每 120 ms 打印：前台 app、`ForegroundCoverage` 如何分类它、屏上所有整屏尺寸的窗。

**凭空造显示器** —— 不需要硬件。Apple 芯片笔记本最多外接 2 台（Max 芯片 4 台），
但虚拟屏是免费的：

```bash
betterdisplaycli create --type=VirtualScreen --virtualScreenName=Test1
betterdisplaycli set --name=Test1 --connected=on     # 必须，只 create 系统看不见
betterdisplaycli set --name=Test1 --connected=off
betterdisplaycli discard --name=Test1                # discard 千万别不带 --name
```

**读 Space 布局**（类型、顺序、每个全屏 Space 属于哪个 app）：

```bash
plutil -convert json -o - ~/Library/Preferences/com.apple.spaces.plist
```

⚠️ 这个文件是**滞后缓存**；要实时答案就调 `CGSCopyManagedDisplaySpaces`
（`SpaceBridge` 就是这么做的）。

## 6. 花过时间的坑

- **`⌃←/→` 不等价于触控板手势。** 开着「减弱动态效果」时它是瞬时淡入淡出、
  **没有中间态**，复现不了任何需要「转换到一半」的问题。只有真手势能悬停在中途，
  而它无法被合成 —— WindowServer 把它吃掉了。
- **两份偏好设置文件。** 如果沙盒变体曾经跑过，`defaults read/write` 可能命中
  `~/Library/Containers/<bundle-id>/Data/Library/Preferences/`，而普通构建读的是
  `~/Library/Preferences/`。两份会无声地漂移。查设置用 `plutil -p` 读外层那份，
  或者直接信调试日志的抬头。
- **app 运行时写 defaults 会被覆盖** —— app 退出时会把自己内存里那份刷回去。
  要先退出、再写、再启动。
- **验证正在跑的二进制，而不是安装的文件。** 下结论说「没修好」之前，
  先比对 `ps -Ao pid,lstart` 与二进制的 mtime。
- **偏好设置落盘会晚几秒。** 刚改完设置时 `plutil -p` 可能还是旧值，以调试日志为准。
- **UI 的启用/禁用必须跟着「解析后的状态」走，而不是「用户选的那一档」。**
  只要放置方式解析成单扇跟随，叠窗层数就被强制成 1 —— 包括「自动」档在
  Reduce Motion 关着的时候。只按 `mode == .off` 来禁用，会留给用户一个改了没反应的控件。
