//
//  ImagingService.swift
//  Discbot
//
//  Service for creating disc images
//

import Foundation
import Darwin
import os.log

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

    var preferredImageExtension: String {
        switch self {
        case .audioCDDA: return "zip"
        case .mixedModeCD: return "bin"
        case .dataCD, .dvd, .unknown: return "iso"
        }
    }
}

enum RipOutputMode: String, Codable, CaseIterable, Hashable {
    /// Preserve the established per-media outputs: lossless AIFF ZIP for
    /// audio CDs and ISO for filesystem discs.
    case automatic
    /// Prefer a single playable ISO for filesystem discs. CD-DA remains a
    /// lossless AIFF ZIP because an audio CD has no ISO/UDF filesystem.
    case iso
    /// Preserve a decrypted DVD-Video folder instead of rebuilding it as an
    /// ISO. Other media retain their established lossless output format.
    case dvdFolder

    var displayName: String {
        switch self {
        case .automatic: return "Best format for each disc"
        case .iso: return "ISO disc image"
        case .dvdFolder: return "DVD folder (faster)"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Audio CDs become lossless AIFF ZIP archives; data CDs and DVDs become ISO images."
        case .iso:
            return "Data discs and DVDs become playable ISO images. Audio CDs remain lossless AIFF ZIP archives because CD-DA cannot be represented by ISO."
        case .dvdFolder:
            return "DVD-Video discs become playable .dvdmedia folders without the extra ISO-building pass. Other discs keep their normal lossless format."
        }
    }

    func preferredExtension(for discType: DiscType) -> String {
        if self == .dvdFolder && discType == .dvd { return "dvdmedia" }
        // Every mode intentionally retains the safe Catalina audio path.
        return discType.preferredImageExtension
    }
}

/// A physical read may produce a locally staged artifact that can be
/// finalized after the changer has safely returned the disc.
enum BatchImageArtifact {
    case complete(URL)
    case staged(StagedImageArtifact)
}

final class StagedImageArtifact {
    let expectedFinalURL: URL
    private let finalizeBlock: (ImagingService.ImagingControl?) throws -> URL
    private let discardBlock: () -> Void

    init(
        expectedFinalURL: URL,
        finalize: @escaping (ImagingService.ImagingControl?) throws -> URL,
        discard: @escaping () -> Void
    ) {
        self.expectedFinalURL = expectedFinalURL
        self.finalizeBlock = finalize
        self.discardBlock = discard
    }

    func finalize(control: ImagingService.ImagingControl?) throws -> URL {
        try finalizeBlock(control)
    }

    func discard() {
        discardBlock()
    }
}

protocol ImagingServicing: AnyObject {
    func estimateDiscSizeBytes(bsdName: String) -> Int64?
    func detectDiscType(bsdName: String) -> DiscType
    func createImage(
        bsdName: String,
        discType: DiscType,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL
    func createImage(
        bsdName: String,
        discType: DiscType,
        outputMode: RipOutputMode,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL
    func createBatchImage(
        bsdName: String,
        discType: DiscType,
        outputMode: RipOutputMode,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> BatchImageArtifact
}

extension ImagingServicing {
    func createImage(
        bsdName: String,
        discType: DiscType,
        outputMode: RipOutputMode,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        try createImage(
            bsdName: bsdName,
            discType: discType,
            outputPath: outputPath,
            totalBytes: totalBytes,
            control: control,
            progress: progress
        )
    }

    func createBatchImage(
        bsdName: String,
        discType: DiscType,
        outputMode: RipOutputMode,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> BatchImageArtifact {
        .complete(try createImage(
            bsdName: bsdName,
            discType: discType,
            outputMode: outputMode,
            outputPath: outputPath,
            totalBytes: totalBytes,
            control: control,
            progress: progress
        ))
    }
}

final class ImagingService: ImagingServicing {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Discbot",
        category: "ImagingService"
    )

    final class ImagingControl {
        private enum CancellationScope {
            case none
            case currentDisc
            case all
        }

        private let lock = NSLock()
        private var process: Process?
        private var paused = false
        private var cancellationScope: CancellationScope = .none

        var isPaused: Bool {
            lock.lock()
            defer { lock.unlock() }
            return paused
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationScope != .none
        }

        var isBatchCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationScope == .all
        }

        func checkCancellation() throws {
            if isCancelled { throw ImagingError.cancelled }
        }

        func attach(process: Process?) {
            lock.lock()
            self.process = process
            let shouldPause = paused
            let wasCancelled = cancellationScope != .none
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
            cancellationScope = .all
            let wasPaused = paused
            paused = false
            let process = self.process
            lock.unlock()

            if wasPaused, let process = process {
                _ = kill(process.processIdentifier, SIGCONT)
            }
            process?.terminate()
        }

        func cancelCurrentDisc() {
            lock.lock()
            if cancellationScope != .all {
                cancellationScope = .currentDisc
            }
            let wasPaused = paused
            paused = false
            let process = self.process
            lock.unlock()

            if wasPaused, let process = process {
                _ = kill(process.processIdentifier, SIGCONT)
            }
            process?.terminate()
        }

        /// Clears a disc-scoped cancellation after its partial output has
        /// been removed and the disc is ready to be returned. A batch-scoped
        /// cancellation is deliberately never consumed here.
        func consumeCurrentDiscCancellation() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard cancellationScope == .currentDisc else { return false }
            cancellationScope = .none
            return true
        }

        func reset() {
            lock.lock()
            paused = false
            cancellationScope = .none
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
            guard process.discbotWaitUntilExit(timeout: 5),
                  process.terminationStatus == 0 else { return nil }

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
        // Use diskutil's property list so drive capabilities (for example a
        // CD drive that can also read DVDs) cannot be mistaken for the media
        // that is actually loaded. In particular, this identifies cddafs
        // without opening the raw FireWire BSD device.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", bsdName]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            guard process.discbotWaitUntilExit(timeout: 5) else {
                throw ImagingError.timeout
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let type = Self.discType(fromDiskutilInfo: data) { return type }
        } catch {
            // Ignore errors
        }

        // The published CD TOC is the fallback for media that diskutil cannot
        // classify (notably mixed-mode CDs). NativeRawCDReader only reads that
        // IORegistry property here; the raw descriptor is opened lazily if a
        // caller later requests sectors.
        if let cdType = RawCDImageService.detectDiscType(bsdName: bsdName) {
            return cdType
        }

        return .unknown
    }

    /// Parse only media-specific fields from `diskutil info -plist`.
    /// `OpticalDeviceType` deliberately is not consulted because it describes
    /// the drive's capabilities, not the disc currently in the drive.
    static func discType(fromDiskutilInfo data: Data) -> DiscType? {
        guard
            let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let info = propertyList as? [String: Any]
        else { return nil }

        func normalized(_ key: String) -> String {
            (info[key] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }

        let filesystemName = normalized("FilesystemName")
        let filesystemType = normalized("FilesystemType")
        let filesystemVisibleName = normalized("FilesystemUserVisibleName")
        let content = normalized("Content")
        let opticalMediaType = normalized("OpticalMediaType")
        let volumeName = normalized("VolumeName")

        if filesystemName == "CD-DA"
            || filesystemType == "CDDAFS"
            || filesystemVisibleName == "CD AUDIO"
            || content == "CD_DA"
            || volumeName == "AUDIO CD"
        {
            return .audioCDDA
        }
        if opticalMediaType.hasPrefix("DVD") || content.hasPrefix("DVD") {
            return .dvd
        }
        if opticalMediaType.hasPrefix("CD")
            || content.hasPrefix("CD_")
            || filesystemName.contains("ISO 9660")
            || filesystemType == "CD9660"
        {
            return .dataCD
        }
        return nil
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
        let isoPath = outputBase.appendingPathExtension("iso")
        let temporaryBase = outputBase
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputBase.lastPathComponent).\(UUID().uuidString).partial")
        let temporaryCDR = temporaryBase.appendingPathExtension("cdr")
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: isoPath.path) else {
            throw ImagingError.writeFailed(isoPath)
        }
        defer {
            if fileManager.fileExists(atPath: temporaryCDR.path) {
                try? fileManager.removeItem(at: temporaryCDR)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "create",
            "-srcdevice", "/dev/\(bsdName)",
            "-format", "UDTO",
            "-puppetstrings",
            "-o", temporaryBase.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Monitor progress via puppetstrings output
        let progressQueue = DispatchQueue(label: "imaging.progress")
        let startTime = Date()
        var outputBuffer = ""
        var outputTail: [String] = []
        let maxOutputTailLines = 60
        let outputTailLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let line = String(data: data, encoding: .utf8) {
                outputBuffer.append(line)
                let components = outputBuffer.components(separatedBy: "\n")
                outputBuffer = components.last ?? ""

                // Parse puppetstrings format: PERCENT:n.n
                for component in components.dropLast() {
                    let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        outputTailLock.lock()
                        outputTail.append(trimmed)
                        if outputTail.count > maxOutputTailLines {
                            outputTail.removeFirst(outputTail.count - maxOutputTailLines)
                        }
                        outputTailLock.unlock()
                    }

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

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            os_log(
                "createISOImage failed to launch hdiutil for %{public}@: %{public}@",
                log: Self.log,
                type: .error,
                bsdName,
                error.localizedDescription
            )
            throw error
        }
        control?.attach(process: process)
        process.waitUntilExit()
        control?.attach(process: nil)

        pipe.fileHandleForReading.readabilityHandler = nil

        if control?.isCancelled == true {
            throw ImagingError.cancelled
        }

        guard process.terminationStatus == 0 else {
            outputTailLock.lock()
            let tailSnapshot = outputTail
            outputTailLock.unlock()
            let diagnostics = tailSnapshot
                .filter { !$0.hasPrefix("PERCENT:") }
                .suffix(12)
                .joined(separator: " | ")
            let reason = diagnostics.isEmpty ? "hdiutil failed" : "hdiutil failed: \(diagnostics)"
            os_log(
                "createISOImage failed for %{public}@: status=%{public}d %{public}@",
                log: Self.log,
                type: .error,
                bsdName,
                process.terminationStatus,
                reason
            )
            throw ImagingError.processFailed(process.terminationStatus, reason)
        }

        // UDTO is an ISO payload with a .cdr suffix. Publish only after hdiutil
        // has completed successfully so cancellation never leaves a final-named file.
        guard fileManager.fileExists(atPath: temporaryCDR.path) else {
            throw ImagingError.writeFailed(temporaryCDR)
        }
        try fileManager.moveItem(at: temporaryCDR, to: isoPath)

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

    /// Create a lossless BIN/CUE image from complete 2,352-byte CD sectors.
    func createBINCUEImage(
        bsdName: String,
        outputPath: URL,
        totalBytes: Int64? = nil,
        control: ImagingControl? = nil,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        return try RawCDImageService.createImage(
            bsdName: bsdName,
            outputPath: outputPath,
            control: control,
            progress: progress
        )
    }

    /// Archive Catalina's cddafs track files as a lossless, portable ZIP.
    /// The Sony FireWire bridge can deadlock during raw BSD-device open, while
    /// cddafs is Apple's supported audio-CD path and exposes the same 16-bit,
    /// 44.1 kHz PCM audio as AIFF files with track boundaries preserved.
    func createCDDAArchive(
        bsdName: String,
        outputPath: URL,
        totalBytes: Int64? = nil,
        control: ImagingControl? = nil,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        if control?.isCancelled == true { throw ImagingError.cancelled }

        let fileManager = FileManager.default

        func currentMountURL() -> URL? {
            guard let pointer = mount_get_mount_point(bsdName) else { return nil }
            let path = String(cString: pointer)
            free(UnsafeMutableRawPointer(mutating: pointer))
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }

        guard currentMountURL() != nil else { throw ImagingError.discNotReady }

        let outputBase = outputPath.deletingPathExtension()
        let archiveURL = outputBase.appendingPathExtension("zip")
        let temporaryURL = outputBase
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputBase.lastPathComponent).\(UUID().uuidString).partial.zip")
        let zipWorkingURL = outputBase
            .deletingLastPathComponent()
            .appendingPathComponent(".\(outputBase.lastPathComponent).\(UUID().uuidString).zipwork", isDirectory: true)
        guard !fileManager.fileExists(atPath: archiveURL.path) else {
            throw ImagingError.writeFailed(archiveURL)
        }
        try fileManager.createDirectory(
            at: zipWorkingURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: zipWorkingURL)
        }

        // Do not enumerate cddafs with Foundation here. On Catalina,
        // URLResourceValues can issue an open that never returns on this
        // FireWire bridge even though ordinary sequential file reads work.
        // The published TOC provides an estimate without touching the mount.
        let discLayout = try? NativeRawCDReader(bsdName: bsdName).layout
        guard let layout = discLayout, !layout.tracks.isEmpty else {
            throw ImagingError.discNotReady
        }
        let trackNumbers = layout.tracks.map(\.number)
        let tocBytes = Int64(layout.sectorCount) * Int64(DISCBOT_CD_SECTOR_SIZE)
        let expectedBytes: Int64? = totalBytes ?? tocBytes
        let startedAt = Date()

        var archiveSucceeded = false
        var lastStatus: Int32 = -1
        var lastDiagnostics = "zip could not archive the audio tracks"
        for attempt in 0..<5 {
            if control?.isCancelled == true { throw ImagingError.cancelled }
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            guard let sourceURL = currentMountURL() else {
                if attempt < 4 {
                    Thread.sleep(forTimeInterval: 2)
                    continue
                }
                break
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            let trackPaths = trackNumbers.map {
                sourceURL.appendingPathComponent("\($0) Audio Track.aiff").path
            }
            // Pass every TOC-derived track path explicitly. Directory walkers
            // such as FileManager and ditto call opendir(), which Catalina's
            // cddafs can block forever on this bridge. Store mode (-0) keeps
            // the lossless PCM untouched and avoids pointless recompression.
            // zip normally hides its growing output in an unpredictable `zi*`
            // file. Give it a job-specific work directory so progress can be
            // measured and pushed to the web client while a track is reading.
            process.arguments = ["-q", "-0", "-j", "-b", zipWorkingURL.path, temporaryURL.path] + trackPaths
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw ImagingError.processFailed(-1, "Could not start the audio-CD ZIP writer: \(error.localizedDescription)")
            }
            control?.attach(process: process)
            while process.isRunning {
                if control?.isCancelled == true { process.terminate() }
                let publishedBytes = ((try? fileManager.attributesOfItem(atPath: temporaryURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
                let workingBytes = (try? fileManager.contentsOfDirectory(
                    at: zipWorkingURL,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                ))?.reduce(Int64(0)) { largest, url in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    return max(largest, size)
                } ?? 0
                let archiveBytes = max(publishedBytes, workingBytes)
                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                let speed = archiveBytes > 0 ? Double(archiveBytes) / elapsed : nil
                let fraction = expectedBytes.map { min(Double(archiveBytes) / Double(max($0, 1)), 0.99) } ?? 0
                progress(ImagingProgressInfo(
                    fractionCompleted: fraction,
                    bytesTransferred: archiveBytes,
                    totalBytes: expectedBytes,
                    speedBytesPerSecond: speed,
                    etaSeconds: nil
                ))
                Thread.sleep(forTimeInterval: 0.25)
            }
            process.waitUntilExit()
            control?.attach(process: nil)

            if control?.isCancelled == true { throw ImagingError.cancelled }
            lastStatus = process.terminationStatus
            lastDiagnostics = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if lastStatus == 0 {
                archiveSucceeded = true
                break
            }

            // Catalina can replace a temporary direct cddafs mount with its
            // delayed /Volumes mount while the first track is opening. Remove
            // that partial archive, resolve the current mount, and retry.
            if attempt < 4 { Thread.sleep(forTimeInterval: 2) }
        }
        guard archiveSucceeded else {
            throw ImagingError.processFailed(
                lastStatus,
                lastDiagnostics.isEmpty ? "zip could not archive the audio tracks" : lastDiagnostics
            )
        }
        guard
            fileManager.fileExists(atPath: temporaryURL.path),
            let archiveSize = ((try? fileManager.attributesOfItem(atPath: temporaryURL.path)[.size]) as? NSNumber)?.int64Value,
            archiveSize > 0
        else { throw ImagingError.writeFailed(temporaryURL) }

        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", temporaryURL.path]
        let listingPipe = Pipe()
        listing.standardOutput = listingPipe
        listing.standardError = FileHandle.nullDevice
        try listing.run()
        guard listing.discbotWaitUntilExit(timeout: 10) else {
            throw ImagingError.timeout
        }
        guard listing.terminationStatus == 0 else {
            throw ImagingError.processFailed(listing.terminationStatus, "Could not inspect the audio-CD ZIP")
        }
        let memberNames = String(
            data: listingPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.lowercased() ?? ""
        guard memberNames.contains(".aiff") || memberNames.contains(".aif") else {
            throw ImagingError.processFailed(-1, "The audio-CD ZIP contains no AIFF tracks")
        }

        // Test the central directory and every member before publishing the
        // final name, so a damaged/partial ZIP is never recorded as complete.
        let validation = Process()
        validation.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        validation.arguments = ["-tqq", temporaryURL.path]
        validation.standardOutput = FileHandle.nullDevice
        validation.standardError = FileHandle.nullDevice
        try validation.run()
        guard validation.discbotWaitUntilExit(timeout: 120) else {
            throw ImagingError.timeout
        }
        guard validation.terminationStatus == 0 else {
            throw ImagingError.processFailed(validation.terminationStatus, "Audio-CD ZIP validation failed")
        }

        try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        progress(ImagingProgressInfo(
            fractionCompleted: 1,
            bytesTransferred: expectedBytes ?? archiveSize,
            totalBytes: expectedBytes,
            speedBytesPerSecond: Double(expectedBytes ?? archiveSize) / elapsed,
            etaSeconds: 0
        ))
        return archiveURL
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
        try createImage(
            bsdName: bsdName,
            discType: discType,
            outputMode: .automatic,
            outputPath: outputPath,
            totalBytes: totalBytes,
            control: control,
            progress: progress
        )
    }

    func createImage(
        bsdName: String,
        discType: DiscType,
        outputMode: RipOutputMode,
        outputPath: URL,
        totalBytes: Int64? = nil,
        control: ImagingControl? = nil,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        switch discType {
        case .audioCDDA:
            return try createCDDAArchive(
                bsdName: bsdName,
                outputPath: outputPath,
                totalBytes: totalBytes,
                control: control,
                progress: progress
            )

        case .mixedModeCD:
            throw ImagingError.unsupportedDiscType(
                "Mixed-mode CD raw imaging is disabled on this Sony FireWire bridge because the raw-device open can lock the changer"
            )

        case .dvd:
            return try createDVDImage(
                bsdName: bsdName,
                outputMode: outputMode,
                outputPath: outputPath,
                totalBytes: totalBytes,
                control: control,
                progress: progress
            )

        case .dataCD, .unknown:
            return try createISOImage(
                bsdName: bsdName,
                outputPath: outputPath,
                totalBytes: totalBytes,
                control: control,
                progress: progress
            )
        }
    }

    func createBatchImage(
        bsdName: String,
        discType: DiscType,
        outputMode: RipOutputMode,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> BatchImageArtifact {
        guard discType == .dvd else {
            return .complete(try createImage(
                bsdName: bsdName,
                discType: discType,
                outputMode: outputMode,
                outputPath: outputPath,
                totalBytes: totalBytes,
                control: control,
                progress: progress
            ))
        }

        let dvdVideo = DVDVideoImagingService()
        var dvdVideoFailure: Error?
        if dvdVideo.isAvailable {
            do {
                let format: DVDVideoImagingService.OutputFormat = outputMode == .dvdFolder
                    ? .dvdFolder
                    : .iso
                let staged = try dvdVideo.stage(
                    bsdName: bsdName,
                    outputPath: outputPath,
                    volumeName: outputPath.lastPathComponent,
                    format: format,
                    totalBytes: totalBytes,
                    control: control,
                    progress: progress
                )
                return .staged(StagedImageArtifact(
                    expectedFinalURL: staged.expectedFinalURL,
                    finalize: { finalizationControl in
                        try staged.finalize(control: finalizationControl)
                    },
                    discard: {
                        staged.discard()
                    }
                ))
            } catch ImagingError.cancelled {
                throw ImagingError.cancelled
            } catch {
                // A plain data DVD cannot be mirrored through dvdbackup.
                // Its block-image fallback still needs the physical disc.
                dvdVideoFailure = error
            }
        }

        do {
            return .complete(try createISOImage(
                bsdName: bsdName,
                outputPath: outputPath,
                totalBytes: totalBytes,
                control: control,
                progress: progress
            ))
        } catch ImagingError.cancelled {
            throw ImagingError.cancelled
        } catch {
            throw combinedDVDError(dvdVideoFailure: dvdVideoFailure, fallbackError: error)
        }
    }

    private func createDVDImage(
        bsdName: String,
        outputMode: RipOutputMode,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        let dvdVideo = DVDVideoImagingService()
        var dvdVideoFailure: Error?

        if dvdVideo.isAvailable {
            do {
                if outputMode == .dvdFolder {
                    return try dvdVideo.createDVDMediaFolder(
                        bsdName: bsdName,
                        outputPath: outputPath,
                        volumeName: outputPath.lastPathComponent,
                        totalBytes: totalBytes,
                        control: control,
                        progress: progress
                    )
                } else {
                    return try dvdVideo.createISO(
                        bsdName: bsdName,
                        outputPath: outputPath,
                        volumeName: outputPath.lastPathComponent,
                        totalBytes: totalBytes,
                        control: control,
                        progress: progress
                    )
                }
            } catch ImagingError.cancelled {
                throw ImagingError.cancelled
            } catch {
                // A plain data DVD is not a DVD-Video title. Preserve support
                // for it by falling through to Apple's block-image path.
                dvdVideoFailure = error
            }
        }

        do {
            return try createISOImage(
                bsdName: bsdName,
                outputPath: outputPath,
                totalBytes: totalBytes,
                control: control,
                progress: progress
            )
        } catch ImagingError.cancelled {
            throw ImagingError.cancelled
        } catch {
            throw combinedDVDError(dvdVideoFailure: dvdVideoFailure, fallbackError: error)
        }
    }

    private func combinedDVDError(dvdVideoFailure: Error?, fallbackError: Error) -> Error {
        let message = fallbackError.localizedDescription
        let permissionDenied = message.range(
            of: "permission denied",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        if let dvdVideoFailure = dvdVideoFailure {
            return ImagingError.processFailed(
                -1,
                "CSS-aware DVD copy failed: \(dvdVideoFailure.localizedDescription). "
                    + "The data-DVD fallback also failed: \(message)"
            )
        }
        if permissionDenied {
            return ImagingError.unsupportedDiscType(
                "This appears to be a CSS-protected DVD-Video disc. Run Scripts/install-dvd-video-support.sh on the changer Mac, restart Discbot, and retry"
            )
        }
        return fallbackError
    }
}

// MARK: - Mock Imaging Service

final class MockImagingService: ImagingServicing {
    /// Simulated disc catalog for variety
    private struct MockDisc {
        let volumeName: String
        let discType: DiscType
        let sizeBytes: Int64
    }

    /// Seeded RNG so mock data is deterministic per slot
    private let mockDiscs: [MockDisc] = [
        MockDisc(volumeName: "PLANET_EARTH_S1D1", discType: .dvd, sizeBytes: 4_700_000_000),
        MockDisc(volumeName: "Abbey_Road", discType: .audioCDDA, sizeBytes: 320_000_000),
        MockDisc(volumeName: "OFFICE_BACKUP_2019", discType: .dataCD, sizeBytes: 680_000_000),
        MockDisc(volumeName: "The_Dark_Knight", discType: .dvd, sizeBytes: 7_900_000_000),
        MockDisc(volumeName: "Kind_of_Blue", discType: .audioCDDA, sizeBytes: 280_000_000),
        MockDisc(volumeName: "PHOTOS_CHRISTMAS_2020", discType: .dataCD, sizeBytes: 450_000_000),
        MockDisc(volumeName: "Breaking_Bad_S3D2", discType: .dvd, sizeBytes: 6_200_000_000),
        MockDisc(volumeName: "Rumours", discType: .audioCDDA, sizeBytes: 310_000_000),
        MockDisc(volumeName: "SW_INSTALL_DISC", discType: .dataCD, sizeBytes: 700_000_000),
        MockDisc(volumeName: "Interstellar", discType: .dvd, sizeBytes: 8_500_000_000),
        MockDisc(volumeName: "Thriller", discType: .audioCDDA, sizeBytes: 290_000_000),
        MockDisc(volumeName: "TAX_RECORDS_2021", discType: .dataCD, sizeBytes: 210_000_000),
        MockDisc(volumeName: "Seinfeld_S4D3", discType: .dvd, sizeBytes: 4_300_000_000),
        MockDisc(volumeName: "The_Wall", discType: .audioCDDA, sizeBytes: 480_000_000),
        MockDisc(volumeName: "HOME_VIDEOS_2018", discType: .dvd, sizeBytes: 3_800_000_000),
        MockDisc(volumeName: "OK_Computer", discType: .audioCDDA, sizeBytes: 330_000_000),
        MockDisc(volumeName: "DRIVER_DISC_HP", discType: .dataCD, sizeBytes: 150_000_000),
        MockDisc(volumeName: "Jurassic_Park", discType: .dvd, sizeBytes: 7_100_000_000),
        MockDisc(volumeName: "Blue_Train", discType: .audioCDDA, sizeBytes: 250_000_000),
        MockDisc(volumeName: "Blade_Runner_2049", discType: .dvd, sizeBytes: 8_200_000_000),
    ]

    /// Imaging speed simulation: ~2-6 seconds per disc (fast enough for demo, slow enough to see progress)
    private let imageDurationRange: ClosedRange<Double>

    init(imageDurationRange: ClosedRange<Double> = 2.0...6.0) {
        self.imageDurationRange = imageDurationRange
    }

    private func mockDisc(for bsdName: String) -> MockDisc {
        // Extract serial from bsdName like "mockdisk42" to pick a deterministic disc
        let serial = Int(bsdName.filter { $0.isNumber }) ?? 0
        return mockDiscs[max(serial - 1, 0) % mockDiscs.count]
    }

    func estimateDiscSizeBytes(bsdName: String) -> Int64? {
        return mockDisc(for: bsdName).sizeBytes
    }

    func detectDiscType(bsdName: String) -> DiscType {
        return mockDisc(for: bsdName).discType
    }

    func createImage(
        bsdName: String,
        discType: DiscType,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        let disc = mockDisc(for: bsdName)
        let totalSize = totalBytes ?? disc.sizeBytes
        let duration = Double.random(in: imageDurationRange)
        let steps = 50
        let stepInterval = duration / Double(steps)
        let startTime = Date()

        for i in 1...steps {
            if control?.isCancelled == true {
                throw ImagingError.cancelled
            }

            // Pause support
            while control?.isPaused == true {
                Thread.sleep(forTimeInterval: 0.1)
                if control?.isCancelled == true {
                    throw ImagingError.cancelled
                }
            }

            Thread.sleep(forTimeInterval: stepInterval)

            let fraction = Double(i) / Double(steps)
            let transferred = Int64(Double(totalSize) * fraction)
            let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
            let speed = Double(transferred) / elapsed
            let remaining = totalSize - transferred
            let eta = speed > 0 ? Double(remaining) / speed : nil

            progress(ImagingProgressInfo(
                fractionCompleted: fraction,
                bytesTransferred: transferred,
                totalBytes: totalSize,
                speedBytesPerSecond: speed,
                etaSeconds: eta
            ))
        }

        // Create a tiny placeholder file so the path exists
        let isoPath = outputPath.deletingPathExtension().appendingPathExtension("iso")
        FileManager.default.createFile(atPath: isoPath.path, contents: "MOCK ISO".data(using: .utf8))

        return isoPath
    }
}
