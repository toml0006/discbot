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

    // Base cell dimensions (before zoom)
    private let baseCellWidth: CGFloat = 40
    private let baseCellHeight: CGFloat = 50
    private let baseSpacing: CGFloat = 2

    // Computed dimensions based on zoom
    private var cellWidth: CGFloat { baseCellWidth * CGFloat(zoomScale) }
    private var cellHeight: CGFloat { baseCellHeight * CGFloat(zoomScale) }
    private var spacing: CGFloat { baseSpacing * CGFloat(zoomScale) }

    // Dynamic column count based on available width
    private let columns = 20

    var body: some View {
        ScrollView {
            if viewModel.slots.isEmpty {
                emptyState
            } else {
                gridContent
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var gridContent: some View {
        VStack(spacing: spacing) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { col in
                        cellAt(row: row, col: col)
                    }
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func cellAt(row: Int, col: Int) -> some View {
        let index = row * columns + col
        if index < viewModel.slots.count {
            let slot = viewModel.slots[index]
            SlotCellView(
                slot: slot,
                isSelected: slot.id == viewModel.selectedSlotId,
                cellSize: CGSize(width: cellWidth, height: cellHeight)
            )
            .onTapGesture {
                viewModel.selectedSlotId = slot.id
            }
            .gesture(doubleTapGesture(for: slot))
            .contextMenu { slotContextMenu(for: slot) }
        } else {
            Color.clear
                .frame(width: cellWidth, height: cellHeight)
        }
    }

    private func doubleTapGesture(for slot: Slot) -> some Gesture {
        TapGesture(count: 2)
            .onEnded {
                if slot.isFull && !slot.isInDrive {
                    viewModel.loadSlot(slot.id)
                }
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

        // Eject to I/E slot (only if slot has disc and not in drive)
        if slot.isFull && !slot.isInDrive && viewModel.hasIESlot {
            Button(action: { viewModel.unloadSlot(slot.id) }) {
                Text("Eject to I/E Slot")
            }
            .disabled(viewModel.currentOperation != nil)
        }

        // Import from I/E slot (only if slot is empty)
        if !slot.isFull && !slot.isInDrive && viewModel.hasIESlot {
            Button(action: { viewModel.importToSlot(slot.id) }) {
                Text("Import from I/E Slot")
            }
            .disabled(viewModel.currentOperation != nil)
        }

        // Eject here (if disc is in drive, eject to this slot)
        if !slot.isFull && !slot.isInDrive {
            if case .loaded = viewModel.driveStatus {
                Button(action: { viewModel.ejectDisc(toSlot: slot.id) }) {
                    Text("Eject Drive Here")
                }
                .disabled(viewModel.currentOperation != nil)
            }
        }
    }

    private var rowCount: Int {
        (viewModel.slots.count + columns - 1) / columns
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            if !viewModel.isConnected {
                notConnectedView
            } else {
                noSlotsView
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var notConnectedView: some View {
        VStack(spacing: 20) {
            SFSymbol(name: "bolt.horizontal.circle", size: 56)
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text("Not Connected")
                    .font(.title)
                    .fontWeight(.medium)
                Text("Waiting for changer connection...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: { viewModel.connect() }) {
                HStack(spacing: 6) {
                    SFSymbol(name: "arrow.clockwise", size: 14)
                    Text("Retry Connection")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private var noSlotsView: some View {
        VStack(spacing: 20) {
            SFSymbol(name: "circle.grid.3x3", size: 56)
                .foregroundColor(.secondary)

            VStack(spacing: 6) {
                Text("No Slots Found")
                    .font(.title)
                    .fontWeight(.medium)
                Text("Run a scan to detect all slots")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: { viewModel.scanInventory() }) {
                HStack(spacing: 6) {
                    SFSymbol(name: "magnifyingglass", size: 14)
                    Text("Scan Inventory")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
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
