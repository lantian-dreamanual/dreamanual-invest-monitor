import SwiftUI
import AppKit

/// 界面结构门禁（出图侧）：把设置页渲染成 PNG，交给 analyze.py 判读。
///
/// 这里只做「渲染 + 导出」，不做像素判读 —— 取像素这件事在本机有几条路都不通，
/// 详见 analyze.py 顶部注释。Swift 侧只保留一条实测可靠的路径：
/// `bitmapImageRepForCachingDisplay` → `cacheDisplay` → `representation(.png)`。
@main
struct UIShot {
    static var failures = 0

    /// 找出页面的真实内容高度：ScrollView 的 documentView 有多高，内容就有多高。
    /// 不用「把窗口开得足够高」的做法 —— 那样导出的图片高度恒等于窗口高，
    /// 跟内容无关，图片下方还会留一大片空白，而高度读数也失去意义。
    static func contentHeight(of view: NSView) -> CGFloat? {
        if let sv = view as? NSScrollView, let doc = sv.documentView {
            return doc.frame.height
        }
        for sub in view.subviews {
            if let h = contentHeight(of: sub) { return h }
        }
        return nil
    }

    static func main() {
        let outDir = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : NSTemporaryDirectory() + "/invest-ui-selfcheck"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let ctrl = MenuBarController()
        // 补上 app 里那层面板底色（MainPanelView 的 .background）：
        // 不补的话 ScrollView 外面是透明像素，与「纯黑」无法区分
        let root = SettingsView(controller: ctrl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.panelBackground)
        let hosting = NSHostingView(rootView: root)
        // 先给一个足够高的窗口量内容高度，再收到内容高度上重新布局
        let probeHeight: CGFloat = 3000
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: probeHeight)

        let win = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.contentView = hosting
        win.orderFrontRegardless()

        var queue: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

        func step() {
            guard !queue.isEmpty else {
                NSApp.terminate(nil)
                exit(failures == 0 ? 0 : 1)
            }
            let (name, appearance) = queue.removeFirst()
            hosting.appearance = NSAppearance(named: appearance)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                hosting.layoutSubtreeIfNeeded()

                // 把窗口收到内容高度：图片高度 = 内容高度，「整页高」才是有效读数。
                // 收完要再布局一次（布局可能反过来影响内容高度），量两轮取稳定值。
                for _ in 0..<2 {
                    guard let h = contentHeight(of: hosting), h > 100 else { break }
                    if abs(h - hosting.frame.height) < 0.5 { break }
                    hosting.frame = NSRect(x: 0, y: 0, width: 400, height: h)
                    win.setContentSize(NSSize(width: 400, height: h))
                    hosting.layoutSubtreeIfNeeded()
                }
                guard let measured = contentHeight(of: hosting), measured > 100 else {
                    print("  ✗ \(name): 量不到内容高度（没找到 ScrollView 的 documentView？）")
                    failures += 1
                    return
                }
                hosting.frame = NSRect(x: 0, y: 0, width: 400, height: measured)
                win.setContentSize(NSSize(width: 400, height: measured))
                hosting.layoutSubtreeIfNeeded()

                defer { step() }
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    print("  ✗ \(name): 创建缓存位图失败")
                    failures += 1
                    return
                }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]), !png.isEmpty else {
                    print("  ✗ \(name): 导出 PNG 失败")
                    failures += 1
                    return
                }
                let path = "\(outDir)/settings-\(name).png"
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    print("  ✓ 已渲染 \(name) 主题 → \(path)（\(png.count) 字节，"
                          + "\(rep.pixelsWide)x\(rep.pixelsHigh)，内容高 \(measured)pt）")
                } catch {
                    print("  ✗ \(name): 写文件失败 \(error)")
                    failures += 1
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step() }
        app.run()
    }
}
