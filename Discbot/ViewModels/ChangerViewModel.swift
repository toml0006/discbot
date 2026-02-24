//
//  ChangerViewModel.swift
//  Discbot
//
//  Main view model for the application
//

import Foundation
import SwiftUI
import Combine
import DiskArbitration
import os.log

final class ChangerViewModel: ObservableObject {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Discbot",
        category: "ChangerViewModel"
    )

    private static func logType(for error: ChangerError) -> OSLogType {
        switch error {
        case .driveNotEmpty, .driveEmpty, .slotEmpty, .slotOccupied, .cancelled:
            return .info
        default:
            return .error
        }
    }

    // Connection state
    @Published var isConnected = false
    @Published var connectionError: ChangerError? {
        didSet {
            guard let connectionError = connectionError else { return }
            os_log(
                "connectionError while operation=%{public}@: %{public}@",
                log: Self.log,
                type: Self.logType(for: connectionError),
                String(describing: currentOperation),
                connectionError.localizedDescription
            )
        }
    }

    // Device info
    @Published var deviceVendor: String?
    @Published var deviceProduct: String?

    // Drive state
    @Published var driveStatus: DriveStatus = .empty {
        didSet {
            switch driveStatus {
            case .loaded(let slot, _) where slot > 0,
                 .loading(let slot) where slot > 0:
                Self.setDirtyFlag(sourceSlot: slot)
            case .empty:
                Self.clearDirtyFlag()
            case .error(let message):
                os_log(
                    "driveStatus error while operation=%{public}@: %{public}@",
                    log: Self.log,
                    type: .error,
                    String(describing: currentOperation),
                    message
                )
            default:
                break
            }
        }
    }
    @Published var currentBSDName: String?

    // Inventory
    @Published var slots: [Slot] = []
    @Published var selectedSlotId: Int?
    @Published var selectedSlotsForRip: Set<Int> = []

    // Search and filter
    @Published var searchText: String = ""
    @Published var slotFilter: SlotFilter = .all

    enum SlotFilter: String, CaseIterable {
        case all = "All"
        case full = "Full"
        case empty = "Empty"
        case audioCDs = "Audio CDs"
        case dataCDs = "Data CDs"
        case dvds = "DVDs"
        case unscanned = "Unscanned"
        case inDrive = "In Drive"
    }

    var filteredSlots: [Slot] {
        var result = slots

        switch slotFilter {
        case .all: break
        case .full: result = result.filter { $0.isFull || $0.isInDrive }
        case .empty: result = result.filter { !$0.isFull && !$0.isInDrive }
        case .audioCDs: result = result.filter { $0.discType == .audioCDDA }
        case .dataCDs: result = result.filter { $0.discType == .dataCD }
        case .dvds: result = result.filter { $0.discType == .dvd }
        case .unscanned: result = result.filter { $0.discType == .unscanned && $0.isFull }
        case .inDrive: result = result.filter { $0.isInDrive }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                String($0.id).contains(query) ||
                ($0.volumeLabel?.lowercased().contains(query) ?? false) ||
                $0.discType.label.lowercased().contains(query)
            }
        }

        return result
    }

    var isFiltering: Bool {
        slotFilter != .all || !searchText.isEmpty
    }

    // Operation state
    @Published var currentOperation: Operation?
    @Published var operationStatusText: String = ""

    // Batch operation
    @Published var batchState: BatchOperationState?
    @Published var pendingRipDirectory: URL?  // Set by RipConfigSheet, consumed by MainView
    private var pendingLoadSlotIdAfterEject: Int?
    @Published var carouselAnimationEvent: CarouselAnimationEvent?

    // Unload all state
    @Published var unloadAllInProgress = false
    @Published var unloadAllQueue: [Int] = []  // Slots remaining to unload
    @Published var unloadAllCompleted: Int = 0
    @Published var unloadAllTotal: Int = 0

    // Settings
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []

    // Services
    private var changerService: ChangerServicing
    private var mountService: MountServicing
    private var mockState: MockChangerState?
    private var imagingService: ImagingServicing = ImagingService()
    let catalogService = CatalogService()
    private lazy var driveMediaObserver: DriveMediaObserver = DriveMediaObserver { [weak self] in
        self?.scheduleReconcileDriveStatusFromOS()
    }

    // Coalesce multiple DiskArbitration events into one reconcile pass.
    private var pendingDriveReconcile: DispatchWorkItem?
    private let catalogCacheQueue = DispatchQueue(label: "discbot.catalogCache", qos: .userInitiated)
    private var cachedDiscsBySlot: [Int: DiscRecord] = [:]
    private var cachedBackupStatusesBySlot: [Int: BackupStatus] = [:]

    enum Operation: Equatable {
        case connecting
        case loadingSlot(Int)
        case ejecting
        case mounting
        case unmounting
        case scanning
        case refreshing
        case unloading(Int)
        case scanningSlot(Int)
        case waitingForDiscRemoval(Int)  // Waiting for user to remove disc from I/E
    }

    struct CarouselAnimationEvent: Equatable {
        enum Kind: Equatable {
            case loadFromSlot(Int)
            case ejectToSlot(Int)
            case ejectFromChamber(Int)
        }

        let id = UUID()
        let kind: Kind
    }

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings

        if settings.mockChangerEnabled {
            let state = MockChangerState()
            self.mockState = state
            self.changerService = MockChangerService(state: state)
            self.mountService = MockMountService(state: state)
            self.imagingService = MockImagingService()
        } else {
            self.mockState = nil
            self.changerService = ChangerService()
            self.mountService = MountService()
            self.imagingService = ImagingService()
        }

        // React to settings changes.
        settings.$mockChangerEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.handleMockChangerSettingChanged(enabled)
            }
            .store(in: &cancellables)

        // Avoid touching hardware / DiskArbitration while rendering SwiftUI previews.
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if !isPreview {
            // Start observing drive media changes early; we gate updates while operations run.
            driveMediaObserver.start()

            // Auto-connect on start
            connect()
        }
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }
        guard currentOperation == nil else { return }

        currentOperation = .connecting
        operationStatusText = "Connecting to changer..."
        connectionError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.connect()

                DispatchQueue.main.async {
                    self.isConnected = true
                    self.operationStatusText = "Connected, loading inventory..."
                }

                // Get device info
                let info = try self.changerService.getDeviceInfo()
                DispatchQueue.main.async {
                    self.deviceVendor = info.vendor
                    self.deviceProduct = info.product
                    NotificationCenter.default.post(name: NSNotification.Name("DeviceInfoChanged"), object: nil)
                }

                // Load initial inventory and hydrate catalog cache once.
                self.doRefreshInventory(includeCatalogHydration: true)

                DispatchQueue.main.async {
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil
                    self.isConnected = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.currentOperation = nil
                    self.isConnected = false
                }
            }
        }
    }

    func disconnect() {
        changerService.disconnect()
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.slots = []
            self?.driveStatus = .empty
            self?.currentBSDName = nil
            self?.catalogCacheQueue.sync {
                self?.cachedDiscsBySlot = [:]
                self?.cachedBackupStatusesBySlot = [:]
            }
        }
    }

    private func handleMockChangerSettingChanged(_ enabled: Bool) {
        let currentlyMocking = (mockState != nil)
        guard enabled != currentlyMocking else { return }

        // Don't allow mode flips mid-operation; settings UI should also disable the toggle.
        guard currentOperation == nil, batchState?.isRunning != true else {
            connectionError = .unknown("Stop the current operation before changing settings.")
            settings.mockChangerEnabled = currentlyMocking
            return
        }

        // Tear down any existing connection state immediately.
        changerService.disconnect()
        isConnected = false
        connectionError = nil
        deviceVendor = nil
        deviceProduct = nil
        driveStatus = .empty
        currentBSDName = nil
        slots = []
        selectedSlotId = nil
        selectedSlotsForRip.removeAll()
        pendingRipDirectory = nil
        batchState = nil
        unloadAllInProgress = false
        unloadAllQueue = []
        unloadAllCompleted = 0
        unloadAllTotal = 0
        currentOperation = nil
        operationStatusText = ""
        catalogCacheQueue.sync {
            cachedDiscsBySlot = [:]
            cachedBackupStatusesBySlot = [:]
        }

        if enabled {
            let state = MockChangerState()
            mockState = state
            changerService = MockChangerService(state: state)
            mountService = MockMountService(state: state)
            imagingService = MockImagingService()
        } else {
            mockState = nil
            changerService = ChangerService()
            mountService = MountService()
            imagingService = ImagingService()
        }

        // Reconnect using the new backend.
        connect()
    }

    private func scheduleReconcileDriveStatusFromOS() {
        // DiskArbitration events can arrive in quick bursts (and off-main).
        // Coalesce and apply on the main queue only when we're idle.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingDriveReconcile?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.reconcileDriveStatusFromOS()
            }
            self.pendingDriveReconcile = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    private func publishCarouselAnimation(_ kind: CarouselAnimationEvent.Kind) {
        DispatchQueue.main.async {
            self.carouselAnimationEvent = CarouselAnimationEvent(kind: kind)
        }
    }

    private func reconcileDriveStatusFromOS() {
        // Don't fight the explicit state machine during active operations.
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        if batchState?.isRunning == true { return }

        let discPresent = mountService.isDiscPresent()
        let bsdName = mountService.findDiscBSDName()

        if !discPresent || bsdName == nil {
            // If we thought a disc was loaded, clear drive state and any stale in-drive markers.
            if currentBSDName != nil || driveStatus != .empty {
                currentBSDName = nil
                driveStatus = .empty
                for i in 0..<slots.count {
                    slots[i].isInDrive = false
                }
            }
            return
        }

        let bsd = bsdName!
        let mountPoint = mountService.getMountPoint(bsdName: bsd)
        currentBSDName = bsd

        switch driveStatus {
        case .empty:
            driveStatus = .loaded(sourceSlot: 0, mountPoint: mountPoint)
        case .loaded(let sourceSlot, _):
            driveStatus = .loaded(sourceSlot: sourceSlot, mountPoint: mountPoint)
            if sourceSlot > 0, sourceSlot <= slots.count {
                slots[sourceSlot - 1].isInDrive = true
            }
        default:
            // Leave loading/ejecting/error states alone; user actions will reconcile.
            break
        }
    }

    // MARK: - Inventory

    func refreshInventory() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard batchState?.isRunning != true else { return }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .refreshing
            self?.operationStatusText = "Reading element status..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.doRefreshInventory()
            DispatchQueue.main.async {
                self?.currentOperation = nil
            }
        }
    }

    /// Internal refresh - must be called from background thread
    private func doRefreshInventory(includeCatalogHydration: Bool = false) {
        do {
            let inventory = try self.changerService.getInventoryStatus()
            var newSlots = inventory.slots
            let sourceSlotFromSCSI = inventory.drive.sourceSlot

            // Use DiskArbitration to detect if disc is present (more reliable)
            let discPresent = self.mountService.isDiscPresent()
            let bsdName = self.mountService.findDiscBSDName()

            if includeCatalogHydration {
                hydrateCatalogCache()
            }

            let (discsBySlot, backupStatuses) = catalogCacheSnapshot()
            for i in 0..<newSlots.count {
                let slotId = newSlots[i].id
                if let status = backupStatuses[slotId] {
                    newSlots[i].backupStatus = status
                }
                if let disc = discsBySlot[slotId] {
                    newSlots[i].discType = SlotDiscType.from(catalogString: disc.discType)
                    newSlots[i].volumeLabel = disc.volumeLabel
                }
            }

            // Capture existing source slot BEFORE dispatching to main
            // This avoids race conditions with the main queue
            let existingSourceSlot = DispatchQueue.main.sync { self.driveStatus.sourceSlot }

#if DEBUG
            print("doRefreshInventory: SCSI sourceSlot=\(sourceSlotFromSCSI ?? -1), existingSourceSlot=\(existingSourceSlot ?? -1), discPresent=\(discPresent), bsdName=\(bsdName ?? "nil")")
#endif

            DispatchQueue.main.async {
                self.slots = newSlots

                if discPresent, let bsd = bsdName {
                    // Disc is present - use DiskArbitration info
                    self.currentBSDName = bsd
                    let mountPoint = self.mountService.getMountPoint(bsdName: bsd)

                    // Use SCSI source slot if available, otherwise preserve existing sourceSlot
                    // (VGP-XL1B doesn't return drive element data, so we must remember it)
                    let sourceSlot: Int
                    if let scsiSlot = sourceSlotFromSCSI {
                        sourceSlot = scsiSlot
                    } else if let existing = existingSourceSlot, existing > 0 {
                        sourceSlot = existing
                    } else {
                        sourceSlot = 0  // Unknown
                    }

                    self.driveStatus = .loaded(sourceSlot: sourceSlot, mountPoint: mountPoint)

                    // Mark slot as in drive if we know the source
                    if sourceSlot > 0 && sourceSlot <= self.slots.count {
                        self.slots[sourceSlot - 1].isInDrive = true
                    }
                } else {
                    // No disc detected
                    self.driveStatus = .empty
                    self.currentBSDName = nil
                }
            }

        } catch let error as ChangerError {
            DispatchQueue.main.async {
                self.connectionError = error
            }
        } catch {
            DispatchQueue.main.async {
                self.connectionError = .unknown(error.localizedDescription)
            }
        }
    }

    private func hydrateCatalogCache() {
        let allDiscs = catalogService.getAllDiscs()
        let allStatuses = catalogService.getAllBackupStatuses()
        let discsBySlot = Dictionary(allDiscs.map { ($0.slotId, $0) }, uniquingKeysWith: { _, last in last })
        catalogCacheQueue.sync {
            self.cachedDiscsBySlot = discsBySlot
            self.cachedBackupStatusesBySlot = allStatuses
        }
    }

    private func catalogCacheSnapshot() -> ([Int: DiscRecord], [Int: BackupStatus]) {
        catalogCacheQueue.sync {
            (self.cachedDiscsBySlot, self.cachedBackupStatusesBySlot)
        }
    }

    private func refreshCatalogCache(forSlotIds slotIds: [Int], applyToVisibleSlots: Bool = true) {
        let uniqueSlotIds = Array(Set(slotIds)).sorted()
        guard !uniqueSlotIds.isEmpty else { return }

        var discBySlot: [Int: DiscRecord] = [:]
        var statusBySlot: [Int: BackupStatus] = [:]
        for slotId in uniqueSlotIds {
            if let disc = catalogService.getDisc(slotId: slotId) {
                discBySlot[slotId] = disc
            }
            statusBySlot[slotId] = catalogService.getBackupStatus(slotId: slotId)
        }

        catalogCacheQueue.sync {
            for slotId in uniqueSlotIds {
                if let disc = discBySlot[slotId] {
                    self.cachedDiscsBySlot[slotId] = disc
                } else {
                    self.cachedDiscsBySlot.removeValue(forKey: slotId)
                }
                if let status = statusBySlot[slotId] {
                    self.cachedBackupStatusesBySlot[slotId] = status
                } else {
                    self.cachedBackupStatusesBySlot.removeValue(forKey: slotId)
                }
            }
        }

        guard applyToVisibleSlots else { return }
        DispatchQueue.main.async {
            for slotId in uniqueSlotIds {
                guard slotId > 0, slotId <= self.slots.count else { continue }
                if let status = statusBySlot[slotId] {
                    self.slots[slotId - 1].backupStatus = status
                }
                if let disc = discBySlot[slotId] {
                    self.slots[slotId - 1].discType = SlotDiscType.from(catalogString: disc.discType)
                    self.slots[slotId - 1].volumeLabel = disc.volumeLabel
                }
            }
        }
    }

    func scanInventory() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard batchState?.isRunning != true else { return }

        let unknownSlots = slots.filter { $0.isFull && !$0.isInDrive && $0.discType == .unscanned }
        guard !unknownSlots.isEmpty else {
            operationStatusText = "No unknown discs to scan"
            return
        }

        let state = BatchOperationState()
        DispatchQueue.main.async { [weak self] in
            self?.batchState = state
        }

        let fallbackSourceSlot = slots.first(where: { $0.isInDrive })?.id
        let scannedSlotIds = unknownSlots.map(\.id)

        state.runScanUnknown(
            slots: unknownSlots,
            driveFallbackSourceSlot: fallbackSourceSlot,
            changerService: changerService,
            mountService: mountService,
            imagingService: imagingService,
            catalogService: catalogService,
            onUpdate: { [weak self] in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            },
            onSlotLoaded: { [weak self] slot, bsdName, mountPoint in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.currentBSDName = bsdName
                    self.driveStatus = .loaded(sourceSlot: slot, mountPoint: mountPoint)
                    if slot > 0 && slot <= self.slots.count {
                        self.slots[slot - 1].isFull = false
                        self.slots[slot - 1].isInDrive = true
                    }
                }
            },
            onSlotCataloged: { [weak self] slot in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.refreshCatalogCache(forSlotIds: [slot])
                }
            },
            onSlotEjected: { [weak self] slot in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if slot > 0 && slot <= self.slots.count {
                        self.slots[slot - 1].isInDrive = false
                        self.slots[slot - 1].isFull = true
                    }
                    self.driveStatus = .empty
                    self.currentBSDName = nil
                }
            },
            onComplete: { [weak self] in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.refreshCatalogCache(forSlotIds: scannedSlotIds)
                }
                self?.refreshInventory()
            }
        )
    }

    // MARK: - Single Slot Operations

    func loadSlot(_ slotNumber: Int) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard slotNumber >= 1 && slotNumber <= slots.count else { return }

        // Check drive is empty - use both our state and DiskArbitration
        guard driveStatus == .empty else {
            connectionError = .driveNotEmpty
            return
        }

        // Double-check with DiskArbitration since SCSI drive status doesn't work on VGP-XL1B
        if mountService.isDiscPresent() {
            connectionError = .driveNotEmpty
            // Refresh to sync our state with reality
            refreshInventory()
            return
        }

        // Check slot has disc
        guard slots[slotNumber - 1].isFull else {
            connectionError = .slotEmpty(slotNumber)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .loadingSlot(slotNumber)
            self?.driveStatus = .loading(fromSlot: slotNumber)
            self?.operationStatusText = "Loading disc from slot \(slotNumber)..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.loadSlot(slotNumber)
                self.publishCarouselAnimation(.loadFromSlot(slotNumber))

                DispatchQueue.main.async {
                    // Update slot status
                    self.slots[slotNumber - 1].isFull = false
                    self.slots[slotNumber - 1].isInDrive = true
                    self.operationStatusText = "Waiting for disc..."
                }

                // Wait for disc to appear
                let bsdName = try self.mountService.waitForDisc(timeout: 60)

                DispatchQueue.main.async {
                    self.currentBSDName = bsdName
                    self.operationStatusText = "Mounting disc..."
                }

                // Mount if possible. Some media (e.g. audio CDs) have no filesystem mount.
                let discType = self.imagingService.detectDiscType(bsdName: bsdName)
                let allowMountless = (discType == .audioCDDA)
                let mountPoint: String?
                do {
                    mountPoint = try self.mountService.mountDisc(bsdName: bsdName)
                } catch let error as ChangerError {
                    if
                        allowMountless,
                        case .mountFailed(let reason) = error,
                        reason == "No mount point returned"
                    {
                        mountPoint = self.mountService.getMountPoint(bsdName: bsdName)
                    } else {
                        throw error
                    }
                }

                DispatchQueue.main.async {
                    self.driveStatus = .loaded(sourceSlot: slotNumber, mountPoint: mountPoint)
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil

                    // If drive is not empty, update our state and refresh
                    if case .driveNotEmpty = error {
                        // We thought drive was empty but it's not - refresh to sync state
                        self.driveStatus = .loaded(sourceSlot: 0, mountPoint: nil)
                    } else {
                        self.driveStatus = .error(error.localizedDescription ?? "Unknown error")
                    }
                }

                // Refresh inventory to sync with hardware state
                if case .driveNotEmpty = error {
                    self.doRefreshInventory()
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.driveStatus = .error(error.localizedDescription)
                    self.currentOperation = nil
                }
            }
        }
    }

    func loadSlotWithEjectIfNeeded(_ slotNumber: Int) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard slotNumber >= 1 && slotNumber <= slots.count else { return }
        guard slots[slotNumber - 1].isFull && !slots[slotNumber - 1].isInDrive else { return }

        switch driveStatus {
        case .empty:
            loadSlot(slotNumber)
        case .loaded:
            pendingLoadSlotIdAfterEject = slotNumber
            ejectDisc { [weak self] in
                guard let self = self else { return }
                let target = self.pendingLoadSlotIdAfterEject
                self.pendingLoadSlotIdAfterEject = nil
                guard let target else { return }
                guard target >= 1 && target <= self.slots.count else { return }
                guard self.slots[target - 1].isFull && !self.slots[target - 1].isInDrive else { return }
                self.loadSlot(target)
            }
        default:
            return
        }
    }

    func ejectDisc(toSlot: Int? = nil, completion: (() -> Void)? = nil) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }

        guard case .loaded(let sourceSlot, _) = driveStatus else {
            connectionError = .driveEmpty
            return
        }

        // Determine target slot - use provided slot, or source slot if known
        let targetSlot: Int
        if let specified = toSlot {
            targetSlot = specified
        } else if sourceSlot > 0 {
            targetSlot = sourceSlot
        } else if let inDriveSlot = slots.first(where: { $0.isInDrive })?.id {
            // Found a slot marked as "in drive" - that's where the disc came from
            targetSlot = inDriveSlot
            print("ejectDisc: source slot unknown but found slot \(inDriveSlot) marked as inDrive")
        } else {
            // Source slot truly unknown - need to find an empty slot
            if let emptySlot = slots.first(where: { !$0.isFull && !$0.isInDrive })?.id {
                targetSlot = emptySlot
                print("ejectDisc: source slot unknown, using first empty slot \(emptySlot)")
            } else {
                connectionError = .commandFailed("Cannot eject: source slot unknown and no empty slots")
                return
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .ejecting
            self?.driveStatus = .ejecting(toSlot: targetSlot)
            self?.operationStatusText = "Unmounting disc..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Unmount the disc first
                if let bsd = self.currentBSDName {
                    if self.mountService.isMounted(bsdName: bsd) {
                        DispatchQueue.main.async {
                            self.operationStatusText = "Unmounting disc..."
                        }
                        try self.mountService.unmountDisc(bsdName: bsd)
                    }

                    // Eject the optical drive tray using drutil (real hardware only).
                    // This tells the drive to release/present the disc so the changer can grab it.
                    if self.mockState == nil {
                        DispatchQueue.main.async {
                            self.operationStatusText = "Ejecting disc from drive..."
                        }
                        let process = Process()
                        process.launchPath = "/usr/bin/drutil"
                        process.arguments = ["eject"]
                        process.launch()
                        process.waitUntilExit()
                    }
                }

                DispatchQueue.main.async {
                    self.operationStatusText = "Moving disc to slot \(targetSlot)..."
                }

                try self.changerService.ejectToSlot(targetSlot)
                self.publishCarouselAnimation(.ejectToSlot(targetSlot))

                DispatchQueue.main.async {
                    // Update state
                    if sourceSlot > 0 && sourceSlot <= self.slots.count {
                        self.slots[sourceSlot - 1].isInDrive = false
                    }
                    if targetSlot > 0 && targetSlot <= self.slots.count {
                        self.slots[targetSlot - 1].isFull = true
                    }

                    self.driveStatus = .empty
                    self.currentBSDName = nil
                    self.currentOperation = nil
                    completion?()
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.driveStatus = .error(error.localizedDescription ?? "Unknown error")
                    self.currentOperation = nil
                    self.pendingLoadSlotIdAfterEject = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.driveStatus = .error(error.localizedDescription)
                    self.currentOperation = nil
                    self.pendingLoadSlotIdAfterEject = nil
                }
            }
        }
    }

    func mountDisc() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }

        guard case .loaded(let sourceSlot, nil) = driveStatus else {
            // Already mounted or no disc
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .mounting
            self?.operationStatusText = "Mounting disc..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                guard let bsd = self.currentBSDName ?? self.mountService.findDiscBSDName() else {
                    throw ChangerError.driveEmpty
                }

                DispatchQueue.main.async {
                    self.currentBSDName = bsd
                }

                let mountPoint = try self.mountService.mountDisc(bsdName: bsd)

                DispatchQueue.main.async {
                    self.driveStatus = .loaded(sourceSlot: sourceSlot, mountPoint: mountPoint)
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.currentOperation = nil
                }
            }
        }
    }

    func unmountDisc(force: Bool = false) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }

        guard case .loaded(let sourceSlot, let mp) = driveStatus, mp != nil else {
            // Not mounted
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .unmounting
            self?.operationStatusText = "Unmounting disc..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                guard let bsd = self.currentBSDName else {
                    throw ChangerError.driveEmpty
                }

                try self.mountService.unmountDisc(bsdName: bsd, force: force)

                DispatchQueue.main.async {
                    self.driveStatus = .loaded(sourceSlot: sourceSlot, mountPoint: nil)
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.currentOperation = nil
                }
            }
        }
    }

    // MARK: - Scan Slot

    /// Scan a single slot: load disc, mount, record metadata, unmount, eject back
    func scanSlotDisc(_ slotNumber: Int) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard slotNumber >= 1 && slotNumber <= slots.count else { return }
        guard slots[slotNumber - 1].isFull && !slots[slotNumber - 1].isInDrive else { return }

        // If drive has a disc, we can't scan
        if driveStatus != .empty || mountService.isDiscPresent() {
            connectionError = .driveNotEmpty
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .scanningSlot(slotNumber)
            self?.driveStatus = .loading(fromSlot: slotNumber)
            self?.operationStatusText = "Loading disc from slot \(slotNumber)..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // 1. Load disc into drive
                try self.changerService.loadSlot(slotNumber)
                self.publishCarouselAnimation(.loadFromSlot(slotNumber))

                DispatchQueue.main.async {
                    self.slots[slotNumber - 1].isFull = false
                    self.slots[slotNumber - 1].isInDrive = true
                    self.operationStatusText = "Waiting for disc..."
                }

                // 2. Wait for disc to appear
                let bsdName = try self.mountService.waitForDisc(timeout: 60)

                DispatchQueue.main.async {
                    self.currentBSDName = bsdName
                    self.operationStatusText = "Mounting disc..."
                }

                // 3. Mount disc
                let mountPoint = try self.mountService.mountDisc(bsdName: bsdName)

                DispatchQueue.main.async {
                    self.driveStatus = .loaded(sourceSlot: slotNumber, mountPoint: mountPoint)
                    self.operationStatusText = "Detecting disc type..."
                }

                // 4. Detect disc type and record metadata
                let discType = self.imagingService.detectDiscType(bsdName: bsdName)
                let estimatedSize = self.imagingService.estimateDiscSizeBytes(bsdName: bsdName)

                _ = self.catalogService.recordDisc(
                    slotId: slotNumber,
                    bsdName: bsdName,
                    discType: discType,
                    sizeBytes: estimatedSize
                )

                self.refreshCatalogCache(forSlotIds: [slotNumber])

                DispatchQueue.main.async {
                    self.operationStatusText = "Unmounting disc..."
                }

                // 5. Unmount
                if self.mountService.isMounted(bsdName: bsdName) {
                    try self.mountService.unmountDisc(bsdName: bsdName)
                }

                // 6. Eject from drive tray (real hardware only)
                if self.mockState == nil {
                    DispatchQueue.main.async {
                        self.operationStatusText = "Ejecting disc from drive..."
                    }
                    let process = Process()
                    process.launchPath = "/usr/bin/drutil"
                    process.arguments = ["eject"]
                    process.launch()
                    process.waitUntilExit()
                }

                DispatchQueue.main.async {
                    self.driveStatus = .ejecting(toSlot: slotNumber)
                    self.operationStatusText = "Ejecting to slot \(slotNumber)..."
                }

                // 7. Move disc back to slot
                try self.changerService.ejectToSlot(slotNumber)
                self.publishCarouselAnimation(.ejectToSlot(slotNumber))

                DispatchQueue.main.async {
                    self.slots[slotNumber - 1].isInDrive = false
                    self.slots[slotNumber - 1].isFull = true
                    self.driveStatus = .empty
                    self.currentBSDName = nil
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.driveStatus = .error(error.localizedDescription ?? "Unknown error")
                    self.currentOperation = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.driveStatus = .error(error.localizedDescription)
                    self.currentOperation = nil
                }
            }
        }
    }

    // MARK: - Import/Export Operations

    func unloadSlot(_ slotNumber: Int) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard slotNumber >= 1 && slotNumber <= slots.count else { return }

        // Check slot has disc
        guard slots[slotNumber - 1].isFull else {
            connectionError = .slotEmpty(slotNumber)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .ejecting
            self?.operationStatusText = "Ejecting slot \(slotNumber) to I/E slot..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.unloadToIE(slotNumber)
                self.publishCarouselAnimation(.ejectFromChamber(slotNumber))

                DispatchQueue.main.async {
                    self.slots[slotNumber - 1].isFull = false
                    self.currentOperation = nil
                    self.operationStatusText = "Remove disc from I/E slot"
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.currentOperation = nil
                }
            }
        }
    }

    func importToSlot(_ slotNumber: Int) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard slotNumber >= 1 && slotNumber <= slots.count else { return }

        // Check slot is empty
        guard !slots[slotNumber - 1].isFull else {
            connectionError = .slotOccupied(slotNumber)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .loadingSlot(slotNumber)
            self?.operationStatusText = "Importing disc from I/E slot to slot \(slotNumber)..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.importFromIE(slotNumber)

                DispatchQueue.main.async {
                    self.slots[slotNumber - 1].isFull = true
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.currentOperation = nil
                }
            }
        }
    }

    /// Check if changer has I/E slot
    var hasIESlot: Bool {
        changerService.hasIESlot
    }

    /// Import disc from I/E slot directly into drive
    func importFromIESlot() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard case .empty = driveStatus else { return }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .loadingSlot(0)
            self?.operationStatusText = "Loading disc from I/E slot..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.loadFromIE()

                DispatchQueue.main.async {
                    self.operationStatusText = "Waiting for disc..."
                }

                // Wait for disc to appear
                let bsdName = try self.mountService.waitForDisc(timeout: 60)

                DispatchQueue.main.async {
                    self.currentBSDName = bsdName
                    self.operationStatusText = "Mounting disc..."
                }

                // Mount
                let mountPoint = try self.mountService.mountDisc(bsdName: bsdName)

                DispatchQueue.main.async {
                    self.driveStatus = .loaded(sourceSlot: 0, mountPoint: mountPoint)
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.currentOperation = nil
                }
            }
        }
    }

    // MARK: - Unload All

    /// Start unloading all discs to I/E slot one at a time
    func startUnloadAll() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard hasIESlot else { return }

        // Build queue of slots with discs (not in drive)
        let slotsToUnload = slots.filter { $0.isFull && !$0.isInDrive }.map { $0.id }
        guard !slotsToUnload.isEmpty else { return }

        unloadAllQueue = slotsToUnload
        unloadAllTotal = slotsToUnload.count
        unloadAllCompleted = 0
        unloadAllInProgress = true

        // Start with first disc
        unloadNextDisc()
    }

    /// Cancel unload all operation
    func cancelUnloadAll() {
        unloadAllInProgress = false
        unloadAllQueue = []
        currentOperation = nil
    }

    /// Continue to next disc after user removes current one from I/E
    func continueUnloadAll() {
        guard unloadAllInProgress else { return }
        // In mock mode, treat "Continue" as the user removing the disc from I/E.
        mockState?.clearIESlot()
        unloadNextDisc()
    }

    private func unloadNextDisc() {
        guard unloadAllInProgress else { return }

        guard let nextSlot = unloadAllQueue.first else {
            // All done
            unloadAllInProgress = false
            currentOperation = nil
            operationStatusText = "Eject complete"
            return
        }

        unloadAllQueue.removeFirst()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentOperation = .unloading(nextSlot)
            self.operationStatusText = "Ejecting slot \(nextSlot) to I/E (\(self.unloadAllCompleted + 1) of \(self.unloadAllTotal))..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.unloadToIE(nextSlot)
                self.publishCarouselAnimation(.ejectFromChamber(nextSlot))

                DispatchQueue.main.async {
                    self.slots[nextSlot - 1].isFull = false
                    self.unloadAllCompleted += 1

                    if self.mockState != nil {
                        // In mock mode, auto-clear I/E and continue without waiting for user input.
                        self.mockState?.clearIESlot()
                        if self.unloadAllQueue.isEmpty {
                            self.unloadAllInProgress = false
                            self.currentOperation = nil
                            self.operationStatusText = "Eject complete"
                        } else {
                            self.currentOperation = .refreshing
                            self.operationStatusText = "Preparing next disc..."
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                self.unloadNextDisc()
                            }
                        }
                    } else if self.unloadAllQueue.isEmpty {
                        // Last disc - we're done
                        self.unloadAllInProgress = false
                        self.currentOperation = nil
                        self.operationStatusText = "Eject complete - remove disc from I/E slot"
                    } else {
                        // Wait for user to remove disc before continuing
                        self.currentOperation = .waitingForDiscRemoval(nextSlot)
                        self.operationStatusText = "Remove disc from I/E, then Continue (\(self.unloadAllCompleted)/\(self.unloadAllTotal))"
                    }
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    // Skip errors and continue to next slot
                    print("Slot \(nextSlot) failed: \(error.localizedDescription ?? "unknown"), skipping...")
                    self.slots[nextSlot - 1].isFull = false  // Mark as empty since it probably is
                    // Continue to next disc
                    self.unloadNextDisc()
                }
            } catch {
                DispatchQueue.main.async {
                    // Skip errors and continue to next slot
                    print("Slot \(nextSlot) failed: \(error.localizedDescription), skipping...")
                    self.slots[nextSlot - 1].isFull = false
                    self.unloadNextDisc()
                }
            }
        }
    }

    // MARK: - Computed Properties

    var fullSlotCount: Int {
        slots.filter { $0.isFull || $0.isInDrive }.count
    }

    var emptySlotCount: Int {
        slots.filter { !$0.isFull && !$0.isInDrive }.count
    }

    var deviceDescription: String {
        if let vendor = deviceVendor, let product = deviceProduct {
            return "\(vendor) \(product)"
        }
        return "Not connected"
    }

    // MARK: - Batch Operations

    /// Start batch load operation
    func startBatchLoad() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }

        let state = BatchOperationState()
        DispatchQueue.main.async { [weak self] in
            self?.batchState = state
        }

        state.runLoadAll(
            slots: slots,
            changerService: changerService,
            mountService: mountService,
            onUpdate: { [weak self] in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            },
            onSlotLoaded: { [weak self] slot, bsdName, mountPoint in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.currentBSDName = bsdName
                    self.driveStatus = .loaded(sourceSlot: slot, mountPoint: mountPoint)
                    if slot > 0 && slot <= self.slots.count {
                        self.slots[slot - 1].isFull = false
                        self.slots[slot - 1].isInDrive = true
                    }
                }
            },
            onSlotEjected: { [weak self] slot in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if slot > 0 && slot <= self.slots.count {
                        self.slots[slot - 1].isFull = true
                        self.slots[slot - 1].isInDrive = false
                    }
                    self.driveStatus = .empty
                    self.currentBSDName = nil
                }
            },
            onComplete: { [weak self] in
                self?.refreshInventory()
            }
        )
    }

    // MARK: - Imaging Operations

    /// Get slots available for imaging (have discs, including one in drive)
    var rippableSlots: [Slot] {
        slots.filter { $0.isFull || $0.isInDrive }
    }

    /// Selected slots that have already been successfully imaged.
    var previouslyImagedSelectedSlots: [Slot] {
        slots
            .filter { selectedSlotsForRip.contains($0.id) }
            .filter {
                if case .backedUp = $0.backupStatus {
                    return true
                }
                return false
            }
            .sorted { $0.id < $1.id }
    }

    var previouslyImagedSelectedCount: Int {
        previouslyImagedSelectedSlots.count
    }

    /// Anchor slot for shift-click range selection
    var ripSelectionAnchor: Int?

    /// Select only this slot (plain click)
    func selectSlotForRip(_ slotId: Int) {
        selectedSlotsForRip = [slotId]
        ripSelectionAnchor = slotId
    }

    /// Toggle individual slot (Cmd+click)
    func toggleSlotForRip(_ slotId: Int) {
        if selectedSlotsForRip.contains(slotId) {
            selectedSlotsForRip.remove(slotId)
        } else {
            selectedSlotsForRip.insert(slotId)
        }
        ripSelectionAnchor = slotId
    }

    /// Extend selection as range from anchor to slotId (Shift+click)
    func extendSlotSelectionForRip(to slotId: Int) {
        let anchor = ripSelectionAnchor ?? slotId
        let lo = min(anchor, slotId)
        let hi = max(anchor, slotId)
        let rangeIds = slots.filter { $0.id >= lo && $0.id <= hi && ($0.isFull || $0.isInDrive) }.map { $0.id }
        selectedSlotsForRip = Set(rangeIds)
        // Don't update anchor - keep it for subsequent shift-clicks
    }

    /// Select all rippable slots
    func selectAllSlotsForRip() {
        selectedSlotsForRip = Set(rippableSlots.map { $0.id })
    }

    /// Clear slot selection for ripping
    func clearSlotSelectionForRip() {
        selectedSlotsForRip.removeAll()
        ripSelectionAnchor = nil
    }

    /// Start batch imaging operation
    func startBatchImaging(outputDirectory: URL) {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard !selectedSlotsForRip.isEmpty else { return }

        let slotsToRip = slots.filter { selectedSlotsForRip.contains($0.id) && ($0.isFull || $0.isInDrive) }
        guard !slotsToRip.isEmpty else { return }
        let slotIdsToRip = slotsToRip.map(\.id)

        let state = BatchOperationState()
        DispatchQueue.main.async { [weak self] in
            self?.batchState = state
        }

        state.runImageAll(
            slots: slotsToRip,
            outputDirectory: outputDirectory,
            driveFallbackSourceSlot: slots.first(where: { $0.isInDrive })?.id,
            changerService: changerService,
            mountService: mountService,
            imagingService: imagingService,
            catalogService: catalogService,
            onUpdate: { [weak self] in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            },
            onSlotLoaded: { [weak self] slot, bsdName, mountPoint in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.currentBSDName = bsdName
                    self.driveStatus = .loaded(sourceSlot: slot, mountPoint: mountPoint)
                    if slot > 0 && slot <= self.slots.count {
                        self.slots[slot - 1].isFull = false
                        self.slots[slot - 1].isInDrive = true
                    }
                }
            },
            onSlotEjected: { [weak self] slot in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if slot > 0 && slot <= self.slots.count {
                        self.slots[slot - 1].isFull = true
                        self.slots[slot - 1].isInDrive = false
                    }
                    self.driveStatus = .empty
                    self.currentBSDName = nil
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.refreshCatalogCache(forSlotIds: [slot])
                }
            },
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    self?.selectedSlotsForRip.removeAll()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.refreshCatalogCache(forSlotIds: slotIdsToRip)
                }
                self?.refreshInventory()
            }
        )
    }

    // MARK: - Dirty Flag (Crash Recovery)

    private static let dirtyFlagKey = "discbot.operationInProgress"

    static func setDirtyFlag(sourceSlot: Int) {
        UserDefaults.standard.set(sourceSlot, forKey: dirtyFlagKey)
        UserDefaults.standard.synchronize()
    }

    static func clearDirtyFlag() {
        UserDefaults.standard.removeObject(forKey: dirtyFlagKey)
        UserDefaults.standard.synchronize()
    }

    static func checkDirtyFlag() -> Int? {
        let value = UserDefaults.standard.integer(forKey: dirtyFlagKey)
        return value > 0 ? value : nil
    }

    // MARK: - Emergency Shutdown

    /// Attempt to eject disc back to its source slot synchronously.
    /// Called during app termination from a background thread.
    func emergencyEjectSync() -> Bool {
        guard case .loaded(let sourceSlot, _) = driveStatus, sourceSlot > 0 else {
            return true
        }

        do {
            if let bsd = currentBSDName {
                try? mountService.unmountDisc(bsdName: bsd, force: true)
                Thread.sleep(forTimeInterval: 1.0)

                if mockState == nil {
                    let process = Process()
                    process.launchPath = "/usr/bin/drutil"
                    process.arguments = ["eject"]
                    process.launch()
                    process.waitUntilExit()
                    Thread.sleep(forTimeInterval: 3.0)
                }
            }

            try changerService.ejectToSlot(sourceSlot)
            return true
        } catch {
            print("emergencyEjectSync failed: \(error)")
            return false
        }
    }
}

// MARK: - Drive Media Observer (Event-Driven, No Changer Polling)

private final class DriveMediaObserver {
    typealias ChangeHandler = () -> Void

    private let onChange: ChangeHandler
    private let queue = DispatchQueue(label: "discbot.driveMediaObserver")
    private var session: DASession?

    init(onChange: @escaping ChangeHandler) {
        self.onChange = onChange
    }

    func start() {
        guard session == nil else { return }
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        // Whole + removable reduces noise (partitions, internal disks, etc).
        let match: CFDictionary = [
            kDADiskDescriptionMediaWholeKey as String: true,
            kDADiskDescriptionMediaRemovableKey as String: true,
        ] as CFDictionary

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        DARegisterDiskAppearedCallback(session, match, driveMediaObserverDiskAppeared, context)
        DARegisterDiskDisappearedCallback(session, match, driveMediaObserverDiskDisappeared, context)

        // DiskArbitration will invoke callbacks on this queue.
        DASessionSetDispatchQueue(session, queue)
    }

    func stop() {
        guard let session = session else { return }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
    }

    deinit {
        stop()
    }

    fileprivate func notifyChange() {
        onChange()
    }
}

private func driveMediaObserverDiskAppeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let observer = Unmanaged<DriveMediaObserver>.fromOpaque(context).takeUnretainedValue()
    observer.notifyChange()
}

private func driveMediaObserverDiskDisappeared(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let observer = Unmanaged<DriveMediaObserver>.fromOpaque(context).takeUnretainedValue()
    observer.notifyChange()
}
