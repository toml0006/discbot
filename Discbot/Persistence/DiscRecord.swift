//
//  DiscRecord.swift
//  Discbot
//
//  Model representing a disc record in the database
//

import Foundation

struct DiscRecord {
    let id: Int64?
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
    let firstSeenAt: String?
    let lastSeenAt: String?
    let metadataFetchedAt: String?

    init(
        id: Int64? = nil,
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
        firstSeenAt: String? = nil,
        lastSeenAt: String? = nil,
        metadataFetchedAt: String? = nil
    ) {
        self.id = id
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
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.metadataFetchedAt = metadataFetchedAt
    }

    /// Create from DiscMetadata
    static func from(slotId: Int, metadata: DiscMetadata, discType: DiscType, sizeBytes: Int64?) -> DiscRecord {
        let sourceString: String
        switch metadata.source {
        case .musicBrainz: sourceString = "musicBrainz"
        case .cddb: sourceString = "cddb"
        case .volumeLabel: sourceString = "volumeLabel"
        case .slotNumber: sourceString = "slotNumber"
        }

        let discTypeString: String
        switch discType {
        case .audioCDDA: discTypeString = "audioCDDA"
        case .dataCD: discTypeString = "dataCD"
        case .mixedModeCD: discTypeString = "mixedModeCD"
        case .dvd: discTypeString = "dvd"
        case .unknown: discTypeString = "unknown"
        }

        return DiscRecord(
            slotId: slotId,
            volumeLabel: metadata.album,
            discType: discTypeString,
            sizeBytes: sizeBytes,
            artist: metadata.artist,
            album: metadata.album,
            year: metadata.year,
            trackCount: metadata.tracks?.count,
            metadataSource: sourceString
        )
    }
}
