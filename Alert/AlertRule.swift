import Foundation

/// 预警标的类型
enum AlertTargetType: String, Codable {
    case goldCNY = "黄金CNY"      // 黄金折算价 CNY/g
    case sector = "板块"          // 板块涨跌幅
    case fund = "基金"            // 基金估算/净值
}

/// 预警方向
enum AlertDirection: String, Codable {
    case above = "≥"   // 价格涨到阈值
    case below = "≤"   // 价格跌到阈值

    /// 结构化用语：通知标题与「同时命中」列表共用（长度恒定，用户改文案也不影响标题）
    var verb: String { self == .above ? "涨破" : "跌破" }
}

/// 基金预警基准：净值价位 / 涨跌幅百分比
enum FundMetric: String, Codable, CaseIterable {
    case nav = "净值"       // 基金净值价位（如 1.50）
    case changePct = "涨跌幅" // 涨跌幅百分比（如 -2.50%）
}

/// 预警规则
struct AlertRule: Codable, Identifiable, Hashable {
    var id: String            // UUID
    var targetType: AlertTargetType
    var targetCode: String     // 黄金留空、板块如 BK0475、基金如 161725
    var targetName: String     // 显示名
    var direction: AlertDirection
    var threshold: Double       // 阈值
    var label: String           // 提醒文案，如「第1档止盈 · 建议卖1/3」
    var enabled: Bool           // 单条规则开关
    /// 运行态：本进程内是否已推送过。界面即时显示用，**结论以事件表为准**
    var triggered: Bool
    var triggeredAt: Date?
    /// 基金预警基准（仅 targetType == .fund 有意义，默认净值）
    var fundMetric: FundMetric?
    /// 确认天数：连续几个判定价日站在触发区内才算数。缺省 1（= 与旧行为一致）
    var confirmDays: Int?
    /// 显式复位价：判定价回到这里才算「已复位」。缺省走 0.5% 兜底迟滞带
    var resetThreshold: Double?

    /// 有效确认天数（钳制到 1–10）
    var effectiveConfirmDays: Int { min(max(confirmDays ?? 1, 1), 10) }

    /// 触发后标记
    mutating func markTriggered() {
        triggered = true
        triggeredAt = Date()
    }

    /// 价格回落过阈值后重置（恢复可再次触发）
    mutating func reset() {
        triggered = false
        triggeredAt = nil
    }
}

// ============ 复位价输入 ============

/// 复位价输入框的校验与解析 —— 添加弹窗与编辑弹窗共用一份，避免两处口径漂移
///
/// 语义与 `AlertStateMachine.explicitResetPrice` 对齐：**留空是合法输入**，
/// 表示把复位判定交回 0.5% 兜底迟滞带。因此「留空」在保存时等于**删掉这个键**，
/// 而不是写一个 0 或沿用旧值。
enum AlertResetInput {
    /// 校验：返回错误文案，nil 表示合法（留空也算合法）
    static func error(
        text: String,
        thresholdText: String,
        direction: AlertDirection
    ) -> String? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        guard let v = Double(s), v > 0 else { return "请填正数，或留空" }
        // 触发价本身还没填对时不做方向判断 —— 判据不成立，报错只会误导
        guard let th = Double(thresholdText.trimmingCharacters(in: .whitespaces)), th > 0 else { return nil }
        switch direction {
        case .below: return v > th ? nil : "跌破线的复位价要在触发价上方"
        case .above: return v < th ? nil : "涨破线的复位价要在触发价下方"
        }
    }

    /// 解析：留空或非法 → nil。nil 的含义是「这条线没有显式复位价」
    static func parse(text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let v = Double(s), v > 0 else { return nil }
        return v
    }

    /// 编辑弹窗回填用：最短往返表示（905.0 → 905，2.66 → 2.66，0.5323 → 0.5323）
    ///
    /// ⚠️ 用最短往返表示，不要用 `%.3f`：基金净值是 4 位小数，
    /// `%.3f` 会把 0.5323 写成 0.532，用户「打开编辑再原样保存」就静默改了复位价。
    static func editText(_ value: Double?) -> String {
        guard let v = value else { return "" }
        var s = String(v)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }
}

// ============ 格式化 ============

/// 预警数值格式化：一处定义，通知标题/正文、规则行、编辑弹窗共用
enum AlertFormat {
    /// 阈值
    static func threshold(_ rule: AlertRule) -> String { number(rule, rule.threshold) }

    /// 判定价 / 当前值
    static func value(_ rule: AlertRule, _ v: Double) -> String { number(rule, v) }

    private static func number(_ rule: AlertRule, _ v: Double) -> String {
        switch rule.targetType {
        case .goldCNY:
            return String(format: "%.2f", v)
        case .sector:
            return String(format: "%.2f%%", v)
        case .fund:
            // 净值模式显示价位（3 位小数），涨跌幅模式显示百分比
            return rule.fundMetric == .changePct
                ? String(format: "%.2f%%", v)
                : String(format: "%.3f", v)
        }
    }
}
