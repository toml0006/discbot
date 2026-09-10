//
//  BackupRecord.swift
//  Discbot
//
//  One rip attempt in a disc's permanent history
//

import Foundation
import CommonCrypto
import Darwin

enum RipArtifactInspector {
    /// POSIX I/O reports errors without FileHandle's older Objective-C
    /// exceptions and supports the initial Catalina release (10.15.0).
    static func readChunk(from handle: FileHandle, checkCancellation: () throws -> Void) throws -> Data {
        var data = Data(count: 1024 * 1024)
        while true {
            try checkCancellation()
            let count = data.withUnsafeMutableBytes {
                Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count >= 0 {
                data.count = count
                return data
            }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    static func writeChunk(_ data: Data, to handle: FileHandle, checkCancellation: () throws -> Void) throws {
        var offset = 0
        while offset < data.count {
            try checkCancellation()
            let count = data.withUnsafeBytes {
                Darwin.write(handle.fileDescriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count > 0 { offset += count }
            else if count == 0 { throw POSIXError(.EIO) }
            else if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    static func integrityHash(at primaryURL: URL, checkCancellation: () throws -> Void = {}) throws -> String {
        try checkCancellation()
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        for entry in try RipArtifactInspector.hashEntries(for: primaryURL) {
            try checkCancellation()
            let marker = Data("\nDISCBOT-FILE:\(entry.marker)\n".utf8)
            marker.withUnsafeBytes { bytes in
                _ = CC_SHA256_Update(&context, bytes.baseAddress, CC_LONG(marker.count))
            }
            let handle = try FileHandle(forReadingFrom: entry.url)
            defer { handle.closeFile() }
            while true {
                try checkCancellation()
                let data = try readChunk(from: handle, checkCancellation: checkCancellation)
                if data.isEmpty { break }
                data.withUnsafeBytes { bytes in
                    _ = CC_SHA256_Update(&context, bytes.baseAddress, CC_LONG(data.count))
                }
            }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sizeBytes(at url: URL, fileManager: FileManager = .default) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if values.isDirectory == true {
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            var total: Int64 = 0
            for case let child as URL in enumerator {
                let childValues = try child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if childValues.isRegularFile == true {
                    total += Int64(childValues.fileSize ?? 0)
                }
            }
            if let error = enumerationError { throw error }
            return total
        }
        guard values.isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return Int64(values.fileSize ?? 0)
    }

    static func hashEntries(
        for primaryURL: URL,
        fileManager: FileManager = .default
    ) throws -> [(marker: String, url: URL)] {
        let values = try primaryURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: primaryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw CocoaError(.fileReadUnknown)
            }
            let rootPath = primaryURL.standardizedFileURL.path
            var entries: [(String, URL)] = []
            for case let child as URL in enumerator {
                let childValues = try child.resourceValues(forKeys: [.isRegularFileKey])
                guard childValues.isRegularFile == true else { continue }
                let path = child.standardizedFileURL.path
                let relative = path.hasPrefix(rootPath + "/")
                    ? String(path.dropFirst(rootPath.count + 1))
                    : child.lastPathComponent
                entries.append((relative, child))
            }
            if let error = enumerationError { throw error }
            return entries.sorted { $0.0 < $1.0 }
        }

        var urls = [primaryURL]
        if primaryURL.pathExtension.lowercased() == "bin" {
            urls.append(primaryURL.deletingPathExtension().appendingPathExtension("cue"))
        }
        return urls.map { ($0.pathExtension.lowercased(), $0) }
    }
}

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
        if let expectedSize = backupSizeBytes {
            guard let actualSize = try? RipArtifactInspector.sizeBytes(at: URL(fileURLWithPath: backupPath)),
                  actualSize == expectedSize else {
                return false
            }
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
    let discId: Int64?
    let slotId: Int?
    let eventType: String
    let message: String
    let eventAt: String

    var eventDate: Date? { ISO8601DateFormatter().date(from: eventAt) }
}
