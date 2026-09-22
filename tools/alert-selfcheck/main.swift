import Foundation

// ============ 预警判定层 验收断言 ============
// 覆盖：W1 判定口径 / W2 确认天数 / W4 判定窗口 / 频控与轮次边界 / W7 合并 / W8 留痕 / 状态机边界

var failures = 0
var total = 0

func check(_ ok: Bool, _ label: String) {
    total += 1
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

func section(_ s: String) { print("\n【\(s)】") }

let workDir = NSTemporaryDirectory() + "invest-alert-selfcheck-data"
try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

/// 每次给一个干净的库文件，互不干扰
func freshStore(_ name: String) -> AlertEventStore {
    let p = "\(workDir)/\(name).db"
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + suffix) }
    return AlertEventStore(databasePath: p)
}

func at(_ hhmm: String) -> Date {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return f.date(from: "2026-09-21 \(hhmm)")!
}

func goldQuote(_ price: Double, date: String) -> GoldQuote {
    GoldQuote(priceCNY: price, prevCNY: price, highCNY: price, lowCNY: price,
              changePct: 0, time: "15:36:00", date: date)
}

func rule(_ id: String, _ dir: AlertDirection, _ th: Double, days: Int? = nil,
          type: AlertTargetType = .goldCNY, code: String = "") -> AlertRule {
    AlertRule(id: id, targetType: type, targetCode: code, targetName: "黄金(CNY/g)",
              direction: dir, threshold: th, label: "测试线",
              enabled: true, triggered: false, triggeredAt: nil,
              fundMetric: nil, confirmDays: days, resetThreshold: nil)
}

let goldScope = AlertScope(attempted: [.goldCNY], succeeded: [.goldCNY])

func eval(_ rules: [AlertRule], _ price: Double?, date: String, now: Date,
          store: AlertEventStore, scope: AlertScope = goldScope) -> AlertEvalResult {
    AlertEngine.evaluate(
        rules: rules, gold: price.map { goldQuote($0, date: date) },
        sectors: [], funds: [], scope: scope, today: date, now: now, store: store
    )
}

// ─────────────────────────────────────────────

section("W1 连续三日收盘穿越 → 每日各推一条")
do {
    let store = freshStore("w1")
    let r = [rule("r1", .above, 700)]
    var pushes: [String] = []
    for (d, p) in [("2026-09-21", 701.0), ("2026-09-22", 702.0), ("2026-09-23", 703.0)] {
        let res = eval(r, p, date: d, now: at("15:36"), store: store)
        pushes.append(contentsOf: res.pending.map { $0.pdate })
    }
    check(pushes.count == 3, "三日各推一条（实得 \(pushes.count) 条）")
    let hist = store.history(ruleId: "r1")
    check(hist.count == 3, "事件表 3 行（实得 \(hist.count) 行）")
    check(Set(hist.map(\.pdate)).count == 3, "三行 pdate 各不相同")
    check(hist.allSatisfy { $0.state == .confirmed }, "三行 state 都是 confirmed")
    check(hist.first?.days == 3, "最新一行 days = 3（一直没复位就一直数下去）")
}

section("W1 盘中插针 → 当日收在阈值下，不推")
do {
    let store = freshStore("w1b")
    let r = [rule("r1", .above, 700)]
    let spike = eval(r, 705, date: "2026-09-21", now: at("15:00"), store: store)
    check(spike.evaluated.isEmpty && spike.pending.isEmpty, "15:00 插针（未到窗口）→ 不评估不推送")
    let close = eval(r, 698, date: "2026-09-21", now: at("15:36"), store: store)
    check(close.evaluated.first?.state == .idle, "收盘 698 在阈值下方 → idle")
    check(close.pending.isEmpty, "不推送")
}

section("W2 确认天数 = 2 的三种走向")
do {
    // A：第一天跌破、第二天涨回复位 → idle，不推
    let sA = freshStore("w2a")
    let rA = [rule("r1", .below, 900, days: 2)]
    let a1 = eval(rA, 899, date: "2026-09-21", now: at("15:36"), store: sA)
    check(a1.evaluated.first?.state == .counting && a1.evaluated.first?.days == 1,
          "A 第 1 天跌破 → counting 1")
    check(a1.pending.isEmpty, "A 第 1 天不推（确认天数未满）")
    let a2 = eval(rA, 910, date: "2026-09-22", now: at("15:36"), store: sA)
    check(a2.evaluated.first?.state == .idle, "A 第 2 天涨回 910 → 回 idle")
    check(a2.pending.isEmpty, "A 全程不推")

    // B：第一天跌破、第二天停在迟滞带内（901 = 阈值上方 0.11%）→ 冻结，不清零
    let sB = freshStore("w2b")
    let rB = [rule("r1", .below, 900, days: 2)]
    _ = eval(rB, 899, date: "2026-09-21", now: at("15:36"), store: sB)
    let b2 = eval(rB, 901, date: "2026-09-22", now: at("15:36"), store: sB)
    check(b2.evaluated.first?.position == .hold, "B 迟滞带内 → 位置 HOLD")
    check(b2.evaluated.first?.state == .counting && b2.evaluated.first?.days == 1,
          "B 计数冻结在 1（不是清零——清零等于确认天数这个功能不存在）")
    check(b2.pending.isEmpty, "B 不推")

    // C：连续两天站在下方 → confirmed，只推 1 条
    let sC = freshStore("w2c")
    let rC = [rule("r1", .below, 900, days: 2)]
    _ = eval(rC, 899, date: "2026-09-21", now: at("15:36"), store: sC)
    let c2 = eval(rC, 898, date: "2026-09-22", now: at("15:36"), store: sC)
    check(c2.evaluated.first?.state == .confirmed && c2.evaluated.first?.days == 2,
          "C 连续两天 → confirmed 2")
    check(c2.pending.count == 1, "C 推 1 条（不是 2 条）")
}

section("W4 判定窗口（下界 15:35 / 上界 21:00 / 基金 20:30）")
do {
    let store = freshStore("w4")
    let r = [rule("r1", .above, 700)]
    let early = eval(r, 705, date: "2026-09-21", now: at("15:00"), store: store)
    check(early.evaluated.isEmpty, "15:00 未到窗口 → 不评估")
    let night = eval(r, 705, date: "2026-09-21", now: at("22:00"), store: store)
    check(night.evaluated.isEmpty, "22:00 夜盘 → 已过窗口，不拿夜盘价当收盘价")
    let ok = eval(r, 705, date: "2026-09-21", now: at("15:36"), store: store)
    check(ok.evaluated.count == 1 && ok.pending.count == 1, "15:36 窗口内 → 评估并推送")

    let fRule = [rule("f1", .above, 1.5, type: .fund, code: "161725")]
    let fScope = AlertScope(attempted: [.fund], succeeded: [.fund])
    let fund = FundDetail(quote: FundQuote(code: "161725", name: "测试基金", nav: 1.6,
                                           navChangePct: 0.5, navDate: "2026-09-21"),
                          holdings: [], estNav: nil, estChangePct: nil)
    let fEarly = AlertEngine.evaluate(rules: fRule, gold: nil, sectors: [], funds: [fund],
                                      scope: fScope, today: "2026-09-21", now: at("19:00"),
                                      store: store)
    check(fEarly.evaluated.isEmpty, "基金 19:00 → 未到 20:30，不评估")
    let fOk = AlertEngine.evaluate(rules: fRule, gold: nil, sectors: [], funds: [fund],
                                   scope: fScope, today: "2026-09-21", now: at("20:40"),
                                   store: store)
    check(fOk.evaluated.count == 1, "基金 20:40 → 评估")
}

section("幂等：同一判定价日只判一次")
do {
    let store = freshStore("idem")
    let r = [rule("r1", .above, 700)]
    _ = eval(r, 705, date: "2026-09-21", now: at("15:36"), store: store)
    let again = eval(r, 706, date: "2026-09-21", now: at("16:30"), store: store)
    check(again.evaluated.isEmpty, "同 pdate 再评估 → 跳过（计数不随轮询次数增长）")
    check(store.history(ruleId: "r1").count == 1, "事件表仍只有 1 行")
    let night = eval(r, 707, date: "2026-09-21", now: at("20:50"), store: store)
    check(night.evaluated.isEmpty, "同一天晚些时候再拿新价 → 仍跳过")
}

section("频控与轮次边界")
do {
    let store = freshStore("freq")
    let r = [rule("r1", .above, 700, days: 2)]
    _ = eval(r, 701, date: "2026-09-21", now: at("15:36"), store: store)
    let d2 = eval(r, 702, date: "2026-09-22", now: at("15:36"), store: store)
    check(d2.pending.count == 1, "第 2 天确认 → 推 1 条")
    store.markNotified(ruleId: "r1", pdate: "2026-09-22")

    let d3 = eval(r, 703, date: "2026-09-23", now: at("15:36"), store: store)
    check(d3.pending.count == 1, "第 3 天更高 → 再推（同一轮穿越里更糟就出声）")
    store.markNotified(ruleId: "r1", pdate: "2026-09-23")

    let d4 = eval(r, 702.5, date: "2026-09-24", now: at("15:36"), store: store)
    check(d4.pending.isEmpty, "第 4 天回落但仍在区内 → 静音")

    // 复位：价格要**跌回阈值下方**才算复位（涨得更远是 OUTSIDE，不是复位）
    let reset = eval(r, 690, date: "2026-09-25", now: at("15:36"), store: store)
    check(reset.evaluated.first?.state == .idle, "第 5 天跌回 690 → 复位 idle")
    // 回到与上次推送**完全相同**的数字：新起一轮，轮次边界必须让它最终出声
    // （该规则确认 2 日，所以新起一轮要到第 2 天才 confirmed）
    let same1 = eval(r, 703, date: "2026-09-28", now: at("15:36"), store: store)
    check(same1.evaluated.first?.state == .counting && same1.evaluated.first?.days == 1,
          "第 6 天回到 703（与上次推送同一数字）→ 重新计数 1，不推")
    let same2 = eval(r, 703, date: "2026-09-29", now: at("15:36"), store: store)
    check(same2.pending.count == 1,
          "第 7 天仍是 703 → 出声（若只比价格相等会被误判成「没变化」而静默）")
}

section("W7 同品种多线合并 + 通知文案")
do {
    let store = freshStore("merge")
    let rs = [rule("a", .above, 700), rule("b", .above, 750)]
    let res = eval(rs, 760, date: "2026-09-21", now: at("15:36"), store: store)
    check(res.pending.count == 2, "两条线都命中（实得 \(res.pending.count)）")
    let groups = AlertEngine.grouped(res.pending)
    check(groups.count == 1, "合并为 1 组")
    check(groups.first?.main.rule.id == "b", "阈值更高者 750 作主条")
    check(groups.first?.rest.count == 1, "rest 挂 1 条")
    if let g = groups.first {
        var n = AlertEngine.notice(from: g.main)
        n.rest = g.rest.map { AlertEngine.notice(from: $0) }
        check(n.title.contains("第 1 天"), "标题带天数 → \(n.title)")
        check(n.body.contains("750.00"), "正文自带阈值")
        check(n.body.contains("同时命中") && n.body.contains("700.00"), "正文列同时命中")
        print("  ── 通知样例 ──\n  \(n.title)\n  " + n.body.replacingOccurrences(of: "\n", with: "\n  "))
    }
}

section("W8 拿不到判定价 → 留痕而不是静默")
do {
    let store = freshStore("miss")
    let r = [rule("r1", .above, 700)]
    let failing = AlertScope(attempted: [.goldCNY], succeeded: [])
    let res = eval(r, nil, date: "2026-09-21", now: at("15:36"), store: store, scope: failing)
    check(res.missing.count == 1 && res.missing.first?.ruleId == "r1", "整族抓取失败 → missing 1 条")

    let notPolled = AlertScope(attempted: [], succeeded: [])
    let res2 = eval(r, nil, date: "2026-09-21", now: at("15:36"), store: store, scope: notPolled)
    check(res2.missing.isEmpty && res2.evaluated.isEmpty, "本轮没抓该族 → 不评估也不留痕")

    // 数据库层的幂等：同日重复 record 返回 false
    let first = store.record(ruleId: "x", secid: "goldCNY", code: "goldCNY",
                             pdate: "2026-09-21", price: 700, state: .idle, days: 0, firstHit: nil)
    let second = store.record(ruleId: "x", secid: "goldCNY", code: "goldCNY",
                              pdate: "2026-09-21", price: 999, state: .confirmed, days: 9, firstHit: nil)
    check(first && !second, "唯一索引幂等：首次 created=true，重复 created=false")
    let kept = store.history(ruleId: "x").first
    check(kept?.price == 700, "重复写入不改已有行（price 仍 700）")
}

section("状态机与复位价边界")
do {
    let below = rule("r1", .below, 900)
    check(AlertStateMachine.position(value: 899, rule: below) == .outside, "跌破线 899 → OUTSIDE")
    check(AlertStateMachine.position(value: 901, rule: below) == .hold, "迟滞带 901 → HOLD")
    check(AlertStateMachine.position(value: 904.5, rule: below) == .hold,
          "904.5（恰好等于 0.5% 缓冲）→ HOLD，不算复位")
    check(AlertStateMachine.position(value: 905, rule: below) == .inside, "905 → INSIDE")
    check(AlertStateMachine.position(value: 910, rule: below) == .inside, "910 → INSIDE")

    let above = rule("r2", .above, 700)
    check(AlertStateMachine.position(value: 701, rule: above) == .outside, "涨破线 701 → OUTSIDE")
    check(AlertStateMachine.position(value: 696.5, rule: above) == .hold,
          "696.5（恰好等于 0.5% 缓冲）→ HOLD")
    check(AlertStateMachine.position(value: 696, rule: above) == .inside, "696 → INSIDE")

    var wrong = rule("r3", .below, 900)
    wrong.resetThreshold = 890          // below 需要复位价 > 阈值，890 是配反的
    check(AlertStateMachine.explicitResetPrice(of: wrong) == nil, "方向配反的显式复位价被丢弃")
    var right = rule("r4", .below, 900)
    right.resetThreshold = 910
    check(AlertStateMachine.explicitResetPrice(of: right) == 910, "方向正确的显式复位价被采用")
    check(AlertStateMachine.position(value: 905, rule: right) == .hold, "显式复位价 910 下 → 905 是 HOLD")
    check(AlertStateMachine.position(value: 912, rule: right) == .inside, "912 → INSIDE")

    check(rule("r5", .above, 700, days: 99).effectiveConfirmDays == 10, "确认天数上钳到 10")
    check(rule("r6", .above, 700, days: 0).effectiveConfirmDays == 1, "确认天数下钳到 1")
    check(rule("r7", .above, 700).effectiveConfirmDays == 1, "缺省确认天数 = 1")
}

section("规则解码：缺 optional 字段的旧 JSON 仍能解出（向后兼容）")
do {
    let legacyJSON = """
    {"id":"ok1","targetType":"黄金CNY","targetCode":"","targetName":"黄金(CNY/g)",
     "direction":"≥","threshold":700,"label":"测试","enabled":true,"triggered":false}
    """
    let r = try? JSONDecoder().decode(AlertRule.self, from: legacyJSON.data(using: .utf8)!)
    check(r != nil, "旧 JSON（无 confirmDays / resetThreshold / fundMetric）能解码")
    check(r?.effectiveConfirmDays == 1, "缺省确认天数 = 1（与旧行为一致）")
    check(r?.resetThreshold == nil, "缺省复位价 = nil（走 0.5% 兜底迟滞带）")
    check(r?.fundMetric == nil, "缺省基金基准 = nil")
}

// ─────────────────────────────────────────────
// R 系列（第二轮：交易日历 / 降级链 / 时效 / 覆盖度 / 配置容错）

section("R1 交易日历：节假日与调休（上交所 2026 公告）")
do {
    check(TradingCalendar.isTradingDay("2026-10-01") == false, "2026-10-01 国庆 → 非交易日")
    check(TradingCalendar.isTradingDay("2026-10-07") == false, "2026-10-07 国庆最后一天 → 非交易日")
    check(TradingCalendar.isTradingDay("2026-10-08") == true, "2026-10-08 节后首日（周四）→ 交易日")
    check(TradingCalendar.isTradingDay("2026-10-09") == true, "2026-10-09 周五 → 交易日")
    check(TradingCalendar.isTradingDay("2026-10-10") == false, "2026-10-10 周六 → 非交易日")
    check(TradingCalendar.isTradingDay("2026-02-17") == false, "2026-02-17 春节 → 非交易日")
    check(TradingCalendar.isTradingDay("2026-02-24") == true, "2026-02-24 春节后首日 → 交易日")
    check(TradingCalendar.isTradingDay("2026-09-25") == false, "2026-09-25 中秋 → 非交易日")
    check(TradingCalendar.isTradingDay("2026-09-28") == true, "2026-09-28 中秋后首日 → 交易日")
    check(TradingCalendar.isTradingDay("2026-05-04") == false, "2026-05-04 劳动节 → 非交易日")
    check(TradingCalendar.isTradingDay("2026-01-02") == false, "2026-01-02 元旦 → 非交易日")
    check(TradingCalendar.isTradingDay("2026-01-05") == true, "2026-01-05 元旦后首日 → 交易日")
    check(TradingCalendar.isTradingDay("2027-01-04") == true, "2027 年（表外）按周末规则降级 → 周一为交易日")
    check(TradingCalendar.isTradingDay("2027-01-02") == false, "2027 年表外 + 周六 → 非交易日")
}

section("R2 降级链：命中即返回 / 逐级降级 / 全败带来源名")
do {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let r1 = try? await QuoteChain.run([
            QuoteSource<Double>("主源") { 933.02 },
            QuoteSource<Double>("备源") { 999.0 },
        ])
        check(r1?.value == 933.02 && r1?.source == "主源", "首选成功即返回，不碰备源")

        let r2 = try? await QuoteChain.run([
            QuoteSource<Double>("主源") { throw FetchError.badResponse },
            QuoteSource<Double>("备源") { 4319.08 },
            QuoteSource<Double>("第三级") { 0 },
        ])
        check(r2?.value == 4319.08 && r2?.source == "备源", "首选失败 → 落到备源并记来源")

        do {
            _ = try await QuoteChain.run([
                QuoteSource<Double>("东财延时") { throw FetchError.timeout },
                QuoteSource<Double>("东财主站") { throw FetchError.badResponse },
                QuoteSource<Double>("东财单只") { throw FetchError.noConnection },
            ])
            check(false, "全败应当抛错")
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            check(msg.contains("东财延时") && msg.contains("东财主站") && msg.contains("东财单只"),
                  "全败错误带出每一级来源名 →「\(msg)」")
        }
        sem.signal()
    }
    sem.wait()
}

section("R3 数据时效：只在交易时段判陈旧")
do {
    let now = at("15:36")
    let stale = now.addingTimeInterval(-12 * 60)
    let fresh = now.addingTimeInterval(-3 * 60)

    let d1 = DataFreshness.display(quoteAt: stale, status: .trading, now: now)
    check(d1?.isStale == true, "盘中 + 12 分钟前 → 判为陈旧")
    check(d1?.text.contains("数据延迟 12 分钟") == true, "文案「\(d1?.text ?? "-")」含延迟分钟数")

    let d2 = DataFreshness.display(quoteAt: stale, status: .closed, now: now)
    check(d2?.isStale == false, "收盘后 + 同一时间戳 → 不判陈旧（周末看周五行情的常态）")
    check(d2?.text.hasPrefix("截至 ") == true, "收盘后只给「截至 …」不附加延迟")

    check(DataFreshness.display(quoteAt: fresh, status: .trading, now: now)?.isStale == false,
          "盘中 + 3 分钟前 → 不陈旧")
    check(DataFreshness.display(quoteAt: nil, status: .trading, now: now)?.isStale == true,
          "盘中拿不到行情时间 → 判为陈旧")
    check(DataFreshness.display(quoteAt: nil, status: .closed, now: now) == nil,
          "收盘且无时间戳 → 不显示（不制造噪音）")
    check(DataFreshness.shortDate("2026-09-21") == "09-21", "净值日期缩写 2026-09-21 → 09-21")
}

section("R5 估值覆盖度：缺价重仓不再静默丢弃")
do {
    let codes = (1...10).map { String(format: "%06d", 600000 + $0) }   // 600001…600010
    let h10 = codes.map { FundHolding(code: $0, name: "股\($0)", weight: 10, exchange: 1) }

    let partial = FundEstimator.estimate(holdings: h10, stockMap: ["600001": 2.0, "600002": 4.0])
    check(partial != nil, "只有 2 只有行情 → 仍给得出估值")
    check(abs((partial?.pct ?? 0) - 3.0) < 0.0001, "估值 = 有行情部分的加权（3.0%）")
    check(abs((partial?.coverage ?? 0) - 20.0) < 0.0001, "覆盖度 = 20%（10 只各 10%，只有 2 只有价）")

    let full = FundEstimator.estimate(
        holdings: h10,
        stockMap: Dictionary(uniqueKeysWithValues: codes.map { ($0, 1.0) })
    )
    check(abs((full?.coverage ?? 0) - 100.0) < 0.0001, "全部有行情 → 覆盖度 100%")
    check(FundEstimator.estimate(holdings: h10, stockMap: [:]) == nil, "一只都没行情 → 不给估值（而不是给 0）")
}

section("R7 配置逐项解码：一条坏项不牵连整份")
do {
    let bad = """
    {"sectors":[{"code":"BK0475","name":"半导体"},{"code":123}],
     "funds":[{"code":"161725","name":"白酒"},{"name":"缺代码"}],
     "statusBarSource":"BK0475"}
    """.data(using: .utf8)!
    let (cfg, rep) = ConfigStore.decode(bad)
    check(cfg.sectors.count == 1 && cfg.sectors.first?.code == "BK0475", "坏的板块项被跳过，好的保留")
    check(cfg.funds.count == 1 && cfg.funds.first?.code == "161725", "坏的基金项被跳过，好的保留")
    check(rep == 2, "计数 2 项已重置（实得 \(rep)）")
    check(cfg.statusBarSource == "BK0475", "状态栏来源不受影响")

    let (def, rep0) = ConfigStore.decode(nil)
    check(rep0 == 0 && def.sectors.count == 3, "无数据 → 走默认配置且计数为 0")

    let (empty, rep1) = ConfigStore.decode("{}".data(using: .utf8)!)
    check(empty.sectors.isEmpty && rep1 == 0, "空对象 → 空列表，不是默认配置（保留用户清空的意图）")
}

section("R4 冷启动快照：往返编解码要保住行情时间与来源")
do {
    // 独立 suite：跑自检不覆盖用户真实的快照
    let suite = UserDefaults(suiteName: "com.dreamanual.investmonitor.selfcheck")!
    let now = at("15:36")

    let g = GoldQuote(priceCNY: 933.02, prevCNY: 940.18, highCNY: 943.22, lowCNY: 932.0,
                      changePct: -1.06, time: "15:17:50", date: "2026-09-22",
                      quoteAt: now, source: "东财延时")
    let s = SectorQuote(code: "BK0475", name: "银行Ⅱ", index: 4319.08, changePct: -0.08,
                        prevIndex: 4322.66, amount: 2.2e10, quoteDate: "2026-09-22",
                        quoteAt: now, source: "东财主站")
    let f = FundDetail(
        quote: FundQuote(code: "161725", name: "白酒", nav: 0.5323,
                         navChangePct: 0.76, navDate: "2026-09-21", source: "东财基金"),
        holdings: [], estNav: 0.5363, estChangePct: 0.75, estCoverage: 62
    )
    SnapshotStore.save(gold: g, sector: s, sectors: [s], funds: [f], defaults: suite)

    let back = SnapshotStore.load(defaults: suite)
    check(back != nil, "快照能读回")
    check(back?.gold?.quote.quoteAt != nil, "行情自身时间在往返后仍在（不是抓取时刻）")
    check(abs((back?.gold?.quote.priceCNY ?? 0) - 933.02) < 0.0001, "黄金价格往返一致")
    check(back?.sector?.quote.source == "东财主站", "命中的来源名往返保留")
    check(abs((back?.sector?.quote.index ?? 0) - 4319.08) < 0.0001, "板块指数往返一致")
    check(back?.funds.first?.detail.estCoverage == 62, "估值覆盖度往返保留")
    check(back?.funds.first?.detail.holdings.isEmpty == true, "重仓列表不回填（启动后当轮重新取）")
    check(back?.funds.first?.detail.quote.navDate == "2026-09-21", "净值日期往返保留")
}

// ─────────────────────────────────────────────
// 复位价输入（添加/编辑弹窗共用的一份校验）

section("复位价输入：留空合法 / 方向配反拦住 / 留空即删键")
do {
    check(AlertResetInput.error(text: "", thresholdText: "905", direction: .below) == nil,
          "留空合法（交回 0.5% 兜底迟滞带）")
    check(AlertResetInput.parse(text: "  ") == nil, "纯空白解析为 nil（不写成 0）")
    check(AlertResetInput.parse(text: "abc") == nil, "非数字解析为 nil（保存时不写入）")
    check(AlertResetInput.parse(text: "-3") == nil, "负数解析为 nil")
    check(AlertResetInput.parse(text: "910") == 910, "合法值解析成 910")

    check(AlertResetInput.error(text: "910", thresholdText: "905", direction: .below) == nil,
          "跌破线 905 配复位价 910（上方）合法")
    check(AlertResetInput.error(text: "900", thresholdText: "905", direction: .below) != nil,
          "跌破线 905 配复位价 900（下方）被拦住")
    check(AlertResetInput.error(text: "905", thresholdText: "905", direction: .below) != nil,
          "复位价等于阈值被拦住（迟滞带为 0）")
    check(AlertResetInput.error(text: "900", thresholdText: "905", direction: .above) == nil,
          "涨破线 905 配复位价 900（下方）合法")
    check(AlertResetInput.error(text: "910", thresholdText: "905", direction: .above) != nil,
          "涨破线 905 配复位价 910（上方）被拦住")
    check(AlertResetInput.error(text: "900", thresholdText: "", direction: .below) == nil,
          "触发价还没填 → 不做方向判断（不误报）")
    check(AlertResetInput.error(text: "abc", thresholdText: "905", direction: .below) != nil,
          "非数字被拦住")

    check(AlertResetInput.editText(nil) == "", "nil 回填成空串")
    check(AlertResetInput.editText(905.0) == "905", "905.0 回填去掉尾零 → 905")
    check(AlertResetInput.editText(2.66) == "2.66", "2.66 回填 → 2.66")
    check(AlertResetInput.editText(0.5323) == "0.5323",
          "0.5323 回填保留 4 位小数（基金净值是 4 位，用 %.3f 会被截成 0.532）")

    // 回填 → 再解析 的往返：编辑弹窗「打开后不修改直接保存」不能悄悄改掉复位价
    for v in [905.0, 910.5, 2.66, 0.5323, 4.0751] {
        let back = AlertResetInput.parse(text: AlertResetInput.editText(v))
        check(back == v, "往返一致：\(v) → \"\(AlertResetInput.editText(v))\" → \(back.map { String($0) } ?? "nil")")
    }

    // 「留空 = 删键」要能被证实，不然界面清空了、配置里还留着旧复位价
    let nilRule = rule("r8", .below, 905)
    let nilJSON = (try? JSONEncoder().encode(nilRule))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(!nilJSON.contains("resetThreshold"), "nil 编码后不含 resetThreshold 键（等于删键）")
    var setRule = rule("r9", .below, 905)
    setRule.resetThreshold = 910
    let setJSON = (try? JSONEncoder().encode(setRule))
        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(setJSON.contains("\"resetThreshold\":910"), "非 nil 编码后带 resetThreshold")
}

// ─────────────────────────────────────────────

print("\n" + String(repeating: "─", count: 50))
if failures == 0 {
    print("全部通过：\(total) 条断言")
} else {
    print("失败 \(failures) / \(total) 条")
}
exit(failures == 0 ? 0 : 1)
