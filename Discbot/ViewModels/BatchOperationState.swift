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
        !isRunning && currentIndex >= totalCount
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
        allowMountless: Bool
    ) throws -> String? {
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
                // Media without a filesystem (for example audio CDs) can still be imaged raw.
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

        DispatchQueue.main.async { [weak self] in
            self?.operationType = .loadAll
            self?.isRunning = true
            self?.isCancelled = false
            self?.isPaused = false
            self?.totalCount = occupiedSlots.count
            self?.currentIndex = 0
            self?.completedSlots = []
            self?.failedSlots = []
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for slot in occupiedSlots {
                if self.isCancelled {
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

                    // Unmount and eject
                    if mountService.isMounted(bsdName: bsdName) {
                        try mountService.unmountDisc(bsdName: bsdName)
                    }
                    try changerService.ejectToSlot(slot.id)

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

    /// Run batch image operation on background thread
    func runImageAll(
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

                    if let bsdName = mountService.findDiscBSDName(), mountService.isMounted(bsdName: bsdName) {
                        try? mountService.unmountDisc(bsdName: bsdName, force: true)
                    }
                    try changerService.ejectToSlot(sourceSlot)
                    DispatchQueue.main.async {
                        onSlotEjected(sourceSlot)
                    }
                }
            } catch {
                self.logFailure("initial eject before image-all", error: error)
                // Best effort - continue even if eject fails
            }

            for slot in occupiedSlots {
                if self.isCancelled {
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
                        allowMountless: (discType == .audioCDDA)
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

                    // Unmount before imaging (hdiutil needs raw access)
                    if mountService.isMounted(bsdName: bsdName) {
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

                    // Eject disc back to slot
                    try changerService.ejectToSlot(slot.id)

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
                        if let bsdName = mountService.findDiscBSDName(), mountService.isMounted(bsdName: bsdName) {
                            try? mountService.unmountDisc(bsdName: bsdName, force: true)
                        }
                        try changerService.ejectToSlot(slot.id)
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

        DispatchQueue.main.async { [weak self] in
            self?.operationType = .scanUnknown
            self?.isRunning = true
            self?.isCancelled = false
            self?.isPaused = false
            self?.totalCount = unknownSlots.count
            self?.currentIndex = 0
            self?.completedSlots = []
            self?.failedSlots = []
            self?.imagingProgress = 0
            self?.currentDiscTransferredBytes = 0
            self?.currentDiscTotalBytes = nil
            self?.currentDiscSpeedBytesPerSecond = 0
            self?.currentDiscETASeconds = nil
            self?.overallTransferredBytes = 0
            self?.overallEstimatedTotalBytes = nil
            self?.overallETASeconds = nil
            self?.averageDiscOperationSeconds = nil
            self?.statusText = "Preparing scan..."
            onUpdate()
        }

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
                    if let bsdName = mountService.findDiscBSDName(), mountService.isMounted(bsdName: bsdName) {
                        try? mountService.unmountDisc(bsdName: bsdName, force: true)
                    }
                    try changerService.ejectToSlot(sourceSlot)
                    DispatchQueue.main.async {
                        onSlotEjected(sourceSlot)
                    }
                }
            } catch {
                self.logFailure("initial eject before scan-unknown", error: error)
            }

            for slot in unknownSlots {
                if self.isCancelled {
                    DispatchQueue.main.async {
                        self.statusText = "Cancelled after \(self.currentIndex) disc(s)"
                        onUpdate()
                    }
                    break
                }

                let discStartedAt = Date()
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
                        allowMountless: (discType == .audioCDDA)
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
                        sizeBytes: estimatedSize
                    )

                    DispatchQueue.main.async {
                        onSlotCataloged(slot.id)
                        onUpdate()
                    }

                    if mountService.isMounted(bsdName: bsdName) {
                        DispatchQueue.main.async {
                            self.statusText = "Unmounting slot \(slot.id)..."
                            onUpdate()
                        }
                        updateScanTiming(currentDiscElapsed: Date().timeIntervalSince(discStartedAt))
                        try mountService.unmountDisc(bsdName: bsdName, force: true)
                    }

                    DispatchQueue.main.async {
                        self.statusText = "Returning slot \(slot.id)..."
                        onUpdate()
                    }
                    updateScanTiming(currentDiscElapsed: Date().timeIntervalSince(discStartedAt))
                    try changerService.ejectToSlot(slot.id)

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
                        if let bsdName = mountService.findDiscBSDName(), mountService.isMounted(bsdName: bsdName) {
                            try? mountService.unmountDisc(bsdName: bsdName, force: true)
                        }
                        try changerService.ejectToSlot(slot.id)
                        DispatchQueue.main.async {
                            onSlotEjected(slot.id)
                            onUpdate()
                        }
                    } catch {
                        self.logFailure("scan unknown cleanup eject", slot: slot.id, error: error)
                    }
                }

                completedDurations.append(Date().timeIntervalSince(discStartedAt))
                updateScanTiming(currentDiscElapsed: nil)

                DispatchQueue.main.async {
                    self.currentIndex += 1
                    onUpdate()
                }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                if !self.isCancelled {
                    self.statusText = "Complete: \(self.completedSlots.count) cataloged, \(self.failedSlots.count) failed"
                    self.overallETASeconds = 0
                }
                onUpdate()
                onComplete()
            }
        }
    }
}
