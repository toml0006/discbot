//
//  ChangerService.swift
//  Discbot
//
//  Service for communicating with the DVD changer (thread-safe)
//

import Foundation

/// Thread-safe service for communicating with the DVD changer
final class ChangerService {
    private var connection: UnsafeMutablePointer<ChangerConnection>?
    private var elementMap: ElementMapWrapper?
    private let lock = NSLock()

    struct ChangerDeviceInfo {
        let vendor: String
        let product: String
        let revision: String
        let deviceType: UInt8
    }

    struct ElementMapWrapper {
        let transport: UInt16
        let slots: [UInt16]
        let drive: UInt16
        let ie: UInt16?
    }

    /// Connect to the DVD changer (blocking)
    func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        if connection != nil {
            return // Already connected
        }

        // Allocate connection struct
        let conn = UnsafeMutablePointer<ChangerConnection>.allocate(capacity: 1)
        conn.initialize(to: ChangerConnection())

        let result = changer_connect(conn)

        if result != 0 {
            conn.deallocate()
            throw ChangerError.connectionFailed
        }

        connection = conn

        // Load element map
        try loadElementMapLocked()
    }

    /// Disconnect from the changer
    func disconnect() {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else { return }
        changer_disconnect(conn)
        conn.deallocate()
        connection = nil
        elementMap = nil
    }

    /// Get device info via INQUIRY (blocking)
    func getDeviceInfo() throws -> ChangerDeviceInfo {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }

        var info = DeviceInfo()
        let result = scsi_inquiry(conn, &info)

        if result != 0 {
            throw ChangerError.commandFailed("INQUIRY")
        }

        return ChangerDeviceInfo(
            vendor: String(cString: &info.vendor.0).trimmingCharacters(in: .whitespaces),
            product: String(cString: &info.product.0).trimmingCharacters(in: .whitespaces),
            revision: String(cString: &info.revision.0).trimmingCharacters(in: .whitespaces),
            deviceType: info.device_type
        )
    }

    /// Load element map from MODE SENSE (must hold lock)
    private func loadElementMapLocked() throws {
        guard let conn = connection else {
            throw ChangerError.notConnected
        }

        var map = ElementMap()
        let result = scsi_mode_sense_element(conn, &map)

        if result != 0 {
            throw ChangerError.commandFailed("MODE SENSE")
        }

        // Copy slot addresses to Swift array
        var slots: [UInt16] = []
        if map.slot_count > 0 && map.slots != nil {
            for i in 0..<map.slot_count {
                slots.append(map.slots[i])
            }
        }

        elementMap = ElementMapWrapper(
            transport: map.transport,
            slots: slots,
            drive: map.drive,
            ie: map.has_ie ? map.ie : nil
        )

        print("Element map loaded: transport=\(map.transport), drive=\(map.drive), slots=\(slots.count) (\(slots.first ?? 0)-\(slots.last ?? 0)), ie=\(map.has_ie ? String(map.ie) : "none")")

        element_map_free(&map)
    }

    /// Get status of all slots (blocking)
    /// Note: VGP-XL1B only returns ~40 elements per query, so we read in chunks
    func getSlotStatus() throws -> [Slot] {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }

        let totalCount = map.slots.count
        guard totalCount > 0 else {
            return []
        }

        // Read in chunks of 50 (VGP-XL1B returns max ~40 per query)
        let chunkSize = 50
        var allSlots: [Slot] = []
        var slotsByAddress: [UInt16: Slot] = [:]

        let statuses = UnsafeMutablePointer<ElementStatus>.allocate(capacity: chunkSize)
        defer { statuses.deallocate() }

        var offset = 0
        while offset < totalCount {
            let remaining = totalCount - offset
            let count = min(remaining, chunkSize)
            let startAddr = map.slots[offset]

            let result = scsi_read_element_status(
                conn,
                UInt8(ELEM_STORAGE),
                startAddr,
                UInt16(count),
                statuses,
                chunkSize
            )

            if result < 0 {
                throw ChangerError.commandFailed("READ ELEMENT STATUS")
            }

            let resultCount = Int(result)
            for i in 0..<resultCount {
                let s = statuses[i]
                // Find slot number from address
                if let slotIndex = map.slots.firstIndex(of: s.address) {
                    let slot = Slot(
                        id: slotIndex + 1,
                        address: s.address,
                        isFull: s.full,
                        isInDrive: false,
                        hasException: s.except
                    )
                    slotsByAddress[s.address] = slot
                }
            }

            offset += count
        }

        // Build final array, filling in any missing slots as empty
        for i in 0..<totalCount {
            let addr = map.slots[i]
            if let slot = slotsByAddress[addr] {
                allSlots.append(slot)
            } else {
                allSlots.append(Slot(
                    id: i + 1,
                    address: addr,
                    isFull: false,
                    isInDrive: false,
                    hasException: false
                ))
            }
        }

        return allSlots.sorted { $0.id < $1.id }
    }

    /// Get drive status (blocking)
    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?) {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }

        let status = UnsafeMutablePointer<ElementStatus>.allocate(capacity: 1)
        defer { status.deallocate() }

        print("getDriveStatus: querying drive at address \(map.drive)")

        let result = scsi_read_element_status(
            conn,
            UInt8(ELEM_DRIVE),
            map.drive,
            1,
            status,
            1
        )

        print("getDriveStatus: READ ELEMENT STATUS returned \(result)")

        if result < 0 {
            throw ChangerError.commandFailed("READ ELEMENT STATUS (drive)")
        }

        guard result > 0 else {
            print("getDriveStatus: no elements returned, assuming empty")
            return (false, nil)
        }

        print("getDriveStatus: address=\(status.pointee.address), full=\(status.pointee.full), source_valid=\(status.pointee.source_valid), source=\(status.pointee.source)")

        let sourceSlot: Int?
        if status.pointee.source_valid {
            // Find slot number from source address
            if let idx = map.slots.firstIndex(of: status.pointee.source) {
                sourceSlot = idx + 1
            } else {
                sourceSlot = nil
            }
        } else {
            sourceSlot = nil
        }

        print("getDriveStatus: returning hasDisc=\(status.pointee.full), sourceSlot=\(sourceSlot ?? -1)")
        return (status.pointee.full, sourceSlot)
    }

    /// Load disc from slot to drive (blocking, takes 60-120 seconds)
    func loadSlot(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard slotNumber >= 1 && slotNumber <= map.slots.count else {
            throw ChangerError.slotEmpty(slotNumber)
        }

        let slotAddr = map.slots[slotNumber - 1]

        print("MOVE MEDIUM: transport=\(map.transport), source=\(slotAddr), dest=\(map.drive)")
        let result = scsi_move_medium(conn, map.transport, slotAddr, map.drive)

        if result != 0 {
            var sense = scsi_get_last_sense()
            let msg = String(cString: scsi_sense_string(&sense))
            print("MOVE MEDIUM failed: \(msg), sense valid=\(sense.valid)")

            // Check for "Medium destination full" (sense 05/3b/0d) - means drive has disc
            // This happens because VGP-XL1B doesn't support READ ELEMENT STATUS for drive
            if msg.contains("destination full") {
                throw ChangerError.driveNotEmpty
            }
            throw ChangerError.moveFailed(msg)
        }
    }

    /// Eject disc from drive to slot (blocking, takes 60-120 seconds)
    func ejectToSlot(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard slotNumber >= 1 && slotNumber <= map.slots.count else {
            throw ChangerError.slotOccupied(slotNumber)
        }

        let slotAddr = map.slots[slotNumber - 1]

        print("MOVE MEDIUM: transport=\(map.transport), source=\(map.drive), dest=\(slotAddr)")
        var result = scsi_move_medium(conn, map.transport, map.drive, slotAddr)

        if result != 0 {
            var sense = scsi_get_last_sense()
            let msg = String(cString: scsi_sense_string(&sense))
            print("MOVE MEDIUM failed: \(msg), sense valid=\(sense.valid), sense_key=\(sense.sense_key)")

            // Check for specific SCSI errors
            if msg.contains("source empty") {
                throw ChangerError.driveEmpty
            }
            if msg.contains("destination full") {
                throw ChangerError.slotOccupied(slotNumber)
            }

            // VGP-XL1B quirk: if sense is "No sense" (00/00/00), the changer's
            // internal state may be out of sync. Run INITIALIZE ELEMENT STATUS
            // to rescan and then retry.
            if sense.sense_key == 0 && sense.asc == 0 && sense.ascq == 0 {
                print("Got 'No sense' error - changer state may be stale. Running INITIALIZE ELEMENT STATUS...")
                let initResult = scsi_init_element_status(conn)
                if initResult == 0 {
                    // Wait for init to complete
                    Thread.sleep(forTimeInterval: 5.0)

                    print("INITIALIZE ELEMENT STATUS complete, retrying MOVE MEDIUM...")
                    result = scsi_move_medium(conn, map.transport, map.drive, slotAddr)

                    if result == 0 {
                        print("MOVE MEDIUM succeeded after INITIALIZE ELEMENT STATUS")
                        return
                    }

                    // Still failed - get new sense data
                    sense = scsi_get_last_sense()
                    let retryMsg = String(cString: scsi_sense_string(&sense))
                    print("MOVE MEDIUM still failed after init: \(retryMsg)")
                    throw ChangerError.moveFailed(retryMsg)
                } else {
                    print("INITIALIZE ELEMENT STATUS failed")
                }
            }

            throw ChangerError.moveFailed(msg)
        }
    }

    /// Initialize element status (full inventory scan, blocking, takes several minutes)
    func initializeElementStatus() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }

        let result = scsi_init_element_status(conn)

        if result != 0 {
            throw ChangerError.commandFailed("INITIALIZE ELEMENT STATUS")
        }

        // Reload element map after scan
        try loadElementMapLocked()
    }

    /// Unload disc from slot to I/E slot for physical removal (blocking)
    func unloadToIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard let ieAddr = map.ie else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard slotNumber >= 1 && slotNumber <= map.slots.count else {
            throw ChangerError.slotEmpty(slotNumber)
        }

        let slotAddr = map.slots[slotNumber - 1]

        print("MOVE MEDIUM (eject to I/E): transport=\(map.transport), source=\(slotAddr), dest=\(ieAddr)")
        let result = scsi_move_medium(conn, map.transport, slotAddr, ieAddr)

        if result != 0 {
            var sense = scsi_get_last_sense()
            let msg = String(cString: scsi_sense_string(&sense))
            print("MOVE MEDIUM failed: \(msg), sense valid=\(sense.valid)")

            // Check for specific SCSI errors
            if msg.contains("source empty") {
                throw ChangerError.slotEmpty(slotNumber)
            }
            if msg.contains("destination full") {
                throw ChangerError.commandFailed("I/E slot is full - remove disc first")
            }
            throw ChangerError.moveFailed(msg)
        }
    }

    /// Import disc from I/E slot to specified slot (blocking)
    func importFromIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard let ieAddr = map.ie else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }
        guard slotNumber >= 1 && slotNumber <= map.slots.count else {
            throw ChangerError.slotOccupied(slotNumber)
        }

        let slotAddr = map.slots[slotNumber - 1]

        print("MOVE MEDIUM (import): transport=\(map.transport), source=\(ieAddr), dest=\(slotAddr)")
        let result = scsi_move_medium(conn, map.transport, ieAddr, slotAddr)

        if result != 0 {
            var sense = scsi_get_last_sense()
            let msg = String(cString: scsi_sense_string(&sense))
            print("MOVE MEDIUM failed: \(msg), sense valid=\(sense.valid)")
            throw ChangerError.moveFailed(msg)
        }
    }

    /// Load disc from I/E slot directly to drive (blocking)
    func loadFromIE() throws {
        lock.lock()
        defer { lock.unlock() }

        guard let conn = connection else {
            throw ChangerError.notConnected
        }
        guard let map = elementMap else {
            throw ChangerError.commandFailed("No element map")
        }
        guard let ieAddr = map.ie else {
            throw ChangerError.commandFailed("Changer has no import/export slot")
        }

        print("MOVE MEDIUM (load from I/E): transport=\(map.transport), source=\(ieAddr), dest=\(map.drive)")
        let result = scsi_move_medium(conn, map.transport, ieAddr, map.drive)

        if result != 0 {
            var sense = scsi_get_last_sense()
            let msg = String(cString: scsi_sense_string(&sense))
            print("MOVE MEDIUM failed: \(msg), sense valid=\(sense.valid)")

            if msg.contains("source empty") {
                throw ChangerError.commandFailed("I/E slot is empty")
            }
            if msg.contains("destination full") {
                throw ChangerError.driveNotEmpty
            }
            throw ChangerError.moveFailed(msg)
        }
    }

    /// Check if changer has an I/E slot
    var hasIESlot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return elementMap?.ie != nil
    }

    /// Get slot count
    var slotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return elementMap?.slots.count ?? 0
    }

    /// Check if connected
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil
    }
}
