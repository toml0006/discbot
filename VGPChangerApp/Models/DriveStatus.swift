//
//  DriveStatus.swift
//  VGPChangerApp
//
//  Represents the current state of the drive
//

import Foundation

enum DriveStatus: Equatable {
    case empty
    case loading(fromSlot: Int)
    case loaded(sourceSlot: Int, mountPoint: String?)
    case ejecting(toSlot: Int)
    case error(String)

    var hasDisc: Bool {
        switch self {
        case .loaded: return true
        default: return false
        }
    }

    var sourceSlot: Int? {
        switch self {
        case .loaded(let slot, _): return slot
        default: return nil
        }
    }

    var mountPoint: String? {
        switch self {
        case .loaded(_, let mount): return mount
        default: return nil
        }
    }

    var isMounted: Bool {
        switch self {
        case .loaded(_, let mount): return mount != nil
        default: return false
        }
    }
}
