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

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }

        var slots: [Slot] = []

        for i in 0..<map.slot_count {
            let slotNumber = Int(i) + 1
            var status = MChangerElementStatus()

            let result = mchanger_get_slot_status(h, Int32(slotNumber), &status)

            if result == MCHANGER_OK {
                slots.append(Slot(
                    id: slotNumber,
                    address: status.address,
                    isFull: status.full,
                    isInDrive: false,
                    hasException: status.except
                ))
            } else {
                // On error, add empty slot placeholder
                slots.append(Slot(
                    id: slotNumber,
                    address: map.slot_addrs?[i] ?? 0,
                    isFull: false,
                    isInDrive: false,
                    hasException: false
                ))
            }
        }

        return slots.sorted { $0.id < $1.id }
    }

    /// Get drive status (blocking)
    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?) {
        lock.lock()
        defer { lock.unlock() }

        guard let h = handle else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }

        var status = MChangerElementStatus()
        let result = mchanger_get_drive_status(h, 1, &status)

        if result != MCHANGER_OK {
            print("getDriveStatus: mchanger_get_drive_status returned \(result)")
            return (false, nil)
        }

        print("getDriveStatus: full=\(status.full), valid_source=\(status.valid_source), source=\(status.source_addr)")

        var sourceSlot: Int? = nil
        if status.valid_source && map.slot_addrs != nil {
            // Find slot number from source address
            for i in 0..<map.slot_count {
                if map.slot_addrs[i] == status.source_addr {
                    sourceSlot = Int(i) + 1
                    break
                }
            }
        }

        return (status.full, sourceSlot)
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
