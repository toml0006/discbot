//
//  ChangerViewModel.swift
//  Discbot
//
//  Main view model for the application
//

import Foundation
import SwiftUI
import Combine

final class ChangerViewModel: ObservableObject {
    // Connection state
    @Published var isConnected = false
    @Published var connectionError: ChangerError?

    // Device info
    @Published var deviceVendor: String?
    @Published var deviceProduct: String?

    // Drive state
    @Published var driveStatus: DriveStatus = .empty
    @Published var currentBSDName: String?

    // Inventory
    @Published var slots: [Slot] = []
    @Published var selectedSlotId: Int?

    // Operation state
    @Published var currentOperation: Operation?
    @Published var operationStatusText: String = ""

    // Batch operation
    @Published var batchState: BatchOperationState?

    // Unload all state
    @Published var unloadAllInProgress = false
    @Published var unloadAllQueue: [Int] = []  // Slots remaining to unload
    @Published var unloadAllCompleted: Int = 0
    @Published var unloadAllTotal: Int = 0

    // Services
    private let changerService = ChangerService()
    private let mountService = MountService()

    enum Operation: Equatable {
        case connecting
        case loadingSlot(Int)
        case ejecting
        case mounting
        case unmounting
        case scanning
        case refreshing
        case unloading(Int)
        case waitingForDiscRemoval(Int)  // Waiting for user to remove disc from I/E
    }

    init() {
        // Auto-connect on start
        connect()
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
                }

                // Load initial inventory
                self.doRefreshInventory()

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
        }
    }

    // MARK: - Inventory

    func refreshInventory() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }

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
    private func doRefreshInventory() {
        do {
            let newSlots = try self.changerService.getSlotStatus()

            // Note: VGP-XL1B doesn't support READ ELEMENT STATUS for drive elements,
            // so we detect disc presence using DiskArbitration instead
            let (_, sourceSlotFromSCSI) = try self.changerService.getDriveStatus()

            // Use DiskArbitration to detect if disc is present (more reliable)
            let discPresent = self.mountService.isDiscPresent()
            let bsdName = self.mountService.findDiscBSDName()

            // Capture existing source slot BEFORE dispatching to main
            // This avoids race conditions with the main queue
            let existingSourceSlot = DispatchQueue.main.sync { self.driveStatus.sourceSlot }

            print("doRefreshInventory: SCSI sourceSlot=\(sourceSlotFromSCSI ?? -1), existingSourceSlot=\(existingSourceSlot ?? -1), discPresent=\(discPresent), bsdName=\(bsdName ?? "nil")")

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

    func scanInventory() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }

        DispatchQueue.main.async { [weak self] in
            self?.currentOperation = .scanning
            self?.operationStatusText = "Scanning all slots (this may take several minutes)..."
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.initializeElementStatus()

                // Wait a bit for the changer to settle
                Thread.sleep(forTimeInterval: 5.0)

                DispatchQueue.main.async {
                    self.operationStatusText = "Reading element status..."
                }

                // Refresh inventory directly (don't use refreshInventory() which has guards)
                self.doRefreshInventory()

                DispatchQueue.main.async {
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

                // Mount
                let mountPoint = try self.mountService.mountDisc(bsdName: bsdName)

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

    func ejectDisc(toSlot: Int? = nil) {
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
                        // Give the system time to finish unmount
                        Thread.sleep(forTimeInterval: 1.0)
                    }

                    // Eject the optical drive tray using drutil
                    // This tells the drive to release/present the disc so the changer can grab it
                    DispatchQueue.main.async {
                        self.operationStatusText = "Ejecting disc from drive..."
                    }
                    let process = Process()
                    process.launchPath = "/usr/bin/drutil"
                    process.arguments = ["eject"]
                    process.launch()
                    process.waitUntilExit()
                    // Give the drive time to fully eject
                    Thread.sleep(forTimeInterval: 3.0)
                }

                DispatchQueue.main.async {
                    self.operationStatusText = "Moving disc to slot \(targetSlot)..."
                }

                try self.changerService.ejectToSlot(targetSlot)

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

                DispatchQueue.main.async {
                    self.slots[nextSlot - 1].isFull = false
                    self.unloadAllCompleted += 1

                    if self.unloadAllQueue.isEmpty {
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
}
