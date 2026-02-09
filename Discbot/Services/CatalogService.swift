//
//  CatalogService.swift
//  Discbot
//
//  Service for managing the disc catalog and backup tracking
//

import Foundation

final class CatalogService {
    private let database = Database.shared
    private let metadataService = MetadataService()
    private let imagingService = ImagingService()

    // MARK: - Disc Operations

    /// Record a disc when it's loaded/seen
    func recordDisc(
        slotId: Int,
        bsdName: String,
        discType: DiscType,
        sizeBytes: Int64?
    ) -> Int64? {
        // Get metadata from MetadataService
        let metadata = metadataService.resolveMetadata(bsdName: bsdName, slotNumber: slotId)

        let record = DiscRecord.from(
            slotId: slotId,
            metadata: metadata,
            discType: discType,
            sizeBytes: sizeBytes
        )

        return database.insertOrUpdateDisc(record)
    }

    /// Get disc record for a slot
    func getDisc(slotId: Int) -> DiscRecord? {
        return database.getDisc(slotId: slotId)
    }

    /// Get all disc records
    func getAllDiscs() -> [DiscRecord] {
        return database.getAllDiscs()
    }

    // MARK: - Backup Operations

    /// Record a successful backup
    func recordBackupCompleted(
        slotId: Int,
        backupPath: String,
        backupSizeBytes: Int64?
    ) {
        guard let disc = database.getDisc(slotId: slotId), let discId = disc.id else {
            print("CatalogService: No disc record found for slot \(slotId)")
            return
        }

        let backup = BackupRecord(
            discId: discId,
            backupPath: backupPath,
            backupSizeBytes: backupSizeBytes,
            backupStatus: "completed"
        )

        _ = database.insertBackup(backup)
    }

    /// Record a failed backup
    func recordBackupFailed(
        slotId: Int,
        backupPath: String,
        error: String
    ) {
        guard let disc = database.getDisc(slotId: slotId), let discId = disc.id else {
            print("CatalogService: No disc record found for slot \(slotId)")
            return
        }

        let backup = BackupRecord(
            discId: discId,
            backupPath: backupPath,
            backupStatus: "failed",
            errorMessage: error
        )

        _ = database.insertBackup(backup)
    }

    /// Get backup status for a slot
    func getBackupStatus(slotId: Int) -> BackupStatus {
        guard let backup = database.getLatestBackup(slotId: slotId) else {
            return .notBackedUp
        }

        if backup.isCompleted, let date = backup.backupDateParsed {
            return .backedUp(date)
        } else if backup.isFailed {
            return .failed
        }

        return .notBackedUp
    }

    /// Get all backups for a slot
    func getBackups(slotId: Int) -> [BackupRecord] {
        guard let disc = database.getDisc(slotId: slotId), let discId = disc.id else {
            return []
        }
        return database.getBackups(discId: discId)
    }

    /// Get backup statuses for all slots (for batch loading)
    func getAllBackupStatuses() -> [Int: BackupStatus] {
        let discs = database.getAllDiscs()
        var statuses: [Int: BackupStatus] = [:]

        for disc in discs {
            statuses[disc.slotId] = getBackupStatus(slotId: disc.slotId)
        }

        return statuses
    }
}
