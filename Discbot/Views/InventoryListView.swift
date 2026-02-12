//
//  InventoryListView.swift
//  Discbot
//
//  List view showing all slots in a table format
//

import SwiftUI

struct InventoryListView: View {
    @EnvironmentObject private var viewModel: ChangerViewModel

    var body: some View {
        ScrollView {
            if viewModel.slots.isEmpty {
                emptyState
            } else if viewModel.filteredSlots.isEmpty {
                filteredEmptyState
            } else {
                listContent
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            // Header row
            headerRow
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Slot rows
            ForEach(viewModel.filteredSlots, id: \.id) { slot in
                SlotRowView(
                    slot: slot,
                    isSelected: slot.id == viewModel.selectedSlotId,
                    isSelectedForRip: viewModel.selectedSlotsForRip.contains(slot.id),
                    onLoad: (slot.isFull && !slot.isInDrive) ? { viewModel.loadSlotWithEjectIfNeeded(slot.id) } : nil
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.selectedSlotId = slot.id
                    if slot.isFull || slot.isInDrive {
                        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                        if modifiers.contains(.shift) {
                            viewModel.extendSlotSelectionForRip(to: slot.id)
                        } else if modifiers.contains(.command) {
                            viewModel.toggleSlotForRip(slot.id)
                        } else {
                            viewModel.selectSlotForRip(slot.id)
                        }
                    }
                }
                .gesture(
                    TapGesture(count: 2)
                        .onEnded {
                            if slot.isFull && !slot.isInDrive {
                                viewModel.loadSlotWithEjectIfNeeded(slot.id)
                            }
                        }
                )
                .contextMenu { slotContextMenu(for: slot) }

                Divider()
                    .padding(.leading, 16)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Slot")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)

            Text("Type")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text("Label")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 180, alignment: .leading)

            Text("Status")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)

            Spacer()
        }
    }

    @ViewBuilder
    private func slotContextMenu(for slot: Slot) -> some View {
        // Load into drive (only if slot has disc and not already in drive)
        if slot.isFull && !slot.isInDrive {
            Button(action: { viewModel.loadSlot(slot.id) }) {
                Text("Load into Drive")
            }
            .disabled(viewModel.currentOperation != nil || viewModel.driveStatus != .empty)
        }

        // Scan disc (load, detect metadata, eject back)
        if slot.isFull && !slot.isInDrive {
            Button(action: { viewModel.scanSlotDisc(slot.id) }) {
                Text("Scan Disc")
            }
            .disabled(viewModel.currentOperation != nil || viewModel.driveStatus != .empty)
        }

        // Eject disc (only if slot has disc and not in drive)
        if slot.isFull && !slot.isInDrive && viewModel.hasIESlot {
            Button(action: { viewModel.unloadSlot(slot.id) }) {
                Text("Eject Disc")
            }
            .disabled(viewModel.currentOperation != nil)
        }

        // Load from I/E (only if slot is empty)
        if !slot.isFull && !slot.isInDrive && viewModel.hasIESlot {
            Button(action: { viewModel.importToSlot(slot.id) }) {
                Text("Load from I/E")
            }
            .disabled(viewModel.currentOperation != nil)
        }

        // Eject drive disc here (if disc is in drive, eject to this slot)
        if !slot.isFull && !slot.isInDrive {
            if case .loaded = viewModel.driveStatus {
                Button(action: { viewModel.ejectDisc(toSlot: slot.id) }) {
                    Text("Eject Here")
                }
                .disabled(viewModel.currentOperation != nil)
            }
        }
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            SFSymbol(name: "magnifyingglass", size: 36)
                .foregroundColor(.secondary)
            Text("No matching slots")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Try adjusting your search or filter")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Clear Filters") {
                viewModel.searchText = ""
                viewModel.slotFilter = .all
            }
            .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !viewModel.isConnected {
            EmptyStateView(
                icon: "bolt.horizontal.circle",
                title: "Not Connected",
                subtitle: "Waiting for changer connection...",
                buttonTitle: "Retry Connection",
                buttonIcon: "arrow.clockwise",
                action: { viewModel.connect() }
            )
        } else {
            EmptyStateView(
                icon: "circle.grid.3x3",
                title: "No Slots Found",
                subtitle: "Run a scan to detect all slots",
                buttonTitle: "Scan Inventory",
                buttonIcon: "magnifyingglass",
                action: { viewModel.scanInventory() }
            )
        }
    }
}

struct SlotRowView: View {
    let slot: Slot
    let isSelected: Bool
    var isSelectedForRip: Bool = false
    var onLoad: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        rowContent
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(rowBackground)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }

    private var rowContent: some View {
        HStack(spacing: 0) {
            slotNumberColumn
            statusBadge
                .frame(width: 100, alignment: .leading)
            volumeLabelColumn
            imagingStatusColumn
            Spacer()
            hoverActions
        }
    }

    private var slotNumberColumn: some View {
        HStack(spacing: 8) {
            statusIndicator
            Text("\(slot.id)")
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
        .frame(width: 60, alignment: .leading)
    }

    private var volumeLabelColumn: some View {
        Text(slot.volumeLabel ?? "")
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 180, alignment: .leading)
    }

    private var imagingStatusColumn: some View {
        HStack(spacing: 4) {
            switch slot.backupStatus {
            case .backedUp(let date):
                SFSymbol(name: "checkmark.circle.fill", size: 10)
                    .foregroundColor(.green)
                Text(Self.shortDateFormatter.string(from: date))
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
            case .failed:
                SFSymbol(name: "exclamationmark.triangle.fill", size: 10)
                    .foregroundColor(.red)
                Text("Failed")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.red)
            case .notBackedUp:
                if slot.isFull || slot.isInDrive {
                    SFSymbol(name: "circle.dashed", size: 10)
                        .foregroundColor(.secondary)
                    Text("Not imaged")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 120, alignment: .leading)
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    @ViewBuilder
    private var hoverActions: some View {
        if isHovered && slot.isFull && !slot.isInDrive, let onLoad = onLoad {
            Button("Load") { onLoad() }
                .buttonStyle(BorderlessButtonStyle())
                .font(.caption)
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 10, height: 10)
    }

    private var indicatorColor: Color {
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

    @ViewBuilder
    private var statusBadge: some View {
        if slot.isInDrive {
            CapsuleBadge(text: "In Drive", color: .accentColor)
        } else if slot.hasException {
            CapsuleBadge(text: "Exception", color: .red)
        } else if slot.isFull {
            CapsuleBadge(text: slot.discType.label, color: discTypeBadgeColor)
        } else {
            Text("Empty")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var discTypeBadgeColor: Color {
        switch slot.discType {
        case .audioCDDA: return .purple
        case .dvd: return .green
        case .dataCD: return Color(NSColor.systemTeal)
        case .mixedModeCD: return Color(NSColor.systemIndigo)
        case .unknown: return Color(NSColor.systemGray)
        case .unscanned: return .green
        }
    }

    private var rowBackground: Color {
        if isSelectedForRip {
            return Color.orange.opacity(0.15)
        } else if isSelected {
            return Color.accentColor.opacity(0.15)
        } else if isHovered {
            return Color.primary.opacity(0.03)
        } else {
            return Color.clear
        }
    }
}

#if DEBUG
struct InventoryListView_Previews: PreviewProvider {
    static var previews: some View {
        InventoryListView()
            .environmentObject(ChangerViewModel.preview)
    }
}
#endif
