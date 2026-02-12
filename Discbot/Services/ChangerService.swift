//
//  ChangerService.swift
//  Discbot
//
//  Service for communicating with the DVD changer using mchanger library
//

import Foundation

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

    /// Connect to the DVD changer (blocking)
    func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        if handle != nil {
            return // Already connected
        }

        guard let h = mchanger_open(nil) else {
            throw ChangerError.connectionFailed
        }

        handle = h

        // Load element map
        try loadElementMapLocked()
    }

    /// Disconnect from the changer
    func disconnect() {
        lock.lock()
        defer { lock.unlock() }

        if let h = handle {
            mchanger_close(h)
            handle = nil
        }

        if var map = elementMap {
            mchanger_free_element_map(&map)
            elementMap = nil
        }
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

        let result = mchanger_inquiry(h, &vendor, 64, &product, 64, &revision, 64)

        if result != MCHANGER_OK {
            throw ChangerError.commandFailed("INQUIRY")
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
        }

        var map = MChangerElementMap()
        let result = mchanger_get_element_map(h, &map)

        if result != MCHANGER_OK {
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

        switch result {
        case MCHANGER_OK:
            return
        case MCHANGER_ERR_EMPTY:
            throw ChangerError.driveEmpty
        case MCHANGER_ERR_BUSY:
            throw ChangerError.slotOccupied(slotNumber)
        default:
            throw ChangerError.moveFailed("mchanger_unload_drive returned \(result)")
        }
    }

    /// Initialize element status (full inventory scan, blocking, takes several minutes)
    func initializeElementStatus() throws {
        lock.lock()
        defer { lock.unlock() }

        guard handle != nil else {
            throw ChangerError.notConnected
        }

        // Reload element map
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

        print("Ejecting slot \(slotNumber) to I/E slot")
        let result = mchanger_eject(h, Int32(slotNumber), 1)

        switch result {
        case MCHANGER_OK:
            return
        case MCHANGER_ERR_EMPTY:
            throw ChangerError.slotEmpty(slotNumber)
        default:
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
        guard map.ie_count > 0, let ieAddrs = map.ie_addrs else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard slotNumber >= 1 && slotNumber <= map.slot_count, let slotAddrs = map.slot_addrs else {
            throw ChangerError.slotOccupied(slotNumber)
        }
        guard let transportAddrs = map.transport_addrs, map.transport_count > 0 else {
            throw ChangerError.commandFailed("No transport element")
        }

        let slotAddr = slotAddrs[slotNumber - 1]
        let ieAddr = ieAddrs[0]
        let transport = transportAddrs[0]

        print("MOVE MEDIUM (import): transport=\(transport), source=\(ieAddr), dest=\(slotAddr)")
        let result = mchanger_move_medium(h, transport, ieAddr, slotAddr)

        if result != MCHANGER_OK {
            throw ChangerError.moveFailed("mchanger_move_medium returned \(result)")
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
    private var discSerial: Int

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
        self.discSerial = 1
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
        driveBSDName = "mockdisk\(discSerial)"
        driveMounted = false
        driveMountPoint = nil
        let names = MockChangerState.mockVolumeNames
        driveVolumeName = names[(slotNumber - 1) % names.count]
        discSerial += 1
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
        driveBSDName = "mockdisk\(discSerial)"
        driveMounted = false
        driveMountPoint = nil
        driveVolumeName = "Mock Disc (I/E)"
        discSerial += 1
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
