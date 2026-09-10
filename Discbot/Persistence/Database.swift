//
//  Database.swift
//  Discbot
//
//  SQLite-backed permanent disc catalog and rip history
//

import Foundation

final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "discbot.database", qos: .userInitiated)
    private let databaseURL: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Includes every write through this connection, including artwork and logs.
    var revision: Int {
        queue.sync { db.map { Int(sqlite3_total_changes($0)) } ?? 0 }
    }

    init(databaseURL: URL? = nil) {
        if let databaseURL = databaseURL {
            self.databaseURL = databaseURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.databaseURL = appSupport
                .appendingPathComponent("Discbot", isDirectory: true)
                .appendingPathComponent("discbot.sqlite")
        }
        openDatabase()
        createTables()
        migrateLegacyCatalogIfNeeded()
        markInterruptedRips()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Setup

    private func openDatabase() {
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Database: Failed to create \(directory.path): \(error)")
            return
        }

        print("Database: Opening at \(databaseURL.path)")
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            if let db = db { print("Database: \(String(cString: sqlite3_errmsg(db)))") }
            db = nil
            return
        }
        execute(sql: "PRAGMA foreign_keys = ON;")
        execute(sql: "PRAGMA journal_mode = WAL;")
    }

    private func createTables() {
        execute(sql: """
            CREATE TABLE IF NOT EXISTS catalog_discs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fingerprint TEXT NOT NULL UNIQUE,
                fingerprint_kind TEXT NOT NULL,
                fingerprint_confidence INTEGER NOT NULL DEFAULT 1,
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
                metadata_fetched_at TEXT,
                metadata_provider_id TEXT,
                metadata_overview TEXT,
                artwork_url TEXT,
                metadata_user_edited INTEGER NOT NULL DEFAULT 0,
                metadata_tracks_json TEXT,
                artwork_path TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_catalog_discs_last_seen ON catalog_discs(last_seen_at DESC);

            CREATE TABLE IF NOT EXISTS disc_sightings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                disc_id INTEGER NOT NULL,
                session_id TEXT NOT NULL,
                slot_id INTEGER NOT NULL,
                seen_at TEXT NOT NULL,
                FOREIGN KEY (disc_id) REFERENCES catalog_discs(id)
            );
            CREATE INDEX IF NOT EXISTS idx_sightings_disc ON disc_sightings(disc_id, seen_at DESC);
            CREATE INDEX IF NOT EXISTS idx_sightings_session_slot ON disc_sightings(session_id, slot_id, seen_at DESC);

            CREATE TABLE IF NOT EXISTS rip_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                disc_id INTEGER NOT NULL,
                slot_id INTEGER,
                backup_path TEXT NOT NULL,
                backup_size_bytes INTEGER,
                backup_hash TEXT,
                started_at TEXT NOT NULL,
                completed_at TEXT,
                backup_status TEXT NOT NULL,
                error_message TEXT,
                FOREIGN KEY (disc_id) REFERENCES catalog_discs(id)
            );
            CREATE INDEX IF NOT EXISTS idx_rips_disc ON rip_history(disc_id, started_at DESC);
            CREATE INDEX IF NOT EXISTS idx_rips_status ON rip_history(backup_status, completed_at DESC);

            CREATE TABLE IF NOT EXISTS rip_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                rip_id INTEGER,
                disc_id INTEGER NOT NULL,
                slot_id INTEGER,
                event_type TEXT NOT NULL,
                message TEXT NOT NULL,
                event_at TEXT NOT NULL,
                FOREIGN KEY (rip_id) REFERENCES rip_history(id),
                FOREIGN KEY (disc_id) REFERENCES catalog_discs(id)
            );
            CREATE INDEX IF NOT EXISTS idx_rip_events_time ON rip_events(event_at DESC);
            CREATE INDEX IF NOT EXISTS idx_rip_events_rip ON rip_events(rip_id, event_at);

            CREATE TABLE IF NOT EXISTS operation_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                slot_id INTEGER,
                event_type TEXT NOT NULL,
                message TEXT NOT NULL,
                event_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_operation_events_time ON operation_events(event_at DESC);
            """)
        ensureMetadataColumns()
    }

    private func ensureMetadataColumns() {
        let additions = [
            ("metadata_provider_id", "TEXT"),
            ("metadata_overview", "TEXT"),
            ("artwork_url", "TEXT"),
            ("metadata_user_edited", "INTEGER NOT NULL DEFAULT 0"),
            ("metadata_tracks_json", "TEXT"),
            ("artwork_path", "TEXT")
        ]
        for (name, declaration) in additions where !columnExists(table: "catalog_discs", column: name) {
            execute(sql: "ALTER TABLE catalog_discs ADD COLUMN \(name) \(declaration);")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if string(stmt, 1) == column { return true }
        }
        return false
    }

    /// Preserve catalogs created by versions that treated a slot as a disc identity.
    private func migrateLegacyCatalogIfNeeded() {
        guard tableExists("discs") else { return }
        execute(sql: """
            INSERT OR IGNORE INTO catalog_discs (
                id, fingerprint, fingerprint_kind, fingerprint_confidence,
                volume_label, disc_type, size_bytes, musicbrainz_disc_id,
                artist, album, year, genre, track_count, metadata_source,
                first_seen_at, last_seen_at, metadata_fetched_at
            )
            SELECT
                id, 'legacy-slot:' || slot_id, 'legacy-slot', 0,
                volume_label, disc_type, size_bytes, musicbrainz_disc_id,
                artist, album, year, genre, track_count, metadata_source,
                first_seen_at, last_seen_at, metadata_fetched_at
            FROM discs;

            INSERT INTO disc_sightings (disc_id, session_id, slot_id, seen_at)
            SELECT d.id, 'legacy', d.slot_id, d.last_seen_at
            FROM discs d
            WHERE NOT EXISTS (
                SELECT 1 FROM disc_sightings s
                WHERE s.disc_id = d.id AND s.session_id = 'legacy'
            );
            """)

        guard tableExists("backups") else { return }
        execute(sql: """
            INSERT INTO rip_history (
                id, disc_id, slot_id, backup_path, backup_size_bytes,
                backup_hash, started_at, completed_at, backup_status, error_message
            )
            SELECT
                b.id, b.disc_id, d.slot_id, b.backup_path, b.backup_size_bytes,
                b.backup_hash, b.backup_date,
                CASE WHEN b.backup_status = 'completed' THEN b.backup_date ELSE NULL END,
                b.backup_status, b.error_message
            FROM backups b
            JOIN discs d ON d.id = b.disc_id
            WHERE NOT EXISTS (SELECT 1 FROM rip_history r WHERE r.id = b.id);
            """)
    }

    private func markInterruptedRips() {
        let now = ISO8601DateFormatter().string(from: Date())
        execute(sql: """
            UPDATE rip_history
            SET backup_status = 'failed', completed_at = '\(now)',
                error_message = COALESCE(error_message, 'Discbot exited before this rip completed')
            WHERE backup_status = 'in_progress';
            """)
    }

    private func tableExists(_ name: String) -> Bool {
        guard let db = db else { return false }
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: name)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func execute(sql: String) {
        guard let db = db else { return }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            if let error = error {
                print("Database: SQL error - \(String(cString: error))")
                sqlite3_free(error)
            }
        }
    }

    // MARK: - Disc identity and sightings

    func upsertDisc(_ disc: DiscRecord, sessionId: String) -> DiscRecord? {
        queue.sync {
            guard let db = db else { return nil }
            let now = ISO8601DateFormatter().string(from: Date())

            let sql = """
                INSERT INTO catalog_discs (
                    fingerprint, fingerprint_kind, fingerprint_confidence,
                    volume_label, disc_type, size_bytes, musicbrainz_disc_id,
                    artist, album, year, genre, track_count, metadata_source,
                    first_seen_at, last_seen_at, metadata_fetched_at,
                    metadata_provider_id, metadata_overview, artwork_url, metadata_user_edited,
                    metadata_tracks_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(fingerprint) DO UPDATE SET
                    fingerprint_kind = excluded.fingerprint_kind,
                    fingerprint_confidence = MAX(catalog_discs.fingerprint_confidence, excluded.fingerprint_confidence),
                    volume_label = COALESCE(excluded.volume_label, catalog_discs.volume_label),
                    disc_type = COALESCE(excluded.disc_type, catalog_discs.disc_type),
                    size_bytes = COALESCE(excluded.size_bytes, catalog_discs.size_bytes),
                    artist = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.artist ELSE COALESCE(excluded.artist, catalog_discs.artist) END,
                    album = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.album ELSE COALESCE(excluded.album, catalog_discs.album) END,
                    year = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.year ELSE COALESCE(excluded.year, catalog_discs.year) END,
                    genre = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.genre ELSE COALESCE(excluded.genre, catalog_discs.genre) END,
                    track_count = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.track_count ELSE COALESCE(excluded.track_count, catalog_discs.track_count) END,
                    metadata_source = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.metadata_source ELSE COALESCE(excluded.metadata_source, catalog_discs.metadata_source) END,
                    metadata_fetched_at = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.metadata_fetched_at ELSE COALESCE(excluded.metadata_fetched_at, catalog_discs.metadata_fetched_at) END,
                    metadata_provider_id = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.metadata_provider_id ELSE COALESCE(excluded.metadata_provider_id, catalog_discs.metadata_provider_id) END,
                    metadata_overview = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.metadata_overview ELSE COALESCE(excluded.metadata_overview, catalog_discs.metadata_overview) END,
                    artwork_url = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.artwork_url ELSE COALESCE(excluded.artwork_url, catalog_discs.artwork_url) END,
                    metadata_tracks_json = CASE WHEN catalog_discs.metadata_user_edited = 1 THEN catalog_discs.metadata_tracks_json ELSE COALESCE(excluded.metadata_tracks_json, catalog_discs.metadata_tracks_json) END,
                    last_seen_at = excluded.last_seen_at
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, index: 1, value: disc.fingerprint)
            bindText(stmt, index: 2, value: disc.fingerprintKind)
            sqlite3_bind_int(stmt, 3, Int32(disc.fingerprintConfidence))
            bindText(stmt, index: 4, value: disc.volumeLabel)
            bindText(stmt, index: 5, value: disc.discType)
            bindInt64(stmt, index: 6, value: disc.sizeBytes)
            bindText(stmt, index: 7, value: disc.musicbrainzDiscId)
            bindText(stmt, index: 8, value: disc.artist)
            bindText(stmt, index: 9, value: disc.album)
            bindText(stmt, index: 10, value: disc.year)
            bindText(stmt, index: 11, value: disc.genre)
            bindInt(stmt, index: 12, value: disc.trackCount)
            bindText(stmt, index: 13, value: disc.metadataSource)
            bindText(stmt, index: 14, value: disc.firstSeenAt ?? now)
            bindText(stmt, index: 15, value: now)
            bindText(stmt, index: 16, value: disc.metadataFetchedAt)
            bindText(stmt, index: 17, value: disc.metadataProviderID)
            bindText(stmt, index: 18, value: disc.metadataOverview)
            bindText(stmt, index: 19, value: disc.artworkURL)
            sqlite3_bind_int(stmt, 20, disc.metadataUserEdited ? 1 : 0)
            bindText(stmt, index: 21, value: encodeTracks(disc.metadataTracks))
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }

            guard let stored = getDiscByFingerprintSync(disc.fingerprint, latestSlotId: disc.slotId),
                  let discId = stored.id else { return nil }
            insertSightingSync(discId: discId, sessionId: sessionId, slotId: disc.slotId, seenAt: now)
            return stored
        }
    }

    func getDisc(slotId: Int, sessionId: String) -> DiscRecord? {
        queue.sync {
            guard let db = db else { return nil }
            let sql = """
                SELECT d.*, s.slot_id
                FROM disc_sightings s
                JOIN catalog_discs d ON d.id = s.disc_id
                WHERE s.session_id = ? AND s.slot_id = ?
                ORDER BY s.seen_at DESC LIMIT 1
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: sessionId)
            sqlite3_bind_int(stmt, 2, Int32(slotId))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return discFromStatement(stmt)
        }
    }

    func getAllDiscs() -> [DiscRecord] {
        queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT d.*, COALESCE((
                    SELECT s.slot_id FROM disc_sightings s
                    WHERE s.disc_id = d.id ORDER BY s.seen_at DESC LIMIT 1
                ), 0) AS latest_slot
                FROM catalog_discs d
                ORDER BY d.last_seen_at DESC
                """
            var stmt: OpaquePointer?
            var result: [DiscRecord] = []
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let disc = discFromStatement(stmt) { result.append(disc) }
            }
            return result
        }
    }

    func updateDiscMetadata(id: Int64, metadata: DiscMetadata, userEdited: Bool) -> DiscRecord? {
        queue.sync {
            guard let db = db else { return nil }
            let sql = """
                UPDATE catalog_discs SET
                    artist = ?, album = ?, year = ?, genre = ?, track_count = ?,
                    metadata_source = ?, metadata_fetched_at = ?, metadata_provider_id = ?,
                    metadata_overview = ?, artwork_url = ?, metadata_user_edited = ?,
                    metadata_tracks_json = ?
                WHERE id = ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: metadata.artist)
            bindText(stmt, index: 2, value: metadata.album)
            bindText(stmt, index: 3, value: metadata.year)
            bindText(stmt, index: 4, value: metadata.genre)
            bindInt(stmt, index: 5, value: metadata.tracks?.count)
            bindText(stmt, index: 6, value: metadata.source.rawValue)
            bindText(stmt, index: 7, value: ISO8601DateFormatter().string(from: Date()))
            bindText(stmt, index: 8, value: metadata.providerID)
            bindText(stmt, index: 9, value: metadata.overview)
            bindText(stmt, index: 10, value: metadata.artworkURL)
            sqlite3_bind_int(stmt, 11, userEdited ? 1 : 0)
            bindText(stmt, index: 12, value: encodeTracks(metadata.tracks))
            sqlite3_bind_int64(stmt, 13, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return getDiscByIDSync(id)
        }
    }

    func getDisc(id: Int64) -> DiscRecord? {
        queue.sync { getDiscByIDSync(id) }
    }

    @discardableResult
    func updateDiscArtworkPath(id: Int64, path: String?) -> DiscRecord? {
        queue.sync {
            guard let db = db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "UPDATE catalog_discs SET artwork_path = ? WHERE id = ?",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: path)
            sqlite3_bind_int64(stmt, 2, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return getDiscByIDSync(id)
        }
    }

    private func getDiscByIDSync(_ id: Int64) -> DiscRecord? {
        guard let db = db else { return nil }
        let sql = """
            SELECT d.*, COALESCE((SELECT s.slot_id FROM disc_sightings s
                WHERE s.disc_id = d.id ORDER BY s.seen_at DESC LIMIT 1), 0) AS latest_slot
            FROM catalog_discs d WHERE d.id = ? LIMIT 1
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return discFromStatement(stmt)
    }

    func getDiscs(sessionId: String) -> [DiscRecord] {
        queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT d.*, s.slot_id
                FROM disc_sightings s
                JOIN catalog_discs d ON d.id = s.disc_id
                WHERE s.session_id = ?
                  AND s.id = (
                      SELECT s2.id FROM disc_sightings s2
                      WHERE s2.session_id = s.session_id AND s2.slot_id = s.slot_id
                      ORDER BY s2.seen_at DESC, s2.id DESC LIMIT 1
                  )
                ORDER BY s.slot_id
                """
            var stmt: OpaquePointer?
            var result: [DiscRecord] = []
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: sessionId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let disc = discFromStatement(stmt) { result.append(disc) }
            }
            return result
        }
    }

    func getMostRecentSessionId() -> String? {
        queue.sync {
            guard let db = db else { return nil }
            let sql = """
                SELECT session_id
                FROM disc_sightings
                WHERE session_id <> 'legacy'
                ORDER BY seen_at DESC, id DESC
                LIMIT 1
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return string(stmt, 0)
        }
    }

    private func getDiscByFingerprintSync(_ fingerprint: String, latestSlotId: Int) -> DiscRecord? {
        guard let db = db else { return nil }
        let sql = "SELECT d.*, ? AS latest_slot FROM catalog_discs d WHERE fingerprint = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(latestSlotId))
        bindText(stmt, index: 2, value: fingerprint)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return discFromStatement(stmt)
    }

    private func insertSightingSync(discId: Int64, sessionId: String, slotId: Int, seenAt: String) {
        guard let db = db else { return }
        let sql = "INSERT INTO disc_sightings (disc_id, session_id, slot_id, seen_at) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, discId)
        bindText(stmt, index: 2, value: sessionId)
        sqlite3_bind_int(stmt, 3, Int32(slotId))
        bindText(stmt, index: 4, value: seenAt)
        sqlite3_step(stmt)
    }

    private func discFromStatement(_ stmt: OpaquePointer?) -> DiscRecord? {
        guard let stmt = stmt else { return nil }
        return DiscRecord(
            id: sqlite3_column_int64(stmt, 0),
            fingerprint: string(stmt, 1) ?? "",
            fingerprintKind: string(stmt, 2) ?? "unknown",
            fingerprintConfidence: Int(sqlite3_column_int(stmt, 3)),
            slotId: Int(sqlite3_column_int(stmt, 23)),
            volumeLabel: string(stmt, 4),
            discType: string(stmt, 5),
            sizeBytes: optionalInt64(stmt, 6),
            musicbrainzDiscId: string(stmt, 7),
            artist: string(stmt, 8),
            album: string(stmt, 9),
            year: string(stmt, 10),
            genre: string(stmt, 11),
            trackCount: optionalInt(stmt, 12),
            metadataSource: string(stmt, 13),
            metadataProviderID: string(stmt, 17),
            metadataOverview: string(stmt, 18),
            artworkURL: string(stmt, 19),
            artworkPath: string(stmt, 22),
            metadataUserEdited: sqlite3_column_int(stmt, 20) != 0,
            metadataTracks: decodeTracks(string(stmt, 21)),
            firstSeenAt: string(stmt, 14),
            lastSeenAt: string(stmt, 15),
            metadataFetchedAt: string(stmt, 16)
        )
    }

    // MARK: - Rip history

    func startRip(discId: Int64, slotId: Int, path: String) -> Int64? {
        let ripId: Int64? = queue.sync {
            guard let db = db else { return nil }
            let sql = """
                INSERT INTO rip_history (disc_id, slot_id, backup_path, started_at, backup_status)
                VALUES (?, ?, ?, ?, 'in_progress')
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, discId)
            sqlite3_bind_int(stmt, 2, Int32(slotId))
            bindText(stmt, index: 3, value: path)
            bindText(stmt, index: 4, value: ISO8601DateFormatter().string(from: Date()))
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return sqlite3_last_insert_rowid(db)
        }
        if let ripId = ripId {
            recordRipEvent(
                ripId: ripId, discId: discId, slotId: slotId,
                type: "started", message: "Ripping to \(path)"
            )
        }
        return ripId
    }

    func finishRip(
        id: Int64,
        status: String,
        finalPath: String? = nil,
        sizeBytes: Int64? = nil,
        hash: String? = nil,
        error: String? = nil
    ) {
        var discId: Int64?
        var slotId: Int?
        queue.sync {
            guard let db = db else { return }
            let sql = """
                UPDATE rip_history SET
                    backup_path = COALESCE(?, backup_path),
                    backup_size_bytes = ?, backup_hash = ?, completed_at = ?,
                    backup_status = ?, error_message = ?
                WHERE id = ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: finalPath)
            bindInt64(stmt, index: 2, value: sizeBytes)
            bindText(stmt, index: 3, value: hash)
            bindText(stmt, index: 4, value: ISO8601DateFormatter().string(from: Date()))
            bindText(stmt, index: 5, value: status)
            bindText(stmt, index: 6, value: error)
            sqlite3_bind_int64(stmt, 7, id)
            sqlite3_step(stmt)

            let lookup = "SELECT disc_id, slot_id FROM rip_history WHERE id = ?"
            var lookupStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, lookup, -1, &lookupStatement, nil) == SQLITE_OK {
                defer { sqlite3_finalize(lookupStatement) }
                sqlite3_bind_int64(lookupStatement, 1, id)
                if sqlite3_step(lookupStatement) == SQLITE_ROW {
                    discId = sqlite3_column_int64(lookupStatement, 0)
                    slotId = optionalInt(lookupStatement, 1)
                }
            }
        }
        if let discId = discId {
            let message = error ?? finalPath ?? status.capitalized
            recordRipEvent(ripId: id, discId: discId, slotId: slotId, type: status, message: message)
        }
    }

    func markRipReplaced(id: Int64, replacementPath: String) {
        var discId: Int64?
        var slotId: Int?
        queue.sync {
            guard let db = db else { return }
            let sql = """
                UPDATE rip_history
                SET backup_status = 'replaced',
                    error_message = 'Superseded by ' || ?
                WHERE id = ? AND backup_status = 'completed'
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: replacementPath)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)

            let lookup = "SELECT disc_id, slot_id FROM rip_history WHERE id = ?"
            var lookupStatement: OpaquePointer?
            if sqlite3_prepare_v2(db, lookup, -1, &lookupStatement, nil) == SQLITE_OK {
                defer { sqlite3_finalize(lookupStatement) }
                sqlite3_bind_int64(lookupStatement, 1, id)
                if sqlite3_step(lookupStatement) == SQLITE_ROW {
                    discId = sqlite3_column_int64(lookupStatement, 0)
                    slotId = optionalInt(lookupStatement, 1)
                }
            }
        }
        if let discId = discId {
            recordRipEvent(
                ripId: id, discId: discId, slotId: slotId,
                type: "replaced", message: "Superseded by \(replacementPath)"
            )
        }
    }

    func getRecentRipEvents(limit: Int = 250) -> [RipLogRecord] {
        queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT id, rip_id, disc_id, slot_id, event_type, message, event_at
                FROM (
                    SELECT id, rip_id, disc_id, slot_id, event_type, message, event_at,
                           id AS source_sequence
                    FROM rip_events
                    UNION ALL
                    SELECT -id, NULL, NULL, slot_id, event_type, message, event_at,
                           id AS source_sequence
                    FROM operation_events
                )
                ORDER BY event_at DESC, source_sequence DESC LIMIT ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))
            var result: [RipLogRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(RipLogRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    ripId: optionalInt64(stmt, 1),
                    discId: optionalInt64(stmt, 2),
                    slotId: optionalInt(stmt, 3),
                    eventType: string(stmt, 4) ?? "unknown",
                    message: string(stmt, 5) ?? "",
                    eventAt: string(stmt, 6) ?? ""
                ))
            }
            return result
        }
    }

    func recordOperationEvent(slotId: Int?, type: String, message: String) {
        queue.sync {
            guard let db = db else { return }
            let sql = """
                INSERT INTO operation_events (slot_id, event_type, message, event_at)
                VALUES (?, ?, ?, ?)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if let slotId = slotId { sqlite3_bind_int(stmt, 1, Int32(slotId)) }
            else { sqlite3_bind_null(stmt, 1) }
            bindText(stmt, index: 2, value: type)
            bindText(stmt, index: 3, value: message)
            bindText(stmt, index: 4, value: ISO8601DateFormatter().string(from: Date()))
            sqlite3_step(stmt)
        }
    }

    private func recordRipEvent(
        ripId: Int64?, discId: Int64, slotId: Int?, type: String, message: String
    ) {
        queue.sync {
            guard let db = db else { return }
            let sql = """
                INSERT INTO rip_events (rip_id, disc_id, slot_id, event_type, message, event_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindInt64(stmt, index: 1, value: ripId)
            sqlite3_bind_int64(stmt, 2, discId)
            if let slotId = slotId { sqlite3_bind_int(stmt, 3, Int32(slotId)) }
            else { sqlite3_bind_null(stmt, 3) }
            bindText(stmt, index: 4, value: type)
            bindText(stmt, index: 5, value: message)
            bindText(stmt, index: 6, value: ISO8601DateFormatter().string(from: Date()))
            sqlite3_step(stmt)
        }
    }

    func getRips(discId: Int64) -> [BackupRecord] {
        queue.sync { getRipsSync(discId: discId) }
    }

    func getLatestCompletedRip(discId: Int64) -> BackupRecord? {
        queue.sync {
            getRipsSync(discId: discId).first(where: { $0.isCompleted })
        }
    }

    private func getRipsSync(discId: Int64) -> [BackupRecord] {
        guard let db = db else { return [] }
        let sql = """
            SELECT id, disc_id, slot_id, backup_path, backup_size_bytes, backup_hash,
                   started_at, completed_at, backup_status, error_message
            FROM rip_history WHERE disc_id = ? ORDER BY started_at DESC, id DESC
            """
        var stmt: OpaquePointer?
        var result: [BackupRecord] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, discId)
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(BackupRecord(
                id: sqlite3_column_int64(stmt, 0),
                discId: sqlite3_column_int64(stmt, 1),
                slotId: optionalInt(stmt, 2),
                backupPath: string(stmt, 3) ?? "",
                backupSizeBytes: optionalInt64(stmt, 4),
                backupHash: string(stmt, 5),
                startedAt: string(stmt, 6),
                completedAt: string(stmt, 7),
                backupStatus: string(stmt, 8) ?? "unknown",
                errorMessage: string(stmt, 9)
            ))
        }
        return result
    }

    func getSightings(discId: Int64) -> [DiscSightingRecord] {
        queue.sync {
            guard let db = db else { return [] }
            let sql = """
                SELECT id, disc_id, session_id, slot_id, seen_at
                FROM disc_sightings WHERE disc_id = ? ORDER BY seen_at DESC
                """
            var stmt: OpaquePointer?
            var result: [DiscSightingRecord] = []
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, discId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(DiscSightingRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    discId: sqlite3_column_int64(stmt, 1),
                    sessionId: string(stmt, 2) ?? "",
                    slotId: Int(sqlite3_column_int(stmt, 3)),
                    seenAt: string(stmt, 4) ?? ""
                ))
            }
            return result
        }
    }

    // MARK: - SQLite binding helpers

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindInt64(_ stmt: OpaquePointer?, index: Int32, value: Int64?) {
        if let value = value { sqlite3_bind_int64(stmt, index, value) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func bindInt(_ stmt: OpaquePointer?, index: Int32, value: Int?) {
        if let value = value { sqlite3_bind_int(stmt, index, Int32(value)) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func string(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: ptr)
    }

    private func optionalInt64(_ stmt: OpaquePointer?, _ column: Int32) -> Int64? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, column)
    }

    private func optionalInt(_ stmt: OpaquePointer?, _ column: Int32) -> Int? {
        sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, column))
    }

    private func encodeTracks(_ tracks: [DiscMetadata.TrackInfo]?) -> String? {
        guard let tracks = tracks, let data = try? JSONEncoder().encode(tracks) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeTracks(_ value: String?) -> [DiscMetadata.TrackInfo]? {
        guard let value = value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([DiscMetadata.TrackInfo].self, from: data)
    }
}
