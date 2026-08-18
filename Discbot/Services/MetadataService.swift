//
//  MetadataService.swift
//  Discbot
//
//  Provider-backed metadata lookup for audio CDs and video DVDs.
//

import Foundation
import CommonCrypto

struct MetadataCandidate: Codable, Equatable {
    let id: String
    let provider: String
    let title: String
    let artist: String?
    let year: String?
    let genre: String?
    let overview: String?
    let artworkURL: String?
    let tracks: [DiscMetadata.TrackInfo]?

    var discMetadata: DiscMetadata {
        DiscMetadata(
            artist: artist ?? "Unknown",
            album: title,
            year: year,
            genre: genre,
            tracks: tracks,
            source: DiscMetadata.MetadataSource(rawValue: provider) ?? .manual,
            providerID: id,
            overview: overview,
            artworkURL: artworkURL
        )
    }
}

enum MetadataProvider: String, Codable, CaseIterable {
    case musicBrainz
    case tmdb
    case none

    var displayName: String {
        switch self {
        case .musicBrainz: return "MusicBrainz + Cover Art Archive"
        case .tmdb: return "TMDB"
        case .none: return "Local/manual only"
        }
    }
}

final class MetadataService {
    static let audioProviderKey = "metadataAudioProvider"
    static let videoProviderKey = "metadataVideoProvider"
    static let tmdbTokenKey = "metadataTMDBReadAccessToken"

    private let mountService = MountService()
    private let session: URLSession
    private let defaults: UserDefaults
    private static let musicBrainzRequestLock = NSLock()
    private static var lastMusicBrainzRequestAt = Date.distantPast

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    var audioProvider: MetadataProvider {
        get { MetadataProvider(rawValue: defaults.string(forKey: Self.audioProviderKey) ?? "") ?? .musicBrainz }
        set { defaults.set(newValue.rawValue, forKey: Self.audioProviderKey) }
    }

    var videoProvider: MetadataProvider {
        get { MetadataProvider(rawValue: defaults.string(forKey: Self.videoProviderKey) ?? "") ?? .tmdb }
        set { defaults.set(newValue.rawValue, forKey: Self.videoProviderKey) }
    }

    var tmdbReadAccessToken: String {
        get { defaults.string(forKey: Self.tmdbTokenKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.tmdbTokenKey) }
    }

    var providerConfiguration: [String: Any] {
        [
            "audioProvider": audioProvider.rawValue,
            "videoProvider": videoProvider.rawValue,
            "tmdbConfigured": !tmdbReadAccessToken.isEmpty,
            "providers": MetadataProvider.allCases.map { ["id": $0.rawValue, "name": $0.displayName] }
        ]
    }

    func configure(audioProvider: String?, videoProvider: String?, tmdbToken: String?) {
        if let raw = audioProvider, let provider = MetadataProvider(rawValue: raw) { self.audioProvider = provider }
        if let raw = videoProvider, let provider = MetadataProvider(rawValue: raw) { self.videoProvider = provider }
        if let tmdbToken = tmdbToken { self.tmdbReadAccessToken = tmdbToken }
    }

    // MARK: - Automatic resolution

    func automaticMetadata(
        bsdName: String,
        discType: DiscType,
        volumeLabel: String?
    ) -> DiscMetadata? {
        switch discType {
        case .audioCDDA where audioProvider == .musicBrainz,
             .mixedModeCD where audioProvider == .musicBrainz:
            return musicBrainzCandidates(discID: musicBrainzDiscID(bsdName: bsdName)).first?.discMetadata
        case .dvd where videoProvider == .tmdb:
            guard !tmdbReadAccessToken.isEmpty,
                  let query = cleanedSearchTitle(volumeLabel), !query.isEmpty else { return nil }
            let candidates = tmdbCandidates(query: query)
            // DVD volume labels are noisy. Auto-apply only an exact normalized
            // title match; otherwise leave the candidates for user selection.
            return candidates.first(where: {
                normalizedTitle($0.title) == normalizedTitle(query)
            })?.discMetadata
        default:
            return nil
        }
    }

    func search(provider: MetadataProvider, query: String) -> [MetadataCandidate] {
        switch provider {
        case .musicBrainz: return musicBrainzCandidates(query: query)
        case .tmdb: return tmdbCandidates(query: query)
        case .none: return []
        }
    }

    // MARK: - MusicBrainz / Cover Art Archive

    private struct MusicBrainzResponse: Decodable {
        let releases: [Release]?

        struct Release: Decodable {
            let id: String
            let title: String
            let artistCredit: [ArtistCredit]?
            let date: String?
            let media: [Medium]?

            enum CodingKeys: String, CodingKey {
                case id, title, date, media
                case artistCredit = "artist-credit"
            }
        }

        struct ArtistCredit: Decodable { let name: String }
        struct Medium: Decodable { let tracks: [Track]? }
        struct Track: Decodable {
            let position: Int?
            let title: String?
            let length: Int?
            let recording: Recording?
        }
        struct Recording: Decodable { let title: String? }
    }

    func musicBrainzCandidates(discID: String?) -> [MetadataCandidate] {
        guard let discID = discID, !discID.isEmpty else { return [] }
        let path = "https://musicbrainz.org/ws/2/discid/\(discID)?fmt=json&inc=artists+recordings"
        return decodeMusicBrainz(path)
    }

    func musicBrainzCandidates(query: String) -> [MetadataCandidate] {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/release") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "inc", value: "artists+recordings")
        ]
        return decodeMusicBrainz(components.url?.absoluteString)
    }

    private func decodeMusicBrainz(_ urlString: String?) -> [MetadataCandidate] {
        guard let urlString = urlString, let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Discbot/1.0 (https://github.com/toml0006/discbot)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = musicBrainzRequestData(request),
              let response = try? JSONDecoder().decode(MusicBrainzResponse.self, from: data) else { return [] }
        return (response.releases ?? []).map { release in
            let tracks = release.media?.flatMap { $0.tracks ?? [] }.enumerated().map { index, track in
                DiscMetadata.TrackInfo(
                    number: track.position ?? index + 1,
                    title: track.recording?.title ?? track.title ?? "Track \(index + 1)",
                    duration: track.length.map { TimeInterval($0) / 1000 }
                )
            }
            return MetadataCandidate(
                id: release.id,
                provider: MetadataProvider.musicBrainz.rawValue,
                title: release.title,
                artist: release.artistCredit?.map(\.name).joined() ?? "Unknown Artist",
                year: release.date.map { String($0.prefix(4)) },
                genre: nil,
                overview: nil,
                artworkURL: "https://coverartarchive.org/release/\(release.id)/front-500",
                tracks: tracks?.isEmpty == false ? tracks : nil
            )
        }
    }

    // MARK: - TMDB

    private struct TMDBSearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let id: Int
            let mediaType: String?
            let title: String?
            let name: String?
            let releaseDate: String?
            let firstAirDate: String?
            let overview: String?
            let posterPath: String?

            enum CodingKeys: String, CodingKey {
                case id, title, name, overview
                case mediaType = "media_type"
                case releaseDate = "release_date"
                case firstAirDate = "first_air_date"
                case posterPath = "poster_path"
            }
        }
    }

    func tmdbCandidates(query: String) -> [MetadataCandidate] {
        let token = tmdbReadAccessToken
        guard !token.isEmpty,
              var components = URLComponents(string: "https://api.themoviedb.org/3/search/multi") else { return [] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "page", value: "1")
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = requestData(request),
              let response = try? JSONDecoder().decode(TMDBSearchResponse.self, from: data) else { return [] }
        return response.results.compactMap { value in
            guard value.mediaType == "movie" || value.mediaType == "tv",
                  let title = value.title ?? value.name else { return nil }
            let date = value.releaseDate ?? value.firstAirDate
            return MetadataCandidate(
                id: "\(value.mediaType ?? "movie"):\(value.id)",
                provider: MetadataProvider.tmdb.rawValue,
                title: title,
                artist: value.mediaType == "tv" ? "TV" : "Movie",
                year: date.map { String($0.prefix(4)) },
                genre: value.mediaType == "tv" ? "Television" : "Movie",
                overview: value.overview,
                artworkURL: value.posterPath.map { "https://image.tmdb.org/t/p/w500\($0)" },
                tracks: nil
            )
        }
    }

    // MARK: - Local fallback and sidecars

    func getVolumeLabel(bsdName: String) -> String? { mountService.getVolumeName(bsdName: bsdName) }

    func resolveMetadata(bsdName: String, slotNumber: Int) -> DiscMetadata {
        if let volumeLabel = getVolumeLabel(bsdName: bsdName), !volumeLabel.isEmpty {
            return DiscMetadata(artist: "Unknown", album: volumeLabel, year: nil, tracks: nil, source: .volumeLabel)
        }
        return DiscMetadata(
            artist: "Unknown",
            album: "Disc from Slot \(String(format: "%03d", slotNumber))",
            year: nil,
            tracks: nil,
            source: .slotNumber
        )
    }

    func writeSidecar(for disc: DiscRecord, ripURL: URL) throws {
        let sidecarURL = ripURL.deletingPathExtension().appendingPathExtension("metadata.json")
        var object: [String: Any] = [
            "schema": "discbot.metadata.v1",
            "fingerprint": disc.fingerprint,
            "userEdited": disc.metadataUserEdited,
            "writtenAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let value = disc.id { object["discId"] = value }
        if let value = disc.discType { object["discType"] = value }
        if let value = disc.album { object["title"] = value }
        if let value = disc.artist { object["artist"] = value }
        if let value = disc.year { object["year"] = value }
        if let value = disc.genre { object["genre"] = value }
        if let value = disc.metadataSource { object["provider"] = value }
        if let value = disc.metadataProviderID { object["providerId"] = value }
        if let value = disc.metadataOverview { object["overview"] = value }
        if let value = disc.artworkURL { object["artworkURL"] = value }
        if let tracks = disc.metadataTracks {
            object["tracks"] = tracks.map { track -> [String: Any] in
                var value: [String: Any] = ["number": track.number, "title": track.title]
                if let duration = track.duration { value["duration"] = duration }
                return value
            }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: sidecarURL, options: .atomic)

        if let rawURL = disc.artworkURL,
           let url = URL(string: rawURL),
           isApprovedArtworkURL(url) {
            let artworkURL = ripURL.deletingPathExtension().appendingPathExtension("cover.jpg")
            if let data = requestData(URLRequest(url: url)), !data.isEmpty {
                // Artwork is useful but optional; a CDN outage must not turn a
                // verified disc image into a failed rip.
                try? data.write(to: artworkURL, options: .atomic)
            }
        }
    }

    // MARK: - MusicBrainz disc ID

    func musicBrainzDiscID(bsdName: String) -> String? {
        guard let reader = try? NativeRawCDReader(bsdName: bsdName),
              let first = reader.layout.tracks.first,
              let last = reader.layout.tracks.last else { return nil }
        return calculateMusicBrainzDiscID(
            firstTrack: first.number,
            lastTrack: last.number,
            leadOutOffset: Int(reader.layout.leadoutLBA) + 150,
            trackOffsets: reader.layout.tracks.map { Int($0.startLBA) + 150 }
        )
    }

    func calculateMusicBrainzDiscID(firstTrack: Int, lastTrack: Int, leadOutOffset: Int, trackOffsets: [Int]) -> String {
        var data = String(format: "%02X%02X%08X", firstTrack, lastTrack, leadOutOffset)
        for i in 0..<99 { data += String(format: "%08X", i < trackOffsets.count ? trackOffsets[i] : 0) }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let bytes = Array(data.utf8)
        CC_SHA1(bytes, CC_LONG(bytes.count), &hash)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    private func requestData(_ request: URLRequest) -> Data? {
        var request = request
        request.timeoutInterval = 20
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { result = data }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return result
    }

    /// MusicBrainz asks clients to average no more than one request per second.
    /// Keep that guarantee even when several remote clients search concurrently.
    private func musicBrainzRequestData(_ request: URLRequest) -> Data? {
        Self.musicBrainzRequestLock.lock()
        defer { Self.musicBrainzRequestLock.unlock() }
        let elapsed = Date().timeIntervalSince(Self.lastMusicBrainzRequestAt)
        if elapsed < 1.05 { Thread.sleep(forTimeInterval: 1.05 - elapsed) }
        Self.lastMusicBrainzRequestAt = Date()
        return requestData(request)
    }

    private func cleanedSearchTitle(_ value: String?) -> String? {
        value?.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTitle(_ value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private func isApprovedArtworkURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "coverartarchive.org" || host == "image.tmdb.org"
    }
}
