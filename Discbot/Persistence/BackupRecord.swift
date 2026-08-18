//
//  BackupRecord.swift
//  Discbot
//
//  One rip attempt in a disc's permanent history
//

import Foundation

struct BackupRecord: Identifiable, Equatable {
    let id: Int64?
    let discId: Int64
    let slotId: Int?
    let backupPath: String
    let backupSizeBytes: Int64?
    let backupHash: String?
    let startedAt: String
    let completedAt: String?
    let backupStatus: String  // in_progress, completed, failed, cancelled, skipped
    let errorMessage: String?

    init(
        id: Int64? = nil,
        discId: Int64,
        slotId: Int? = nil,
        backupPath: String,
        backupSizeBytes: Int64? = nil,
        backupHash: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil,
        backupStatus: String,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.discId = discId
        self.slotId = slotId
        self.backupPath = backupPath
        self.backupSizeBytes = backupSizeBytes
        self.backupHash = backupHash
        self.startedAt = startedAt ?? ISO8601DateFormatter().string(from: Date())
        self.completedAt = completedAt
        self.backupStatus = backupStatus
        self.errorMessage = errorMessage
    }

    var isCompleted: Bool { backupStatus == "completed" }
    var isFailed: Bool { backupStatus == "failed" }
    var isCancelled: Bool { backupStatus == "cancelled" }
    var isReplaced: Bool { backupStatus == "replaced" }
    var fileExists: Bool {
        guard isCompleted, FileManager.default.fileExists(atPath: backupPath) else { return false }
        if let expectedSize = backupSizeBytes,
           let attributes = try? FileManager.default.attributesOfItem(atPath: backupPath),
           let actualSize = attributes[.size] as? NSNumber,
           actualSize.int64Value != expectedSize {
            return false
        }
        guard URL(fileURLWithPath: backupPath).pathExtension.lowercased() == "bin" else { return true }
        return FileManager.default.fileExists(atPath: associatedCueURL.path)
    }

    var associatedCueURL: URL {
        URL(fileURLWithPath: backupPath).deletingPathExtension().appendingPathExtension("cue")
    }

    var preferredOpenURL: URL {
        let fileURL = URL(fileURLWithPath: backupPath)
        return fileURL.pathExtension.lowercased() == "bin" && FileManager.default.fileExists(atPath: associatedCueURL.path)
            ? associatedCueURL
            : fileURL
    }

    var backupDate: String { completedAt ?? startedAt }

    var backupDateParsed: Date? {
        ISO8601DateFormatter().date(from: backupDate)
    }
}

struct RipLogRecord: Identifiable, Equatable {
    let id: Int64?
    let ripId: Int64?
    let discId: Int64
    let slotId: Int?
    let eventType: String
    let message: String
    let eventAt: String

    var eventDate: Date? { ISO8601DateFormatter().date(from: eventAt) }
}
