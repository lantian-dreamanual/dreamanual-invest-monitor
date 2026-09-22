import SwiftUI
import AppKit

/// 代码反查状态
enum LookupState {
    case idle
    case loading
    case found(String)
    case notFound

    var isSearching: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// 设置页：自选板块 → 自选基金 → 预警规则（标题在卡片外，对齐 macOS 系统设置风格）
struct SettingsView: View {
    @ObservedObject var controller: MenuBarController
    @State private var newSectorCode = ""
    @State private var sectorLookup: LookupState = .idle
    @State private var lastSearchedSectorCode = ""
    @State private var newFundCode = ""
    @State private var fundLookup: LookupState = .idle
    @State private var lastSearchedFundCode = ""
    @State private var showAddSector = false
    @State private var showAddFund = false
    @State private var showAddAlert = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // ===== 自选板块 =====
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader(
                        title: "自选板块",
                    trailing: IconButton(iconName: showAddSector ? "minus" : "plus") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showAddSector.toggle()
                        }
                    }
                    .help(showAddSector ? "收起" : "添加板块")
                    )

                    SettingsCard {
                        VStack(spacing: 0) {
                            if showAddSector {
                                sectorAddRow
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                Divider().opacity(0.4)
                            }
                            if controller.configStore.config.sectors.isEmpty {
                                Text("暂无板块，点击 + 添加")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                ForEach(Array(controller.configStore.config.sectors.enumerated()), id: \.element.code) { idx, s in
                                    HStack {
                                        Text(s.name).font(.system(size: 13))
                                        Text(s.code).font(.system(size: 11)).foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            let wasCurrent = (s.code == controller.currentSectorCode)
                                            controller.configStore.removeSector(s)
                                            // 删除的是当前板块：立即切到第一个，不等异步 refresh
                                            if wasCurrent {
                                                controller.currentSectorCode = controller.configStore.config.sectors.first?.code ?? "BK0475"
                                                Task { await controller.refreshSector(code: controller.currentSectorCode) }
                                            } else {
                                                Task { await controller.refresh() }
                                            }
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                    if idx < controller.configStore.config.sectors.count - 1 {
                                        Divider().opacity(0.4)
                                    }
                                }
                            }
                        }
                    }
                }

                // ===== 自选基金 =====
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader(
                        title: "自选基金",
                    trailing: IconButton(iconName: showAddFund ? "minus" : "plus") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showAddFund.toggle()
                        }
                    }
                    .help(showAddFund ? "收起" : "添加基金")
                    )

                    SettingsCard {
                        VStack(spacing: 0) {
                            if showAddFund {
                                fundAddRow
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                Divider().opacity(0.4)
                            }
                            if controller.configStore.config.funds.isEmpty {
                                Text("暂无基金，点击 + 添加")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                ForEach(Array(controller.configStore.config.funds.enumerated()), id: \.element.code) { idx, f in
                                    HStack {
                                        Text(f.name).font(.system(size: 13))
                                        Text(f.code).font(.system(size: 11)).foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            controller.configStore.removeFund(f)
                                            Task { await controller.refresh() }
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                    if idx < controller.configStore.config.funds.count - 1 {
                                        Divider().opacity(0.4)
                                    }
                                }
                            }
                        }
                    }
                }

                // ===== 状态栏显示 =====
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader(title: "状态栏显示", trailing: EmptyView())

                    SettingsCard {
                        VStack(spacing: 0) {
                            HStack {
                                Text("显示内容")
                                    .font(.system(size: 13))
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { controller.configStore.config.statusBarSource ?? "gold" },
                                    set: { newValue in
                                        controller.configStore.config.statusBarSource = (newValue == "gold") ? nil : newValue
                                        controller.updateStatusTitle()
                                    }
                                )) {
                                    Text("黄金(CNY/g)").tag("gold")
                                    ForEach(controller.configStore.config.sectors) { sector in
                                        Text(sector.name).tag(sector.code)
                                    }
                                }
                                .pickerStyle(.menu)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                    }
                }

                // ===== 预警规则 =====
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader(
                        title: "预警规则",
                        trailing: IconButton(iconName: "plus") {
                            showAddAlert = true
                        }
                        .help("添加规则")
                    )

                    SettingsCard {
                        AlertRuleList(controller: controller)
                    }
                }

                // ===== 关于 =====
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader(title: "关于", trailing: EmptyView())

                    SettingsCard {
                        VStack(spacing: 0) {
                            // 版本号
                            HStack {
                                Text("当前版本")
                                    .font(.system(size: 13))
                                Spacer()
                                Text("v\(controller.updateChecker.currentVersion)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)

                            Divider().opacity(0.4)

                            // 自动检查更新开关
                            HStack {
                                Text("自动检查更新")
                                    .font(.system(size: 13))
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { controller.updateChecker.autoCheckEnabled },
                                    set: { controller.updateChecker.autoCheckEnabled = $0 }
                                ))
                                .labelsHidden()
                                .toggleStyle(GoldToggleStyle())
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())

                            Divider().opacity(0.4)

                            // 立即检查
                            HStack {
                                Text("检查最新版本")
                                    .font(.system(size: 13))
                                Spacer()
                                // 状态反馈
                                if controller.updateChecker.manualCheckStatus != .idle {
                                    if controller.updateChecker.manualCheckStatus == .checking {
                                        Text("检查中…")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text(statusText(controller.updateChecker.manualCheckStatus))
                                            .font(.system(size: 11))
                                            .foregroundColor(statusColor(controller.updateChecker.manualCheckStatus))
                                    }
                                }
                                Button {
                                    if controller.updateChecker.manualCheckStatus == .newVersion,
                                       let info = controller.updateChecker.availableUpdate,
                                       let url = URL(string: info.downloadUrl) {
                                        NSWorkspace.shared.open(url)
                                    } else {
                                        controller.updateChecker.manualCheck()
                                    }
                                } label: {
                                    Text(controller.updateChecker.manualCheckStatus == .newVersion ? "下载更新" : "立即检查")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(controller.updateChecker.isChecking)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)

                            Divider().opacity(0.4)

                            // 赞赏
                            Button {
                                if let url = URL(string: "https://afdian.com/a/wuyifa001") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    AppIcon(name: "coffee", size: 13)
                                    Text("请我喝杯咖啡")
                                        .font(.system(size: 13))
                                    Spacer()
                                }
                                .foregroundColor(.brandGold)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                    }
                }

                // ===== 运行状态（只读）：回答「这份数从哪来、日历管到什么时候」 =====
                VStack(alignment: .leading, spacing: 5) {
                    sectionHeader(title: "运行状态", trailing: EmptyView())

                    SettingsCard {
                        // 多行内容收在一个 VStack 里：与页面其它卡片写法一致
                        VStack(spacing: 0) {
                            statusRow("交易日历", "覆盖至 \(TradingCalendar.coveredUntil)")
                            Divider().opacity(0.4)
                            statusRow("黄金数据源", sourceName(controller.gold?.source))
                            Divider().opacity(0.4)
                            statusRow("板块数据源", sourceName(controller.sector?.source))
                            Divider().opacity(0.4)
                            statusRow("基金数据源", sourceName(controller.funds.first?.quote.source))

                            // 坏配置提示：不提示的话，用户只会发现自己少了两只基金
                            if controller.configStore.repairedCount > 0 {
                                Divider().opacity(0.4)
                                HStack(spacing: 6) {
                                    AppIcon(name: "warning", size: 12)
                                        .foregroundColor(.orange)
                                    Text("\(controller.configStore.repairedCount) 项配置无法读取，已重置")
                                        .font(.system(size: 12))
                                        .foregroundColor(.orange)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                            }
                        }
                    }
                }

                // ===== 退出程序（独立卡片） =====
                VStack(alignment: .leading, spacing: 5) {
                    SettingsCard {
                        Button {
                            NSApplication.shared.terminate(nil)
                        } label: {
                            HStack(spacing: 6) {
                                AppIcon(name: "power", size: 13)
                                Text("退出投资监控")
                                    .font(.system(size: 13))
                                Spacer()
                            }
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }

                if let m = message {
                    Text(m)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showAddAlert) {
            AddAlertSheet(controller: controller, isPresented: $showAddAlert)
        }
    }

    /// 区块标题行：标题在左、操作按钮在右（对齐 macOS 系统设置标题在卡片外的风格）
    /// 统一固定 28pt 高度，消除有按钮/无按钮时的间距差异
    private func sectionHeader<Trailing: View>(title: String, trailing: Trailing) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
            trailing
        }
        .frame(height: 28)
    }

    // MARK: - 运行状态行

    /// 只读状态行：左标签右值
    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 数据源名：空串与 nil 都显示占位符，避免出现一行空白让人以为界面坏了
    private func sourceName(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "—" }
        return s
    }

    // MARK: - 更新检查状态文案

    private func statusText(_ status: UpdateChecker.ManualCheckStatus) -> String {
        switch status {
        case .idle: return ""
        case .checking: return "检查中…"
        case .upToDate: return "已是最新版本"
        case .newVersion: return "发现新版本"
        case .failed: return "检查失败，稍后再试"
        }
    }

    private func statusColor(_ status: UpdateChecker.ManualCheckStatus) -> Color {
        switch status {
        case .upToDate: return .green
        case .newVersion: return .brandGold
        case .failed: return .red
        default: return .secondary
        }
    }

    // MARK: - 添加板块

    private func lookupSector() {
        let code = newSectorCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { sectorLookup = .idle; return }
        sectorLookup = .loading
        lastSearchedSectorCode = code
        Task {
            let name = await LookupService.sectorName(code: code)
            await MainActor.run {
                if let name {
                    sectorLookup = .found(name)
                } else {
                    sectorLookup = .notFound
                }
            }
        }
    }

    private func addSector() {
        let code = newSectorCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return }
        // 检查重复
        guard !controller.configStore.config.sectors.contains(where: { $0.code == code }) else {
            message = "该板块已添加"
            return
        }
        // 优先用识别到的名称，识别失败则用代码作为名称
        let name: String
        if case let .found(n) = sectorLookup {
            name = n
        } else {
            name = code
        }
        controller.configStore.addSector(SectorConfig(code: code, name: name))
        newSectorCode = ""
        sectorLookup = .idle
        lastSearchedSectorCode = ""
        message = nil
        withAnimation(.easeInOut(duration: 0.15)) { showAddSector = false }
        Task { await controller.refresh() }
    }

    // MARK: - 添加基金

    private func lookupFund() {
        let code = newFundCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { fundLookup = .idle; return }
        fundLookup = .loading
        lastSearchedFundCode = code
        Task {
            let name = await LookupService.fundName(code: code)
            await MainActor.run {
                if let name {
                    fundLookup = .found(name)
                } else {
                    fundLookup = .notFound
                }
            }
        }
    }

    private func addFund() {
        let code = newFundCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        // 检查重复
        guard !controller.configStore.config.funds.contains(where: { $0.code == code }) else {
            message = "该基金已添加"
            return
        }
        let name: String
        if case let .found(n) = fundLookup {
            name = n
        } else {
            name = code
        }
        controller.configStore.addFund(FundConfig(code: code, name: name))
        newFundCode = ""
        fundLookup = .idle
        lastSearchedFundCode = ""
        message = nil
        withAnimation(.easeInOut(duration: 0.15)) { showAddFund = false }
        Task { await controller.refresh() }
    }

    // MARK: - 添加表单行（展开时显示，只输入代码自动识别名称）

    private var sectorAddRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                FormTextField(placeholder: "板块代码 (BK0475)", text: $newSectorCode)
                    .onSubmit { lookupSector() }
                searchButton(
                    code: newSectorCode,
                    lastSearched: lastSearchedSectorCode,
                    isSearching: sectorLookup.isSearching,
                    action: { lookupSector() }
                )
            }
            lookupRow(state: sectorLookup, label: "板块")
        }
    }

    private var fundAddRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                FormTextField(placeholder: "基金代码 (161725)", text: $newFundCode)
                    .onSubmit { lookupFund() }
                searchButton(
                    code: newFundCode,
                    lastSearched: lastSearchedFundCode,
                    isSearching: fundLookup.isSearching,
                    action: { lookupFund() }
                )
            }
            lookupRow(state: fundLookup, label: "基金")
        }
    }

    /// 搜索按钮：与输入框等高（30pt），三种状态循环
    /// - 就绪态（代码未改 / 搜索完成）：无底色 + 主色放大镜
    /// - 待搜索态（代码已改尚未搜索）：主色底 + 深色放大镜
    /// - 搜索中：无底色 + 主色放大镜 + 旋转
    @ViewBuilder
    private func searchButton(code: String, lastSearched: String, isSearching: Bool, action: @escaping () -> Void) -> some View {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        let needsSearch = !trimmed.isEmpty && trimmed.uppercased() != lastSearched.uppercased() && !isSearching
        Button(action: action) {
            AppIcon(name: "search", size: 12)
                .foregroundColor(needsSearch ? Color(red: 0.13, green: 0.15, blue: 0.16) : Color.brandGold)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(needsSearch ? Color.brandGold : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(trimmed.isEmpty || isSearching)
        .rotationEffect(isSearching ? .degrees(360) : .zero)
        .animation(isSearching ? .linear(duration: 1).repeatForever(autoreverses: false) : .easeInOut(duration: 0.2), value: isSearching)
        .help("查询名称")
    }
    @ViewBuilder
    private func lookupRow(state: LookupState, label: String) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("查询中…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        case .found(let name):
            HStack(spacing: 6) {
                AppIcon(name: "check-circle", size: 10)
                    .foregroundColor(.down)
                Text(name)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    if label == "板块" {
                        addSector()
                    } else {
                        addFund()
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.brandGold)
                .help("添加\(label)")
            }
        case .notFound:
            HStack(spacing: 4) {
                    AppIcon(name: "warning", size: 10)
                    .foregroundColor(.orange)
                Text("未找到该\(label)，请检查代码")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                // 识别失败时仍允许手动添加（用代码作名称）
                Button {
                    if label == "板块" {
                        addSector()
                    } else {
                        addFund()
                    }
                } label: {
                    Text("仍要添加")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("用代码作为名称添加")
            }
        }
    }
}
