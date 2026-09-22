import Foundation

// ============ 判定输入输出 ============

/// 判定价：当日唯一的权威值，且**自带日期**
struct JudgedQuote {
    let value: Double
    let pdate: String
    let changePct: Double?
}

/// 本轮抓取范围：`attempted` = 发起过请求的族，`succeeded` = 该族拿到了可用数据
///
/// 分这两个是因为「抓了但没价」与「压根没抓」的处置完全不同：
/// 前者要留痕（用户配的线没在跑），后者要跳过 —— 净值窗口里本来就不抓交易所族，
/// 拿上一轮快照的旧价评估会凭空造出一次穿越。
struct AlertScope {
    var attempted: Set<AlertTargetType>
    var succeeded: Set<AlertTargetType>

    init(attempted: Set<AlertTargetType> = [], succeeded: Set<AlertTargetType> = []) {
        self.attempted = attempted
        self.succeeded = succeeded
    }

    static let full = AlertScope(attempted: [.goldCNY, .sector, .fund],
                                 succeeded: [.goldCNY, .sector, .fund])
}

/// 一条线的本轮结论
struct AlertEvaluation {
    let rule: AlertRule
    let position: AlertPosition
    let state: AlertJudgeState
    let days: Int
    let pdate: String
    let price: Double
    let changePct: Double?
    /// 该判定价日是否本轮新写（幂等命中为 false）
    let isNew: Bool
}

/// 拿不到判定价的线
struct AlertMissing {
    let ruleId: String
    let targetName: String
    let reason: String
}

struct AlertEvalResult {
    var evaluated: [AlertEvaluation] = []
    var pending: [AlertEvaluation] = []
    var missing: [AlertMissing] = []
    /// 本轮**拿到判定价**的线（含因幂等跳过的）—— 用来清掉「无行情」标记
    var judged: Set<String> = []
}

// ============ 通知内容 ============

/// 待推送的一条通知。标题与正文在这里成型，通道只负责投递。
struct AlertNotice {
    let rule: AlertRule
    let pdate: String
    let price: Double
    let changePct: Double?
    let days: Int
    /// 同日同品种同时命中的其他线
    var rest: [AlertNotice] = []

    /// 结构化线名（「涨破 750.00」）。长度恒定 —— 用户改说明文案也不会让标题改样
    var lineLabel: String { "\(rule.direction.verb) \(AlertFormat.threshold(rule))" }

    /// 标题必须带天数：通知列表只显示标题，缺了天数就判断不出紧迫程度。
    /// 天数也正好让「每天一条」不再是复读。
    var title: String { "\(rule.targetName) · \(lineLabel) · 第 \(days) 天" }

    /// 正文三段：判定价与持续天数 → 说明 → 同时命中
    var body: String {
        var lines: [String] = []
        let pctText = changePct.map { String(format: "（%+.2f%%）", $0) } ?? ""
        lines.append("判定价 \(AlertFormat.value(rule, price))\(pctText) · "
                     + "\(lineLabel) 已持续 \(days) 天（确认 \(rule.effectiveConfirmDays) 日）")
        if !rule.label.isEmpty { lines.append("说明：\(rule.label)") }
        if !rest.isEmpty {
            lines.append("同时命中：" + rest.map { "\($0.lineLabel)（第 \($0.days) 天）" }
                .joined(separator: "、"))
        }
        return lines.joined(separator: "\n")
    }
}

// ============ 引擎 ============

/// 日终判定引擎
///
/// 与旧实现的根本差别：判据是**位置状态机 + 判定价自带日期**，不是「这一帧在不在区内」。
/// 前者让「连续 N 天收盘跌破」可表达、让盘中插针被确认天数压掉；后者两件事都做不到 ——
/// 插针即触发，之后横盘全程静音，而「连续几天」这个维度没有地方可放。
enum AlertEngine {

    /// 判定价 key（与规则一一对应）
    static func judgeKey(_ rule: AlertRule) -> String {
        switch rule.targetType {
        case .goldCNY: return "goldCNY"
        case .sector: return "sector_\(rule.targetCode)"
        case .fund:
            return rule.fundMetric == .changePct
                ? "fund_pct_\(rule.targetCode)"
                : "fund_nav_\(rule.targetCode)"
        }
    }

    /// 标的标识（同品种合并与提示共用）
    static func secid(_ rule: AlertRule) -> String {
        switch rule.targetType {
        case .goldCNY: return "goldCNY"
        case .sector, .fund: return rule.targetCode
        }
    }

    /// 取一条线对应的判定价（含自带日期）。nil = 本轮没拿到
    static func judgedQuote(rule: AlertRule, gold: GoldQuote?,
                            sectors: [SectorQuote], funds: [FundDetail]) -> JudgedQuote? {
        switch rule.targetType {
        case .goldCNY:
            guard let g = gold, g.priceCNY != 0, !g.date.isEmpty else { return nil }
            return JudgedQuote(value: g.priceCNY, pdate: g.date, changePct: g.changePct)
        case .sector:
            // 板块的判定价是涨跌幅，「有没有拿到」看指数点位（平盘时 changePct 合法为 0）
            guard let s = sectors.first(where: { $0.code == rule.targetCode }),
                  s.index != 0, !s.quoteDate.isEmpty else { return nil }
            return JudgedQuote(value: s.changePct, pdate: s.quoteDate, changePct: nil)
        case .fund:
            guard let f = funds.first(where: { $0.quote.code == rule.targetCode }),
                  !f.quote.navDate.isEmpty else { return nil }
            if rule.fundMetric == .changePct {
                return JudgedQuote(value: f.quote.navChangePct, pdate: f.quote.navDate,
                                   changePct: f.quote.navChangePct)
            }
            guard f.quote.nav != 0 else { return nil }
            return JudgedQuote(value: f.quote.nav, pdate: f.quote.navDate,
                               changePct: f.quote.navChangePct)
        }
    }

    /// 主流程：逐线跑状态机 → 落事件表 → 过推送闸门
    ///
    /// 七步的顺序照抄 my-app 的 `evaluateAlerts`，每一步都对应一个实测踩过的坑。
    static func evaluate(rules: [AlertRule], gold: GoldQuote?, sectors: [SectorQuote],
                         funds: [FundDetail], scope: AlertScope, today: String,
                         now: Date, store: AlertEventStore) -> AlertEvalResult {
        var result = AlertEvalResult()
        let latest = store.latest()
        let notified = store.latestNotified()

        for rule in rules {
            guard rule.enabled else { continue }

            // ① 本轮没抓这个族 → 不评估、也不标「无行情」
            guard scope.attempted.contains(rule.targetType) else { continue }

            // ② 整族没数据，或这个标的没值 → 留痕
            guard scope.succeeded.contains(rule.targetType),
                  let q = judgedQuote(rule: rule, gold: gold, sectors: sectors, funds: funds)
            else {
                result.missing.append(AlertMissing(ruleId: rule.id,
                                                   targetName: rule.targetName,
                                                   reason: "no_quote"))
                continue
            }

            // ③ 判定价自带日期不可得 / 晚于今天 → 本轮不评估
            //    （未来日期只在数据源错乱时出现，但那一下会把计数推到虚假的一天，宁可不判）
            guard q.pdate <= today else { continue }
            result.judged.insert(rule.id)

            // ④ 未到该品种的判定窗口（或已过场内上界）→ 今日的权威价还没出来 / 已经不是它了
            guard JudgeWindow.judicable(rule.targetType, now: now) else { continue }

            // ⑤ 幂等：这个判定价日已经判过 —— 同日多轮、夜盘再动全走这支。
            //    没有它，计数会随轮询次数增长。
            let prev = latest[rule.id]
            if let prev, prev.pdate == q.pdate { continue }

            // ⑥ 状态机 + 落表
            let pos = AlertStateMachine.position(value: q.value, rule: rule)
            let next = AlertStateMachine.advance(
                prevState: prev?.state,
                prevDays: prev?.days ?? 0,
                prevFirstHit: prev?.firstHit,
                position: pos,
                confirmDays: rule.effectiveConfirmDays,
                pdate: q.pdate
            )
            let isNew = store.record(
                ruleId: rule.id, secid: secid(rule), code: judgeKey(rule), pdate: q.pdate,
                price: q.value, state: next.state, days: next.days,
                firstHit: next.firstHit, notified: false
            )
            let item = AlertEvaluation(
                rule: rule, position: pos, state: next.state, days: next.days,
                pdate: q.pdate, price: q.value, changePct: q.changePct, isNew: isNew
            )
            result.evaluated.append(item)

            // ⑦ 推送闸门两道，缺一不可
            //    第一道：只推 confirmed —— counting 正是「盘中插针」该被压掉的位置；
            //    把它也推出去，2 日确认就退化成 2 条通知而不是 1 条。
            guard next.state == .confirmed, isNew else { continue }

            //    第二道：同一轮穿越里只在「更糟」时再出声。
            //    ⚠️ 判据必须带**轮次边界**（上次推送还属不属于本轮穿越）：少了它，
            //    价格复位后回到同一个数字（真金白银里极常见）会被当成「没变化」静默吞掉 ——
            //    那比重复提醒更糟，用户以为纪律没被触发，其实线已经击穿了。
            if let ln = notified[rule.id], let fh = next.firstHit, ln.pdate >= fh {
                let worse = rule.direction == .below ? q.value < ln.price : q.value > ln.price
                if !worse { continue }
            }
            result.pending.append(item)
        }
        return result
    }

    /// 同品种同日多条线命中 → 合并为一条
    static func grouped(_ pending: [AlertEvaluation])
        -> [(main: AlertEvaluation, rest: [AlertEvaluation])] {
        var order: [String] = []
        var dict: [String: [AlertEvaluation]] = [:]
        for e in pending {
            let k = secid(e.rule)
            if dict[k] == nil { order.append(k) }
            dict[k, default: []].append(e)
        }
        return order.map { k in
            let g = dict[k]!.sorted(by: severityPrecedes)
            return (g[0], Array(g.dropFirst()))
        }
    }

    /// 严重度：跌破优先于涨破（要减仓的信号比「涨到位了」更该先被看到）；
    /// 同为跌破取阈值最低者（跌得最深），同为涨破取阈值最高者（涨得最高）
    static func severityPrecedes(_ x: AlertEvaluation, _ y: AlertEvaluation) -> Bool {
        let dx = x.rule.direction == .below ? 0 : 1
        let dy = y.rule.direction == .below ? 0 : 1
        if dx != dy { return dx < dy }
        return dx == 0
            ? x.rule.threshold < y.rule.threshold
            : x.rule.threshold > y.rule.threshold
    }

    static func notice(from e: AlertEvaluation) -> AlertNotice {
        AlertNotice(rule: e.rule, pdate: e.pdate, price: e.price,
                    changePct: e.changePct, days: e.days)
    }
}
