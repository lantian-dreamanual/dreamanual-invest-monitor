import AppKit
import SwiftUI
import Combine

/// 可聚焦的 NSPanel：nonactivatingPanel 默认 canBecomeKey 为 false，
/// 导致面板内 TextField 无法获得焦点（输入框点不动）。
/// 覆写后点击输入框时面板可作为 key window 接收键盘输入，同时保持非激活特性。
final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 状态栏控制器：负责状态栏图标、定时刷新、面板弹出
final class MenuBarController: NSObject, ObservableObject {
    @Published var gold: GoldQuote?
    @Published var lastUpdate: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?       // 主要数据（黄金/板块）错误
    @Published var fundErrorMessage: String?    // 基金数据错误（独立显示）
    // M3 板块
    @Published var sector: SectorQuote?
    @Published var sectorStocks: [StockQuote] = []
    // M4 基金
    @Published var funds: [FundDetail] = []
    @Published var fundStockChanges: [String: Double] = [:]
    // M5 配置
    @Published var configStore: ConfigStore
    @Published var allSectors: [SectorQuote] = []   // 所有配置板块指数
    @Published var currentSectorCode: String        // 当前选中板块
    // 分时线
    @Published var trendData: TrendData?       // 板块分时
    @Published var goldTrendData: TrendData?   // 黄金分时
    // M6 预警
    @Published var alertConfig: AlertConfig
    // 刷新倒计时（秒），右上角展示「x 秒后更新」
    @Published var countdown = 30
    // 右上角状态文案
    @Published var allMarketsClosed = false
    @Published var panelStatusText: String = ""
    /// 通知点击后待切换的 Tab（nil 表示无需切换）
    @Published var pendingTab: MainPanelView.Tab?
    /// 版本更新检查器
    @Published var updateChecker = UpdateChecker()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var timer: Timer?
    private var countdownTimer: Timer?
    private let service = GoldService()
    private let sectorService = SectorService()
    private let fundService = FundService()
    private var cancellables = Set<AnyCancellable>()
    private let notifier = AlertNotifier.shared

    override init() {
        let store = ConfigStore()
        self.configStore = store
        self.currentSectorCode = store.config.sectors.first?.code ?? "BK0475"
        self.alertConfig = AlertConfig()
        super.init()
        // configStore 变化转发到 controller，驱动 SwiftUI 视图刷新
        store.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        alertConfig.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        // 请求通知权限
        notifier.requestPermission()
        // 通知点击回调：通过规则 ID 查找标的类型，切换到对应 Tab 并打开面板
        notifier.onNotificationTap = { [weak self] ruleId in
            DispatchQueue.main.async {
                self?.handleNotificationTap(ruleId: ruleId)
            }
        }
        setupStatusItem()
        setupPanel()
        startTimer()
        // 启动后延迟 2 秒检查更新（避免与启动刷新竞争网络）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateChecker.checkForUpdate()
        }
        // 每 6 小时定时检查一次
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.updateChecker.checkForUpdate()
        }
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            // 监听左右键鼠标抬起，区分左键切面板 / 右键弹菜单
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusTitle()
    }

    /// 统一入口：左键 toggle 面板，右键弹出菜单
    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            togglePopover(nil)
            return
        }
        if event.type == .rightMouseUp {
            closePanel() // 右键时先收起面板
            statusItem.popUpMenu(buildContextMenu())
        } else {
            togglePopover(nil)
        }
    }

    /// 右键菜单：退出应用
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    /// 退出应用
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// 更新状态栏文字：根据配置显示黄金或板块指数，交易时段带箭头
    func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let source = configStore.config.statusBarSource ?? "gold"

        if source == "gold" {
            // 黄金
            guard let g = gold else { button.title = "--"; return }
            let title: String
            if goldMarketStatus == .trading || goldMarketStatus == .delayed {
                let arrow = g.changePct >= 0 ? "▲" : "▼"
                title = String(format: "%@ %.2f", arrow, g.priceCNY)
            } else {
                title = String(format: "%.2f", g.priceCNY)
            }
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            )
        } else {
            // 板块指数
            guard let s = allSectors.first(where: { $0.code == source }) ?? sector
            else { button.title = "--"; return }
            let title: String
            if stockMarketStatus == .trading {
                let arrow = s.changePct >= 0 ? "▲" : "▼"
                title = String(format: "%@ %.2f", arrow, s.index)
            } else {
                title = String(format: "%.2f", s.index)
            }
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            )
        }
    }

    // MARK: - 弹窗（自定义 NSPanel，无三角箭头）

    private func setupPanel() {
        let contentView = MainPanelView(controller: self)
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        // 圆角裁剪：面板本身透明，内容视图裁出圆角
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 14
        hosting.layer?.masksToBounds = true

        panel = FocusablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
    }

    @objc private func togglePopover(_ sender: Any?) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        // 弹出前立即刷新一次，保证数据最新
        Task { await refresh() }

        // 定位到状态栏按钮下方居中，屏幕边界内钳制
        let size = panel.frame.size
        let btnFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? button.bounds
        var x = btnFrame.midX - size.width / 2
        let y = btnFrame.minY - size.height - 4
        if let screen = button.window?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        // 延迟启动监控，避免触发弹出的那次点击被 monitor 捕获导致面板瞬关
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.panel.isVisible == true else { return }
            self?.startMonitoring()
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        stopMonitoring()
    }

    // MARK: - 外部点击关闭

    private func startMonitoring() {
        stopMonitoring()
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleOutsideClick() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleOutsideClick()
            return event
        }
    }

    private func stopMonitoring() {
        if let m = globalEventMonitor { NSEvent.removeMonitor(m); globalEventMonitor = nil }
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
    }

    /// 点击面板外部时关闭；点击状态栏按钮区域交给 toggle 逻辑处理，不在此关闭
    private func handleOutsideClick() {
        guard panel.isVisible else { return }
        let mouseLoc = NSEvent.mouseLocation // 屏幕坐标（左下原点），与 panel.frame 同坐标系
        if let button = statusItem.button, let win = button.window {
            let btnFrame = win.convertToScreen(button.convert(button.bounds, to: nil))
                .insetBy(dx: -4, dy: -4)
            if btnFrame.contains(mouseLoc) { return }
        }
        if panel.frame.contains(mouseLoc) { return }
        // 点击落在本 App 的其他窗口（如 SwiftUI Popover、Alert 弹窗等）时不关闭
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(mouseLoc) }) { return }
        closePanel()
    }

    // MARK: - 定时器

    /// 黄金交易时段：夜盘 21:00-02:30 + 日盘 09:00-11:30 / 13:30-15:00（周末休市）
    var goldMarketStatus: MarketStatus {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: Date())
        // 周末休市
        guard weekday != 1 && weekday != 7 else { return .closed }
        let now = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
        // 夜盘 21:00-02:30
        if now >= 21 * 60 || now <= 2 * 60 + 30 {
            return isGoldDataStale ? .delayed : .trading
        }
        // 日盘 09:00-11:30
        if now >= 9 * 60 && now <= 11 * 60 + 30 {
            return isGoldDataStale ? .delayed : .trading
        }
        // 午休 11:30-13:30
        if now > 11 * 60 + 30 && now < 13 * 60 + 30 {
            return .break_
        }
        // 日盘 13:30-15:00
        if now >= 13 * 60 + 30 && now <= 15 * 60 {
            return isGoldDataStale ? .delayed : .trading
        }
        return .closed
    }

    /// A股交易时段：09:30-11:30 + 13:00-15:00
    var stockMarketStatus: MarketStatus {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: Date())
        // 周末休市
        guard weekday != 1 && weekday != 7 else { return .closed }
        let now = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
        if now >= 9 * 60 + 30 && now <= 11 * 60 + 30 { return .trading }
        if now > 11 * 60 + 30 && now < 13 * 60 { return .break_ }
        if now >= 13 * 60 && now <= 15 * 60 { return .trading }
        return .closed
    }

    /// 黄金分时数据是否过期（最后一个数据点距今超过 2 分钟）
    private var isGoldDataStale: Bool {
        guard let lastPoint = goldTrendData?.points.last else { return true }
        let dfmt = DateFormatter()
        dfmt.dateFormat = "yyyy-MM-dd HH:mm"
        dfmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let lastDate = dfmt.date(from: lastPoint.time) else { return true }
        return Date().timeIntervalSince(lastDate) > 120
    }

    /// 任一市场在交易时段（含数据延迟）则刷新；全部休市则停止
    private var anyMarketOpen: Bool {
        goldMarketStatus == .trading || goldMarketStatus == .delayed || stockMarketStatus == .trading
    }

    /// 后台常驻定时器：任一市场交易时段每 30 秒刷新，全部休市时自动暂停
    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.anyMarketOpen {
                Task { await self.refresh() }
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        startCountdownTimer()
        // 启动立即刷新
        Task { await refresh() }
    }

    /// 每秒倒计时，驱动右上角文案
    private func startCountdownTimer() {
        guard countdownTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let gold = self.goldMarketStatus
            let stock = self.stockMarketStatus
            let anyTrading = gold == .trading || gold == .delayed || stock == .trading
            let anyBreak = gold == .break_ || stock == .break_

            if anyTrading {
                self.allMarketsClosed = false
                if self.isLoading { return }
                self.countdown -= 1
                if self.countdown <= 0 { self.countdown = 30 }
            } else if anyBreak {
                self.allMarketsClosed = false
                self.countdown = 0
                self.panelStatusText = "午休"
            } else {
                self.allMarketsClosed = true
                self.countdown = 0
                self.panelStatusText = "已收盘"
            }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    // MARK: - 刷新

    @MainActor
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        defer {
            isRefreshing = false
            isLoading = false
            countdown = 30
        }
        // 板块被删除后，修正当前选中到第一个可用板块
        if !configStore.config.sectors.contains(where: { $0.code == currentSectorCode }) {
            currentSectorCode = configStore.config.sectors.first?.code ?? "BK0475"
        }
        do {
            let sectorCodes = configStore.config.sectors.map { $0.code }
            let sectorName = configStore.config.sectors.first(where: { $0.code == currentSectorCode })?.name ?? ""
            async let goldTask = service.fetch()
            // 当前板块：指数 + 成分股 + 分时线
            async let sectorTask = sectorService.fetchIndex(code: currentSectorCode, name: sectorName)
            async let stocksTask = sectorService.fetchStocks(code: currentSectorCode)
            async let trendsTask = sectorService.fetchTrends(code: currentSectorCode, name: sectorName)
            // 黄金分时线（国际品种，独立拉取）
            async let goldTrendsTask = sectorService.fetchGoldTrends()
            let (g, s, st, td, gtd) = try await (goldTask, sectorTask, stocksTask, trendsTask, goldTrendsTask)
            self.gold = g
            self.sector = s
            self.sectorStocks = st
            self.trendData = td
            self.goldTrendData = gtd

            // 所有板块指数（用于 Tab 快速切换）
            if sectorCodes.count > 1 {
                let sectorQuotes = try await sectorService.fetchIndices(codes: sectorCodes, names: configStore.config.sectors.map { $0.name })
                self.allSectors = sectorQuotes
            } else {
                self.allSectors = [s]
            }

            // M4 基金：净值 + 重仓 + 实时行情估算
            await self.refreshFunds()

            self.lastUpdate = Date()
            self.errorMessage = nil
            self.updateStatusTitle()

            // M6 预警检查
            self.checkAlerts()
        } catch let error as FetchError {
            self.errorMessage = "\(error.localizedDescription)（已显示上次数据）"
            // 保留旧数据
        } catch {
            self.errorMessage = "更新失败，请稍后重试"
        }
    }

    /// 当前板块代码
    private var currentSector: String {
        currentSectorCode
    }

    /// 刷新基金：净值 → 重仓 → 批量行情 → 估算
    @MainActor
    func refreshFunds() async {
        // 立即移除已从配置删除的基金，UI 瞬间反映
        let validCodes = Set(configStore.config.funds.map { $0.code })
        self.funds = self.funds.filter { validCodes.contains($0.quote.code) }

        do {
            let details = try await fundService.fetchAll(codes: configStore.config.funds.map { $0.code })
            // 合并所有重仓股，去重
            var holdings: [(code: String, exchange: Int)] = []
            var seen = Set<String>()
            for d in details {
                for h in d.holdings {
                    let key = h.code
                    if !seen.contains(key) {
                        seen.insert(key)
                        holdings.append((code: h.code, exchange: h.exchange))
                    }
                }
            }
            // 批量拉取实时涨跌
            let changes = try await sectorService.fetchStockChanges(codes: holdings)
            // 计算估算：交易日（非周末）且净值未更新到今日时计算估算，
            // 时段限制在当日 9:30 之后——开盘前重仓股无当日行情，估算无意义
            // 收盘后到净值发布前保留当日估算快照作为参考
            // 净值已更新到今日则估算无意义，不再计算
            let today = Self.todayString()
            let cal = Calendar.current
            let weekday = cal.component(.weekday, from: Date())
            let isTradingDay = weekday != 1 && weekday != 7 // 周一~周五（节假日未做映射）
            let nowMinute = cal.component(.hour, from: Date()) * 60 + cal.component(.minute, from: Date())
            let afterOpen = nowMinute >= 9 * 60 + 30 // 已过 9:30
            var updated = details
            for i in updated.indices {
                guard isTradingDay, afterOpen, updated[i].quote.navDate != today else { continue }
                let pct = FundEstimator.estimateChangePct(holdings: updated[i].holdings, stockMap: changes)
                updated[i].estChangePct = pct
                if let pct {
                    updated[i].estNav = FundEstimator.estimateNav(nav: updated[i].quote.nav, changePct: pct)
                }
            }
            self.funds = updated
            self.fundStockChanges = changes
            self.fundErrorMessage = nil
        } catch let error as FetchError {
            self.fundErrorMessage = "基金数据\(error.localizedDescription)"
            // 基金失败不阻塞主流程，保留旧数据
        } catch {
            self.fundErrorMessage = "基金数据更新失败"
        }
    }

    func refreshNow() async {
        await refresh()
    }

    /// 方案C：切换板块时只刷新当前板块相关数据（指数 + 成分股 + 分时线），
    /// 不触发黄金/基金的增量请求，降低板块切换时的卡顿
    @MainActor
    func refreshSector(code: String) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sectorName = configStore.config.sectors.first(where: { $0.code == code })?.name ?? ""
        do {
            async let sectorTask = sectorService.fetchIndex(code: code, name: sectorName)
            async let stocksTask = sectorService.fetchStocks(code: code)
            async let trendsTask = sectorService.fetchTrends(code: code, name: sectorName)
            let (s, st, td) = try await (sectorTask, stocksTask, trendsTask)
            self.sector = s
            self.sectorStocks = st
            self.trendData = td
        } catch {
            // 板块切换失败保留旧数据，不阻塞主流程
            self.errorMessage = "板块刷新失败（已显示上次数据）"
        }
    }

    // MARK: - 预警

    /// 预警检查：比对最新数据与所有规则，触发通知 + 管理状态
    @MainActor
    func checkAlerts() {
        let values = AlertEngine.extractValues(
            gold: gold, sectors: allSectors, funds: funds
        )
        let (triggerIdx, resetIdx) = AlertEngine.checkAll(
            rules: alertConfig.rules, values: values
        )

        // 触发通知
        for i in triggerIdx {
            let rule = alertConfig.rules[i]
            let key = AlertEngine.ruleKey(rule)
            if let value = values[key] {
                notifier.sendNotification(rule: rule, currentValue: value)
            }
            alertConfig.updateStatus(at: i, triggered: true)
        }

        // 恢复已触发规则
        for i in resetIdx {
            alertConfig.updateStatus(at: i, triggered: false)
        }
    }

    /// 通知点击：通过规则 ID 查找标的类型，切换到对应 Tab 并打开面板
    private func handleNotificationTap(ruleId: String) {
        // 查找规则
        guard let rule = alertConfig.rules.first(where: { $0.id == ruleId }) else {
            // 找不到规则（可能已删除），仅打开面板
            showPanel()
            return
        }

        // 根据标的类型决定切换到哪个 Tab
        switch rule.targetType {
        case .goldCNY:
            pendingTab = .gold
        case .sector:
            pendingTab = .cpo
            // 如果规则关联的板块不是当前板块，切换板块
            if !rule.targetCode.isEmpty && rule.targetCode != currentSectorCode {
                currentSectorCode = rule.targetCode
                Task { await refreshSector(code: rule.targetCode) }
            }
        case .fund:
            pendingTab = .fund
        }

        // 打开面板
        showPanel()
    }

    private var isRefreshing = false

    /// 今日日期字符串 YYYY-MM-DD（用于判断基金净值日期是否为今日）
    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }
}