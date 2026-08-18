//
//  BatchOperationState.swift
//  Discbot
//
//  State for batch operations (Load All, Image All)
//

import Foundation
import Combine
import os.log

final class BatchOperationState: ObservableObject {
    enum OperationType: Equatable {
        case loadAll
        case imageAll(outputDirectory: URL)
        case scanUnknown
    }

    @Published var operationType: OperationType?
    @Published var isRunning = false
    @Published var isCancelled = false
    @Published var isPaused = false
    @Published var currentIndex = 0
    @Published var totalCount = 0
    @Published var currentSlot: Int = 0
    @Published var statusText: String = ""
    @Published var completedSlots: [Int] = []
    @Published var failedSlots: [(slot: Int, error: String)] = []
    @Published var skippedSlots: [(slot: Int, existingPath: String)] = []
    @Published var replacedSlots: [Int] = []
    @Published var haltReason: String?

    // Imaging specific
    @Published var currentDiscMetadata: DiscMetadata?
    @Published var imagingProgress: Double = 0
    @Published var currentDiscName: String?
    @Published var currentDiscTransferredBytes: Int64 = 0
    @Published var currentDiscTotalBytes: Int64?
    @Published var currentDiscSpeedBytesPerSecond: Double = 0
    @Published var currentDiscETASeconds: TimeInterval?
    @Published var overallTransferredBytes: Int64 = 0
    @Published var overallEstimatedTotalBytes: Int64?
    @Published var overallETASeconds: TimeInterval?
    @Published var averageDiscOperationSeconds: TimeInterval?

    private let imagingControl = ImagingService.ImagingControl()
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Discbot",
        category: "BatchOperation"
    )

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1.0, max(0.0, (Double(currentIndex) + imagingProgress) / Double(totalCount)))
    }

    var isComplete: Bool {
        !isRunning && (currentIndex >= totalCount || haltReason != nil)
    }

    func cancel() {
        isCancelled = true
        isPaused = false
        imagingControl.cancel()
    }

    func pauseImaging() {
        guard case .imageAll = operationType else { return }
        guard isRunning else { return }
        isPaused = true
        imagingControl.setPaused(true)
    }

    func resumeImaging() {
        guard case .imageAll = operationType else { return }
        guard isRunning else { return }
        isPaused = false
        imagingControl.setPaused(false)
    }

    func reset() {
        operationType = nil
        isRunning = false
        isCancelled = false
        isPaused = false
        currentIndex = 0
        totalCount = 0
        currentSlot = 0
        statusText = ""
        completedSlots = []
        failedSlots = []
        skippedSlots = []
        replacedSlots = []
        haltReason = nil
        currentDiscMetadata = nil
        imagingProgress = 0
        currentDiscName = nil
        currentDiscTransferredBytes = 0
        currentDiscTotalBytes = nil
        currentDiscSpeedBytesPerSecond = 0
        currentDiscETASeconds = nil
        overallTransferredBytes = 0
        overallEstimatedTotalBytes = nil
        overallETASeconds = nil
        averageDiscOperationSeconds = nil
        imagingControl.reset()
    }

    private func mountDiscIfAvailable(
        bsdName: String,
        mountService: MountServicing,
        allowMountless: Bool,
        preferPrivateAudioMount: Bool = false
    ) throws -> String? {
        if preferPrivateAudioMount {
            return try mountService.mountAudioDisc(bsdName: bsdName, timeout: 45)
        }
        if let existing = mountService.getMountPoint(bsdName: bsdName) {
            return existing
        }

        do {
            return try mountService.mountDisc(bsdName: bsdName)
        } catch let error as ChangerError {
            if
                allowMountless,
                case .mountFailed(let reason) = error,
                reason == "No mount point returned"
            {
                // Some optical media genuinely has no mountable filesystem.
                return mountService.getMountPoint(bsdName: bsdName)
            }
            throw error
        }
    }

    private func logFailure(_ context: String, slot: Int? = nil, error: Error) {
        if let slot = slot {
            os_log(
                "%{public}@ failed for slot %{public}d: %{public}@",
                log: Self.log,
                type: .error,
                context,
                slot,
                error.localizedDescription
            )
        } else {
            os_log(
                "%{public}@ failed: %{public}@",
                log: Self.log,
                type: .error,
                context,
                error.localizedDescription
            )
        }
    }

    /// Run batch load operation on background thread
    func runLoadAll(
        slots: [Slot],
        changerService: ChangerServicing,
        mountService: MountServicing,
        onUpdate: @escaping () -> Void,
        onSlotLoaded: @escaping (Int, String, String?) -> Void,
        onSlotEjected: @escaping (Int) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let occupiedSlots = slots.filter { $0.isFull && !$0.isInDrive }
        guard !occupiedSlots.isEmpty else { return }

        operationType = .loadAll
        isRunning = true
        isCancelled = false
        isPaused = false
        totalCount = occupiedSlots.count
        currentIndex = 0
        completedSlots = []
        failedSlots = []
        skippedSlots = []
        replacedSlots = []
        haltReason = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for slot in occupiedSlots {
                if self.imagingControl.isCancelled {
                    DispatchQueue.main.async {
                        self.statusText = "Cancelled after \(self.currentIndex) disc(s)"
                        onUpdate()
                    }
                    break
                }

                DispatchQueue.main.async {
                    self.currentSlot = slot.id
                    self.statusText = "Loading slot \(slot.id)..."
                    onUpdate()
                }

                do {
                    // Load disc
                    try changerService.loadSlot(slot.id)

                    DispatchQueue.main.async {
                        self.statusText = "Waiting for disc..."
                        onUpdate()
                    }

                    // Wait for disc and mount (if it has a filesystem)
                    let bsdName = try mountService.waitForDisc(timeout: 60)
                    let mountPoint = try mountDiscIfAvailable(
                        bsdName: bsdName,
                        mountService: mountService,
                        allowMountless: false
                    )

                    DispatchQueue.main.async {
                        if let mountPoint = mountPoint {
                            self.statusText = "Mounted at \(mountPoint)"
                        } else {
                            self.statusText = "Disc ready (no filesystem mount)"
                        }
                        onSlotLoaded(slot.id, bsdName, mountPoint)
                        onUpdate()
                    }

                    DispatchQueue.main.async {
                        self.statusText = "Ejecting slot \(slot.id)..."
                        onUpdate()
                    }

                    try self.releaseDiscForChanger(
                        bsdName: bsdName,
                        destinationSlot: slot.id,
                        changerService: changerService,
                        mountService: mountService
                    )

                    DispatchQueue.main.async {
                        self.completedSlots.append(slot.id)
                        onSlotEjected(slot.id)
                        onUpdate()
                    }

                } catch {
                    self.logFailure("batch load", slot: slot.id, error: error)
                    DispatchQueue.main.async {
                        self.failedSlots.append((slot.id, error.localizedDescription))
                        onUpdate()
                    }
                }

                DispatchQueue.main.async {
                    self.currentIndex += 1
                    onUpdate()
                }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                if !self.isCancelled {
                    self.statusText = "Complete: \(self.completedSlots.count) successful, \(self.failedSlots.count) failed"
                }
                onUpdate()
                onComplete()
            }
        }
    }

    /// Previous implementation retained temporarily for database migration compatibility.
    /// New callers must use the duplicate-policy overload below.
    private func legacyRunImageAll(
        slots: [Slot],
        outputDirectory: URL,
        driveFallbackSourceSlot: Int?,
        changerService: ChangerServicing,
        mountService: MountServicing,
        imagingService: ImagingServicing,
        catalogService: CatalogService,
        onUpdate: @escaping () -> Void,
        onSlotLoaded: @escaping (Int, String, String?) -> Void,
        onSlotEjected: @escaping (Int) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let occupiedSlots = slots.filter { $0.isFull || $0.isInDrive }
        guard !occupiedSlots.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            self?.operationType = .imageAll(outputDirectory: outputDirectory)
            self?.isRunning = true
            self?.isCancelled = false
            self?.isPaused = false
            self?.totalCount = occupiedSlots.count
            self?.currentIndex = 0
            self?.completedSlots = []
            self?.failedSlots = []
            self?.skippedSlots = []
            self?.haltReason = nil
            self?.imagingProgress = 0
            self?.currentDiscTransferredBytes = 0
            self?.currentDiscTotalBytes = nil
            self?.currentDiscSpeedBytesPerSecond = 0
            self?.currentDiscETASeconds = nil
            self?.overallTransferredBytes = 0
            self?.overallEstimatedTotalBytes = nil
            self?.overallETASeconds = nil
            self?.averageDiscOperationSeconds = nil
            self?.imagingControl.reset()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var completedBytes: Int64 = 0
            var knownDiscSizes: [Int64] = []

            // Eject any disc currently in the drive before starting
            do {
                let driveStatus = try? changerService.getDriveStatus()
                if driveStatus?.hasDisc == true {
                    let sourceSlot = driveStatus?.sourceSlot ?? driveFallbackSourceSlot
                    guard let sourceSlot else {
                        DispatchQueue.main.async {
                            self.isCancelled = true
                            self.statusText = "Drive contains a disc with unknown source slot. Eject it first, then retry."
                            self.failedSlots.append((0, "Drive not empty (source slot unknown)"))
                            onUpdate()
                        }
                        DispatchQueue.main.async {
                            self.isRunning = false
                            self.isPaused = false
                            onUpdate()
                            onComplete()
                        }
                        return
                    }

                    try self.releaseDiscForChanger(
                        bsdName: mountService.findDiscBSDName(),
                        destinationSlot: sourceSlot,
                        changerService: changerService,
                        mountService: mountService
                    )
                    DispatchQueue.main.async {
                        onSlotEjected(sourceSlot)
                    }
                }
            } catch {
                self.logFailure("initial eject before image-all", error: error)
                // Best effort - continue even if eject fails
            }

            for slot in occupiedSlots {
                if self.imagingControl.isCancelled {
                    DispatchQueue.main.async {
                        self.statusText = "Cancelled after \(self.currentIndex) disc(s)"
                        onUpdate()
                    }
                    break
                }

                // Track imaging path for failure recording
                var attemptedOutputPath: URL?

                DispatchQueue.main.async {
                    self.currentSlot = slot.id
                    self.statusText = "Loading slot \(slot.id)..."
                    self.imagingProgress = 0
                    onUpdate()
                }

                do {
                    // Load disc
                    try changerService.loadSlot(slot.id)

                    DispatchQueue.main.async {
                        self.statusText = "Waiting for disc..."
                        onUpdate()
                    }

                    // Wait for disc, detect media type, then mount.
                    let bsdName = try mountService.waitForDisc(timeout: 60)
                    let discType = imagingService.detectDiscType(bsdName: bsdName)
                    let mountPoint = try mountDiscIfAvailable(
                        bsdName: bsdName,
                        mountService: mountService,
                        allowMountless: (discType == .audioCDDA),
                        preferPrivateAudioMount: discType == .audioCDDA
                    )

                    DispatchQueue.main.async {
                        if mountPoint != nil {
                            self.statusText = "Mounted, detecting disc type..."
                        } else {
                            self.statusText = "Disc ready, detecting disc type..."
                        }
                        onSlotLoaded(slot.id, bsdName, mountPoint)
                        onUpdate()
                    }

                    // Get volume name for filename
                    let volumeName = mountService.getVolumeName(bsdName: bsdName) ?? "Disc_Slot\(slot.id)"
                    let safeVolumeName = volumeName.replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: ":", with: "_")
                    let estimatedSize = imagingService.estimateDiscSizeBytes(bsdName: bsdName)
                    if let estimatedSize = estimatedSize {
                        knownDiscSizes.append(estimatedSize)
                    }

                    // Record disc in catalog
                    _ = catalogService.recordDisc(
                        slotId: slot.id,
                        bsdName: bsdName,
                        discType: discType,
                        sizeBytes: estimatedSize
                    )

                    DispatchQueue.main.async {
                        self.statusText = "Imaging \(safeVolumeName)..."
                        self.currentDiscName = safeVolumeName
                        self.currentDiscTransferredBytes = 0
                        self.currentDiscTotalBytes = estimatedSize
                        self.currentDiscSpeedBytesPerSecond = 0
                        self.currentDiscETASeconds = nil
                        onUpdate()
                    }

                    // hdiutil needs block-device access. Audio CDs instead use
                    // Catalina's mounted cddafs AIFF tracks and must stay mounted.
                    if discType != .audioCDDA, mountService.isMounted(bsdName: bsdName) {
                        try mountService.unmountDisc(bsdName: bsdName, force: true)
                    }

                    // Create image
                    let outputPath = outputDirectory.appendingPathComponent(safeVolumeName)
                    attemptedOutputPath = outputPath
                    let _ = try imagingService.createImage(
                        bsdName: bsdName,
                        discType: discType,
                        outputPath: outputPath,
                        totalBytes: estimatedSize,
                        control: self.imagingControl,
                        progress: { progress in
                            DispatchQueue.main.async {
                                self.imagingProgress = progress.fractionCompleted
                                self.currentDiscTransferredBytes = progress.bytesTransferred
                                self.currentDiscTotalBytes = progress.totalBytes
                                self.currentDiscSpeedBytesPerSecond = progress.speedBytesPerSecond ?? 0
                                self.currentDiscETASeconds = progress.etaSeconds

                                let remainingAfterCurrent = max(self.totalCount - self.currentIndex - 1, 0)
                                let averageDiscSize = knownDiscSizes.isEmpty ? nil : (knownDiscSizes.reduce(Int64(0), +) / Int64(knownDiscSizes.count))
                                let estimatedRemaining = averageDiscSize.map { $0 * Int64(remainingAfterCurrent) } ?? 0
                                let totalEstimate: Int64? = {
                                    guard let estimatedSize = estimatedSize else { return nil }
                                    return completedBytes + estimatedSize + estimatedRemaining
                                }()
                                let overallTransferred = completedBytes + progress.bytesTransferred

                                self.overallTransferredBytes = overallTransferred
                                self.overallEstimatedTotalBytes = totalEstimate
                                if
                                    let totalEstimate = totalEstimate,
                                    let speed = progress.speedBytesPerSecond,
                                    speed > 0
                                {
                                    self.overallETASeconds = max(Double(totalEstimate - overallTransferred) / speed, 0)
                                } else {
                                    self.overallETASeconds = nil
                                }

                                let percent = Int(progress.fractionCompleted * 100)
                                self.statusText = self.isPaused
                                    ? "Imaging \(safeVolumeName)... paused at \(percent)%"
                                    : "Imaging \(safeVolumeName)... \(percent)%"
                                onUpdate()
                            }
                        }
                    )

                    completedBytes += estimatedSize ?? 0

                    // Record successful backup in catalog
                    let isoPath = outputPath.appendingPathExtension("iso")
                    let fileSize = try? FileManager.default.attributesOfItem(atPath: isoPath.path)[.size] as? Int64
                    catalogService.recordBackupCompleted(
                        slotId: slot.id,
                        backupPath: isoPath.path,
                        backupSizeBytes: fileSize
                    )

                    DispatchQueue.main.async {
                        self.statusText = "Ejecting slot \(slot.id)..."
                        onUpdate()
                    }

                    try self.releaseDiscForChanger(
                        bsdName: bsdName,
                        destinationSlot: slot.id,
                        changerService: changerService,
                        mountService: mountService
                    )

                    DispatchQueue.main.async {
                        self.completedSlots.append(slot.id)
                        self.imagingProgress = 0
                        onSlotEjected(slot.id)
                        onUpdate()
                    }

                    if self.isCancelled {
                        DispatchQueue.main.async {
                            self.statusText = "Cancelled after \(self.currentIndex) disc(s)"
                            onUpdate()
                        }
                        break
                    }

                } catch {
                    self.logFailure("batch image", slot: slot.id, error: error)
                    let imagingCancelled: Bool = {
                        guard let imagingError = error as? ImagingError else { return false }
                        if case .cancelled = imagingError {
                            return true
                        }
                        return false
                    }()

                    let changerCancelled: Bool = {
                        guard let changerError = error as? ChangerError else { return false }
                        if case .cancelled = changerError {
                            return true
                        }
                        return false
                    }()

                    if imagingCancelled || changerCancelled || self.isCancelled {
                        DispatchQueue.main.async {
                            self.isCancelled = true
                            self.isPaused = false
                            self.statusText = "Cancelled after \(self.currentIndex) disc(s)"
                            onUpdate()
                        }
                        break
                    }

                    DispatchQueue.main.async {
                        self.failedSlots.append((slot.id, error.localizedDescription))
                        onUpdate()
                    }

                    // Record failed backup if we got far enough to start imaging
                    if let outputPath = attemptedOutputPath {
                        catalogService.recordBackupFailed(
                            slotId: slot.id,
                            backupPath: outputPath.appendingPathExtension("iso").path,
                            error: error.localizedDescription
                        )
                    }

                    // Try to eject disc if loaded
                    do {
                        try self.releaseDiscForChanger(
                            bsdName: mountService.findDiscBSDName(),
                            destinationSlot: slot.id,
                            changerService: changerService,
                            mountService: mountService
                        )
                        DispatchQueue.main.async {
                            onSlotEjected(slot.id)
                        }
                    } catch {
                        self.logFailure("batch image cleanup eject", slot: slot.id, error: error)
                        // Ignore eject errors
                    }
                }

                DispatchQueue.main.async {
                    self.currentIndex += 1
                    self.currentDiscTransferredBytes = 0
                    self.currentDiscTotalBytes = nil
                    self.currentDiscSpeedBytesPerSecond = 0
                    self.currentDiscETASeconds = nil
                    self.currentDiscName = nil
                    onUpdate()
                }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                self.isPaused = false
                if !self.isCancelled {
                    self.statusText = "Complete: \(self.completedSlots.count) imaged, \(self.failedSlots.count) failed"
                }
                onUpdate()
                onComplete()
            }
        }
    }

    /// Safe batch image operation with persistent disc identity and duplicate policy.
    func runImageAll(
        slots: [Slot],
        outputDirectory: URL,
        duplicatePolicy: DuplicatePolicy,
        driveFallbackSourceSlot: Int?,
        ignoreUntrackedDriveFull: Bool = false,
        changerService: ChangerServicing,
        mountService: MountServicing,
        imagingService: ImagingServicing,
        catalogService: CatalogService,
        onUpdate: @escaping () -> Void,
        onSlotLoaded: @escaping (Int, String, String?) -> Void,
        onSlotEjected: @escaping (Int) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let occupiedSlots = slots.filter { $0.isFull || $0.isInDrive }
        guard !occupiedSlots.isEmpty else { return }

        operationType = .imageAll(outputDirectory: outputDirectory)
        isRunning = true
        isCancelled = false
        isPaused = false
        totalCount = occupiedSlots.count
        currentIndex = 0
        completedSlots = []
        failedSlots = []
        skippedSlots = []
        replacedSlots = []
        haltReason = nil
        imagingProgress = 0
        currentDiscTransferredBytes = 0
        currentDiscTotalBytes = nil
        currentDiscSpeedBytesPerSecond = 0
        currentDiscETASeconds = nil
        overallTransferredBytes = 0
        overallEstimatedTotalBytes = nil
        overallETASeconds = nil
        imagingControl.reset()
        onUpdate()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var completedBytes: Int64 = 0
            var knownDiscSizes: [Int64] = []
            var processedCount = 0

            do {
                let drive = try changerService.getDriveStatus()
                let opticalMediaPresent = mountService.isDiscPresent()
                let reconciledEmpty = ignoreUntrackedDriveFull
                    && drive.sourceSlot == nil
                    && driveFallbackSourceSlot == nil
                if !reconciledEmpty && (drive.hasDisc || opticalMediaPresent) {
                    guard let sourceSlot = drive.sourceSlot ?? driveFallbackSourceSlot else {
                        throw ChangerError.commandFailed("Drive contains a disc whose source slot is unknown")
                    }
                    try self.releaseDiscForChanger(
                        bsdName: mountService.findDiscBSDName(),
                        destinationSlot: sourceSlot,
                        changerService: changerService,
                        mountService: mountService
                    )
                    DispatchQueue.main.async { onSlotEjected(sourceSlot); onUpdate() }
                }
            } catch {
                self.logFailure("prepare drive for batch", error: error)
                DispatchQueue.main.async {
                    self.haltReason = "Could not clear the drive before starting: \(error.localizedDescription)"
                    self.statusText = self.haltReason ?? "Batch stopped"
                    self.failedSlots.append((0, self.statusText))
                    self.isRunning = false
                    onUpdate()
                    onComplete()
                }
                return
            }

            for slot in occupiedSlots {
                if self.imagingControl.isCancelled { break }

                var loaded = false
                var bsdName: String?
                var ripId: Int64?
                var ripCompleted = false
                var processingError: Error?
                var skippedPath: String?
                var completedThisDisc = false
                var replacedThisDisc = false

                DispatchQueue.main.async {
                    self.currentSlot = slot.id
                    self.statusText = "Loading slot \(slot.id)..."
                    self.imagingProgress = 0
                    self.currentDiscName = nil
                    onUpdate()
                }

                do {
                    try changerService.loadSlot(slot.id)
                    loaded = true
                    DispatchQueue.main.async { self.statusText = "Waiting for disc..."; onUpdate() }

                    let detectedBSDName = try mountService.waitForDisc(timeout: 90)
                    bsdName = detectedBSDName
                    let discType = imagingService.detectDiscType(bsdName: detectedBSDName)
                    let mountPoint = try self.mountDiscIfAvailable(
                        bsdName: detectedBSDName,
                        mountService: mountService,
                        allowMountless: discType == .audioCDDA || discType == .mixedModeCD,
                        preferPrivateAudioMount: discType == .audioCDDA
                    )
                    DispatchQueue.main.async {
                        onSlotLoaded(slot.id, detectedBSDName, mountPoint)
                        self.statusText = "Identifying disc..."
                        onUpdate()
                    }

                    let estimatedSize = imagingService.estimateDiscSizeBytes(bsdName: detectedBSDName)
                    if let estimatedSize = estimatedSize { knownDiscSizes.append(estimatedSize) }
                    guard let disc = catalogService.recordDisc(
                        slotId: slot.id,
                        bsdName: detectedBSDName,
                        discType: discType,
                        sizeBytes: estimatedSize,
                        volumeLabel: mountService.getVolumeName(bsdName: detectedBSDName)
                    ) else {
                        throw ChangerError.metadataFailed("Could not save this disc to the catalog")
                    }

                    DispatchQueue.main.async {
                        self.statusText = "Checking previous rip integrity..."
                        onUpdate()
                    }
                    let existingRip = duplicatePolicy == .replaceExisting
                        ? catalogService.latestRipForReplacement(disc: disc)
                        : catalogService.latestVerifiedRip(disc: disc)
                    if duplicatePolicy == .skipExisting,
                       let existing = existingRip {
                        skippedPath = existing.backupPath
                        catalogService.recordRipSkipped(disc: disc, slotId: slot.id, existing: existing)
                        DispatchQueue.main.async {
                            self.currentDiscName = disc.displayName
                            self.statusText = "Already ripped; returning slot \(slot.id)..."
                            onUpdate()
                        }
                    } else {
                        let outputBase = catalogService.uniqueOutputBase(
                            directory: outputDirectory,
                            disc: disc,
                            slotId: slot.id
                        )
                        guard let startedRipId = catalogService.startRip(
                            disc: disc,
                            slotId: slot.id,
                            proposedPath: outputBase.appendingPathExtension(discType.preferredImageExtension)
                        ) else {
                            throw ChangerError.imagingFailed("Could not create a rip history record")
                        }
                        ripId = startedRipId

                        DispatchQueue.main.async {
                            self.statusText = "Imaging \(disc.displayName)..."
                            self.currentDiscName = disc.displayName
                            self.currentDiscTransferredBytes = 0
                            self.currentDiscTotalBytes = estimatedSize
                            self.currentDiscSpeedBytesPerSecond = 0
                            self.currentDiscETASeconds = nil
                            onUpdate()
                        }

                        // hdiutil needs block-device access. Pure audio CDs are
                        // archived from Catalina's mounted cddafs track files.
                        if discType != .audioCDDA {
                            try mountService.unmountDisc(bsdName: detectedBSDName, force: true)
                        }

                        let finalURL = try imagingService.createImage(
                            bsdName: detectedBSDName,
                            discType: discType,
                            outputPath: outputBase,
                            totalBytes: estimatedSize,
                            control: self.imagingControl,
                            progress: { progress in
                                DispatchQueue.main.async {
                                    self.imagingProgress = progress.fractionCompleted
                                    self.currentDiscTransferredBytes = progress.bytesTransferred
                                    self.currentDiscTotalBytes = progress.totalBytes
                                    self.currentDiscSpeedBytesPerSecond = progress.speedBytesPerSecond ?? 0
                                    self.currentDiscETASeconds = progress.etaSeconds

                                    let remaining = max(occupiedSlots.count - processedCount - 1, 0)
                                    let averageSize = knownDiscSizes.isEmpty ? nil : knownDiscSizes.reduce(0, +) / Int64(knownDiscSizes.count)
                                    let estimatedRemaining = averageSize.map { $0 * Int64(remaining) } ?? 0
                                    let totalEstimate = estimatedSize.map { completedBytes + $0 + estimatedRemaining }
                                    let transferred = completedBytes + progress.bytesTransferred
                                    self.overallTransferredBytes = transferred
                                    self.overallEstimatedTotalBytes = totalEstimate
                                    if let totalEstimate = totalEstimate,
                                       let speed = progress.speedBytesPerSecond, speed > 0 {
                                        self.overallETASeconds = max(Double(totalEstimate - transferred) / speed, 0)
                                    } else {
                                        self.overallETASeconds = nil
                                    }
                                    let percent = Int(progress.fractionCompleted * 100)
                                    self.statusText = self.isPaused
                                        ? "Imaging \(disc.displayName)... paused at \(percent)%"
                                        : "Imaging \(disc.displayName)... \(percent)%"
                                    onUpdate()
                                }
                            }
                        )

                        guard FileManager.default.fileExists(atPath: finalURL.path) else {
                            throw ImagingError.writeFailed(finalURL)
                        }
                        let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
                        guard let finalSize = attributes[.size] as? NSNumber, finalSize.int64Value > 0 else {
                            throw ImagingError.writeFailed(finalURL)
                        }
                        try catalogService.recordRipCompleted(ripId: startedRipId, finalURL: finalURL, disc: disc)
                        if duplicatePolicy == .replaceExisting, let existing = existingRip {
                            try catalogService.supersede(existing, with: finalURL)
                            replacedThisDisc = true
                        }
                        ripCompleted = true
                        completedThisDisc = true
                        completedBytes += estimatedSize ?? finalSize.int64Value
                    }
                } catch {
                    processingError = error
                    self.logFailure("batch image", slot: slot.id, error: error)
                    if let ripId = ripId, !ripCompleted {
                        catalogService.recordRipFailed(
                            ripId: ripId,
                            error: error.localizedDescription,
                            cancelled: self.imagingControl.isCancelled
                        )
                    }
                }

                var cleanupError: Error?
                if loaded {
                    DispatchQueue.main.async { self.statusText = "Returning slot \(slot.id)..."; onUpdate() }
                    do {
                        try self.releaseDiscForChanger(
                            bsdName: bsdName ?? mountService.findDiscBSDName(),
                            destinationSlot: slot.id,
                            changerService: changerService,
                            mountService: mountService
                        )
                        DispatchQueue.main.async { onSlotEjected(slot.id); onUpdate() }
                    } catch {
                        cleanupError = error
                        self.logFailure("return disc after batch item", slot: slot.id, error: error)
                    }
                }

                processedCount += 1
                DispatchQueue.main.async {
                    if completedThisDisc { self.completedSlots.append(slot.id) }
                    if replacedThisDisc { self.replacedSlots.append(slot.id) }
                    if let path = skippedPath { self.skippedSlots.append((slot.id, path)) }
                    if !self.imagingControl.isCancelled,
                       let processingError = processingError {
                        var message = processingError.localizedDescription
                        if let cleanupError = cleanupError {
                            message += "; disc return also failed: \(cleanupError.localizedDescription)"
                        }
                        self.failedSlots.append((slot.id, message))
                    } else if let cleanupError = cleanupError {
                        self.failedSlots.append((slot.id, cleanupError.localizedDescription))
                    }
                    if let error = cleanupError {
                        let message = "Could not return the disc; queue stopped to protect the remaining discs: \(error.localizedDescription)"
                        self.haltReason = message
                    }
                    self.currentIndex = processedCount
                    self.imagingProgress = 0
                    self.currentDiscTransferredBytes = 0
                    self.currentDiscTotalBytes = nil
                    self.currentDiscSpeedBytesPerSecond = 0
                    self.currentDiscETASeconds = nil
                    self.currentDiscName = nil
                    onUpdate()
                }

                if cleanupError != nil || self.imagingControl.isCancelled { break }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                self.isPaused = false
                if self.imagingControl.isCancelled {
                    self.isCancelled = true
                    self.statusText = "Cancelled safely after \(processedCount) disc(s)"
                } else if let reason = self.haltReason {
                    self.statusText = reason
                } else {
                    self.statusText = "Complete: \(self.completedSlots.count) imaged, \(self.skippedSlots.count) skipped, \(self.failedSlots.count) failed"
                }
                onUpdate()
                onComplete()
            }
        }
    }

    /// macOS must release optical media before the changer can physically grab it.
    private func releaseDiscForChanger(
        bsdName: String?,
        destinationSlot: Int,
        changerService: ChangerServicing,
        mountService: MountServicing
    ) throws {
        if let bsdName = bsdName {
            if mountService.isMounted(bsdName: bsdName) {
                try mountService.unmountDisc(bsdName: bsdName, force: true)
            }

            // Release the exact BSD device once before asking the robot to
            // move it. The library intentionally performs robotics only. A
            // failed release must stop here; moving media still owned by
            // macOS is what wedges this Sony FireWire control channel.
            try mountService.ejectDisc(bsdName: bsdName, force: true)
        }
        try changerService.ejectToSlot(destinationSlot)

        // The changer's element inventory is authoritative for the physical
        // drive. Catalina can retain a stale IOMedia node after a successful
        // robotic return, especially when running headless. Never accept an
        // inventory read error as "empty".
        for _ in 0..<40 {
            if let status = try? changerService.getDriveStatus(), !status.hasDisc {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ChangerError.commandFailed("Could not verify an empty changer drive after return")
    }

    /// Scan unknown discs: load, mount, catalog metadata, unmount/eject, repeat.
    func runScanUnknown(
        slots: [Slot],
        driveFallbackSourceSlot: Int?,
        changerService: ChangerServicing,
        mountService: MountServicing,
        imagingService: ImagingServicing,
        catalogService: CatalogService,
        onUpdate: @escaping () -> Void,
        onSlotLoaded: @escaping (Int, String, String?) -> Void,
        onSlotCataloged: @escaping (Int) -> Void,
        onSlotEjected: @escaping (Int) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let unknownSlots = slots.filter { $0.isFull && !$0.isInDrive && $0.discType == .unscanned }
        guard !unknownSlots.isEmpty else { return }

        operationType = .scanUnknown
        isRunning = true
        isCancelled = false
        isPaused = false
        totalCount = unknownSlots.count
        currentIndex = 0
        completedSlots = []
        failedSlots = []
        skippedSlots = []
        replacedSlots = []
        haltReason = nil
        imagingProgress = 0
        currentDiscTransferredBytes = 0
        currentDiscTotalBytes = nil
        currentDiscSpeedBytesPerSecond = 0
        currentDiscETASeconds = nil
        overallTransferredBytes = 0
        overallEstimatedTotalBytes = nil
        overallETASeconds = nil
        averageDiscOperationSeconds = nil
        statusText = "Preparing scan..."
        onUpdate()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var completedDurations: [TimeInterval] = []

            func updateScanTiming(currentDiscElapsed: TimeInterval?) {
                let average = completedDurations.isEmpty
                    ? nil
                    : completedDurations.reduce(0, +) / Double(completedDurations.count)
                let remainingAfterCurrent = max(self.totalCount - self.currentIndex - 1, 0)
                let eta: TimeInterval? = {
                    guard let average = average else { return nil }
                    let currentRemaining = max(average - (currentDiscElapsed ?? 0), 0)
                    return currentRemaining + (average * Double(remainingAfterCurrent))
                }()
                DispatchQueue.main.async {
                    self.averageDiscOperationSeconds = average
                    self.overallETASeconds = eta
                    onUpdate()
                }
            }

            // Eject any disc currently in the drive before starting.
            do {
                let driveStatus = try? changerService.getDriveStatus()
                if driveStatus?.hasDisc == true {
                    let sourceSlot = driveStatus?.sourceSlot ?? driveFallbackSourceSlot
                    guard let sourceSlot else {
                        DispatchQueue.main.async {
                            self.isCancelled = true
                            self.statusText = "Drive contains a disc with unknown source slot. Eject it first, then retry."
                            self.failedSlots.append((0, "Drive not empty (source slot unknown)"))
                            onUpdate()
                            self.isRunning = false
                            onUpdate()
                            onComplete()
                        }
                        return
                    }
                    try self.releaseDiscForChanger(
                        bsdName: mountService.findDiscBSDName(),
                        destinationSlot: sourceSlot,
                        changerService: changerService,
                        mountService: mountService
                    )
                    DispatchQueue.main.async {
                        onSlotEjected(sourceSlot)
                    }
                }
            } catch {
                self.logFailure("initial eject before scan-unknown", error: error)
                DispatchQueue.main.async {
                    let message = "Could not clear the drive before scanning: \(error.localizedDescription)"
                    self.haltReason = message
                    self.failedSlots.append((0, message))
                    self.statusText = message
                    self.isRunning = false
                    onUpdate()
                    onComplete()
                }
                return
            }

            for slot in unknownSlots {
                if self.imagingControl.isCancelled {
                    DispatchQueue.main.async {
                        self.statusText = "Cancelled after \(self.currentIndex) disc(s)"
                        onUpdate()
                    }
                    break
                }

                let discStartedAt = Date()
                var cleanupFailed = false
                updateScanTiming(currentDiscElapsed: 0)

                DispatchQueue.main.async {
                    self.currentSlot = slot.id
                    self.statusText = "Loading slot \(slot.id)..."
                    onUpdate()
                }

                do {
                    try changerService.loadSlot(slot.id)

                    DispatchQueue.main.async {
                        self.statusText = "Waiting for slot \(slot.id)..."
                        onUpdate()
                    }
                    updateScanTiming(currentDiscElapsed: Date().timeIntervalSince(discStartedAt))

                    let bsdName = try mountService.waitForDisc(timeout: 90)
                    let discType = imagingService.detectDiscType(bsdName: bsdName)
                    let mountPoint = try self.mountDiscIfAvailable(
                        bsdName: bsdName,
                        mountService: mountService,
                        allowMountless: (discType == .audioCDDA),
                        preferPrivateAudioMount: discType == .audioCDDA
                    )

                    DispatchQueue.main.async {
                        if mountPoint != nil {
                            self.statusText = "Cataloging slot \(slot.id)..."
                        } else {
                            self.statusText = "Cataloging slot \(slot.id) (no filesystem mount)..."
                        }
                        onSlotLoaded(slot.id, bsdName, mountPoint)
                        onUpdate()
                    }
                    updateScanTiming(currentDiscElapsed: Date().timeIntervalSince(discStartedAt))

                    let estimatedSize = imagingService.estimateDiscSizeBytes(bsdName: bsdName)
                    _ = catalogService.recordDisc(
                        slotId: slot.id,
                        bsdName: bsdName,
                        discType: discType,
                        sizeBytes: estimatedSize,
                        volumeLabel: mountService.getVolumeName(bsdName: bsdName)
                    )

                    DispatchQueue.main.async {
                        onSlotCataloged(slot.id)
                        onUpdate()
                    }

                    DispatchQueue.main.async {
                        self.statusText = "Returning slot \(slot.id)..."
                        onUpdate()
                    }
                    updateScanTiming(currentDiscElapsed: Date().timeIntervalSince(discStartedAt))
                    try self.releaseDiscForChanger(
                        bsdName: bsdName,
                        destinationSlot: slot.id,
                        changerService: changerService,
                        mountService: mountService
                    )

                    DispatchQueue.main.async {
                        self.completedSlots.append(slot.id)
                        onSlotEjected(slot.id)
                        onUpdate()
                    }

                } catch {
                    self.logFailure("scan unknown", slot: slot.id, error: error)
                    DispatchQueue.main.async {
                        self.failedSlots.append((slot.id, error.localizedDescription))
                        onUpdate()
                    }

                    // Best-effort cleanup for the current slot before continuing.
                    do {
                        try self.releaseDiscForChanger(
                            bsdName: mountService.findDiscBSDName(),
                            destinationSlot: slot.id,
                            changerService: changerService,
                            mountService: mountService
                        )
                        DispatchQueue.main.async {
                            onSlotEjected(slot.id)
                            onUpdate()
                        }
                    } catch {
                        self.logFailure("scan unknown cleanup eject", slot: slot.id, error: error)
                        cleanupFailed = true
                        DispatchQueue.main.async {
                            let message = "Could not return the disc; scan stopped to protect the remaining discs: \(error.localizedDescription)"
                            self.failedSlots.append((slot.id, message))
                            self.haltReason = message
                            onUpdate()
                        }
                    }
                }

                completedDurations.append(Date().timeIntervalSince(discStartedAt))
                updateScanTiming(currentDiscElapsed: nil)

                DispatchQueue.main.async {
                    self.currentIndex += 1
                    onUpdate()
                }
                if cleanupFailed { break }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                if let reason = self.haltReason {
                    self.statusText = reason
                } else if !self.isCancelled {
                    self.statusText = "Complete: \(self.completedSlots.count) cataloged, \(self.failedSlots.count) failed"
                    self.overallETASeconds = 0
                }
                onUpdate()
                onComplete()
            }
        }
    }
}
