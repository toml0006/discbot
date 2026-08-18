//
//  ChangerService.swift
//  Discbot
//
//  Service for communicating with the DVD changer using mchanger library
//

import Foundation
import Darwin

/// Thread-safe service for communicating with the DVD changer
final class ChangerService {
    private var handle: OpaquePointer?
    private var elementMap: MChangerElementMap?
    private let lock = NSLock()

    struct ChangerDeviceInfo {
        let vendor: String
        let product: String
        let revision: String
    }

    struct DriveElementStatus {
        let isSupported: Bool
        let hasDisc: Bool
        let sourceSlot: Int?
    }

    struct InventoryStatus {
        let slots: [Slot]
        let drive: DriveElementStatus
    }

    enum ReturnDiscState: Equatable {
        case complete
        case safeToMove
        case unsafe
    }

    static func returnDiscState(driveHasDisc: Bool, destinationFull: Bool) -> ReturnDiscState {
        switch (driveHasDisc, destinationFull) {
        case (false, true): return .complete
        case (true, false): return .safeToMove
        default: return .unsafe
        }
    }

    /// Connect to the DVD changer (blocking)
    func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        if handle != nil {
            return // Already connected
        }

        try connectLocked()
    }

    /// Open and validate a new changer session. The caller must hold `lock`.
    private func connectLocked() throws {
        guard handle == nil else { return }

        // This Sony model can return CHECK CONDITION / NO SENSE for TEST UNIT
        // READY while READ ELEMENT STATUS continues to work. Skip TUR here and
        // use the element-map read below as the authoritative readiness check.
        guard let h = mchanger_open_ex(nil, false, true) else {
            switch mchanger_last_connect_error() {
            case MCHANGER_CONNECT_ERROR_NOT_FOUND:
                throw ChangerError.deviceNotFound
            case MCHANGER_CONNECT_ERROR_OWNED_ELSEWHERE:
                throw ChangerError.ownedElsewhere
            case MCHANGER_CONNECT_ERROR_NOT_RESPONDING:
                throw ChangerError.notResponding
            default:
                throw ChangerError.connectionFailed
            }
        }

        handle = h

        // A failed initial map read must not leave a half-connected handle that
        // causes all future reconnect attempts to return early.
        do {
            try loadElementMapLocked()
        } catch {
            mchanger_close(h)
            handle = nil
            throw error
        }
    }

    /// Close the current user client and discard cached element addresses.
    /// The caller must hold `lock`.
    private func disconnectLocked() {
        if let h = handle {
            mchanger_close(h)
            handle = nil
        }

        if var map = elementMap {
            mchanger_free_element_map(&map)
            elementMap = nil
        }
    }

    /// Reopening the SCSI user client is the only safe recovery after this
    /// bridge stops responding. Never keep issuing commands on the old handle.
    /// Catalina can take several seconds to retire the previous user client;
    /// reopening immediately returns kIOReturnNoResources and strands a disc.
    private func reconnectLocked() throws {
        disconnectLocked()
        let cooldowns: [TimeInterval] = [2, 5, 10]
        var lastError: Error = ChangerError.connectionFailed

        for cooldown in cooldowns {
            Thread.sleep(forTimeInterval: cooldown)
            do {
                try connectLocked()
                return
            } catch {
                lastError = error
                disconnectLocked()
            }
        }

        throw lastError
    }

    /// Disconnect from the changer
    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        disconnectLocked()
    }

    /// Get device info via INQUIRY (blocking)
    func getDeviceInfo() throws -> ChangerDeviceInfo {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }

        var vendor = [CChar](repeating: 0, count: 64)
        var product = [CChar](repeating: 0, count: 64)
        var revision = [CChar](repeating: 0, count: 64)

        // Device identity is already present in IORegistry. Do not send SCSI
        // INQUIRY: this Sony bridge can reject that otherwise optional probe
        // and stop responding to subsequent commands.
        let result = mchanger_get_registry_identity(h, &vendor, 64, &product, 64, &revision, 64)

        if result != MCHANGER_OK {
            throw ChangerError.commandFailed("IORegistry device identity")
        }

        return ChangerDeviceInfo(
            vendor: String(cString: vendor).trimmingCharacters(in: .whitespaces),
            product: String(cString: product).trimmingCharacters(in: .whitespaces),
            revision: String(cString: revision).trimmingCharacters(in: .whitespaces)
        )
    }

    /// Load element map (must hold lock)
    private func loadElementMapLocked() throws {
        guard let h = handle else {
            throw ChangerError.notConnected
        }

        // Free existing map if any
        if var map = elementMap {
            mchanger_free_element_map(&map)
            elementMap = nil
        }

        var map = MChangerElementMap()
        let result = mchanger_get_element_map(h, &map)

        if result != MCHANGER_OK {
            if mchanger_last_command_was_not_responding() {
                throw ChangerError.notResponding
            }
            throw ChangerError.commandFailed("GET ELEMENT MAP")
        }

        elementMap = map

        print("Element map loaded: \(map.slot_count) slots, \(map.drive_count) drives, \(map.ie_count) I/E slots")
    }

    /// Get status of all slots (blocking)
    func getSlotStatus() throws -> [Slot] {
        lock.lock()
        defer { lock.unlock() }

        return try getInventoryStatusLocked().slots
    }

    /// Get drive status (blocking)
    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?) {
        lock.lock()
        defer { lock.unlock() }

        let status = try getInventoryStatusLocked()
        return (status.drive.hasDisc, status.drive.sourceSlot)
    }

    /// Get inventory (slot + optional drive element status) in a single SCSI READ ELEMENT STATUS call.
    func getInventoryStatus() throws -> InventoryStatus {
        lock.lock()
        defer { lock.unlock() }
        return try getInventoryStatusLocked()
    }

    /// Internal helper - must be called with lock held.
    private func getInventoryStatusLocked() throws -> InventoryStatus {
        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard let slotAddrs = map.slot_addrs else {
            throw ChangerError.commandFailed("No slot addresses")
        }

        var slotStatuses: [MChangerElementStatus] = Array(
            repeating: MChangerElementStatus(),
            count: Int(map.slot_count)
        )

        let driveAddr: UInt16 = {
            guard map.drive_count > 0, let driveAddrs = map.drive_addrs else { return 0 }
            return driveAddrs[0]
        }()

        var driveStatus = MChangerElementStatus()
        var driveSupported = false

        let result = mchanger_get_bulk_status(
            h,
            slotAddrs,
            map.slot_count,
            driveAddr,
            &driveStatus,
            &slotStatuses,
            &driveSupported
        )

        if result != MCHANGER_OK {
            if mchanger_last_command_was_not_responding() {
                disconnectLocked()
                throw ChangerError.notResponding
            }
            throw ChangerError.commandFailed("READ ELEMENT STATUS (bulk)")
        }

        var slots: [Slot] = []
        slots.reserveCapacity(Int(map.slot_count))
        for i in 0..<Int(map.slot_count) {
            let slotNumber = i + 1
            let st = slotStatuses[i]
            slots.append(Slot(
                id: slotNumber,
                address: st.address,
                isFull: st.full,
                isInDrive: false,
                hasException: st.except
            ))
        }

        // Map drive source address back to a 1-based slot index when available.
        var sourceSlot: Int? = nil
        if driveSupported && driveStatus.valid_source {
            for i in 0..<Int(map.slot_count) {
                if slotAddrs[i] == driveStatus.source_addr {
                    sourceSlot = i + 1
                    break
                }
            }
        }

        let drive = DriveElementStatus(
            isSupported: driveSupported && driveAddr != 0,
            hasDisc: driveSupported && driveStatus.full,
            sourceSlot: sourceSlot
        )

        return InventoryStatus(slots: slots, drive: drive)
    }

    /// Load disc from slot to drive (blocking, takes 60-120 seconds)
    func loadSlot(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard slotNumber >= 1 && slotNumber <= map.slot_count else {
            throw ChangerError.slotEmpty(slotNumber)
        }

        print("Loading slot \(slotNumber) into drive")
        let result = mchanger_load_slot(h, Int32(slotNumber), 1)

        switch result {
        case MCHANGER_OK:
            return
        case MCHANGER_ERR_EMPTY:
            throw ChangerError.slotEmpty(slotNumber)
        case MCHANGER_ERR_BUSY:
            throw ChangerError.driveNotEmpty
        default:
            if mchanger_last_command_was_not_responding() {
                disconnectLocked()
                throw ChangerError.notResponding
            }
            throw ChangerError.moveFailed("mchanger_load_slot returned \(result)")
        }
    }

    /// Eject disc from drive to slot (blocking, takes 60-120 seconds)
    func ejectToSlot(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard slotNumber >= 1 && slotNumber <= map.slot_count else {
            throw ChangerError.slotOccupied(slotNumber)
        }

        print("Unloading drive to slot \(slotNumber)")
        let result = mchanger_unload_drive(h, Int32(slotNumber), 1)

        if result == MCHANGER_OK {
            do {
                if try waitForCompletedReturnLocked(slotNumber: slotNumber) { return }
            } catch {
                // Reconcile below using a fresh user client. A successful MOVE
                // followed by a failed status read is still ambiguous.
            }
        }

        let originalWasUnresponsive = mchanger_last_command_was_not_responding()
        do {
            try reconcileReturnLocked(slotNumber: slotNumber, allowSafeRetry: true)
        } catch let error as ChangerError {
            if originalWasUnresponsive, error == .connectionFailed {
                throw ChangerError.notResponding
            }
            throw error
        }
    }

    /// Execute exactly one drive-to-slot command without attempting to reopen
    /// the SCSI user client. The process-backed coordinator uses this entry
    /// point, then exits the helper and verifies the result from a fresh
    /// process before deciding whether a retry is safe.
    func ejectToSlotOnce(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard slotNumber >= 1 && slotNumber <= map.slot_count else {
            throw ChangerError.slotOccupied(slotNumber)
        }

        print("Unloading drive to slot \(slotNumber) (single-session helper)")
        let result = mchanger_unload_drive(h, Int32(slotNumber), 1)
        guard result == MCHANGER_OK else {
            if mchanger_last_command_was_not_responding() {
                throw ChangerError.notResponding
            }
            throw ChangerError.moveFailed("mchanger_unload_drive returned \(result)")
        }
    }

    /// Reopen the FireWire/SCSI session and use authoritative element state to
    /// resolve an ambiguous return. MOVE MEDIUM is replayed at most once, and
    /// only when the drive is full while the requested slot is empty.
    private func reconcileReturnLocked(slotNumber: Int, allowSafeRetry: Bool) throws {
        do {
            try reconnectLocked()
        } catch {
            disconnectLocked()
            if let changerError = error as? ChangerError { throw changerError }
            throw ChangerError.connectionFailed
        }

        let decision = try returnDecisionLocked(slotNumber: slotNumber)
        switch decision {
        case .complete:
            return
        case .unsafe:
            throw ChangerError.moveFailed(
                "Return state is ambiguous: drive and slot inventory disagree"
            )
        case .safeToMove:
            guard allowSafeRetry, let h = handle else {
                throw ChangerError.moveFailed(
                    "Disc remains in the drive after the verified retry"
                )
            }

            let retryResult = mchanger_unload_drive(h, Int32(slotNumber), 1)
            if retryResult == MCHANGER_OK {
                do {
                    if try waitForCompletedReturnLocked(slotNumber: slotNumber) { return }
                } catch {
                    // A fresh read below resolves whether the command completed.
                }
            }

            let retryWasUnresponsive = mchanger_last_command_was_not_responding()
            do {
                try reconcileReturnLocked(slotNumber: slotNumber, allowSafeRetry: false)
            } catch {
                if retryWasUnresponsive {
                    disconnectLocked()
                    throw ChangerError.notResponding
                }
                throw error
            }
        }
    }

    private func returnDecisionLocked(slotNumber: Int) throws -> ReturnDiscState {
        let inventory = try getInventoryStatusLocked()
        guard slotNumber >= 1, slotNumber <= inventory.slots.count else {
            throw ChangerError.slotOccupied(slotNumber)
        }
        return Self.returnDiscState(
            driveHasDisc: inventory.drive.hasDisc,
            destinationFull: inventory.slots[slotNumber - 1].isFull
        )
    }

    private func waitForCompletedReturnLocked(slotNumber: Int) throws -> Bool {
        for _ in 0..<40 {
            switch try returnDecisionLocked(slotNumber: slotNumber) {
            case .complete: return true
            case .unsafe:
                throw ChangerError.moveFailed(
                    "Return state is ambiguous: drive and slot inventory disagree"
                )
            case .safeToMove:
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        return false
    }

    /// Initialize element status (full inventory scan, blocking, takes several minutes)
    func initializeElementStatus() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }

        let result = mchanger_initialize_element_status(h)
        guard result == MCHANGER_OK else {
            if mchanger_last_command_was_not_responding() {
                disconnectLocked()
                throw ChangerError.notResponding
            }
            throw ChangerError.commandFailed("INITIALIZE ELEMENT STATUS")
        }

        // The C layer invalidates its cached map after a successful scan.
        try loadElementMapLocked()
    }

    /// Eject disc to I/E slot for physical removal (blocking)
    func unloadToIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard map.ie_count > 0 else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard slotNumber >= 1 && slotNumber <= map.slot_count else {
            throw ChangerError.slotEmpty(slotNumber)
        }

        print("Exporting slot \(slotNumber) to the I/E gate")
        let result = mchanger_export_slot(h, Int32(slotNumber))

        switch result {
        case MCHANGER_OK:
            return
        case MCHANGER_ERR_EMPTY:
            throw ChangerError.slotEmpty(slotNumber)
        case MCHANGER_ERR_BUSY:
            throw ChangerError.commandFailed("Remove the disc already presented at the gate")
        case MCHANGER_ERR_TIMEOUT:
            throw ChangerError.timeout
        default:
            if mchanger_last_command_was_not_responding() {
                disconnectLocked()
                throw ChangerError.notResponding
            }
            throw ChangerError.moveFailed("mchanger_eject returned \(result)")
        }
    }

    /// Import disc from I/E slot to specified slot (blocking)
    func importFromIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard map.ie_count > 0 else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard slotNumber >= 1 && slotNumber <= map.slot_count else {
            throw ChangerError.slotOccupied(slotNumber)
        }
        guard map.transport_count > 0 else {
            throw ChangerError.commandFailed("No transport element")
        }

        print("Importing one disc from the I/E gate to slot \(slotNumber)")
        let result = mchanger_import_slot(h, Int32(slotNumber))

        if result != MCHANGER_OK {
            if mchanger_last_command_was_not_responding() {
                disconnectLocked()
                throw ChangerError.notResponding
            }
            if result == MCHANGER_ERR_BUSY {
                throw ChangerError.slotOccupied(slotNumber)
            }
            if result == MCHANGER_ERR_TIMEOUT {
                throw ChangerError.timeout
            }
            throw ChangerError.moveFailed("mchanger_import_slot returned \(result)")
        }
    }

    /// Load disc from I/E slot directly to drive (blocking)
    func loadFromIE() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard map.ie_count > 0, let ieAddrs = map.ie_addrs else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard let driveAddrs = map.drive_addrs, map.drive_count > 0 else {
            throw ChangerError.commandFailed("No drive element")
        }
        guard let transportAddrs = map.transport_addrs, map.transport_count > 0 else {
            throw ChangerError.commandFailed("No transport element")
        }

        let driveAddr = driveAddrs[0]
        let ieAddr = ieAddrs[0]
        let transport = transportAddrs[0]

        print("MOVE MEDIUM (load from I/E): transport=\(transport), source=\(ieAddr), dest=\(driveAddr)")
        let result = mchanger_move_medium(h, transport, ieAddr, driveAddr)

        if result != MCHANGER_OK {
            if mchanger_last_command_was_not_responding() {
                disconnectLocked()
                throw ChangerError.notResponding
            }
            if result == MCHANGER_ERR_EMPTY {
                throw ChangerError.commandFailed("I/E slot is empty")
            }
            if result == MCHANGER_ERR_BUSY {
                throw ChangerError.driveNotEmpty
            }
            throw ChangerError.moveFailed("mchanger_move_medium returned \(result)")
        }
    }

    /// Check if changer has an I/E slot
    var hasIESlot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (elementMap?.ie_count ?? 0) > 0
    }

    /// Get slot count
    var slotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(elementMap?.slot_count ?? 0)
    }

    /// Check if connected
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    static func isChangerPresent() -> Bool {
        var list: UnsafeMutablePointer<MChangerHandleInfo>?
        var count = 0
        let result = mchanger_list_changers(&list, &count)
        if let list = list { mchanger_free_changer_list(list) }
        return result == MCHANGER_OK && count > 0
    }
}

// MARK: - Process-isolated changer transport

private struct ChangerHelperSlot: Codable {
    let id: Int
    let address: UInt16
    let full: Bool
    let exception: Bool
}

private struct ChangerHelperDrive: Codable {
    let supported: Bool
    let hasDisc: Bool
    let sourceSlot: Int?
}

private struct ChangerHelperInventory: Codable {
    let slots: [ChangerHelperSlot]
    let drive: ChangerHelperDrive
}

private struct ChangerHelperDevice: Codable {
    let vendor: String
    let product: String
    let revision: String
}

private struct ChangerHelperResponse: Codable {
    var ok: Bool
    var errorCode: String? = nil
    var errorArgument: Int? = nil
    var message: String? = nil
    var device: ChangerHelperDevice? = nil
    var inventory: ChangerHelperInventory? = nil
    var hasIESlot: Bool? = nil
    var slotCount: Int? = nil
}

/// Entry point used by `--changer-helper`. Each invocation owns the FireWire
/// SCSI user client for one bounded command and then exits. This is deliberate:
/// on Catalina a CHECK CONDITION can poison that user client for the lifetime
/// of its process even after every public IOKit object has been released.
enum ChangerHelperRunner {
    private final class HardwareLock {
        private let descriptor: Int32

        init() throws {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Discbot", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let path = support.appendingPathComponent("changer-helper.lock").path
            let fd = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw ChangerError.connectionFailed }
            guard flock(fd, LOCK_EX) == 0 else {
                Darwin.close(fd)
                throw ChangerError.connectionFailed
            }
            descriptor = fd
        }

        deinit {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    static func run(arguments: [String]) -> Int32 {
        var response: ChangerHelperResponse
        do {
            guard let command = arguments.first else {
                throw ChangerError.commandFailed("Missing helper command")
            }
            let hardwareLock = try HardwareLock()
            defer { withExtendedLifetime(hardwareLock) {} }
            let service = ChangerService()
            try service.connect()
            defer { service.disconnect() }

            switch command {
            case "inventory":
                let info = try? service.getDeviceInfo()
                let inventory = try service.getInventoryStatus()
                response = ChangerHelperResponse(
                    ok: true,
                    device: info.map {
                        ChangerHelperDevice(vendor: $0.vendor, product: $0.product, revision: $0.revision)
                    },
                    inventory: helperInventory(inventory),
                    hasIESlot: service.hasIESlot,
                    slotCount: service.slotCount
                )
            case "load":
                try service.loadSlot(try slotArgument(arguments))
                response = ChangerHelperResponse(ok: true)
            case "unload":
                try service.ejectToSlotOnce(try slotArgument(arguments))
                response = ChangerHelperResponse(ok: true)
            case "unload-ie":
                try service.unloadToIE(try slotArgument(arguments))
                response = ChangerHelperResponse(ok: true)
            case "import-ie":
                try service.importFromIE(try slotArgument(arguments))
                response = ChangerHelperResponse(ok: true)
            case "load-ie":
                try service.loadFromIE()
                response = ChangerHelperResponse(ok: true)
            case "initialize":
                try service.initializeElementStatus()
                response = ChangerHelperResponse(ok: true)
            default:
                throw ChangerError.commandFailed("Unknown helper command: \(command)")
            }
        } catch let error as ChangerError {
            response = errorResponse(error)
        } catch {
            response = ChangerHelperResponse(
                ok: false,
                errorCode: "unknown",
                message: error.localizedDescription
            )
        }

        do {
            let data = try JSONEncoder().encode(response)
            FileHandle.standardOutput.write(Data("\n".utf8))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Changer helper could not encode its response\n".utf8))
            return 70
        }
    }

    private static func slotArgument(_ arguments: [String]) throws -> Int {
        guard arguments.count == 2, let slot = Int(arguments[1]), slot > 0 else {
            throw ChangerError.commandFailed("A positive slot number is required")
        }
        return slot
    }

    private static func helperInventory(_ inventory: ChangerService.InventoryStatus) -> ChangerHelperInventory {
        ChangerHelperInventory(
            slots: inventory.slots.map {
                ChangerHelperSlot(id: $0.id, address: $0.address, full: $0.isFull, exception: $0.hasException)
            },
            drive: ChangerHelperDrive(
                supported: inventory.drive.isSupported,
                hasDisc: inventory.drive.hasDisc,
                sourceSlot: inventory.drive.sourceSlot
            )
        )
    }

    private static func errorResponse(_ error: ChangerError) -> ChangerHelperResponse {
        let code: String
        var argument: Int?
        let message: String
        switch error {
        case .connectionFailed: code = "connectionFailed"; message = error.localizedDescription
        case .ownedElsewhere: code = "ownedElsewhere"; message = error.localizedDescription
        case .notResponding: code = "notResponding"; message = error.localizedDescription
        case .notConnected: code = "notConnected"; message = error.localizedDescription
        case .deviceNotFound: code = "deviceNotFound"; message = error.localizedDescription
        case .commandFailed(let detail): code = "commandFailed"; message = detail
        case .moveFailed(let detail): code = "moveFailed"; message = detail
        case .slotEmpty(let slot): code = "slotEmpty"; argument = slot; message = error.localizedDescription
        case .slotOccupied(let slot): code = "slotOccupied"; argument = slot; message = error.localizedDescription
        case .driveNotEmpty: code = "driveNotEmpty"; message = error.localizedDescription
        case .driveEmpty: code = "driveEmpty"; message = error.localizedDescription
        case .mountFailed(let detail): code = "mountFailed"; message = detail
        case .unmountFailed(let detail): code = "unmountFailed"; message = detail
        case .timeout: code = "timeout"; message = error.localizedDescription
        case .cancelled: code = "cancelled"; message = error.localizedDescription
        case .imagingFailed(let detail): code = "imagingFailed"; message = detail
        case .metadataFailed(let detail): code = "metadataFailed"; message = detail
        case .unknown(let detail): code = "unknown"; message = detail
        }
        return ChangerHelperResponse(
            ok: false,
            errorCode: code,
            errorArgument: argument,
            message: message
        )
    }
}

/// Changer service used by the app and web server. It never opens an IOKit
/// changer handle in the long-lived parent process; every call is delegated to
/// the helper mode above and authoritative inventory is read by a new process.
final class ProcessChangerService: ChangerServicing {
    private enum LoadState {
        case complete
        case unchanged
        case unsafe
    }

    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private var connected = false
    private var cachedDevice: ChangerService.ChangerDeviceInfo?
    private var cachedHasIESlot = false
    private var cachedSlotCount = 0

    func connect() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let response = try readInventoryWithFreshProcess()
        updateState(from: response)
    }

    func disconnect() {
        stateLock.lock()
        connected = false
        stateLock.unlock()
    }

    func getDeviceInfo() throws -> ChangerService.ChangerDeviceInfo {
        stateLock.lock()
        let value = cachedDevice
        let isOnline = connected
        stateLock.unlock()
        guard isOnline else { throw ChangerError.notConnected }
        if let value = value { return value }

        operationLock.lock()
        defer { operationLock.unlock() }
        let response = try readInventoryWithFreshProcess()
        updateState(from: response)
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedDevice ?? ChangerService.ChangerDeviceInfo(
            vendor: "Sony",
            product: "VAIOChanger1",
            revision: ""
        )
    }

    func getSlotStatus() throws -> [Slot] {
        try getInventoryStatus().slots
    }

    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?) {
        let inventory = try getInventoryStatus()
        return (inventory.drive.hasDisc, inventory.drive.sourceSlot)
    }

    func getInventoryStatus() throws -> ChangerService.InventoryStatus {
        guard isConnected else { throw ChangerError.notConnected }
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            let response = try readInventoryWithFreshProcess()
            updateState(from: response)
            return try inventory(from: response)
        } catch {
            markDisconnectedIfNeeded(error)
            throw error
        }
    }

    func loadSlot(_ slotNumber: Int) throws {
        guard isConnected else { throw ChangerError.notConnected }
        operationLock.lock()
        defer { operationLock.unlock() }

        var lastCommandError: ChangerError?
        for attempt in 0..<2 {
            do {
                _ = try invoke(command: "load", slot: slotNumber, timeout: 100)
                lastCommandError = nil
            } catch let error as ChangerError {
                switch error {
                case .slotEmpty, .driveNotEmpty:
                    throw error
                default:
                    lastCommandError = error
                }
            }

            let response = try readInventoryWithFreshProcess()
            updateState(from: response)
            let current = try inventory(from: response)
            switch loadState(inventory: current, slotNumber: slotNumber) {
            case .complete:
                return
            case .unchanged where attempt == 0:
                continue
            case .unchanged:
                throw lastCommandError ?? ChangerError.moveFailed(
                    "Slot-to-drive move did not complete after a verified retry"
                )
            case .unsafe:
                throw ChangerError.moveFailed(
                    "Load state is ambiguous: drive and source-slot inventory disagree"
                )
            }
        }
    }

    func ejectToSlot(_ slotNumber: Int) throws {
        guard isConnected else { throw ChangerError.notConnected }
        operationLock.lock()
        defer { operationLock.unlock() }

        var lastCommandError: ChangerError?
        for attempt in 0..<2 {
            do {
                _ = try invoke(command: "unload", slot: slotNumber, timeout: 100)
                lastCommandError = nil
            } catch let error as ChangerError {
                lastCommandError = error
            }

            let response = try readInventoryWithFreshProcess()
            updateState(from: response)
            let current = try inventory(from: response)
            guard slotNumber >= 1, slotNumber <= current.slots.count else {
                throw ChangerError.slotOccupied(slotNumber)
            }
            switch ChangerService.returnDiscState(
                driveHasDisc: current.drive.hasDisc,
                destinationFull: current.slots[slotNumber - 1].isFull
            ) {
            case .complete:
                return
            case .safeToMove where attempt == 0:
                continue
            case .safeToMove:
                throw lastCommandError ?? ChangerError.moveFailed(
                    "Drive-to-slot move did not complete after a verified retry"
                )
            case .unsafe:
                throw ChangerError.moveFailed(
                    "Return state is ambiguous: drive and destination-slot inventory disagree"
                )
            }
        }
    }

    func unloadToIE(_ slotNumber: Int) throws {
        try runSingleMovement(command: "unload-ie", slot: slotNumber)
    }

    func importFromIE(_ slotNumber: Int) throws {
        try runSingleMovement(command: "import-ie", slot: slotNumber)
    }

    func loadFromIE() throws {
        try runSingleMovement(command: "load-ie", slot: nil)
    }

    func initializeElementStatus() throws {
        guard isConnected else { throw ChangerError.notConnected }
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            _ = try invoke(command: "initialize", timeout: 900)
            let response = try readInventoryWithFreshProcess()
            updateState(from: response)
        } catch {
            markDisconnectedIfNeeded(error)
            throw error
        }
    }

    var hasIESlot: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedHasIESlot
    }

    var slotCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedSlotCount
    }

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connected
    }

    private func runSingleMovement(command: String, slot: Int?) throws {
        guard isConnected else { throw ChangerError.notConnected }
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            _ = try invoke(command: command, slot: slot, timeout: 120)
            let response = try readInventoryWithFreshProcess()
            updateState(from: response)
        } catch {
            markDisconnectedIfNeeded(error)
            throw error
        }
    }

    private func loadState(
        inventory: ChangerService.InventoryStatus,
        slotNumber: Int
    ) -> LoadState {
        guard slotNumber >= 1, slotNumber <= inventory.slots.count else { return .unsafe }
        let sourceFull = inventory.slots[slotNumber - 1].isFull
        if inventory.drive.hasDisc, !sourceFull { return .complete }
        if !inventory.drive.hasDisc, sourceFull { return .unchanged }
        return .unsafe
    }

    private func readInventoryWithFreshProcess() throws -> ChangerHelperResponse {
        // One fresh-process retry is enough to distinguish Catalina retiring a
        // prior user client from a genuinely stalled bus. More retries only
        // hammer the same FireWire bridge and delay the circuit breaker.
        let cooldowns: [TimeInterval] = [0, 5]
        var lastError: ChangerError = .connectionFailed
        for cooldown in cooldowns {
            if cooldown > 0 { Thread.sleep(forTimeInterval: cooldown) }
            do {
                return try invoke(command: "inventory", timeout: 75)
            } catch let error as ChangerError {
                lastError = error
                guard Self.shouldRetryInventory(error) else { throw error }
            }
        }
        markDisconnectedIfNeeded(lastError)
        throw lastError
    }

    /// READ ELEMENT STATUS occasionally returns an ordinary SCSI failure while
    /// Catalina retires the previous FireWire user client. It is safe to retry
    /// an inventory read because it cannot move media. Movement commands use
    /// stricter state reconciliation and are intentionally excluded here.
    static func shouldRetryInventory(_ error: ChangerError) -> Bool {
        if error.isTransportUnavailable || error == .ownedElsewhere { return true }
        if case .commandFailed = error { return true }
        return false
    }

    private func invoke(
        command: String,
        slot: Int? = nil,
        timeout: TimeInterval
    ) throws -> ChangerHelperResponse {
        guard let executable = Bundle.main.executableURL else {
            throw ChangerError.connectionFailed
        }
        let process = Process()
        process.executableURL = executable
        var arguments = ["--changer-helper", command]
        if let slot = slot { arguments.append(String(slot)) }
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw ChangerError.connectionFailed
        }
        guard process.discbotWaitUntilExit(timeout: timeout) else {
            throw ChangerError.notResponding
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let response = decodeResponse(from: data) else {
            throw process.terminationStatus == 0
                ? ChangerError.connectionFailed
                : ChangerError.notResponding
        }
        guard response.ok else { throw changerError(from: response) }
        return response
    }

    private func decodeResponse(from data: Data) -> ChangerHelperResponse? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        for line in text.split(whereSeparator: { $0.isNewline }).reversed() {
            if let value = try? decoder.decode(ChangerHelperResponse.self, from: Data(line.utf8)) {
                return value
            }
        }
        return nil
    }

    private func changerError(from response: ChangerHelperResponse) -> ChangerError {
        let message = response.message ?? "Changer helper failed"
        switch response.errorCode {
        case "connectionFailed": return .connectionFailed
        case "ownedElsewhere": return .ownedElsewhere
        case "notResponding": return .notResponding
        case "notConnected": return .notConnected
        case "deviceNotFound": return .deviceNotFound
        case "commandFailed": return .commandFailed(message)
        case "moveFailed": return .moveFailed(message)
        case "slotEmpty": return .slotEmpty(response.errorArgument ?? 0)
        case "slotOccupied": return .slotOccupied(response.errorArgument ?? 0)
        case "driveNotEmpty": return .driveNotEmpty
        case "driveEmpty": return .driveEmpty
        case "timeout": return .timeout
        case "cancelled": return .cancelled
        default: return .unknown(message)
        }
    }

    private func inventory(from response: ChangerHelperResponse) throws -> ChangerService.InventoryStatus {
        guard let value = response.inventory else {
            throw ChangerError.commandFailed("Helper returned no inventory")
        }
        return ChangerService.InventoryStatus(
            slots: value.slots.map {
                Slot(
                    id: $0.id,
                    address: $0.address,
                    isFull: $0.full,
                    isInDrive: false,
                    hasException: $0.exception
                )
            },
            drive: ChangerService.DriveElementStatus(
                isSupported: value.drive.supported,
                hasDisc: value.drive.hasDisc,
                sourceSlot: value.drive.sourceSlot
            )
        )
    }

    private func updateState(from response: ChangerHelperResponse) {
        stateLock.lock()
        connected = true
        if let device = response.device {
            cachedDevice = ChangerService.ChangerDeviceInfo(
                vendor: device.vendor,
                product: device.product,
                revision: device.revision
            )
        }
        if let value = response.hasIESlot { cachedHasIESlot = value }
        if let value = response.slotCount { cachedSlotCount = value }
        stateLock.unlock()
    }

    private func markDisconnectedIfNeeded(_ error: Error) {
        guard let changerError = error as? ChangerError,
              changerError.isTransportUnavailable || changerError == .ownedElsewhere else { return }
        stateLock.lock()
        connected = false
        stateLock.unlock()
    }
}

protocol ChangerServicing: AnyObject {
    func connect() throws
    func disconnect()
    func getDeviceInfo() throws -> ChangerService.ChangerDeviceInfo
    func getSlotStatus() throws -> [Slot]
    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?)
    func getInventoryStatus() throws -> ChangerService.InventoryStatus
    func loadSlot(_ slotNumber: Int) throws
    func ejectToSlot(_ slotNumber: Int) throws
    func unloadToIE(_ slotNumber: Int) throws
    func importFromIE(_ slotNumber: Int) throws
    func loadFromIE() throws
    func initializeElementStatus() throws

    var hasIESlot: Bool { get }
    var slotCount: Int { get }
    var isConnected: Bool { get }
}

extension ChangerService: ChangerServicing {}

// MARK: - Mock Changer

final class MockChangerState {
    struct DriveSnapshot {
        let hasDisc: Bool
        let sourceSlot: Int?
        let bsdName: String?
        let isMounted: Bool
        let mountPoint: String?
        let volumeName: String?
    }

    private let lock = NSLock()

    let slotCount: Int
    let hasIESlot: Bool

    private var slotsFull: [Bool]
    private var driveHasDisc: Bool
    private var driveSourceSlot: Int?
    private var driveBSDName: String?
    private var driveMounted: Bool
    private var driveMountPoint: String?
    private var driveVolumeName: String?
    private var ieHasDisc: Bool

    /// Mock disc info for variety - indexed by slot number
    struct MockDiscInfo {
        let volumeName: String
        let discType: SlotDiscType
    }

    static let mockDiscCatalog: [MockDiscInfo] = [
        MockDiscInfo(volumeName: "PLANET_EARTH_S1D1", discType: .dvd),
        MockDiscInfo(volumeName: "Abbey Road", discType: .audioCDDA),
        MockDiscInfo(volumeName: "OFFICE_BACKUP_2019", discType: .dataCD),
        MockDiscInfo(volumeName: "The Dark Knight", discType: .dvd),
        MockDiscInfo(volumeName: "Kind of Blue", discType: .audioCDDA),
        MockDiscInfo(volumeName: "PHOTOS_CHRISTMAS_2020", discType: .dataCD),
        MockDiscInfo(volumeName: "Breaking Bad S3D2", discType: .dvd),
        MockDiscInfo(volumeName: "Rumours", discType: .audioCDDA),
        MockDiscInfo(volumeName: "SW_INSTALL_DISC", discType: .dataCD),
        MockDiscInfo(volumeName: "Interstellar", discType: .dvd),
        MockDiscInfo(volumeName: "Thriller", discType: .audioCDDA),
        MockDiscInfo(volumeName: "TAX_RECORDS_2021", discType: .dataCD),
        MockDiscInfo(volumeName: "Seinfeld S4D3", discType: .dvd),
        MockDiscInfo(volumeName: "The Wall", discType: .mixedModeCD),
        MockDiscInfo(volumeName: "HOME_VIDEOS_2018", discType: .dvd),
        MockDiscInfo(volumeName: "OK Computer", discType: .audioCDDA),
        MockDiscInfo(volumeName: "DRIVER_DISC_HP", discType: .dataCD),
        MockDiscInfo(volumeName: "Jurassic Park", discType: .dvd),
        MockDiscInfo(volumeName: "Blue Train", discType: .audioCDDA),
        MockDiscInfo(volumeName: "Blade Runner 2049", discType: .dvd),
    ]

    /// Mock volume names for variety - indexed by slot number
    private static let mockVolumeNames: [String] = mockDiscCatalog.map { $0.volumeName }

    /// Get mock disc info for a slot
    func mockDiscInfo(for slotNumber: Int) -> MockDiscInfo {
        let catalog = MockChangerState.mockDiscCatalog
        return catalog[(slotNumber - 1) % catalog.count]
    }

    init(slotCount: Int = 200, hasIESlot: Bool = true) {
        self.slotCount = slotCount
        self.hasIESlot = hasIESlot

        // Randomized occupancy (~60% full) for a realistic-looking inventory
        var rng = SystemRandomNumberGenerator()
        self.slotsFull = (1...slotCount).map { _ in
            Double.random(in: 0...1, using: &rng) < 0.6
        }

        self.driveHasDisc = false
        self.driveSourceSlot = nil
        self.driveBSDName = nil
        self.driveMounted = false
        self.driveMountPoint = nil
        self.driveVolumeName = nil
        self.ieHasDisc = false
    }

    func snapshotSlotsFull() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return slotsFull
    }

    func snapshotDrive() -> DriveSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DriveSnapshot(
            hasDisc: driveHasDisc,
            sourceSlot: driveSourceSlot,
            bsdName: driveBSDName,
            isMounted: driveMounted,
            mountPoint: driveMountPoint,
            volumeName: driveVolumeName
        )
    }

    func clearIESlot() {
        lock.lock()
        defer { lock.unlock() }
        ieHasDisc = false
    }

    func loadFromSlot(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard slotNumber >= 1, slotNumber <= slotCount else {
            throw ChangerError.slotEmpty(slotNumber)
        }
        guard !driveHasDisc else {
            throw ChangerError.driveNotEmpty
        }
        guard slotsFull[slotNumber - 1] else {
            throw ChangerError.slotEmpty(slotNumber)
        }

        slotsFull[slotNumber - 1] = false
        driveHasDisc = true
        driveSourceSlot = slotNumber
        driveBSDName = "mockdisk\(slotNumber)"
        driveMounted = false
        driveMountPoint = nil
        let names = MockChangerState.mockVolumeNames
        driveVolumeName = names[(slotNumber - 1) % names.count]
    }

    func ejectDrive(toSlot slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard slotNumber >= 1, slotNumber <= slotCount else {
            throw ChangerError.slotOccupied(slotNumber)
        }
        guard driveHasDisc else {
            throw ChangerError.driveEmpty
        }
        guard !slotsFull[slotNumber - 1] else {
            throw ChangerError.slotOccupied(slotNumber)
        }

        slotsFull[slotNumber - 1] = true
        driveHasDisc = false
        driveSourceSlot = nil
        driveBSDName = nil
        driveMounted = false
        driveMountPoint = nil
        driveVolumeName = nil
    }

    func unloadSlotToIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard hasIESlot else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard slotNumber >= 1, slotNumber <= slotCount else {
            throw ChangerError.slotEmpty(slotNumber)
        }

        // If the disc is in the drive and originally came from this slot, eject it to I/E.
        if !slotsFull[slotNumber - 1], driveHasDisc, driveSourceSlot == slotNumber {
            driveHasDisc = false
            driveSourceSlot = nil
            driveBSDName = nil
            driveMounted = false
            driveMountPoint = nil
            driveVolumeName = nil
            ieHasDisc = true
            return
        }

        guard slotsFull[slotNumber - 1] else {
            throw ChangerError.slotEmpty(slotNumber)
        }

        slotsFull[slotNumber - 1] = false
        ieHasDisc = true
    }

    func importIE(toSlot slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard hasIESlot else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard slotNumber >= 1, slotNumber <= slotCount else {
            throw ChangerError.slotOccupied(slotNumber)
        }
        guard ieHasDisc else {
            throw ChangerError.commandFailed("I/E slot is empty")
        }
        guard !slotsFull[slotNumber - 1] else {
            throw ChangerError.slotOccupied(slotNumber)
        }

        slotsFull[slotNumber - 1] = true
        ieHasDisc = false
    }

    func loadIEToDrive() throws {
        lock.lock()
        defer { lock.unlock() }

        guard hasIESlot else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard ieHasDisc else {
            throw ChangerError.commandFailed("I/E slot is empty")
        }
        guard !driveHasDisc else {
            throw ChangerError.driveNotEmpty
        }

        ieHasDisc = false
        driveHasDisc = true
        driveSourceSlot = nil
        driveBSDName = "mockdisk0"
        driveMounted = false
        driveMountPoint = nil
        driveVolumeName = "Mock Disc (I/E)"
    }

    func mountCurrentDisc() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard driveHasDisc else { return "" }
        driveMounted = true
        let mountPoint = "/Volumes/\(driveVolumeName ?? "Mock Disc")"
        driveMountPoint = mountPoint
        return mountPoint
    }

    func unmountCurrentDisc() {
        lock.lock()
        defer { lock.unlock() }
        driveMounted = false
        driveMountPoint = nil
    }
}

final class MockChangerService: ChangerServicing {
    private let state: MockChangerState
    private var connected = false

    init(state: MockChangerState) {
        self.state = state
    }

    func connect() throws {
        connected = true
    }

    func disconnect() {
        connected = false
    }

    func getDeviceInfo() throws -> ChangerService.ChangerDeviceInfo {
        guard connected else { throw ChangerError.notConnected }
        return ChangerService.ChangerDeviceInfo(vendor: "Discbot", product: "Mock Changer", revision: "mock")
    }

    func getSlotStatus() throws -> [Slot] {
        return try getInventoryStatus().slots
    }

    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?) {
        let inv = try getInventoryStatus()
        return (inv.drive.hasDisc, inv.drive.sourceSlot)
    }

    func getInventoryStatus() throws -> ChangerService.InventoryStatus {
        guard connected else { throw ChangerError.notConnected }

        let slotsFull = state.snapshotSlotsFull()
        let driveSnapshot = state.snapshotDrive()

        var slots: [Slot] = []
        slots.reserveCapacity(slotsFull.count)
        for i in 0..<slotsFull.count {
            let slotNumber = i + 1
            let isFull = slotsFull[i]
            let info = state.mockDiscInfo(for: slotNumber)
            slots.append(Slot(
                id: slotNumber,
                address: UInt16(slotNumber),
                isFull: isFull,
                isInDrive: false,
                hasException: false,
                discType: isFull ? info.discType : .unscanned,
                volumeLabel: isFull ? info.volumeName : nil
            ))
        }

        let drive = ChangerService.DriveElementStatus(
            isSupported: true,
            hasDisc: driveSnapshot.hasDisc,
            sourceSlot: driveSnapshot.sourceSlot
        )

        return ChangerService.InventoryStatus(slots: slots, drive: drive)
    }

    func loadSlot(_ slotNumber: Int) throws {
        guard connected else { throw ChangerError.notConnected }
        try state.loadFromSlot(slotNumber)
    }

    func ejectToSlot(_ slotNumber: Int) throws {
        guard connected else { throw ChangerError.notConnected }
        try state.ejectDrive(toSlot: slotNumber)
    }

    func unloadToIE(_ slotNumber: Int) throws {
        guard connected else { throw ChangerError.notConnected }
        try state.unloadSlotToIE(slotNumber)
    }

    func importFromIE(_ slotNumber: Int) throws {
        guard connected else { throw ChangerError.notConnected }
        try state.importIE(toSlot: slotNumber)
    }

    func loadFromIE() throws {
        guard connected else { throw ChangerError.notConnected }
        try state.loadIEToDrive()
    }

    func initializeElementStatus() throws {
        guard connected else { throw ChangerError.notConnected }
    }

    var hasIESlot: Bool { state.hasIESlot }
    var slotCount: Int { state.slotCount }
    var isConnected: Bool { connected }
}
