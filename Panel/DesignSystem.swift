import SwiftUI

// ============ 设计系统：共享组件 ============

// 配色不在本文件里。色值全部来自 DreamanualTheme.invest.swift（design/build.mjs 生成，
// 请勿手改），本文件只负责「哪个角色用哪个令牌」。改色 → 改 design/tokens.json → 重跑
// build.mjs → 用 scripts/check-tokens.mjs 同步并校验。
//
// 令牌角色速查（细节见 design/docs/design-system.md 第二节）：
//   dmAccent      强调文字 / 图标 / 描边
//   dmAccent2     选中态文字 / 焦点环 / 悬停文字
//   dmAccentFill  承载元素的实心块底（按钮、开关打开态、徽章）
//   dmAccentSoft  选中态底（与 dmAccent2 配对）
//   dmPanel / dmPanel2 / dmPanel3   面板 / 卡片 / 高亮行，依次提亮
//   dmInk / dmInk2 / dmInk3         三级正文，依次变暗

/// 交易状态
enum MarketStatus: Equatable {
    case trading   // 交易中
    case delayed   // 数据延迟（交易时段但数据未实时更新）
    case break_    // 午休
    case closed    // 已收盘
}

/// 状态文案与配色的**单一来源**
///
/// 原先同一句话散在三处：枚举、badge 里的 switch、控制器的字符串赋值。
/// 改文案要记住改三个地方，漏一个就出现「徽标说已收盘、右上角说交易中」。
/// 现在枚举只负责 kind，文案只在这里出现一次，控制器与徽标都从这里取。
struct StatusDescriptor: Equatable {
    enum Tone { case live, warn, quiet }

    let text: String
    let tone: Tone

    static let trading = StatusDescriptor(text: "交易中", tone: .live)
    static let delayed = StatusDescriptor(text: "数据延迟", tone: .warn)
    static let break_ = StatusDescriptor(text: "午休", tone: .quiet)
    static let closed = StatusDescriptor(text: "已收盘", tone: .quiet)
    /// 场内休市、场外净值在披露（15:00–21:00）—— 面板状态用，不对应某个市场
    static let navUpdating = StatusDescriptor(text: "净值更新中", tone: .quiet)

    static func of(_ s: MarketStatus) -> StatusDescriptor {
        switch s {
        case .trading: return .trading
        case .delayed: return .delayed
        case .break_: return .break_
        case .closed: return .closed
        }
    }

    /// 徽章的字色取各族的**亮档**（`-ink` / `accent-2`），因为它是压在自己那族的
    /// 深色底上（见下面的 `background`）；族基色只压中性底 —— 族色压本族 soft 底
    /// 到不了 4.5:1（red-500 压 red-950 只有 4.29:1，四个族都一样）。见设计系统第三节。
    var color: Color {
        switch tone {
        case .live: return .dmAccent2
        case .warn: return .dmWarnInk
        case .quiet: return .dmInk3
        }
    }

    var background: Color {
        switch tone {
        case .live: return .dmAccentSoft
        case .warn: return .dmWarnSoft
        case .quiet: return .dmPanel
        }
    }
}

/// 交易状态标签
struct MarketStatusBadge: View {
    let status: MarketStatus

    var body: some View {
        let d = StatusDescriptor.of(status)
        Text(d.text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(d.background)
            .foregroundColor(d.color)
            .cornerRadius(6)
    }
}

// ============ 设计系统：分段控件 ============

/// 自定义分段控件：对齐 macOS Tahoe 系统设置样式
/// 选中态 = `dmAccentSoft` 深底 + `dmAccent2` 亮字（与密码管理、视频下载同一套表达）；
/// 未选中 = 透明 + 次要色文字
/// 解决 nonactivatingPanel 下系统分段控件选中态变灰的问题
struct SegmentedTabs<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    var label: (T) -> String
    var style: Style = .default

    enum Style {
        case `default`      // 主 Tab：通栏等宽
        case compact        // 表单内：跟随内容宽度
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { idx, item in
                let selected = item == selection
                let isLast = idx == items.count - 1
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundColor(selected ? Color.dmAccent2 : Color.dmInk2)
                        .lineLimit(1)
                        .padding(.horizontal, style == .default ? 16 : 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.dmAccentSoft)
                                .opacity(selected ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.dmPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.dmLine2, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// ============ 设计系统：自定义图标 ============

/// 统一加载 app bundle 内的 Lucide 图标（PNG template 模式）
/// 用法：AppIcon("gear", size: 14).foregroundColor(Color.dmInk2)
struct AppIcon: View {
    let name: String
    var size: CGFloat = 14

    var body: some View {
        if let nsImage = NSImage(named: "icon-\(name)") ?? loadFromBundle("icon-\(name)") {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            // fallback：找不到资源时显示占位
            Image(systemName: "questionmark")
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
        }
    }

    private func loadFromBundle(_ name: String) -> NSImage? {
        let bundle = Bundle.main
        if let path = bundle.path(forResource: name, ofType: "png", inDirectory: "icons") {
            return NSImage(contentsOfFile: path)
        }
        if let path = bundle.path(forResource: name, ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
}

// ============ 设计系统：图标按钮 ============

/// 带悬浮反馈的图标按钮：解决 nonactivatingPanel 下 .borderless/.plain 无悬浮态问题
/// 悬浮时背景变亮 + 图标颜色提亮，让用户感知可点击
struct IconButton: View {
    let iconName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            AppIcon(name: iconName, size: 14)
                .foregroundColor(isHovered ? Color.dmInk : Color.dmInk2)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.dmPanel3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// ============ 设计系统：品牌开关 ============

/// 金色开关：对齐 macOS 系统开关形态（胶囊轨道 + 滑块），开启态用品牌金 + 深色滑块
struct GoldToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            RoundedRectangle(cornerRadius: 9.5, style: .continuous)
                .fill(configuration.isOn ? Color.dmAccentFill : Color.dmPanel3)
                .frame(width: 32, height: 19)
                .overlay(
                    GeometryReader { geo in
                        Circle()
                            .fill(configuration.isOn ? Color.dmOnAccent : Color.dmInk)
                            .frame(width: 13, height: 13)
                            .offset(
                                x: configuration.isOn ? geo.size.width - 15 : 2,
                                y: (geo.size.height - 13) / 2
                            )
                    }
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
    }
}

// ============ 设计系统：表单组件 ============

/// 表单标签：统一 12pt secondary，与控件间距 6pt
struct FormLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Color.dmInk2)
    }
}

/// 自定义输入框：可见边框 + 聚焦高亮，解决系统默认边框不可见问题
/// - 高度 28pt，圆角 6pt，底色 `dmPanel3`（高亮行档），边框 `dmLine2` 常态 / `dmAccent2` 聚焦
struct FormTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.dmPanel3)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isFocused ? Color.dmAccent2 : Color.dmLine2,
                        lineWidth: isFocused ? 1.5 : 0.5
                    )
            )
            .cornerRadius(6)
            .frame(height: 30)
            .frame(width: width)
    }
}

/// 表单区块：标签 + 内容垂直排列，标签到内容间距 8pt
struct FormSection<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormLabel(text: label)
            content
        }
    }
}

/// 表单卡片容器：统一内边距 14pt、圆角 10pt、可见边框
struct FormCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background(Color.dmPanel2)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.dmLine2, lineWidth: 0.5)
            )
    }
}

/// 行情卡片容器：圆角12、边框0.10、内边距14，对齐 macOS Tahoe 内容卡片风格
struct MarketCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // 与 SettingsCard 同源风险：content 若是多个平铺子视图（TupleView），下面这组
        // modifier 会逐个分发到每个子视图上，卡片被打散成多个小块。先收进 spacing:0
        // 的 VStack 再套样式，将来调用点怎么写都不会重演。
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(Color.dmPanel2)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.dmLine2, lineWidth: 0.5)
        )
    }
}

/// 设置页卡片：内容区，对齐 macOS Tahoe 系统设置列表风格（标题在卡片外）
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // 内容先收进 spacing:0 的 VStack：content 若是多个平铺子视图（ViewBuilder 的
        // TupleView），下面这组 modifier 会**逐个分发到每个子视图**上 —— 背景与描边
        // 各画一遍，一张卡片被打散成 N 个独立小卡片，行间还会多出隐式间距。
        VStack(spacing: 0) {
            content
        }
        .background(Color.dmPanel2)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.dmLine2, lineWidth: 0.5)
        )
    }
}

/// 统一行情头部：标签 + 状态 → 大价格 → 涨跌 + 次要信息 + 行情时间
struct PriceHeader: View {
    let title: String
    let marketStatus: MarketStatus?      // nil = 不显示状态标签
    let price: String               // 格式化后的价格文本
    let changePct: Double           // 涨跌幅 %
    let secondary: String?          // 可选次要信息，如 "成交额 12.3亿"
    /// 行情**自身**时间（f124）。区别于右上角的刷新倒计时 ——
    /// 那个说的是「下一次什么时候抓」，这个说的是「这份数是什么时候的」
    var quoteAt: Date? = nil

    var body: some View {
        VStack(spacing: 4) {
            // 标签行
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(Color.dmInk2)
                if let status = marketStatus {
                    MarketStatusBadge(status: status)
                }
            }

            // 大价格
            Text(price)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(Color.trend(changePct))

            // 涨跌幅 + 次要信息 + 行情时间
            HStack(spacing: 12) {
                Text(Format.pct(changePct))
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Color.trend(changePct))
                if let sec = secondary {
                    Text(sec)
                        .font(.caption2)
                        .foregroundColor(Color.dmInk2)
                }
                Spacer(minLength: 6)
                if let fresh = DataFreshness.display(quoteAt: quoteAt, status: marketStatus ?? .closed) {
                    Text(fresh.text)
                        .font(.system(size: 10))
                        .foregroundColor(fresh.isStale ? StatusDescriptor.delayed.color : Color.dmInk3)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
