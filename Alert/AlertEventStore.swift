import Foundation
import SQLite3

/// `sqlite3_bind_text` 的析构器常量（Swift 未导出，需自己构造）
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 判定事件的长期留痕表（对应 my-app 的 `market_alert_event`）
///
/// 三条设计约束：
///   ① 幂等由**唯一索引** `(rule_id, pdate)` 保证，不是代码级「先查再插」：
///      `record()` 用 `INSERT OR IGNORE`，撞了就是 `created = false`（幂等是正常路径，不抛错）。
///   ② 「当前状态」= 该线 pdate 最大的那一行，不另存一份 —— 状态与历史永远一致，
///      不会出现「历史说第 3 天、状态说第 1 天」这种两处漂移。
///   ③ 判定与通知通道分离：本表长期保留（730 天），通知当天过期。
///      两者的生命周期**必须不同** —— 用户可删的数据不能同时当判据。
final class AlertEventStore {
    static let shared = AlertEventStore()

    /// 一条判定结论
    struct Event {
        let ruleId: String
        let secid: String
        let code: String
        let pdate: String
        let price: Double
        let state: AlertJudgeState
        let days: Int
        let firstHit: String?
        let notified: Bool
    }

    /// 保留期（天）。判据只需要最近若干天，更早的留着只为可查史。
    static let retentionDays = 730

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.dreamanual.investmonitor.alertevents")
    /// 自定义库路径（验收断言用）。nil = Application Support 下的默认位置
    private let customPath: String?

    private init() {
        self.customPath = nil
        open()
    }

    /// 指向一个独立库文件，不碰真实数据
    init(databasePath: String) {
        self.customPath = databasePath
        open()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 建库

    private var databasePath: String {
        if let customPath { return customPath }
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DreamanualInvestMonitor", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("alerts.db").path
    }

    private func open() {
        let path = databasePath
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            print("[判定事件表] 打开失败：\(lastError())")
            db = nil
            return
        }
        raw("""
        CREATE TABLE IF NOT EXISTS alert_event (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          rule_id    TEXT    NOT NULL,
          secid      TEXT    NOT NULL,
          code       TEXT    NOT NULL,
          pdate      TEXT    NOT NULL,
          price      REAL    NOT NULL,
          state      TEXT    NOT NULL,
          days       INTEGER NOT NULL DEFAULT 0,
          first_hit  TEXT,
          notified   INTEGER NOT NULL DEFAULT 0,
          created_at TEXT    NOT NULL DEFAULT (datetime('now'))
        );
        """)
        raw("CREATE UNIQUE INDEX IF NOT EXISTS ux_ae_rule_date ON alert_event (rule_id, pdate);")
        purgeLocked(now: Date())
    }

    private func lastError() -> String {
        guard let db else { return "无连接" }
        return String(cString: sqlite3_errmsg(db))
    }

    /// 直接执行 SQL（不经过串行队列，仅供 init 使用）
    @discardableResult
    private func raw(_ sql: String) -> Bool {
        guard let db else { return false }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("[判定事件表] SQL 失败：\(lastError())")
            return false
        }
        return true
    }

    // MARK: - 读

    /// 每条线的最新一行 → 「当前状态」（pdate 最大者）
    func latest() -> [String: Event] {
        queue.sync {
            let sql = """
            SELECT e.rule_id, e.secid, e.code, e.pdate, e.price, e.state, e.days, e.first_hit, e.notified
              FROM alert_event e
              JOIN (SELECT rule_id, MAX(pdate) AS d FROM alert_event GROUP BY rule_id) m
                ON m.rule_id = e.rule_id AND m.d = e.pdate
            """
            var out: [String: Event] = [:]
            query(sql) { stmt in
                if let e = Self.read(stmt) { out[e.ruleId] = e }
            }
            return out
        }
    }

    /// 每条线**最近一次推送**的那一行 → `ruleId: (pdate, price)`
    ///
    /// ⚠️ 必须连 pdate 一起给：调用方要靠它判断「上次推送还在不在本轮穿越里」
    /// （`lastNotified.pdate >= firstHit`）。只看价格相等，会把「复位后回到同一个数字」
    /// 当成没变化而静默吞掉 —— 那是比重复提醒更糟的漏报。
    func latestNotified() -> [String: (pdate: String, price: Double)] {
        queue.sync {
            let sql = """
            SELECT e.rule_id, e.pdate, e.price FROM alert_event e
              JOIN (SELECT rule_id, MAX(pdate) AS d FROM alert_event
                     WHERE notified = 1 GROUP BY rule_id) m
                ON m.rule_id = e.rule_id AND m.d = e.pdate
            """
            var out: [String: (pdate: String, price: Double)] = [:]
            query(sql) { stmt in
                guard let rid = Self.text(stmt, 0), let pd = Self.text(stmt, 1) else { return }
                out[rid] = (pd, sqlite3_column_double(stmt, 2))
            }
            return out
        }
    }

    /// 某条线的历史（判定日倒序）—— 供 UI/排查看「这几天到底怎么走的」
    func history(ruleId: String, limit: Int = 30) -> [Event] {
        queue.sync {
            let lim = min(max(limit, 1), 500)
            let sql = """
            SELECT rule_id, secid, code, pdate, price, state, days, first_hit, notified
              FROM alert_event WHERE rule_id = ? ORDER BY pdate DESC LIMIT \(lim)
            """
            var stmt: OpaquePointer?
            guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, ruleId, -1, SQLITE_TRANSIENT)
            var out: [Event] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let e = Self.read(stmt) { out.append(e) }
            }
            return out
        }
    }

    // MARK: - 写

    /// 写一条评估结论。该判定价日已有 → 返回 false（幂等命中，不抛错）
    @discardableResult
    func record(ruleId: String, secid: String, code: String, pdate: String,
                price: Double, state: AlertJudgeState, days: Int,
                firstHit: String?, notified: Bool = false) -> Bool {
        queue.sync {
            let sql = """
            INSERT OR IGNORE INTO alert_event
              (rule_id, secid, code, pdate, price, state, days, first_hit, notified)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            guard let db else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, ruleId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, secid, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, pdate, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, price)
            sqlite3_bind_text(stmt, 6, state.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 7, Int32(days))
            if let firstHit {
                sqlite3_bind_text(stmt, 8, firstHit, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_int(stmt, 9, notified ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            return sqlite3_changes(db) == 1
        }
    }

    /// 标记「这一天推送过了」（幂等：重复标记不改任何东西）
    func markNotified(ruleId: String, pdate: String) {
        queue.sync {
            let sql = "UPDATE alert_event SET notified = 1 WHERE rule_id = ? AND pdate = ? AND notified = 0"
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, ruleId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, pdate, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    /// 保留期回收：删**判定价日**早于 cutoff 的行
    func purgeOld(now: Date = Date()) {
        queue.sync { purgeLocked(now: now) }
    }

    private func purgeLocked(now: Date) {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: now)
        else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let cutoffStr = f.string(from: cutoff)
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM alert_event WHERE pdate < ?", -1, &stmt, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, cutoffStr, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// 清空全部判定结论（设置页「重置判定状态」用）
    func clearAll() {
        queue.sync { raw("DELETE FROM alert_event;") }
    }

    // MARK: - 底层小工具

    private func query(_ sql: String, each: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
    }

    private static func read(_ stmt: OpaquePointer?) -> Event? {
        guard let ruleId = text(stmt, 0), let pdate = text(stmt, 3) else { return nil }
        return Event(
            ruleId: ruleId,
            secid: text(stmt, 1) ?? "",
            code: text(stmt, 2) ?? "",
            pdate: pdate,
            price: sqlite3_column_double(stmt, 4),
            state: AlertJudgeState(rawValue: text(stmt, 5) ?? "") ?? .idle,
            days: Int(sqlite3_column_int(stmt, 6)),
            firstHit: text(stmt, 7),
            notified: sqlite3_column_int(stmt, 8) != 0
        )
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
}
