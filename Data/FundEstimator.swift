import Foundation

/// 基金盘中模拟估值：重仓股权重 × 实时个股涨跌
/// 估算涨跌% = Σ(权重 × 个股涨跌%) / Σ(权重)
enum FundEstimator {

    /// 估算结果。必须带覆盖度 —— 10 只重仓只有 2 只有行情时，
    /// 函数照样算得出一个数，界面上却看不出它只代表那 2 只
    struct Estimate {
        let pct: Double       // 加权估算涨跌 %
        let coverage: Double  // 参与估算的重仓权重合计，占全部重仓权重的 %
    }

    /// 计算单只基金的估算涨跌与覆盖度
    ///
    /// 分母用「有行情那部分」的权重和（与主流估算口径一致），另给出覆盖率，
    /// 让界面能说出这个数字代表了多少仓位。
    /// - Parameters:
    ///   - holdings: 重仓股（含权重）
    ///   - stockMap: 重仓股代码 → 实时涨跌%（key 为去前缀代码，如 "300308"）
    /// - Returns: 一只重仓都没拿到行情时返回 nil
    static func estimate(holdings: [FundHolding], stockMap: [String: Double]) -> Estimate? {
        var weightSum = 0.0      // 有行情部分的权重
        var totalWeight = 0.0    // 全部重仓权重合计
        var weighted = 0.0
        for h in holdings {
            totalWeight += h.weight
            // 代码统一去前缀（沪 600/688、深 300/002、港 06869 等）
            let key = normalizeCode(h.code)
            if let pct = stockMap[key] {
                weightSum += h.weight
                weighted += h.weight * pct
            }
        }
        guard weightSum > 0 else { return nil }
        return Estimate(
            pct: weighted / weightSum,
            coverage: totalWeight > 0 ? weightSum / totalWeight * 100 : 0
        )
    }

    /// 估算净值 = 最新净值 × (1 + 估算涨跌%)
    static func estimateNav(nav: Double, changePct: Double) -> Double {
        nav * (1 + changePct / 100)
    }

    /// 统一代码格式：东财重仓 GPDM 可能是 "300308"，行情接口需要去市场前缀
    static func normalizeCode(_ code: String) -> String {
        // 6 位纯数字，无需处理；带 sh/sz 前缀则去前缀
        if code.count > 6 {
            return String(code.suffix(6))
        }
        return code
    }
}
