//
//  InventoryGridView.swift
//  Discbot
//
//  Grid showing all 200 slots
//

import SwiftUI

struct InventoryGridView: View {
    @EnvironmentObject private var viewModel: ChangerViewModel

    // Zoom scale from parent (0.5 to 2.0)
    var zoomScale: Double = 1.0

    // Base dimensions (before zoom)
    private let baseMinCellWidth: CGFloat = 40
    private let baseSpacing: CGFloat = 6

    // Spacing scales with zoom
    private var spacing: CGFloat { baseSpacing * CGFloat(zoomScale) }

    // Padding around the grid
    private let gridPadding: CGFloat = 12

    // Group size for section headers
    private let slotsPerGroup = 50

    // Minimum cell width based on zoom (used to compute column count)
    private var minCellWidth: CGFloat { baseMinCellWidth * CGFloat(zoomScale) }

    // Cell height from width — content needs roughly: accent bar (3-6) + icon (35%) + number + metadata + spacing
    // We cap height so tiles are always wider than tall
    private func cellHeight(for width: CGFloat) -> CGFloat {
        let contentHeight = width * 1.3 + (width >= 55 ? 12 : 0)
        // Never taller than wide
        return min(contentHeight, width)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView {
                    if viewModel.slots.isEmpty {
                        emptyState
                    } else if viewModel.filteredSlots.isEmpty {
                        filteredEmptyState
                    } else {
                        gridContent(availableWidth: geometry.size.width)
                    }
                }

                // Keyboard handler overlay
                if !viewModel.slots.isEmpty {
                    KeyEventHandler { keyCode, modifiers in
                        handleKeyEvent(keyCode: keyCode, modifiers: modifiers, availableWidth: geometry.size.width)
                    }
                    .frame(width: 0, height: 0)
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private func columnCount(for availableWidth: CGFloat) -> Int {
        let usableWidth = availableWidth - (gridPadding * 2)
        let cellPlusSpacing = minCellWidth + spacing
        let count = Int((usableWidth + spacing) / cellPlusSpacing)
        return max(1, count)
    }

    /// Actual cell width when filling available space
    private func flexCellWidth(for availableWidth: CGFloat, columns: Int) -> CGFloat {
        let usableWidth = availableWidth - (gridPadding * 2)
        let totalSpacing = spacing * CGFloat(columns - 1)
        return max(minCellWidth, (usableWidth - totalSpacing) / CGFloat(columns))
    }

    // MARK: - Grid Content with Section Headers

    private func gridContent(availableWidth: CGFloat) -> some View {
        let columns = columnCount(for: availableWidth)
        let cw = flexCellWidth(for: availableWidth, columns: columns)
        let ch = cellHeight(for: cw)
        let groups = groupedSlots()

        return VStack(alignment: .leading, spacing: spacing * 2) {
            ForEach(groups, id: \.startIndex) { group in
                sectionView(group: group, columns: columns, cellW: cw, cellH: ch)
            }
        }
        .padding(gridPadding)
    }

    private func sectionView(group: SlotGroup, columns: Int, cellW: CGFloat, cellH: CGFloat) -> some View {
        let rowCount = (group.slots.count + columns - 1) / columns

        return VStack(alignment: .leading, spacing: spacing) {
            // Section header
            Text("\(group.startIndex + 1)–\(group.startIndex + group.slots.count)")
                .font(.system(.caption, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(Color.secondary.opacity(0.6))
                .padding(.leading, 4)

            // Rows in this section
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { col in
                        let index = row * columns + col
                        if index < group.slots.count {
                            let slot = group.slots[index]
                            SlotCellView(
                                slot: slot,
                                isSelected: slot.id == viewModel.selectedSlotId,
                                isSelectedForRip: viewModel.selectedSlotsForRip.contains(slot.id),
                                cellSize: CGSize(width: cellW, height: cellH)
                            )
                            .onTapGesture {
                                handleSlotTap(slot)
                            }
                            .gesture(doubleTapGesture(for: slot))
                            .contextMenu { slotContextMenu(for: slot) }
                        } else {
                            Color.clear
                                .frame(width: cellW, height: cellH)
                        }
                    }
                }
            }
        }
    }

    private struct SlotGroup {
        let startIndex: Int
        let slots: [Slot]
    }

    private func groupedSlots() -> [SlotGroup] {
        var groups: [SlotGroup] = []
        let allSlots = viewModel.filteredSlots
        var index = 0
        while index < allSlots.count {
            let end = min(index + slotsPerGroup, allSlots.count)
            let chunk = Array(allSlots[index..<end])
            groups.append(SlotGroup(startIndex: index, slots: chunk))
            index = end
        }
        return groups
    }

    // MARK: - Keyboard Navigation

    private func handleKeyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, availableWidth: CGFloat) -> Bool {
        let columns = columnCount(for: availableWidth)
        let filtered = viewModel.filteredSlots
        let slotCount = filtered.count
        guard slotCount > 0 else { return false }

        let currentIndex: Int
        if let selectedId = viewModel.selectedSlotId,
           let idx = filtered.firstIndex(where: { $0.id == selectedId }) {
            currentIndex = idx
        } else {
            // No selection - select first filtered slot on any arrow key
            if [123, 124, 125, 126].contains(keyCode) {
                viewModel.selectedSlotId = filtered[0].id
                return true
            }
            return false
        }

        switch keyCode {
        case 123: // Left arrow
            let newIndex = max(0, currentIndex - 1)
            viewModel.selectedSlotId = filtered[newIndex].id
            return true
        case 124: // Right arrow
            let newIndex = min(slotCount - 1, currentIndex + 1)
            viewModel.selectedSlotId = filtered[newIndex].id
            return true
        case 126: // Up arrow
            let newIndex = currentIndex - columns
            if newIndex >= 0 {
                viewModel.selectedSlotId = filtered[newIndex].id
            }
            return true
        case 125: // Down arrow
            let newIndex = currentIndex + columns
            if newIndex < slotCount {
                viewModel.selectedSlotId = filtered[newIndex].id
            }
            return true
        case 36: // Return/Enter - load selected slot
            if let slot = filtered.first(where: { $0.id == viewModel.selectedSlotId }),
               slot.isFull && !slot.isInDrive {
                viewModel.loadSlotWithEjectIfNeeded(slot.id)
            }
            return true
        case 53: // Escape - deselect
            viewModel.selectedSlotId = nil
            return true
        default:
            return false
        }
    }

    // MARK: - Slot Tap Handling

    private func handleSlotTap(_ slot: Slot) {
        viewModel.selectedSlotId = slot.id

        guard slot.isFull || slot.isInDrive else { return }

        // Read modifier keys from the current NSEvent
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []

        if modifiers.contains(.shift) {
            // Shift+Click: range selection from anchor
            viewModel.extendSlotSelectionForRip(to: slot.id)
        } else if modifiers.contains(.command) {
            // Cmd+Click: toggle individual item
            viewModel.toggleSlotForRip(slot.id)
        } else {
            // Plain click: select only this item
            viewModel.selectSlotForRip(slot.id)
        }
    }

    // MARK: - Gestures & Context Menu

    private func doubleTapGesture(for slot: Slot) -> some Gesture {
        TapGesture(count: 2)
            .onEnded {
                if slot.isFull && !slot.isInDrive {
                    viewModel.loadSlotWithEjectIfNeeded(slot.id)
                }
            }
    }

    @ViewBuilder
    private func slotContextMenu(for slot: Slot) -> some View {
        // Metadata section
        if slot.isFull || slot.isInDrive {
            Text(slot.volumeLabel ?? "Disc from Slot \(slot.id)")
            Text("\(slot.discType.label)  ·  \(slot.discType.typicalSizeLabel)")
            Text(backupStatusLabel(slot.backupStatus))
        } else {
            Text("Slot \(slot.id) — Empty")
        }

        Divider()

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

    private func backupStatusLabel(_ status: BackupStatus) -> String {
        switch status {
        case .backedUp(let date):
            let f = DateFormatter()
            f.dateStyle = .short
            return "Imaged \(f.string(from: date))"
        case .failed:
            return "Imaging failed"
        case .notBackedUp:
            return "Not imaged"
        }
    }

    // MARK: - Filtered Empty State

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

    // MARK: - Empty State

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

#if DEBUG
struct InventoryGridView_Previews: PreviewProvider {
    static var previews: some View {
        InventoryGridView(zoomScale: 1.0)
            .environmentObject(ChangerViewModel.preview)
    }
}
#endif
