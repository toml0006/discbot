//
//  DiscMetadata.swift
//  VGPChangerApp
//
//  Metadata for a disc (from MusicBrainz, CDDB, or filesystem)
//

import Foundation

struct DiscMetadata: Equatable {
    let artist: String
    let album: String
    let year: String?
    let tracks: [TrackInfo]?
    let source: MetadataSource

    enum MetadataSource: Equatable {
        case musicBrainz
        case cddb
        case volumeLabel
        case slotNumber
    }

    struct TrackInfo: Equatable {
        let number: Int
        let title: String
        let duration: TimeInterval?
    }

    /// Generate a sanitized filename from metadata
    func generateFilename(slotNumber: Int, includeSlot: Bool = true) -> String {
        var name: String

        switch source {
        case .musicBrainz, .cddb:
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
