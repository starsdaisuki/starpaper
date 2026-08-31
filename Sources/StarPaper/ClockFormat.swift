import Foundation

/// 时钟格式字符串的解析器。
///
/// 采用和多数动态壁纸编辑器一致的 token 写法，方便直接照抄壁纸原作者写的格式：
///
/// | token | 含义 | 例 |
/// |---|---|---|
/// | `yyyy` / `yy` | 年（四位 / 后两位） | `2026` / `26` |
/// | `MM` | 月，补零 | `08` |
/// | `dd` | 日，补零 | `22` |
/// | `HH` | 时，24 小时制补零 | `00` |
/// | `hh` | 时，12 小时制 | `12` |
/// | `mm` | 分，补零 | `41` |
/// | `ss` | 秒，补零 | `07` |
/// | `[W]` | 星期几 | `周五` / `Fri` |
/// | `[P]` | 时间段 | `凌晨` / `Night` |
///
/// 不匹配任何 token 的字符原样输出，所以 `MM|dd [W]` 里的 `|` 和空格都会保留。
///
/// ⚠️ 匹配顺序要紧：`yyyy` 必须排在 `yy` 前面，`HH` 和 `hh` 大小写敏感 ——
/// 否则 `yyyy` 会被拆成两个 `yy`。下面的表是按长度降序写的，不要随手重排。
enum ClockFormat {

    /// 各时间段的起始小时。来自壁纸编辑器常见的 `0~5 / 6~11 / 12~15 / 16~23` 划分。
    private static let periodStarts = [0, 6, 12, 16]

    private static func weekdayName(_ i: Int, zh: Bool) -> String {
        // i: 1 = 周日 … 7 = 周六（Calendar 的 weekday 约定）
        let z = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let e = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let idx = max(0, min(6, i - 1))
        return zh ? z[idx] : e[idx]
    }

    private static func periodName(_ hour: Int, zh: Bool) -> String {
        let z = ["凌晨", "上午", "下午", "晚上"]
        let e = ["Night", "Morning", "Afternoon", "Evening"]
        var idx = 0
        for (i, start) in periodStarts.enumerated() where hour >= start { idx = i }
        return zh ? z[idx] : e[idx]
    }

    /// 把格式字符串渲染成当前时刻的文本。
    ///
    /// `zh` 决定 `[W]` / `[P]` 用中文还是英文；数字部分不受影响，
    /// 因为 12 小时制和补零在两种语言下写法相同。
    static func render(_ format: String, at date: Date, calendar: Calendar = .current,
                       zh: Bool) -> String {
        guard !format.isEmpty else { return "" }
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let year = c.year ?? 0, hour24 = c.hour ?? 0
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

        // 长 token 在前，避免 yyyy 被 yy 抢先吃掉
        let table: [(String, String)] = [
            ("yyyy", String(format: "%04d", year)),
            ("yy",   pad(year % 100)),
            ("MM",   pad(c.month ?? 0)),
            ("dd",   pad(c.day ?? 0)),
            ("HH",   pad(hour24)),
            ("hh",   String(hour24 % 12 == 0 ? 12 : hour24 % 12)),
            ("mm",   pad(c.minute ?? 0)),
            ("ss",   pad(c.second ?? 0)),
            ("[W]",  weekdayName(c.weekday ?? 1, zh: zh)),
            ("[P]",  periodName(hour24, zh: zh)),
        ]

        var out = ""
        var i = format.startIndex
        outer: while i < format.endIndex {
            for (token, value) in table {
                if format[i...].hasPrefix(token) {
                    out += value
                    i = format.index(i, offsetBy: token.count)
                    continue outer
                }
            }
            // 不匹配就原样搬运，包括 `|`、空格、冒号和任何标点
            out.append(format[i])
            i = format.index(after: i)
        }
        return out
    }

    /// 这个格式渲染出来的文本会不会随秒变化。
    ///
    /// 只含到分钟的格式每分钟才变一次，用它可以让刷新判重更省 —— 不过实际重绘
    /// 由文本比对决定，这里只是给调用方一个提示。
    static func needsSecondTick(_ format: String) -> Bool {
        format.contains("ss")
    }
}
