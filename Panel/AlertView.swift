import SwiftUI
import AppKit

// ============ 规则行状态 ============

/// 规则行的状态种类，优先级从高到低：hit > counting > confirmed > dead > last > none
///
/// 两条优先级规则：
///   · `hit` 排在 `counting`/`confirmed` 前面 —— 否则用户永远看不到「今日已触发」那一天
///   · `dead` 排在 `counting`/`confirmed` 之后 —— 「没拿到行情」是数据运行态，
///     「连续第几天」是长期结论；让前者盖掉后者，一次网络抖动就把「纪律还在成立」藏起来了
enum AlertRowKind {
    case hit        // 今日推送过 —— 唯一「要你动手」的状态
    case counting   // 已在触发区、天数未满
    case confirmed  // 纪律已成立（连续 N 日）
    case dead       // 判定价拿不到
    case last       // 非今日的旧结论
    case none       // 还没判过
}

struct AlertRowState {
    let kind: AlertRowKind
    let text: String
}

/// 预警规则列表（嵌入设置页卡片内）：按标的分组展示 + 增删 + 组折叠
struct AlertRuleList: View {
    @ObservedObject var controller: MenuBarController
    /// 折叠的组键（持久化）
    @AppStorage("com.dreamanual.investmonitor.CollapsedGroups") private var collapsedGroupsRaw = ""

    private var collapsed: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 总开关行：全部规则一键启停，样式与单行开关一致
            if !controller.alertConfig.rules.isEmpty {
                HStack(spacing: DmSpace.s6) {
                    LucideIcon("bell", size: DmIcon.i12)
                        .foregroundColor(Color.dmInk2)
                        .frame(width: 18)
                    Text("全部规则")
                        .font(.system(size: DmText.t13, weight: .semibold))
                        .foregroundColor(Color.dmInk)
                        .lineLimit(1)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { !controller.alertConfig.rules.allSatisfy { !$0.enabled } },
                        set: { on in controller.alertConfig.setAllEnabled(on) }
                    ))
                    .toggleStyle(GoldToggleStyle())
                    .labelsHidden()
                }
                .padding(.horizontal, DmSpace.s14)
                .frame(height: DmControl.h38)
                .background(Color.dmPanel2)
                Divider().opacity(0.6)
            }

            if controller.alertConfig.rules.isEmpty {
                HStack(spacing: DmSpace.s6) {
                    LucideIcon("bell-off", size: DmIcon.i12)
                        .foregroundColor(Color.dmInk2)
                    Text("暂无预警规则，点击 + 添加")
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DmSpace.s14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                        AlertGroupView(
                            group: group,
                            controller: controller,
                            isCollapsed: collapsed.contains(group.id),
                            onToggleCollapse: { toggleCollapse(group.id) }
                        )
                        if idx < groups.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 分组

    struct RuleGroup: Identifiable {
        let id: String
        let targetType: AlertTargetType
        let name: String
        let rules: [AlertRule]
    }

    private var groups: [RuleGroup] {
        var order: [String] = []
        var dict: [String: [AlertRule]] = [:]
        for r in controller.alertConfig.rules {
            let key = AlertRuleList.groupKey(r)
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append(r)
        }
        return order.map { key in
            let rules = dict[key]!
            let first = rules[0]
            return RuleGroup(id: key, targetType: first.targetType, name: first.targetName, rules: rules)
        }
    }

    private static func groupKey(_ r: AlertRule) -> String {
        "\(r.targetType.rawValue)|\(r.targetCode)"
    }

    private func toggleCollapse(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedGroupsRaw = set.sorted().joined(separator: ",")
    }
}

/// 标的分组：组头（图标 + 标的名 + 条数 + 折叠） + 组内规则行
struct AlertGroupView: View {
    let group: AlertRuleList.RuleGroup
    @ObservedObject var controller: MenuBarController
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    /// 今日有命中 —— 唯一值得给组头染色的事
    private var hasTodayHit: Bool {
        group.rules.contains { $0.enabled && controller.alertRowState(for: $0).kind == .hit }
    }
    private var allDisabled: Bool { group.rules.allSatisfy { !$0.enabled } }

    var body: some View {
        VStack(spacing: 0) {
            // 组头
            Button(action: onToggleCollapse) {
                HStack(spacing: DmSpace.s6) {
                    LucideIcon(appIconName, size: DmIcon.i12)
                        .foregroundColor(groupColor)
                        .frame(width: 18)
                    Text(group.name)
                        .font(.system(size: DmText.t13, weight: .semibold))
                        .foregroundColor(Color.dmInk)
                        .lineLimit(1)
                    Text("\(group.rules.count) 条")
                        .font(.system(size: DmText.t10))
                        .padding(.horizontal, DmSpace.s6)
                        .padding(.vertical, DmSpace.s2)
                        .background(hasTodayHit ? Color.dmDangerSoft : Color.dmPanel3)
                        .foregroundColor(hasTodayHit ? Color.dmDangerInk : Color.dmInk2)
                        .cornerRadius(DmRadius.r6)
                    Spacer()
                    LucideIcon("chevron-right", size: DmIcon.i10)
                        .foregroundColor(Color.dmInk2)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                }
                .padding(.horizontal, DmSpace.s14)
                .frame(height: DmControl.h38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.dmPanel2)

            // 组内规则
            if !isCollapsed {
                Divider().opacity(0.6)
                VStack(spacing: 0) {
                    ForEach(Array(group.rules.enumerated()), id: \.element.id) { idx, rule in
                        AlertRuleRow(rule: rule, controller: controller)
                        if idx < group.rules.count - 1 {
                            Divider().opacity(0.4).padding(.leading, 26)
                        }
                    }
                }
            }
        }
        .background(Color.clear)
        .cornerRadius(DmRadius.r10)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r10)
                .stroke(Color.dmLine2.opacity(allDisabled ? 0.5 : 1), lineWidth: DmLine.hairline)
        )
        .opacity(allDisabled ? 0.65 : 1)
    }

    private var appIconName: String {
        switch group.targetType {
        case .goldCNY: return "gold"
        case .sector: return "sector"
        case .fund: return "fund"
        }
    }

    private var groupColor: Color {
        Color.dmInk2
    }
}

/// 单条规则行（双行明细）
struct AlertRuleRow: View {
    let rule: AlertRule
    @ObservedObject var controller: MenuBarController

    var body: some View {
        HStack(alignment: .top, spacing: DmSpace.s8) {
            VStack(alignment: .leading, spacing: DmSpace.s4) {
                // 第一行：方向徽标 + 阈值
                HStack(spacing: DmSpace.s6) {
                    Text(directionText)
                        .font(.system(size: DmText.t10, weight: .semibold))
                        .padding(.horizontal, DmSpace.s6)
                        .padding(.vertical, DmSpace.s2)
                        .foregroundColor(directionColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .stroke(directionColor.opacity(0.45), lineWidth: DmLine.base)
                        )
                    Text(AlertFormat.threshold(rule))
                        .font(.system(size: DmText.t13, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(rule.enabled ? Color.dmInk : Color.dmInk2)
                    if rule.effectiveConfirmDays > 1 {
                        Text("确认 \(rule.effectiveConfirmDays) 日")
                            .font(.system(size: DmText.t10))
                            .foregroundColor(Color.dmInk2)
                    }
                    // 显式复位价必须露出来：否则它成了「看不见也改不掉」的隐形配置
                    if let rs = rule.resetThreshold {
                        Text("复位 \(AlertFormat.value(rule, rs))")
                            .font(.system(size: DmText.t10))
                            .foregroundColor(Color.dmInk2)
                    }
                }

                // 第二行：状态（由事件表派生，不是配置文案）
                HStack(spacing: DmSpace.s4) {
                    if let icon = stateIcon {
                        LucideIcon(icon, size: DmIcon.i10)
                            .foregroundColor(stateColor)
                    }
                    Text(state.text)
                        .font(.system(size: DmText.t11, weight: stateWeight))
                        .foregroundColor(stateColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // 开关（品牌金）
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in controller.alertConfig.toggle(rule) }
            ))
            .toggleStyle(GoldToggleStyle())
            .labelsHidden()
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s8)
        .background(Color.dmPanel)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                // 弹窗状态收敛到 controller，由 MainPanelView 根部的自绘模态统一呈现
                controller.editingRule = rule
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                controller.alertConfig.remove(rule)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var state: AlertRowState { controller.alertRowState(for: rule) }

    private var stateColor: Color {
        switch state.kind {
        case .hit: return .dmDanger
        case .dead: return .dmWarn
        default: return .dmInk2
        }
    }

    private var stateWeight: Font.Weight {
        switch state.kind {
        case .counting, .confirmed: return .medium
        default: return .regular
        }
    }

    private var stateIcon: String? {
        switch state.kind {
        case .hit: return "check-circle"
        case .dead: return "warning"
        default: return nil
        }
    }

    private var directionText: String {
        rule.direction == .above ? "↑ 止盈" : "↓ 止损"
    }

    private var directionColor: Color {
        rule.direction == .above ? Color.dmUp : Color.dmDown
    }
}

/// 添加规则弹窗
struct AddAlertSheet: View {
    @ObservedObject var controller: MenuBarController
    @Binding var isPresented: Bool

    @State private var targetType: AlertTargetType = .goldCNY
    @State private var targetCode = ""
    @State private var targetName = "黄金(CNY/g)"
    @State private var direction: AlertDirection = .above
    @State private var threshold = ""
    @State private var label = ""
    @State private var fundMetric: FundMetric = .nav
    @State private var confirmDays = "1"
    /// 复位价：留空 = 交回 0.5% 兜底迟滞带（与源系统口径一致）
    @State private var resetThreshold = ""

    var body: some View {
        DmModalCard(
            title: "添加预警规则",
            content: {            // 标的类型
            FormSection("标的类型") {
                SegmentedTabs(
                    items: [AlertTargetType.goldCNY, AlertTargetType.sector, AlertTargetType.fund],
                    selection: $targetType,
                    label: { t in
                        switch t {
                        case .goldCNY: return "金CNY"
                        case .sector: return "板块"
                        case .fund: return "基金"
                        }
                    },
                    style: .compact
                )
                .onChange(of: targetType) { newType in
                    switch newType {
                    case .goldCNY: targetName = "黄金(CNY/g)"; targetCode = ""
                    case .sector:
                        targetName = ""
                        targetCode = controller.configStore.config.sectors.first?.code ?? ""
                    case .fund:
                        targetName = ""
                        targetCode = controller.configStore.config.funds.first?.code ?? ""
                    }
                }
            }

            // 板块/基金选择
            if targetType == .sector || targetType == .fund {
                FormSection("选择标的") {
                    if targetType == .sector {
                        DmMenuPicker(
                            selection: $targetCode,
                            items: controller.configStore.config.sectors.map { .init(value: $0.code, label: "\($0.name) (\($0.code))") },
                            style: .modal
                        )
                        .onChange(of: targetCode) { newCode in
                            targetName = controller.configStore.config.sectors.first(where: { $0.code == newCode })?.name ?? ""
                        }
                    } else {
                        DmMenuPicker(
                            selection: $targetCode,
                            items: controller.configStore.config.funds.map { .init(value: $0.code, label: "\($0.name) (\($0.code))") },
                            style: .modal
                        )
                        .onChange(of: targetCode) { newCode in
                            targetName = controller.configStore.config.funds.first(where: { $0.code == newCode })?.name ?? ""
                        }
                    }
                }
            }

            // 基金预警基准（仅基金）
            if targetType == .fund {
                FormSection("预警基准") {
                    SegmentedTabs(
                        items: FundMetric.allCases,
                        selection: $fundMetric,
                        label: { $0.rawValue },
                        style: .compact
                    )
                    .onChange(of: fundMetric) { _ in
                        threshold = ""
                    }
                }
            }

            // 方向 + 阈值 + 确认天数。三个组之间用等宽弹性空档（最小 s12）：
            // 原先只有方向后面一个 Spacer，方向→阈值一大段、阈值→确认天数 s10，
            // 一行里两种节奏。三件控件现已同为 38 档高（SegmentedTabs compact 钉档）。
            // 确认天数说明贴在行下方 s4 —— 与复位价的「字段→提示」间距同节奏
            // （原先漂在提醒文案下面、吃的是 s12 段距，两处提示离各自字段不一样远）。
            VStack(alignment: .leading, spacing: DmSpace.s4) {
                HStack(alignment: .top, spacing: 0) {
                    FormSection("方向") {
                        SegmentedTabs(
                            items: [AlertDirection.above, AlertDirection.below],
                            selection: $direction,
                            label: { d in d == .above ? "≥ 涨到" : "≤ 跌到" },
                            style: .compact
                        )
                        .frame(width: 148)
                    }
                    Spacer(minLength: DmSpace.s12)
                    FormSection("阈值") {
                        FormTextField(placeholder: thresholdPlaceholder, text: $threshold, width: 84)
                    }
                    Spacer(minLength: DmSpace.s12)
                    FormSection("确认天数") {
                        FormTextField(placeholder: "1", text: $confirmDays, width: 64)
                    }
                }
                // 确认天数说明：只有这里能解释「连续几天才算数」这件事
                HStack(spacing: DmSpace.s4) {
                    LucideIcon("info", size: DmIcon.i10)
                        .foregroundColor(Color.dmInk2)
                    Text("确认天数：连续几个判定价日站在触发区内才提醒（1–10，默认 1）")
                        .font(.system(size: DmText.t10))
                        .foregroundColor(Color.dmInk2)
                }
            }

            // 复位价：可选。留空 = 交回 0.5% 兜底迟滞带
            FormSection("复位价") {
                VStack(alignment: .leading, spacing: DmSpace.s4) {
                    FormTextField(placeholder: "可选", text: $resetThreshold)
                    HStack(spacing: DmSpace.s4) {
                        LucideIcon(resetError == nil ? "info" : "warning", size: DmIcon.i10)
                            .foregroundColor(resetError == nil ? Color.dmInk2 : Color.dmDanger)
                        Text(resetError ?? "留空按触发价 0.5% 自动留迟滞带")
                            .font(.system(size: DmText.t10))
                            .foregroundColor(resetError == nil ? Color.dmInk2 : Color.dmDanger)
                    }
                }
            }

            FormSection("提醒文案") {
                FormTextField(placeholder: "第1档止盈 · 建议卖1/3", text: $label)
            }

            },
            foot: {
                Button("取消") { isPresented = false }
                    .buttonStyle(SecondaryButtonStyle())
                Button("添加") {
                    addRule()
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(threshold.isEmpty || label.isEmpty || resetError != nil)
            }
        )
    }

    private var thresholdPlaceholder: String {
        if targetType == .goldCNY { return "700.00" }
        if targetType == .fund && fundMetric == .nav { return "1.50" }
        return "-2.50"
    }

    /// 确认天数：非法或 ≤1 都存 nil（= 与旧行为一致，不写多余的字段）
    private var parsedConfirmDays: Int? {
        guard let d = Int(confirmDays.trimmingCharacters(in: .whitespaces)), d > 1 else { return nil }
        return min(d, 10)
    }

    /// 复位价校验结果：nil = 合法（留空也合法）
    private var resetError: String? {
        AlertResetInput.error(text: resetThreshold, thresholdText: threshold, direction: direction)
    }

    private func addRule() {
        guard let thr = Double(threshold) else { return }
        let rule = AlertRule(
            id: UUID().uuidString,
            targetType: targetType,
            targetCode: targetCode,
            targetName: targetName.isEmpty ? defaultName() : targetName,
            direction: direction,
            threshold: thr,
            label: label,
            enabled: true,
            triggered: false,
            triggeredAt: nil,
            fundMetric: targetType == .fund ? fundMetric : nil,
            confirmDays: parsedConfirmDays,
            resetThreshold: AlertResetInput.parse(text: resetThreshold)
        )
        controller.alertConfig.add(rule)
    }

    private func defaultName() -> String {
        switch targetType {
        case .goldCNY: return "黄金(CNY/g)"
        case .sector: return "板块"
        case .fund: return "基金"
        }
    }
}

/// 编辑规则弹窗（复用添加弹窗字段，预填当前值）
struct EditAlertSheet: View {
    @ObservedObject var controller: MenuBarController
    let rule: AlertRule
    @Binding var isPresented: Bool

    @State private var targetType: AlertTargetType
    @State private var targetCode: String
    @State private var targetName: String
    @State private var direction: AlertDirection
    @State private var threshold: String
    @State private var label: String
    @State private var fundMetric: FundMetric
    @State private var confirmDays: String
    /// 复位价：从规则照搬，空串 = 这条线没有显式复位价（保存时写回 nil，等于删键）
    @State private var resetThreshold: String

    init(controller: MenuBarController, rule: AlertRule, isPresented: Binding<Bool>) {
        self.controller = controller
        self.rule = rule
        self._isPresented = isPresented
        _targetType = State(initialValue: rule.targetType)
        _targetCode = State(initialValue: rule.targetCode)
        _targetName = State(initialValue: rule.targetName)
        _direction = State(initialValue: rule.direction)
        _threshold = State(initialValue: String(format: "%.3f", rule.threshold))
        _label = State(initialValue: rule.label)
        _fundMetric = State(initialValue: rule.fundMetric ?? .nav)
        _confirmDays = State(initialValue: String(rule.effectiveConfirmDays))
        _resetThreshold = State(initialValue: AlertResetInput.editText(rule.resetThreshold))
    }

    var body: some View {
        DmModalCard(
            title: "编辑预警规则",
            content: {
            // 标的类型
            FormSection("标的类型") {
                SegmentedTabs(
                    items: [AlertTargetType.goldCNY, AlertTargetType.sector, AlertTargetType.fund],
                    selection: $targetType,
                    label: { t in
                        switch t {
                        case .goldCNY: return "金CNY"
                        case .sector: return "板块"
                        case .fund: return "基金"
                        }
                    },
                    style: .compact
                )
                .disabled(true)  // 编辑时不允许改标的类型
                .onChange(of: targetType) { newType in
                    switch newType {
                    case .goldCNY: targetName = "黄金(CNY/g)"; targetCode = ""
                    case .sector:
                        targetName = ""
                        targetCode = controller.configStore.config.sectors.first?.code ?? ""
                    case .fund:
                        targetName = ""
                        targetCode = controller.configStore.config.funds.first?.code ?? ""
                    }
                }
            }

            // 板块/基金选择
            if targetType == .sector || targetType == .fund {
                FormSection("选择标的") {
                    if targetType == .sector {
                        DmMenuPicker(
                            selection: $targetCode,
                            items: controller.configStore.config.sectors.map { .init(value: $0.code, label: "\($0.name) (\($0.code))") },
                            style: .modal
                        )
                        .onChange(of: targetCode) { newCode in
                            targetName = controller.configStore.config.sectors.first(where: { $0.code == newCode })?.name ?? ""
                        }
                    } else {
                        DmMenuPicker(
                            selection: $targetCode,
                            items: controller.configStore.config.funds.map { .init(value: $0.code, label: "\($0.name) (\($0.code))") },
                            style: .modal
                        )
                        .onChange(of: targetCode) { newCode in
                            targetName = controller.configStore.config.funds.first(where: { $0.code == newCode })?.name ?? ""
                        }
                    }
                }
            }

            // 基金预警基准（仅基金）
            if targetType == .fund {
                FormSection("预警基准") {
                    SegmentedTabs(
                        items: FundMetric.allCases,
                        selection: $fundMetric,
                        label: { $0.rawValue },
                        style: .compact
                    )
                    .onChange(of: fundMetric) { _ in
                        threshold = ""
                    }
                }
            }

            // 方向 + 阈值 + 确认天数。三个组之间用等宽弹性空档（最小 s12）：
            // 原先只有方向后面一个 Spacer，方向→阈值一大段、阈值→确认天数 s10，
            // 一行里两种节奏。三件控件现已同为 38 档高（SegmentedTabs compact 钉档）。
            // 确认天数说明贴在行下方 s4 —— 与复位价的「字段→提示」间距同节奏
            // （原先漂在提醒文案下面、吃的是 s12 段距，两处提示离各自字段不一样远）。
            VStack(alignment: .leading, spacing: DmSpace.s4) {
                HStack(alignment: .top, spacing: 0) {
                    FormSection("方向") {
                        SegmentedTabs(
                            items: [AlertDirection.above, AlertDirection.below],
                            selection: $direction,
                            label: { d in d == .above ? "≥ 涨到" : "≤ 跌到" },
                            style: .compact
                        )
                        .frame(width: 148)
                    }
                    Spacer(minLength: DmSpace.s12)
                    FormSection("阈值") {
                        FormTextField(placeholder: thresholdPlaceholder, text: $threshold, width: 84)
                    }
                    Spacer(minLength: DmSpace.s12)
                    FormSection("确认天数") {
                        FormTextField(placeholder: "1", text: $confirmDays, width: 64)
                    }
                }
                // 确认天数说明：只有这里能解释「连续几天才算数」这件事
                HStack(spacing: DmSpace.s4) {
                    LucideIcon("info", size: DmIcon.i10)
                        .foregroundColor(Color.dmInk2)
                    Text("确认天数：连续几个判定价日站在触发区内才提醒（1–10，默认 1）")
                        .font(.system(size: DmText.t10))
                        .foregroundColor(Color.dmInk2)
                }
            }

            // 复位价：可选。留空 = 交回 0.5% 兜底迟滞带
            FormSection("复位价") {
                VStack(alignment: .leading, spacing: DmSpace.s4) {
                    FormTextField(placeholder: "可选", text: $resetThreshold)
                    HStack(spacing: DmSpace.s4) {
                        LucideIcon(resetError == nil ? "info" : "warning", size: DmIcon.i10)
                            .foregroundColor(resetError == nil ? Color.dmInk2 : Color.dmDanger)
                        Text(resetError ?? "留空按触发价 0.5% 自动留迟滞带")
                            .font(.system(size: DmText.t10))
                            .foregroundColor(resetError == nil ? Color.dmInk2 : Color.dmDanger)
                    }
                }
            }

            FormSection("提醒文案") {
                FormTextField(placeholder: "第1档止盈 · 建议卖1/3", text: $label)
            }

            },
            foot: {
                Button("取消") { isPresented = false }
                    .buttonStyle(SecondaryButtonStyle())
                Button("保存") {
                    saveRule()
                    isPresented = false
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(threshold.isEmpty || label.isEmpty || resetError != nil)
            }
        )
    }

    private var thresholdPlaceholder: String {
        if targetType == .goldCNY { return "700.00" }
        if targetType == .fund && fundMetric == .nav { return "1.50" }
        return "-2.50"
    }

    private var parsedConfirmDays: Int? {
        guard let d = Int(confirmDays.trimmingCharacters(in: .whitespaces)), d > 1 else { return nil }
        return min(d, 10)
    }

    /// 复位价校验结果：nil = 合法（留空也合法）
    private var resetError: String? {
        AlertResetInput.error(text: resetThreshold, thresholdText: threshold, direction: direction)
    }

    private func saveRule() {
        guard let thr = Double(threshold) else { return }
        var updated = rule
        updated.targetType = targetType
        updated.targetCode = targetCode
        updated.targetName = targetName.isEmpty ? defaultName() : targetName
        updated.direction = direction
        updated.threshold = thr
        updated.label = label
        updated.fundMetric = targetType == .fund ? fundMetric : nil
        updated.confirmDays = parsedConfirmDays
        // 留空 → nil，等于删掉这个键（交回 0.5% 兜底）；不能写成「沿用旧值」，
        // 否则界面上清空了复位价、实际判定仍按老复位价走 —— 屏幕和纪律不一致
        updated.resetThreshold = AlertResetInput.parse(text: resetThreshold)
        controller.alertConfig.update(updated)
    }

    private func defaultName() -> String {
        switch targetType {
        case .goldCNY: return "黄金(CNY/g)"
        case .sector: return "板块"
        case .fund: return "基金"
        }
    }
}
