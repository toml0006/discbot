//
//  ImagingService.swift
//  Discbot
//
//  Service for creating disc images
//

import Foundation

/// Disc type detection result
enum DiscType: Equatable {
    case audioCDDA        // Pure audio CD
    case dataCD           // Data CD (ISO 9660, HFS+, etc.)
    case mixedModeCD      // Audio + data tracks
    case dvd              // DVD-ROM
    case unknown
}

final class ImagingService {
    /// Detect the type of disc in the drive (blocking)
    func detectDiscType(bsdName: String) -> DiscType {
        // Use diskutil to get media info
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", bsdName]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if output.contains("DVD") {
                return .dvd
            } else if output.contains("Audio") || output.contains("CDDA") {
                return .audioCDDA
            } else if output.contains("CD") {
                return .dataCD
            }
        } catch {
            // Ignore errors
        }

        return .unknown
    }

    /// Create an ISO image using hdiutil (blocking)
    func createISOImage(
        bsdName: String,
        outputPath: URL,
        progress: @escaping (Double) -> Void
    ) throws -> URL {
        let outputBase = outputPath.deletingPathExtension()
        let cdrPath = outputBase.appendingPathExtension("cdr")
        let isoPath = outputBase.appendingPathExtension("iso")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "create",
            "-srcdevice", "/dev/\(bsdName)",
            "-format", "UDTO",
            "-puppetstrings",
            "-o", outputBase.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Monitor progress via puppetstrings output
        let progressQueue = DispatchQueue(label: "imaging.progress")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let line = String(data: data, encoding: .utf8) {
                // Parse puppetstrings format: PERCENT:n.n
                for component in line.components(separatedBy: "\n") {
                    if component.hasPrefix("PERCENT:") {
                        if let value = Double(component.dropFirst(8)) {
                            progressQueue.async {
                                DispatchQueue.main.async {
                                    progress(value / 100.0)
                                }
                            }
                        }
                    }
                }
            }
        }

        try process.run()
        process.waitUntilExit()

        pipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw ImagingError.processFailed(process.terminationStatus, "hdiutil failed")
        }

        // Rename .cdr to .iso (they are equivalent for data discs)
        if FileManager.default.fileExists(atPath: cdrPath.path) {
            try FileManager.default.moveItem(at: cdrPath, to: isoPath)
        }

        progress(1.0)
        return isoPath
    }

    /// Create a BIN/CUE image for audio CDs (not yet implemented)
    func createBINCUEImage(
        bsdName: String,
        outputPath: URL,
        progress: @escaping (Double) -> Void
    ) throws -> URL {
        // For audio CDs, we'd need to use IOCDMediaBSDClient.h ioctls for raw sector reading
        // For now, fall back to ISO format
        throw ImagingError.unsupportedDiscType("Audio CD BIN/CUE imaging not yet implemented. Use ISO format.")
    }

    /// Create an image of appropriate type based on disc type (blocking)
    func createImage(
        bsdName: String,
        discType: DiscType,
        outputPath: URL,
        progress: @escaping (Double) -> Void
    ) throws -> URL {
        switch discType {
        case .audioCDDA:
            // Try BIN/CUE first, fall back to ISO
            do {
                return try createBINCUEImage(bsdName: bsdName, outputPath: outputPath, progress: progress)
            } catch ImagingError.unsupportedDiscType {
                // Fall back to ISO
                return try createISOImage(bsdName: bsdName, outputPath: outputPath, progress: progress)
            }

        case .dataCD, .dvd, .mixedModeCD, .unknown:
            return try createISOImage(bsdName: bsdName, outputPath: outputPath, progress: progress)
        }
    }
}
