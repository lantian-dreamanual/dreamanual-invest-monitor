import Foundation

/// 数据时效：把「行情自身时间」翻译成界面上的「截至 MM-DD HH:mm」与陈旧提示
///
/// 两条判据，缺一不可：
///   · 时间戳取自**行情源**（f124 / PDATE），不取抓取时刻 —— 抓取时刻永远显示「刚刚」，
///     分不清「数据没变」和「根本没拿到」
///   · 只在**交易时段内**判陈旧 —— 周末看到上周五的盘面是常态，一律转红等于天天误报
enum DataFreshness {
    /// 陈旧阈值：10 分钟
    static let staleAfter: TimeInterval = 600

    struct Display {
        let text: String
        let isStale: Bool
    }

    static func isStale(_ quoteAt: Date?, now: Date = Date()) -> Bool {
        guard let at = quoteAt else { return true }
        return now.timeIntervalSince(at) > staleAfter
    }

    /// 生成展示串
    ///
    /// - 拿不到行情时间且处于交易时段 → 「无行情时间」（转橙）
    /// - 非交易时段 → 只给「截至 MM-DD HH:mm」，不判陈旧
    /// - 交易时段超阈值 → 追加「· 数据延迟 N 分钟」并转橙
    static func display(quoteAt: Date?, status: MarketStatus, now: Date = Date()) -> Display? {
        let inSession = (status == .trading || status == .delayed)
        guard let at = quoteAt else {
            return inSession ? Display(text: "行情时间缺失", isStale: true) : nil
        }
        let stamp = Self.stamp(at)
        guard inSession else { return Display(text: "截至 \(stamp)", isStale: false) }
        let lag = now.timeIntervalSince(at)
        guard lag > staleAfter else { return Display(text: "截至 \(stamp)", isStale: false) }
        return Display(text: "截至 \(stamp) · 数据延迟 \(Int(lag / 60)) 分钟", isStale: true)
    }

    /// 净值日期（只有 YYYY-MM-DD，无时刻）→ 「净值 09-21」
    static func shortDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3 else { return ymd }
        return "\(parts[1])-\(parts[2])"
    }

    private static let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = MarketClock.shanghai
        return f
    }()

    static func stamp(_ d: Date) -> String { stampFmt.string(from: d) }
}
