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
    @Published var currentIndex = 0
    @Published var totalCount = 0
    @Published var currentSlot: Int = 0
    @Published var statusText: String = ""
    @Published var completedSlots: [Int] = []
    @Published var failedSlots: [(slot: Int, error: String)] = []

    // Imaging specific
    @Published var currentDiscMetadata: DiscMetadata?
    @Published var imagingProgress: Double = 0

    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(currentIndex) / Double(totalCount)
    }

    var isComplete: Bool {
        !isRunning && currentIndex >= totalCount
    }

    func cancel() {
        isCancelled = true
    }

    func reset() {
        operationType = nil
        isRunning = false
        isCancelled = false
        currentIndex = 0
        totalCount = 0
        currentSlot = 0
        statusText = ""
        completedSlots = []
        failedSlots = []
        currentDiscMetadata = nil
        imagingProgress = 0
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
}
