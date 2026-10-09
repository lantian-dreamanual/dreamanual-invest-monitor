import SwiftUI
import AppKit

/// 主面板：Tab 切换（黄金 / 板块 / 基金），设置页为独立页面（底部齿轮进入）
struct MainPanelView: View {
    @ObservedObject var controller: MenuBarController
    @State private var tab: Tab = .gold
    @State private var showSettings = false
    // 自绘下拉的浮层模型：DmMenuPicker 在面板各处（头部/设置页/弹窗）都要用
    @StateObject private var dropdown = DropdownModel()

    enum Tab: String, CaseIterable {
        case gold = "黄金"
        case cpo = "板块"
        case fund = "基金"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // 更新提示横幅（仅在非设置页且有新版本时显示）
            if !showSettings, let update = controller.updateChecker.availableUpdate {
                UpdateBanner(
                    version: update.version,
                    notes: update.notes,
                    downloadUrl: update.downloadUrl,
                    onIgnore: { controller.updateChecker.ignoreCurrentVersion() }
                )
                Divider()
            }
            if showSettings {
                SettingsView(controller: controller)
            } else {
                content
                if let err = controller.errorMessage {
                    Divider()
                    HStack(spacing: DmSpace.s4) {
                        LucideIcon("warning", size: DmIcon.i10)
                            .foregroundColor(Color.dmWarn)
                        Text(err)
                            .font(.system(size: DmText.t11))
                            .foregroundColor(Color.dmInk2)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, DmSpace.s12)
                    .padding(.vertical, DmSpace.s4)
                }
            }
        }
        .frame(width: 400, height: 500)
        .background(Color.dmPanel)
        // 预警弹窗（自绘模态，取代系统 .sheet —— macOS 26 的 sheet 玻璃外壳
        // 在面板上多包一圈边）。挂在根部：遮罩盖满整个 400×500 面板。
        .dmModal(
            isPresented: controller.showAddAlert,
            onDismiss: { controller.showAddAlert = false }
        ) {
            AddAlertSheet(controller: controller, isPresented: $controller.showAddAlert)
        }
        .dmModal(
            isPresented: controller.editingRule != nil,
            onDismiss: { controller.editingRule = nil }
        ) {
            if let rule = controller.editingRule {
                EditAlertSheet(
                    controller: controller,
                    rule: rule,
                    isPresented: Binding(
                        get: { controller.editingRule != nil },
                        set: { if !$0 { controller.editingRule = nil } }
                    )
                )
            }
        }
        // 自绘下拉浮层：挂在弹窗之后（盖住弹窗在内的全部内容），点遮罩关
        .overlay { DmDropdownOverlay() }
        .environmentObject(dropdown)
        .onReceive(controller.$pendingTab) { target in
            if let target = target {
                // 通知点击触发的 Tab 切换：先退出设置页（如果在），再切 Tab
                if showSettings { showSettings = false }
                withAnimation(.easeInOut(duration: DmMotion.fast)) {
                    tab = target
                }
                // 清空标记，避免重复触发
                DispatchQueue.main.async {
                    controller.pendingTab = nil
                }
            }
        }
    }

    // 顶部标题栏：正常态「投资监控 + 倒计时 + 齿轮」，设置态「设置 + 叉号」
    private var header: some View {
        HStack {
            Text(showSettings ? "设置" : "Dreamanual 投资监控")
                .font(.system(size: DmText.t15, weight: .semibold))
            Spacer()
            if showSettings {
                IconButton(iconName: "close") {
                    showSettings = false
                }
                .help("返回")
            } else {
                if controller.allMarketsClosed {
                    Text(controller.panelStatusText)
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                } else if controller.countdown == 0 {
                    Text(controller.panelStatusText)
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                } else if controller.isLoading {
                    Text("刷新中…")
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                } else {
                    Text("\(controller.countdown) 秒后更新")
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk3)
                        .monospacedDigit()
                }
                IconButton(iconName: "gear") {
                    showSettings = true
                }
                .help("设置")
            }
        }
        .padding(.horizontal, DmSpace.s16)
        .padding(.vertical, DmSpace.s10)
    }

    // Tab 切换
    private var content: some View {
        VStack(spacing: 0) {
            SegmentedTabs(items: Tab.allCases, selection: $tab) { t in
                t.rawValue
            }
            .padding(.horizontal, DmSpace.s16)
            .padding(.top, DmSpace.s10)
            .padding(.bottom, DmSpace.s8)

            // 板块页内多板块切换（仅板块 Tab 时显示，不占位）
            if tab == .cpo && controller.configStore.config.sectors.count > 1 {
                sectorPicker
            }

            // 三个 Tab 常驻保留，切换用 opacity + allowsHitTesting 控制显隐，
            // 避免每次切换销毁重建视图导致的卡顿
            ZStack {
                GoldView(controller: controller)
                    .opacity(tab == .gold ? 1 : 0)
                    .allowsHitTesting(tab == .gold)
                    .accessibilityHidden(tab != .gold)
                SectorView(controller: controller)
                    .opacity(tab == .cpo ? 1 : 0)
                    .allowsHitTesting(tab == .cpo)
                    .accessibilityHidden(tab != .cpo)
                FundView(controller: controller)
                    .opacity(tab == .fund ? 1 : 0)
                    .allowsHitTesting(tab == .fund)
                    .accessibilityHidden(tab != .fund)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    // 板块切换选择器（字段壳：悬空在面板头部，裸触发没依托 —— 2026-10-09 用户反馈）
    private var sectorPicker: some View {
        DmMenuPicker(
            selection: $controller.currentSectorCode,
            items: controller.configStore.config.sectors.map { .init(value: $0.code, label: $0.name) },
            style: .field
        )
        .onChange(of: controller.currentSectorCode) { newCode in
            // 方案C：切换板块只刷新当前板块相关数据，不再触发全量 refresh
            Task { await controller.refreshSector(code: newCode) }
        }
        .padding(.horizontal, DmSpace.s16)
        .padding(.top, DmSpace.s6)
        .padding(.bottom, DmSpace.s10)
    }
}

/// 更新提示横幅
struct UpdateBanner: View {
    let version: String
    let notes: String?
    let downloadUrl: String
    let onIgnore: () -> Void

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            LucideIcon("update", size: DmIcon.i16)
                .foregroundColor(Color.dmAccent)

            VStack(alignment: .leading, spacing: DmSpace.s2) {
                Text("发现新版本 v\(version)")
                    .font(.system(size: DmText.t12, weight: .medium))
                    .foregroundColor(Color.dmInk)
                if let notes, !notes.isEmpty {
                    Text(notes)
                        .font(.system(size: DmText.t10))
                        .foregroundColor(Color.dmInk2)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                if let url = URL(string: downloadUrl) { NSWorkspace.shared.open(url) }
            } label: {
                Text("下载更新")
            }
            .buttonStyle(PrimaryButtonStyle())

            IconButton(iconName: "close") {
                onIgnore()
            }
            .help("忽略此版本")
        }
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s8)
        .background(Color.dmPanel2)
    }
}

/// 黄金页
struct GoldView: View {
    @ObservedObject var controller: MenuBarController

    var body: some View {
        ScrollView {
            VStack(spacing: DmSpace.s14) {
                if let g = controller.gold {
                    // 头部卡片
                    FormCard {
                        PriceHeader(
                            title: "沪金主连 (CNY/g)",
                            marketStatus: controller.goldMarketStatus,
                            price: String(format: "¥%.2f", g.priceCNY),
                            changePct: g.changePct,
                            secondary: nil,
                            quoteAt: g.quoteAt
                        )
                    }

                    // 分时图卡片
                    if let trend = controller.goldTrendData {
                        FormCard {
                            TrendChart(trend: trend, mode: .shfeGold)
                        }
                    }
                } else {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
            .padding(DmSpace.s14)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 信息小格
struct InfoCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: DmSpace.s2) {
            Text(label)
                .font(.system(size: DmText.t11))
                .foregroundColor(Color.dmInk2)
            Text(value)
                .font(.system(size: DmText.t13, weight: .medium))
        }
        .frame(maxWidth: .infinity)
    }
}