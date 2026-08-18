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

enum CarouselBatchMode: String {
    case load
    case unload
}

enum CarouselBatchAction: String {
    case retry
    case skip
    case continueAfterRemoval = "continue"
    case finish
    case cancel
}

struct CarouselBatchFailure: Equatable {
    let slot: Int
    let message: String
}

struct CarouselBatchSnapshot: Equatable {
    let id: String
    let mode: CarouselBatchMode
    let running: Bool
    let cancelled: Bool
    let awaitingAction: Bool
    let allowedActions: [CarouselBatchAction]
    let currentSlot: Int?
    let currentIndex: Int
    let total: Int
    let completedSlots: [Int]
    let skippedSlots: [Int]
    let failures: [CarouselBatchFailure]
    let status: String

    var progress: Double {
        total == 0 ? 0 : Double(completedSlots.count + skippedSlots.count) / Double(total)
    }
}

/// Serial, state-reconciled operator workflow for the Sony XL1B gate. Each
/// movement is followed by a fresh inventory read before the queue advances.
/// The worker can wait for a web/desktop action without holding any changer
/// lock, and cancellation takes effect at the next mechanically safe boundary.
final class CarouselBatchOperation {
    private let condition = NSCondition()
    private let service: ChangerServicing
    private let targets: [Int]
    private let onSnapshot: (CarouselBatchSnapshot) -> Void
    private let onSlotState: (Int, Bool) -> Void
    private let onFinished: () -> Void

    private var running = true
    private var cancelled = false
    private var finishRequested = false
    private var awaitingAction = false
    private var allowedActions: [CarouselBatchAction] = []
    private var pendingAction: CarouselBatchAction?
    private var currentSlot: Int?
    private var currentIndex = 0
    private var completedSlots: [Int] = []
    private var skippedSlots: [Int] = []
    private var failures: [CarouselBatchFailure] = []
    private var status: String

    let id = UUID().uuidString
    let mode: CarouselBatchMode

    init(
        mode: CarouselBatchMode,
        targets: [Int],
        service: ChangerServicing,
        onSnapshot: @escaping (CarouselBatchSnapshot) -> Void,
        onSlotState: @escaping (Int, Bool) -> Void,
        onFinished: @escaping () -> Void
    ) {
        self.mode = mode
        self.targets = targets
        self.service = service
        self.onSnapshot = onSnapshot
        self.onSlotState = onSlotState
        self.onFinished = onFinished
        self.status = mode == .load ? "Preparing bulk load…" : "Preparing bulk unload…"
    }

    func start() {
        publish()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.run()
        }
    }

    func perform(_ action: CarouselBatchAction) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard running else { return false }
        if action == .cancel || action == .finish {
            cancelled = action == .cancel
            finishRequested = action == .finish
            pendingAction = action
            condition.broadcast()
            return true
        }
        guard awaitingAction, allowedActions.contains(action) else { return false }
        pendingAction = action
        condition.broadcast()
        return true
    }

    func snapshot() -> CarouselBatchSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return snapshotLocked()
    }

    private func run() {
        for (offset, slot) in targets.enumerated() {
            if shouldStop() { break }
            setCurrent(slot: slot, index: offset + 1)

            var retry = true
            while retry && !shouldStop() {
                retry = false
                do {
                    let inventory = try service.getInventoryStatus()
                    guard slot > 0, slot <= inventory.slots.count else {
                        throw ChangerError.commandFailed("Slot \(slot) is outside the reported inventory")
                    }
                    let full = inventory.slots[slot - 1].isFull
                    if mode == .load && full { throw ChangerError.slotOccupied(slot) }
                    if mode == .unload && !full { throw ChangerError.slotEmpty(slot) }

                    setStatus(mode == .load
                        ? "Insert disc for slot \(slot) (\(offset + 1) of \(targets.count))"
                        : "Presenting slot \(slot) (\(offset + 1) of \(targets.count))")
                    if mode == .load {
                        try service.importFromIE(slot)
                    } else {
                        try service.unloadToIE(slot)
                    }

                    let verified = try service.getInventoryStatus()
                    let destinationFull = verified.slots[slot - 1].isFull
                    guard destinationFull == (mode == .load) else {
                        throw ChangerError.moveFailed("Inventory did not confirm the move for slot \(slot)")
                    }

                    markCompleted(slot: slot)
                    onSlotState(slot, mode == .load)

                    if mode == .unload {
                        let action = waitForAction(
                            status: "Remove the disc from the gate, then continue",
                            allowed: [.continueAfterRemoval, .finish, .cancel]
                        )
                        if action == .cancel { setCancelled() }
                        if action == .finish || action == .cancel { break }
                    }
                } catch let error as ChangerError {
                    if reconcileCompleted(slot: slot) {
                        markCompleted(slot: slot)
                        onSlotState(slot, mode == .load)
                        continue
                    }

                    let message = error == .timeout && mode == .load
                        ? "No disc was inserted for slot \(slot)"
                        : error.localizedDescription
                    recordFailure(slot: slot, message: message)
                    let action = waitForAction(
                        status: message,
                        allowed: [.retry, .skip, .finish, .cancel]
                    )
                    switch action {
                    case .retry:
                        retry = true
                    case .skip:
                        markSkipped(slot: slot)
                    case .cancel:
                        setCancelled()
                    case .finish, .continueAfterRemoval:
                        break
                    }
                    if action == .finish || action == .cancel { break }
                } catch {
                    let message = error.localizedDescription
                    recordFailure(slot: slot, message: message)
                    let action = waitForAction(
                        status: message,
                        allowed: [.retry, .skip, .finish, .cancel]
                    )
                    retry = action == .retry
                    if action == .skip { markSkipped(slot: slot) }
                    if action == .cancel { setCancelled() }
                    if action == .finish || action == .cancel { break }
                }
            }
        }

        condition.lock()
        running = false
        awaitingAction = false
        allowedActions = []
        currentSlot = nil
        if cancelled {
            status = "Carousel operation cancelled safely"
        } else if completedSlots.count + skippedSlots.count == targets.count {
            status = mode == .load
                ? "Bulk load complete — \(completedSlots.count) discs loaded"
                : "Bulk unload complete — \(completedSlots.count) discs removed"
        } else {
            status = "Carousel operation finished early"
        }
        let final = snapshotLocked()
        condition.unlock()
        onSnapshot(final)
        onFinished()
    }

    private func reconcileCompleted(slot: Int) -> Bool {
        guard let inventory = try? service.getInventoryStatus(),
              slot > 0, slot <= inventory.slots.count else { return false }
        return inventory.slots[slot - 1].isFull == (mode == .load)
    }

    private func shouldStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return cancelled || finishRequested
    }

    private func waitForAction(
        status newStatus: String,
        allowed: [CarouselBatchAction]
    ) -> CarouselBatchAction {
        condition.lock()
        if cancelled || finishRequested {
            let action: CarouselBatchAction = cancelled ? .cancel : .finish
            condition.unlock()
            return action
        }
        status = newStatus
        awaitingAction = true
        allowedActions = allowed
        pendingAction = nil
        let value = snapshotLocked()
        condition.unlock()
        onSnapshot(value)

        condition.lock()
        while pendingAction == nil && running {
            condition.wait()
        }
        let action = pendingAction ?? .finish
        pendingAction = nil
        awaitingAction = false
        allowedActions = []
        condition.unlock()
        publish()
        return action
    }

    private func setCurrent(slot: Int, index: Int) {
        condition.lock()
        currentSlot = slot
        currentIndex = index
        condition.unlock()
        publish()
    }

    private func setStatus(_ value: String) {
        condition.lock()
        status = value
        condition.unlock()
        publish()
    }

    private func markCompleted(slot: Int) {
        condition.lock()
        if !completedSlots.contains(slot) { completedSlots.append(slot) }
        failures.removeAll { $0.slot == slot }
        condition.unlock()
        publish()
    }

    private func markSkipped(slot: Int) {
        condition.lock()
        if !skippedSlots.contains(slot) { skippedSlots.append(slot) }
        condition.unlock()
        publish()
    }

    private func recordFailure(slot: Int, message: String) {
        condition.lock()
        failures.removeAll { $0.slot == slot }
        failures.append(CarouselBatchFailure(slot: slot, message: message))
        condition.unlock()
        publish()
    }

    private func setCancelled() {
        condition.lock()
        cancelled = true
        condition.unlock()
        publish()
    }

    private func publish() {
        onSnapshot(snapshot())
    }

    private func snapshotLocked() -> CarouselBatchSnapshot {
        CarouselBatchSnapshot(
            id: id,
            mode: mode,
            running: running,
            cancelled: cancelled,
            awaitingAction: awaitingAction,
            allowedActions: allowedActions,
            currentSlot: currentSlot,
            currentIndex: currentIndex,
            total: targets.count,
            completedSlots: completedSlots,
            skippedSlots: skippedSlots,
            failures: failures,
            status: status
        )
    }
}

enum ChangerConnectionHealth: String {
    case connecting
    case online
    case retrying
    case deviceMissing
    case ownedElsewhere
    case notResponding
    case offline

    var label: String {
        switch self {
        case .connecting: return "Connecting"
        case .online: return "Online"
        case .retrying: return "Retrying"
        case .deviceMissing: return "Device missing"
        case .ownedElsewhere: return "Owned by another process"
        case .notResponding: return "Communication paused — safe retry available"
        case .offline: return "Offline"
        }
    }

    var requiresPowerCycle: Bool { false }
}

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
    @Published private(set) var connectionHealth: ChangerConnectionHealth = .offline
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var nextReconnectAt: Date?
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
                // State transitions and disconnects are not proof that the
                // physical drive is empty.  Clear the recovery marker only at
                // call sites that have verified the return with both the
                // changer inventory and the optical-media view.
                break
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
    @Published private(set) var operationNotice: String?

    var isHardwareBusy: Bool {
        currentOperation != nil || batchState?.isRunning == true
    }

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
    @Published private(set) var carouselBatchSnapshot: CarouselBatchSnapshot?
    private var carouselBatchOperation: CarouselBatchOperation?

    // Settings
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []
    private var reconnectWorkItem: DispatchWorkItem?
    private var hardwareWatchdog: DispatchSourceTimer?
    private var presenceCheckInFlight = false
    private var lastHardwarePresence: Bool?

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
        case batchLoading
        case batchImaging
        case batchScanning
        case bulkImport
        case bulkExport
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
            self.changerService = ProcessChangerService()
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
            startHardwareWatchdog()
        }
    }

    // MARK: - Connection

    func connect() {
        attemptConnection(resetRetryBudget: true)
    }

    private func attemptConnection(resetRetryBudget: Bool) {
        guard !isConnected else { return }
        guard currentOperation == nil else { return }

        if resetRetryBudget {
            reconnectAttempt = 0
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            nextReconnectAt = nil
        }

        currentOperation = .connecting
        connectionHealth = reconnectAttempt == 0 ? .connecting : .retrying
        operationStatusText = "Connecting to changer..."
        connectionError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                try self.changerService.connect()

                // Identification comes from IORegistry and is optional. The
                // element-map read in connect() and the inventory read below
                // are the authoritative connectivity checks.
                let info: ChangerService.ChangerDeviceInfo?
                do {
                    info = try self.changerService.getDeviceInfo()
                } catch {
                    info = nil
                    os_log(
                        "Changer identity lookup failed after a successful element-map read; validating with inventory: %{public}@",
                        log: Self.log,
                        type: .info,
                        error.localizedDescription
                    )
                }

                // Load initial inventory and hydrate catalog cache once.
                if let inventoryError = self.doRefreshInventory(
                    includeCatalogHydration: true,
                    publishConnectionFailure: false
                ) {
                    throw inventoryError
                }

                DispatchQueue.main.async {
                    self.deviceVendor = info?.vendor ?? "Sony"
                    self.deviceProduct = info?.product ?? "VAIOChanger1"
                    NotificationCenter.default.post(name: NSNotification.Name("DeviceInfoChanged"), object: nil)
                    self.isConnected = true
                    self.connectionHealth = .online
                    self.connectionError = nil
                    self.reconnectAttempt = 0
                    self.nextReconnectAt = nil
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                self.changerService.disconnect()
                DispatchQueue.main.async {
                    self.connectionError = error
                    self.currentOperation = nil
                    self.isConnected = false
                    self.scheduleReconnect(after: error)
                }
            } catch {
                self.changerService.disconnect()
                DispatchQueue.main.async {
                    self.connectionError = .unknown(error.localizedDescription)
                    self.currentOperation = nil
                    self.isConnected = false
                    self.scheduleReconnect(after: .unknown(error.localizedDescription))
                }
            }
        }
    }

    private func scheduleReconnect(after error: ChangerError) {
        reconnectWorkItem?.cancel()
        let delays: [TimeInterval]
        switch error {
        case .notResponding:
            connectionHealth = .notResponding
            // Reopen the SCSI user client once after a cooldown. Repeated
            // commands against a sick FireWire session can wedge this Sony,
            // so further attempts require a device reattach or an explicit
            // user retry.
            delays = [5]
        case .ownedElsewhere:
            connectionHealth = .ownedElsewhere
            delays = [5, 15, 30]
        case .deviceNotFound:
            connectionHealth = .deviceMissing
            // Presence watchdog reconnects immediately when FireWire reports
            // a remove/add transition; these retries cover missed events.
            delays = [2, 5, 15, 30, 60]
        default:
            connectionHealth = .offline
            delays = [2, 5, 15]
        }

        guard reconnectAttempt < delays.count else {
            nextReconnectAt = nil
            return
        }
        let delay = delays[reconnectAttempt]
        reconnectAttempt += 1
        nextReconnectAt = Date().addingTimeInterval(delay)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.reconnectWorkItem = nil
            self.nextReconnectAt = nil
            self.attemptConnection(resetRetryBudget: false)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Keep the UI's connection state aligned with the service handle. Slot
    /// and drive state are intentionally preserved so a loaded disc remains
    /// recoverable after a transport failure.
    private func applyChangerError(_ error: ChangerError) {
        connectionError = error
        guard error.isTransportUnavailable || !changerService.isConnected else { return }

        isConnected = false
        switch error {
        case .notResponding:
            connectionHealth = .notResponding
        case .deviceNotFound:
            connectionHealth = .deviceMissing
        default:
            connectionHealth = .offline
        }
        scheduleReconnect(after: error)
    }

    private func startHardwareWatchdog() {
        guard hardwareWatchdog == nil, mockState == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkHardwarePresence() }
        hardwareWatchdog = timer
        timer.resume()
    }

    private func checkHardwarePresence() {
        guard !presenceCheckInFlight, currentOperation != .connecting, mockState == nil else { return }
        presenceCheckInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let present = ChangerService.isChangerPresent()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.presenceCheckInFlight = false
                let previous = self.lastHardwarePresence
                self.lastHardwarePresence = present
                if !present {
                    self.reconnectWorkItem?.cancel()
                    self.reconnectWorkItem = nil
                    self.nextReconnectAt = nil
                    if self.isConnected {
                        self.disconnect(resultingHealth: .deviceMissing)
                    } else {
                        self.connectionHealth = .deviceMissing
                    }
                    return
                }
                if previous == false, !self.isConnected, self.currentOperation == nil {
                    self.attemptConnection(resetRetryBudget: true)
                }
            }
        }
    }

    func disconnect(resultingHealth: ChangerConnectionHealth = .offline) {
        changerService.disconnect()
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.connectionHealth = resultingHealth
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
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        nextReconnectAt = nil
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
            hardwareWatchdog?.cancel()
            hardwareWatchdog = nil
            let state = MockChangerState()
            mockState = state
            changerService = MockChangerService(state: state)
            mountService = MockMountService(state: state)
            imagingService = MockImagingService()
        } else {
            mockState = nil
            changerService = ProcessChangerService()
            mountService = MountService()
            imagingService = ImagingService()
            lastHardwarePresence = nil
            startHardwareWatchdog()
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
            guard let recoverySlot = Self.checkDirtyFlag() else {
                // Ignore a stale IOMedia node after the changer has already
                // verified and recorded a physical return.
                return
            }
            driveStatus = .loaded(sourceSlot: recoverySlot, mountPoint: mountPoint)
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

    /// Ask the changer to perform a physical element scan, then read the
    /// resulting inventory. This is intentionally separate from the fast
    /// refresh because a 200-disc carousel can take several minutes.
    func rescanElementStatus() {
        guard isConnected else { return }
        guard currentOperation == nil else { return }
        guard batchState?.isRunning != true else { return }

        currentOperation = .refreshing
        operationStatusText = "Rescanning changer inventory..."
        operationNotice = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let finalStatus: String
            do {
                try self.changerService.initializeElementStatus()
                if let refreshError = self.doRefreshInventory() {
                    throw refreshError
                }
                finalStatus = "Full inventory rescan complete"
            } catch let error as ChangerError {
                finalStatus = "Full inventory rescan failed: \(error.localizedDescription)"
                DispatchQueue.main.async {
                    self.applyChangerError(error)
                }
            } catch {
                finalStatus = "Full inventory rescan failed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.operationStatusText = finalStatus
                self.operationNotice = finalStatus
                self.currentOperation = nil
            }
        }
    }

    /// Internal refresh - must be called from background thread
    @discardableResult
    private func doRefreshInventory(
        includeCatalogHydration: Bool = false,
        publishConnectionFailure: Bool = true
    ) -> ChangerError? {
        do {
            let inventory = try self.changerService.getInventoryStatus()
            var newSlots = inventory.slots
            let sourceSlotFromSCSI = inventory.drive.sourceSlot
            let recoverySourceSlot = Self.checkDirtyFlag()

            // Use DiskArbitration to detect if disc is present (more reliable)
            let discPresent = self.mountService.isDiscPresent()
            let bsdName = self.mountService.findDiscBSDName()
            let sourceSlotStillFull: Bool = {
                guard let source = sourceSlotFromSCSI,
                      source > 0,
                      source <= newSlots.count else { return false }
                return newSlots[source - 1].isFull
            }()
            let contradictoryDriveFull = inventory.drive.hasDisc
                && sourceSlotStillFull
                && !discPresent
            let changerDriveHasDisc = inventory.drive.hasDisc && !contradictoryDriveFull
            if contradictoryDriveFull {
                os_log(
                    "Ignoring stale changer drive-full bit: source slot is full and optical drive has no media",
                    log: Self.log,
                    type: .info
                )
            }

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
                self.connectionError = nil
                if self.isConnected {
                    self.connectionHealth = .online
                }
                self.slots = newSlots

                let shouldTreatDriveAsLoaded = changerDriveHasDisc || recoverySourceSlot != nil
                if shouldTreatDriveAsLoaded {
                    // Changer inventory owns physical state. Disk Arbitration
                    // supplies optional BSD/mount metadata and may lag a move.
                    self.currentBSDName = bsdName
                    let mountPoint = bsdName.flatMap {
                        self.mountService.getMountPoint(bsdName: $0)
                    }

                    // Use SCSI source slot if available, otherwise preserve existing sourceSlot
                    // (VGP-XL1B doesn't return drive element data, so we must remember it)
                    let sourceSlot: Int
                    if let scsiSlot = sourceSlotFromSCSI {
                        sourceSlot = scsiSlot
                    } else if let existing = existingSourceSlot, existing > 0 {
                        sourceSlot = existing
                    } else if let recovered = recoverySourceSlot, recovered > 0 {
                        sourceSlot = recovered
                    } else {
                        sourceSlot = 0  // Unknown
                    }

                    self.driveStatus = .loaded(sourceSlot: sourceSlot, mountPoint: mountPoint)

                    // Mark slot as in drive if we know the source
                    if sourceSlot > 0 && sourceSlot <= self.slots.count {
                        self.slots[sourceSlot - 1].isFull = false
                        self.slots[sourceSlot - 1].isInDrive = true
                    }
                } else {
                    // The changer reports an empty physical drive and there is
                    // no outstanding recovery record. Ignore stale IOMedia.
                    Self.clearDirtyFlag()
                    self.driveStatus = .empty
                    self.currentBSDName = nil
                }
            }
            return nil

        } catch let error as ChangerError {
            if publishConnectionFailure {
                DispatchQueue.main.async {
                    self.applyChangerError(error)
                }
            }
            return error
        } catch {
            let wrapped = ChangerError.unknown(error.localizedDescription)
            DispatchQueue.main.async {
                self.connectionError = wrapped
            }
            return wrapped
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
        guard !isHardwareBusy else { return }

        let unknownSlots = slots.filter { $0.isFull && !$0.isInDrive && $0.discType == .unscanned }
        guard !unknownSlots.isEmpty else {
            operationStatusText = "No unknown discs to scan"
            return
        }

        let state = BatchOperationState()
        batchState = state
        currentOperation = .batchScanning
        operationStatusText = "Scanning unknown discs..."

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
                    Self.clearDirtyFlag()
                }
            },
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    self?.currentOperation = nil
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.refreshCatalogCache(forSlotIds: scannedSlotIds)
                }
                DispatchQueue.main.async {
                    self?.refreshInventory()
                }
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
                    self.applyChangerError(error)
                    self.currentOperation = nil

                    // If drive is not empty, update our state and refresh
                    if case .driveNotEmpty = error {
                        // We thought drive was empty but it's not - refresh to sync state
                        self.driveStatus = .loaded(sourceSlot: 0, mountPoint: nil)
                    } else {
                        self.driveStatus = .error(error.localizedDescription)
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
                if let bsd = self.currentBSDName {
                    if self.mountService.isMounted(bsdName: bsd) {
                        DispatchQueue.main.async {
                            self.operationStatusText = "Unmounting disc..."
                        }
                        try self.mountService.unmountDisc(bsdName: bsd, force: true)
                    }

                    DispatchQueue.main.async {
                        self.operationStatusText = "Releasing disc from drive..."
                    }
                    try self.mountService.ejectDisc(bsdName: bsd, force: true)
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
                    Self.clearDirtyFlag()
                    self.currentOperation = nil
                    completion?()
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.applyChangerError(error)
                    self.driveStatus = .error(error.localizedDescription)
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
                    self.applyChangerError(error)
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
                    self.applyChangerError(error)
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

                if self.mountService.isMounted(bsdName: bsdName) {
                    try self.mountService.unmountDisc(bsdName: bsdName, force: true)
                }

                DispatchQueue.main.async {
                    self.operationStatusText = "Releasing disc from drive..."
                }
                try self.mountService.ejectDisc(bsdName: bsdName, force: true)

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
                    Self.clearDirtyFlag()
                    self.currentOperation = nil
                }

            } catch let error as ChangerError {
                DispatchQueue.main.async {
                    self.applyChangerError(error)
                    self.driveStatus = .error(error.localizedDescription)
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
                    self.applyChangerError(error)
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
                    self.applyChangerError(error)
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
                    self.applyChangerError(error)
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

    // MARK: - Software-driven carousel loading and unloading

    @discardableResult
    func startCarouselLoad(targetSlots: [Int]) -> Bool {
        beginCarouselBatch(mode: .load, targets: targetSlots)
    }

    @discardableResult
    func startCarouselUnload(targetSlots: [Int]) -> Bool {
        beginCarouselBatch(mode: .unload, targets: targetSlots)
    }

    private func beginCarouselBatch(mode: CarouselBatchMode, targets: [Int]) -> Bool {
        guard isConnected, currentOperation == nil, batchState?.isRunning != true,
              hasIESlot, driveStatus == .empty else { return false }

        let uniqueTargets = Array(Set(targets)).sorted()
        guard !uniqueTargets.isEmpty,
              uniqueTargets.allSatisfy({ $0 > 0 && $0 <= slots.count }) else { return false }
        let statesAreValid = uniqueTargets.allSatisfy { slot in
            let full = slots[slot - 1].isFull || slots[slot - 1].isInDrive
            return mode == .load ? !full : full && !slots[slot - 1].isInDrive
        }
        guard statesAreValid else { return false }

        currentOperation = mode == .load ? .bulkImport : .bulkExport
        operationStatusText = mode == .load ? "Preparing bulk load…" : "Preparing bulk unload…"
        operationNotice = nil
        unloadAllInProgress = mode == .unload
        unloadAllQueue = uniqueTargets
        unloadAllTotal = uniqueTargets.count
        unloadAllCompleted = 0

        let operation = CarouselBatchOperation(
            mode: mode,
            targets: uniqueTargets,
            service: changerService,
            onSnapshot: { [weak self] snapshot in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.carouselBatchSnapshot = snapshot
                    self.operationStatusText = snapshot.status
                    self.unloadAllCompleted = snapshot.completedSlots.count
                    self.unloadAllQueue = uniqueTargets.filter {
                        !snapshot.completedSlots.contains($0) && !snapshot.skippedSlots.contains($0)
                    }
                    self.objectWillChange.send()
                }
            },
            onSlotState: { [weak self] slot, full in
                DispatchQueue.main.async {
                    guard let self = self, slot > 0, slot <= self.slots.count else { return }
                    self.slots[slot - 1].isFull = full
                    self.slots[slot - 1].isInDrive = false
                    if !full {
                        self.slots[slot - 1].discType = .unscanned
                        self.slots[slot - 1].volumeLabel = nil
                    }
                    if mode == .unload { self.publishCarouselAnimation(.ejectFromChamber(slot)) }
                }
            },
            onFinished: { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.unloadAllInProgress = false
                    self.currentOperation = nil
                    self.carouselBatchOperation = nil
                    self.operationNotice = self.carouselBatchSnapshot?.status
                    self.refreshInventory()
                }
            }
        )
        carouselBatchOperation = operation
        carouselBatchSnapshot = operation.snapshot()
        operation.start()
        return true
    }

    @discardableResult
    func controlCarouselBatch(_ action: CarouselBatchAction) -> Bool {
        if action == .continueAfterRemoval { mockState?.clearIESlot() }
        return carouselBatchOperation?.perform(action) ?? false
    }

    /// Compatibility entry points used by the Catalina desktop UI.
    func startUnloadAll() {
        _ = startCarouselUnload(targetSlots: slots.filter { $0.isFull && !$0.isInDrive }.map(\.id))
    }

    func cancelUnloadAll() {
        _ = controlCarouselBatch(.cancel)
    }

    func continueUnloadAll() {
        _ = controlCarouselBatch(.continueAfterRemoval)
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
        _ = startCarouselLoad(targetSlots: slots.filter { !$0.isFull && !$0.isInDrive }.map(\.id))
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
    func startBatchImaging(
        outputDirectory: URL,
        duplicatePolicy: DuplicatePolicy = .skipExisting
    ) {
        guard isConnected else { return }
        guard !isHardwareBusy else { return }
        guard !selectedSlotsForRip.isEmpty else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: outputDirectory.path) else {
            connectionError = .imagingFailed("The selected output folder is unavailable or not writable")
            return
        }

        let slotsToRip = slots.filter { selectedSlotsForRip.contains($0.id) && ($0.isFull || $0.isInDrive) }
        guard !slotsToRip.isEmpty else { return }
        let slotIdsToRip = slotsToRip.map(\.id)
        let driveWasReconciledEmpty: Bool = {
            guard Self.checkDirtyFlag() == nil else { return false }
            if case .empty = driveStatus { return true }
            return false
        }()

        let state = BatchOperationState()
        batchState = state
        currentOperation = .batchImaging
        operationStatusText = "Preparing rip queue..."

        state.runImageAll(
            slots: slotsToRip,
            outputDirectory: outputDirectory,
            duplicatePolicy: duplicatePolicy,
            driveFallbackSourceSlot: slots.first(where: { $0.isInDrive })?.id,
            ignoreUntrackedDriveFull: driveWasReconciledEmpty,
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
                    Self.clearDirtyFlag()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.refreshCatalogCache(forSlotIds: [slot])
                }
            },
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.currentOperation = nil
                    self.selectedSlotsForRip.removeAll()
                    if self.changerService.isConnected {
                        self.refreshInventory()
                    } else {
                        self.applyChangerError(.notResponding)
                    }
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.refreshCatalogCache(forSlotIds: slotIdsToRip)
                }
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
        let snapshot: (DriveStatus, String?) = {
            if Thread.isMainThread { return (driveStatus, currentBSDName) }
            return DispatchQueue.main.sync { (driveStatus, currentBSDName) }
        }()

        let sourceSlot = snapshot.0.sourceSlot ?? Self.checkDirtyFlag() ?? 0
        if sourceSlot <= 0 {
            return !mountService.isDiscPresent()
        }
        guard sourceSlot > 0 else { return false }

        do {
            if let bsd = snapshot.1 {
                if mountService.isMounted(bsdName: bsd) {
                    try mountService.unmountDisc(bsdName: bsd, force: true)
                }
                try mountService.ejectDisc(bsdName: bsd, force: true)
            }

            try changerService.ejectToSlot(sourceSlot)
            for _ in 0..<40 {
                if let status = try? changerService.getDriveStatus(), !status.hasDisc {
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            guard let status = try? changerService.getDriveStatus(), !status.hasDisc else {
                return false
            }
            Self.clearDirtyFlag()
            DispatchQueue.main.async {
                self.currentBSDName = nil
                self.driveStatus = .empty
                if sourceSlot <= self.slots.count {
                    self.slots[sourceSlot - 1].isFull = true
                    self.slots[sourceSlot - 1].isInDrive = false
                }
            }
            return true
        } catch {
            print("emergencyEjectSync failed: \(error)")
            return false
        }
    }

    deinit {
        reconnectWorkItem?.cancel()
        hardwareWatchdog?.cancel()
        driveMediaObserver.stop()
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
