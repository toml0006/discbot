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
        case "checkmark.circle.fill": return "✓"
        case "opticaldisc": return "◉"
        case "disc.cd.audio": return "♪"
        case "disc.cd.data": return "◉"
        case "disc.cd.mixed": return "◉"
        case "disc.dvd": return "▶"
        case "disc.unknown": return "◉"
        case "disc.unscanned": return "○"
        case "questionmark": return "?"
        case "checkmark": return "✓"
        case "xmark": return "✕"
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

// MARK: - Segmented Action Button Style

struct SegmentedActionStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundColor(isEnabled ? .primary : .secondary)
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.12)
                    : Color.primary.opacity(0.06)
            )
            .opacity(isEnabled ? 1.0 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}

/// A visually connected group of small action buttons
struct SegmentedActions<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 1) {
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let buttonIcon: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            SFSymbol(name: icon, size: 56)
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: action) {
                HStack(spacing: 6) {
                    SFSymbol(name: buttonIcon, size: 14)
                    Text(buttonTitle)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Key Event Handler

struct KeyEventHandler: NSViewRepresentable {
    let onKeyDown: (UInt16, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> KeyEventNSView {
        let view = KeyEventNSView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyEventNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }

    class KeyEventNSView: NSView {
        var onKeyDown: ((UInt16, NSEvent.ModifierFlags) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if let handler = onKeyDown, handler(event.keyCode, event.modifierFlags) {
                return
            }
            super.keyDown(with: event)
        }
    }
}

// MARK: - Search Field (NSSearchField wrapper for 10.15)

struct SearchFieldView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField {
                text.wrappedValue = field.stringValue
            }
        }
    }
}

// MARK: - PopUp Button (NSPopUpButton wrapper for 10.15)

struct PopUpButtonView<T: Hashable>: NSViewRepresentable {
    let items: [(title: String, value: T)]
    @Binding var selection: T

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.removeAllItems()
        for item in items {
            button.addItem(withTitle: item.title)
        }
        if let index = items.firstIndex(where: { $0.value == selection }) {
            button.selectItem(at: index)
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        return button
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        if let index = items.firstIndex(where: { $0.value == selection }) {
            if nsView.indexOfSelectedItem != index {
                nsView.selectItem(at: index)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, selection: $selection)
    }

    class Coordinator: NSObject {
        let items: [(title: String, value: T)]
        var selection: Binding<T>

        init(items: [(title: String, value: T)], selection: Binding<T>) {
            self.items = items
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            if index >= 0 && index < items.count {
                selection.wrappedValue = items[index].value
            }
        }
    }
}

// MARK: - Double Extension for UserDefaults

extension Double {
    /// Returns self if non-zero, otherwise returns the default value
    func nonZeroOrDefault(_ defaultValue: Double) -> Double {
        return self == 0 ? defaultValue : self
    }
}
