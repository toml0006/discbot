//
//  ImagingService.swift
//  Discbot
//
//  Service for creating disc images
//

import Foundation
import Darwin

struct ImagingProgressInfo {
    let fractionCompleted: Double
    let bytesTransferred: Int64
    let totalBytes: Int64?
    let speedBytesPerSecond: Double?
    let etaSeconds: TimeInterval?
}

/// Disc type detection result
enum DiscType: Equatable {
    case audioCDDA        // Pure audio CD
    case dataCD           // Data CD (ISO 9660, HFS+, etc.)
    case mixedModeCD      // Audio + data tracks
    case dvd              // DVD-ROM
    case unknown
}

final class ImagingService {
    final class ImagingControl {
        private let lock = NSLock()
        private var process: Process?
        private var paused = false
        private var cancelled = false

        var isPaused: Bool {
            lock.lock()
            defer { lock.unlock() }
            return paused
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func attach(process: Process?) {
            lock.lock()
            self.process = process
            let shouldPause = paused
            let wasCancelled = cancelled
            lock.unlock()

            guard let process = process else { return }
            if wasCancelled {
                process.terminate()
            } else if shouldPause {
                _ = kill(process.processIdentifier, SIGSTOP)
            }
        }

        func setPaused(_ paused: Bool) {
            lock.lock()
            self.paused = paused
            let attachedProcess = self.process
            lock.unlock()

            guard let process = attachedProcess else { return }
            let signal = paused ? SIGSTOP : SIGCONT
            _ = kill(process.processIdentifier, signal)
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()

            process?.terminate()
        }

        func reset() {
            lock.lock()
            paused = false
            cancelled = false
            process = nil
            lock.unlock()
        }
    }

    func estimateDiscSizeBytes(bsdName: String) -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/dev/\(bsdName)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else {
                return nil
            }

            if let totalSize = plist["TotalSize"] as? Int64 {
                return totalSize
            }
            if let size = plist["Size"] as? Int64 {
                return size
            }
        } catch {
            return nil
        }

        return nil
    }

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
        totalBytes: Int64? = nil,
        control: ImagingControl? = nil,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        if control?.isCancelled == true {
            throw ImagingError.cancelled
        }

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
        let startTime = Date()
        var outputBuffer = ""
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let line = String(data: data, encoding: .utf8) {
                outputBuffer.append(line)
                let components = outputBuffer.components(separatedBy: "\n")
                outputBuffer = components.last ?? ""

                // Parse puppetstrings format: PERCENT:n.n
                for component in components.dropLast() {
                    if component.hasPrefix("PERCENT:") {
                        if let value = Double(component.dropFirst(8)) {
                            progressQueue.async {
                                DispatchQueue.main.async {
                                    let fraction = value / 100.0
                                    let transferred = Int64((Double(totalBytes ?? 0) * fraction).rounded())
                                    let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
                                    let speed = transferred > 0 ? (Double(transferred) / elapsed) : nil
                                    let eta: TimeInterval?
                                    if let totalBytes = totalBytes, let speed = speed, speed > 0 {
                                        eta = max(Double(totalBytes - transferred) / speed, 0)
                                    } else {
                                        eta = nil
                                    }
                                    progress(
                                        ImagingProgressInfo(
                                            fractionCompleted: fraction,
                                            bytesTransferred: transferred,
                                            totalBytes: totalBytes,
                                            speedBytesPerSecond: speed,
                                            etaSeconds: eta
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        try process.run()
        control?.attach(process: process)
        process.waitUntilExit()
        control?.attach(process: nil)

        pipe.fileHandleForReading.readabilityHandler = nil

        if control?.isCancelled == true {
            throw ImagingError.cancelled
        }

        guard process.terminationStatus == 0 else {
            throw ImagingError.processFailed(process.terminationStatus, "hdiutil failed")
        }

        // Rename .cdr to .iso (they are equivalent for data discs)
        if FileManager.default.fileExists(atPath: cdrPath.path) {
            try FileManager.default.moveItem(at: cdrPath, to: isoPath)
        }

        let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
        let speed = totalBytes.map { Double($0) / elapsed }
        progress(
            ImagingProgressInfo(
                fractionCompleted: 1.0,
                bytesTransferred: totalBytes ?? 0,
                totalBytes: totalBytes,
                speedBytesPerSecond: speed,
                etaSeconds: 0
            )
        )
        return isoPath
    }

    /// Create a BIN/CUE image for audio CDs (not yet implemented)
    func createBINCUEImage(
        bsdName: String,
        outputPath: URL,
        totalBytes: Int64? = nil,
        control: ImagingControl? = nil,
        progress: @escaping (ImagingProgressInfo) -> Void
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
        totalBytes: Int64? = nil,
        control: ImagingControl? = nil,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        switch discType {
        case .audioCDDA:
            // Try BIN/CUE first, fall back to ISO
            do {
                return try createBINCUEImage(
                    bsdName: bsdName,
                    outputPath: outputPath,
                    totalBytes: totalBytes,
                    control: control,
                    progress: progress
                )
            } catch ImagingError.unsupportedDiscType {
                // Fall back to ISO
                return try createISOImage(
                    bsdName: bsdName,
                    outputPath: outputPath,
                    totalBytes: totalBytes,
                    control: control,
                    progress: progress
                )
            }

        case .dataCD, .dvd, .mixedModeCD, .unknown:
            return try createISOImage(
                bsdName: bsdName,
                outputPath: outputPath,
                totalBytes: totalBytes,
                control: control,
                progress: progress
            )
        }
    }
}
