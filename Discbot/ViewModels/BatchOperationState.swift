//
//  BatchOperationState.swift
//  Discbot
//
//  State for batch operations (Load All, Image All)
//

import Foundation
import Combine

final class BatchOperationState: ObservableObject {
    enum OperationType: Equatable {
        case loadAll
        case imageAll(outputDirectory: URL)
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

    private let imagingControl = ImagingService.ImagingControl()

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

    func pauseRip() {
        guard case .imageAll = operationType else { return }
        guard isRunning else { return }
        isPaused = true
        imagingControl.setPaused(true)
    }

    func resumeRip() {
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
        imagingControl.reset()
    }

    /// Run batch load operation on background thread
    func runLoadAll(
        slots: [Slot],
        changerService: ChangerService,
        mountService: MountService,
        onUpdate: @escaping () -> Void,
        onSlotLoaded: @escaping (Int, String, String) -> Void,
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

                    // Wait for disc and mount
                    let bsdName = try mountService.waitForDisc(timeout: 60)
                    let mountPoint = try mountService.mountDisc(bsdName: bsdName)

                    DispatchQueue.main.async {
                        self.statusText = "Mounted at \(mountPoint)"
                        onSlotLoaded(slot.id, bsdName, mountPoint)
                        onUpdate()
                    }

                    // Brief pause to let user see the mounted disc
                    Thread.sleep(forTimeInterval: 2.0)

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
        changerService: ChangerService,
        mountService: MountService,
        imagingService: ImagingService,
        catalogService: CatalogService,
        onUpdate: @escaping () -> Void,
        onSlotLoaded: @escaping (Int, String, String) -> Void,
        onSlotEjected: @escaping (Int) -> Void,
        onComplete: @escaping () -> Void
    ) {
        let occupiedSlots = slots.filter { $0.isFull && !$0.isInDrive }
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
            self?.imagingControl.reset()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var completedBytes: Int64 = 0
            var knownDiscSizes: [Int64] = []

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

                    // Wait for disc and mount
                    let bsdName = try mountService.waitForDisc(timeout: 60)
                    let mountPoint = try mountService.mountDisc(bsdName: bsdName)

                    DispatchQueue.main.async {
                        self.statusText = "Mounted, detecting disc type..."
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

                    // Detect disc type
                    let discType = imagingService.detectDiscType(bsdName: bsdName)

                    // Record disc in catalog
                    _ = catalogService.recordDisc(
                        slotId: slot.id,
                        bsdName: bsdName,
                        discType: discType,
                        sizeBytes: estimatedSize
                    )

                    DispatchQueue.main.async {
                        self.statusText = "Ripping \(safeVolumeName)..."
                        self.currentDiscName = safeVolumeName
                        self.currentDiscTransferredBytes = 0
                        self.currentDiscTotalBytes = estimatedSize
                        self.currentDiscSpeedBytesPerSecond = 0
                        self.currentDiscETASeconds = nil
                        onUpdate()
                    }

                    // Unmount before imaging (hdiutil needs raw access)
                    if mountService.isMounted(bsdName: bsdName) {
                        try mountService.unmountDisc(bsdName: bsdName)
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
                                    ? "Ripping \(safeVolumeName)... paused at \(percent)%"
                                    : "Ripping \(safeVolumeName)... \(percent)%"
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
                        try changerService.ejectToSlot(slot.id)
                        DispatchQueue.main.async {
                            onSlotEjected(slot.id)
                        }
                    } catch {
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
                    self.statusText = "Complete: \(self.completedSlots.count) ripped, \(self.failedSlots.count) failed"
                }
                onUpdate()
                onComplete()
            }
        }
    }
}
