//
//  SlotCellView.swift
//  Discbot
//
//  Individual slot cell in the inventory grid
//

import SwiftUI

struct SlotCellView: View {
    let slot: Slot
    let isSelected: Bool
    var cellSize: CGSize = CGSize(width: 40, height: 50)

    @State private var isHovered = false

    // Computed sizes based on cell size
    private var indicatorSize: CGFloat { cellSize.width * 0.8 }
    private var iconSize: CGFloat { cellSize.width * 0.3 }
    private var fontSize: CGFloat { max(8, cellSize.width * 0.225) }

    var body: some View {
        VStack(spacing: cellSize.height * 0.08) {
            statusIndicator
            slotLabel
        }
        .frame(width: cellSize.width, height: cellSize.height)
        .background(cellBackground)
        .overlay(cellBorder)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .background(TooltipView(tooltip: tooltipText))
    }

    private var statusIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: indicatorSize * 0.19)
                .fill(backgroundColor)
                .frame(width: indicatorSize, height: indicatorSize)
                .shadow(color: shadowColor, radius: isSelected ? 4 : 2, x: 0, y: 1)

            indicatorIcon

            // Backup status badge
            if slot.isFull {
                backupBadge
                    .offset(x: indicatorSize * 0.35, y: indicatorSize * 0.35)
            }
        }
    }

    @ViewBuilder
    private var backupBadge: some View {
        let badgeSize = max(10, indicatorSize * 0.4)
        switch slot.backupStatus {
        case .backedUp:
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: badgeSize, height: badgeSize)
                SFSymbol(name: "checkmark", size: badgeSize * 0.6)
                    .foregroundColor(.white)
            }
        case .failed:
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: badgeSize, height: badgeSize)
                SFSymbol(name: "xmark", size: badgeSize * 0.6)
                    .foregroundColor(.white)
            }
        case .notBackedUp:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indicatorIcon: some View {
        if slot.isInDrive {
            SFSymbol(name: "play.fill", size: iconSize)
                .foregroundColor(.white)
        } else if slot.hasException {
            SFSymbol(name: "exclamationmark.triangle.fill", size: iconSize)
                .foregroundColor(.white)
        } else if slot.isFull {
            SFSymbol(name: "circle.fill", size: iconSize)
                .foregroundColor(Color.white.opacity(0.9))
        } else {
            EmptyView()
        }
    }

    private var slotLabel: some View {
        Text("\(slot.id)")
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .foregroundColor(isSelected ? .accentColor : .secondary)
    }

    private var cellBackground: some View {
        RoundedRectangle(cornerRadius: cellSize.width * 0.2)
            .fill(backgroundFill)
    }

    private var backgroundFill: Color {
        if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return Color.primary.opacity(0.05)
        } else {
            return Color.clear
        }
    }

    private var cellBorder: some View {
        RoundedRectangle(cornerRadius: cellSize.width * 0.2)
            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
    }

    private var backgroundColor: Color {
        if slot.isInDrive {
            return Color.accentColor
        } else if slot.hasException {
            return Color.red
        } else if slot.isFull {
            return Color(NSColor.systemGreen)
        } else {
            return Color(NSColor.quaternaryLabelColor)
        }
    }

    private var shadowColor: Color {
        if slot.isInDrive {
            return Color.accentColor.opacity(0.4)
        } else if slot.isFull {
            return Color.green.opacity(0.3)
        } else {
            return Color.black.opacity(0.1)
        }
    }

    private var tooltipText: String {
        var text = "Slot \(slot.id)"
        if slot.isInDrive {
            text += " (In Drive)"
        } else if slot.isFull {
            text += " (Full)"
        } else {
            text += " (Empty)"
        }
        if slot.hasException {
            text += " - Exception"
        }
        switch slot.backupStatus {
        case .backedUp(let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            text += " - Backed up \(formatter.string(from: date))"
        case .failed:
            text += " - Backup failed"
        case .notBackedUp:
            break
        }
        return text
    }
}

// Tooltip wrapper for macOS 10.15
struct TooltipView: NSViewRepresentable {
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

#if DEBUG
struct SlotCellView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 8) {
            SlotCellView(slot: Slot(id: 1, address: 4, isFull: true), isSelected: false)
            SlotCellView(slot: Slot(id: 2, address: 5, isFull: false), isSelected: false)
            SlotCellView(slot: Slot(id: 3, address: 6, isFull: true, isInDrive: true), isSelected: false)
            SlotCellView(slot: Slot(id: 4, address: 7, isFull: true, hasException: true), isSelected: false)
            SlotCellView(slot: Slot(id: 5, address: 8, isFull: true), isSelected: true)
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}
#endif
