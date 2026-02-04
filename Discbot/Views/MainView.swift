//
//  MainView.swift
//  Discbot
//
//  Main application window
//

import SwiftUI

enum InventoryViewMode: String {
    case grid
    case list
}

struct MainView: View {
    @EnvironmentObject private var viewModel: ChangerViewModel

    @State private var showingBatchSheet = false
    @State private var showingError = false
    @State private var viewMode: InventoryViewMode = .grid

    // Zoom scale (0.5 to 2.0, default 1.0) - using UserDefaults for 10.15 compatibility
    @State private var zoomScale: Double = UserDefaults.standard.double(forKey: "gridZoomScale").nonZeroOrDefault(1.0)

    var body: some View {
        VStack(spacing: 0) {
            // Header with device and drive info
            DriveStatusView()
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))

            Divider()

            // Inventory view (grid or list)
            if viewMode == .grid {
                InventoryGridView(zoomScale: zoomScale)
            } else {
                InventoryListView()
            }

            Divider()

            // Footer with stats and actions
            footerView
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay(operationOverlay)
        .alert(isPresented: $showingError) {
            Alert(
                title: Text("Error"),
                message: Text(viewModel.connectionError?.localizedDescription ?? "Unknown error"),
                dismissButton: .default(Text("OK")) {
                    viewModel.connectionError = nil
                }
            )
        }
        .onReceive(viewModel.$connectionError) { error in
            showingError = error != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Auto-refresh when app gains focus
            if viewModel.isConnected && viewModel.currentOperation == nil {
                viewModel.refreshInventory()
            }
        }
        .sheet(isPresented: $showingBatchSheet) {
            if let batchState = viewModel.batchState {
                BatchOperationSheet(batchState: batchState) {
                    batchState.cancel()
                }
            }
        }
    }

    @ViewBuilder
    private var operationOverlay: some View {
        // Only show overlay for long-running operations, not refreshing
        if let op = viewModel.currentOperation, !isQuickOperation(op) {
            ZStack {
                Color.black.opacity(0.3)

                OperationProgressView(
                    operation: viewModel.currentOperation!,
                    statusText: viewModel.operationStatusText
                )
            }
        }
    }

    private func isQuickOperation(_ op: ChangerViewModel.Operation) -> Bool {
        switch op {
        case .refreshing:
            return true
        default:
            return false
        }
    }

    private var footerView: some View {
        HStack(spacing: 16) {
            // Stats with icons
            statsSection

            Spacer()

            // Show Continue/Cancel when waiting for disc removal
            if isWaitingForDiscRemoval {
                waitingSection
            } else {
                // Normal actions
                actionsSection
            }
        }
    }

    private var statsSection: some View {
        HStack(spacing: 16) {
            // View mode toggle
            viewModeToggle

            // Zoom slider (only in grid mode)
            if viewMode == .grid {
                zoomSlider
            }

            Divider()
                .frame(height: 16)

            // Stats
            HStack(spacing: 4) {
                SFSymbol(name: "circle.fill", size: 12)
                    .foregroundColor(.green)
                Text("\(viewModel.fullSlotCount) full")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                SFSymbol(name: "circle.dashed", size: 12)
                    .foregroundColor(.secondary)
                Text("\(viewModel.emptySlotCount) empty")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            Button(action: { viewMode = .grid }) {
                SFSymbol(name: "circle.grid.3x3", size: 14)
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(ToggleButtonStyle(isActive: viewMode == .grid))

            Button(action: { viewMode = .list }) {
                SFSymbol(name: "list.bullet", size: 14)
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(ToggleButtonStyle(isActive: viewMode == .list))
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var zoomSlider: some View {
        HStack(spacing: 6) {
            Text("−")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Slider(value: Binding(
                get: { zoomScale },
                set: { newValue in
                    zoomScale = newValue
                    UserDefaults.standard.set(newValue, forKey: "gridZoomScale")
                }
            ), in: 0.5...2.0, step: 0.1)
                .frame(width: 80)
            Text("+")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var waitingSection: some View {
        HStack(spacing: 12) {
            SFSymbol(name: "arrow.down.circle.fill", size: 16)
                .foregroundColor(.orange)
            Text(viewModel.operationStatusText)
                .font(.subheadline)
                .foregroundColor(.orange)

            Button("Continue") {
                viewModel.continueUnloadAll()
            }

            Button("Cancel") {
                viewModel.cancelUnloadAll()
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 8) {
            // Refresh group
            refreshButtons

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            // Selected slot actions
            slotButtons

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            // Batch actions
            batchButtons
        }
    }

    private var refreshButtons: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.refreshInventory() }) {
                HStack(spacing: 4) {
                    if viewModel.currentOperation == .refreshing {
                        SpinnerView(controlSize: .small)
                            .frame(width: 12, height: 12)
                    } else {
                        SFSymbol(name: "arrow.clockwise", size: 12)
                    }
                    Text("Refresh")
                }
            }
            .disabled(viewModel.currentOperation != nil)

            Button(action: { viewModel.scanInventory() }) {
                HStack(spacing: 4) {
                    SFSymbol(name: "magnifyingglass", size: 12)
                    Text("Scan All")
                }
            }
            .disabled(viewModel.currentOperation != nil)
        }
    }

    private var slotButtons: some View {
        HStack(spacing: 8) {
            Button(action: {
                if let slot = viewModel.selectedSlotId {
                    viewModel.loadSlot(slot)
                }
            }) {
                HStack(spacing: 4) {
                    SFSymbol(name: "arrow.right.circle", size: 12)
                    Text("Load")
                }
            }
            .disabled(!canLoadSelected)
            .helpTooltip("Load selected disc into drive")

            Button(action: {
                if let slot = viewModel.selectedSlotId {
                    viewModel.unloadSlot(slot)
                }
            }) {
                HStack(spacing: 4) {
                    SFSymbol(name: "tray.and.arrow.up", size: 12)
                    Text("Eject")
                }
            }
            .disabled(!canUnloadSelected)
            .helpTooltip("Eject selected disc to I/E slot")
        }
    }

    private var batchButtons: some View {
        HStack(spacing: 8) {
            Button(action: {
                showingBatchSheet = true
                viewModel.startBatchLoad()
            }) {
                HStack(spacing: 4) {
                    SFSymbol(name: "square.stack.3d.up", size: 12)
                    Text("Load All")
                }
            }
            .disabled(viewModel.currentOperation != nil || viewModel.fullSlotCount == 0)

            Button(action: { viewModel.startUnloadAll() }) {
                HStack(spacing: 4) {
                    SFSymbol(name: "tray.and.arrow.up", size: 12)
                    Text("Eject All")
                }
            }
            .disabled(viewModel.currentOperation != nil || viewModel.fullSlotCount == 0 || !viewModel.hasIESlot)
        }
    }

    // MARK: - Button State Helpers

    private var selectedSlot: Slot? {
        guard let id = viewModel.selectedSlotId, id > 0, id <= viewModel.slots.count else {
            return nil
        }
        return viewModel.slots[id - 1]
    }

    private var canLoadSelected: Bool {
        guard viewModel.currentOperation == nil else { return false }
        guard viewModel.driveStatus == .empty else { return false }
        guard let slot = selectedSlot else { return false }
        return slot.isFull && !slot.isInDrive
    }

    private var canUnloadSelected: Bool {
        guard viewModel.currentOperation == nil else { return false }
        guard viewModel.hasIESlot else { return false }
        guard let slot = selectedSlot else { return false }
        return slot.isFull && !slot.isInDrive
    }

    private var isWaitingForDiscRemoval: Bool {
        if case .waitingForDiscRemoval = viewModel.currentOperation {
            return true
        }
        return false
    }
}

// Preview provider
extension ChangerViewModel {
    static var preview: ChangerViewModel {
        let vm = ChangerViewModel()
        vm.isConnected = true
        vm.deviceVendor = "Sony"
        vm.deviceProduct = "VGP-XL1B"
        vm.driveStatus = .loaded(sourceSlot: 42, mountPoint: "/Volumes/DISC")
        vm.slots = (1...200).map { Slot(id: $0, address: UInt16($0 + 3), isFull: $0 % 3 == 0) }
        vm.slots[41].isInDrive = true
        return vm
    }
}

#if DEBUG
struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
            .environmentObject(ChangerViewModel.preview)
    }
}
#endif
