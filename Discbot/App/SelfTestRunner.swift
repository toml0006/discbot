//
//  SelfTestRunner.swift
//  Discbot
//
//  Hardware-free integration check used locally and by CI
//

import Foundation

enum SelfTestRunner {
    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("discbot-self-test-\(UUID().uuidString)", isDirectory: true)
        let output = root.appendingPathComponent("images", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            guard verifyOpticalMediaDetection() else {
                print("SELF TEST FAILED: diskutil media classification used drive capabilities")
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

            let entries = catalog.getCatalogEntries()
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
                print("SELF TEST FAILED: corrupt prior image was incorrectly skipped")
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
                  !catalog.getRecentRipLog().isEmpty else {
                print("SELF TEST FAILED: rip logs or collection statistics are incomplete")
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

            print("SELF TEST PASSED: batch rip, verified duplicate handling, safe replacement, logs/stats, metadata catalog/sidecars, raw CD BIN/CUE, cancellation cleanup, safe return, catalog migration/history, and authenticated remote push API")
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

    private static func verifyRemoteServerAPI(in output: URL) -> Bool {
        let destination = RemoteRipDestination(name: "Self Test", path: output.path)
        var configuredDestinations = [destination]
        let provider = SelfTestRemoteControlProvider()
        let controller = RemoteAPIController(
            control: provider,
            token: { "test-token" },
            destinations: { configuredDestinations },
            updateDestinations: { configuredDestinations = $0 },
            destinationRoots: { [output.deletingLastPathComponent()] }
        )

        let health = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/api/v1/health", headers: [:], body: Data()
        ))
        guard health.status == 200 else { return false }

        let unauthorized = controller.response(to: RemoteHTTPRequest(
            method: "GET", path: "/api/v1/state", headers: [:], body: Data()
        ))
        guard unauthorized.status == 401 else { return false }

        let authorizedHeaders = ["authorization": "Bearer test-token"]
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

        let body: [String: Any] = [
            "slots": [1, 2],
            "destinationId": destination.id.uuidString,
            "duplicatePolicy": DuplicatePolicy.replaceExisting.rawValue,
            "path": "/tmp/client-controlled-path-must-be-ignored"
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        let start = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/rip", headers: authorizedHeaders, body: bodyData
        ))
        guard start.status == 202,
              provider.startedDestination == destination,
              provider.startedSlots == [1, 2],
              provider.startedPolicy == .replaceExisting else { return false }

        let conflicting = controller.response(to: RemoteHTTPRequest(
            method: "POST", path: "/api/v1/jobs/rip", headers: authorizedHeaders, body: bodyData
        ))
        guard conflicting.status == 409 else { return false }

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
        changer: ChangerServicing,
        mount: MountServicing,
        imaging: ImagingServicing,
        catalog: CatalogService,
        cancelAfter: TimeInterval? = nil
    ) -> Bool {
        var finished = false
        state.runImageAll(
            slots: slots,
            outputDirectory: output,
            duplicatePolicy: policy,
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

        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return finished
    }

    private static func verifyCarouselBatchOperation() -> Bool {
        let loadService = SelfTestCarouselChanger(fullSlots: [1], timeoutImportOnce: [2])
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
        guard waitUntil({
            load.snapshot().awaitingAction && load.snapshot().currentSlot == 2
        }), load.perform(.retry), waitUntil({ loadFinished }) else { return false }
        let loaded = load.snapshot()
        guard !loaded.running, !loaded.cancelled,
              loaded.completedSlots == [2, 3],
              loadService.fullSlots == Set([1, 2, 3]),
              loadSnapshots.contains(where: { $0.allowedActions.contains(.retry) }) else {
            return false
        }

        let unloadService = SelfTestCarouselChanger(fullSlots: [1, 2])
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
        guard waitUntil({
            unload.snapshot().awaitingAction && unload.snapshot().currentSlot == 1
        }), unload.perform(.continueAfterRemoval), waitUntil({
            unload.snapshot().awaitingAction && unload.snapshot().currentSlot == 2
        }), unload.perform(.cancel), waitUntil({ unloadFinished }) else { return false }
        let unloaded = unload.snapshot()
        return unloaded.cancelled
            && unloaded.completedSlots == [1, 2]
            && unloadService.fullSlots.isEmpty
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

private final class SelfTestRemoteControlProvider: RemoteControlProviding {
    var startedSlots: [Int]?
    var startedDestination: RemoteRipDestination?
    var startedPolicy: DuplicatePolicy?
    var cancelled = false
    var updatedMetadata: (Int64, DiscMetadata)?
    var refreshed = false
    var rescanned = false
    var returnedLoadedDisc = false
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

    func metadataConfiguration() -> [String: Any] {
        [
            "audioProvider": MetadataProvider.musicBrainz.rawValue,
            "videoProvider": MetadataProvider.tmdb.rawValue,
            "tmdbConfigured": false
        ]
    }

    func configureMetadata(audioProvider: String?, videoProvider: String?, tmdbToken: String?) {}

    func searchMetadata(provider: MetadataProvider, query: String) -> [MetadataCandidate] { [] }

    func updateMetadata(discId: Int64, metadata: DiscMetadata) -> Result<Void, RemoteAPIError> {
        updatedMetadata = (discId, metadata)
        return .success(())
    }

    func startRemoteRip(
        slots: [Int],
        destination: RemoteRipDestination,
        policy: DuplicatePolicy
    ) -> Result<String, RemoteAPIError> {
        guard !active else {
            return .failure(RemoteAPIError(status: 409, message: "Already active"))
        }
        active = true
        startedSlots = slots
        startedDestination = destination
        startedPolicy = policy
        return .success("self-test-job")
    }

    func cancelRemoteJob(id: String?) -> Result<Void, RemoteAPIError> {
        guard active, id == nil || id == "self-test-job" else {
            return .failure(RemoteAPIError(status: 404, message: "Not active"))
        }
        active = false
        cancelled = true
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
    private var timeoutImportOnce: Set<Int>
    private let count = 8

    init(fullSlots: Set<Int>, timeoutImportOnce: Set<Int> = []) {
        occupied = fullSlots
        self.timeoutImportOnce = timeoutImportOnce
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
        guard occupied.remove(slotNumber) != nil else { throw ChangerError.slotEmpty(slotNumber) }
    }
    func importFromIE(_ slotNumber: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        if timeoutImportOnce.remove(slotNumber) != nil { throw ChangerError.timeout }
        guard !occupied.contains(slotNumber) else { throw ChangerError.slotOccupied(slotNumber) }
        occupied.insert(slotNumber)
    }
    func loadFromIE() throws {}
    func initializeElementStatus() throws {}
    var hasIESlot: Bool { true }
    var slotCount: Int { count }
    var isConnected: Bool { true }
}
