//
//  Slot.swift
//  Discbot
//
//  Model representing a single storage slot in the changer
//

import Foundation

enum BackupStatus: Equatable {
    case notBackedUp
    case backedUp(Date)
    case failed
}

/// Known disc type for a slot (populated after scan/load)
enum SlotDiscType: Equatable {
    case audioCDDA
    case dataCD
    case mixedModeCD
    case dvd
    case unknown       // Scanned but type unrecognized
    case unscanned     // Never been loaded/scanned

    var iconName: String {
        switch self {
        case .audioCDDA:   return "disc.cd.audio"
        case .dataCD:      return "disc.cd.data"
        case .mixedModeCD: return "disc.cd.mixed"
        case .dvd:         return "disc.dvd"
        case .unknown:     return "disc.unknown"
        case .unscanned:   return "disc.unscanned"
        }
    }

    var label: String {
        switch self {
        case .audioCDDA:   return "Audio CD"
        case .dataCD:      return "Data CD"
        case .mixedModeCD: return "Mixed CD"
        case .dvd:         return "DVD"
        case .unknown:     return "Unknown"
        case .unscanned:   return "Unscanned"
        }
    }

    var typicalSizeLabel: String {
        switch self {
        case .audioCDDA:   return "~700 MB"
        case .dataCD:      return "~700 MB"
        case .mixedModeCD: return "~700 MB"
        case .dvd:         return "~4.7 GB"
        case .unknown:     return "Unknown size"
        case .unscanned:   return "Unknown size"
        }
    }

    /// Parse from catalog string
    static func from(catalogString: String?) -> SlotDiscType {
        switch catalogString {
        case "audioCDDA":   return .audioCDDA
        case "dataCD":      return .dataCD
        case "mixedModeCD": return .mixedModeCD
        case "dvd":         return .dvd
        case "unknown":     return .unknown
        default:            return .unscanned
        }
    }
}

struct Slot: Identifiable, Equatable {
    let id: Int              // 1-based slot number (1-200)
    let address: UInt16      // SCSI element address
    var isFull: Bool         // Has disc in slot
    var isInDrive: Bool      // Currently loaded in drive
    var hasException: Bool   // Exception condition from changer
    var backupStatus: BackupStatus  // Backup tracking status
    var discType: SlotDiscType = .unscanned   // Known disc type
    var volumeLabel: String?        // Volume label from last scan

    init(id: Int, address: UInt16, isFull: Bool = false, isInDrive: Bool = false, hasException: Bool = false, backupStatus: BackupStatus = .notBackedUp, discType: SlotDiscType = .unscanned, volumeLabel: String? = nil) {
        self.id = id
        self.address = address
        self.isFull = isFull
        self.isInDrive = isInDrive
        self.hasException = hasException
        self.backupStatus = backupStatus
        self.discType = discType
        self.volumeLabel = volumeLabel
    }
}
