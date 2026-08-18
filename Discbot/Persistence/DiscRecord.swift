//
//  DiscRecord.swift
//  Discbot
//
//  Persistent disc identity and catalog presentation models
//

import Foundation

/// A physical disc, identified independently from whichever changer slot it occupies.
struct DiscRecord: Identifiable, Equatable {
    let id: Int64?
    let fingerprint: String
    let fingerprintKind: String
    let fingerprintConfidence: Int
    let slotId: Int
    let volumeLabel: String?
    let discType: String?
    let sizeBytes: Int64?
    let musicbrainzDiscId: String?
    let artist: String?
    let album: String?
    let year: String?
    let genre: String?
    let trackCount: Int?
    let metadataSource: String?
    let metadataProviderID: String?
    let metadataOverview: String?
    let artworkURL: String?
    let metadataUserEdited: Bool
    let metadataTracks: [DiscMetadata.TrackInfo]?
    let firstSeenAt: String?
    let lastSeenAt: String?
    let metadataFetchedAt: String?

    init(
        id: Int64? = nil,
        fingerprint: String,
        fingerprintKind: String,
        fingerprintConfidence: Int,
        slotId: Int,
        volumeLabel: String? = nil,
        discType: String? = nil,
        sizeBytes: Int64? = nil,
        musicbrainzDiscId: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        year: String? = nil,
        genre: String? = nil,
        trackCount: Int? = nil,
        metadataSource: String? = nil,
        metadataProviderID: String? = nil,
        metadataOverview: String? = nil,
        artworkURL: String? = nil,
        metadataUserEdited: Bool = false,
        metadataTracks: [DiscMetadata.TrackInfo]? = nil,
        firstSeenAt: String? = nil,
        lastSeenAt: String? = nil,
        metadataFetchedAt: String? = nil
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.fingerprintKind = fingerprintKind
        self.fingerprintConfidence = fingerprintConfidence
        self.slotId = slotId
        self.volumeLabel = volumeLabel
        self.discType = discType
        self.sizeBytes = sizeBytes
        self.musicbrainzDiscId = musicbrainzDiscId
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.trackCount = trackCount
        self.metadataSource = metadataSource
        self.metadataProviderID = metadataProviderID
        self.metadataOverview = metadataOverview
        self.artworkURL = artworkURL
        self.metadataUserEdited = metadataUserEdited
        self.metadataTracks = metadataTracks
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.metadataFetchedAt = metadataFetchedAt
    }

    var hasReliableIdentity: Bool {
        fingerprintConfidence >= 2
    }

    var displayName: String {
        if let album = album, !album.isEmpty, album != "Unknown" { return album }
        if let volumeLabel = volumeLabel, !volumeLabel.isEmpty { return volumeLabel }
        return "Untitled Disc"
    }

    static func make(
        identity: DiscIdentity,
        slotId: Int,
        metadata: DiscMetadata,
        discType: DiscType,
        sizeBytes: Int64?
    ) -> DiscRecord {
        let sourceString: String
        switch metadata.source {
        case .musicBrainz: sourceString = "musicBrainz"
        case .tmdb: sourceString = "tmdb"
        case .cddb: sourceString = "cddb"
        case .manual: sourceString = "manual"
        case .volumeLabel: sourceString = "volumeLabel"
        case .slotNumber: sourceString = "slotNumber"
        }

        return DiscRecord(
            fingerprint: identity.fingerprint,
            fingerprintKind: identity.kind,
            fingerprintConfidence: identity.confidence,
            slotId: slotId,
            volumeLabel: metadata.source == .slotNumber ? nil : metadata.album,
            discType: discType.catalogString,
            sizeBytes: sizeBytes,
            artist: metadata.artist,
            album: metadata.album,
            year: metadata.year,
            genre: metadata.genre,
            trackCount: metadata.tracks?.count,
            metadataSource: sourceString,
            metadataProviderID: metadata.providerID,
            metadataOverview: metadata.overview,
            artworkURL: metadata.artworkURL,
            metadataTracks: metadata.tracks
        )
    }
}

extension DiscType {
    var catalogString: String {
        switch self {
        case .audioCDDA: return "audioCDDA"
        case .dataCD: return "dataCD"
        case .mixedModeCD: return "mixedModeCD"
        case .dvd: return "dvd"
        case .unknown: return "unknown"
        }
    }
}

struct DiscSightingRecord: Identifiable, Equatable {
    let id: Int64?
    let discId: Int64
    let sessionId: String
    let slotId: Int
    let seenAt: String

    var seenDate: Date? {
        ISO8601DateFormatter().date(from: seenAt)
    }
}

struct CatalogEntry: Identifiable, Equatable {
    let disc: DiscRecord
    let sightings: [DiscSightingRecord]
    let rips: [BackupRecord]

    var id: Int64 { disc.id ?? -1 }
    var existingRips: [BackupRecord] { rips.filter(\.fileExists) }
    var latestExistingRip: BackupRecord? { existingRips.first }
}
