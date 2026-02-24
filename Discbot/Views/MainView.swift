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
    case carousel
}

struct MainView: View {
    @EnvironmentObject private var viewModel: ChangerViewModel
    @EnvironmentObject private var settings: AppSettings

    @State private var showingBatchSheet = false
    @State private var showingError = false
    @State private var viewMode: InventoryViewMode = .grid

    // Zoom scale (0.5 to 2.0, default 1.0)
    @State private var zoomScale: Double = UserDefaults.standard.double(forKey: "gridZoomScale").nonZeroOrDefault(1.0)

    /// Whether any slots have been loaded (controls search/filter enabled state)
    private var hasSlots: Bool {
        !viewModel.slots.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: changer info + actions | drive info + actions
            DriveStatusView()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))

            Divider()

            // Search/filter bar
            searchFilterBar
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))

            // Waiting banner (disc removal)
            if isWaitingForDiscRemoval {
                waitingBanner
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
            }

            Divider()

            // Inventory view
            if viewMode == .grid {
                InventoryGridView(zoomScale: zoomScale)
            } else if viewMode == .list {
                InventoryListView()
            } else {
                InventoryCarouselView()
            }

            Divider()

            // Footer: view controls + stats
            footerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
        }
        .frame(minWidth: 700, minHeight: 500)
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
        .sheet(isPresented: $showingBatchSheet) {
            if let batchState = viewModel.batchState {
                BatchOperationSheet(batchState: batchState)
            }
        }
        .onReceive(viewModel.$batchState) { state in
            if state?.isRunning == true && !showingBatchSheet {
                showingBatchSheet = true
            }
        }
        // Menu bar notifications
        .onReceive(NotificationCenter.default.publisher(for: .menuSetViewMode)) { notification in
            if let mode = notification.object as? String {
                switch mode {
                case "grid": viewMode = .grid
                case "list": viewMode = .list
                case "carousel": viewMode = .carousel
                default: break
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuZoomIn)) { _ in
            zoomScale = min(2.0, zoomScale + 0.1)
            UserDefaults.standard.set(zoomScale, forKey: "gridZoomScale")
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuZoomOut)) { _ in
            zoomScale = max(0.5, zoomScale - 0.1)
            UserDefaults.standard.set(zoomScale, forKey: "gridZoomScale")
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuImageSelected)) { _ in
            pickFolderAndStartImaging()
        }
    }

    @ViewBuilder
    private var operationOverlay: some View {
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

    // MARK: - Search / Filter Bar

    private var searchFilterBar: some View {
        HStack(spacing: 12) {
            // Search field (left-aligned)
            SearchFieldView(text: $viewModel.searchText, placeholder: "Search slots...")
                .frame(width: 180, height: 22)
                .disabled(!hasSlots)
                .opacity(hasSlots ? 1.0 : 0.5)

            // Filter popup
            PopUpButtonView(
                items: ChangerViewModel.SlotFilter.allCases.map { ($0.rawValue, $0) },
                selection: $viewModel.slotFilter
            )
            .frame(width: 100, height: 22)
            .disabled(!hasSlots)
            .opacity(hasSlots ? 1.0 : 0.5)

            if viewModel.isFiltering {
                Text("\(viewModel.filteredSlots.count) shown")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.orange)
            }

            Spacer()

            // Selection info + Image button
            if !viewModel.selectedSlotsForRip.isEmpty {
                selectionControls
            }
        }
    }

    // MARK: - Selection Controls

    private var selectionControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                SFSymbol(name: "opticaldisc", size: 11)
                    .foregroundColor(.orange)
                Text("\(viewModel.selectedSlotsForRip.count) selected")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.orange)
            }

            if viewModel.previouslyImagedSelectedCount > 0 {
                HStack(spacing: 4) {
                    SFSymbol(name: "exclamationmark.circle.fill", size: 11)
                        .foregroundColor(.yellow)
                    Text("\(viewModel.previouslyImagedSelectedCount) already imaged")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.yellow)
                }
            }

            Button("Clear") {
                viewModel.clearSlotSelectionForRip()
            }
            .font(.caption)
            .buttonStyle(BorderlessButtonStyle())

            if viewModel.selectedSlotsForRip.count < viewModel.rippableSlots.count {
                Button("Select All") {
                    viewModel.selectAllSlotsForRip()
                }
                .font(.caption)
                .buttonStyle(BorderlessButtonStyle())
            }

            Divider()
                .frame(height: 16)

            Button(action: { pickFolderAndStartImaging() }) {
                HStack(spacing: 3) {
                    SFSymbol(name: "opticaldisc", size: 12)
                    Text(imageButtonLabel)
                        .font(.caption)
                }
            }
            .disabled(viewModel.currentOperation != nil || viewModel.selectedSlotsForRip.isEmpty)
            .helpTooltip(imageTooltip)
        }
    }

    // MARK: - Waiting Banner

    private var waitingBanner: some View {
        HStack(spacing: 12) {
            SFSymbol(name: "arrow.down.circle.fill", size: 14)
                .foregroundColor(.orange)
            Text(viewModel.operationStatusText)
                .font(.caption)
                .foregroundColor(.orange)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Continue") {
                viewModel.continueUnloadAll()
            }
            .font(.caption)

            Button("Cancel") {
                viewModel.cancelUnloadAll()
            }
            .font(.caption)
        }
    }

    // MARK: - Footer (view controls + stats)

    private var footerBar: some View {
        HStack(spacing: 12) {
            // View mode toggle
            viewModeToggle

            // Zoom (grid only)
            if viewMode == .grid {
                zoomSlider
            }

            Divider()
                .frame(height: 16)

            // Stats
            statsView

            Spacer()
        }
    }

    // MARK: - Stats

    private var statsView: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                SFSymbol(name: "circle.fill", size: 9)
                    .foregroundColor(.green)
                Text("\(viewModel.fullSlotCount) full")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 3) {
                SFSymbol(name: "circle.dashed", size: 9)
                    .foregroundColor(.secondary)
                Text("\(viewModel.emptySlotCount) empty")
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - View Controls

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            Button(action: { viewMode = .grid }) {
                SFSymbol(name: "circle.grid.3x3", size: 13)
                    .frame(width: 26, height: 20)
            }
            .buttonStyle(ToggleButtonStyle(isActive: viewMode == .grid))

            Button(action: { viewMode = .list }) {
                SFSymbol(name: "list.bullet", size: 13)
                    .frame(width: 26, height: 20)
            }
            .buttonStyle(ToggleButtonStyle(isActive: viewMode == .list))

            Button(action: { viewMode = .carousel }) {
                SFSymbol(name: "rotate.3d", size: 13)
                    .frame(width: 26, height: 20)
            }
            .buttonStyle(ToggleButtonStyle(isActive: viewMode == .carousel))
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var zoomSlider: some View {
        HStack(spacing: 4) {
            Text("−")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Slider(value: Binding(
                get: { zoomScale },
                set: { newValue in
                    zoomScale = newValue
                    UserDefaults.standard.set(newValue, forKey: "gridZoomScale")
                }
            ), in: 0.5...2.0, step: 0.1)
                .frame(width: 70)
            Text("+")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helpers

    private var isWaitingForDiscRemoval: Bool {
        if case .waitingForDiscRemoval = viewModel.currentOperation {
            return true
        }
        return false
    }

    private var imageButtonLabel: String {
        let count = viewModel.selectedSlotsForRip.count
        if count == 0 {
            return "Image"
        }
        return "Image (\(count))"
    }

    private var imageTooltip: String {
        guard viewModel.currentOperation == nil else { return "Wait for current operation to finish" }
        if viewModel.selectedSlotsForRip.isEmpty {
            return "Click discs to select them for imaging"
        }
        return "Image \(viewModel.selectedSlotsForRip.count) disc(s) to ISO (⌘⌥I)"
    }

    private func pickFolderAndStartImaging() {
        if !confirmReimagingIfNeeded() {
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        showingBatchSheet = true
        viewModel.startBatchImaging(outputDirectory: url)
    }

    private func confirmReimagingIfNeeded() -> Bool {
        let previouslyImaged = viewModel.previouslyImagedSelectedSlots
        guard !previouslyImaged.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = "\(previouslyImaged.count) selected disc(s) were already imaged"

        let slotSummary = previouslyImaged
            .prefix(8)
            .map { slot in
                if let label = slot.volumeLabel, !label.isEmpty {
                    return "Slot \(slot.id): \(label)"
                }
                return "Slot \(slot.id)"
            }
            .joined(separator: "\n")
        let remaining = previouslyImaged.count - min(previouslyImaged.count, 8)
        let suffix = remaining > 0 ? "\n…and \(remaining) more" : ""
        alert.informativeText = "This queue includes discs with successful rip history.\n\n\(slotSummary)\(suffix)\n\nContinue anyway?"

        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
            .environmentObject(AppSettings())
    }
}
#endif
