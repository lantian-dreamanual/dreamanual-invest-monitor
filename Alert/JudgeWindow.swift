import Foundation

/// 判定时点闸门：判定价**最早什么时候可信**、**晚到什么时候就不该再算**
///
/// ⚠️ 下界不可省。没有它，黄金会拿夜盘 02:30 的读数当「今日收盘价」判定 ——
/// pdate 在同一天内不变，但那个价不是收盘价，违反「只取日盘收盘」。
/// ⚠️ 上界同样不可省。21:00 起沪金进入夜盘，此后 f124 仍是当天，数字却已经是夜盘价；
/// 拿它判会凭空造出一次穿越，而且比漏判更糟 —— 用户看到一个不存在的收盘价。
enum JudgeWindow {
    /// 场内（黄金 / 板块）：日盘已收，此刻的读数 = 收盘价
    static let quoteMinute = 15 * 60 + 35
    /// 场内窗口上界：21:00 起沪金进入夜盘
    static let quoteCloseMinute = 21 * 60
    /// 场外基金：净值 19:00 起陆续披露，早于这个点去看只会拿到昨天的 PDATE
    static let fundMinute = 20 * 60 + 30

    private static func minutes(_ now: Date, _ cal: Calendar) -> Int {
        cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
    }

    /// 场内判定窗口 `[15:35, 21:00)`
    static func quoteJudicable(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let m = minutes(now, calendar)
        return m >= quoteMinute && m < quoteCloseMinute
    }

    /// 场外基金：20:30 之后（净值当天什么时候披露完都算当日）
    static func fundJudicable(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        minutes(now, calendar) >= fundMinute
    }

    /// 该品种此刻是否处于可判定窗口
    static func judicable(_ type: AlertTargetType, now: Date = Date(),
                          calendar: Calendar = .current) -> Bool {
        type == .fund ? fundJudicable(now: now, calendar: calendar)
                      : quoteJudicable(now: now, calendar: calendar)
    }
}
