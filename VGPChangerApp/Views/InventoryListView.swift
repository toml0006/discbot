//
//  InventoryListView.swift
//  VGPChangerApp
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
            ForEach(viewModel.slots, id: \.id) { slot in
                SlotRowView(
                    slot: slot,
                    isSelected: slot.id == viewModel.selectedSlotId
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.selectedSlotId = slot.id
                }
                .gesture(
                    TapGesture(count: 2)
                        .onEnded {
                            if slot.isFull && !slot.isInDrive {
                                viewModel.loadSlot(slot.id)
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

            Text("Status")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text("Address")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)

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

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            if !viewModel.isConnected {
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
            } else {
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

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct SlotRowView: View {
    let slot: Slot
    let isSelected: Bool
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
            addressColumn
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

    private var addressColumn: some View {
        Text(String(format: "0x%04X", slot.address))
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(width: 80, alignment: .leading)
    }

    @ViewBuilder
    private var hoverActions: some View {
        if isHovered && slot.isFull && !slot.isInDrive {
            Button("Load") {}
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
            // Blue circle indicates in-drive status, no badge needed
            EmptyView()
        } else if slot.hasException {
            CapsuleBadge(text: "Exception", color: .red)
        } else if slot.isFull {
            CapsuleBadge(text: "Full", color: .green)
        } else {
            Text("Empty")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var rowBackground: Color {
        if isSelected {
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
