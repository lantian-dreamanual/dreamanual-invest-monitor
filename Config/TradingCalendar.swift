import Foundation

/// A 股交易日历（上交所口径）
///
/// 数据来源：上证公告〔2025〕45 号《关于上海证券交易所 2026 年部分节假日休市安排的通知》
/// （2025-12-22 发布）。2027 年安排通常于当年 12 月发布，公布前不预填 —— 编造日期
/// 比不判断更糟：一个错的「休市」会让那天整天不刷新。
///
/// 表外的日期按「周一~周五」降级。2026 年公告未涉及调休上班（公告里 1/4、2/14、2/28、
/// 5/9、9/20、10/10 全部注明「为周末休市」），因此表里只有休市日，没有「周末开市」条目。
enum TradingCalendar {

    /// 公告覆盖的最后一天。设置页展示它，超期后由用户在下一份公告发布时更新。
    static let coveredUntil = "2026-12-31"

    /// 覆盖范围内的休市日（仅列非周末的工作日；周末由 weekday 判定承担）
    private static let holidays: Set<String> = [
        // 元旦：1/1（四）–1/3（六）
        "2026-01-01", "2026-01-02",
        // 春节：2/15（日）–2/23（一）
        "2026-02-16", "2026-02-17", "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-23",
        // 清明节：4/4（六）–4/6（一）
        "2026-04-06",
        // 劳动节：5/1（五）–5/5（二）
        "2026-05-01", "2026-05-04", "2026-05-05",
        // 端午节：6/19（五）–6/21（日）
        "2026-06-19",
        // 中秋节：9/25（五）–9/27（日）
        "2026-09-25",
        // 国庆节：10/1（四）–10/7（三）
        "2026-10-01", "2026-10-02", "2026-10-05", "2026-10-06", "2026-10-07",
    ]

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = MarketClock.shanghai
        return f
    }()

    /// 该日 YYYY-MM-DD 是否交易日
    static func isTradingDay(_ ymd: String) -> Bool {
        guard let d = fmt.date(from: ymd) else { return false }
        // 周末
        let wd = Calendar(identifier: .gregorian).component(.weekday, from: d)
        guard wd != 1 && wd != 7 else { return false }
        return !holidays.contains(ymd)
    }

    static func isTradingDay(_ date: Date) -> Bool {
        isTradingDay(fmt.string(from: date))
    }

    /// 今天是否交易日
    static func isTradingDay() -> Bool { isTradingDay(Date()) }
}
