import Foundation

// 真机联网自检：三类行情的降级链是否真的取到数、命中了哪一级
//
// 与 alert-selfcheck 的分工：那个是纯逻辑断言（不联网），这个是**真实网络**验证 ——
// 接口口径变了、字段改名了、Referer 要求变了，只有真发请求才知道。
//
// 用法：./tools/net-selfcheck/run.sh

let sem = DispatchSemaphore(value: 0)
var failures = 0
let t0 = Date()

func section(_ t: String) { print("\n=== \(t) ===") }
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ✅ \(what)" : "  ❌ \(what)")
    if !ok { failures += 1 }
}
func ok(_ what: String) { print("  ✅ \(what)") }

Task {
    let gold = GoldService()
    let sector = SectorService()
    let fund = FundService()
    let now = Date()

    // ---------- 黄金 ----------
    section("黄金 113.aum（三级链）")
    do {
        let q = try await gold.fetch()
        print("  来源 \(q.source)｜价 \(q.priceCNY)｜昨收 \(q.prevCNY)｜涨跌 \(q.changePct)%｜行情 \(q.date) \(q.time)")
        check(q.priceCNY > 0, "价格 > 0（f2 为 0 时抛错是预期行为）")
        check(!q.date.isEmpty && !q.time.isEmpty, "取到行情自身时间（f124，不是抓取时刻）")
        check(q.quoteAt != nil, "quoteAt 可解析为 Date")
        if let at = q.quoteAt {
            let lag = Int(now.timeIntervalSince(at) / 60)
            print("  行情时间距今 \(lag) 分钟（非交易日或休市时偏大是正常的）")
        }
        if let f = DataFreshness.display(quoteAt: q.quoteAt, status: .trading, now: now) {
            print("  时效文案（按盘中口径）：\(f.text)\(f.isStale ? " ⚠️" : "")")
        }
    } catch { check(false, "黄金抓取失败：\(error.localizedDescription)") }

    // ---------- 板块 ----------
    section("板块指数 BK0475（三级链）")
    do {
        let s = try await sector.fetchIndex(code: "BK0475", name: "银行")
        print("  来源 \(s.source)｜\(s.name) \(s.index)｜涨跌 \(s.changePct)%｜行情 \(s.quoteDate)")
        check(s.index > 0, "指数 > 0")
        check(!s.quoteDate.isEmpty, "取到行情自身日期")
        check(s.quoteAt != nil, "quoteAt 可解析")
    } catch { check(false, "板块指数抓取失败：\(error.localizedDescription)") }

    section("板块批量（两级链）")
    do {
        let list = try await sector.fetchIndices(codes: ["BK0475", "BK0547"], names: ["银行", "黄金概念"])
        print("  来源 \(list.first?.source ?? "-")｜返回 \(list.count) 条")
        check(list.count == 2, "批量返回 2 条")
        check(list.allSatisfy { !$0.quoteDate.isEmpty }, "每条都带行情日期")
    } catch { check(false, "板块批量失败：\(error.localizedDescription)") }

    section("成分股 clist（两级链）")
    do {
        let stocks = try await sector.fetchStocks(code: "BK0475", topN: 5)
        print("  返回 \(stocks.count) 条，首条 \(stocks.first?.name ?? "-") \(stocks.first?.price ?? 0)")
        check(!stocks.isEmpty, "成分股非空（空列表会被判为失败并降级）")
    } catch { check(false, "成分股失败：\(error.localizedDescription)") }

    section("分时线 trends2（两级链）")
    do {
        let td = try await sector.fetchTrends(code: "BK0475", name: "银行")
        print("  板块分时 \(td.points.count) 点，首 \(td.points.first?.time ?? "-")，末 \(td.points.last?.time ?? "-")")
        check(!td.points.isEmpty, "板块分时非空")

        let gtd = try await sector.fetchGoldTrends()
        print("  黄金分时 \(gtd.points.count) 点，首 \(gtd.points.first?.time ?? "-")，末 \(gtd.points.last?.time ?? "-")")
        check(!gtd.points.isEmpty, "黄金分时非空")
    } catch { check(false, "分时线失败：\(error.localizedDescription)") }

    // ---------- 基金 ----------
    section("基金净值（两级真异源：东财 → 新浪）")
    do {
        let quotes = try await fund.fetchQuotes(codes: ["161725", "110011"])
        for q in quotes {
            print("  来源 \(q.source)｜\(q.code) \(q.name)｜净值 \(q.nav)｜涨跌 \(q.navChangePct)%｜\(q.navDate)")
        }
        check(quotes.count == 2, "两只基金都取到")
        check(quotes.allSatisfy { $0.nav > 0 }, "净值 > 0")
        check(quotes.allSatisfy { !$0.navDate.isEmpty }, "取到净值日期")
    } catch { check(false, "基金净值失败：\(error.localizedDescription)") }

    section("新浪基金源单测（绕过降级链，验证解析）")
    do {
        let list = try await fund.fetchFromSina(codes: ["161725"])
        let q = list.first
        print("  来源 新浪基金｜\(q?.name ?? "-") 净值 \(q?.nav ?? 0) 涨跌 \(q?.navChangePct ?? 0)% 日期 \(q?.navDate ?? "-")")
        check(q != nil && (q?.nav ?? 0) > 0, "新浪源能独立解析出净值")
    } catch { check(false, "新浪源单测失败：\(error.localizedDescription)") }

    // ---------- 交易日历 ----------
    section("交易日历（不联网）")
    check(TradingCalendar.isTradingDay("2026-10-01") == false, "2026-10-01（国庆）→ 非交易日")
    check(TradingCalendar.isTradingDay("2026-10-08") == true, "2026-10-08（国庆后首日，周四）→ 交易日")
    check(TradingCalendar.isTradingDay("2026-10-09") == true, "2026-10-09（周五）→ 交易日")
    check(TradingCalendar.isTradingDay("2026-10-10") == false, "2026-10-10（周六）→ 非交易日")
    check(TradingCalendar.isTradingDay("2026-02-17") == false, "2026-02-17（春节）→ 非交易日")
    check(TradingCalendar.isTradingDay("2026-09-25") == false, "2026-09-25（中秋）→ 非交易日")

    let dt = Date().timeIntervalSince(t0)
    print("\n" + String(repeating: "─", count: 46))
    print(failures == 0
          ? "全部通过（\(String(format: "%.1f", dt))s）"
          : "\(failures) 项失败（\(String(format: "%.1f", dt))s）")
    sem.signal()
}

sem.wait()
exit(failures == 0 ? 0 : 1)
