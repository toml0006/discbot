//
//  DriveStatusView.swift
//  Discbot
//
//  Shows device info, drive status, and their respective action buttons
//

import SwiftUI

struct DriveStatusView: View {
    @EnvironmentObject private var viewModel: ChangerViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 0) {
            // Changer section (info + actions)
            changerSection

            Divider()
                .frame(height: 50)
                .padding(.horizontal, 16)

            // Drive section (info + actions)
            driveSection

            Spacer(minLength: 0)
        }
    }

    // MARK: - Changer Section

    private var changerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Info row
            HStack(spacing: 10) {
                SFSymbol(name: "server.rack", size: 18)
                    .foregroundColor(viewModel.isConnected ? .accentColor : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(viewModel.deviceDescription)
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)

                        if settings.mockChangerEnabled {
                            CapsuleBadge(text: "mock", color: .orange)
                        }
                    }
                    Text("\(viewModel.fullSlotCount)/\(viewModel.slots.count) populated")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .opacity(viewModel.isConnected ? 1.0 : 0.6)

            // Changer actions
            changerActions
        }
        .frame(minWidth: 260, alignment: .leading)
    }

    private var changerActions: some View {
        SegmentedActions {
            Button(action: { viewModel.refreshInventory() }) {
                HStack(spacing: 3) {
                    if viewModel.currentOperation == .refreshing {
                        SpinnerView(controlSize: .small)
                            .frame(width: 10, height: 10)
                    } else {
                        SFSymbol(name: "arrow.clockwise", size: 10)
                    }
                    Text("Refresh")
                }
            }
            .buttonStyle(SegmentedActionStyle(isEnabled: viewModel.currentOperation == nil))
            .disabled(viewModel.currentOperation != nil)
            .helpTooltip("Refresh slot status (⌘R)")

            Button(action: { viewModel.scanInventory() }) {
                HStack(spacing: 3) {
                    SFSymbol(name: "magnifyingglass", size: 10)
                    Text("Scan")
                }
            }
            .buttonStyle(SegmentedActionStyle(isEnabled: viewModel.currentOperation == nil))
            .disabled(viewModel.currentOperation != nil)
            .helpTooltip("Full SCSI scan of all slots (⌘⇧R)")

            changerMoreMenu
        }
    }

    private var changerMoreMenu: some View {
        MenuButton(label:
            HStack(spacing: 3) {
                Text("More")
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))
        ) {
            Button("Load All Discs") {
                viewModel.startBatchLoad()
            }
            .disabled(viewModel.currentOperation != nil || viewModel.fullSlotCount == 0)

            Button("Eject All") {
                viewModel.startUnloadAll()
            }
            .disabled(viewModel.currentOperation != nil || viewModel.fullSlotCount == 0 || !viewModel.hasIESlot)

            if viewModel.hasIESlot {
                VStack { Divider() }

                Button("Load from I/E") {
                    viewModel.importFromIESlot()
                }
                .disabled(viewModel.currentOperation != nil)
            }
        }
        .menuButtonStyle(BorderlessButtonMenuButtonStyle())
    }

    // MARK: - Drive Section

    private var driveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Info row
            HStack(spacing: 10) {
                driveIcon
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Drive")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    driveStatusText
                }
            }

            // Drive actions
            driveActions
        }
        .frame(minWidth: 240, alignment: .leading)
    }

    @ViewBuilder
    private var driveIcon: some View {
        switch viewModel.driveStatus {
        case .empty:
            SFSymbol(name: "circle.dashed", size: 18)
                .foregroundColor(.secondary)
        case .loading, .ejecting:
            SpinnerView(controlSize: .small)
                .frame(width: 18, height: 18)
        case .loaded:
            SFSymbol(name: "circle.fill", size: 18)
                .foregroundColor(.accentColor)
        case .error:
            SFSymbol(name: "exclamationmark.triangle.fill", size: 16)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var driveStatusText: some View {
        switch viewModel.driveStatus {
        case .empty:
            Text("Empty")
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(.secondary)

        case .loading(let slot):
            Text("Loading slot \(slot)...")
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)

        case .loaded(let sourceSlot, let mountPoint):
            discNameText(sourceSlot: sourceSlot, mountPoint: mountPoint)

        case .ejecting(let slot):
            Text("Ejecting to slot \(slot)...")
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)

        case .error(let message):
            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(.red)
                .lineLimit(1)
        }
    }

    private func discNameText(sourceSlot: Int, mountPoint: String?) -> some View {
        HStack(spacing: 6) {
            if let mount = mountPoint {
                Text(volumeName(from: mount))
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.medium)
            } else {
                Text("Disc from Slot \(sourceSlot)")
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.medium)
            }

            CapsuleBadge(
                text: mountPoint != nil ? "mounted" : "unmounted",
                color: mountPoint != nil ? .green : .orange
            )
        }
    }

    private func volumeName(from mountPoint: String) -> String {
        let components = mountPoint.split(separator: "/")
        if let last = components.last {
            return String(last)
        }
        return mountPoint
    }

    private var driveActions: some View {
        SegmentedActions {
            Button(action: {
                if let slot = viewModel.selectedSlotId {
                    viewModel.loadSlotWithEjectIfNeeded(slot)
                }
            }) {
                HStack(spacing: 3) {
                    SFSymbol(name: "arrow.right.circle", size: 10)
                    Text(loadLabel)
                }
            }
            .buttonStyle(SegmentedActionStyle(isEnabled: canLoadSelected))
            .disabled(!canLoadSelected)
            .helpTooltip(loadTooltip)

            if case .loaded(_, let mountPoint) = viewModel.driveStatus {
                if mountPoint != nil {
                    Button(action: { viewModel.unmountDisc() }) {
                        HStack(spacing: 3) {
                            SFSymbol(name: "eject", size: 10)
                            Text("Unmount")
                        }
                    }
                    .buttonStyle(SegmentedActionStyle(isEnabled: viewModel.currentOperation == nil))
                    .disabled(viewModel.currentOperation != nil)
                    .helpTooltip("Unmount disc filesystem (⌘U)")
                } else {
                    Button(action: { viewModel.mountDisc() }) {
                        HStack(spacing: 3) {
                            SFSymbol(name: "play.fill", size: 10)
                            Text("Mount")
                        }
                    }
                    .buttonStyle(SegmentedActionStyle(isEnabled: viewModel.currentOperation == nil))
                    .disabled(viewModel.currentOperation != nil)
                    .helpTooltip("Mount disc filesystem (⌘U)")
                }

                Button(action: { viewModel.ejectDisc() }) {
                    HStack(spacing: 3) {
                        SFSymbol(name: "arrow.uturn.backward", size: 10)
                        Text("Eject")
                    }
                }
                .buttonStyle(SegmentedActionStyle(isEnabled: viewModel.currentOperation == nil))
                .disabled(viewModel.currentOperation != nil)
                .helpTooltip("Eject disc to slot (⌘E)")
            }

            if viewModel.hasIESlot {
                Button(action: {
                    if let slot = viewModel.selectedSlotId {
                        viewModel.unloadSlot(slot)
                    }
                }) {
                    HStack(spacing: 3) {
                        SFSymbol(name: "tray.and.arrow.up", size: 10)
                        Text("Eject")
                    }
                }
                .buttonStyle(SegmentedActionStyle(isEnabled: canUnloadSelected))
                .disabled(!canUnloadSelected)
                .helpTooltip("Eject selected disc to I/E slot (⌘⇧E)")
            }
        }
    }

    // MARK: - Helpers

    private var loadLabel: String {
        if let id = viewModel.selectedSlotId {
            return "Load \(id)"
        }
        return "Load"
    }

    private var selectedSlot: Slot? {
        guard let id = viewModel.selectedSlotId, id > 0, id <= viewModel.slots.count else {
            return nil
        }
        return viewModel.slots[id - 1]
    }

    private var canLoadSelected: Bool {
        guard viewModel.currentOperation == nil else { return false }
        guard let slot = selectedSlot else { return false }
        return slot.isFull && !slot.isInDrive
    }

    private var canUnloadSelected: Bool {
        guard viewModel.currentOperation == nil else { return false }
        guard viewModel.hasIESlot else { return false }
        guard let slot = selectedSlot else { return false }
        return slot.isFull && !slot.isInDrive
    }

    private var loadTooltip: String {
        guard viewModel.currentOperation == nil else { return "Wait for current operation to finish" }
        guard let slot = selectedSlot else { return "Select a slot first (⌘L)" }
        if !slot.isFull { return "Selected slot is empty" }
        if slot.isInDrive { return "Disc is already in drive" }
        return "Load slot \(slot.id) into drive (⌘L)"
    }
}

#if DEBUG
struct DriveStatusView_Previews: PreviewProvider {
    static var previews: some View {
        DriveStatusView()
            .environmentObject(ChangerViewModel.preview)
            .environmentObject(AppSettings())
            .padding()
    }
}
#endif
