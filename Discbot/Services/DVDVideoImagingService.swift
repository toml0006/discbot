//
//  DVDVideoImagingService.swift
//  Discbot
//
//  CSS-aware DVD-Video copying through an isolated external helper.
//

import Foundation
import Darwin

final class DVDVideoImagingService {
    struct ToolInstallation: Equatable {
        let executable: URL
        let libraryDirectory: URL?
    }

    enum DVDVideoError: LocalizedError {
        case toolUnavailable
        case copyFailed(Int32, String)
        case isoCreationFailed(Int32, String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .toolUnavailable:
                return "Protected DVD support is not installed. Run Scripts/install-dvd-video-support.sh on the Mac connected to the changer, then restart Discbot."
            case .copyFailed(let status, let detail):
                return "DVD-Video copy failed (code \(status)): \(detail)"
            case .isoCreationFailed(let status, let detail):
                return "DVD ISO creation failed (code \(status)): \(detail)"
            case .invalidOutput(let detail):
                return "DVD imaging produced an invalid result: \(detail)"
            }
        }
    }

    enum OutputFormat: Equatable {
        case iso
        case dvdFolder

        var pathExtension: String {
            switch self {
            case .iso: return "iso"
            case .dvdFolder: return "dvdmedia"
            }
        }
    }

    final class StagedCopy {
        let expectedFinalURL: URL

        private let service: DVDVideoImagingService
        private let workRoot: URL
        private let copiedRoot: URL
        private let format: OutputFormat
        private let volumeName: String
        private let totalBytes: Int64?
        private let stagedBesideDestination: Bool
        private let lock = NSLock()
        private var consumed = false

        fileprivate init(
            service: DVDVideoImagingService,
            workRoot: URL,
            copiedRoot: URL,
            expectedFinalURL: URL,
            format: OutputFormat,
            volumeName: String,
            totalBytes: Int64?,
            stagedBesideDestination: Bool
        ) {
            self.service = service
            self.workRoot = workRoot
            self.copiedRoot = copiedRoot
            self.expectedFinalURL = expectedFinalURL
            self.format = format
            self.volumeName = volumeName
            self.totalBytes = totalBytes
            self.stagedBesideDestination = stagedBesideDestination
        }

        func finalize(
            control: ImagingService.ImagingControl?,
            phaseRange: ClosedRange<Double> = 0...1,
            progress: @escaping (ImagingProgressInfo) -> Void = { _ in }
        ) throws -> URL {
            lock.lock()
            guard !consumed else {
                lock.unlock()
                throw DVDVideoError.invalidOutput("the staged DVD was already finalized or discarded")
            }
            consumed = true
            lock.unlock()
            defer { try? service.fileManager.removeItem(at: workRoot) }
            return try service.finalize(
                copiedRoot: copiedRoot,
                workRoot: workRoot,
                finalURL: expectedFinalURL,
                format: format,
                volumeName: volumeName,
                totalBytes: totalBytes,
                stagedBesideDestination: stagedBesideDestination,
                control: control,
                phaseRange: phaseRange,
                progress: progress
            )
        }

        func discard() {
            lock.lock()
            guard !consumed else {
                lock.unlock()
                return
            }
            consumed = true
            lock.unlock()
            try? service.fileManager.removeItem(at: workRoot)
        }

        deinit {
            discard()
        }
    }

    private let fileManager: FileManager
    private let installation: ToolInstallation?

    init(
        fileManager: FileManager = .default,
        installation: ToolInstallation? = DVDVideoImagingService.locateTool()
    ) {
        self.fileManager = fileManager
        self.installation = installation
    }

    var isAvailable: Bool { installation != nil }

    static func locateTool(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleURL: URL? = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> ToolInstallation? {
        var candidates: [(URL, URL?)] = []
        if let bundleURL = bundleURL {
            candidates.append((
                bundleURL.appendingPathComponent("Contents/Helpers/DVDTools/bin/dvdbackup"),
                bundleURL.appendingPathComponent("Contents/Helpers/DVDTools/lib", isDirectory: true)
            ))
        }
        let supportRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/Discbot/DVDTools", isDirectory: true)
        candidates.append((
            supportRoot.appendingPathComponent("bin/dvdbackup"),
            supportRoot.appendingPathComponent("lib", isDirectory: true)
        ))
        candidates.append((URL(fileURLWithPath: "/usr/local/bin/dvdbackup"), nil))
        candidates.append((URL(fileURLWithPath: "/opt/local/bin/dvdbackup"), nil))

        for (executable, libraryDirectory) in candidates where fileManager.isExecutableFile(atPath: executable.path) {
            let usableLibraryDirectory = libraryDirectory.flatMap {
                fileManager.fileExists(atPath: $0.path) ? $0 : nil
            }
            return ToolInstallation(executable: executable, libraryDirectory: usableLibraryDirectory)
        }
        return nil
    }

    func createISO(
        bsdName: String,
        outputPath: URL,
        volumeName: String,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        let staged = try stage(
            bsdName: bsdName,
            outputPath: outputPath,
            volumeName: volumeName,
            format: .iso,
            totalBytes: totalBytes,
            control: control,
            phaseRange: 0...0.82,
            progress: progress
        )
        return try staged.finalize(
            control: control,
            phaseRange: 0.82...1,
            progress: progress
        )
    }

    func createDVDMediaFolder(
        bsdName: String,
        outputPath: URL,
        volumeName: String,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        let staged = try stage(
            bsdName: bsdName,
            outputPath: outputPath,
            volumeName: volumeName,
            format: .dvdFolder,
            totalBytes: totalBytes,
            control: control,
            phaseRange: 0...0.98,
            progress: progress
        )
        return try staged.finalize(
            control: control,
            phaseRange: 0.98...1,
            progress: progress
        )
    }

    func stage(
        bsdName: String,
        outputPath: URL,
        volumeName: String,
        format: OutputFormat,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        phaseRange: ClosedRange<Double> = 0...1,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> StagedCopy {
        guard let installation = installation else { throw DVDVideoError.toolUnavailable }
        if control?.isCancelled == true { throw ImagingError.cancelled }

        let finalURL = outputPath.deletingPathExtension().appendingPathExtension(format.pathExtension)
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw ImagingError.writeFailed(finalURL)
        }

        let parent = finalURL.deletingLastPathComponent()
        let destinationIsLocal = (try? parent.resourceValues(
            forKeys: [.volumeIsLocalKey]
        ).volumeIsLocal) == true
        let stagingParent: URL
        if destinationIsLocal {
            stagingParent = parent
        } else {
            stagingParent = fileManager.temporaryDirectory
                .appendingPathComponent("Discbot-DVD-Staging", isDirectory: true)
            try fileManager.createDirectory(
                at: stagingParent,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        // ISO construction temporarily holds both VIDEO_TS and the ISO.
        // Reserve a conservative dual-layer estimate when capacity is unknown.
        let sourceBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil } ?? 8_600_000_000
        let multiplier: Int64 = format == .iso ? 2 : 1
        let reserve: Int64 = 512 * 1024 * 1024
        guard sourceBytes <= (Int64.max - reserve) / multiplier else {
            throw DVDVideoError.invalidOutput("invalid DVD size estimate")
        }
        let requiredBytes = sourceBytes * multiplier + reserve
        if let capacity = try? stagingParent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = capacity.volumeAvailableCapacityForImportantUsage,
           available < requiredBytes {
            throw DVDVideoError.invalidOutput("not enough local staging space for this DVD")
        }
        let workRoot = stagingParent.appendingPathComponent(
            ".\(finalURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).dvd-partial",
            isDirectory: true
        )
        let copiedRoot = workRoot.appendingPathComponent("DVD", isDirectory: true)
        try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: false, attributes: nil)
        var keepStaging = false
        defer {
            if !keepStaging { try? fileManager.removeItem(at: workRoot) }
        }

        let copyProcess = Process()
        copyProcess.executableURL = installation.executable
        // libdvdcss performs its own sector reads and should use Darwin's raw
        // character device. The block device remains reserved for hdiutil.
        let rawBSDName = bsdName.hasPrefix("r") ? bsdName : "r\(bsdName)"
        copyProcess.arguments = [
            "--mirror",
            "--progress",
            "--input=/dev/\(rawBSDName)",
            "--output=\(workRoot.path)",
            "--name=DVD"
        ]
        var environment = ProcessInfo.processInfo.environment
        if let libraryDirectory = installation.libraryDirectory {
            let existing = environment["DYLD_LIBRARY_PATH"].flatMap { $0.isEmpty ? nil : $0 }
            environment["DYLD_LIBRARY_PATH"] = ([libraryDirectory.path] + (existing.map { [$0] } ?? []))
                .joined(separator: ":")
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Discbot/dvdcss", isDirectory: true)
        try? fileManager.createDirectory(at: cache, withIntermediateDirectories: true, attributes: nil)
        environment["DVDCSS_CACHE"] = cache.path
        environment["LC_ALL"] = "C"
        copyProcess.environment = environment

        let copyResult = try run(
            copyProcess,
            control: control,
            phaseRange: phaseRange,
            totalBytes: totalBytes,
            observedBytes: { [weak self] in self?.directorySize(at: workRoot) },
            progress: progress
        )
        guard copyResult.status == 0 else {
            throw DVDVideoError.copyFailed(copyResult.status, copyResult.diagnostics)
        }
        guard fileManager.fileExists(atPath: copiedRoot.appendingPathComponent("VIDEO_TS").path) else {
            throw DVDVideoError.invalidOutput("the copied disc has no VIDEO_TS folder")
        }
        guard let copiedSize = directorySize(at: copiedRoot), copiedSize > 1_048_576 else {
            throw DVDVideoError.invalidOutput("the copied VIDEO_TS folder is unexpectedly small")
        }

        keepStaging = true
        return StagedCopy(
            service: self,
            workRoot: workRoot,
            copiedRoot: copiedRoot,
            expectedFinalURL: finalURL,
            format: format,
            volumeName: volumeName,
            totalBytes: totalBytes,
            stagedBesideDestination: destinationIsLocal
        )
    }

    private func finalize(
        copiedRoot: URL,
        workRoot: URL,
        finalURL: URL,
        format: OutputFormat,
        volumeName: String,
        totalBytes: Int64?,
        stagedBesideDestination: Bool,
        control: ImagingService.ImagingControl?,
        phaseRange: ClosedRange<Double>,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        if control?.isCancelled == true { throw ImagingError.cancelled }
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw ImagingError.writeFailed(finalURL)
        }

        let source: URL
        switch format {
        case .iso:
            let temporaryISO = workRoot.appendingPathComponent("image.iso")
            let hybrid = Process()
            hybrid.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            hybrid.arguments = [
                "makehybrid",
                "-udf",
                "-udf-volume-name", Self.sanitizedVolumeName(volumeName),
                "-o", temporaryISO.path,
                copiedRoot.path
            ]
            let hybridResult = try run(
                hybrid,
                control: control,
                phaseRange: phaseRange,
                totalBytes: totalBytes,
                progress: progress
            )
            guard hybridResult.status == 0 else {
                throw DVDVideoError.isoCreationFailed(hybridResult.status, hybridResult.diagnostics)
            }

            guard let attributes = try? fileManager.attributesOfItem(atPath: temporaryISO.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 1_048_576 else {
                throw DVDVideoError.invalidOutput("the ISO file is missing or unexpectedly small")
            }
            source = temporaryISO
        case .dvdFolder:
            source = copiedRoot
        }

        try publish(source: source, to: finalURL, stagedBesideDestination: stagedBesideDestination, control: control)
        let finalSize: Int64
        if format == .dvdFolder {
            finalSize = directorySize(at: finalURL) ?? 0
        } else {
            let attributes = try? fileManager.attributesOfItem(atPath: finalURL.path)
            finalSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard finalSize > 1_048_576 else {
            try? fileManager.removeItem(at: finalURL)
            throw DVDVideoError.invalidOutput("the published DVD is unexpectedly small")
        }
        progress(ImagingProgressInfo(
            fractionCompleted: 1,
            bytesTransferred: totalBytes ?? finalSize,
            totalBytes: totalBytes,
            speedBytesPerSecond: nil,
            etaSeconds: 0
        ))
        return finalURL
    }

    private func publish(
        source: URL, to finalURL: URL, stagedBesideDestination: Bool,
        control: ImagingService.ImagingControl?
    ) throws {
        try control?.checkCancellation()
        if stagedBesideDestination {
            try fileManager.moveItem(at: source, to: finalURL)
            return
        }

        let partial = finalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalURL.lastPathComponent).\(UUID().uuidString).partial",
            isDirectory: finalURL.pathExtension.lowercased() == "dvdmedia"
        )
        defer { try? fileManager.removeItem(at: partial) }
        try Self.copyArtifact(from: source, to: partial) { try control?.checkCancellation() }
        try control?.checkCancellation()
        try fileManager.moveItem(at: partial, to: finalURL)
    }

    /// Copy in bounded chunks so cancellation releases partial network output.
    /// A single filesystem syscall may still wait for the OS's network timeout.
    static func copyArtifact(
        from source: URL, to destination: URL,
        checkCancellation: () throws -> Void
    ) throws {
        try checkCancellation()
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        var completed = false
        var created = false
        defer { if created && !completed { try? manager.removeItem(at: destination) } }
        if values.isDirectory == true {
            try manager.createDirectory(at: destination, withIntermediateDirectories: false)
            created = true
            for child in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyArtifact(
                    from: child, to: destination.appendingPathComponent(child.lastPathComponent),
                    checkCancellation: checkCancellation
                )
            }
        } else {
            guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let input = try FileHandle(forReadingFrom: source)
            defer { input.closeFile() }
            let attributes = try manager.attributesOfItem(atPath: source.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            let descriptor = Darwin.open(destination.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(permissions & 0o777))
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            created = true
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { output.closeFile() }
            while true {
                try checkCancellation()
                let data = try RipArtifactInspector.readChunk(from: input, checkCancellation: checkCancellation)
                if data.isEmpty { break }
                try checkCancellation()
                try RipArtifactInspector.writeChunk(data, to: output, checkCancellation: checkCancellation)
            }
        }
        try checkCancellation()
        completed = true
    }

    private struct ProcessResult {
        let status: Int32
        let diagnostics: String
    }

    private func run(
        _ process: Process,
        control: ImagingService.ImagingControl?,
        phaseRange: ClosedRange<Double>,
        totalBytes: Int64?,
        observedBytes: (() -> Int64?)? = nil,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> ProcessResult {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lock = NSLock()
        var buffered = ""
        var tail: [String] = []
        let startedAt = Date()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            buffered.append(text)
            let lines = buffered.components(separatedBy: .newlines)
            buffered = lines.last ?? ""
            for line in lines.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                tail.append(trimmed)
                if tail.count > 80 { tail.removeFirst(tail.count - 80) }
                // dvdbackup reports progress independently for each VOB, so
                // those percentages repeatedly restart from zero. When the
                // caller can observe aggregate output bytes, that measurement
                // is the authoritative whole-disc progress source.
                if observedBytes == nil, let percent = Self.percentage(in: trimmed) {
                    let phase = phaseRange.lowerBound
                        + ((phaseRange.upperBound - phaseRange.lowerBound) * percent)
                    let transferred = Int64(Double(totalBytes ?? 0) * phase)
                    let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                    let speed = transferred > 0 ? Double(transferred) / elapsed : nil
                    let eta: TimeInterval?
                    if let value = speed, let totalBytes = totalBytes, value > 0 {
                        eta = max(Double(totalBytes - transferred) / value, 0)
                    } else {
                        eta = nil
                    }
                    DispatchQueue.main.async {
                        progress(ImagingProgressInfo(
                            fractionCompleted: phase,
                            bytesTransferred: transferred,
                            totalBytes: totalBytes,
                            speedBytesPerSecond: speed,
                            etaSeconds: eta
                        ))
                    }
                }
            }
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        control?.attach(process: process)
        while process.isRunning {
            if let observed = observedBytes?(),
               let totalBytes = totalBytes,
               totalBytes > 0 {
                let copyFraction = min(max(Double(observed) / Double(totalBytes), 0), 1)
                let phase = phaseRange.lowerBound
                    + ((phaseRange.upperBound - phaseRange.lowerBound) * copyFraction)
                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                let speed = observed > 0 ? Double(observed) / elapsed : nil
                let eta = speed.flatMap { value in
                    value > 0 ? max(Double(totalBytes - observed) / value, 0) : nil
                }
                DispatchQueue.main.async {
                    progress(ImagingProgressInfo(
                        fractionCompleted: phase,
                        bytesTransferred: observed,
                        totalBytes: totalBytes,
                        speedBytesPerSecond: speed,
                        etaSeconds: eta
                    ))
                }
            }
            Thread.sleep(forTimeInterval: 0.75)
        }
        process.waitUntilExit()
        control?.attach(process: nil)
        pipe.fileHandleForReading.readabilityHandler = nil
        if control?.isCancelled == true { throw ImagingError.cancelled }

        lock.lock()
        if !buffered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tail.append(buffered.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let diagnostic = tail.suffix(14).joined(separator: " | ")
        lock.unlock()
        return ProcessResult(
            status: process.terminationStatus,
            diagnostics: diagnostic.isEmpty ? "no diagnostic output" : diagnostic
        )
    }

    private func directorySize(at root: URL) -> Int64? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    static func percentage(in line: String) -> Double? {
        let pattern = #"(?<![0-9])([0-9]{1,3}(?:\.[0-9]+)?)%"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let range = Range(match.range(at: 1), in: line),
              let value = Double(line[range]) else { return nil }
        return min(max(value / 100, 0), 1)
    }

    static func sanitizedVolumeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_ -"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((result.isEmpty ? "DVD_VIDEO" : result).prefix(32))
    }
}
