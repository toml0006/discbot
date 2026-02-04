//
//  Slot.swift
//  VGPChangerApp
//
//  Model representing a single storage slot in the changer
//

import Foundation

struct Slot: Identifiable, Equatable {
    let id: Int              // 1-based slot number (1-200)
    let address: UInt16      // SCSI element address
    var isFull: Bool         // Has disc in slot
    var isInDrive: Bool      // Currently loaded in drive
    var hasException: Bool   // Exception condition from changer

    init(id: Int, address: UInt16, isFull: Bool = false, isInDrive: Bool = false, hasException: Bool = false) {
        self.id = id
        self.address = address
        self.isFull = isFull
        self.isInDrive = isInDrive
        self.hasException = hasException
    }
}
