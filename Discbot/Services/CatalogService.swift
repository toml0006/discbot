//
//  CatalogService.swift
//  Discbot
//
//  Permanent disc catalog, sightings, duplicate detection, and rip history
//

import Foundation

enum DuplicatePolicy: String, Equatable {
    case skipExisting
    case imageAgain
    case replaceExisting

    var displayName: String {
        switch self {
        case .skipExisting: return "Skip existing"
        case .imageAgain: return "Keep both"
        case .replaceExisting: return "Replace existing"
        }
    }
}

struct CatalogStatistics: Equatable {
    let totalDiscs: Int
    let totalSightings: Int
    let ripAttempts: Int
    let completedRips: Int
    let failedRips: Int
    let cancelledRips: Int
    let skippedRips: Int
    let replacedRips: Int
    let availableImages: Int
    let storedBytes: Int64

    static let empty = CatalogStatistics(
        totalDiscs: 0, totalSightings: 0, ripAttempts: 0, completedRips: 0,
        failedRips: 0, cancelledRips: 0, skippedRips: 0, replacedRips: 0,
        availableImages: 0, storedBytes: 0
    )
}

final class CatalogService {
    private static let persistentSessionKey = "discbot.catalogSessionId"
    private let database: Database
    private let metadataService: MetadataService
    private let identityService: DiscIdentifying

    /// Sightings are scoped to one app run so a different magazine cannot inherit
    /// stale slot metadata from a previous set of discs.
    let sessionId: String

    init(
        database: Database = .shared,
        metadataService: MetadataService = MetadataService(),
        identityService: DiscIdentifying = DiscIdentityService(),
        sessionId: String? = nil
    ) {
        self.database = database
        self.metadataService = metadataService
        self.identityService = identityService
        if let sessionId = sessionId {
            self.sessionId = sessionId
        } else if let persisted = UserDefaults.standard.string(forKey: Self.persistentSessionKey),
                  !persisted.isEmpty {
            self.sessionId = persisted
        } else {
            // Preserve current slot-to-disc knowledge across app/server
            // restarts. The most recent sighting bootstraps upgrades from the
            // previous per-process session behavior.
            let resolved = database.getMostRecentSessionId() ?? UUID().uuidString
            self.sessionId = resolved
            UserDefaults.standard.set(resolved, forKey: Self.persistentSessionKey)
        }
    }

    // MARK: - Disc sightings

    @discardableResult
    func recordDisc(
        slotId: Int,
        bsdName: String,
        discType: DiscType,
        sizeBytes: Int64?,
        volumeLabel: String? = nil
    ) -> DiscRecord? {
        let metadata: DiscMetadata
        if let volumeLabel = volumeLabel, !volumeLabel.isEmpty {
            metadata = DiscMetadata(
                artist: "Unknown",
                album: volumeLabel,
                year: nil,
                tracks: nil,
                source: .volumeLabel
            )
        } else {
            metadata = metadataService.resolveMetadata(bsdName: bsdName, slotNumber: slotId)
        }
        let resolvedVolumeLabel = metadata.source == .slotNumber ? nil : metadata.album
        let identity = identityService.identify(
            bsdName: bsdName,
            discType: discType,
            volumeLabel: resolvedVolumeLabel,
            sizeBytes: sizeBytes
        )
        let record = DiscRecord.make(
            identity: identity,
            slotId: slotId,
            metadata: metadata,
            discType: discType,
            sizeBytes: sizeBytes
        )
        guard let stored = database.upsertDisc(record, sessionId: sessionId) else { return nil }
        guard !stored.metadataUserEdited else { return stored }
        if stored.metadataFetchedAt != nil,
           (stored.metadataSource == MetadataProvider.musicBrainz.rawValue
            || stored.metadataSource == MetadataProvider.tmdb.rawValue) {
            return stored
        }
        guard let online = metadataService.automaticMetadata(
            bsdName: bsdName,
            discType: discType,
            volumeLabel: volumeLabel ?? resolvedVolumeLabel
        ), let id = stored.id else { return stored }
        guard let updated = database.updateDiscMetadata(id: id, metadata: online, userEdited: false) else {
            return stored
        }
        return persistArtwork(for: updated)
    }

    func getDisc(slotId: Int) -> DiscRecord? {
        database.getDisc(slotId: slotId, sessionId: sessionId)
    }

    func getAllDiscs() -> [DiscRecord] {
        database.getDiscs(sessionId: sessionId)
    }

    func getCatalogEntries() -> [CatalogEntry] {
        database.getAllDiscs().map { disc in
            guard let id = disc.id else { return CatalogEntry(disc: disc, sightings: [], rips: []) }
            return CatalogEntry(
                disc: disc,
                sightings: database.getSightings(discId: id),
                rips: database.getRips(discId: id)
            )
        }
    }

    var revision: Int { database.revision }

    func getStatistics(entries: [CatalogEntry]? = nil) -> CatalogStatistics {
        let entries = entries ?? getCatalogEntries()
        let rips = entries.flatMap(\.rips)
        let available = rips.filter(\.fileExists)
        return CatalogStatistics(
            totalDiscs: entries.count,
            totalSightings: entries.reduce(0) { $0 + $1.sightings.count },
            ripAttempts: rips.count,
            completedRips: rips.filter(\.isCompleted).count,
            failedRips: rips.filter(\.isFailed).count,
            cancelledRips: rips.filter(\.isCancelled).count,
            skippedRips: rips.filter { $0.backupStatus == "skipped" }.count,
            replacedRips: rips.filter(\.isReplaced).count,
            availableImages: available.count,
            storedBytes: available.compactMap(\.backupSizeBytes).reduce(0, +)
        )
    }

    func getRecentRipLog(limit: Int = 250) -> [RipLogRecord] {
        database.getRecentRipEvents(limit: limit)
    }

    func recordActivity(type: String, slotId: Int? = nil, message: String) {
        database.recordOperationEvent(slotId: slotId, type: type, message: message)
    }

    // MARK: - Metadata

    func metadataConfiguration() -> [String: Any] { metadataService.providerConfiguration }

    func configureMetadata(audioProvider: String?, videoProvider: String?, tmdbToken: String?) {
        metadataService.configure(
            audioProvider: audioProvider,
            videoProvider: videoProvider,
            tmdbToken: tmdbToken
        )
    }

    func searchMetadata(provider: MetadataProvider, query: String) -> [MetadataCandidate] {
        metadataService.search(provider: provider, query: query)
    }

    @discardableResult
    func updateMetadata(discId: Int64, metadata: DiscMetadata, userEdited: Bool = true) -> DiscRecord? {
        let previousArtworkURL = database.getDisc(id: discId)?.artworkURL
        guard var updated = database.updateDiscMetadata(
            id: discId,
            metadata: metadata,
            userEdited: userEdited
        ) else { return nil }
        if previousArtworkURL != updated.artworkURL {
            updated = database.updateDiscArtworkPath(id: discId, path: nil) ?? updated
        }
        updated = persistArtwork(for: updated)
        for rip in database.getRips(discId: discId) where rip.fileExists {
            try? metadataService.writeSidecar(for: updated, ripURL: URL(fileURLWithPath: rip.backupPath))
        }
        return updated
    }

    /// Returns the durable selected artwork, lazily importing an older rip
    /// sidecar or provider image for catalogs created before artwork caching.
    func artworkData(discId: Int64) -> Data? {
        guard var disc = database.getDisc(id: discId) else { return nil }
        if let data = metadataService.artworkData(path: disc.artworkPath) { return data }

        for rip in database.getRips(discId: discId) where rip.fileExists {
            let cover = URL(fileURLWithPath: rip.backupPath)
                .deletingPathExtension()
                .appendingPathExtension("cover.jpg")
            guard let data = try? Data(contentsOf: cover),
                  let path = metadataService.cacheArtwork(discID: discId, data: data) else { continue }
            _ = database.updateDiscArtworkPath(id: discId, path: path)
            return metadataService.artworkData(path: path)
        }

        disc = persistArtwork(for: disc)
        return metadataService.artworkData(path: disc.artworkPath)
    }

    private func persistArtwork(for disc: DiscRecord) -> DiscRecord {
        guard let id = disc.id else { return disc }
        if metadataService.artworkData(path: disc.artworkPath) != nil { return disc }
        guard let path = metadataService.cacheArtwork(discID: id, rawURL: disc.artworkURL) else {
            return disc
        }
        return database.updateDiscArtworkPath(id: id, path: path) ?? disc
    }

    // MARK: - Duplicate decisions

    /// Only reliable identities with a completed image that still exists are
    /// eligible for automatic skipping.
    func existingRipForAutomaticSkip(disc: DiscRecord) -> BackupRecord? {
        try? existingRipForAutomaticSkip(disc: disc, control: nil)
    }

    func existingRipForAutomaticSkip(
        disc: DiscRecord,
        control: ImagingService.ImagingControl?
    ) throws -> BackupRecord? {
        guard disc.hasReliableIdentity, let discId = disc.id else { return nil }
        for rip in database.getRips(discId: discId) {
            try control?.checkCancellation()
            guard rip.fileExists, let expected = rip.backupHash, !expected.isEmpty else { continue }
            do {
                if try integrityHash(for: URL(fileURLWithPath: rip.backupPath), control: control) == expected {
                    return rip
                }
            } catch ImagingError.cancelled {
                throw ImagingError.cancelled
            } catch { continue }
        }
        return nil
    }

    func latestVerifiedRip(disc: DiscRecord) -> BackupRecord? {
        guard let discId = disc.id else { return nil }
        return database.getRips(discId: discId).first(where: isVerifiedRip)
    }

    func latestRipForReplacement(disc: DiscRecord) -> BackupRecord? {
        guard disc.hasReliableIdentity, let discId = disc.id else { return nil }
        return database.getRips(discId: discId).first(where: { rip in
            guard rip.isCompleted, FileManager.default.fileExists(atPath: rip.backupPath) else { return false }
            if URL(fileURLWithPath: rip.backupPath).pathExtension.lowercased() == "bin" {
                return FileManager.default.fileExists(atPath: rip.associatedCueURL.path)
            }
            return true
        })
    }

    // MARK: - Rip lifecycle

    func startRip(disc: DiscRecord, slotId: Int, proposedPath: URL) -> Int64? {
        guard let discId = disc.id else { return nil }
        return database.startRip(discId: discId, slotId: slotId, path: proposedPath.path)
    }

    func recordRipCompleted(
        ripId: Int64, finalURL: URL, disc: DiscRecord? = nil,
        control: ImagingService.ImagingControl? = nil
    ) throws {
        try control?.checkCancellation()
        let size = try RipArtifactInspector.sizeBytes(at: finalURL)
        guard size > 0 else {
            throw ImagingError.writeFailed(finalURL)
        }
        let hash = try integrityHash(for: finalURL, control: control)
        try control?.checkCancellation()
        if let disc = disc {
            do {
                try metadataService.writeSidecar(for: disc, ripURL: finalURL)
            } catch {
                // The image is already complete and verified. Keep it usable
                // even if a full destination prevents the small sidecar write.
                print("Metadata sidecar could not be written for \(finalURL.path): \(error.localizedDescription)")
            }
        }
        try control?.checkCancellation()
        database.finishRip(
            id: ripId,
            status: "completed",
            finalPath: finalURL.path,
            sizeBytes: size,
            hash: hash
        )
    }

    /// Marks the previous image as superseded only after the replacement is complete.
    /// If removing the old file fails, both copies remain and the old row stays completed.
    func supersede(_ previous: BackupRecord, with replacementURL: URL) throws {
        let previousURL = URL(fileURLWithPath: previous.backupPath)
        guard previousURL.standardizedFileURL != replacementURL.standardizedFileURL else { return }
        let fileManager = FileManager.default
        var previousFiles = [previousURL]
        if previousURL.pathExtension.lowercased() == "bin" {
            let cue = previous.associatedCueURL
            previousFiles.append(cue)
        }
        previousFiles.append(previousURL.deletingPathExtension().appendingPathExtension("metadata.json"))
        previousFiles.append(previousURL.deletingPathExtension().appendingPathExtension("cover.jpg"))
        previousFiles = previousFiles.filter { fileManager.fileExists(atPath: $0.path) }

        let token = UUID().uuidString
        let stagedFiles = previousFiles.map {
            $0.deletingLastPathComponent()
                .appendingPathComponent(".\($0.lastPathComponent).superseded-\(token)")
        }
        var movedCount = 0
        do {
            for (source, staged) in zip(previousFiles, stagedFiles) {
                try fileManager.moveItem(at: source, to: staged)
                movedCount += 1
            }
        } catch {
            for index in (0..<movedCount).reversed() {
                try? fileManager.moveItem(at: stagedFiles[index], to: previousFiles[index])
            }
            throw error
        }

        if let id = previous.id {
            database.markRipReplaced(id: id, replacementPath: replacementURL.path)
        }
        // The catalog switch is complete. Cleanup failure is non-fatal because the
        // staged files are hidden and no longer qualify as a library image.
        for staged in stagedFiles { try? fileManager.removeItem(at: staged) }
    }

    func recordRipFailed(ripId: Int64, error: String, cancelled: Bool = false) {
        database.finishRip(
            id: ripId,
            status: cancelled ? "cancelled" : "failed",
            error: error
        )
    }

    /// Only used for a newly produced artifact whose catalog commit was cancelled.
    func discardUncommittedImage(at url: URL) {
        var urls = [url]
        if url.pathExtension.lowercased() == "bin" {
            urls.append(url.deletingPathExtension().appendingPathExtension("cue"))
        }
        urls.append(url.deletingPathExtension().appendingPathExtension("metadata.json"))
        urls.append(url.deletingPathExtension().appendingPathExtension("cover.jpg"))
        for file in urls { try? FileManager.default.removeItem(at: file) }
    }

    func recordRipSkipped(disc: DiscRecord, slotId: Int, existing: BackupRecord) {
        guard let ripId = startRip(
            disc: disc,
            slotId: slotId,
            proposedPath: URL(fileURLWithPath: existing.backupPath)
        ) else { return }
        database.finishRip(
            id: ripId,
            status: "skipped",
            finalPath: existing.backupPath,
            error: "Skipped because a verified rip already exists"
        )
    }

    // Kept for source compatibility with older operation paths while the catalog
    // migration is in place. New batch code uses the explicit rip lifecycle above.
    func recordBackupCompleted(slotId: Int, backupPath: String, backupSizeBytes: Int64?) {
        guard let disc = getDisc(slotId: slotId),
              let ripId = startRip(disc: disc, slotId: slotId, proposedPath: URL(fileURLWithPath: backupPath)) else { return }
        do {
            try recordRipCompleted(ripId: ripId, finalURL: URL(fileURLWithPath: backupPath))
        } catch {
            recordRipFailed(ripId: ripId, error: error.localizedDescription)
        }
    }

    func recordBackupFailed(slotId: Int, backupPath: String, error: String) {
        guard let disc = getDisc(slotId: slotId),
              let ripId = startRip(disc: disc, slotId: slotId, proposedPath: URL(fileURLWithPath: backupPath)) else { return }
        recordRipFailed(ripId: ripId, error: error)
    }

    func getBackups(slotId: Int) -> [BackupRecord] {
        guard let discId = getDisc(slotId: slotId)?.id else { return [] }
        return database.getRips(discId: discId)
    }

    func getBackupStatus(slotId: Int) -> BackupStatus {
        guard let discId = getDisc(slotId: slotId)?.id else { return .notBackedUp }
        let rips = database.getRips(discId: discId)
        if let completed = rips.first(where: { $0.fileExists }), let date = completed.backupDateParsed {
            return .backedUp(date)
        }
        if rips.contains(where: { $0.isFailed }) { return .failed }
        return .notBackedUp
    }

    private func isVerifiedRip(_ rip: BackupRecord) -> Bool {
        guard rip.fileExists else { return false }
        guard let expectedHash = rip.backupHash, !expectedHash.isEmpty else {
            // Legacy rips retain size validation but are not trusted for silent skipping.
            return false
        }
        guard let actualHash = try? integrityHash(for: URL(fileURLWithPath: rip.backupPath)) else {
            return false
        }
        return actualHash == expectedHash
    }

    private func integrityHash(
        for primaryURL: URL, control: ImagingService.ImagingControl? = nil
    ) throws -> String {
        try RipArtifactInspector.integrityHash(at: primaryURL) { try control?.checkCancellation() }
    }

    func getAllBackupStatuses() -> [Int: BackupStatus] {
        var result: [Int: BackupStatus] = [:]
        for disc in database.getDiscs(sessionId: sessionId) {
            result[disc.slotId] = getBackupStatus(slotId: disc.slotId)
        }
        return result
    }

    // MARK: - Output naming

    func uniqueOutputBase(
        directory: URL,
        disc: DiscRecord,
        slotId: Int
    ) -> URL {
        let label = sanitizedFilename(disc.displayName)
        let fingerprint = String(disc.fingerprint.prefix(10))
        let stem = "\(String(format: "%03d", slotId))_\(label)_\(fingerprint)"
        var candidate = directory.appendingPathComponent(stem)
        var suffix = 2
        while outputExists(base: candidate) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private func outputExists(base: URL) -> Bool {
        let extensions = ["iso", "cdr", "bin", "cue", "zip", "dvdmedia", "partial"]
        return extensions.contains {
            FileManager.default.fileExists(atPath: base.appendingPathExtension($0).path)
        } || FileManager.default.fileExists(atPath: base.appendingPathExtension("metadata.json").path)
            || FileManager.default.fileExists(atPath: base.appendingPathExtension("cover.jpg").path)
    }

    private func sanitizedFilename(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = value.components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled_Disc" : String(cleaned.prefix(100))
    }
}
