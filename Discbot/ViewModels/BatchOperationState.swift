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
    @Published var cancelledSlots: [Int] = []
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
    @Published var canCancelCurrentDisc = false
    @Published var finalizingDiscCount = 0

    private var smoothedImagingSpeedBytesPerSecond: Double?

    private let imagingControl = ImagingService.ImagingControl()
    private let finalizationControlLock = NSLock()
    private var finalizationControls: [ObjectIdentifier: ImagingService.ImagingControl] = [:]
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Discbot",
        category: "BatchOperation"
    )

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        let value = min(1.0, max(0.0, (Double(currentIndex) + imagingProgress) / Double(totalCount)))
        return finalizingDiscCount > 0 ? min(value, 0.99) : value
    }

    var isComplete: Bool {
        !isRunning && (currentIndex >= totalCount || haltReason != nil)
    }

    func cancel() {
        isCancelled = true
        isPaused = false
        canCancelCurrentDisc = false
        statusText = currentSlot > 0
            ? "Cancelling batch; returning slot \(currentSlot) safely..."
            : "Cancelling batch safely..."
        imagingControl.cancel()
        cancelFinalizations()
    }

    @discardableResult
    func cancelCurrentDisc() -> Bool {
        guard case .imageAll = operationType,
              isRunning,
              canCancelCurrentDisc,
              currentSlot > 0 else { return false }
        canCancelCurrentDisc = false
        isPaused = false
        statusText = "Cancelling this rip; returning slot \(currentSlot) safely..."
        imagingControl.cancelCurrentDisc()
        return true
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
        cancelledSlots = []
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
        canCancelCurrentDisc = false
        finalizingDiscCount = 0
        smoothedImagingSpeedBytesPerSecond = nil
        imagingControl.reset()
        cancelFinalizations()
    }

    private func registerFinalizationControl(_ control: ImagingService.ImagingControl) {
        finalizationControlLock.lock()
        finalizationControls[ObjectIdentifier(control)] = control
        let shouldCancel = imagingControl.isBatchCancelled
        finalizationControlLock.unlock()
        if shouldCancel { control.cancel() }
    }

    private func unregisterFinalizationControl(_ control: ImagingService.ImagingControl) {
        finalizationControlLock.lock()
        finalizationControls.removeValue(forKey: ObjectIdentifier(control))
        finalizationControlLock.unlock()
    }

    private func cancelFinalizations() {
        finalizationControlLock.lock()
        let controls = Array(finalizationControls.values)
        finalizationControlLock.unlock()
        controls.forEach { $0.cancel() }
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
        cancelledSlots = []
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
            self?.cancelledSlots = []
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
        outputMode: RipOutputMode = .automatic,
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
        cancelledSlots = []
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
        canCancelCurrentDisc = false
        finalizingDiscCount = 0
        smoothedImagingSpeedBytesPerSecond = nil
        imagingControl.reset()
        catalogService.recordActivity(
            type: "batch_started",
            message: "Started batch for \(occupiedSlots.count) disc(s) to \(outputDirectory.path) using \(duplicatePolicy.displayName.lowercased()) and \(outputMode.displayName.lowercased())."
        )
        onUpdate()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var completedBytes: Int64 = 0
            var knownDiscSizes: [Int64] = []
            var processedCount = 0
            let finalizationQueue = OperationQueue()
            finalizationQueue.name = "discbot.batch.finalization"
            finalizationQueue.qualityOfService = .utility
            finalizationQueue.maxConcurrentOperationCount = 1
            // One disc may finalize while one more is read or queued.
            let stagingSlots = DispatchSemaphore(value: 2)
            let finalizationGroup = DispatchGroup()
            var pendingByDiscID: [Int64: DispatchGroup] = [:]

            do {
                guard mountService.isOpticalDriveAvailable() else {
                    throw ChangerError.opticalDriveUnavailable
                }
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
                catalogService.recordActivity(
                    type: "batch_failed",
                    message: "Batch stopped before moving media: \(error.localizedDescription)"
                )
                DispatchQueue.main.async {
                    self.haltReason = "Batch could not start: \(error.localizedDescription)"
                    self.statusText = self.haltReason ?? "Batch stopped"
                    self.failedSlots.append((0, self.statusText))
                    self.isRunning = false
                    onUpdate()
                    onComplete()
                }
                return
            }

            for slot in occupiedSlots {
                if self.imagingControl.isBatchCancelled { break }

                if stagingSlots.wait(timeout: .now()) == .timedOut {
                    DispatchQueue.main.async {
                        self.statusText = "Waiting for saved DVDs to finish..."
                        self.canCancelCurrentDisc = false
                        onUpdate()
                    }
                    while stagingSlots.wait(timeout: .now() + 0.1) == .timedOut {
                        if self.imagingControl.isBatchCancelled { break }
                    }
                    if self.imagingControl.isBatchCancelled { break }
                }
                var handedOffToFinalization = false
                defer { if !handedOffToFinalization { stagingSlots.signal() } }
                if self.imagingControl.isBatchCancelled { break }

                var loaded = false
                var bsdName: String?
                var ripId: Int64?
                var ripCompleted = false
                var createdFinalURL: URL?
                var processingError: Error?
                var skippedPath: String?
                var completedThisDisc = false
                var replacedThisDisc = false
                var cancelledThisDisc = false
                var stagedArtifact: StagedImageArtifact?
                var stagedDisc: DiscRecord?
                var stagedExistingRip: BackupRecord?
                var stagedDiscGroup: DispatchGroup?

                DispatchQueue.main.async {
                    self.currentSlot = slot.id
                    self.statusText = "Loading slot \(slot.id)..."
                    self.imagingProgress = 0
                    self.currentDiscName = nil
                    self.canCancelCurrentDisc = false
                    self.smoothedImagingSpeedBytesPerSecond = nil
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
                    if duplicatePolicy != .imageAgain,
                       let discID = disc.id,
                       let pending = pendingByDiscID[discID] {
                        while pending.wait(timeout: .now() + 0.1) == .timedOut {
                            try self.imagingControl.checkCancellation()
                        }
                    }
                    try self.imagingControl.checkCancellation()
                    let existingRip: BackupRecord?
                    switch duplicatePolicy {
                    case .skipExisting:
                        existingRip = try catalogService.existingRipForAutomaticSkip(
                            disc: disc, control: self.imagingControl
                        )
                    case .replaceExisting:
                        existingRip = catalogService.latestRipForReplacement(disc: disc)
                    case .imageAgain:
                        existingRip = nil
                    }
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
                            proposedPath: outputBase.appendingPathExtension(outputMode.preferredExtension(for: discType))
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
                            self.canCancelCurrentDisc = true
                            onUpdate()
                        }

                        // hdiutil needs block-device access. Pure audio CDs are
                        // archived from Catalina's mounted cddafs track files.
                        if discType != .audioCDDA {
                            try mountService.unmountDisc(bsdName: detectedBSDName, force: true)
                        }

                        let artifact = try imagingService.createBatchImage(
                            bsdName: detectedBSDName,
                            discType: discType,
                            outputMode: outputMode,
                            outputPath: outputBase,
                            totalBytes: estimatedSize,
                            control: self.imagingControl,
                            progress: { progress in
                                DispatchQueue.main.async {
                                    let stableFraction = max(self.imagingProgress, progress.fractionCompleted)
                                    let stableBytes = max(self.currentDiscTransferredBytes, progress.bytesTransferred)
                                    self.imagingProgress = stableFraction
                                    self.currentDiscTransferredBytes = stableBytes
                                    self.currentDiscTotalBytes = progress.totalBytes
                                    if let speed = progress.speedBytesPerSecond, speed > 0 {
                                        let smoothed = self.smoothedImagingSpeedBytesPerSecond.map {
                                            ($0 * 0.85) + (speed * 0.15)
                                        } ?? speed
                                        self.smoothedImagingSpeedBytesPerSecond = smoothed
                                        self.currentDiscSpeedBytesPerSecond = smoothed
                                        if let total = progress.totalBytes {
                                            self.currentDiscETASeconds = max(Double(total - stableBytes) / smoothed, 0)
                                        } else {
                                            self.currentDiscETASeconds = progress.etaSeconds
                                        }
                                    }

                                    let remaining = max(occupiedSlots.count - processedCount - 1, 0)
                                    let averageSize = knownDiscSizes.isEmpty ? nil : knownDiscSizes.reduce(0, +) / Int64(knownDiscSizes.count)
                                    let estimatedRemaining = averageSize.map { $0 * Int64(remaining) } ?? 0
                                    let totalEstimate = estimatedSize.map { completedBytes + $0 + estimatedRemaining }
                                    let transferred = completedBytes + stableBytes
                                    self.overallTransferredBytes = transferred
                                    self.overallEstimatedTotalBytes = totalEstimate
                                    if let totalEstimate = totalEstimate,
                                       let speed = self.smoothedImagingSpeedBytesPerSecond, speed > 0 {
                                        self.overallETASeconds = max(Double(totalEstimate - transferred) / speed, 0)
                                    } else {
                                        self.overallETASeconds = nil
                                    }
                                    let percent = Int(stableFraction * 100)
                                    self.statusText = self.isPaused
                                        ? "Imaging \(disc.displayName)... paused at \(percent)%"
                                        : "Imaging \(disc.displayName)... \(percent)%"
                                    onUpdate()
                                }
                            }
                        )

                        DispatchQueue.main.async {
                            self.canCancelCurrentDisc = false
                            self.statusText = "Preparing to return \(disc.displayName)..."
                            onUpdate()
                        }

                        switch artifact {
                        case .complete(let finalURL):
                            createdFinalURL = finalURL
                            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                                throw ImagingError.writeFailed(finalURL)
                            }
                            let finalSize = try RipArtifactInspector.sizeBytes(at: finalURL)
                            guard finalSize > 0 else {
                                throw ImagingError.writeFailed(finalURL)
                            }
                            try catalogService.recordRipCompleted(
                                ripId: startedRipId,
                                finalURL: finalURL,
                                disc: disc,
                                control: self.imagingControl
                            )
                            ripCompleted = true
                            completedThisDisc = true
                            if duplicatePolicy == .replaceExisting, let existing = existingRip {
                                try catalogService.supersede(existing, with: finalURL)
                                replacedThisDisc = true
                            }
                            completedBytes += estimatedSize ?? finalSize

                        case .staged(let pending):
                            stagedArtifact = pending
                            stagedDisc = disc
                            stagedExistingRip = existingRip
                            let discGroup = DispatchGroup()
                            discGroup.enter()
                            stagedDiscGroup = discGroup
                            if let discID = disc.id {
                                pendingByDiscID[discID] = discGroup
                            }
                            completedBytes += estimatedSize ?? 0
                        }
                    }
                } catch {
                    processingError = error
                    cancelledThisDisc = self.imagingControl.consumeCurrentDiscCancellation()
                    if !ripCompleted, let finalURL = createdFinalURL,
                       cancelledThisDisc || self.imagingControl.isBatchCancelled {
                        catalogService.discardUncommittedImage(at: finalURL)
                    }
                    self.logFailure("batch image", slot: slot.id, error: error)
                    if let ripId = ripId, !ripCompleted {
                        catalogService.recordRipFailed(
                            ripId: ripId,
                            error: error.localizedDescription,
                            cancelled: cancelledThisDisc || self.imagingControl.isBatchCancelled
                        )
                    } else {
                        catalogService.recordActivity(
                            type: (cancelledThisDisc || self.imagingControl.isBatchCancelled) ? "cancelled" : "failed",
                            slotId: slot.id,
                            message: "Failed before imaging began: \(error.localizedDescription)"
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
                        catalogService.recordActivity(
                            type: "recovery_failed",
                            slotId: slot.id,
                            message: "Could not safely return the disc: \(error.localizedDescription)"
                        )
                    }
                }

                if let artifact = stagedArtifact,
                   let stagedDisc = stagedDisc,
                   let stagedRipID = ripId {
                    let existingRipForFinalization = stagedExistingRip
                    let discGroupForFinalization = stagedDiscGroup
                    let finalizingSlotID = slot.id
                    finalizationGroup.enter()
                    DispatchQueue.main.async {
                        self.finalizingDiscCount += 1
                        onUpdate()
                    }
                    handedOffToFinalization = true
                    finalizationQueue.addOperation { [weak self] in
                        defer { stagingSlots.signal() }
                        guard let self = self else {
                            artifact.discard()
                            discGroupForFinalization?.leave()
                            finalizationGroup.leave()
                            return
                        }

                        let finalizationControl = ImagingService.ImagingControl()
                        self.registerFinalizationControl(finalizationControl)
                        var finalizationError: Error?
                        var didReplace = false
                        var didComplete = false
                        var finalizedURL: URL?

                        do {
                            if self.imagingControl.isBatchCancelled {
                                artifact.discard()
                                throw ImagingError.cancelled
                            }
                            let finalURL = try artifact.finalize(control: finalizationControl)
                            finalizedURL = finalURL
                            let finalSize = try RipArtifactInspector.sizeBytes(at: finalURL)
                            guard finalSize > 0 else {
                                throw ImagingError.writeFailed(finalURL)
                            }
                            try catalogService.recordRipCompleted(
                                ripId: stagedRipID,
                                finalURL: finalURL,
                                disc: stagedDisc,
                                control: finalizationControl
                            )
                            didComplete = true
                            if duplicatePolicy == .replaceExisting,
                               let existing = existingRipForFinalization {
                                try catalogService.supersede(existing, with: finalURL)
                                didReplace = true
                            }
                        } catch {
                            finalizationError = error
                            let cancelled = self.imagingControl.isBatchCancelled
                                || finalizationControl.isCancelled
                            if !didComplete {
                                if cancelled, let finalURL = finalizedURL {
                                    catalogService.discardUncommittedImage(at: finalURL)
                                }
                                catalogService.recordRipFailed(
                                    ripId: stagedRipID,
                                    error: error.localizedDescription,
                                    cancelled: cancelled
                                )
                            }
                            self.logFailure("finalize staged image", slot: finalizingSlotID, error: error)
                        }

                        self.unregisterFinalizationControl(finalizationControl)
                        let wasCancelled = self.imagingControl.isBatchCancelled
                            || finalizationControl.isCancelled
                        DispatchQueue.main.async {
                            self.finalizingDiscCount = max(self.finalizingDiscCount - 1, 0)
                            if didComplete {
                                self.completedSlots.append(finalizingSlotID)
                                if didReplace { self.replacedSlots.append(finalizingSlotID) }
                            } else if wasCancelled {
                                self.cancelledSlots.append(finalizingSlotID)
                            } else if let error = finalizationError {
                                self.failedSlots.append((finalizingSlotID, error.localizedDescription))
                            }
                            onUpdate()
                        }
                        discGroupForFinalization?.leave()
                        finalizationGroup.leave()
                    }
                }

                processedCount += 1
                DispatchQueue.main.async {
                    self.canCancelCurrentDisc = false
                    if completedThisDisc { self.completedSlots.append(slot.id) }
                    if replacedThisDisc { self.replacedSlots.append(slot.id) }
                    if let path = skippedPath { self.skippedSlots.append((slot.id, path)) }
                    if cancelledThisDisc { self.cancelledSlots.append(slot.id) }
                    if !cancelledThisDisc,
                       !self.imagingControl.isBatchCancelled,
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

                if cleanupError != nil || self.imagingControl.isBatchCancelled { break }
            }

            if finalizationQueue.operationCount > 0 {
                let remainingFinalizations = finalizationQueue.operationCount
                DispatchQueue.main.async {
                    self.currentDiscName = nil
                    self.canCancelCurrentDisc = false
                    self.statusText = "Finalizing \(remainingFinalizations) saved DVD(s)..."
                    onUpdate()
                }
            }
            finalizationGroup.wait()

            DispatchQueue.main.async {
                self.isRunning = false
                self.isPaused = false
                self.canCancelCurrentDisc = false
                if self.imagingControl.isCancelled {
                    self.isCancelled = true
                    self.statusText = "Cancelled safely after \(processedCount) disc(s)"
                } else if let reason = self.haltReason {
                    self.statusText = reason
                } else {
                    self.statusText = "Complete: \(self.completedSlots.count) imaged, \(self.skippedSlots.count) skipped, \(self.cancelledSlots.count) cancelled, \(self.failedSlots.count) failed"
                }
                catalogService.recordActivity(
                    type: self.isCancelled ? "batch_cancelled" : (self.failedSlots.isEmpty ? "batch_completed" : "batch_completed_with_errors"),
                    message: self.statusText
                )
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
        cancelledSlots = []
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
