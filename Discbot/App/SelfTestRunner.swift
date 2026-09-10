//
//  SelfTestRunner.swift
//  Discbot
//
//  Hardware-free integration check used locally and by CI
//

import Foundation
import AppKit

enum SelfTestRunner {
    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("discbot-self-test-\(UUID().uuidString)", isDirectory: true)
        let output = root.appendingPathComponent("images", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            guard try verifyReviewRegressions(in: root) else {
                print("SELF TEST FAILED: identity, artifact I/O, or cache regressions")
                return 1
            }
            guard verifyRemoteResponsiveness() else {
                print("SELF TEST FAILED: remote responsiveness regression")
                return 1
            }
            guard verifyOpticalMediaDetection() else {
                print("SELF TEST FAILED: diskutil media classification used drive capabilities")
                return 1
            }
            guard verifyAmbiguousMetadataSelection() else {
                print("SELF TEST FAILED: ambiguous online metadata was selected automatically")
                return 1
            }
            let unreadableIdentity = DiscIdentityService(devicePaths: { _ in [root.path] }).identify(
                bsdName: "self-test-unreadable-device",
                discType: .dataCD,
                volumeLabel: "Unreadable test disc",
                sizeBytes: 1_000_000
            )
            guard unreadableIdentity.kind == "metadata-v1",
                  unreadableIdentity.confidence == 1 else {
                print("SELF TEST FAILED: unreadable device sampling did not fall back safely")
                return 1
            }
            guard ChangerService.returnDiscState(
                driveHasDisc: false,
                destinationFull: true
            ) == .complete,
            ChangerService.returnDiscState(
                driveHasDisc: true,
                destinationFull: false
            ) == .safeToMove,
            ChangerService.returnDiscState(
                driveHasDisc: true,
                destinationFull: true
            ) == .unsafe,
            ChangerService.returnDiscState(
                driveHasDisc: false,
                destinationFull: false
            ) == .unsafe else {
                print("SELF TEST FAILED: safe return reconciliation accepted an ambiguous state")
                return 1
            }
            guard ProcessChangerService.shouldRetryInventory(.notResponding),
                  ProcessChangerService.shouldRetryInventory(.ownedElsewhere),
                  ProcessChangerService.shouldRetryInventory(.commandFailed("GET ELEMENT MAP")),
                  !ProcessChangerService.shouldRetryInventory(.slotEmpty(1)),
                  !ProcessChangerService.shouldRetryInventory(.moveFailed("ambiguous state")) else {
                print("SELF TEST FAILED: helper inventory retry classification is unsafe")
                return 1
            }
            guard verifyCarouselBatchOperation() else {
                print("SELF TEST FAILED: software carousel coordination was unsafe")
                return 1
            }
            guard try verifyRipOutputModes(in: root) else {
                print("SELF TEST FAILED: rip output modes or DVD helper discovery were invalid")
                return 1
            }

            let lockURL = root.appendingPathComponent("process.lock")
            let processLock = try ProcessInstanceLock(url: lockURL)
            do {
                _ = try ProcessInstanceLock(url: lockURL)
                print("SELF TEST FAILED: a second process lock was accepted")
                return 1
            } catch ProcessInstanceLockError.alreadyRunning {
                _ = processLock // Keep ownership for the duration of the test.
            }

            let database = Database(databaseURL: root.appendingPathComponent("catalog.sqlite"))
            let catalog = CatalogService(database: database, sessionId: "self-test-session")
            let mockState = MockChangerState(slotCount: 12)
            let changer = MockChangerService(state: mockState)
            let mount = MockMountService(state: mockState)
            let imaging = MockImagingService(imageDurationRange: 0.01...0.02)
            try changer.connect()

            let occupied = try changer.getSlotStatus().filter(\.isFull)
            guard occupied.count >= 3 else {
                print("SELF TEST FAILED: mock changer did not create enough occupied slots")
                return 1
            }
            let queue = Array(occupied.prefix(3))

            let first = BatchOperationState()
            guard runBatch(
                state: first,
                slots: queue,
                output: output,
                policy: .skipExisting,
                changer: changer,
                mount: mount,
                imaging: imaging,
                catalog: catalog
            ) else {
                print("SELF TEST FAILED: first batch timed out")
                return 1
            }
            guard first.completedSlots.count == queue.count,
                  first.skippedSlots.isEmpty,
                  first.failedSlots.isEmpty,
                  first.haltReason == nil else {
                print("SELF TEST FAILED: first batch result was \(first.statusText)")
                return 1
            }

            let refreshed = try changer.getSlotStatus()
            let secondQueue = queue.compactMap { original in refreshed.first(where: { $0.id == original.id }) }
            let second = BatchOperationState()
            guard runBatch(
                state: second,
                slots: secondQueue,
                output: output,
                policy: .skipExisting,
                changer: changer,
                mount: mount,
                imaging: imaging,
                catalog: catalog
            ) else {
                print("SELF TEST FAILED: duplicate batch timed out")
                return 1
            }
            guard second.completedSlots.isEmpty,
                  second.skippedSlots.count == queue.count,
                  second.failedSlots.isEmpty,
                  second.haltReason == nil else {
                print("SELF TEST FAILED: duplicate policy result was \(second.statusText)")
                return 1
            }

            // Catalog ordering follows timestamps, which can cross a second
            // during a batch. Keep fixtures aligned with the slot queue below.
            let initialEntries = catalog.getCatalogEntries()
            let entries = queue.compactMap { slot in
                initialEntries.first(where: { $0.disc.slotId == slot.id })
            }
            guard entries.count == queue.count,
                  database.getMostRecentSessionId() == "self-test-session",
                  entries.allSatisfy({
                      $0.sightings.count == 2
                          && $0.existingRips.count == 1
                          && $0.existingRips[0].backupHash?.count == 64
                  }) else {
                print("SELF TEST FAILED: catalog did not retain sightings and rip paths")
                return 1
            }

            guard entries.allSatisfy({ entry in
                guard let rip = entry.latestExistingRip else { return false }
                let sidecar = URL(fileURLWithPath: rip.backupPath)
                    .deletingPathExtension().appendingPathExtension("metadata.json")
                guard let data = try? Data(contentsOf: sidecar),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                return object["schema"] as? String == "discbot.metadata.v1"
                    && object["fingerprint"] as? String == entry.disc.fingerprint
            }) else {
                print("SELF TEST FAILED: rip metadata sidecars were not created")
                return 1
            }

            let editedMetadata = DiscMetadata(
                artist: "Self Test Artist",
                album: "Self Test Album",
                year: "2026",
                genre: "Test",
                tracks: [.init(number: 1, title: "Track One", duration: 123.5)],
                source: .manual,
                providerID: nil,
                overview: "Edited metadata",
                artworkURL: nil
            )
            guard let editedID = entries[1].disc.id,
                  let edited = catalog.updateMetadata(discId: editedID, metadata: editedMetadata),
                  edited.metadataUserEdited,
                  edited.album == "Self Test Album",
                  edited.metadataTracks?.first?.duration == 123.5,
                  let editedRip = entries[1].latestExistingRip else {
                print("SELF TEST FAILED: edited catalog metadata was not persisted")
                return 1
            }
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 8, bitsPerPixel: 32
            ), let pixels = bitmap.bitmapData else {
                print("SELF TEST FAILED: could not create artwork fixture")
                return 1
            }
            for offset in stride(from: 0, to: 16, by: 4) {
                pixels[offset] = 42; pixels[offset + 1] = 118; pixels[offset + 2] = 214; pixels[offset + 3] = 255
            }
            guard let fixture = bitmap.representation(using: .jpeg, properties: [:]) else {
                print("SELF TEST FAILED: could not encode artwork fixture")
                return 1
            }
            let artworkService = MetadataService(
                artworkDirectory: root.appendingPathComponent("Artwork", isDirectory: true)
            )
            guard let cachedArtworkPath = artworkService.cacheArtwork(discID: editedID, data: fixture),
                  let cachedArtwork = artworkService.artworkData(path: cachedArtworkPath),
                  cachedArtwork.starts(with: [0xff, 0xd8]),
                  database.updateDiscArtworkPath(id: editedID, path: cachedArtworkPath)?.artworkPath == cachedArtworkPath,
                  database.getDisc(id: editedID)?.artworkPath == cachedArtworkPath else {
                print("SELF TEST FAILED: selected artwork path was not retained by the catalog")
                return 1
            }
            let editedSidecar = URL(fileURLWithPath: editedRip.backupPath)
                .deletingPathExtension().appendingPathExtension("metadata.json")
            guard let editedData = try? Data(contentsOf: editedSidecar),
                  let editedObject = try? JSONSerialization.jsonObject(with: editedData) as? [String: Any],
                  editedObject["title"] as? String == "Self Test Album",
                  (editedObject["tracks"] as? [[String: Any]])?.first?["duration"] as? Double == 123.5 else {
                print("SELF TEST FAILED: edited metadata did not update the rip sidecar")
                return 1
            }

            // A path that still exists but no longer matches its recorded size/hash
            // must never cause an automatic skip.
            guard let originalURL = entries[0].latestExistingRip.map({ URL(fileURLWithPath: $0.backupPath) }) else {
                print("SELF TEST FAILED: missing original image for integrity test")
                return 1
            }
            try Data("CORRUPTED".utf8).write(to: originalURL)
            let integrityRetry = BatchOperationState()
            guard runBatch(
                state: integrityRetry,
                slots: [secondQueue[0]],
                output: output,
                policy: .skipExisting,
                changer: changer,
                mount: mount,
                imaging: imaging,
                catalog: catalog
            ), integrityRetry.completedSlots == [secondQueue[0].id], integrityRetry.skippedSlots.isEmpty else {
                print("SELF TEST FAILED: corrupt prior image retry: \(integrityRetry.statusText), failures: \(integrityRetry.failedSlots)")
                return 1
            }

            let beforeReplace = catalog.getCatalogEntries()
                .first(where: { $0.id == entries[0].id })?.latestExistingRip
            let replacement = BatchOperationState()
            guard runBatch(
                state: replacement,
                slots: [secondQueue[0]],
                output: output,
                policy: .replaceExisting,
                changer: changer,
                mount: mount,
                imaging: imaging,
                catalog: catalog
            ), replacement.completedSlots == [secondQueue[0].id],
               replacement.replacedSlots == [secondQueue[0].id],
               replacement.failedSlots.isEmpty else {
                print("SELF TEST FAILED: replace-existing policy did not complete")
                return 1
            }
            if let oldPath = beforeReplace?.backupPath,
               FileManager.default.fileExists(atPath: oldPath) {
                print("SELF TEST FAILED: replace-existing left the superseded verified image in place")
                return 1
            }

            let statistics = catalog.getStatistics()
            guard statistics.skippedRips == queue.count,
                  statistics.replacedRips == 1,
                  statistics.availableImages == queue.count,
                  catalog.getRecentRipLog().contains(where: { $0.eventType == "batch_completed" }) else {
                print("SELF TEST FAILED: rip logs or collection statistics are incomplete")
                return 1
            }

            let pipelineDatabase = Database(databaseURL: root.appendingPathComponent("pipeline.sqlite"))
            let pipelineCatalog = CatalogService(
                database: pipelineDatabase,
                sessionId: "pipeline-self-test"
            )
            let pipelineState = MockChangerState(slotCount: 12)
            let pipelineChanger = MockChangerService(state: pipelineState)
            let pipelineMount = MockMountService(state: pipelineState)
            let pipelineImaging = SelfTestStagedImagingService(waitForSecondRead: true)
            try pipelineChanger.connect()
            let pipelineSlots = Array(try pipelineChanger.getSlotStatus().filter(\.isFull).prefix(4))
            let pipelinedBatch = BatchOperationState()
            guard pipelineSlots.count == 4,
                  runBatch(
                    state: pipelinedBatch,
                    slots: pipelineSlots,
                    output: output.appendingPathComponent("pipeline", isDirectory: true),
                    policy: .imageAgain,
                    outputMode: .iso,
                    changer: pipelineChanger,
                    mount: pipelineMount,
                    imaging: pipelineImaging,
                    catalog: pipelineCatalog
                  ),
                  pipelineImaging.didOverlapReadAndFinalization,
                  pipelinedBatch.completedSlots.count == 4,
                  pipelineImaging.maximumOutstandingReads <= 2,
                  pipelinedBatch.finalizingDiscCount == 0,
                  pipelinedBatch.failedSlots.isEmpty,
                  !pipelineMount.isDiscPresent() else {
                print("SELF TEST FAILED: DVD pipeline: \(pipelinedBatch.statusText), overlap=\(pipelineImaging.didOverlapReadAndFinalization), outstanding=\(pipelineImaging.maximumOutstandingReads), failures=\(pipelinedBatch.failedSlots)")
                return 1
            }

            let stagedCancellationState = MockChangerState(slotCount: 12)
            let stagedCancellationChanger = MockChangerService(state: stagedCancellationState)
            let stagedCancellationMount = MockMountService(state: stagedCancellationState)
            try stagedCancellationChanger.connect()
            let stagedCancellationSlot = try stagedCancellationChanger.getSlotStatus().first(where: \.isFull)!
            let stagedCancellation = BatchOperationState()
            guard runBatch(
                state: stagedCancellation,
                slots: [stagedCancellationSlot],
                output: output.appendingPathComponent("pipeline-cancel", isDirectory: true),
                policy: .imageAgain,
                outputMode: .iso,
                changer: stagedCancellationChanger,
                mount: stagedCancellationMount,
                imaging: SelfTestStagedImagingService(),
                catalog: CatalogService(
                    database: Database(databaseURL: root.appendingPathComponent("pipeline-cancel.sqlite")),
                    sessionId: "pipeline-cancel-self-test"
                ),
                cancelAfter: 0.1
            ), stagedCancellation.isCancelled,
               stagedCancellation.completedSlots.isEmpty,
               stagedCancellation.cancelledSlots == [stagedCancellationSlot.id],
               stagedCancellation.failedSlots.isEmpty,
               stagedCancellation.finalizingDiscCount == 0,
               !stagedCancellationMount.isDiscPresent() else {
                print("SELF TEST FAILED: cancelling background DVD finalization was unsafe")
                return 1
            }

            // If Catalina has retained the changer LUN but dropped the optical
            // drive, reject the batch before moving any media and persist the
            // diagnostic even though no rip-history row exists yet.
            let unavailableMount = MockMountService(state: mockState)
            unavailableMount.opticalDriveAvailable = false
            let unavailable = BatchOperationState()
            let preflightSlot = try changer.getSlotStatus().first(where: { $0.isFull })!
            guard runBatch(
                state: unavailable,
                slots: [preflightSlot],
                output: output,
                policy: .skipExisting,
                changer: changer,
                mount: unavailableMount,
                imaging: imaging,
                catalog: catalog
            ), unavailable.completedSlots.isEmpty,
               unavailable.failedSlots.count == 1,
               unavailable.haltReason?.contains("macOS cannot see its optical drive") == true,
               !unavailableMount.isDiscPresent(),
               catalog.getRecentRipLog().contains(where: {
                   $0.eventType == "batch_failed"
                       && $0.message.contains("macOS cannot see its optical drive")
               }) else {
                print("SELF TEST FAILED: missing optical-drive preflight or durable failure activity")
                return 1
            }

            let cancelled = BatchOperationState()
            guard runBatch(
                state: cancelled,
                slots: [secondQueue[0]],
                output: output,
                policy: .imageAgain,
                changer: changer,
                mount: mount,
                imaging: MockImagingService(imageDurationRange: 0.5...0.5),
                catalog: catalog,
                cancelAfter: 0.08
            ), cancelled.isCancelled else {
                print("SELF TEST FAILED: cancellation did not complete safely")
                return 1
            }
            guard !mount.isDiscPresent() else {
                print("SELF TEST FAILED: a disc was left in the drive")
                return 1
            }

            let currentDiscCancelled = BatchOperationState()
            let currentCancellationQueue = Array(secondQueue.prefix(2))
            guard currentCancellationQueue.count == 2,
                  runBatch(
                    state: currentDiscCancelled,
                    slots: currentCancellationQueue,
                    output: output,
                    policy: .imageAgain,
                    changer: changer,
                    mount: mount,
                    imaging: MockImagingService(imageDurationRange: 0.5...0.5),
                    catalog: catalog,
                    cancelCurrentAfter: 0.08
                  ),
                  !currentDiscCancelled.isCancelled,
                  currentDiscCancelled.cancelledSlots == [currentCancellationQueue[0].id],
                  currentDiscCancelled.completedSlots == [currentCancellationQueue[1].id],
                  currentDiscCancelled.failedSlots.isEmpty,
                  !mount.isDiscPresent() else {
                print("SELF TEST FAILED: current-disc cancellation did not continue safely")
                return 1
            }

            // Cancelling a catalog-only scan while a disc is in transit must
            // finish the current disc's return before stopping the queue.
            let scanDatabase = Database(databaseURL: root.appendingPathComponent("scan.sqlite"))
            let scanCatalog = CatalogService(database: scanDatabase, sessionId: "scan-self-test")
            let scanMockState = MockChangerState(slotCount: 12)
            let scanBaseChanger = MockChangerService(state: scanMockState)
            let scanChanger = SelfTestSlowLoadChanger(base: scanBaseChanger, delay: 0.12)
            let scanMount = MockMountService(state: scanMockState)
            try scanChanger.connect()
            let scanSlots = Array(try scanChanger.getSlotStatus().filter(\.isFull).prefix(2)).map {
                Slot(id: $0.id, address: $0.address, isFull: true, discType: .unscanned)
            }
            guard scanSlots.count == 2 else {
                print("SELF TEST FAILED: mock changer did not create enough scan slots")
                return 1
            }
            let cancelledScan = BatchOperationState()
            guard runUnknownScan(
                state: cancelledScan,
                slots: scanSlots,
                changer: scanChanger,
                mount: scanMount,
                imaging: MockImagingService(imageDurationRange: 0.01...0.01),
                catalog: scanCatalog,
                cancelAfter: 0.03
            ), cancelledScan.isCancelled,
               cancelledScan.completedSlots == [scanSlots[0].id],
               cancelledScan.failedSlots.isEmpty,
               !scanMount.isDiscPresent() else {
                print("SELF TEST FAILED: cancelled disc scan did not return the current disc")
                return 1
            }
            let restoredScanSlots = try scanChanger.getSlotStatus()
            guard scanSlots.allSatisfy({ id in
                restoredScanSlots.first(where: { $0.id == id.id })?.isFull == true
            }) else {
                print("SELF TEST FAILED: cancelled disc scan changed source-slot occupancy")
                return 1
            }

            guard try verifyRawCDAudioImaging(in: output) else {
                print("SELF TEST FAILED: BIN/CUE generation or cancellation cleanup was invalid")
                return 1
            }

            let legacyURL = root.appendingPathComponent("legacy.sqlite")
            guard createLegacyDatabase(at: legacyURL) else {
                print("SELF TEST FAILED: could not create the legacy migration fixture")
                return 1
            }
            let migratedCatalog = CatalogService(
                database: Database(databaseURL: legacyURL),
                sessionId: "migration-test"
            )
            let migratedEntries = migratedCatalog.getCatalogEntries()
            guard migratedEntries.count == 1,
                  migratedEntries[0].disc.fingerprint == "legacy-slot:42",
                  migratedEntries[0].disc.fingerprintConfidence == 0,
                  migratedEntries[0].sightings.first?.slotId == 42,
                  migratedEntries[0].rips.count == 1,
                  migratedEntries[0].rips[0].backupStatus == "completed" else {
                print("SELF TEST FAILED: legacy catalog and rip history were not preserved")
                return 1
            }

            guard verifyRemoteServerAPI(in: output) else {
                print("SELF TEST FAILED: remote server authentication, destination policy, or job exclusivity failed")
                return 1
            }

            print("SELF TEST PASSED: malformed HTTP framing, concurrent remote cancellation/SSE, weak duplicate protection, sampled-identity collisions, cancellable copy/hash, snapshot invalidation, bounded pipelined batch rip, ISO/DVD-folder output, staged-finalization cancellation, DVD helper discovery, verified duplicate handling, safe replacement, logs/stats, metadata catalog/sidecars, raw CD BIN/CUE, cancellation cleanup, safe return, catalog migration/history, and authenticated remote push API")
            return 0
        } catch {
            print("SELF TEST FAILED: \(error.localizedDescription)")
            return 1
        }
    }

    private static func verifyOpticalMediaDetection() -> Bool {
        let audioInfo: [String: Any] = [
            "Content": "CD_partition_scheme",
            "FilesystemName": "CD-DA",
            "FilesystemType": "cddafs",
            "FilesystemUserVisibleName": "CD Audio",
            "OpticalMediaType": "CD-ROM",
            // This is the field that caused the production regression. It
            // describes drive capability and must not turn an audio CD into a DVD.
            "OpticalDeviceType": "CD-ROM, CD-R, DVD-ROM, DVD-R, DVD+RW",
            "VolumeName": "Audio CD"
        ]
        let dvdInfo: [String: Any] = [
            "Content": "DVD_partition_scheme",
            "FilesystemName": "UDF",
            "OpticalMediaType": "DVD-ROM"
        ]
        let dataCDInfo: [String: Any] = [
            "Content": "CD_ROM_Mode_1",
            "FilesystemName": "ISO 9660",
            "OpticalMediaType": "CD-ROM"
        ]
        guard
            let audioData = try? PropertyListSerialization.data(
                fromPropertyList: audioInfo, format: .xml, options: 0
            ),
            let dvdData = try? PropertyListSerialization.data(
                fromPropertyList: dvdInfo, format: .xml, options: 0
            ),
            let dataCDData = try? PropertyListSerialization.data(
                fromPropertyList: dataCDInfo, format: .xml, options: 0
            )
        else { return false }

        return ImagingService.discType(fromDiskutilInfo: audioData) == .audioCDDA
            && ImagingService.discType(fromDiskutilInfo: dvdData) == .dvd
            && ImagingService.discType(fromDiskutilInfo: dataCDData) == .dataCD
    }

    private static func verifyAmbiguousMetadataSelection() -> Bool {
        let first = MetadataCandidate(
            id: "one", provider: "musicBrainz", title: "Same Album", artist: "Artist",
            year: "2001", genre: nil, overview: nil, artworkURL: nil, tracks: nil
        )
        let second = MetadataCandidate(
            id: "two", provider: "musicBrainz", title: "Same Album", artist: "Artist",
            year: "2002", genre: nil, overview: nil, artworkURL: nil, tracks: nil
        )
        return MetadataService.unambiguousAudioCandidate([first]) == first
            && MetadataService.unambiguousAudioCandidate([first, second]) == nil
            && MetadataService.unambiguousVideoCandidate([first], query: "Same Album") == first
            && MetadataService.unambiguousVideoCandidate([first, second], query: "Same Album") == nil
    }

    private static func verifyRipOutputModes(in root: URL) throws -> Bool {
        guard RipOutputMode.automatic.preferredExtension(for: .audioCDDA) == "zip",
              RipOutputMode.iso.preferredExtension(for: .audioCDDA) == "zip",
              RipOutputMode.dvdFolder.preferredExtension(for: .audioCDDA) == "zip",
              RipOutputMode.automatic.preferredExtension(for: .dvd) == "iso",
              RipOutputMode.iso.preferredExtension(for: .dvd) == "iso",
              RipOutputMode.dvdFolder.preferredExtension(for: .dvd) == "dvdmedia",
              DVDVideoImagingService.percentage(in: "Copying title set 42.5%") == 0.425,
              DVDVideoImagingService.percentage(in: "Copying 180%") == 1,
              DVDVideoImagingService.sanitizedVolumeName("A/B:C") == "A_B_C" else {
            return false
        }

        let dvdFolder = root.appendingPathComponent("folder-test.dvdmedia", isDirectory: true)
        let videoTS = dvdFolder.appendingPathComponent("VIDEO_TS", isDirectory: true)
        try FileManager.default.createDirectory(at: videoTS, withIntermediateDirectories: true)
        let ifo = videoTS.appendingPathComponent("VIDEO_TS.IFO")
        let vob = videoTS.appendingPathComponent("VTS_01_1.VOB")
        try Data(repeating: 0x49, count: 128).write(to: ifo)
        try Data(repeating: 0x56, count: 512).write(to: vob)
        let folderSize = try RipArtifactInspector.sizeBytes(at: dvdFolder)
        let folderRip = BackupRecord(
            discId: 1,
            backupPath: dvdFolder.path,
            backupSizeBytes: folderSize,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            backupStatus: "completed"
        )
        guard folderSize == 640, folderRip.fileExists else { return false }
        try Data(repeating: 0x58, count: 513).write(to: vob)
        guard !folderRip.fileExists else { return false }

        let folderDatabase = Database(databaseURL: root.appendingPathComponent("folder-catalog.sqlite"))
        let folderCatalog = CatalogService(database: folderDatabase, sessionId: "folder-output-test")
        let folderDisc = DiscRecord(
            fingerprint: "folder-output-fingerprint",
            fingerprintKind: "self-test",
            fingerprintConfidence: 3,
            slotId: 1,
            volumeLabel: "Folder Test",
            discType: "dvd"
        )
        guard let storedFolderDisc = folderDatabase.upsertDisc(
            folderDisc,
            sessionId: "folder-output-test"
        ), let folderRipID = folderCatalog.startRip(
            disc: storedFolderDisc,
            slotId: 1,
            proposedPath: dvdFolder
        ) else { return false }
        try folderCatalog.recordRipCompleted(
            ripId: folderRipID,
            finalURL: dvdFolder,
            disc: storedFolderDisc
        )
        guard folderCatalog.latestVerifiedRip(disc: storedFolderDisc) != nil else { return false }
        try Data(repeating: 0x59, count: 513).write(to: vob)
        guard folderCatalog.latestVerifiedRip(disc: storedFolderDisc) == nil else { return false }

        let fakeHome = root.appendingPathComponent("dvd-helper-home", isDirectory: true)
        let fakeRoot = fakeHome.appendingPathComponent(
            "Library/Application Support/Discbot/DVDTools",
            isDirectory: true
        )
        let fakeExecutable = fakeRoot.appendingPathComponent("bin/dvdbackup")
        try FileManager.default.createDirectory(
            at: fakeExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fakeRoot.appendingPathComponent("lib", isDirectory: true),
            withIntermediateDirectories: true
        )
        let fakeDVDBackup = """
        #!/bin/sh
        output=
        name=DVD
        for argument in "$@"; do
          case "$argument" in
            --output=*) output=${argument#--output=} ;;
            --name=*) name=${argument#--name=} ;;
          esac
        done
        test -n "$output" || exit 2
        mkdir -p "$output/$name/VIDEO_TS" || exit 3
        printf 'DVDVIDEO-IFO' > "$output/$name/VIDEO_TS/VIDEO_TS.IFO"
        dd if=/dev/zero of="$output/$name/VIDEO_TS/VTS_01_1.VOB" bs=1048576 count=2 2>/dev/null
        echo 'Copying title set 100%'
        """
        try Data((fakeDVDBackup + "\n").utf8).write(to: fakeExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeExecutable.path
        )
        guard let located = DVDVideoImagingService.locateTool(
            homeDirectory: fakeHome,
            bundleURL: nil
        ), located.executable == fakeExecutable,
           located.libraryDirectory == fakeRoot.appendingPathComponent("lib", isDirectory: true) else {
            return false
        }

        let dvdService = DVDVideoImagingService(installation: located)
        let folderURL = try dvdService.createDVDMediaFolder(
            bsdName: "disk-self-test",
            outputPath: root.appendingPathComponent("dvd-copy.tmp"),
            volumeName: "DVD/Test",
            totalBytes: 2_097_164,
            control: nil,
            progress: { _ in }
        )
        guard folderURL.pathExtension == "dvdmedia",
              FileManager.default.fileExists(
                  atPath: folderURL.appendingPathComponent("VIDEO_TS/VIDEO_TS.IFO").path
              ),
              ((try? RipArtifactInspector.sizeBytes(at: folderURL)) ?? 0) > 1_048_576 else {
            return false
        }

        let isoURL = try dvdService.createISO(
            bsdName: "rdisk-self-test",
            outputPath: root.appendingPathComponent("dvd-image.tmp"),
            volumeName: "DVD/Test",
            totalBytes: 2_097_164,
            control: nil,
            progress: { _ in }
        )
        guard isoURL.pathExtension == "iso",
              ((try? RipArtifactInspector.sizeBytes(at: isoURL)) ?? 0) > 1_048_576 else {
            return false
        }

        let staged = try dvdService.stage(
            bsdName: "disk-self-test",
            outputPath: root.appendingPathComponent("discarded-copy.tmp"),
            volumeName: "Discarded",
            format: .dvdFolder,
            totalBytes: 2_097_164,
            control: nil,
            progress: { _ in }
        )
        staged.discard()
        guard !FileManager.default.fileExists(atPath: staged.expectedFinalURL.path) else {
            return false
        }

        let cancelledControl = ImagingService.ImagingControl()
        cancelledControl.cancel()
        do {
            _ = try dvdService.createDVDMediaFolder(
                bsdName: "disk-self-test",
                outputPath: root.appendingPathComponent("cancelled-copy.tmp"),
                volumeName: "Cancelled",
                totalBytes: nil,
                control: cancelledControl,
                progress: { _ in }
            )
            return false
        } catch ImagingError.cancelled {
            return true
        } catch {
            return false
        }
    }

    private static func verifyReviewRegressions(in root: URL) throws -> Bool {
        for header in ["Content-Length:", "Content-Length: -1", "Content-Length: +2",
                       "Content-Length: 9223372036854775807", "Content-Length: 99999999999999999999999",
                       "Content-Length: 2\r\nContent-Length: 2", "Transfer-Encoding: chunked"] {
            let bytes = Data("POST / HTTP/1.1\r\n\(header)\r\n\r\n".utf8)
            guard case .rejected = RemoteHTTPRequest.framing(bytes) else {
                print("SELF TEST DETAIL: accepted malformed framing \(header)")
                return false
            }
        }
        let prefix = Data("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8)
        guard RemoteHTTPRequest.framing(prefix) == .incomplete,
              RemoteHTTPRequest.framing(prefix + Data("cd".utf8)) == .ready(prefix.count + 2) else { return false }

        let original = root.appendingPathComponent("sample-a.bin")
        let changed = root.appendingPathComponent("sample-b.bin")
        var bytes = Data(repeating: 0, count: 4 * 1024 * 1024)
        try bytes.write(to: original)
        bytes[128 * 1024] = 1 // Outside every sampled region.
        try bytes.write(to: changed)
        let first = DiscIdentityService(devicePaths: { _ in [original.path] }).identify(
            bsdName: "fixture", discType: .dataCD, volumeLabel: "A", sizeBytes: Int64(bytes.count)
        )
        let second = DiscIdentityService(devicePaths: { _ in [changed.path] }).identify(
            bsdName: "fixture", discType: .dataCD, volumeLabel: "B", sizeBytes: Int64(bytes.count)
        )
        guard first.fingerprint == second.fingerprint, first.confidence == 1, second.confidence == 1 else { return false }

        let partial = root.appendingPathComponent("cancelled-copy.bin")
        var checks = 0
        do {
            try DVDVideoImagingService.copyArtifact(from: changed, to: partial) {
                checks += 1
                if checks == 6 { throw ImagingError.cancelled }
            }
            return false
        } catch ImagingError.cancelled {}
        guard !FileManager.default.fileExists(atPath: partial.path) else { return false }
        try DVDVideoImagingService.copyArtifact(from: changed, to: partial, checkCancellation: {})
        guard try Data(contentsOf: partial) == bytes else { return false }
        // Cancellation midway through hashing must propagate, not return a hash.
        checks = 0
        do {
            _ = try RipArtifactInspector.integrityHash(at: partial) {
                checks += 1
                if checks == 6 { throw ImagingError.cancelled }
            }
            return false
        } catch ImagingError.cancelled {}
        let folder = root.appendingPathComponent("copy-source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("track.vob"))
        let copiedFolder = root.appendingPathComponent("copied.dvdmedia")
        try DVDVideoImagingService.copyArtifact(from: folder, to: copiedFolder, checkCancellation: {})
        guard try RipArtifactInspector.integrityHash(at: folder) == RipArtifactInspector.integrityHash(at: copiedFolder) else { return false }

        // Exercise the actual batch path without contacting metadata providers.
        let defaultsName = "discbot-review-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(MetadataProvider.none.rawValue, forKey: MetadataService.audioProviderKey)
        defaults.set(MetadataProvider.none.rawValue, forKey: MetadataService.videoProviderKey)
        let weakOutput = root.appendingPathComponent("weak-images", isDirectory: true)
        try FileManager.default.createDirectory(at: weakOutput, withIntermediateDirectories: true)
        for (kind, confidence) in [("metadata-v1", 1), ("sampled-content-v1", 2)] {
            let database = Database(databaseURL: root.appendingPathComponent("weak-\(kind).sqlite"))
            let catalog = CatalogService(database: database,
                metadataService: MetadataService(defaults: defaults, artworkDirectory: root.appendingPathComponent("artwork")),
                identityService: SelfTestFixedIdentity(
                identity: DiscIdentity(fingerprint: "weak-\(kind)", kind: kind, confidence: confidence)
            ), sessionId: "weak")
            let hardware = MockChangerState(slotCount: 12)
            let changer = MockChangerService(state: hardware)
            let mount = MockMountService(state: hardware)
            try changer.connect()
            let slot = try changer.getSlotStatus().first(where: \.isFull)!
            for policy in [DuplicatePolicy.skipExisting, .skipExisting, .replaceExisting] {
                let batch = BatchOperationState()
                guard runBatch(
                    state: batch, slots: [slot], output: weakOutput,
                    policy: policy, changer: changer, mount: mount,
                    imaging: MockImagingService(imageDurationRange: 0.001...0.002), catalog: catalog
                ), batch.completedSlots == [slot.id], batch.skippedSlots.isEmpty,
                   batch.replacedSlots.isEmpty, batch.failedSlots.isEmpty else {
                    print("SELF TEST DETAIL: weak identity \(kind), \(policy): \(batch.statusText); \(batch.failedSlots)")
                    return false
                }
            }
            guard let entry = catalog.getCatalogEntries().first,
                  !entry.disc.hasReliableIdentity, entry.existingRips.count == 3 else { return false }

            let cache = RemoteLibraryCache()
            let now = Date()
            var builds = 0
            let build = { () -> [String: Any] in builds += 1; return ["build": builds] }
            let revision = database.revision
            _ = cache.value(revision: revision, now: now, build: build)
            _ = cache.value(revision: revision, now: now.addingTimeInterval(2), build: build)
            guard builds == 1 else { return false }
            catalog.recordActivity(type: "test", message: "Invalidate snapshot")
            guard database.revision != revision else { return false }
            _ = cache.value(revision: database.revision, now: now.addingTimeInterval(3), build: build)
            guard builds == 2 else { return false }
            _ = cache.value(revision: database.revision, now: now.addingTimeInterval(64), build: build)
            guard builds == 3 else { return false }
        }
        return true
    }

    private static func verifyRemoteResponsiveness() -> Bool {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let provider = SelfTestRemoteControlProvider()
        provider.searchHook = { started.signal(); _ = release.wait(timeout: .now() + 8) }
        let controller = RemoteAPIController(
            control: provider, token: { "concurrency-test" }, destinations: { [] }, updateDestinations: { _ in }
        )
        var status = ""
        let server = RemoteControlServer(controller: controller) { status = $0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer {
            for _ in 0..<3 { release.signal() }
            session.invalidateAndCancel()
            server.stop()
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }
        var port: UInt16 = 0
        for _ in 0..<5 {
            port = UInt16.random(in: 49152...65535)
            status = ""
            do { try server.start(port: port, localhostOnly: true) } catch {
                print("SELF TEST DETAIL: listener failed: \(error)")
                continue
            }
            if wait({ !status.isEmpty }), status.hasPrefix("Listening") { break }
        }
        guard status.hasPrefix("Listening") else {
            print("SELF TEST DETAIL: listener status: \(status)")
            return false
        }
        func request(_ path: String, body: String? = nil) -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.setValue("Bearer concurrency-test", forHTTPHeaderField: "Authorization")
            if let body = body {
                request.httpMethod = "POST"
                request.httpBody = Data(body.utf8)
            }
            return request
        }
        for _ in 0..<3 {
            session.dataTask(with: request("/api/v1/metadata/search", body: "{\"provider\":\"tmdb\",\"query\":\"fixture\"}")) { _, _, _ in }.resume()
        }
        var searches = 0
        guard wait({
            while started.wait(timeout: .now()) == .success { searches += 1 }
            return searches == 3
        }) else {
            print("SELF TEST DETAIL: only \(searches) slow requests entered workers")
            return false
        }
        var cancelStatus: Int?
        session.dataTask(with: request("/api/v1/jobs/cancel", body: "{}")) { _, response, _ in
            DispatchQueue.main.async { cancelStatus = (response as? HTTPURLResponse)?.statusCode }
        }.resume()
        // No fake batch is active: a prompt 404 proves command dispatch ran.
        guard wait({ cancelStatus != nil }), cancelStatus == 404 else {
            print("SELF TEST DETAIL: concurrent cancellation status \(String(describing: cancelStatus))")
            return false
        }
        let delegate = SelfTestEventDelegate()
        let events = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { events.invalidateAndCancel() }
        events.dataTask(with: request("/api/v1/events")).resume()
        guard wait({ delegate.receivedSnapshot }) else {
            print("SELF TEST DETAIL: no concurrent SSE snapshot")
            return false
        }
        return true
    }

    private static func verifyRemoteServerAPI(in output: URL) -> Bool {
        let destination = RemoteRipDestination(name: "Self Test", path: output.path)
        var configuredDestinations = [destination]
        let remoteShare = output.appendingPathComponent("remote-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: remoteShare, withIntermediateDirectories: true)
        let remoteResolver = RemoteDestinationResolver { shareURL in
            guard shareURL.absoluteString == "smb://media-server/Archive" else {
                throw RemoteDestinationError.mountFailed(EINVAL)
            }
            return remoteShare
        }
        let provider = SelfTestRemoteControlProvider()
        let controller = RemoteAPIController(
            control: provider,
            token: { "test-token" },
            destinations: { configuredDestinations },
            updateDestinations: { configuredDestinations = $0 },
            destinationRoots: { [output.deletingLastPathComponent()] },
            remoteDestinationResolver: remoteResolver
        )

        let health = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/api/v1/health", headers: [:], body: Data()
        ))
        guard health.status == 200 else { return false }

        let webClient = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/", headers: [:], body: Data()
        ))
        guard webClient.status == 200,
              let webHTML = String(data: webClient.body, encoding: .utf8),
              webHTML.contains("id=\"carouselCanvas\""),
              webHTML.contains("class DiscbotCarousel3D"),
              webHTML.contains("updateCarousel3D(s)"),
              webHTML.contains("id=\"slotLoadButton\""),
              webHTML.contains("/api/v1/slots/action"),
              webHTML.contains("smb://nas/Media/Disc Images"),
              webHTML.contains("/api/v1/destinations/connect"),
              webHTML.contains("id=\"jobErrors\""),
              webHTML.contains("activity-type.failure"),
              webHTML.contains("id=\"scanUnknownButton\""),
              webHTML.contains("verified empty slots available"),
              webHTML.contains("unknown=Number(s.unknownSlots)"),
              webHTML.contains("/api/v1/jobs/scan"),
              webHTML.contains("<option value=\"dvdFolder\">"),
              webHTML.contains("id=\"metadataArtworkPreview\""),
              webHTML.contains(".cover.video,.cover-placeholder.video{aspect-ratio:2/3}"),
              webHTML.contains("function artworkShape(discType,provider)"),
              webHTML.contains("function artworkDataURL(buffer,contentType)"),
              webHTML.contains("response.arrayBuffer()"),
              webHTML.contains("const artworkLoads=[],renderedRows=rows.map"),
              webHTML.contains("artworkLoads.push(()=>loadArtwork"),
              webHTML.contains("$('library').replaceChildren(...renderedRows);artworkLoads.forEach"),
              webHTML.contains(".cover.pending{position:absolute"),
              !webHTML.contains("img.loading='lazy';art.append(placeholder)"),
              webHTML.contains("/api/v1/library/artwork/") else { return false }

        let unauthorized = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/api/v1/state", headers: [:], body: Data()
        ))
        guard unauthorized.status == 401 else { return false }

        let authorizedHeaders = ["authorization": "Bearer test-token"]
        let artwork = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/api/v1/library/artwork/7", headers: authorizedHeaders, body: Data()
        ))
        guard artwork.status == 200,
              artwork.contentType == "image/jpeg",
              artwork.body == provider.storedArtwork else { return false }
        let state = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/api/v1/state", headers: authorizedHeaders, body: Data()
        ))
        guard state.status == 200,
              let stateObject = try? JSONSerialization.jsonObject(with: state.body) as? [String: Any],
              let destinations = stateObject["destinations"] as? [[String: Any]],
              destinations.count == 1,
              destinations[0]["path"] == nil else { return false }

        let metadataConfig = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/api/v1/metadata/config", headers: authorizedHeaders, body: Data()
        ))
        guard metadataConfig.status == 200 else { return false }

        let metadataBody = Data("{\"discId\":7,\"title\":\"Edited\",\"artist\":\"Artist\",\"provider\":\"manual\"}".utf8)
        let metadataUpdate = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/metadata/update", headers: authorizedHeaders, body: metadataBody
        ))
        guard metadataUpdate.status == 200,
              provider.updatedMetadata?.0 == 7,
              provider.updatedMetadata?.1.album == "Edited" else { return false }

        let refresh = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/inventory/refresh", headers: authorizedHeaders, body: Data()
        ))
        let rescan = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/inventory/rescan", headers: authorizedHeaders, body: Data()
        ))
        guard refresh.status == 202, rescan.status == 202,
              provider.refreshed, provider.rescanned else { return false }

        let recovery = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/recovery/return-disc",
            headers: authorizedHeaders, body: Data()
        ))
        guard recovery.status == 202, provider.returnedLoadedDisc else { return false }

        let slotAction = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/slots/action", headers: authorizedHeaders,
            body: Data("{\"slot\":7,\"action\":\"unmount\"}".utf8)
        ))
        guard slotAction.status == 202,
              provider.slotAction?.0 == 7,
              provider.slotAction?.1 == .unmount else { return false }

        let scan = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/scan",
            headers: authorizedHeaders, body: Data("{}".utf8)
        ))
        guard scan.status == 202, provider.scanStarted else { return false }
        let cancelScan = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/cancel", headers: authorizedHeaders,
            body: Data("{\"id\":\"self-test-scan\"}".utf8)
        ))
        guard cancelScan.status == 202, provider.cancelled else { return false }
        provider.cancelled = false

        let carouselLoad = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/carousel/load", headers: authorizedHeaders,
            body: Data("{\"count\":3}".utf8)
        ))
        guard carouselLoad.status == 202,
              provider.carouselLoadCount == 3,
              provider.carouselLoadSlots == nil else { return false }

        let carouselAction = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/carousel/action", headers: authorizedHeaders,
            body: Data("{\"id\":\"self-test-carousel\",\"action\":\"retry\"}".utf8)
        ))
        guard carouselAction.status == 202,
              provider.carouselAction == .retry else { return false }

        let carouselUnload = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/carousel/unload", headers: authorizedHeaders,
            body: Data("{\"slots\":[4,7]}".utf8)
        ))
        guard carouselUnload.status == 202,
              provider.carouselUnloadSlots == [4, 7] else { return false }

        let authorizedEventRequest = RemoteHTTPRequest(
            method: "GET", path: "/api/v1/events", headers: authorizedHeaders, body: Data()
        )
        guard controller.isAuthorized(authorizedEventRequest),
              !controller.isAuthorized(RemoteHTTPRequest(
                method: "GET", path: "/api/v1/events", headers: [:], body: Data()
              )),
              let eventData = controller.eventSnapshotData(),
              let eventObject = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
              let eventState = eventObject["state"] as? [String: Any],
              let eventDestinations = eventState["destinations"] as? [[String: Any]],
              eventDestinations.count == 1,
              eventDestinations[0]["path"] == nil,
              eventObject["library"] as? [String: Any] != nil else { return false }

        let managedFolder = output.appendingPathComponent("managed", isDirectory: true)
        try? FileManager.default.createDirectory(at: managedFolder, withIntermediateDirectories: true)
        guard let addBody = try? JSONSerialization.data(withJSONObject: [
            "name": "Managed Test",
            "path": managedFolder.path
        ]) else { return false }
        let addDestination = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/destinations", headers: authorizedHeaders, body: addBody
        ))
        guard addDestination.status == 201,
              configuredDestinations.count == 2,
              let added = configuredDestinations.first(where: { $0.path == managedFolder.path }) else {
            print("SELF TEST DETAIL: destination add status=\(addDestination.status) count=\(configuredDestinations.count) body=\(String(data: addDestination.body, encoding: .utf8) ?? "")")
            return false
        }

        let rejectedDestination = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/destinations", headers: authorizedHeaders,
            body: Data("{\"path\":\"/etc\"}".utf8)
        ))
        guard rejectedDestination.status == 403 else {
            print("SELF TEST DETAIL: destination root rejection status=\(rejectedDestination.status)")
            return false
        }

        guard let removeBody = try? JSONSerialization.data(withJSONObject: ["id": added.id.uuidString]) else {
            return false
        }
        let removeDestination = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/destinations/remove", headers: authorizedHeaders,
            body: removeBody
        ))
        guard removeDestination.status == 200,
              configuredDestinations == [destination] else {
            print("SELF TEST DETAIL: destination remove status=\(removeDestination.status) count=\(configuredDestinations.count)")
            return false
        }

        let addRemote = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/destinations", headers: authorizedHeaders,
            body: Data("{\"name\":\"Remote archive\",\"path\":\"smb://media-server/Archive/Disc%20Images\"}".utf8)
        ))
        guard addRemote.status == 201,
              configuredDestinations.count == 2,
              let remote = configuredDestinations.first(where: { $0.isRemote }),
              remote.remoteURL == "smb://media-server/Archive/Disc%20Images",
              remote.path == remoteShare.appendingPathComponent("Disc Images").path,
              remote.isAvailable else { return false }

        let reconnectRemote = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/destinations/connect", headers: authorizedHeaders,
            body: Data("{\"id\":\"\(remote.id.uuidString)\"}".utf8)
        ))
        guard reconnectRemote.status == 200 else { return false }

        let passwordInURL = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/destinations", headers: authorizedHeaders,
            body: Data("{\"path\":\"smb://user:secret@media-server/Archive\"}".utf8)
        ))
        guard passwordInURL.status == 422 else { return false }

        let removeRemote = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/destinations/remove", headers: authorizedHeaders,
            body: Data("{\"id\":\"\(remote.id.uuidString)\"}".utf8)
        ))
        guard removeRemote.status == 200,
              configuredDestinations == [destination] else { return false }

        let body: [String: Any] = [
            "slots": [1, 2],
            "destinationId": destination.id.uuidString,
            "duplicatePolicy": DuplicatePolicy.replaceExisting.rawValue,
            "outputMode": RipOutputMode.iso.rawValue,
            "path": "/tmp/client-controlled-path-must-be-ignored"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        let start = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/rip", headers: authorizedHeaders, body: bodyData
        ))
        guard start.status == 202,
              provider.startedDestination == destination,
              provider.startedSlots == [1, 2],
              provider.startedPolicy == .replaceExisting,
              provider.startedOutputMode == .iso else { return false }

        let conflicting = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/rip", headers: authorizedHeaders, body: bodyData
        ))
        guard conflicting.status == 409 else { return false }

        let cancelCurrent = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/cancel-current", headers: authorizedHeaders,
            body: Data("{\"id\":\"self-test-job\"}".utf8)
        ))
        guard cancelCurrent.status == 202, provider.currentDiscCancelled else { return false }

        let cancel = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/cancel", headers: authorizedHeaders,
            body: Data("{\"id\":\"self-test-job\"}".utf8)
        ))
        guard cancel.status == 202, provider.cancelled else { return false }

        let raw = Data("GET /api/v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        return RemoteHTTPRequest.parse(raw)?.path == "/api/v1/health"
    }

    private static func runBatch(
        state: BatchOperationState,
        slots: [Slot],
        output: URL,
        policy: DuplicatePolicy,
        outputMode: RipOutputMode = .automatic,
        changer: ChangerServicing,
        mount: MountServicing,
        imaging: ImagingServicing,
        catalog: CatalogService,
        cancelAfter: TimeInterval? = nil,
        cancelCurrentAfter: TimeInterval? = nil
    ) -> Bool {
        var finished = false
        state.runImageAll(
            slots: slots,
            outputDirectory: output,
            duplicatePolicy: policy,
            outputMode: outputMode,
            driveFallbackSourceSlot: nil,
            changerService: changer,
            mountService: mount,
            imagingService: imaging,
            catalogService: catalog,
            onUpdate: {},
            onSlotLoaded: { _, _, _ in },
            onSlotEjected: { _ in },
            onComplete: { finished = true }
        )
        guard state.isRunning else {
            print("SELF TEST FAILED: batch did not claim its operation state synchronously")
            return false
        }
        if let cancelAfter = cancelAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + cancelAfter) {
                state.cancel()
            }
        }
        if let cancelCurrentAfter = cancelCurrentAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + cancelCurrentAfter) {
                _ = state.cancelCurrentDisc()
            }
        }

        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return finished
    }

    private static func runUnknownScan(
        state: BatchOperationState,
        slots: [Slot],
        changer: ChangerServicing,
        mount: MountServicing,
        imaging: ImagingServicing,
        catalog: CatalogService,
        cancelAfter: TimeInterval? = nil
    ) -> Bool {
        var finished = false
        state.runScanUnknown(
            slots: slots,
            driveFallbackSourceSlot: nil,
            changerService: changer,
            mountService: mount,
            imagingService: imaging,
            catalogService: catalog,
            onUpdate: {},
            onSlotLoaded: { _, _, _ in },
            onSlotCataloged: { _ in },
            onSlotEjected: { _ in },
            onComplete: { finished = true }
        )
        guard state.isRunning else { return false }
        if let cancelAfter = cancelAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + cancelAfter) {
                state.cancel()
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return finished
    }

    private static func verifyCarouselBatchOperation() -> Bool {
        let loadService = SelfTestCarouselChanger(fullSlots: [1])
        var loadSnapshots: [CarouselBatchSnapshot] = []
        let loadLock = NSLock()
        var loadFinished = false
        let load = CarouselBatchOperation(
            mode: .load,
            targets: [2, 3],
            service: loadService,
            onSnapshot: { value in
                loadLock.lock()
                loadSnapshots.append(value)
                loadLock.unlock()
            },
            onSlotState: { _, _ in },
            onFinished: { loadFinished = true }
        )
        load.start()
        guard waitUntil({ loadFinished }) else { return false }
        let loaded = load.snapshot()
        guard !loaded.running, !loaded.cancelled,
              loaded.completedSlots == [2, 3],
              loadService.fullSlots == Set([1, 2, 3]),
              !loadSnapshots.contains(where: { $0.allowedActions.contains(.continueAfterRemoval) }) else {
            return false
        }

        let loadTimeoutService = SelfTestCarouselChanger(
            fullSlots: [1],
            timeoutImports: [2]
        )
        var loadTimeoutFinished = false
        let loadTimeout = CarouselBatchOperation(
            mode: .load,
            targets: [2, 3],
            service: loadTimeoutService,
            gateTimeout: 0.02,
            onSnapshot: { _ in },
            onSlotState: { _, _ in },
            onFinished: { loadTimeoutFinished = true }
        )
        loadTimeout.start()
        guard waitUntil({ loadTimeoutFinished }) else { return false }
        let timedOutLoad = loadTimeout.snapshot()
        guard timedOutLoad.cancelled,
              timedOutLoad.completedSlots.isEmpty,
              loadTimeoutService.fullSlots == Set([1]),
              timedOutLoad.failures.first?.message.contains("10 seconds") == true else {
            return false
        }

        let unloadService = SelfTestCarouselChanger(fullSlots: [1, 2], autoRemove: true)
        var unloadFinished = false
        let unload = CarouselBatchOperation(
            mode: .unload,
            targets: [1, 2],
            service: unloadService,
            onSnapshot: { _ in },
            onSlotState: { _, _ in },
            onFinished: { unloadFinished = true }
        )
        unload.start()
        guard waitUntil({ unloadFinished }) else { return false }
        let unloaded = unload.snapshot()
        guard !unloaded.cancelled,
              unloaded.completedSlots == [1, 2],
              unloadService.fullSlots.isEmpty else { return false }

        let unloadTimeoutService = SelfTestCarouselChanger(
            fullSlots: [1, 2],
            timeoutUnloads: [1],
            autoRemove: false
        )
        var unloadTimeoutFinished = false
        let unloadTimeout = CarouselBatchOperation(
            mode: .unload,
            targets: [1, 2],
            service: unloadTimeoutService,
            gateTimeout: 0.02,
            onSnapshot: { _ in },
            onSlotState: { _, _ in },
            onFinished: { unloadTimeoutFinished = true }
        )
        unloadTimeout.start()
        guard waitUntil({ unloadTimeoutFinished }) else { return false }
        let timedOutUnload = unloadTimeout.snapshot()
        return timedOutUnload.cancelled
            && timedOutUnload.completedSlots.isEmpty
            && timedOutUnload.failures.first?.message.contains("returned to slot 1") == true
            && unloadTimeoutService.fullSlots == Set([1, 2])
    }

    private static func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private static func createLegacyDatabase(at url: URL) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle = handle else { return false }
        defer { sqlite3_close(handle) }

        let timestamp = "2025-01-02T03:04:05Z"
        let sql = """
            CREATE TABLE discs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                slot_id INTEGER NOT NULL UNIQUE,
                volume_label TEXT, disc_type TEXT, size_bytes INTEGER,
                musicbrainz_disc_id TEXT, artist TEXT, album TEXT, year TEXT,
                genre TEXT, track_count INTEGER, metadata_source TEXT,
                first_seen_at TEXT NOT NULL, last_seen_at TEXT NOT NULL,
                metadata_fetched_at TEXT
            );
            CREATE TABLE backups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                disc_id INTEGER NOT NULL, backup_path TEXT NOT NULL,
                backup_size_bytes INTEGER, backup_hash TEXT,
                backup_date TEXT NOT NULL, backup_status TEXT NOT NULL,
                error_message TEXT
            );
            INSERT INTO discs (
                id, slot_id, volume_label, disc_type, size_bytes,
                first_seen_at, last_seen_at
            ) VALUES (7, 42, 'Legacy Disc', 'dvd', 4700000000, '\(timestamp)', '\(timestamp)');
            INSERT INTO backups (
                id, disc_id, backup_path, backup_size_bytes,
                backup_date, backup_status
            ) VALUES (9, 7, '/old/archive/Legacy Disc.iso', 4700000000, '\(timestamp)', 'completed');
            """
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    private static func verifyRawCDAudioImaging(in output: URL) throws -> Bool {
        let layout = CDDiscLayout(
            tracks: [
                CDTrackLayout(number: 1, session: 1, control: 0, startLBA: 0, sectorMode: .audio),
                CDTrackLayout(number: 2, session: 1, control: 0x03, startLBA: 3, sectorMode: .audio),
            ],
            leadoutLBA: 20
        )
        let reader = SelfTestCDSectorReader(layout: layout)
        let base = output.appendingPathComponent("audio-format-test")
        var lastProgress: Double = 0
        let binURL = try RawCDImageService.createImage(
            reader: reader,
            outputPath: base,
            control: nil,
            progress: { lastProgress = $0.fractionCompleted }
        )
        let cueURL = base.appendingPathExtension("cue")
        let attributes = try FileManager.default.attributesOfItem(atPath: binURL.path)
        let binSize = (attributes[.size] as? NSNumber)?.int64Value
        let cue = try String(contentsOf: cueURL, encoding: .utf8)
        guard binURL.pathExtension == "bin",
              binSize == Int64(layout.sectorCount) * RawCDImageService.sectorSize,
              lastProgress == 1,
              cue.contains("TRACK 01 AUDIO"),
              cue.contains("TRACK 02 AUDIO"),
              cue.contains("FLAGS PRE DCP"),
              cue.contains("INDEX 01 00:00:03") else {
            return false
        }

        let completedRip = BackupRecord(
            discId: 1,
            backupPath: binURL.path,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            backupStatus: "completed"
        )
        guard completedRip.fileExists, completedRip.preferredOpenURL == cueURL else { return false }
        try FileManager.default.removeItem(at: cueURL)
        guard !completedRip.fileExists else { return false }

        let mixedCue = RawCDImageService.cueSheet(
            binFileName: "mixed.bin",
            layout: CDDiscLayout(
                tracks: [
                    CDTrackLayout(number: 1, session: 1, control: 0, startLBA: 0, sectorMode: .audio),
                    CDTrackLayout(number: 2, session: 1, control: 4, startLBA: 150, sectorMode: .mode1),
                    CDTrackLayout(number: 3, session: 1, control: 4, startLBA: 300, sectorMode: .mode2),
                ],
                leadoutLBA: 450
            )
        )
        guard mixedCue.contains("TRACK 02 MODE1/2352"),
              mixedCue.contains("TRACK 03 MODE2/2352"),
              mixedCue.contains("INDEX 01 00:02:00") else {
            return false
        }

        let control = ImagingService.ImagingControl()
        let cancelledBase = output.appendingPathComponent("audio-cancel-test")
        let cancellingReader = SelfTestCDSectorReader(
            layout: CDDiscLayout(tracks: layout.tracks, leadoutLBA: 40),
            onFirstRead: { control.cancel() }
        )
        do {
            _ = try RawCDImageService.createImage(
                reader: cancellingReader,
                outputPath: cancelledBase,
                control: control,
                progress: { _ in }
            )
            return false
        } catch ImagingError.cancelled {
            let leftovers = ["partial", "bin", "cue", "cue.partial"].contains {
                FileManager.default.fileExists(atPath: cancelledBase.appendingPathExtension($0).path)
            }
            return !leftovers
        }
    }
}

private final class SelfTestCDSectorReader: RawCDSectorReading {
    let layout: CDDiscLayout
    private var onFirstRead: (() -> Void)?

    init(layout: CDDiscLayout, onFirstRead: (() -> Void)? = nil) {
        self.layout = layout
        self.onFirstRead = onFirstRead
    }

    func resolveDataTrackModes() throws {}

    func read(startLBA: UInt32, sectorCount: UInt32) throws -> Data {
        let callback = onFirstRead
        onFirstRead = nil
        callback?()
        var bytes = [UInt8](
            repeating: 0,
            count: Int(sectorCount) * Int(DISCBOT_CD_SECTOR_SIZE)
        )
        for sector in 0..<sectorCount {
            bytes[Int(sector) * Int(DISCBOT_CD_SECTOR_SIZE)] = UInt8(truncatingIfNeeded: startLBA + sector)
        }
        return Data(bytes)
    }
}

private final class SelfTestSlowLoadChanger: ChangerServicing {
    private let base: ChangerServicing
    private let delay: TimeInterval

    init(base: ChangerServicing, delay: TimeInterval) {
        self.base = base
        self.delay = delay
    }

    var hasIESlot: Bool { base.hasIESlot }
    var slotCount: Int { base.slotCount }
    var isConnected: Bool { base.isConnected }

    func connect() throws { try base.connect() }
    func disconnect() { base.disconnect() }
    func getDeviceInfo() throws -> ChangerService.ChangerDeviceInfo { try base.getDeviceInfo() }
    func getSlotStatus() throws -> [Slot] { try base.getSlotStatus() }
    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?) { try base.getDriveStatus() }
    func getInventoryStatus() throws -> ChangerService.InventoryStatus { try base.getInventoryStatus() }
    func loadSlot(_ slotNumber: Int) throws {
        try base.loadSlot(slotNumber)
        Thread.sleep(forTimeInterval: delay)
    }
    func ejectToSlot(_ slotNumber: Int) throws { try base.ejectToSlot(slotNumber) }
    func unloadToIE(_ slotNumber: Int) throws { try base.unloadToIE(slotNumber) }
    func importFromIE(_ slotNumber: Int) throws { try base.importFromIE(slotNumber) }
    func waitForIESlotEmpty(timeout: TimeInterval) throws -> Bool {
        try base.waitForIESlotEmpty(timeout: timeout)
    }
    func loadFromIE() throws { try base.loadFromIE() }
    func initializeElementStatus() throws { try base.initializeElementStatus() }
}

private final class SelfTestStagedImagingService: ImagingServicing {
    private let lock = NSLock()
    private let secondRead = DispatchSemaphore(value: 0)
    private let waitForSecondRead: Bool
    private var readCount = 0
    private(set) var maximumOutstandingReads = 0
    private var finalizationCount = 0
    private var secondReadStartedAt: Date?
    private var firstFinalizationFinishedAt: Date?

    init(waitForSecondRead: Bool = false) {
        self.waitForSecondRead = waitForSecondRead
    }

    var didOverlapReadAndFinalization: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let read = secondReadStartedAt,
              let finalized = firstFinalizationFinishedAt else { return false }
        return read < finalized
    }

    func estimateDiscSizeBytes(bsdName: String) -> Int64? { 4096 }
    func detectDiscType(bsdName: String) -> DiscType { .dvd }

    func createImage(
        bsdName: String,
        discType: DiscType,
        outputPath: URL,
        totalBytes: Int64?,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        let finalURL = outputPath.deletingPathExtension().appendingPathExtension("iso")
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x44, count: 4096).write(to: finalURL)
        progress(ImagingProgressInfo(
            fractionCompleted: 1,
            bytesTransferred: 4096,
            totalBytes: 4096,
            speedBytesPerSecond: nil,
            etaSeconds: 0
        ))
        return finalURL
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
        if control?.isCancelled == true { throw ImagingError.cancelled }
        lock.lock()
        readCount += 1
        maximumOutstandingReads = max(maximumOutstandingReads, readCount - finalizationCount)
        if readCount == 2 {
            secondReadStartedAt = Date()
            secondRead.signal()
        }
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.03)
        progress(ImagingProgressInfo(
            fractionCompleted: 1,
            bytesTransferred: 4096,
            totalBytes: 4096,
            speedBytesPerSecond: 4096 / 0.03,
            etaSeconds: 0
        ))

        let finalURL = outputPath.deletingPathExtension().appendingPathExtension("iso")
        return .staged(StagedImageArtifact(
            expectedFinalURL: finalURL,
            finalize: { [weak self] finalizationControl in
                guard let self = self else { throw ImagingError.cancelled }
                self.lock.lock()
                let first = self.finalizationCount == 0
                self.lock.unlock()
                if self.waitForSecondRead && first {
                    guard self.secondRead.wait(timeout: .now() + 5) == .success else {
                        throw ImagingError.timeout
                    }
                }
                Thread.sleep(forTimeInterval: 0.3)
                if finalizationControl?.isCancelled == true { throw ImagingError.cancelled }
                try FileManager.default.createDirectory(
                    at: finalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(repeating: 0x49, count: 4096).write(to: finalURL)
                self.lock.lock()
                self.finalizationCount += 1
                if self.finalizationCount == 1 {
                    self.firstFinalizationFinishedAt = Date()
                }
                self.lock.unlock()
                return finalURL
            },
            discard: {}
        ))
    }
}

private final class SelfTestRemoteControlProvider: RemoteControlProviding {
    let storedArtwork = Data("self-test-artwork".utf8)
    var startedSlots: [Int]?
    var startedDestination: RemoteRipDestination?
    var startedPolicy: DuplicatePolicy?
    var startedOutputMode: RipOutputMode?
    var scanStarted = false
    var cancelled = false
    var currentDiscCancelled = false
    var updatedMetadata: (Int64, DiscMetadata)?
    var refreshed = false
    var rescanned = false
    var returnedLoadedDisc = false
    var slotAction: (Int, RemoteSlotAction)?
    var carouselLoadCount: Int?
    var carouselLoadSlots: [Int]?
    var carouselUnloadSlots: [Int]?
    var carouselAction: CarouselBatchAction?
    private var active = false

    func remoteState() -> [String: Any] {
        ["connected": true, "busy": active, "slots": []]
    }

    func remoteLibrary() -> [String: Any] {
        ["statistics": [:], "entries": [], "activity": []]
    }

    func artworkData(discId: Int64) -> Data? {
        discId == 7 ? storedArtwork : nil
    }

    func metadataConfiguration() -> [String: Any] {
        [
            "audioProvider": MetadataProvider.musicBrainz.rawValue,
            "videoProvider": MetadataProvider.tmdb.rawValue,
            "tmdbConfigured": false
        ]
    }

    func configureMetadata(audioProvider: String?, videoProvider: String?, tmdbToken: String?) {}

    var searchHook: (() -> Void)?
    func searchMetadata(provider: MetadataProvider, query: String) -> [MetadataCandidate] {
        searchHook?()
        return []
    }

    func updateMetadata(discId: Int64, metadata: DiscMetadata) -> Result<Void, RemoteAPIError> {
        updatedMetadata = (discId, metadata)
        return .success(())
    }

    func startRemoteRip(
        slots: [Int],
        destination: RemoteRipDestination,
        policy: DuplicatePolicy,
        outputMode: RipOutputMode
    ) -> Result<String, RemoteAPIError> {
        guard !active else {
            return .failure(RemoteAPIError(status: 409, message: "Already active"))
        }
        active = true
        startedSlots = slots
        startedDestination = destination
        startedPolicy = policy
        startedOutputMode = outputMode
        return .success("self-test-job")
    }

    func startRemoteScanUnknown() -> Result<String, RemoteAPIError> {
        guard !active else {
            return .failure(RemoteAPIError(status: 409, message: "Already active"))
        }
        active = true
        scanStarted = true
        return .success("self-test-scan")
    }

    func cancelRemoteJob(id: String?) -> Result<Void, RemoteAPIError> {
        guard active, id == nil || id == "self-test-job" || id == "self-test-scan" else {
            return .failure(RemoteAPIError(status: 404, message: "Not active"))
        }
        active = false
        cancelled = true
        return .success(())
    }

    func cancelRemoteCurrentDisc(id: String?) -> Result<Void, RemoteAPIError> {
        guard active, id == nil || id == "self-test-job" else {
            return .failure(RemoteAPIError(status: 404, message: "Not active"))
        }
        currentDiscCancelled = true
        return .success(())
    }

    func refreshRemoteInventory() -> Result<Void, RemoteAPIError> {
        guard !active else { return .failure(RemoteAPIError(status: 409, message: "Busy")) }
        refreshed = true
        return .success(())
    }

    func rescanRemoteInventory() -> Result<Void, RemoteAPIError> {
        guard !active else { return .failure(RemoteAPIError(status: 409, message: "Busy")) }
        rescanned = true
        return .success(())
    }

    func returnLoadedDisc() -> Result<Void, RemoteAPIError> {
        guard !active else { return .failure(RemoteAPIError(status: 409, message: "Busy")) }
        returnedLoadedDisc = true
        return .success(())
    }

    func performRemoteSlotAction(
        slot: Int,
        action: RemoteSlotAction
    ) -> Result<Void, RemoteAPIError> {
        guard !active else { return .failure(RemoteAPIError(status: 409, message: "Busy")) }
        slotAction = (slot, action)
        return .success(())
    }

    func startRemoteCarouselLoad(count: Int?, slots: [Int]?) -> Result<String, RemoteAPIError> {
        carouselLoadCount = count
        carouselLoadSlots = slots
        return .success("self-test-carousel")
    }

    func startRemoteCarouselUnload(slots: [Int]?) -> Result<String, RemoteAPIError> {
        carouselUnloadSlots = slots
        return .success("self-test-carousel")
    }

    func controlRemoteCarousel(
        id: String?,
        action: CarouselBatchAction
    ) -> Result<Void, RemoteAPIError> {
        guard id == nil || id == "self-test-carousel" else {
            return .failure(RemoteAPIError(status: 404, message: "Not active"))
        }
        carouselAction = action
        return .success(())
    }
}

private final class SelfTestCarouselChanger: ChangerServicing {
    private let lock = NSLock()
    private var occupied: Set<Int>
    private var timeoutImports: Set<Int>
    private var timeoutUnloads: Set<Int>
    private var ieFull = false
    private let autoRemove: Bool
    private let count = 8

    init(
        fullSlots: Set<Int>,
        timeoutImports: Set<Int> = [],
        timeoutUnloads: Set<Int> = [],
        autoRemove: Bool = true
    ) {
        occupied = fullSlots
        self.timeoutImports = timeoutImports
        self.timeoutUnloads = timeoutUnloads
        self.autoRemove = autoRemove
    }

    var fullSlots: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return occupied
    }

    func connect() throws {}
    func disconnect() {}
    func getDeviceInfo() throws -> ChangerService.ChangerDeviceInfo {
        ChangerService.ChangerDeviceInfo(vendor: "Self Test", product: "Carousel", revision: "1")
    }
    func getSlotStatus() throws -> [Slot] { try getInventoryStatus().slots }
    func getDriveStatus() throws -> (hasDisc: Bool, sourceSlot: Int?) { (false, nil) }
    func getInventoryStatus() throws -> ChangerService.InventoryStatus {
        lock.lock()
        let values = occupied
        lock.unlock()
        let slots = (1...count).map {
            Slot(id: $0, address: UInt16($0), isFull: values.contains($0))
        }
        return ChangerService.InventoryStatus(
            slots: slots,
            drive: .init(isSupported: true, hasDisc: false, sourceSlot: nil)
        )
    }
    func loadSlot(_ slotNumber: Int) throws {}
    func ejectToSlot(_ slotNumber: Int) throws {}
    func unloadToIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if timeoutUnloads.contains(slotNumber) { throw ChangerError.timeout }
        guard occupied.remove(slotNumber) != nil else { throw ChangerError.slotEmpty(slotNumber) }
        ieFull = true
    }
    func importFromIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if timeoutImports.contains(slotNumber) { throw ChangerError.timeout }
        guard !occupied.contains(slotNumber) else { throw ChangerError.slotOccupied(slotNumber) }
        occupied.insert(slotNumber)
        ieFull = false
    }
    func waitForIESlotEmpty(timeout: TimeInterval) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ieFull else { return true }
        if autoRemove {
            ieFull = false
            return true
        }
        return false
    }
    func loadFromIE() throws {}
    func initializeElementStatus() throws {}
    var hasIESlot: Bool { true }
    var slotCount: Int { count }
    var isConnected: Bool { true }
}

private final class SelfTestFixedIdentity: DiscIdentifying {
    let identity: DiscIdentity
    init(identity: DiscIdentity) { self.identity = identity }
    func identify(bsdName: String, discType: DiscType, volumeLabel: String?, sizeBytes: Int64?) -> DiscIdentity {
        identity
    }
}

private final class SelfTestEventDelegate: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var bytes = Data()
    var receivedSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bytes.range(of: Data("event: snapshot".utf8)) != nil
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bytes.append(data)
        lock.unlock()
    }
}
