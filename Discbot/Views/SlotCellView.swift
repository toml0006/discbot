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
    var isSelectedForRip: Bool = false
    var cellSize: CGSize = CGSize(width: 40, height: 50)

    @State private var isHovered = false

    // Computed sizes
    private var iconSize: CGFloat { max(12, cellSize.width * 0.35) }
    private var fontSize: CGFloat { max(8, cellSize.width * 0.22) }
    private var cornerRadius: CGFloat { min(8, cellSize.width * 0.15) }
    private var showMetadata: Bool { cellSize.width >= 55 }
    private var accentHeight: CGFloat { max(3, cellSize.width * 0.06) }

    var body: some View {
        VStack(spacing: 0) {
            // Thin accent bar at top for disc type
            if slot.isFull || slot.isInDrive {
                accentBar
            } else {
                Color.clear.frame(height: accentHeight)
            }

            Spacer(minLength: 0)

            // Icon
            tileIcon
                .frame(height: iconSize)

            Spacer(minLength: 2)

            // Slot number
            slotLabel

            // Metadata (at larger sizes)
            if showMetadata && (slot.isFull || slot.isInDrive) {
                metadataLabel
                    .padding(.top, 1)
            }

            Spacer(minLength: 3)
        }
        .frame(width: cellSize.width, height: cellSize.height)
        .background(tileBackground)
        .overlay(tileBorder)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .background(TooltipView(tooltip: tooltipText))
    }

    // MARK: - Accent Bar

    private var accentBar: some View {
        Rectangle()
            .fill(accentColor)
            .frame(height: accentHeight)
    }

    // MARK: - Icon

    @ViewBuilder
    private var tileIcon: some View {
        if slot.isInDrive {
            SFSymbol(name: "play.fill", size: iconSize)
                .foregroundColor(accentColor)
        } else if slot.hasException {
            SFSymbol(name: "exclamationmark.triangle.fill", size: iconSize)
                .foregroundColor(.red)
        } else if slot.isFull {
            SFSymbol(name: slot.discType.iconName, size: iconSize)
                .foregroundColor(accentColor)
        } else {
            // Empty slot - faint circle
            SFSymbol(name: "circle.dashed", size: iconSize * 0.7)
                .foregroundColor(Color.primary.opacity(0.12))
        }
    }

    // MARK: - Labels

    private var slotLabel: some View {
        Text("\(slot.id)")
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundColor(labelColor)
    }

    @ViewBuilder
    private var metadataLabel: some View {
        let metaFontSize = max(7, fontSize * 0.75)
        if let label = slot.volumeLabel, !label.isEmpty {
            Text(label)
                .font(.system(size: metaFontSize, design: .rounded))
                .foregroundColor(Color.secondary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: cellSize.width - 6)
        } else if slot.discType != .unscanned {
            Text(slot.discType.label)
                .font(.system(size: metaFontSize, design: .rounded))
                .foregroundColor(Color.secondary.opacity(0.5))
                .lineLimit(1)
        }
    }

    private var labelColor: Color {
        if isSelectedForRip {
            return .orange
        } else if isSelected {
            return .accentColor
        } else {
            return .secondary
        }
    }

    // MARK: - Background & Border

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(backgroundFill)
    }

    private var backgroundFill: Color {
        if isSelectedForRip {
            return Color.orange.opacity(0.1)
        } else if isSelected {
            return Color.accentColor.opacity(0.08)
        } else if isHovered {
            return Color.primary.opacity(0.06)
        } else if slot.isFull || slot.isInDrive {
            return Color.primary.opacity(0.04)
        } else {
            return Color.primary.opacity(0.02)
        }
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(borderColor, lineWidth: (isSelected || isSelectedForRip) ? 2 : 0.5)
    }

    private var borderColor: Color {
        if isSelectedForRip {
            return Color.orange
        } else if isSelected {
            return Color.accentColor
        } else {
            return Color.primary.opacity(0.08)
        }
    }

    // MARK: - Accent Color (subtle, per disc type)

    private var accentColor: Color {
        if slot.isInDrive {
            return Color.accentColor
        } else if slot.hasException {
            return Color.red
        } else {
            return discTypeAccent
        }
    }

    private var discTypeAccent: Color {
        switch slot.discType {
        case .audioCDDA:   return Color.purple
        case .dvd:         return Color(NSColor.systemGreen)
        case .dataCD:      return Color.blue
        case .mixedModeCD: return Color.orange
        case .unknown:     return Color.secondary
        case .unscanned:   return Color.secondary
        }
    }

    // MARK: - Tooltip

    private var tooltipText: String {
        var text = "Slot \(slot.id)"
        if slot.isInDrive {
            text += " (In Drive)"
        } else if slot.isFull {
            text += " (\(slot.discType.label))"
        } else {
            text += " (Empty)"
        }
        if let label = slot.volumeLabel {
            text += " - \(label)"
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
            SlotCellView(slot: Slot(id: 1, address: 4, isFull: true, discType: .audioCDDA, volumeLabel: "Abbey Road"), isSelected: false, cellSize: CGSize(width: 60, height: 78))
            SlotCellView(slot: Slot(id: 2, address: 5, isFull: false), isSelected: false, cellSize: CGSize(width: 60, height: 78))
            SlotCellView(slot: Slot(id: 3, address: 6, isFull: true, isInDrive: true, discType: .dvd, volumeLabel: "Interstellar"), isSelected: false, cellSize: CGSize(width: 60, height: 78))
            SlotCellView(slot: Slot(id: 4, address: 7, isFull: true, hasException: true), isSelected: false, cellSize: CGSize(width: 60, height: 78))
            SlotCellView(slot: Slot(id: 5, address: 8, isFull: true, discType: .dataCD, volumeLabel: "BACKUP_2021"), isSelected: true, cellSize: CGSize(width: 60, height: 78))
            SlotCellView(slot: Slot(id: 6, address: 9, isFull: true, discType: .unscanned), isSelected: false, cellSize: CGSize(width: 60, height: 78))
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}
#endif
