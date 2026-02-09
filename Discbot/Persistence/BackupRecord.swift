//
//  BackupRecord.swift
//  Discbot
//
//  Model representing a backup record in the database
//

import Foundation

struct BackupRecord {
    let id: Int64?
    let discId: Int64
    let backupPath: String
    let backupSizeBytes: Int64?
    let backupHash: String?
    let backupDate: String
    let backupStatus: String  // 'completed', 'failed', 'in_progress'
    let errorMessage: String?

    init(
        id: Int64? = nil,
        discId: Int64,
        backupPath: String,
        backupSizeBytes: Int64? = nil,
        backupHash: String? = nil,
        backupDate: String? = nil,
        backupStatus: String,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.discId = discId
        self.backupPath = backupPath
        self.backupSizeBytes = backupSizeBytes
        self.backupHash = backupHash
        self.backupDate = backupDate ?? ISO8601DateFormatter().string(from: Date())
        self.backupStatus = backupStatus
        self.errorMessage = errorMessage
    }

    var isCompleted: Bool {
        backupStatus == "completed"
    }

    var isFailed: Bool {
        backupStatus == "failed"
    }

    var backupDateParsed: Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: backupDate)
    }
}
