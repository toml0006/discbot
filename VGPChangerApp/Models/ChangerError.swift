//
//  ChangerError.swift
//  VGPChangerApp
//
//  Error types for changer operations
//

import Foundation

enum ChangerError: LocalizedError, Equatable {
    case connectionFailed
    case notConnected
    case deviceNotFound
    case commandFailed(String)
    case moveFailed(String)
    case slotEmpty(Int)
    case slotOccupied(Int)
    case driveNotEmpty
    case driveEmpty
    case mountFailed(String)
    case unmountFailed(String)
    case timeout
    case cancelled
    case imagingFailed(String)
    case metadataFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to DVD changer"
        case .notConnected:
            return "Not connected to DVD changer"
        case .deviceNotFound:
            return "No DVD changer found"
        case .commandFailed(let cmd):
            return "SCSI command failed: \(cmd)"
        case .moveFailed(let reason):
            return "Failed to move disc: \(reason)"
        case .slotEmpty(let n):
            return "Slot \(n) is empty"
        case .slotOccupied(let n):
            return "Slot \(n) is occupied"
        case .driveNotEmpty:
            return "Drive already contains a disc"
        case .driveEmpty:
            return "No disc in drive"
        case .mountFailed(let reason):
            return "Failed to mount disc: \(reason)"
        case .unmountFailed(let reason):
            return "Unmount failed: \(reason)"
        case .timeout:
            return "Operation timed out"
        case .cancelled:
            return "Operation was cancelled"
        case .imagingFailed(let reason):
            return "Imaging failed: \(reason)"
        case .metadataFailed(let reason):
            return "Metadata lookup failed: \(reason)"
        case .unknown(let msg):
            return msg
        }
    }
}

enum ImagingError: LocalizedError {
    case deviceNotFound(String)
    case readFailed(Int32)
    case writeFailed(URL)
    case processFailed(Int32, String)
    case timeout
    case discNotReady
    case unsupportedDiscType(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound(let name):
            return "Device /dev/\(name) not found"
        case .readFailed(let errno):
            return "Read failed: errno \(errno)"
        case .writeFailed(let url):
            return "Failed to write to \(url.path)"
        case .processFailed(let code, let stderr):
            return "Process exited with code \(code): \(stderr)"
        case .timeout:
            return "Operation timed out"
        case .discNotReady:
            return "Disc not ready"
        case .unsupportedDiscType(let type):
            return "Unsupported disc type: \(type)"
        }
    }
}

enum MetadataError: LocalizedError {
    case networkUnavailable
    case rateLimited
    case invalidResponse
    case httpError(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Network unavailable"
        case .rateLimited:
            return "Rate limited, please wait"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .decodingFailed:
            return "Failed to decode response"
        }
    }
}
