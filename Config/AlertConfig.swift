import Foundation

/// 预警规则存储：UserDefaults JSON 持久化
final class AlertConfig: ObservableObject {
    @Published var rules: [AlertRule] {
        didSet { save() }
    }

    private let key = "com.dreamanual.investmonitor.AlertRules"

    init() {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            self.rules = AlertConfig.defaultRules
            return
        }
        self.rules = AlertConfig.decodeRules(data)
    }

    /// 逐项解码：**一条坏规则不会让整份配置退回默认**。
    /// 整体 `try?` 解码的后果是用户自定义的线静默消失 —— 那比丢弃一条更糟。
    private static func decodeRules(_ data: Data) -> [AlertRule] {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return defaultRules
        }
        let decoder = JSONDecoder()
        var out: [AlertRule] = []
        var dropped = 0
        for item in raw {
            guard let d = try? JSONSerialization.data(withJSONObject: item),
                  let r = try? decoder.decode(AlertRule.self, from: d) else {
                dropped += 1
                continue
            }
            out.append(r)
        }
        if dropped > 0 { print("[预警规则] \(dropped) 条配置无法解析，已跳过") }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - 增删改

    func add(_ rule: AlertRule) {
        rules.append(rule)
    }

    func remove(_ rule: AlertRule) {
        rules.removeAll { $0.id == rule.id }
    }

    /// 更新规则（保留 id 与触发状态）
    func update(_ rule: AlertRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
    }

    func toggle(_ rule: AlertRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i].enabled.toggle()
    }

    /// 全局暂停/恢复
    func setAllEnabled(_ enabled: Bool) {
        for i in rules.indices {
            rules[i].enabled = enabled
        }
    }

    // MARK: - 默认规则（黄金五档）

    static let defaultRules: [AlertRule] = [
        AlertRule(
            id: "gold-tp1", targetType: .goldCNY, targetCode: "", targetName: "黄金(CNY/g)",
            direction: .above, threshold: 700, label: "第1档止盈 · 建议卖1/3",
            enabled: true, triggered: false, triggeredAt: nil
        ),
        AlertRule(
            id: "gold-tp2", targetType: .goldCNY, targetCode: "", targetName: "黄金(CNY/g)",
            direction: .above, threshold: 750, label: "第2档止盈 · 建议卖1/3",
            enabled: true, triggered: false, triggeredAt: nil
        ),
        AlertRule(
            id: "gold-tp3", targetType: .goldCNY, targetCode: "", targetName: "黄金(CNY/g)",
            direction: .above, threshold: 800, label: "第3档止盈 · 建议清仓",
            enabled: true, triggered: false, triggeredAt: nil
        ),
        AlertRule(
            id: "gold-sl1", targetType: .goldCNY, targetCode: "", targetName: "黄金(CNY/g)",
            direction: .below, threshold: 600, label: "第1档止损 · 建议减半",
            enabled: true, triggered: false, triggeredAt: nil
        ),
        AlertRule(
            id: "gold-sl2", targetType: .goldCNY, targetCode: "", targetName: "黄金(CNY/g)",
            direction: .below, threshold: 550, label: "第2档止损 · 建议清仓",
            enabled: true, triggered: false, triggeredAt: nil
        ),
    ]
}
