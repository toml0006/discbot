//
//  DiscMetadata.swift
//  Discbot
//
//  Metadata for a disc (from MusicBrainz, CDDB, or filesystem)
//

import Foundation

struct DiscMetadata: Equatable, Codable {
    let artist: String
    let album: String
    let year: String?
    let genre: String?
    let tracks: [TrackInfo]?
    let source: MetadataSource
    let providerID: String?
    let overview: String?
    let artworkURL: String?

    init(
        artist: String,
        album: String,
        year: String?,
        genre: String? = nil,
        tracks: [TrackInfo]?,
        source: MetadataSource,
        providerID: String? = nil,
        overview: String? = nil,
        artworkURL: String? = nil
    ) {
        self.artist = artist
        self.album = album
        self.year = year
        self.genre = genre
        self.tracks = tracks
        self.source = source
        self.providerID = providerID
        self.overview = overview
        self.artworkURL = artworkURL
    }

    enum MetadataSource: String, Equatable, Codable, CaseIterable {
        case musicBrainz
        case tmdb
        case cddb
        case manual
        case volumeLabel
        case slotNumber

        var displayName: String {
            switch self {
            case .musicBrainz: return "MusicBrainz"
            case .tmdb: return "TMDB"
            case .cddb: return "CDDB"
            case .manual: return "Manual"
            case .volumeLabel: return "Disc label"
            case .slotNumber: return "Slot number"
            }
        }
    }

    struct TrackInfo: Equatable, Codable {
        let number: Int
        let title: String
        let duration: TimeInterval?
    }

    /// Generate a sanitized filename from metadata
    func generateFilename(slotNumber: Int, includeSlot: Bool = true) -> String {
        var name: String

        switch source {
        case .musicBrainz, .cddb, .manual, .tmdb:
            var parts = [artist, "-", album]
            if let year = year {
                parts.append("(\(year))")
            }
            name = parts.joined(separator: " ")

        case .volumeLabel:
            name = album

        case .slotNumber:
            name = "Disc_\(String(format: "%03d", slotNumber))"
        }

        // Sanitize for filesystem
        name = sanitize(name)

        // Add slot number prefix for sorting
        if includeSlot {
            name = "\(String(format: "%03d", slotNumber))_\(name)"
        }

        return name
    }

    private func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: illegal)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }
}
