//
//  CompatViews.swift
//  Discbot
//
//  macOS 10.15 compatible replacements for newer SwiftUI views
//

import SwiftUI
import AppKit

// MARK: - Simple Icon (text-based for 10.15 compatibility)

struct SFSymbol: View {
    let name: String
    var size: CGFloat = 16

    var body: some View {
        Text(iconText)
            .font(.system(size: size * 0.9))
            .frame(width: size, height: size)
    }

    // Map SF Symbol names to Unicode/emoji equivalents for 10.15
    private var iconText: String {
        switch name {
        case "play.fill": return "▶"
        case "exclamationmark.triangle.fill": return "⚠"
        case "circle.fill": return "●"
        case "circle.dashed": return "○"
        case "server.rack": return "▦"
        case "externaldrive.fill", "externaldrive": return "💾"
        case "arrow.clockwise": return "↻"
        case "arrow.uturn.backward": return "↩"
        case "arrow.right.circle": return "→"
        case "arrow.up.circle": return "↑"
        case "arrow.down.circle": return "↓"
        case "arrow.down.circle.fill": return "⬇"
        case "magnifyingglass": return "🔍"
        case "square.stack.3d.up": return "▤"
        case "tray.and.arrow.up": return "⇧"
        case "bolt.horizontal.circle": return "⚡"
        case "eject": return "⏏"
        case "hand.point.down.fill": return "👇"
        case "circle.grid.3x3": return "⊞"
        case "list.bullet": return "☰"
        case "doc.badge.gearshape": return "📄"
        case "gearshape.2": return "⚙"
        default: return "•"
        }
    }
}

// MARK: - Icon Label

struct IconLabel: View {
    let title: String
    let systemImage: String
    var spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: spacing) {
            SFSymbol(name: systemImage, size: 14)
            Text(title)
        }
    }
}

// MARK: - Indeterminate Spinner (replaces ProgressView())

struct SpinnerView: NSViewRepresentable {
    var style: NSProgressIndicator.Style = .spinning
    var controlSize: NSControl.ControlSize = .regular

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = style
        indicator.controlSize = controlSize
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.style = style
        nsView.controlSize = controlSize
    }
}

// MARK: - Determinate Progress Bar (replaces ProgressView(value:))

struct ProgressBar: NSViewRepresentable {
    var value: Double  // 0.0 to 1.0

    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.doubleValue = value
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {
        nsView.doubleValue = value
    }
}

// MARK: - Frosted Glass Background (replaces .regularMaterial)

struct FrostedBackground: View {
    var body: some View {
        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Capsule Badge

struct CapsuleBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.15))
            )
            .foregroundColor(color)
    }
}

// MARK: - Help Tooltip Extension

extension View {
    func helpTooltip(_ text: String) -> some View {
        self.background(TooltipHelper(tooltip: text))
    }
}

struct TooltipHelper: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

// MARK: - Toggle Button Style

struct ToggleButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isActive ? .accentColor : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// MARK: - Double Extension for UserDefaults

extension Double {
    /// Returns self if non-zero, otherwise returns the default value
    func nonZeroOrDefault(_ defaultValue: Double) -> Double {
        return self == 0 ? defaultValue : self
    }
}
