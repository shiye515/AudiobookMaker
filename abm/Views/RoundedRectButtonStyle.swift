//
//  RoundedRectButtonStyle.swift
//  abm
//
//  全局按钮样式：小圆角矩形（6pt），替代系统胶囊大圆角。
//

import SwiftUI

/// 普通按钮：浅灰底圆角矩形（根视图统一应用，全部按钮生效）。
struct RoundedRectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// 主操作按钮：强调色填充圆角矩形（导入 / 一键生成 / 导出 / 设为默认旁白）。
struct RoundedRectProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .foregroundStyle(.white)
    }
}

extension View {
    /// 工具栏按钮自绘圆角底（配合 .buttonStyle(.plain) 去掉系统 Liquid Glass 白底）
    @ViewBuilder
    func roundedRectChrome(prominent: Bool = false) -> some View {
        self
            .font(.callout.weight(prominent ? .medium : .regular))
            .padding(.horizontal, prominent ? 12 : 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent
                          ? AnyShapeStyle(Color.accentColor)
                          : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
            .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
    }
}

// MARK: - 移除系统工具栏按钮边框背景

/// 移除窗口工具栏项目默认的系统边框（bezel / Liquid Glass 白色胶囊背景），
/// 使工具栏中的按钮与控件保持自定义或纯透明外观。
final class ToolbarBezelRemoverView: NSView {
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startTimer()
            stripAll()
        } else {
            stopTimer()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopTimer()
        }
    }

    override func layout() {
        super.layout()
        stripAll()
    }

    private func startTimer() {
        stopTimer()
        // 轻量定时巡检，彻底消除重绘或状态切换时系统自动生成的 NSToolbarPlatterView 与 NSGlassEffectView
        let t = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.stripAll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    func scheduleRemoval() {
        stripAll()
        DispatchQueue.main.async { [weak self] in
            self?.stripAll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.stripAll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.stripAll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.stripAll()
        }
    }

    func stripAll() {
        var windows = NSApp.windows
        if let w = self.window, !windows.contains(w) {
            windows.append(w)
        }

        for window in windows {
            // 1. 消除工具栏项目的边框标记
            if let toolbar = window.toolbar {
                for item in toolbar.items {
                    if item.isBordered {
                        item.isBordered = false
                    }
                    if let group = item as? NSToolbarItemGroup {
                        group.isBordered = false
                        for subitem in group.subitems where subitem.isBordered {
                            subitem.isBordered = false
                        }
                    }
                    if let view = item.view {
                        stripButtonBorders(from: view)
                    }
                }
            }

            // 2. 严格限制在标题栏 / 工具栏视图树中查找并隐藏 Platter（NSToolbarPlatterView）
            // 绝不进入 contentView，避免影响侧边栏容器（NSContainerConcentricGlassEffectView）
            if let frameView = window.contentView?.superview {
                for sub in frameView.subviews {
                    let name = String(describing: type(of: sub))
                    if name.contains("Titlebar") || name.contains("Toolbar") {
                        hideToolbarPlatters(in: sub)
                    }
                }
            }

            // 3. 恢复 contentView 内可能被误伤的侧边栏视图
            if let content = window.contentView {
                restoreContentView(content)
            }
        }
    }

    private func stripButtonBorders(from view: NSView) {
        if let button = view as? NSButton {
            button.isBordered = false
            button.showsBorderOnlyWhileMouseInside = false
        }
        for subview in view.subviews {
            stripButtonBorders(from: subview)
        }
    }

    private func hideToolbarPlatters(in view: NSView) {
        let name = String(describing: type(of: view))
        if name.contains("Platter") {
            if !view.isHidden {
                view.isHidden = true
            }
            if view.alphaValue != 0 {
                view.alphaValue = 0
            }
        }
        for sub in view.subviews {
            hideToolbarPlatters(in: sub)
        }
    }

    private func restoreContentView(_ view: NSView) {
        let name = String(describing: type(of: view))
        if name.contains("Glass") {
            if view.isHidden {
                view.isHidden = false
            }
            if view.alphaValue == 0 {
                view.alphaValue = 1.0
            }
        }
        for sub in view.subviews {
            restoreContentView(sub)
        }
    }
}

struct ToolbarBezelRemover: NSViewRepresentable {
    var trigger: AnyHashable? = nil

    func makeNSView(context: Context) -> ToolbarBezelRemoverView {
        ToolbarBezelRemoverView()
    }

    func updateNSView(_ nsView: ToolbarBezelRemoverView, context: Context) {
        nsView.scheduleRemoval()
    }
}

extension View {
    /// 移除当前窗口工具栏上所有项目的系统默认外边框（白色胶囊背景）
    func removeToolbarBezels(trigger: AnyHashable? = nil) -> some View {
        background(ToolbarBezelRemover(trigger: trigger))
    }
}

