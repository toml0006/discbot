//
//  MetadataService.swift
//  Discbot
//
//  Service for looking up disc metadata from online services
//

import Foundation
import CommonCrypto

final class MetadataService {
    private let mountService = MountService()

    // MARK: - MusicBrainz API

    private struct MusicBrainzResponse: Codable {
        let releases: [MBRelease]?

        struct MBRelease: Codable {
            let id: String
            let title: String
            let artistCredit: [ArtistCredit]?
            let date: String?
            let country: String?

            enum CodingKeys: String, CodingKey {
                case id, title, date, country
                case artistCredit = "artist-credit"
            }
        }

        struct ArtistCredit: Codable {
            let name: String
            let artist: Artist
        }

        struct Artist: Codable {
            let id: String
            let name: String
        }
    }

    /// Look up metadata from MusicBrainz by disc ID (blocking)
    func lookupMusicBrainz(discID: String) -> DiscMetadata? {
        let urlString = "https://musicbrainz.org/ws/2/discid/\(discID)?fmt=json&inc=artists"
        guard let url = URL(string: urlString) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Discbot/1.0 (contact@example.com)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let data = resultData,
              let httpResponse = resultResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        do {
            let result = try JSONDecoder().decode(MusicBrainzResponse.self, from: data)
            guard let release = result.releases?.first else {
                return nil
            }

            let artist = release.artistCredit?.first?.name ?? "Unknown Artist"
            let year = release.date?.prefix(4).description

            return DiscMetadata(
                artist: artist,
                album: release.title,
                year: year,
                tracks: nil,
                source: .musicBrainz
            )
        } catch {
            return nil
        }
    }

    // MARK: - Volume Label Fallback

    /// Get volume label for a mounted disc
    func getVolumeLabel(bsdName: String) -> String? {
        return mountService.getVolumeName(bsdName: bsdName)
    }

    // MARK: - Metadata Resolution

    /// Resolve metadata using all available sources (blocking)
    func resolveMetadata(bsdName: String, slotNumber: Int) -> DiscMetadata {
        // 1. Try volume label first (works for any mounted disc)
        if let volumeLabel = getVolumeLabel(bsdName: bsdName), !volumeLabel.isEmpty {
            return DiscMetadata(
                artist: "Unknown",
                album: volumeLabel,
                year: nil,
                tracks: nil,
                source: .volumeLabel
            )
        }

        // 2. Final fallback: slot number
        return DiscMetadata(
            artist: "Unknown",
            album: "Disc from Slot \(String(format: "%03d", slotNumber))",
            year: nil,
            tracks: nil,
            source: .slotNumber
        )
    }

    /// Generate a filename from metadata
    func generateFilename(metadata: DiscMetadata, slotNumber: Int, format: ImageFormat) -> String {
        let baseName = metadata.generateFilename(slotNumber: slotNumber, includeSlot: true)
        return baseName + format.fileExtension
    }

    enum ImageFormat {
        case iso
        case binCue

        var fileExtension: String {
            switch self {
            case .iso: return ".iso"
            case .binCue: return "" // Creates .bin and .cue separately
            }
        }
    }
}

// MARK: - Disc ID Calculation (for future MusicBrainz support)

extension MetadataService {
    /// Calculate MusicBrainz disc ID from CD TOC
    /// This requires reading the TOC via IOKit ioctls
    func calculateMusicBrainzDiscID(firstTrack: Int, lastTrack: Int, leadOutOffset: Int, trackOffsets: [Int]) -> String {
        // Build the hash input
        var data = ""
        data += String(format: "%02X", firstTrack)
        data += String(format: "%02X", lastTrack)
        data += String(format: "%08X", leadOutOffset)

        // 99 track offsets, pad with zeros
        for i in 0..<99 {
            if i < trackOffsets.count {
                data += String(format: "%08X", trackOffsets[i])
            } else {
                data += "00000000"
            }
        }

        // SHA-1 hash using CommonCrypto
        let dataBytes = Array(data.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(dataBytes, CC_LONG(dataBytes.count), &hash)

        // Base64 encode with MusicBrainz custom alphabet
        let hashData = Data(hash)
        let base64 = hashData.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }
}
