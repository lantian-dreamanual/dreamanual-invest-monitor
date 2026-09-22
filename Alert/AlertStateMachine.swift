import Foundation

/// 判定价相对阈值的位置
///
/// 命名沿用 my-app 的口径：`outside` 是「已越线」（朝触发方向冲过去了），
/// `inside` 是「已复位」（回到迟滞带之外），`hold` 夹在触发价与复位价之间。
enum AlertPosition {
    case outside   // 已越线 → 计数 +1
    case hold      // 迟滞区 → 冻结
    case inside    // 已复位 → 计数清零
}

/// 判定状态（存进事件表的 state 列）
enum AlertJudgeState: String {
    case idle
    case counting
    case confirmed

    /// 界面用语
    var text: String {
        switch self {
        case .idle: return "未触发"
        case .counting: return "计数中"
        case .confirmed: return "已确认"
        }
    }
}

/// 一次判定的结论
struct AlertAdvance {
    let state: AlertJudgeState
    let days: Int
    let firstHit: String?
}

/// 位置判定与状态推进 —— 两个纯函数，不含 IO、不读时间
///
/// 与旧实现的根本差别：判据是**位置状态机**（含迟滞区与确认天数），
/// 不是「这一帧在不在区内」。前者让「连续 N 天收盘跌破」可表达，
/// 后者只能表达「此刻是否越线」——盘中插针因此必然误报。
enum AlertStateMachine {
    /// 复位缓冲比例：规则没填 `resetThreshold` 时的兜底迟滞带。
    /// 0.5% 对三类标的都在合理量级：黄金 905 元 → 4.5 元，场外基金 3.00 → 0.015。
    static let rearmBuffer = 0.005

    /// 显式复位价。方向配反的值**丢弃**（回落到兜底推导值）而不是丢掉整条线 ——
    /// 宽进严出的第一原则是「绝不因配置写错就让用户静默失去一条纪律」。
    static func explicitResetPrice(of rule: AlertRule) -> Double? {
        guard let ex = rule.resetThreshold, ex > 0, rule.threshold > 0 else { return nil }
        switch rule.direction {
        case .below: return ex > rule.threshold ? ex : nil
        case .above: return ex < rule.threshold ? ex : nil
        }
    }

    /// 三态位置判定
    ///
    /// ⚠️ 无显式复位价时用**相对偏离率**比较，而不是 `th * (1 ± buf)`：
    /// 后者在 IEEE754 下 `100 * 1.005` 会舍入成 100.49999999999999，
    /// 于是「恰好在缓冲边界」的价格被判成已复位。
    static func position(value: Double, rule: AlertRule) -> AlertPosition {
        let th = rule.threshold
        // 判不了 → 冻结（不推进也不清零）
        guard value.isFinite, th > 0 else { return .hold }
        let explicit = explicitResetPrice(of: rule)
        switch rule.direction {
        case .below:
            if value < th { return .outside }
            if let e = explicit { return value >= e ? .inside : .hold }
            return ((value - th) / th) > rearmBuffer ? .inside : .hold
        case .above:
            if value > th { return .outside }
            if let e = explicit { return value <= e ? .inside : .hold }
            return ((th - value) / th) > rearmBuffer ? .inside : .hold
        }
    }

    /// 状态推进：输入「上次结论 + 这次的位置」，输出「这次的结论」
    ///
    /// `hold` 分支是最容易做错的地方：价格在阈值附近抖动时若把它并进 `inside`，
    /// 计数被反复清零，永远到不了确认天数 —— 那等于「确认天数」这个功能不存在。
    static func advance(
        prevState: AlertJudgeState?,
        prevDays: Int,
        prevFirstHit: String?,
        position pos: AlertPosition,
        confirmDays: Int,
        pdate: String
    ) -> AlertAdvance {
        let need = min(max(confirmDays, 1), 10)
        let ps: AlertJudgeState = (prevState == .counting || prevState == .confirmed)
            ? prevState! : .idle
        let pd = prevDays > 0 ? prevDays : 0

        switch pos {
        case .outside:
            let start = (ps == .idle || pd == 0)
            let days = start ? 1 : pd + 1
            // 天数会超过 confirmDays（出现「第 3/2 天」）属正常：一直没复位就一直数下去
            return AlertAdvance(
                state: days >= need ? .confirmed : .counting,
                days: days,
                firstHit: start ? pdate : prevFirstHit
            )
        case .inside:
            return AlertAdvance(state: .idle, days: 0, firstHit: nil)
        case .hold:
            // 冻结：不 +1、不清零、firstHit 不动
            return AlertAdvance(state: ps, days: pd, firstHit: prevFirstHit)
        }
    }
}
