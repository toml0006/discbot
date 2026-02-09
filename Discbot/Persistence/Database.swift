//
//  Database.swift
//  Discbot
//
//  SQLite database wrapper for disc catalog persistence
//

import Foundation

final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "discbot.database", qos: .userInitiated)

    private init() {
        openDatabase()
        createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let fileManager = FileManager.default

        // Get Application Support directory
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("Database: Failed to get Application Support directory")
            return
        }

        let discbotDir = appSupport.appendingPathComponent("Discbot", isDirectory: true)

        // Create directory if needed
        if !fileManager.fileExists(atPath: discbotDir.path) {
            do {
                try fileManager.createDirectory(at: discbotDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Database: Failed to create directory: \(error)")
                return
            }
        }

        let dbPath = discbotDir.appendingPathComponent("discbot.sqlite").path
        print("Database: Opening at \(dbPath)")

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Database: Failed to open database")
            if let db = db {
                print("Database: Error - \(String(cString: sqlite3_errmsg(db)))")
            }
            db = nil
        }
    }

    private func createTables() {
        let createDiscsTable = """
            CREATE TABLE IF NOT EXISTS discs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                slot_id INTEGER NOT NULL UNIQUE,
                volume_label TEXT,
                disc_type TEXT,
                size_bytes INTEGER,
                musicbrainz_disc_id TEXT,
                artist TEXT,
                album TEXT,
                year TEXT,
                genre TEXT,
                track_count INTEGER,
                metadata_source TEXT,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                metadata_fetched_at TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_discs_slot ON discs(slot_id);
            """

        let createBackupsTable = """
            CREATE TABLE IF NOT EXISTS backups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                disc_id INTEGER NOT NULL,
                backup_path TEXT NOT NULL,
                backup_size_bytes INTEGER,
                backup_hash TEXT,
                backup_date TEXT NOT NULL,
                backup_status TEXT NOT NULL,
                error_message TEXT,
                FOREIGN KEY (disc_id) REFERENCES discs(id)
            );
            CREATE INDEX IF NOT EXISTS idx_backups_disc ON backups(disc_id);
            """

        execute(sql: createDiscsTable)
        execute(sql: createBackupsTable)
    }

    // MARK: - Helpers

    private func execute(sql: String) {
        guard let db = db else { return }

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("Database: SQL error - \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    // MARK: - Disc Operations

    func insertOrUpdateDisc(_ disc: DiscRecord) -> Int64? {
        return queue.sync {
            guard let db = db else { return nil }

            let now = ISO8601DateFormatter().string(from: Date())

            // Check if disc exists
            if let existing = getDiscSync(slotId: disc.slotId) {
                // Update existing
                let sql = """
                    UPDATE discs SET
                        volume_label = ?,
                        disc_type = ?,
                        size_bytes = ?,
                        artist = COALESCE(?, artist),
                        album = COALESCE(?, album),
                        year = COALESCE(?, year),
                        metadata_source = COALESCE(?, metadata_source),
                        last_seen_at = ?
                    WHERE slot_id = ?
                    """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, disc.volumeLabel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 2, disc.discType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    if let size = disc.sizeBytes {
                        sqlite3_bind_int64(stmt, 3, size)
                    } else {
                        sqlite3_bind_null(stmt, 3)
                    }
                    sqlite3_bind_text(stmt, 4, disc.artist, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 5, disc.album, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 6, disc.year, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 7, disc.metadataSource, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 8, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_int(stmt, 9, Int32(disc.slotId))

                    sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
                return existing.id
            } else {
                // Insert new
                let sql = """
                    INSERT INTO discs (slot_id, volume_label, disc_type, size_bytes, artist, album, year, metadata_source, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int(stmt, 1, Int32(disc.slotId))
                    sqlite3_bind_text(stmt, 2, disc.volumeLabel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 3, disc.discType, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    if let size = disc.sizeBytes {
                        sqlite3_bind_int64(stmt, 4, size)
                    } else {
                        sqlite3_bind_null(stmt, 4)
                    }
                    sqlite3_bind_text(stmt, 5, disc.artist, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 6, disc.album, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 7, disc.year, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 8, disc.metadataSource, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 9, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    sqlite3_bind_text(stmt, 10, now, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

                    if sqlite3_step(stmt) == SQLITE_DONE {
                        sqlite3_finalize(stmt)
                        return sqlite3_last_insert_rowid(db)
                    }
                    sqlite3_finalize(stmt)
                }
                return nil
            }
        }
    }

    func getDisc(slotId: Int) -> DiscRecord? {
        return queue.sync {
            getDiscSync(slotId: slotId)
        }
    }

    private func getDiscSync(slotId: Int) -> DiscRecord? {
        guard let db = db else { return nil }

        let sql = "SELECT * FROM discs WHERE slot_id = ?"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(slotId))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return discFromStatement(stmt)
    }

    func getAllDiscs() -> [DiscRecord] {
        return queue.sync {
            guard let db = db else { return [] }

            let sql = "SELECT * FROM discs ORDER BY slot_id"
            var stmt: OpaquePointer?
            var discs: [DiscRecord] = []

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let disc = discFromStatement(stmt) {
                    discs.append(disc)
                }
            }

            return discs
        }
    }

    private func discFromStatement(_ stmt: OpaquePointer?) -> DiscRecord? {
        guard let stmt = stmt else { return nil }

        let id = sqlite3_column_int64(stmt, 0)
        let slotId = Int(sqlite3_column_int(stmt, 1))

        func getString(_ col: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: ptr)
        }

        return DiscRecord(
            id: id,
            slotId: slotId,
            volumeLabel: getString(2),
            discType: getString(3),
            sizeBytes: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_int64(stmt, 4) : nil,
            musicbrainzDiscId: getString(5),
            artist: getString(6),
            album: getString(7),
            year: getString(8),
            genre: getString(9),
            trackCount: sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 10)) : nil,
            metadataSource: getString(11),
            firstSeenAt: getString(12),
            lastSeenAt: getString(13),
            metadataFetchedAt: getString(14)
        )
    }

    // MARK: - Backup Operations

    func insertBackup(_ backup: BackupRecord) -> Int64? {
        return queue.sync {
            guard let db = db else { return nil }

            let sql = """
                INSERT INTO backups (disc_id, backup_path, backup_size_bytes, backup_hash, backup_date, backup_status, error_message)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, backup.discId)
            sqlite3_bind_text(stmt, 2, backup.backupPath, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let size = backup.backupSizeBytes {
                sqlite3_bind_int64(stmt, 3, size)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, backup.backupHash, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 5, backup.backupDate, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 6, backup.backupStatus, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 7, backup.errorMessage, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            if sqlite3_step(stmt) == SQLITE_DONE {
                return sqlite3_last_insert_rowid(db)
            }
            return nil
        }
    }

    func getBackups(discId: Int64) -> [BackupRecord] {
        return queue.sync {
            guard let db = db else { return [] }

            let sql = "SELECT * FROM backups WHERE disc_id = ? ORDER BY backup_date DESC"
            var stmt: OpaquePointer?
            var backups: [BackupRecord] = []

            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, discId)

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let backup = backupFromStatement(stmt) {
                    backups.append(backup)
                }
            }

            return backups
        }
    }

    func getLatestBackup(slotId: Int) -> BackupRecord? {
        return queue.sync {
            guard let db = db else { return nil }

            let sql = """
                SELECT b.* FROM backups b
                JOIN discs d ON b.disc_id = d.id
                WHERE d.slot_id = ? AND b.backup_status = 'completed'
                ORDER BY b.backup_date DESC
                LIMIT 1
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, Int32(slotId))

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            return backupFromStatement(stmt)
        }
    }

    private func backupFromStatement(_ stmt: OpaquePointer?) -> BackupRecord? {
        guard let stmt = stmt else { return nil }

        func getString(_ col: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: ptr)
        }

        return BackupRecord(
            id: sqlite3_column_int64(stmt, 0),
            discId: sqlite3_column_int64(stmt, 1),
            backupPath: getString(2) ?? "",
            backupSizeBytes: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? sqlite3_column_int64(stmt, 3) : nil,
            backupHash: getString(4),
            backupDate: getString(5) ?? "",
            backupStatus: getString(6) ?? "unknown",
            errorMessage: getString(7)
        )
    }
}
