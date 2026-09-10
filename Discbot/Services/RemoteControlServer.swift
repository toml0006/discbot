//
//  RemoteControlServer.swift
//  Discbot
//
//  Authenticated LAN control plane and embedded web client.
//

import Foundation
import Network

struct RemoteRipDestination: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var path: String
    var remoteURL: String?

    init(id: UUID = UUID(), name: String, path: String, remoteURL: String? = nil) {
        self.id = id
        self.name = name
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.remoteURL = remoteURL
    }

    var url: URL { URL(fileURLWithPath: path).standardizedFileURL }
    var location: String { remoteURL ?? path }
    var isRemote: Bool { remoteURL != nil }
    var isAvailable: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue
            && FileManager.default.isWritableFile(atPath: path)
    }
}

enum RemoteDestinationError: LocalizedError {
    case invalidURL(String)
    case credentialsRequired
    case mountFailed(Int32)
    case unavailableFolder(String)
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let reason): return "Invalid SMB location: \(reason)"
        case .credentialsRequired:
            return "The SMB share could not authenticate without prompting. Connect to it once in Finder, save the password in Keychain, then retry."
        case .mountFailed(let status):
            if status > 0, let message = String(validatingUTF8: strerror(status)) {
                return "The SMB share could not be mounted: \(message)"
            }
            return "The SMB share could not be mounted (NetFS error \(status))."
        case .unavailableFolder(let path): return "The remote folder is unavailable: \(path)"
        case .notWritable(let path): return "The remote folder is not writable: \(path)"
        }
    }
}

final class RemoteDestinationResolver {
    typealias ShareMounter = (URL) throws -> URL

    private let mountShare: ShareMounter

    init(mountShare: @escaping ShareMounter = RemoteDestinationResolver.mountUsingNetFS) {
        self.mountShare = mountShare
    }

    func resolve(
        location rawLocation: String,
        name requestedName: String,
        id: UUID = UUID()
    ) throws -> RemoteRipDestination {
        let parsed = try Self.parseSMBLocation(rawLocation)
        let mountRoot = try mountShare(parsed.shareURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let target = parsed.subpath.reduce(mountRoot) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.standardizedFileURL

        do {
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw RemoteDestinationError.unavailableFolder(target.path)
        }
        try Self.verifyWritable(target)

        let trimmedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? parsed.defaultName : trimmedName
        return RemoteRipDestination(
            id: id,
            name: name,
            path: target.path,
            remoteURL: parsed.sanitizedURL
        )
    }

    private struct ParsedSMBLocation {
        let sanitizedURL: String
        let shareURL: URL
        let subpath: [String]
        let defaultName: String
    }

    private static func parseSMBLocation(_ raw: String) throws -> ParsedSMBLocation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "smb",
              let host = components.host,
              !host.isEmpty else {
            throw RemoteDestinationError.invalidURL("use smb://server/share/folder")
        }
        guard components.password == nil else {
            throw RemoteDestinationError.invalidURL("do not put a password in the URL; save it in the Mac Keychain")
        }
        let pathParts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let encodedShare = pathParts.first,
              let share = encodedShare.removingPercentEncoding,
              !share.isEmpty else {
            throw RemoteDestinationError.invalidURL("include a share name after the server")
        }
        let decodedSubpath = try pathParts.dropFirst().map { part -> String in
            guard let decoded = part.removingPercentEncoding,
                  !decoded.isEmpty,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/") else {
                throw RemoteDestinationError.invalidURL("the folder path contains an invalid component")
            }
            return decoded
        }

        components.scheme = "smb"
        components.query = nil
        components.fragment = nil
        components.percentEncodedPath = "/" + pathParts.joined(separator: "/")
        guard let sanitized = components.url?.absoluteString else {
            throw RemoteDestinationError.invalidURL("the URL could not be normalized")
        }

        var shareComponents = components
        shareComponents.percentEncodedPath = "/" + encodedShare
        guard let shareURL = shareComponents.url else {
            throw RemoteDestinationError.invalidURL("the share URL could not be created")
        }
        return ParsedSMBLocation(
            sanitizedURL: sanitized,
            shareURL: shareURL,
            subpath: decodedSubpath,
            defaultName: decodedSubpath.last ?? share
        )
    }

    private static func verifyWritable(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw RemoteDestinationError.unavailableFolder(url.path)
        }
        let probe = url.appendingPathComponent(".discbot-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw RemoteDestinationError.notWritable(url.path)
        }
    }

    static func mountUsingNetFS(_ shareURL: URL) throws -> URL {
        var status: Int32 = 0
        guard let pointer = mount_network_share(shareURL.absoluteString, &status) else {
            if status == -6600 || status == 13 || status == 80 {
                throw RemoteDestinationError.credentialsRequired
            }
            throw RemoteDestinationError.mountFailed(status)
        }
        defer { free(UnsafeMutableRawPointer(mutating: pointer)) }
        let path = String(cString: pointer)
        guard !path.isEmpty else { throw RemoteDestinationError.mountFailed(EIO) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

struct RemoteAPIError: LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? { message }
}

enum RemoteSlotAction: String {
    case load
    case mount
    case unmount
}

protocol RemoteControlProviding: AnyObject {
    func remoteState() -> [String: Any]
    func remoteLibrary() -> [String: Any]
    func artworkData(discId: Int64) -> Data?
    func startRemoteRip(slots: [Int], destination: RemoteRipDestination, policy: DuplicatePolicy, outputMode: RipOutputMode) -> Result<String, RemoteAPIError>
    func startRemoteScanUnknown() -> Result<String, RemoteAPIError>
    func cancelRemoteCurrentDisc(id: String?) -> Result<Void, RemoteAPIError>
    func cancelRemoteJob(id: String?) -> Result<Void, RemoteAPIError>
    func refreshRemoteInventory() -> Result<Void, RemoteAPIError>
    func rescanRemoteInventory() -> Result<Void, RemoteAPIError>
    func returnLoadedDisc() -> Result<Void, RemoteAPIError>
    func performRemoteSlotAction(slot: Int, action: RemoteSlotAction) -> Result<Void, RemoteAPIError>
    func startRemoteCarouselLoad(count: Int?, slots: [Int]?) -> Result<String, RemoteAPIError>
    func startRemoteCarouselUnload(slots: [Int]?) -> Result<String, RemoteAPIError>
    func controlRemoteCarousel(id: String?, action: CarouselBatchAction) -> Result<Void, RemoteAPIError>
    func metadataConfiguration() -> [String: Any]
    func configureMetadata(audioProvider: String?, videoProvider: String?, tmdbToken: String?)
    func searchMetadata(provider: MetadataProvider, query: String) -> [MetadataCandidate]
    func updateMetadata(discId: Int64, metadata: DiscMetadata) -> Result<Void, RemoteAPIError>
}

/// Database writes invalidate immediately; expiry also discovers externally
/// removed images or disconnected shares without rescanning on every SSE tick.
final class RemoteLibraryCache {
    private let lock = NSLock()
    private var cached: (revision: Int, at: Date, value: [String: Any])?

    func value(revision: Int, now: Date = Date(), build: () -> [String: Any]) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cached, cached.revision == revision,
           now.timeIntervalSince(cached.at) < 60 {
            return cached.value
        }
        let value = build()
        cached = (revision, now, value)
        return value
    }
}

final class ChangerRemoteControlAdapter: RemoteControlProviding {
    private weak var viewModel: ChangerViewModel?
    private var activeJobId: String?
    private let libraryCache = RemoteLibraryCache()

    init(viewModel: ChangerViewModel) {
        self.viewModel = viewModel
    }

    func remoteState() -> [String: Any] {
        onMain {
            guard let viewModel = self.viewModel else { return ["available": false] }
            let slots: [[String: Any]] = viewModel.slots.map { slot in
                var value: [String: Any] = [
                    "id": slot.id,
                    "full": slot.isFull,
                    "inDrive": slot.isInDrive,
                    "exception": slot.hasException,
                    "discType": slot.discType.label,
                    "backupStatus": self.backupStatus(slot.backupStatus)
                ]
                value["actions"] = self.availableActions(for: slot, viewModel: viewModel)
                if let label = slot.volumeLabel { value["label"] = label }
                return value
            }
            var result: [String: Any] = [
                "available": true,
                "connected": viewModel.isConnected,
                "connection": self.connectionState(viewModel),
                "device": viewModel.deviceDescription,
                "busy": viewModel.isHardwareBusy,
                "hasIESlot": viewModel.hasIESlot,
                "dvdVideoSupport": DVDVideoImagingService().isAvailable,
                "fullSlots": viewModel.fullSlotCount,
                "emptySlots": viewModel.emptySlotCount,
                "unknownSlots": viewModel.slots.filter(\.hasException).count,
                "slots": slots,
                "drive": self.driveState(viewModel.driveStatus)
            ]
            if let notice = viewModel.operationNotice {
                result["notice"] = notice
            }
            if viewModel.currentOperation != nil,
               viewModel.batchState?.isRunning != true {
                result["operation"] = [
                    "status": viewModel.operationStatusText.isEmpty
                        ? "Changer operation in progress…"
                        : viewModel.operationStatusText
                ]
            }
            if let error = viewModel.connectionError?.localizedDescription {
                result["error"] = error
            }
            if let batch = viewModel.batchState {
                result["job"] = self.batchState(batch, id: self.activeJobId)
            }
            if let carousel = viewModel.carouselBatchSnapshot {
                result["carouselJob"] = self.carouselState(carousel)
            }
            if let recoverySlot = ChangerViewModel.checkDirtyFlag() {
                result["recovery"] = [
                    "needed": true,
                    "slot": recoverySlot,
                    "canReturn": viewModel.isConnected && !viewModel.isHardwareBusy
                ]
            }
            return result
        }
    }

    func remoteLibrary() -> [String: Any] {
        guard let viewModel = viewModel else { return ["entries": [], "activity": []] }
        return libraryCache.value(revision: viewModel.catalogService.revision) {
            self.buildLibrary(catalog: viewModel.catalogService)
        }
    }

    private func buildLibrary(catalog: CatalogService) -> [String: Any] {
        let catalogEntries = catalog.getCatalogEntries()
        let statistics = catalog.getStatistics(entries: catalogEntries)
        let entries = catalogEntries.map { entry -> [String: Any] in
            let existingRips = entry.existingRips
            var value: [String: Any] = [
                "id": entry.id,
                "name": entry.disc.displayName,
                "fingerprint": entry.disc.fingerprint,
                "identityReliable": entry.disc.hasReliableIdentity,
                "sightings": entry.sightings.count,
                "ripAttempts": entry.rips.count,
                "availableImages": existingRips.count
            ]
            if let type = entry.disc.discType { value["discType"] = type }
            if let path = existingRips.first?.backupPath { value["latestPath"] = path }
            if let artist = entry.disc.artist { value["artist"] = artist }
            if let year = entry.disc.year { value["year"] = year }
            if let genre = entry.disc.genre { value["genre"] = genre }
            if let provider = entry.disc.metadataSource { value["metadataSource"] = provider }
            if let providerID = entry.disc.metadataProviderID { value["metadataProviderId"] = providerID }
            if let overview = entry.disc.metadataOverview { value["overview"] = overview }
            if let artworkURL = entry.disc.artworkURL { value["artworkURL"] = artworkURL }
            value["artworkAvailable"] = entry.disc.artworkPath != nil || entry.disc.artworkURL != nil
            value["metadataUserEdited"] = entry.disc.metadataUserEdited
            return value
        }
        let activity = catalog.getRecentRipLog(limit: 100).map { event -> [String: Any] in
            var value: [String: Any] = [
                "id": event.id ?? -1,
                "type": event.eventType,
                "message": event.message,
                "at": event.eventAt
            ]
            if let slot = event.slotId { value["slot"] = slot }
            return value
        }
        return [
            "statistics": [
                "discs": statistics.totalDiscs,
                "sightings": statistics.totalSightings,
                "attempts": statistics.ripAttempts,
                "completed": statistics.completedRips,
                "failed": statistics.failedRips,
                "cancelled": statistics.cancelledRips,
                "skipped": statistics.skippedRips,
                "replaced": statistics.replacedRips,
                "availableImages": statistics.availableImages,
                "storedBytes": statistics.storedBytes
            ],
            "entries": entries,
            "activity": activity
        ]
    }

    func artworkData(discId: Int64) -> Data? {
        viewModel?.catalogService.artworkData(discId: discId)
    }

    func startRemoteRip(
        slots: [Int],
        destination: RemoteRipDestination,
        policy: DuplicatePolicy,
        outputMode: RipOutputMode
    ) -> Result<String, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard viewModel.isConnected else {
                return .failure(RemoteAPIError(status: 503, message: "The changer is not connected"))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is already running"))
            }
            guard destination.isAvailable else {
                return .failure(RemoteAPIError(status: 409, message: "The selected destination is unavailable or read-only"))
            }
            let requested = Set(slots)
            let valid = Set(viewModel.rippableSlots.map(\.id)).intersection(requested)
            guard !requested.isEmpty, valid == requested else {
                return .failure(RemoteAPIError(status: 422, message: "One or more requested slots cannot be ripped"))
            }

            viewModel.selectedSlotsForRip = valid
            viewModel.startBatchImaging(
                outputDirectory: destination.url,
                duplicatePolicy: policy,
                outputMode: outputMode
            )
            guard viewModel.currentOperation == .batchImaging else {
                return .failure(RemoteAPIError(status: 500, message: "The rip queue did not start"))
            }
            let id = UUID().uuidString
            self.activeJobId = id
            return .success(id)
        }
    }

    func startRemoteScanUnknown() -> Result<String, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard viewModel.isConnected else {
                return .failure(RemoteAPIError(status: 503, message: "The changer is not connected"))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is already running"))
            }
            guard viewModel.slots.contains(where: {
                $0.isFull && !$0.isInDrive && $0.discType == .unscanned
            }) else {
                return .failure(RemoteAPIError(status: 409, message: "There are no unknown discs to scan"))
            }

            viewModel.scanInventory()
            guard viewModel.currentOperation == .batchScanning,
                  viewModel.batchState?.isRunning == true else {
                return .failure(RemoteAPIError(status: 500, message: "The disc scan did not start"))
            }
            let id = UUID().uuidString
            self.activeJobId = id
            return .success(id)
        }
    }

    func cancelRemoteJob(id: String?) -> Result<Void, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel,
                  viewModel.batchState?.isRunning == true else {
                return .failure(RemoteAPIError(status: 404, message: "No batch job is running"))
            }
            if let id = id, let active = self.activeJobId, id != active {
                return .failure(RemoteAPIError(status: 404, message: "That job is not active"))
            }
            viewModel.batchState?.cancel()
            return .success(())
        }
    }

    func cancelRemoteCurrentDisc(id: String?) -> Result<Void, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel,
                  let batch = viewModel.batchState,
                  batch.isRunning else {
                return .failure(RemoteAPIError(status: 404, message: "No batch job is running"))
            }
            if let id = id, let active = self.activeJobId, id != active {
                return .failure(RemoteAPIError(status: 404, message: "That job is not active"))
            }
            guard batch.cancelCurrentDisc() else {
                return .failure(RemoteAPIError(
                    status: 409,
                    message: "The current disc is not in an interruptible ripping phase"
                ))
            }
            return .success(())
        }
    }

    func refreshRemoteInventory() -> Result<Void, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is running"))
            }
            if viewModel.isConnected {
                viewModel.refreshInventory()
            } else {
                // The same button doubles as an explicit retry after the
                // automatic retry budget has been exhausted.
                viewModel.connect()
            }
            return .success(())
        }
    }

    func rescanRemoteInventory() -> Result<Void, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard viewModel.isConnected else {
                return .failure(RemoteAPIError(status: 503, message: "The changer is not connected"))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is running"))
            }
            viewModel.rescanElementStatus()
            return .success(())
        }
    }

    func returnLoadedDisc() -> Result<Void, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard viewModel.isConnected else {
                return .failure(RemoteAPIError(
                    status: 503,
                    message: "Reconnect the changer before returning the loaded disc"
                ))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is running"))
            }
            guard case .loaded(let sourceSlot, _) = viewModel.driveStatus, sourceSlot > 0 else {
                return .failure(RemoteAPIError(status: 409, message: "No recoverable disc is loaded"))
            }
            viewModel.ejectDisc(toSlot: sourceSlot)
            return .success(())
        }
    }

    func performRemoteSlotAction(
        slot slotNumber: Int,
        action: RemoteSlotAction
    ) -> Result<Void, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard viewModel.isConnected else {
                return .failure(RemoteAPIError(status: 503, message: "The changer is not connected"))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is running"))
            }
            guard slotNumber >= 1, slotNumber <= viewModel.slots.count else {
                return .failure(RemoteAPIError(status: 422, message: "That slot does not exist"))
            }

            let slot = viewModel.slots[slotNumber - 1]
            switch action {
            case .load:
                guard slot.isFull, !slot.isInDrive else {
                    return .failure(RemoteAPIError(status: 409, message: "Slot \(slotNumber) is not available to load"))
                }
                guard viewModel.driveStatus == .empty else {
                    return .failure(RemoteAPIError(status: 409, message: "Return the current drive disc first"))
                }
                viewModel.loadSlot(slotNumber)

            case .mount:
                guard case .loaded(let sourceSlot, nil) = viewModel.driveStatus,
                      sourceSlot == slotNumber || slot.isInDrive else {
                    return .failure(RemoteAPIError(status: 409, message: "Slot \(slotNumber) is not an unmounted disc in the drive"))
                }
                viewModel.mountDisc()

            case .unmount:
                guard case .loaded(let sourceSlot, let mountPoint) = viewModel.driveStatus,
                      mountPoint != nil,
                      sourceSlot == slotNumber || slot.isInDrive else {
                    return .failure(RemoteAPIError(status: 409, message: "Slot \(slotNumber) is not a mounted disc in the drive"))
                }
                viewModel.unmountDisc()
            }
            return .success(())
        }
    }

    func startRemoteCarouselLoad(count: Int?, slots requestedSlots: [Int]?) -> Result<String, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard viewModel.isConnected else {
                return .failure(RemoteAPIError(status: 503, message: "The changer is not connected"))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is running"))
            }
            guard viewModel.hasIESlot else {
                return .failure(RemoteAPIError(status: 409, message: "This changer reports no loading gate"))
            }
            guard viewModel.driveStatus == .empty else {
                return .failure(RemoteAPIError(status: 409, message: "Return the optical-drive disc before bulk loading"))
            }

            let empty = viewModel.slots.filter {
                !$0.isFull && !$0.isInDrive && !$0.hasException
            }.map(\.id)
            let targets: [Int]
            if let requested = requestedSlots, !requested.isEmpty {
                let unique = Array(Set(requested)).sorted()
                guard unique.count == requested.count, Set(unique).isSubset(of: Set(empty)) else {
                    return .failure(RemoteAPIError(status: 422, message: "Every requested load slot must be unique and empty"))
                }
                targets = unique
            } else {
                guard let count = count, count > 0, count <= empty.count else {
                    return .failure(RemoteAPIError(status: 422, message: "Choose between 1 and \(empty.count) discs"))
                }
                targets = Array(empty.prefix(count))
            }
            guard viewModel.startCarouselLoad(targetSlots: targets),
                  let id = viewModel.carouselBatchSnapshot?.id else {
                return .failure(RemoteAPIError(status: 500, message: "The bulk-load queue did not start"))
            }
            return .success(id)
        }
    }

    func startRemoteCarouselUnload(slots requestedSlots: [Int]?) -> Result<String, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel else {
                return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
            }
            guard viewModel.isConnected else {
                return .failure(RemoteAPIError(status: 503, message: "The changer is not connected"))
            }
            guard !viewModel.isHardwareBusy else {
                return .failure(RemoteAPIError(status: 409, message: "Another changer operation is running"))
            }
            guard viewModel.hasIESlot else {
                return .failure(RemoteAPIError(status: 409, message: "This changer reports no unloading gate"))
            }
            guard viewModel.driveStatus == .empty else {
                return .failure(RemoteAPIError(status: 409, message: "Return the optical-drive disc before bulk unloading"))
            }

            let occupied = viewModel.slots.filter { $0.isFull && !$0.isInDrive }.map(\.id)
            let targets: [Int]
            if let requested = requestedSlots, !requested.isEmpty {
                let unique = Array(Set(requested)).sorted()
                guard unique.count == requested.count, Set(unique).isSubset(of: Set(occupied)) else {
                    return .failure(RemoteAPIError(status: 422, message: "Every requested unload slot must be unique and occupied"))
                }
                targets = unique
            } else {
                targets = occupied
            }
            guard !targets.isEmpty else {
                return .failure(RemoteAPIError(status: 422, message: "There are no carousel discs to unload"))
            }
            guard viewModel.startCarouselUnload(targetSlots: targets),
                  let id = viewModel.carouselBatchSnapshot?.id else {
                return .failure(RemoteAPIError(status: 500, message: "The bulk-unload queue did not start"))
            }
            return .success(id)
        }
    }

    func controlRemoteCarousel(id: String?, action: CarouselBatchAction) -> Result<Void, RemoteAPIError> {
        onMain {
            guard let viewModel = self.viewModel,
                  let snapshot = viewModel.carouselBatchSnapshot,
                  snapshot.running else {
                return .failure(RemoteAPIError(status: 404, message: "No carousel operation is running"))
            }
            if let id = id, id != snapshot.id {
                return .failure(RemoteAPIError(status: 404, message: "That carousel operation is not active"))
            }
            guard viewModel.controlCarouselBatch(action) else {
                return .failure(RemoteAPIError(status: 409, message: "That action is not available right now"))
            }
            return .success(())
        }
    }

    func metadataConfiguration() -> [String: Any] {
        viewModel?.catalogService.metadataConfiguration() ?? [:]
    }

    func configureMetadata(audioProvider: String?, videoProvider: String?, tmdbToken: String?) {
        viewModel?.catalogService.configureMetadata(
            audioProvider: audioProvider,
            videoProvider: videoProvider,
            tmdbToken: tmdbToken
        )
    }

    func searchMetadata(provider: MetadataProvider, query: String) -> [MetadataCandidate] {
        viewModel?.catalogService.searchMetadata(provider: provider, query: query) ?? []
    }

    func updateMetadata(discId: Int64, metadata: DiscMetadata) -> Result<Void, RemoteAPIError> {
        guard let catalog = viewModel?.catalogService else {
            return .failure(RemoteAPIError(status: 503, message: "Discbot is unavailable"))
        }
        guard catalog.updateMetadata(discId: discId, metadata: metadata) != nil else {
            return .failure(RemoteAPIError(status: 404, message: "Disc not found"))
        }
        return .success(())
    }

    private func connectionState(_ viewModel: ChangerViewModel) -> [String: Any] {
        var state: [String: Any] = [
            "status": viewModel.connectionHealth.rawValue,
            "label": viewModel.connectionHealth.label,
            "retryAttempt": viewModel.reconnectAttempt,
            "requiresPowerCycle": viewModel.connectionHealth.requiresPowerCycle
        ]
        if let date = viewModel.nextReconnectAt {
            state["nextRetryAt"] = ISO8601DateFormatter().string(from: date)
            state["retryInSeconds"] = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        }
        return state
    }

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    private func backupStatus(_ status: BackupStatus) -> String {
        switch status {
        case .notBackedUp: return "notRipped"
        case .backedUp: return "ripped"
        case .failed: return "failed"
        }
    }

    private func availableActions(for slot: Slot, viewModel: ChangerViewModel) -> [String] {
        guard viewModel.isConnected, !viewModel.isHardwareBusy else { return [] }

        var actions: [String] = []
        if slot.isFull, !slot.isInDrive, viewModel.driveStatus == .empty {
            actions.append(RemoteSlotAction.load.rawValue)
            if viewModel.hasIESlot { actions.append("eject") }
        }
        if case .loaded(let sourceSlot, let mountPoint) = viewModel.driveStatus,
           sourceSlot == slot.id || slot.isInDrive {
            actions.append(mountPoint == nil
                ? RemoteSlotAction.mount.rawValue
                : RemoteSlotAction.unmount.rawValue)
        }
        return actions
    }

    private func driveState(_ status: DriveStatus) -> [String: Any] {
        switch status {
        case .empty: return ["state": "empty"]
        case .loading(let slot): return ["state": "loading", "slot": slot]
        case .loaded(let slot, let mount):
            var value: [String: Any] = ["state": "loaded", "slot": slot]
            if let mount = mount { value["mountPoint"] = mount }
            return value
        case .ejecting(let slot): return ["state": "ejecting", "slot": slot]
        case .error(let message): return ["state": "error", "message": message]
        }
    }

    private func batchState(_ state: BatchOperationState, id: String?) -> [String: Any] {
        let kind: String
        switch state.operationType {
        case .scanUnknown: kind = "scan"
        case .imageAll: kind = "rip"
        case .loadAll: kind = "load"
        case .none: kind = "unknown"
        }
        var value: [String: Any] = [
            "kind": kind,
            "running": state.isRunning,
            "cancelled": state.isCancelled,
            "paused": state.isPaused,
            "current": state.currentIndex,
            "total": state.totalCount,
            "slot": state.currentSlot,
            "progress": state.progress,
            "overallProgress": state.progress,
            "position": state.isRunning ? min(state.currentIndex + 1, state.totalCount) : state.currentIndex,
            "currentDiscProgress": state.imagingProgress,
            "currentDiscTransferredBytes": state.currentDiscTransferredBytes,
            "currentDiscSpeedBytesPerSecond": state.currentDiscSpeedBytesPerSecond,
            "canCancelCurrentDisc": state.canCancelCurrentDisc,
            "finalizingDiscCount": state.finalizingDiscCount,
            "status": state.statusText,
            "completedSlots": state.completedSlots,
            "replacedSlots": state.replacedSlots,
            "cancelledSlots": state.cancelledSlots,
            "failedSlots": state.failedSlots.map { ["slot": $0.slot, "error": $0.error] },
            "skippedSlots": state.skippedSlots.map { ["slot": $0.slot, "path": $0.existingPath] }
        ]
        if let id = id { value["id"] = id }
        if let name = state.currentDiscName { value["disc"] = name }
        if let total = state.currentDiscTotalBytes { value["currentDiscTotalBytes"] = total }
        if let eta = state.currentDiscETASeconds { value["currentDiscETASeconds"] = eta }
        if let total = state.overallEstimatedTotalBytes { value["overallEstimatedTotalBytes"] = total }
        if let eta = state.overallETASeconds { value["overallETASeconds"] = eta }
        if let halt = state.haltReason { value["haltReason"] = halt }
        return value
    }

    private func carouselState(_ state: CarouselBatchSnapshot) -> [String: Any] {
        var value: [String: Any] = [
            "id": state.id,
            "mode": state.mode.rawValue,
            "running": state.running,
            "cancelled": state.cancelled,
            "awaitingAction": state.awaitingAction,
            "allowedActions": state.allowedActions.map(\.rawValue),
            "current": state.currentIndex,
            "total": state.total,
            "completedSlots": state.completedSlots,
            "skippedSlots": state.skippedSlots,
            "failures": state.failures.map { ["slot": $0.slot, "error": $0.message] },
            "progress": state.progress,
            "status": state.status
        ]
        if let slot = state.currentSlot { value["slot"] = slot }
        return value
    }
}

struct RemoteHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum Framing: Equatable {
        case incomplete
        case ready(Int)
        case rejected(Int)
    }

    static func framing(_ data: Data) -> Framing {
        let maximumSize = 1024 * 1024
        guard data.count <= maximumSize else { return .rejected(413) }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .rejected(413) : .incomplete
        }
        guard separator.upperBound <= 64 * 1024 else { return .rejected(413) }
        guard let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return .rejected(400)
        }
        var contentLength: Int?
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(400) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            // This server accepts fixed-length request bodies only.
            if key == "transfer-encoding" { return .rejected(400) }
            guard key == "content-length" else { continue }
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard contentLength == nil, !raw.isEmpty,
                  raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let length = Int(raw) else { return .rejected(400) }
            // Check before adding, so Int.max cannot overflow the frame size.
            guard length <= maximumSize - separator.upperBound else { return .rejected(413) }
            contentLength = length
        }
        let expected = separator.upperBound + (contentLength ?? 0)
        return data.count >= expected ? .ready(expected) : .incomplete
    }

    static func parse(_ data: Data) -> RemoteHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        let bodyStart = range.upperBound
        return RemoteHTTPRequest(
            method: String(parts[0]).uppercased(),
            path: String(parts[1]).components(separatedBy: "?").first ?? "/",
            headers: headers,
            body: Data(data[bodyStart...])
        )
    }
}

struct RemoteHTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(status: Int = 200, _ object: Any) -> RemoteHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return RemoteHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }
}

final class RemoteAPIController {
    private let control: RemoteControlProviding
    private let token: () -> String
    private let destinations: () -> [RemoteRipDestination]
    private let updateDestinations: ([RemoteRipDestination]) -> Void
    private let destinationRoots: () -> [URL]
    private let remoteDestinationResolver: RemoteDestinationResolver

    init(
        control: RemoteControlProviding,
        token: @escaping () -> String,
        destinations: @escaping () -> [RemoteRipDestination],
        updateDestinations: @escaping ([RemoteRipDestination]) -> Void,
        destinationRoots: @escaping () -> [URL] = {
            [FileManager.default.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Volumes", isDirectory: true)]
        },
        remoteDestinationResolver: RemoteDestinationResolver = RemoteDestinationResolver()
    ) {
        self.control = control
        self.token = { Thread.isMainThread ? token() : DispatchQueue.main.sync(execute: token) }
        self.destinations = { Thread.isMainThread ? destinations() : DispatchQueue.main.sync(execute: destinations) }
        self.updateDestinations = updateDestinations
        self.destinationRoots = destinationRoots
        self.remoteDestinationResolver = remoteDestinationResolver
    }

    func response(to request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        if request.method == "GET" && request.path == "/" {
            return RemoteHTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(RemoteWebClient.html.utf8))
        }
        if request.method == "GET" && request.path == "/api/v1/health" {
            return .json(["ok": true, "service": "discbot", "version": 1])
        }
        guard isAuthorized(request) else {
            return .json(status: 401, ["error": "Invalid or missing bearer token"])
        }

        if request.method == "GET", request.path.hasPrefix("/api/v1/library/artwork/") {
            let rawID = request.path.dropFirst("/api/v1/library/artwork/".count)
            guard let id = Int64(rawID), id > 0 else {
                return .json(status: 400, ["error": "Invalid disc ID"])
            }
            guard let data = control.artworkData(discId: id), !data.isEmpty else {
                return .json(status: 404, ["error": "No artwork is stored for this disc"])
            }
            return RemoteHTTPResponse(status: 200, contentType: "image/jpeg", body: data)
        }

        switch (request.method, request.path) {
        case ("GET", "/api/v1/state"):
            return .json(stateSnapshot())
        case ("GET", "/api/v1/library"):
            return .json(librarySnapshot())
        case ("GET", "/api/v1/destinations"):
            return .json(["destinations": destinationDetails()])
        case ("GET", "/api/v1/metadata/config"):
            return .json(control.metadataConfiguration())
        case ("POST", "/api/v1/metadata/config"):
            return configureMetadata(request)
        case ("POST", "/api/v1/metadata/search"):
            return searchMetadata(request)
        case ("POST", "/api/v1/metadata/update"):
            return updateMetadata(request)
        case ("POST", "/api/v1/destinations"):
            return addDestination(request)
        case ("POST", "/api/v1/destinations/connect"):
            return connectDestination(request)
        case ("POST", "/api/v1/destinations/remove"):
            return removeDestination(request)
        case ("POST", "/api/v1/inventory/refresh"):
            return result(control.refreshRemoteInventory()) { .json(status: 202, ["accepted": true]) }
        case ("POST", "/api/v1/inventory/rescan"):
            return result(control.rescanRemoteInventory()) { .json(status: 202, ["accepted": true]) }
        case ("POST", "/api/v1/recovery/return-disc"):
            return result(control.returnLoadedDisc()) { .json(status: 202, ["accepted": true]) }
        case ("POST", "/api/v1/slots/action"):
            return performSlotAction(request)
        case ("POST", "/api/v1/carousel/load"):
            return startCarouselLoad(request)
        case ("POST", "/api/v1/carousel/unload"):
            return startCarouselUnload(request)
        case ("POST", "/api/v1/carousel/action"):
            return controlCarousel(request)
        case ("POST", "/api/v1/jobs/rip"):
            return startRip(request)
        case ("POST", "/api/v1/jobs/scan"):
            return result(control.startRemoteScanUnknown()) {
                .json(status: 202, ["accepted": true, "jobId": $0])
            }
        case ("POST", "/api/v1/jobs/cancel-current"):
            let object = jsonObject(request.body)
            let id = object?["id"] as? String
            return result(control.cancelRemoteCurrentDisc(id: id)) { .json(status: 202, ["accepted": true]) }
        case ("POST", "/api/v1/jobs/cancel"):
            let object = jsonObject(request.body)
            let id = object?["id"] as? String
            return result(control.cancelRemoteJob(id: id)) { .json(status: 202, ["accepted": true]) }
        default:
            return .json(status: 404, ["error": "Not found"])
        }
    }

    func stateSnapshot() -> [String: Any] {
        var state = control.remoteState()
        state["destinations"] = destinations().map {
            [
                "id": $0.id.uuidString,
                "name": $0.name,
                "available": $0.isAvailable,
                "kind": $0.isRemote ? "smb" : "local"
            ]
        }
        return state
    }

    func librarySnapshot() -> [String: Any] {
        control.remoteLibrary()
    }

    private func destinationDetails() -> [[String: Any]] {
        destinations().map { destination in
            var value: [String: Any] = [
                "id": destination.id.uuidString,
                "name": destination.name,
                "path": destination.path,
                "location": destination.location,
                "kind": destination.isRemote ? "smb" : "local",
                "available": destination.isAvailable
            ]
            if let remoteURL = destination.remoteURL { value["remoteURL"] = remoteURL }
            return value
        }
    }

    func eventSnapshotData() -> Data? {
        try? JSONSerialization.data(
            withJSONObject: ["state": stateSnapshot(), "library": librarySnapshot()],
            options: [.sortedKeys]
        )
    }

    func stateEventData() -> Data? {
        try? JSONSerialization.data(withJSONObject: ["state": stateSnapshot()], options: [.sortedKeys])
    }

    func libraryEventData() -> Data? {
        try? JSONSerialization.data(withJSONObject: ["library": librarySnapshot()], options: [.sortedKeys])
    }

    private func startRip(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let rawSlots = object["slots"] as? [Any],
              let destinationId = object["destinationId"] as? String,
              let uuid = UUID(uuidString: destinationId),
              var destination = destinations().first(where: { $0.id == uuid }) else {
            return .json(status: 422, ["error": "slots and a configured destinationId are required"])
        }
        if !destination.isAvailable, destination.isRemote {
            do {
                destination = try reconnect(destination)
            } catch {
                return .json(status: 409, ["error": error.localizedDescription])
            }
        }
        let slots = rawSlots.compactMap { ($0 as? NSNumber)?.intValue }
        guard slots.count == rawSlots.count else {
            return .json(status: 422, ["error": "Every slot must be an integer"])
        }
        let rawPolicy = object["duplicatePolicy"] as? String ?? DuplicatePolicy.skipExisting.rawValue
        guard let policy = DuplicatePolicy(rawValue: rawPolicy) else {
            return .json(status: 422, ["error": "Unknown duplicate policy"])
        }
        let rawOutputMode = object["outputMode"] as? String ?? RipOutputMode.automatic.rawValue
        guard let outputMode = RipOutputMode(rawValue: rawOutputMode) else {
            return .json(status: 422, ["error": "Unknown rip output mode"])
        }
        return result(control.startRemoteRip(
            slots: slots,
            destination: destination,
            policy: policy,
            outputMode: outputMode
        )) {
            .json(status: 202, ["accepted": true, "jobId": $0])
        }
    }

    private func startCarouselLoad(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        let object = jsonObject(request.body) ?? [:]
        let count = (object["count"] as? NSNumber)?.intValue
        let slots: [Int]?
        if let raw = object["slots"] as? [Any] {
            let parsed = raw.compactMap { ($0 as? NSNumber)?.intValue }
            guard parsed.count == raw.count else {
                return .json(status: 422, ["error": "Every slot must be an integer"])
            }
            slots = parsed
        } else {
            slots = nil
        }
        return result(control.startRemoteCarouselLoad(count: count, slots: slots)) {
            .json(status: 202, ["accepted": true, "operationId": $0])
        }
    }

    private func performSlotAction(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let slot = (object["slot"] as? NSNumber)?.intValue,
              let rawAction = object["action"] as? String,
              let action = RemoteSlotAction(rawValue: rawAction) else {
            return .json(status: 422, ["error": "A slot and valid action are required"])
        }
        return result(control.performRemoteSlotAction(slot: slot, action: action)) {
            .json(status: 202, ["accepted": true])
        }
    }

    private func startCarouselUnload(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        let object = jsonObject(request.body) ?? [:]
        let slots: [Int]?
        if let raw = object["slots"] as? [Any] {
            let parsed = raw.compactMap { ($0 as? NSNumber)?.intValue }
            guard parsed.count == raw.count else {
                return .json(status: 422, ["error": "Every slot must be an integer"])
            }
            slots = parsed
        } else {
            slots = nil
        }
        return result(control.startRemoteCarouselUnload(slots: slots)) {
            .json(status: 202, ["accepted": true, "operationId": $0])
        }
    }

    private func controlCarousel(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let rawAction = object["action"] as? String,
              let action = CarouselBatchAction(rawValue: rawAction) else {
            return .json(status: 422, ["error": "A valid carousel action is required"])
        }
        return result(control.controlRemoteCarousel(
            id: object["id"] as? String,
            action: action
        )) { .json(status: 202, ["accepted": true]) }
    }

    private func configureMetadata(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        let object = jsonObject(request.body) ?? [:]
        control.configureMetadata(
            audioProvider: object["audioProvider"] as? String,
            videoProvider: object["videoProvider"] as? String,
            tmdbToken: object.keys.contains("tmdbToken") ? (object["tmdbToken"] as? String ?? "") : nil
        )
        return .json(control.metadataConfiguration())
    }

    private func searchMetadata(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let rawProvider = object["provider"] as? String,
              let provider = MetadataProvider(rawValue: rawProvider),
              provider != .none,
              let query = object["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .json(status: 422, ["error": "A provider and search query are required"])
        }
        let candidates = control.searchMetadata(provider: provider, query: query).map(candidateJSON)
        return .json(["results": candidates])
    }

    private func updateMetadata(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let discNumber = object["discId"] as? NSNumber,
              let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .json(status: 422, ["error": "discId and title are required"])
        }
        let rawSource = object["provider"] as? String ?? DiscMetadata.MetadataSource.manual.rawValue
        let source = DiscMetadata.MetadataSource(rawValue: rawSource) ?? .manual
        let tracks = (object["tracks"] as? [[String: Any]])?.compactMap { value -> DiscMetadata.TrackInfo? in
            guard let number = (value["number"] as? NSNumber)?.intValue,
                  let title = value["title"] as? String else { return nil }
            return DiscMetadata.TrackInfo(
                number: number,
                title: title,
                duration: (value["duration"] as? NSNumber)?.doubleValue
            )
        }
        let metadata = DiscMetadata(
            artist: (object["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown",
            album: title,
            year: object["year"] as? String,
            genre: object["genre"] as? String,
            tracks: tracks,
            source: source,
            providerID: object["providerId"] as? String,
            overview: object["overview"] as? String,
            artworkURL: object["artworkURL"] as? String
        )
        return result(control.updateMetadata(discId: discNumber.int64Value, metadata: metadata)) {
            .json(["updated": true])
        }
    }

    private func candidateJSON(_ candidate: MetadataCandidate) -> [String: Any] {
        var value: [String: Any] = [
            "providerId": candidate.id,
            "provider": candidate.provider,
            "title": candidate.title
        ]
        if let artist = candidate.artist { value["artist"] = artist }
        if let year = candidate.year { value["year"] = year }
        if let genre = candidate.genre { value["genre"] = genre }
        if let overview = candidate.overview { value["overview"] = overview }
        if let artworkURL = candidate.artworkURL { value["artworkURL"] = artworkURL }
        if let tracks = candidate.tracks {
            value["tracks"] = tracks.map { track -> [String: Any] in
                var item: [String: Any] = ["number": track.number, "title": track.title]
                if let duration = track.duration { item["duration"] = duration }
                return item
            }
        }
        return value
    }

    private func addDestination(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let rawPath = object["path"] as? String else {
            return .json(status: 422, ["error": "A destination path is required"])
        }
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = (object["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmedPath.lowercased().hasPrefix("smb://") {
            do {
                let resolved = try remoteDestinationResolver.resolve(
                    location: trimmedPath,
                    name: requestedName
                )
                guard isAllowedDestination(resolved.url) else {
                    return .json(status: 403, ["error": "The mounted SMB destination must resolve inside /Volumes"])
                }
                var values = destinations()
                if let index = values.firstIndex(where: {
                    $0.remoteURL?.caseInsensitiveCompare(resolved.remoteURL ?? "") == .orderedSame
                }) {
                    values[index] = RemoteRipDestination(
                        id: values[index].id,
                        name: resolved.name,
                        path: resolved.path,
                        remoteURL: resolved.remoteURL
                    )
                } else {
                    values.append(resolved)
                }
                updateDestinations(values)
                return .json(status: 201, ["destinations": destinationDetails()])
            } catch {
                return .json(status: 422, ["error": error.localizedDescription])
            }
        }

        guard trimmedPath.hasPrefix("/") else {
            return .json(status: 422, ["error": "Use an absolute folder path or an smb:// URL"])
        }

        let url = URL(fileURLWithPath: trimmedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard isAllowedDestination(url) else {
            return .json(status: 403, ["error": "Destinations must be inside the user's home folder or /Volumes"])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .json(status: 422, ["error": "That folder does not exist on the Discbot Mac"])
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return .json(status: 422, ["error": "That folder is not writable by Discbot"])
        }

        let name = requestedName.isEmpty ? url.lastPathComponent : requestedName
        var values = destinations()
        if let index = values.firstIndex(where: { $0.url.resolvingSymlinksInPath().path == url.path }) {
            values[index].name = name
        } else {
            values.append(RemoteRipDestination(name: name, path: url.path))
        }
        updateDestinations(values)
        return .json(status: 201, ["destinations": destinationDetails()])
    }

    private func connectDestination(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let rawId = object["id"] as? String,
              let id = UUID(uuidString: rawId),
              let destination = destinations().first(where: { $0.id == id }) else {
            return .json(status: 422, ["error": "A valid remote destination id is required"])
        }
        guard destination.isRemote else {
            return .json(status: 409, ["error": "That destination is not a network share"])
        }
        do {
            _ = try reconnect(destination)
            return .json(["destinations": destinationDetails()])
        } catch {
            return .json(status: 409, ["error": error.localizedDescription])
        }
    }

    private func reconnect(_ destination: RemoteRipDestination) throws -> RemoteRipDestination {
        guard let remoteURL = destination.remoteURL else { return destination }
        let resolved = try remoteDestinationResolver.resolve(
            location: remoteURL,
            name: destination.name,
            id: destination.id
        )
        guard isAllowedDestination(resolved.url) else {
            throw RemoteAPIError(status: 403, message: "The mounted SMB destination resolved outside /Volumes")
        }
        var values = destinations()
        guard let index = values.firstIndex(where: { $0.id == destination.id }) else {
            throw RemoteAPIError(status: 404, message: "Destination not found")
        }
        values[index] = resolved
        updateDestinations(values)
        return resolved
    }

    private func isAllowedDestination(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return destinationRoots().contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }

    private func removeDestination(_ request: RemoteHTTPRequest) -> RemoteHTTPResponse {
        guard let object = jsonObject(request.body),
              let rawId = object["id"] as? String,
              let id = UUID(uuidString: rawId) else {
            return .json(status: 422, ["error": "A valid destination id is required"])
        }
        let current = destinations()
        let updated = current.filter { $0.id != id }
        guard updated.count != current.count else {
            return .json(status: 404, ["error": "Destination not found"])
        }
        updateDestinations(updated)
        return .json(["destinations": destinationDetails()])
    }

    private func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func isAuthorized(_ request: RemoteHTTPRequest) -> Bool {
        guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer ") else { return false }
        let supplied = String(authorization.dropFirst("Bearer ".count))
        let expected = token()
        let left = Array(supplied.utf8)
        let right = Array(expected.utf8)
        guard left.count == right.count, !right.isEmpty else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func result<T>(
        _ result: Result<T, RemoteAPIError>,
        success: (T) -> RemoteHTTPResponse
    ) -> RemoteHTTPResponse {
        switch result {
        case .success(let value): return success(value)
        case .failure(let error): return .json(status: error.status, ["error": error.message])
        }
    }
}

final class RemoteControlServer {
    private let queue = DispatchQueue(label: "discbot.remoteServer", qos: .userInitiated)
    private let controller: RemoteAPIController
    private let requestWorkers = RemoteControlServer.workers("requests", count: 3)
    private let commandWorkers = RemoteControlServer.workers("commands", count: 1)
    private let destinationWorkers = RemoteControlServer.workers("destinations", count: 1)
    private let stateWorkers = RemoteControlServer.workers("state", count: 1)
    private let libraryWorkers = RemoteControlServer.workers("library", count: 1)
    private var generation = UUID()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stateSnapshotPending = false
    private var librarySnapshotPending = false

    private static func workers(_ name: String, count: Int) -> OperationQueue {
        let result = OperationQueue()
        result.name = "discbot.remote.\(name)"
        result.maxConcurrentOperationCount = count
        result.qualityOfService = .userInitiated
        return result
    }
    private var listener: NWListener?
    private var eventConnections: [UUID: NWConnection] = [:]
    private var eventTimer: DispatchSourceTimer?
    private var lastStateSnapshot: Data?
    private var lastLibrarySnapshot: Data?
    private var lastLibraryCheck = Date.distantPast
    private var lastEventWrite = Date.distantPast
    private let statusChanged: (String) -> Void

    init(controller: RemoteAPIController, statusChanged: @escaping (String) -> Void) {
        self.controller = controller
        self.statusChanged = statusChanged
    }

    func start(port: UInt16, localhostOnly: Bool = false) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteAPIError(status: 500, message: "Invalid server port")
        }
        let parameters = NWParameters.tcp
        if localhostOnly {
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(IPv4Address.loopback),
                port: nwPort
            )
        }
        parameters.allowLocalEndpointReuse = true
        // Catalina can otherwise create an IPv6-only wildcard listener, excluding
        // older LAN clients. Explicitly constrain the IP stack to IPv4.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let listener = try localhostOnly
            ? NWListener(using: parameters)
            : NWListener(using: parameters, on: nwPort)
        if !localhostOnly {
            listener.service = NWListener.Service(name: ProcessInfo.processInfo.hostName, type: "_discbot._tcp")
        }
        queue.async {
            self.stopOnQueue()
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self = self, self.listener === listener else { return }
                switch state {
                case .ready: self.publish("Listening on port \(port)")
                case .failed(let error):
                    self.publish("Server failed: \(error.localizedDescription)")
                    self.stopOnQueue()
                case .cancelled: self.publish("Server stopped")
                default: break
                }
            }
            listener.start(queue: self.queue)
            self.startEventTimer()
        }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        generation = UUID()
        eventTimer?.cancel()
        eventTimer = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        eventConnections.removeAll()
        lastStateSnapshot = nil
        lastLibrarySnapshot = nil
        stateSnapshotPending = false
        librarySnapshotPending = false
        lastLibraryCheck = .distantPast
        listener?.cancel()
        listener = nil
        [requestWorkers, commandWorkers, destinationWorkers, stateWorkers, libraryWorkers]
            .forEach { $0.cancelAllOperations() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 128 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection else { return }
            if case .failed = state { self.removeEventConnection(connection) }
            if case .cancelled = state { self.removeEventConnection(connection) }
        }
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self = self else { connection.cancel(); return }
            var buffer = accumulated
            if let data = data { buffer.append(data) }
            switch RemoteHTTPRequest.framing(buffer) {
            case .rejected(let status):
                self.send(.json(status: status, ["error": "Invalid or oversized request"]), on: connection)
            case .ready(let length):
                guard let request = RemoteHTTPRequest.parse(Data(buffer.prefix(length))) else {
                    self.send(.json(status: 400, ["error": "Malformed request"]), on: connection)
                    return
                }
                if request.method == "GET" && request.path == "/api/v1/events" {
                    if self.controller.isAuthorized(request) {
                        self.beginEventStream(on: connection)
                    } else {
                        self.send(.json(status: 401, ["error": "Invalid or missing bearer token"]), on: connection)
                    }
                } else {
                    self.dispatch(request, on: connection)
                }
            case .incomplete:
                if complete || error != nil {
                    self.send(.json(status: 400, ["error": "Malformed request"]), on: connection)
                } else {
                    self.receive(connection, accumulated: buffer)
                }
            }
        }
    }

    private func dispatch(_ request: RemoteHTTPRequest, on connection: NWConnection) {
        let workers: OperationQueue
        if request.path.hasPrefix("/api/v1/jobs/cancel")
            || request.path == "/api/v1/health" || request.path == "/"
            || request.path == "/api/v1/carousel/action"
            || request.path.hasPrefix("/api/v1/inventory/")
            || request.path == "/api/v1/recovery/return-disc"
            || request.path == "/api/v1/slots/action" {
            workers = commandWorkers
        } else if request.path.hasPrefix("/api/v1/destinations") || request.path == "/api/v1/jobs/rip" {
            // Serialize destination read/modify/write operations and reconnection.
            workers = destinationWorkers
        } else {
            workers = requestWorkers
        }
        guard workers.operationCount < 16 else {
            send(.json(status: 503, ["error": "Server busy; retry shortly"]), on: connection)
            return
        }
        let requestGeneration = generation
        workers.addOperation { [weak self] in
            guard let self = self else { return }
            guard self.queue.sync(execute: { self.generation == requestGeneration }) else { return }
            let response = self.controller.response(to: request)
            self.queue.async {
                guard self.generation == requestGeneration else { return }
                self.send(response, on: connection)
            }
        }
    }

    private func startEventTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.publishEventSnapshotIfNeeded() }
        eventTimer = timer
        timer.resume()
    }

    private func beginEventStream(on connection: NWConnection) {
        let id = UUID()
        eventConnections[id] = connection
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream; charset=utf-8\r
        Cache-Control: no-cache, no-store\r
        Transfer-Encoding: chunked\r
        X-Accel-Buffering: no\r
        X-Content-Type-Options: nosniff\r
        Referrer-Policy: no-referrer\r
        Connection: keep-alive\r
        \r

        """
        var events = Data(": connected\n\n".utf8)
        if let state = lastStateSnapshot { events.append(eventData(state)) }
        if let library = lastLibrarySnapshot { events.append(eventData(library)) }
        lastEventWrite = Date()
        var response = Data(header.utf8)
        response.append(chunk(events))
        sendRawEventData(response, id: id, connection: connection)
        publishEventSnapshotIfNeeded()
    }

    private func publishEventSnapshotIfNeeded() {
        guard !eventConnections.isEmpty else { return }
        let snapshotGeneration = generation
        if !stateSnapshotPending {
            stateSnapshotPending = true
            stateWorkers.addOperation { [weak self] in
                guard let self = self else { return }
                let state = self.controller.stateEventData()
                self.queue.async {
                    guard self.generation == snapshotGeneration else { return }
                    self.stateSnapshotPending = false
                    if let state = state, state != self.lastStateSnapshot {
                        self.lastStateSnapshot = state
                        self.lastEventWrite = Date()
                        self.broadcast(self.eventData(state))
                    }
                }
            }
        }
        if !librarySnapshotPending && Date().timeIntervalSince(lastLibraryCheck) >= 2 {
            lastLibraryCheck = Date()
            librarySnapshotPending = true
            libraryWorkers.addOperation { [weak self] in
                guard let self = self else { return }
                let library = self.controller.libraryEventData()
                self.queue.async {
                    guard self.generation == snapshotGeneration else { return }
                    self.librarySnapshotPending = false
                    if let library = library, library != self.lastLibrarySnapshot {
                        self.lastLibrarySnapshot = library
                        self.lastEventWrite = Date()
                        self.broadcast(self.eventData(library))
                    }
                }
            }
        }
        if Date().timeIntervalSince(lastEventWrite) >= 15 {
            lastEventWrite = Date()
            broadcast(Data(": keepalive\n\n".utf8))
        }
    }

    private func eventData(_ snapshot: Data) -> Data {
        var data = Data("event: snapshot\ndata: ".utf8)
        data.append(snapshot)
        data.append(Data("\n\n".utf8))
        return data
    }

    private func broadcast(_ data: Data) {
        let framed = chunk(data)
        for (id, connection) in eventConnections {
            sendRawEventData(framed, id: id, connection: connection)
        }
    }

    private func chunk(_ data: Data) -> Data {
        var framed = Data(String(data.count, radix: 16).utf8)
        framed.append(Data("\r\n".utf8))
        framed.append(data)
        framed.append(Data("\r\n".utf8))
        return framed
    }

    private func sendRawEventData(_ data: Data, id: UUID, connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.queue.async { self?.eventConnections.removeValue(forKey: id)?.cancel() }
            }
        })
    }

    private func removeEventConnection(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
        if let id = eventConnections.first(where: { $0.value === connection })?.key {
            eventConnections.removeValue(forKey: id)
        }
    }

    private func send(_ response: RemoteHTTPResponse, on connection: NWConnection) {
        let reason: String
        switch response.status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 422: reason = "Unprocessable Entity"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        let header = """
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: \(response.contentType)\r
        Content-Length: \(response.body.count)\r
        Cache-Control: no-store\r
        X-Content-Type-Options: nosniff\r
        X-Frame-Options: DENY\r
        Referrer-Policy: no-referrer\r
        Connection: close\r
        \r

        """
        var data = Data(header.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func publish(_ status: String) {
        DispatchQueue.main.async { self.statusChanged(status) }
    }
}

/// Owns the remote-control stack without creating NSApplication.  This is
/// important on a Catalina machine that is running without a logged-in GUI
/// session: AppKit never finishes launching there, but Foundation's main run
/// loop and the changer services work normally.
final class HeadlessRemoteServerRuntime {
    private let settings = AppSettings()
    private lazy var viewModel = ChangerViewModel(settings: settings)
    private var adapter: ChangerRemoteControlAdapter?
    private var server: RemoteControlServer?
    private var shutdownDeadline: Date?
    private var isShuttingDown = false

    func start() throws {
        let adapter = ChangerRemoteControlAdapter(viewModel: viewModel)
        let controller = RemoteAPIController(
            control: adapter,
            token: { [weak self] in self?.settings.remoteAccessToken ?? "" },
            destinations: { [weak self] in self?.settings.remoteDestinations ?? [] },
            updateDestinations: { [weak self] values in
                guard let self = self else { return }
                let update = { self.settings.remoteDestinations = values }
                Thread.isMainThread ? update() : DispatchQueue.main.sync(execute: update)
            }
        )
        let server = RemoteControlServer(controller: controller) { status in
            print("Discbot server: \(status)")
        }
        self.adapter = adapter
        self.server = server
        try server.start(port: UInt16(settings.remoteServerPort))
    }

    /// Stops accepting commands and gives an active batch up to three minutes
    /// to cancel and return its current disc.  Recovery state is only cleared
    /// after the drive is verified empty.
    func shutdown(completion: @escaping (Bool) -> Void) {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        server?.stop()

        let hasActiveOperation = viewModel.currentOperation != nil
        let hasBatch = viewModel.batchState?.isRunning == true
        let hasCarouselOperation = viewModel.carouselBatchSnapshot?.running == true
        let hasLoadedDisc = viewModel.driveStatus != .empty
        guard hasActiveOperation || hasBatch || hasCarouselOperation || hasLoadedDisc else {
            finishShutdown(success: true, completion: completion)
            return
        }

        viewModel.batchState?.cancel()
        if hasCarouselOperation { viewModel.cancelUnloadAll() }
        shutdownDeadline = Date().addingTimeInterval(180)
        waitForSafeReturn(completion: completion)
    }

    private func waitForSafeReturn(completion: @escaping (Bool) -> Void) {
        guard let deadline = shutdownDeadline, Date() < deadline else {
            FileHandle.standardError.write(Data("Discbot server refused to stop: safe-return cleanup timed out.\n".utf8))
            finishShutdown(success: false, completion: completion)
            return
        }
        if viewModel.currentOperation != nil || viewModel.batchState?.isRunning == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.waitForSafeReturn(completion: completion)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.viewModel.emergencyEjectSync()
            DispatchQueue.main.async {
                if success { ChangerViewModel.clearDirtyFlag() }
                if !success {
                    FileHandle.standardError.write(Data("Discbot server refused to stop: the drive could not be verified empty.\n".utf8))
                }
                self.finishShutdown(success: success, completion: completion)
            }
        }
    }

    private func finishShutdown(
        success: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        shutdownDeadline = nil
        if success {
            completion(true)
            return
        }

        // A failed safe return must leave a usable, retryable server. The
        // previous one-shot latch stopped listening forever and ignored every
        // later SIGTERM, eventually forcing an unsafe process kill. Reset the
        // coordinator and resume HTTP service so a later termination request
        // can retry the verified cleanup path.
        isShuttingDown = false
        do {
            try server?.start(port: UInt16(settings.remoteServerPort))
        } catch {
            FileHandle.standardError.write(Data(
                "Discbot server could not resume after failed shutdown: \(error.localizedDescription)\n".utf8
            ))
        }
        completion(false)
    }
}

private enum RemoteWebClient {
    static let html = #"""
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Discbot</title><style>
:root{color-scheme:dark;--bg:#080d14;--panel:#121a25;--panel2:#182230;--line:#29374a;--text:#f2f6fb;--muted:#94a2b6;--blue:#69a9ff;--blue2:#183e6d;--green:#51d393;--red:#ff7883;--amber:#f0bd62}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;line-height:1.45}header{position:sticky;top:0;z-index:5;min-height:64px;padding:10px max(18px,calc((100vw - 1180px)/2));background:#080d14ed;border-bottom:1px solid var(--line);backdrop-filter:blur(18px);display:flex;align-items:center;gap:18px}.brand{display:flex;align-items:center;gap:9px;white-space:nowrap}.brand-mark{width:18px;height:18px;border:2px solid var(--text);border-radius:50%;box-shadow:inset 0 0 0 4px var(--bg)}h1{font-size:20px;margin:0}h2{font-size:21px;margin:0}h3{font-size:15px;margin:0}.task-nav{display:flex;align-items:center;gap:4px}.task-nav button{background:transparent;border-color:transparent;color:var(--muted);font-weight:600}.task-nav button.active{background:var(--panel2);border-color:var(--line);color:var(--text)}.header-state{display:flex;align-items:center;gap:12px;margin-left:auto;min-width:0}.connection-dot{width:8px;height:8px;border-radius:50%;background:var(--green);display:inline-block;margin-right:6px}.header-message{color:var(--muted);max-width:340px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}main{max-width:1180px;margin:auto;padding:28px 20px 56px}.task-view{display:none}.task-view.active{display:block}.page-heading{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;margin-bottom:20px}.page-heading p{margin:5px 0 0}.eyebrow{color:var(--blue);font-size:12px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.card,.panel{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px}.card b{display:block;font-size:25px;margin-top:4px}.muted{color:var(--muted)}button,select,input,textarea{border:1px solid var(--line);border-radius:9px;background:#202c3d;color:var(--text);padding:10px 13px;font:inherit}input,select{min-height:42px}textarea{width:100%;min-height:86px;resize:vertical}button{cursor:pointer}button:hover:not(:disabled){border-color:#49617e}button.primary{background:var(--blue);border-color:var(--blue);color:#07101d;font-weight:800}button.secondary{background:transparent}button.danger{color:var(--red)}button:disabled{opacity:.45;cursor:not-allowed}.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.grow{flex:1;min-width:260px}.panel{margin-top:16px}.workflow{padding:0;overflow:hidden}.step{display:grid;grid-template-columns:38px minmax(0,1fr);gap:14px;padding:20px;border-bottom:1px solid var(--line)}.step:last-child{border-bottom:0}.step-number{width:30px;height:30px;display:grid;place-items:center;border-radius:50%;background:var(--blue2);color:#bcd8ff;font-weight:800}.step-content>p{margin:4px 0 14px}.choice-grid{display:grid;grid-template-columns:minmax(180px,1fr) minmax(180px,1fr);gap:12px}.choice label{display:block;color:var(--muted);font-size:12px;font-weight:700;margin-bottom:6px;text-transform:uppercase;letter-spacing:.05em}.choice select{width:100%}.selection-line{display:flex;align-items:center;gap:10px;margin-bottom:12px}.slots{display:grid;grid-template-columns:repeat(auto-fill,minmax(92px,1fr));gap:8px}.slot{position:relative;padding:12px 7px;text-align:center;border:1px solid var(--line);border-radius:10px;background:#0d141e}.slot.full{border-color:#425b78}.slot.ripped{border-color:#386c5a}.slot.ripped:after{content:"Ripped";display:block;color:var(--green);font-size:11px;font-weight:700;margin-top:4px}.slot input{display:block;margin:0 auto 7px}.status-strip{display:flex;align-items:center;gap:10px;margin-bottom:14px;padding:12px 15px;border:1px solid var(--line);border-radius:12px;background:#0d141e}.status-strip strong{white-space:nowrap}.status-strip .muted{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.progress{height:9px;background:#263246;border-radius:9px;overflow:hidden}.progress i{display:block;height:100%;background:var(--blue);width:0}.progress.indeterminate i{width:35%;animation:scan 1.35s ease-in-out infinite}@keyframes scan{0%{transform:translateX(-110%)}100%{transform:translateX(300%)}}.hidden{display:none!important}.right{margin-left:auto}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:11px 9px;border-bottom:1px solid var(--line);vertical-align:middle}th{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}.cover,.cover-placeholder{width:42px;aspect-ratio:1/1;border-radius:6px;background:#202b3b}.cover{height:auto;object-fit:cover}.cover.pending{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}.cover-placeholder{display:grid;place-items:center;border:1px dashed #3a4b61;background:#0d141e;color:var(--muted);font-size:20px}.cover-placeholder.error{border-color:#713944;color:var(--red)}.cover.video,.cover-placeholder.video{aspect-ratio:2/3}.metadata-editor-layout{display:grid;grid-template-columns:120px minmax(0,1fr);gap:18px;margin-top:14px}.art-preview{width:120px;height:auto;aspect-ratio:1/1;object-fit:cover;border-radius:9px;background:#0d141e;border:1px solid var(--line)}.art-preview.video{aspect-ratio:2/3}.metadata-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.metadata-grid .wide{grid-column:1/-1}.results{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:9px;margin-top:12px}.result{display:flex;gap:9px;text-align:left;align-items:flex-start}.result.selected{border-color:var(--blue);box-shadow:0 0 0 2px #69a9ff33}.result .cover{width:54px;flex:none}.credit{font-size:12px;margin-top:12px}.activity-type{display:inline-block;padding:3px 8px;border-radius:999px;background:var(--panel2);font-size:12px}.empty-state{text-align:center;padding:28px;color:var(--muted)}details.tools{margin-top:14px;border-top:1px solid var(--line);padding-top:14px}details.tools summary{cursor:pointer;color:var(--muted);font-weight:600}.settings-group+.settings-group{margin-top:24px;padding-top:24px;border-top:1px solid var(--line)}@media(max-width:760px){header{align-items:flex-start;flex-wrap:wrap;padding:12px 14px}.task-nav{order:3;width:100%;overflow:auto}.task-nav button{flex:1}.header-message{display:none}main{padding:20px 14px}.page-heading{align-items:flex-start;flex-direction:column}.choice-grid{grid-template-columns:1fr}.step{grid-template-columns:30px minmax(0,1fr);padding:16px 14px}.right{margin-left:0}.grow{min-width:100%}.metadata-grid{grid-template-columns:1fr}.metadata-editor-layout{grid-template-columns:1fr}.art-preview{width:90px}.table-wrap{margin:0 -18px;padding:0 18px}}
	.task-nav button{white-space:nowrap}.guide-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}.guide-card{margin-top:0}.guide-card h2{margin-bottom:5px}.guide-card .count{font-size:34px;font-weight:800;line-height:1;margin:18px 0 4px}.guide-steps{margin:16px 0;padding-left:22px}.guide-steps li{margin:10px 0}.callout{padding:13px 15px;border:1px solid #66512b;border-radius:10px;background:#241d12;color:#f7d999}.guide-actions{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:16px}@media(max-width:760px){.guide-grid{grid-template-columns:1fr}}
	.activity-type.failure{color:var(--red);border:1px solid #713944}.job-errors{margin:12px 0 0;padding:10px 12px 10px 30px;border:1px solid #713944;border-radius:9px;background:#2b151b;color:#ffd4d8}.job-errors li+li{margin-top:5px}.job-header{display:flex;align-items:flex-start;gap:14px;margin-bottom:18px}.job-header-actions{margin-left:auto;display:flex;gap:9px}.job-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.job-grid.finished{grid-template-columns:1fr}.job-stage{padding:16px;border:1px solid var(--line);border-radius:11px;background:#0d141e}.job-stage h3{font-size:18px;margin:3px 0}.job-stage .progress{margin:14px 0 9px}.job-metrics{display:flex;justify-content:space-between;gap:12px;color:var(--muted);font-size:13px}.job-stage button{margin-top:14px}@media(max-width:760px){.job-grid{grid-template-columns:1fr}.job-header{flex-wrap:wrap}.job-header-actions{width:100%;margin-left:0}.job-header-actions button{flex:1}.job-metrics{flex-wrap:wrap}}
	\#(RemoteCarouselRenderer.styles)
	</style></head><body><header>
<div class="brand"><span class="brand-mark" aria-hidden="true"></span><h1>Discbot</h1></div>
<nav id="taskNav" class="task-nav hidden" aria-label="Tasks"><button class="active" data-task-target="rip" onclick="showTask('rip')">Rip discs</button><button data-task-target="carousel" onclick="showTask('carousel')">Carousel</button><button data-task-target="library" onclick="showTask('library')">Library</button><button data-task-target="activity" onclick="showTask('activity')">Activity</button><button data-task-target="settings" onclick="showTask('settings')">Settings</button></nav>
<div class="header-state"><span id="connection"><span class="connection-dot"></span>Disconnected</span><span id="message" class="header-message"></span></div>
</header><main>
<section id="login" class="panel"><div class="page-heading"><div><span class="eyebrow">Remote control</span><h2>Connect to Discbot</h2><p class="muted">Enter the access token stored for this changer.</p></div></div><div class="toolbar"><input id="token" class="grow" type="password" placeholder="Access token"><button class="primary" onclick="connect()">Connect</button></div></section>
<div id="app" class="hidden">
<section class="task-view active" data-task="rip"><div class="page-heading"><div><span class="eyebrow">Task 1</span><h2>Rip discs</h2><p class="muted">Choose loaded discs, decide how to handle duplicates, and start the batch.</p></div></div>
<div class="status-strip"><span class="connection-dot"></span><strong id="device">—</strong><span class="muted"><span id="full">0</span> loaded slots</span></div>
<section id="operationPanel" class="panel hidden" aria-live="polite"><strong id="operationStatus">Changer operation in progress…</strong><div class="progress indeterminate" style="margin-top:12px"><i></i></div><p class="muted">Inventory updates automatically when the changer finishes.</p></section>
<section id="recoveryPanel" class="panel hidden" aria-live="polite"><div class="toolbar"><div><strong id="recoveryStatus">A disc is waiting in the drive</strong><p class="muted" style="margin-bottom:0">Its source slot is preserved and will be verified before movement.</p></div><button id="recoverDiscButton" class="primary right" onclick="returnLoadedDisc()">Return disc safely</button></div></section>
<section id="jobPanel" class="panel hidden" aria-live="polite"><div class="job-header"><div><span id="jobKind" class="eyebrow">Batch rip</span><h2 id="jobHeading">Rip in progress</h2></div><div class="job-header-actions"><button id="cancelAllButton" class="danger" onclick="cancelAll()">Cancel entire batch</button></div></div><div id="jobGrid" class="job-grid"><section id="currentDiscStage" class="job-stage"><span class="eyebrow">Current disc</span><h3 id="currentDiscName">Preparing disc…</h3><p id="currentDiscStatus" class="muted">Waiting for the drive…</p><div class="progress"><i id="currentDiscBar"></i></div><div class="job-metrics"><span id="currentDiscPercent">0%</span><span id="currentDiscMetrics">Calculating…</span></div><button id="cancelCurrentDiscButton" class="danger" onclick="cancelCurrentDisc()">Cancel this disc</button></section><section class="job-stage"><span class="eyebrow">Overall progress</span><h3 id="overallPosition">Preparing batch…</h3><p id="overallETA" class="muted">Estimating time remaining…</p><div class="progress"><i id="overallBar"></i></div><div class="job-metrics"><span id="overallPercent">0%</span><span id="jobDetail"></span></div></section></div><ul id="jobErrors" class="job-errors hidden"></ul></section>
<section class="panel"><div class="toolbar"><div><span class="eyebrow">Catalog first</span><h2>Scan unknown discs</h2><p id="scanUnknownSummary" class="muted" style="margin:5px 0 0">Reading the carousel…</p></div><button id="scanUnknownButton" class="primary right" onclick="startScanUnknown()">Scan discs</button></div><p class="credit muted" style="margin-bottom:0">Each unknown disc is loaded into the drive, identified, matched with online metadata, and returned to its original slot. Cancelling waits for the current disc to be returned safely.</p></section>
<section class="panel workflow">
<div class="step"><span class="step-number">1</span><div class="step-content"><h3>Choose discs</h3><p id="selectionSummary" class="muted">Select one or more loaded slots.</p><div class="selection-line"><button id="selectAllButton" onclick="selectAll()">Select all loaded</button><button id="clearAllButton" class="secondary" onclick="clearAll()">Clear</button></div><div id="slots" class="slots"></div><details class="tools"><summary>Changer tools</summary><div class="toolbar" style="margin-top:12px"><button id="refreshInventoryButton" onclick="refreshInventory()">Refresh inventory</button><button id="rescanInventoryButton" class="danger" onclick="rescanInventory()" title="Physically rescan all changer elements; this can take several minutes">Full hardware rescan</button></div></details></div></div>
<div class="step"><span class="step-number">2</span><div class="step-content"><h3>Choose output and duplicate behavior</h3><p class="muted">DVD folder skips ISO construction and is fastest for DVD-Video. ISO creates a single playable disc image. Audio CDs remain lossless AIFF ZIP archives.</p><div class="choice-grid"><div class="choice"><label for="destination">Save to</label><select id="destination" onchange="updateStartState()" aria-label="Rip destination"></select></div><div class="choice"><label for="outputMode">Rip format</label><select id="outputMode" aria-label="Rip output format"><option value="automatic">Best format for each disc</option><option value="iso">ISO disc image</option><option value="dvdFolder">DVD folder (faster)</option></select></div><div class="choice"><label for="policy">If already ripped</label><select id="policy" aria-label="Duplicate policy"><option value="skipExisting">Skip verified copy</option><option value="replaceExisting">Replace existing copy</option><option value="imageAgain">Keep both copies</option></select></div></div></div></div>
<div class="step"><span class="step-number">3</span><div class="step-content"><h3>Start batch</h3><p class="muted">Discbot will load, identify, rip or skip, and safely return every selected disc.</p><button id="start" class="primary" onclick="startRip()">Start batch rip</button></div></div>
</section></section>
	<section class="task-view" data-task="carousel"><div class="page-heading"><div><span class="eyebrow">Task 2</span><h2>Load or unload the carousel</h2><p class="muted">Discbot opens the Sony XL1B gate for each disc and verifies every move.</p></div><button id="carouselRefreshButton" onclick="refreshInventory()">Refresh inventory</button></div>
	<div class="status-strip"><span class="connection-dot"></span><strong id="carouselDevice">—</strong><span id="carouselSummary" class="muted">Reading carousel…</span></div>
	\#(RemoteCarouselRenderer.markup)
	<section class="guide-grid">
<article class="panel guide-card"><span class="eyebrow">Software bulk load</span><div id="carouselEmptyCount" class="count">0</div><p class="muted">verified empty slots available</p><p id="carouselInventoryNote" class="muted"></p><p>Choose a count. Insert each disc within 10 seconds; Discbot detects it and advances automatically.</p><div class="guide-actions"><input id="carouselLoadCount" type="number" min="1" value="3" style="width:92px" aria-label="Number of discs to load"><button id="startCarouselLoadButton" class="primary" onclick="startCarouselLoad()">Start loading</button></div></article>
<article class="panel guide-card"><span class="eyebrow">Software bulk unload</span><div id="carouselFullCount" class="count">0</div><p class="muted">carousel discs loaded</p><p>Remove each presented disc within 10 seconds. Discbot monitors the gate and advances automatically.</p><button id="startCarouselUnloadButton" class="primary" onclick="startCarouselUnload()">Unload all carousel discs</button></article>
</section>
<section id="carouselDriveWarning" class="panel hidden"><div class="toolbar"><div><strong>A disc is still inside the optical drive</strong><p id="carouselDriveDetail" class="muted" style="margin-bottom:0">Sony’s bulk eject mode only unloads carousel slots.</p></div><button id="carouselReturnDriveButton" class="primary right" onclick="returnCarouselDriveDisc()">Return drive disc first</button></div></section>
<section id="carouselJobPanel" class="panel hidden" aria-live="polite"><div class="toolbar"><div><span id="carouselJobMode" class="eyebrow">Carousel operation</span><h2 id="carouselJobStatus">Preparing…</h2></div><button id="carouselCancelButton" class="danger right" onclick="carouselAction('cancel')">Cancel safely</button></div><div class="progress" style="margin-top:14px"><i id="carouselBar"></i></div><p id="carouselJobDetail" class="muted"></p><div id="carouselActions" class="guide-actions"><button id="carouselContinueButton" class="primary hidden" onclick="carouselAction('continue')">Disc removed — continue</button><button id="carouselRetryButton" class="primary hidden" onclick="carouselAction('retry')">Retry this slot</button><button id="carouselSkipButton" class="secondary hidden" onclick="carouselAction('skip')">Skip this slot</button><button id="carouselFinishButton" class="secondary hidden" onclick="carouselAction('finish')">Finish now</button></div></section>
<p class="credit muted">If a load times out, Discbot closes the gate and cancels. If an unload times out, it returns the disc to its original slot before cancelling.</p></section>
<section class="task-view" data-task="library"><div class="page-heading"><div><span class="eyebrow">Task 3</span><h2>Browse library</h2><p class="muted">Find every disc Discbot has seen and manage its metadata.</p></div><input id="librarySearch" type="search" placeholder="Search discs" oninput="renderLibrary()"></div><section class="grid"><div class="card"><span class="muted">Available images</span><b id="images">0</b></div><div class="card"><span class="muted">Storage used</span><b id="stored">0 B</b></div></section>
<section id="metadataEditor" class="panel hidden"><div class="toolbar"><div><h2>Choose artwork and metadata</h2><p class="muted" style="margin:4px 0 0">When several editions match, select the correct cover before saving.</p></div><button class="right" onclick="closeMetadataEditor()">Close</button></div><div class="toolbar" style="margin-top:14px"><select id="metadataSearchProvider" onchange="updateArtworkShape(null,this.value)"><option value="musicBrainz">MusicBrainz</option><option value="tmdb">TMDB</option></select><input id="metadataQuery" class="grow" placeholder="Search title or artist"><button onclick="searchMetadata()">Search</button></div><div id="metadataResults" class="results"></div><div class="metadata-editor-layout"><img id="metadataArtworkPreview" class="art-preview" alt="Selected artwork preview"><div class="metadata-grid"><input id="metadataTitle" placeholder="Title / album"><input id="metadataArtist" placeholder="Artist / media kind"><input id="metadataYear" placeholder="Year"><input id="metadataGenre" placeholder="Genre"><input id="metadataArtwork" class="wide" placeholder="Artwork URL" oninput="updateArtworkPreview(this.value)"><textarea id="metadataOverview" class="wide" placeholder="Description or notes"></textarea></div></div><div class="toolbar" style="margin-top:10px"><button class="primary" onclick="saveMetadata()">Save selection</button><span id="metadataSourceLabel" class="muted"></span></div></section>
<section class="panel"><div class="table-wrap"><table><thead><tr><th></th><th>Disc</th><th>Type</th><th>Metadata</th><th>Rips</th><th></th></tr></thead><tbody id="library"></tbody></table></div></section></section>
<section class="task-view" data-task="activity"><div class="page-heading"><div><span class="eyebrow">Task 4</span><h2>Review activity</h2><p class="muted">See recent ripping, skipping, and recovery events.</p></div></div><section class="panel"><div class="table-wrap"><table><thead><tr><th>When</th><th>Result</th><th>Details</th></tr></thead><tbody id="activity"></tbody></table></div></section></section>
<section class="task-view" data-task="settings"><div class="page-heading"><div><span class="eyebrow">Task 5</span><h2>Configure Discbot</h2><p class="muted">Manage storage locations and online metadata services.</p><p id="dvdSupport" class="muted"></p></div></div><section class="panel"><div class="settings-group"><h2>Rip destinations</h2><p class="muted">Use a folder on the Mac mini, a mounted volume, or an SMB network location. SMB credentials stay in the Mac mini’s Keychain and are never sent to this web app.</p><div class="toolbar"><input id="destinationName" placeholder="Name (optional)"><input id="destinationPath" class="grow" placeholder="/Users/jackson/Discbot or smb://nas/Media/Disc Images"><button onclick="addDestination()">Add destination</button></div><p id="destinationHint" class="muted"></p><div class="table-wrap"><table><tbody id="destinationRows"></tbody></table></div></div>
<div class="settings-group"><h2>Metadata sources</h2><p class="muted">Choose where audio CD and DVD details come from.</p><div class="choice-grid"><div class="choice"><label for="audioProvider">Audio CDs</label><select id="audioProvider"><option value="musicBrainz">MusicBrainz + Cover Art Archive</option><option value="none">Local/manual only</option></select></div><div class="choice"><label for="videoProvider">DVDs</label><select id="videoProvider"><option value="tmdb">TMDB</option><option value="none">Local/manual only</option></select></div></div><div class="toolbar" style="margin-top:12px"><input id="tmdbToken" class="grow" type="password" placeholder="TMDB API Read Access Token"><button onclick="saveMetadataConfig()">Save metadata settings</button></div><p id="metadataConfigHint" class="muted"></p><p class="credit muted">Music metadata and artwork can come from MusicBrainz and the Cover Art Archive. This product uses the <a href="https://www.themoviedb.org" target="_blank" rel="noreferrer">TMDB API</a> but is not endorsed or certified by TMDB.</p></div></section></section>
	</div></main><script>
	\#(RemoteCarouselRenderer.script)
let auth='',eventAbort=null,currentJob=null,currentCarousel=null,libraryRows=[],destinationRows=[],hardwareBusy=false,editingDisc=null,editingMetadata=null,activeTask='rip',latestState=null,renderedJobId='',renderedDiscKey='',renderedDiscProgress=0,renderedOverallProgress=0;const artworkObjects=new Map(),$=id=>document.getElementById(id);function say(v){$('message').textContent=v||''}function bytes(v){let n=Number(v)||0,u=['B','KB','MB','GB','TB'],i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return (i?n.toFixed(n<10?1:0):n.toFixed(0))+' '+u[i]}function duration(v){let n=Math.max(0,Math.round(Number(v)||0));if(!Number.isFinite(n))return'Calculating…';const h=Math.floor(n/3600),m=Math.floor((n%3600)/60),s=n%60;if(h)return h+' hr '+m+' min';if(m)return m+' min '+s+' sec';return s+' sec'}function showTask(name){activeTask=name;document.querySelectorAll('.task-view').forEach(v=>v.classList.toggle('active',v.dataset.task===name));document.querySelectorAll('[data-task-target]').forEach(b=>b.classList.toggle('active',b.dataset.taskTarget===name));sessionStorage.setItem('discbotTask',name);window.scrollTo({top:0,behavior:'smooth'})}function setConnectionLabel(text,online){const dot=document.createElement('span');dot.className='connection-dot';if(!online)dot.style.background='var(--red)';$('connection').replaceChildren(dot,document.createTextNode(text))}function friendlyType(v){const x=(v||'').toLowerCase();if(x.includes('audio'))return'Audio CD';if(x.includes('dvd'))return'DVD';if(x.includes('data'))return'Data disc';return v||'Unknown'}function localTime(v){const d=new Date(v);return isNaN(d)?v:d.toLocaleString([], {dateStyle:'medium',timeStyle:'short'})}
async function api(path,opt={}){opt.headers={...(opt.headers||{}),Authorization:'Bearer '+auth};if(opt.body)opt.headers['Content-Type']='application/json';const r=await fetch(path,opt);const j=await r.json();if(!r.ok)throw Error(j.error||r.statusText);return j}
async function connect(){auth=$('token').value.trim();sessionStorage.setItem('discbotToken',auth);try{const [s,l,d,m]=await Promise.all([api('/api/v1/state'),api('/api/v1/library'),api('/api/v1/destinations'),api('/api/v1/metadata/config')]);applySnapshot({state:s,library:l,destinations:d.destinations,metadataConfig:m});$('login').classList.add('hidden');$('app').classList.remove('hidden');$('taskNav').classList.remove('hidden');showTask(sessionStorage.getItem('discbotTask')||'rip');startEvents()}catch(e){showConnectionError(e)}}
function applySnapshot(v){if(v.destinations){destinationRows=v.destinations;renderDestinationRows()}if(v.metadataConfig)applyMetadataConfig(v.metadataConfig);if(v.state){const s=v.state,c=s.connection||{};latestState=s;setConnectionLabel(s.connected?s.device+' · Live':(c.label||'Changer offline'),s.connected);$('device').textContent=s.connected?s.device:(c.requiresPowerCycle?'Power cycle required':'Not connected');$('full').textContent=s.fullSlots;const ds=$('dvdSupport');if(ds)ds.textContent=s.dvdVideoSupport?'Protected DVD-Video support: installed':'Protected DVD-Video support: not installed';renderDest(s.destinations||[]);renderSlots(s.slots,s.busy);renderCarousel(s);renderJob(s.job);renderOperation(s.operation);renderRecovery(s.recovery);const retry=c.retryInSeconds!=null?' Retrying in '+c.retryInSeconds+'s.':'';if(s.error||retry)say((s.error||'')+retry);else if(!s.operation&&s.notice)say(s.notice)}if(v.library){const l=v.library;$('images').textContent=l.statistics.availableImages;$('stored').textContent=bytes(l.statistics.storedBytes);libraryRows=l.entries||[];renderLibrary();renderActivity(l.activity)}}
function showConnectionError(e){say(e.message);if(e.message.toLowerCase().includes('token')){if(eventAbort)eventAbort.abort();setConnectionLabel('Disconnected',false);$('taskNav').classList.add('hidden');$('login').classList.remove('hidden');$('app').classList.add('hidden')}}
async function startEvents(){if(eventAbort)eventAbort.abort();const controller=new AbortController();eventAbort=controller;let retry=1000;while(eventAbort===controller&&!controller.signal.aborted){try{const r=await fetch('/api/v1/events',{headers:{Authorization:'Bearer '+auth,Accept:'text/event-stream'},signal:controller.signal});if(!r.ok){const j=await r.json();throw Error(j.error||r.statusText)}if(!r.body||!r.body.getReader)throw Error('This browser does not support live updates');const reader=r.body.getReader(),decoder=new TextDecoder();let buffer='';retry=1000;while(true){const part=await reader.read();if(part.done)throw Error('Live update stream ended');buffer+=decoder.decode(part.value,{stream:true});let boundary;while((boundary=buffer.indexOf('\n\n'))>=0){const block=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);const payload=block.split('\n').filter(x=>x.startsWith('data:')).map(x=>x.slice(5).trimStart()).join('\n');if(payload)applySnapshot(JSON.parse(payload))}}}catch(e){if(controller.signal.aborted)return;showConnectionError(e);if(controller.signal.aborted)return;say('Live updates interrupted; reconnecting…');await new Promise(resolve=>setTimeout(resolve,retry));retry=Math.min(retry*2,10000)}}}
function renderDest(ds){const e=$('destination'),old=e.value,options=ds.map(d=>{const o=document.createElement('option');o.value=d.id;o.textContent=d.name+(d.available?'':' (offline)');o.disabled=!d.available;return o});if(!options.length){const o=document.createElement('option');o.value='';o.textContent='No destination configured';o.disabled=true;o.selected=true;options.push(o)}e.replaceChildren(...options);if([...e.options].some(o=>o.value===old&&!o.disabled))e.value=old;destinationRows=destinationRows.map(row=>{const live=ds.find(d=>d.id===row.id);return live?{...row,...live}:row});renderDestinationRows();updateStartState()}
function setHardwareBusy(busy){hardwareBusy=busy;for(const id of ['scanUnknownButton','refreshInventoryButton','rescanInventoryButton','selectAllButton','clearAllButton','carouselRefreshButton','startCarouselLoadButton','startCarouselUnloadButton'])$(id).disabled=busy;document.querySelectorAll('.slot input').forEach(x=>x.disabled=busy);if(carousel3D)carousel3D.updateInspector();updateStartState()}
function renderSlots(slots,busy){const selected=new Set([...document.querySelectorAll('.slot input:checked')].map(x=>+x.value)),loaded=slots.filter(s=>s.full||s.inDrive),unknown=slots.filter(s=>s.full&&!s.inDrive&&(s.discType||'').toLowerCase()==='unscanned').length;$('scanUnknownSummary').textContent=unknown?unknown+' unknown disc'+(unknown===1?' is':'s are')+' ready to identify.':'All loaded discs have been identified.';$('scanUnknownButton').textContent=unknown?'Scan '+unknown+' disc'+(unknown===1?'':'s'):'No unknown discs';$('scanUnknownButton').disabled=busy||unknown===0||!(latestState&&latestState.connected);if(!loaded.length){const empty=document.createElement('div');empty.className='empty-state';empty.textContent='No loaded discs found. Refresh inventory after loading a magazine.';$('slots').replaceChildren(empty)}else{$('slots').replaceChildren(...loaded.map(s=>{const d=document.createElement('label');d.className='slot full '+(s.backupStatus==='ripped'?'ripped':'');const i=document.createElement('input');i.type='checkbox';i.value=s.id;i.checked=selected.has(s.id);i.disabled=busy;i.onchange=updateStartState;const t=document.createElement('strong');t.textContent='Slot '+s.id;const m=document.createElement('small');m.className='muted';m.textContent=s.label||friendlyType(s.discType);d.append(i,t,document.createElement('br'),m);return d}))}setHardwareBusy(busy);$('scanUnknownButton').disabled=busy||unknown===0||!(latestState&&latestState.connected)}
function updateStartState(){const count=document.querySelectorAll('.slot input:checked').length,hasDestination=!!$('destination').value;$('start').disabled=hardwareBusy||!hasDestination||count===0;$('start').textContent=count?'Start batch · '+count+' disc'+(count===1?'':'s'):'Start batch rip';$('selectionSummary').textContent=count?count+' disc'+(count===1?'':'s')+' selected.':($('full').textContent==='0'?'No loaded discs found.':'Select one or more loaded slots.')}
function renderDestinationRows(){const body=$('destinationRows');body.replaceChildren(...destinationRows.map(d=>{const tr=document.createElement('tr'),name=document.createElement('td'),path=document.createElement('td'),status=document.createElement('td'),action=document.createElement('td'),remove=document.createElement('button');action.className='toolbar';name.textContent=d.name;path.textContent=d.location||d.remoteURL||d.path;status.textContent=d.available?(d.kind==='smb'?'Connected':'Available'):'Offline';status.className=d.available?'':'muted';if(d.kind==='smb'&&!d.available){const connect=document.createElement('button');connect.textContent='Connect';connect.onclick=()=>connectDestination(d.id);action.append(connect)}remove.textContent='Remove';remove.className='danger';remove.onclick=()=>removeDestination(d.id,d.name);action.append(remove);tr.append(name,path,status,action);return tr}));$('destinationHint').textContent=destinationRows.length?'Network shares reconnect automatically before a rip. If authentication fails, connect once in Finder and save the password in Keychain.':'Add a local folder or smb://server/share/folder to enable batch ripping.'}
async function addDestination(){const path=$('destinationPath').value.trim(),name=$('destinationName').value.trim();if(!path){say('Enter a local folder or SMB location');return}try{say(path.toLowerCase().startsWith('smb://')?'Connecting to the SMB share…':'Checking the destination…');const result=await api('/api/v1/destinations',{method:'POST',body:JSON.stringify({name,path})});destinationRows=result.destinations||[];renderDestinationRows();$('destinationName').value='';$('destinationPath').value='';const state=await api('/api/v1/state');applySnapshot({state});say('Rip destination saved')}catch(e){say(e.message)}}
async function connectDestination(id){try{say('Connecting to the SMB share…');const result=await api('/api/v1/destinations/connect',{method:'POST',body:JSON.stringify({id})});destinationRows=result.destinations||[];renderDestinationRows();const state=await api('/api/v1/state');applySnapshot({state});say('SMB destination connected')}catch(e){say(e.message)}}
async function removeDestination(id,name){if(!confirm('Remove the rip destination “'+name+'”?'))return;try{const result=await api('/api/v1/destinations/remove',{method:'POST',body:JSON.stringify({id})});destinationRows=result.destinations||[];renderDestinationRows();const state=await api('/api/v1/state');applySnapshot({state});say('Rip destination removed')}catch(e){say(e.message)}}
function renderJob(j){if(!j){$('jobPanel').classList.add('hidden');renderedJobId='';renderedDiscKey='';renderedDiscProgress=0;renderedOverallProgress=0;return}if(j.id!==renderedJobId){renderedJobId=j.id;renderedDiscKey='';renderedDiscProgress=0;renderedOverallProgress=0}const rip=j.kind==='rip',discKey=(j.slot||'')+'|'+(j.disc||'');if(discKey!==renderedDiscKey){renderedDiscKey=discKey;renderedDiscProgress=0}renderedDiscProgress=Math.max(renderedDiscProgress,Math.min(1,Number(j.currentDiscProgress)||0));const overallValue=j.overallProgress!=null?j.overallProgress:j.progress;renderedOverallProgress=Math.max(renderedOverallProgress,Math.min(1,Number(overallValue)||0));$('jobPanel').classList.remove('hidden');$('currentDiscStage').classList.toggle('hidden',!j.running);$('jobGrid').classList.toggle('finished',!j.running);currentJob=j.id;$('jobKind').textContent=rip?'Batch rip':'Disc scan';$('jobHeading').textContent=j.running?(rip?'Rip in progress':'Scan in progress'):(j.cancelled?'Cancelled':'Finished');$('currentDiscName').textContent=j.disc||(j.slot?'Slot '+j.slot:'Preparing disc…');$('currentDiscStatus').textContent=j.status||(rip?'Preparing current disc…':'Reading current disc…');$('currentDiscBar').style.width=Math.round(renderedDiscProgress*100)+'%';$('currentDiscPercent').textContent=Math.round(renderedDiscProgress*100)+'%';const transferred=Number(j.currentDiscTransferredBytes)||0,total=Number(j.currentDiscTotalBytes)||0,speed=Number(j.currentDiscSpeedBytesPerSecond)||0,metrics=[];if(total)metrics.push(bytes(transferred)+' of '+bytes(total));if(speed)metrics.push(bytes(speed)+'/s');$('currentDiscMetrics').textContent=metrics.join(' · ')||'Waiting for progress…';$('overallBar').style.width=Math.round(renderedOverallProgress*100)+'%';$('overallPercent').textContent=Math.round(renderedOverallProgress*100)+'%';const position=Number(j.position!=null?j.position:j.current)||0,finalizing=Number(j.finalizingDiscCount)||0;$('overallPosition').textContent=(position||0)+' of '+j.total+' discs';$('overallETA').textContent=finalizing&&!j.disc?'Finalizing '+finalizing+' saved DVD'+(finalizing===1?'':'s')+'…':(j.running&&j.overallETASeconds!=null?'About '+duration(j.overallETASeconds)+' remaining':(j.running?'Estimating time remaining…':j.status));$('cancelCurrentDiscButton').classList.toggle('hidden',!rip||!j.running);$('cancelCurrentDiscButton').disabled=!j.canCancelCurrentDisc;$('cancelAllButton').classList.toggle('hidden',!j.running);$('cancelAllButton').textContent=rip?'Cancel entire batch':'Cancel scan';const failures=j.failedSlots||[],cancelled=j.cancelledSlots||[],parts=[(j.completedSlots||[]).length+(rip?' completed':' cataloged')];if(rip)parts.push((j.skippedSlots||[]).length+' skipped',cancelled.length+' cancelled');if(finalizing)parts.push(finalizing+' finalizing');parts.push(failures.length+' failed');$('jobDetail').textContent=parts.join(' · ');const errors=$('jobErrors');errors.replaceChildren(...failures.map(f=>{const item=document.createElement('li');item.textContent=(f.slot?'Slot '+f.slot+': ':'')+f.error;return item}));errors.classList.toggle('hidden',failures.length===0);if(!j.running&&failures.length)say(j.status===failures[0].error?j.status:j.status+': '+failures[0].error)}
function renderOperation(o){if(!o){$('operationPanel').classList.add('hidden');return}$('operationStatus').textContent=o.status||'Changer operation in progress…';$('operationPanel').classList.remove('hidden')}
function renderRecovery(r){const panel=$('recoveryPanel');if(!r||!r.needed){panel.classList.add('hidden');return}$('recoveryStatus').textContent='Disc from slot '+r.slot+' is waiting in the drive';$('recoverDiscButton').disabled=!r.canReturn;panel.classList.remove('hidden')}
	function renderCarousel(s){const connected=!!s.connected,full=Number(s.fullSlots)||0,empty=Number(s.emptySlots)||0,unknown=Number(s.unknownSlots)||0,drive=s.drive||{state:'empty'},driveOccupied=drive.state!=='empty',job=s.carouselJob||null;$('carouselDevice').textContent=connected?s.device:'Changer offline';$('carouselSummary').textContent=full+' loaded · '+empty+' verified empty'+(unknown?' · '+unknown+' unknown':'');$('carouselFullCount').textContent=full;$('carouselEmptyCount').textContent=empty;$('carouselInventoryNote').textContent=unknown?unknown+' slots were not reported by the current hardware inventory. Run a full hardware rescan before loading them.':'';$('carouselLoadCount').max=Math.max(1,empty);if(Number($('carouselLoadCount').value)>empty&&empty>0)$('carouselLoadCount').value=empty;$('startCarouselLoadButton').disabled=hardwareBusy||!connected||empty===0||driveOccupied;$('startCarouselUnloadButton').disabled=hardwareBusy||!connected||full===0||driveOccupied;const warning=$('carouselDriveWarning');warning.classList.toggle('hidden',!driveOccupied);if(driveOccupied){const slot=drive.slot?' from slot '+drive.slot:'';$('carouselDriveDetail').textContent=drive.state==='loaded'?'A disc'+slot+' must be returned before a carousel operation.':'Wait for the current optical-drive operation to finish.';$('carouselReturnDriveButton').classList.toggle('hidden',drive.state!=='loaded'||!drive.slot);$('carouselReturnDriveButton').disabled=hardwareBusy||drive.state!=='loaded'||!drive.slot}updateCarousel3D(s);renderCarouselJob(job)}
function updateSlotActionControls(slot){const actions=new Set((slot&&slot.actions)||[]),buttons={load:$('slotLoadButton'),mount:$('slotMountButton'),unmount:$('slotUnmountButton'),eject:$('slotEjectButton')};for(const [action,button] of Object.entries(buttons)){button.disabled=!slot||hardwareBusy||!actions.has(action)}if(!slot){buttons.load.title=buttons.mount.title=buttons.unmount.title=buttons.eject.title='Select an occupied slot first';return}buttons.load.title=actions.has('load')?'Move this disc into the optical drive':'The drive must be empty and this disc must be stored';buttons.mount.title=actions.has('mount')?'Mount the disc currently in the optical drive':'Load and unmount this slot’s disc before mounting it';buttons.unmount.title=actions.has('unmount')?'Unmount this disc without returning it to the carousel':'Only the mounted optical-drive disc can be unmounted';buttons.eject.title=actions.has('eject')?'Present this disc at the I/E gate for removal':'Return the optical-drive disc and finish other operations first'}
async function performSelectedSlotAction(action){const view=ensureCarousel3D(),slot=view.slots.find(s=>s.id===view.selected);if(!slot){say('Select an occupied carousel slot first');return}if(action==='eject'){if(!confirm('Eject slot '+slot.id+' from the carousel? Remove it from the I/E gate when presented.'))return;try{setHardwareBusy(true);const j=await api('/api/v1/carousel/unload',{method:'POST',body:JSON.stringify({slots:[slot.id]})});currentCarousel={id:j.operationId};say('Presenting slot '+slot.id+' at the I/E gate…')}catch(e){setHardwareBusy(false);updateSlotActionControls(slot);say(e.message)}return}try{setHardwareBusy(true);await api('/api/v1/slots/action',{method:'POST',body:JSON.stringify({slot:slot.id,action})});const messages={load:'Loading slot '+slot.id+' into the optical drive…',mount:'Mounting slot '+slot.id+'…',unmount:'Unmounting slot '+slot.id+'…'};say(messages[action]||'Slot action accepted')}catch(e){setHardwareBusy(false);updateSlotActionControls(slot);say(e.message)}}
function renderCarouselJob(j){const panel=$('carouselJobPanel');if(!j){panel.classList.add('hidden');currentCarousel=null;return}currentCarousel=j;$('carouselJobMode').textContent=j.mode==='load'?'Bulk load':'Bulk unload';$('carouselJobStatus').textContent=j.status||'Preparing…';$('carouselBar').style.width=Math.round((Number(j.progress)||0)*100)+'%';const parts=[(j.current||0)+' of '+j.total];if(j.slot)parts.push('slot '+j.slot);parts.push((j.completedSlots||[]).length+' completed',(j.skippedSlots||[]).length+' skipped',(j.failures||[]).length+' issues');$('carouselJobDetail').textContent=parts.join(' · ');const allowed=new Set(j.allowedActions||[]);$('carouselContinueButton').classList.toggle('hidden',!allowed.has('continue'));$('carouselRetryButton').classList.toggle('hidden',!allowed.has('retry'));$('carouselSkipButton').classList.toggle('hidden',!allowed.has('skip'));$('carouselFinishButton').classList.toggle('hidden',!allowed.has('finish'));$('carouselCancelButton').classList.toggle('hidden',!j.running);panel.classList.remove('hidden')}
async function startCarouselLoad(){if(!latestState||!latestState.connected){say('Reconnect the changer first');return}const count=Number($('carouselLoadCount').value);if(!Number.isInteger(count)||count<1){say('Enter the number of discs to load');return}try{const j=await api('/api/v1/carousel/load',{method:'POST',body:JSON.stringify({count})});say('Bulk load started. Have disc 1 ready at the changer.');currentCarousel={id:j.operationId}}catch(e){say(e.message)}}
async function startCarouselUnload(){if(!confirm('Unload every carousel disc? Stay at the changer to remove each disc as it appears.'))return;try{const j=await api('/api/v1/carousel/unload',{method:'POST',body:'{}'});say('Bulk unload started. Remove each disc when presented.');currentCarousel={id:j.operationId}}catch(e){say(e.message)}}
async function carouselAction(action){try{await api('/api/v1/carousel/action',{method:'POST',body:JSON.stringify({id:currentCarousel&&currentCarousel.id,action})});say(action==='continue'?'Continuing to the next disc…':action.charAt(0).toUpperCase()+action.slice(1)+' requested')}catch(e){say(e.message)}}
async function returnCarouselDriveDisc(){try{$('carouselReturnDriveButton').disabled=true;say('Returning the optical-drive disc to its source slot…');await api('/api/v1/recovery/return-disc',{method:'POST'});}catch(e){$('carouselReturnDriveButton').disabled=false;say(e.message)}}
function artworkDataURL(buffer,contentType){const bytes=new Uint8Array(buffer);let binary='';for(let i=0;i<bytes.length;i+=32768)binary+=String.fromCharCode.apply(null,bytes.subarray(i,i+32768));return'data:'+(contentType||'image/jpeg')+';base64,'+btoa(binary)}
function artworkFailure(img,placeholder,message){img.remove();if(!placeholder.isConnected)return;placeholder.textContent='!';placeholder.title=message;placeholder.classList.add('error')}
async function loadArtwork(img,id,placeholder){try{let source=artworkObjects.get(id);if(!source){const response=await fetch('/api/v1/library/artwork/'+id,{headers:{Authorization:'Bearer '+auth}});if(!response.ok)throw Error(response.status===404?'Artwork is no longer available':'Artwork request failed ('+response.status+')');source=artworkDataURL(await response.arrayBuffer(),response.headers.get('content-type'));artworkObjects.set(id,source)}if(!placeholder.isConnected){img.remove();return}img.onload=()=>{if(!placeholder.isConnected){img.remove();return}img.classList.remove('pending');placeholder.replaceWith(img)};img.onerror=()=>artworkFailure(img,placeholder,'Artwork could not be decoded');img.src=source}catch(error){console.warn('Discbot artwork '+id+': '+error.message);artworkFailure(img,placeholder,error.message)}}
function artworkShape(discType,provider){return ((discType||'').toLowerCase().includes('dvd')||(provider||'').toLowerCase()==='tmdb')?'video':'audio'}
function updateArtworkShape(discType,provider){$('metadataArtworkPreview').classList.toggle('video',artworkShape(discType,provider)==='video')}
function renderLibrary(){const q=$('librarySearch').value.trim().toLowerCase(),rows=libraryRows.filter(r=>!q||(r.name+' '+(r.artist||'')+' '+(r.discType||'')+' '+r.fingerprint).toLowerCase().includes(q)).slice(0,100);if(!rows.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=6;td.className='empty-state';td.textContent=q?'No discs match your search.':'No discs have been cataloged yet.';tr.append(td);$('library').replaceChildren(tr);return}const artworkLoads=[],renderedRows=rows.map(r=>{const tr=document.createElement('tr'),art=document.createElement('td'),placeholder=document.createElement('span'),img=document.createElement('img'),name=document.createElement('td'),type=document.createElement('td'),meta=document.createElement('td'),rips=document.createElement('td'),action=document.createElement('td'),edit=document.createElement('button'),shape=artworkShape(r.discType,r.metadataSource);placeholder.className='cover-placeholder '+shape;placeholder.textContent='◉';placeholder.title=r.artworkAvailable?'Loading artwork…':'No artwork selected';img.className='cover '+shape+' pending';img.alt=r.name+' artwork';art.append(placeholder);if(r.artworkAvailable){art.append(img);artworkLoads.push(()=>loadArtwork(img,r.id,placeholder))}const title=document.createElement('strong');title.textContent=r.name;name.append(title);if(r.artist&&r.artist!=='Unknown'){const by=document.createElement('div');by.className='muted';by.textContent=r.artist;name.append(by)}type.textContent=friendlyType(r.discType);meta.textContent=[r.metadataSource,r.year,r.genre].filter(Boolean).join(' · ')||'Local';rips.textContent=r.availableImages+' available · '+r.ripAttempts+' attempts';edit.textContent=r.artworkAvailable?'Change artwork':'Choose artwork';edit.onclick=()=>openMetadataEditor(r);action.append(edit);tr.append(art,name,type,meta,rips,action);return tr});$('library').replaceChildren(...renderedRows);artworkLoads.forEach(start=>start())}
function applyMetadataConfig(c){$('audioProvider').value=c.audioProvider||'musicBrainz';$('videoProvider').value=c.videoProvider||'tmdb';$('tmdbToken').value='';$('tmdbToken').placeholder=c.tmdbConfigured?'TMDB token configured — enter a new value to replace it':'TMDB API Read Access Token';$('metadataConfigHint').textContent=c.tmdbConfigured?'TMDB is configured. New DVD matches can be selected or edited.':'MusicBrainz is ready. Add a TMDB API Read Access Token to search DVD metadata.'}
async function saveMetadataConfig(){const body={audioProvider:$('audioProvider').value,videoProvider:$('videoProvider').value};if($('tmdbToken').value.trim())body.tmdbToken=$('tmdbToken').value.trim();try{applyMetadataConfig(await api('/api/v1/metadata/config',{method:'POST',body:JSON.stringify(body)}));say('Metadata sources saved')}catch(e){say(e.message)}}
function openMetadataEditor(r){showTask('library');editingDisc=r;editingMetadata={provider:r.metadataSource||'manual',providerId:r.metadataProviderId||null,tracks:null};$('metadataTitle').value=r.name||'';$('metadataArtist').value=r.artist||'';$('metadataYear').value=r.year||'';$('metadataGenre').value=r.genre||'';$('metadataArtwork').value=r.artworkURL||'';$('metadataOverview').value=r.overview||'';$('metadataQuery').value=[r.name,r.artist].filter(Boolean).join(' ');$('metadataSearchProvider').value=(r.discType||'').toLowerCase().includes('audio')?'musicBrainz':'tmdb';updateArtworkShape(r.discType,r.metadataSource);$('metadataSourceLabel').textContent='Current source: '+(r.metadataSource||'local');$('metadataResults').replaceChildren();updateArtworkPreview(r.artworkURL||'',r.id);$('metadataEditor').classList.remove('hidden');$('metadataEditor').scrollIntoView({behavior:'smooth',block:'start'});if($('metadataQuery').value.trim())searchMetadata()}
function closeMetadataEditor(){$('metadataEditor').classList.add('hidden');editingDisc=null;editingMetadata=null}
async function searchMetadata(){if(!editingDisc)return;const query=$('metadataQuery').value.trim(),provider=$('metadataSearchProvider').value;if(!query){say('Enter a title or artist');return}say('Searching '+provider+'…');try{const data=await api('/api/v1/metadata/search',{method:'POST',body:JSON.stringify({provider,query})});renderMetadataResults(data.results||[]);say((data.results||[]).length?'Choose a match or edit the fields manually':'No matches found')}catch(e){say(e.message)}}
function renderMetadataResults(rows){$('metadataResults').replaceChildren(...rows.map(r=>{const b=document.createElement('button'),img=document.createElement('img'),text=document.createElement('span'),title=document.createElement('strong'),detail=document.createElement('small');b.className='result';b.dataset.candidateId=r.id;if(r.artworkURL){img.className='cover '+artworkShape(null,r.provider);img.src=r.artworkURL;img.alt=''}title.textContent=r.title;detail.className='muted';detail.textContent=[r.artist,r.year].filter(Boolean).join(' · ');text.append(title,document.createElement('br'),detail);if(r.artworkURL)b.append(img);b.append(text);b.onclick=()=>chooseMetadata(r);return b}))}
function updateArtworkPreview(url,discId){const img=$('metadataArtworkPreview');img.removeAttribute('src');if(discId&&artworkObjects.has(discId)){img.src=artworkObjects.get(discId)}else if(url){img.src=url}img.alt=url?'Selected artwork preview':'No artwork selected'}
function chooseMetadata(r){editingMetadata=r;$('metadataTitle').value=r.title||'';$('metadataArtist').value=r.artist||'';$('metadataYear').value=r.year||'';$('metadataGenre').value=r.genre||'';$('metadataArtwork').value=r.artworkURL||'';$('metadataOverview').value=r.overview||'';updateArtworkShape(null,r.provider);updateArtworkPreview(r.artworkURL||'');document.querySelectorAll('.result').forEach(b=>b.classList.toggle('selected',b.dataset.candidateId===r.id));$('metadataSourceLabel').textContent='Selected from '+r.provider+' — fields remain editable'}
async function saveMetadata(){if(!editingDisc)return;const body={discId:editingDisc.id,title:$('metadataTitle').value.trim(),artist:$('metadataArtist').value.trim()||'Unknown',year:$('metadataYear').value.trim()||null,genre:$('metadataGenre').value.trim()||null,overview:$('metadataOverview').value.trim()||null,artworkURL:$('metadataArtwork').value.trim()||null,provider:(editingMetadata&&editingMetadata.provider)||'manual',providerId:editingMetadata&&editingMetadata.providerId,tracks:editingMetadata&&editingMetadata.tracks};if(!body.title){say('Title is required');return}try{await api('/api/v1/metadata/update',{method:'POST',body:JSON.stringify(body)});artworkObjects.delete(editingDisc.id);applySnapshot({library:await api('/api/v1/library')});closeMetadataEditor();say('Metadata and artwork saved to the library')}catch(e){say(e.message)}}
function renderActivity(rows){const recent=(rows||[]).slice(0,100);if(!recent.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=3;td.className='empty-state';td.textContent='No activity recorded yet.';tr.append(td);$('activity').replaceChildren(tr);return}$('activity').replaceChildren(...recent.map(r=>{const tr=document.createElement('tr'),when=document.createElement('td'),type=document.createElement('td'),detail=document.createElement('td'),badge=document.createElement('span'),failed=(r.type||'').includes('failed')||(r.type||'').includes('error');when.textContent=localTime(r.at);when.className='muted';badge.className='activity-type'+(failed?' failure':'');badge.textContent=(r.type||'event').split('_').join(' ');type.append(badge);detail.textContent=(r.slot?'Slot '+r.slot+' · ':'')+r.message;tr.append(when,type,detail);return tr}))}
function selectAll(){document.querySelectorAll('.slot input:not(:disabled)').forEach(x=>x.checked=true);updateStartState()}function clearAll(){document.querySelectorAll('.slot input').forEach(x=>x.checked=false);updateStartState()}
async function startScanUnknown(){try{const j=await api('/api/v1/jobs/scan',{method:'POST',body:'{}'});currentJob=j.jobId;say('Disc scan started. Each disc will be returned to its original slot.')}catch(e){say(e.message)}}
async function startRip(){const slots=[...document.querySelectorAll('.slot input:checked')].map(x=>+x.value);if(!slots.length){say('Select at least one slot');return}if(!$('destination').value){say('Add and select a rip destination first');return}try{const j=await api('/api/v1/jobs/rip',{method:'POST',body:JSON.stringify({slots,destinationId:$('destination').value,duplicatePolicy:$('policy').value,outputMode:$('outputMode').value})});currentJob=j.jobId;say('Rip queue accepted')}catch(e){say(e.message)}}
async function cancelCurrentDisc(){const name=$('currentDiscName').textContent||'the current disc';if(!confirm('Cancel ripping '+name+'?\n\nThe partial image will be removed, the disc will be returned safely, and the batch will continue with the next disc.'))return;try{$('cancelCurrentDiscButton').disabled=true;await api('/api/v1/jobs/cancel-current',{method:'POST',body:JSON.stringify({id:currentJob})});say('Cancelling this disc and returning it safely…')}catch(e){$('cancelCurrentDiscButton').disabled=false;say(e.message)}}async function cancelAll(){const rip=latestState&&latestState.job&&latestState.job.kind==='rip',message=rip?'Cancel the entire batch?\n\nThe current partial image will be removed and the loaded disc will be returned safely. Remaining discs will not be ripped.':'Cancel this scan?\n\nThe current disc will be returned safely before the scan stops.';if(!confirm(message))return;try{$('cancelAllButton').disabled=true;await api('/api/v1/jobs/cancel',{method:'POST',body:JSON.stringify({id:currentJob})});say('Cancelling everything after a safe disc return…')}catch(e){$('cancelAllButton').disabled=false;say(e.message)}}async function refreshInventory(){try{setHardwareBusy(true);renderOperation({status:'Reading changer inventory…'});await api('/api/v1/inventory/refresh',{method:'POST'});say('Refresh requested')}catch(e){setHardwareBusy(false);renderOperation(null);say(e.message)}}async function rescanInventory(){if(!confirm('Physically rescan all changer elements? This can take several minutes.'))return;try{setHardwareBusy(true);renderOperation({status:'Starting full inventory rescan…'});await api('/api/v1/inventory/rescan',{method:'POST'});say('Full inventory rescan started…')}catch(e){setHardwareBusy(false);renderOperation(null);say(e.message)}}
async function returnLoadedDisc(){try{$('recoverDiscButton').disabled=true;say('Returning the disc after verified recovery…');await api('/api/v1/recovery/return-disc',{method:'POST'});}catch(e){$('recoverDiscButton').disabled=false;say(e.message)}}
const saved=sessionStorage.getItem('discbotToken');if(saved){$('token').value=saved;connect()}
</script></body></html>
"""#
}
