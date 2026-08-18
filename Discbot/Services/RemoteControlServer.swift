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

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    }

    var url: URL { URL(fileURLWithPath: path).standardizedFileURL }
    var isAvailable: Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && directory.boolValue
            && FileManager.default.isWritableFile(atPath: path)
    }
}

struct RemoteAPIError: LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? { message }
}

protocol RemoteControlProviding: AnyObject {
    func remoteState() -> [String: Any]
    func remoteLibrary() -> [String: Any]
    func startRemoteRip(slots: [Int], destination: RemoteRipDestination, policy: DuplicatePolicy) -> Result<String, RemoteAPIError>
    func cancelRemoteJob(id: String?) -> Result<Void, RemoteAPIError>
    func refreshRemoteInventory() -> Result<Void, RemoteAPIError>
    func rescanRemoteInventory() -> Result<Void, RemoteAPIError>
    func returnLoadedDisc() -> Result<Void, RemoteAPIError>
    func startRemoteCarouselLoad(count: Int?, slots: [Int]?) -> Result<String, RemoteAPIError>
    func startRemoteCarouselUnload(slots: [Int]?) -> Result<String, RemoteAPIError>
    func controlRemoteCarousel(id: String?, action: CarouselBatchAction) -> Result<Void, RemoteAPIError>
    func metadataConfiguration() -> [String: Any]
    func configureMetadata(audioProvider: String?, videoProvider: String?, tmdbToken: String?)
    func searchMetadata(provider: MetadataProvider, query: String) -> [MetadataCandidate]
    func updateMetadata(discId: Int64, metadata: DiscMetadata) -> Result<Void, RemoteAPIError>
}

final class ChangerRemoteControlAdapter: RemoteControlProviding {
    private weak var viewModel: ChangerViewModel?
    private var activeJobId: String?

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
                if let label = slot.volumeLabel { value["label"] = label }
                return value
            }
            var result: [String: Any] = [
                "available": true,
                "connected": viewModel.isConnected,
                "connection": self.connectionState(viewModel),
                "device": viewModel.deviceDescription,
                "busy": viewModel.isHardwareBusy,
                "fullSlots": viewModel.fullSlotCount,
                "emptySlots": viewModel.emptySlotCount,
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
        let statistics = viewModel.catalogService.getStatistics()
        let entries = viewModel.catalogService.getCatalogEntries().map { entry -> [String: Any] in
            var value: [String: Any] = [
                "id": entry.id,
                "name": entry.disc.displayName,
                "fingerprint": entry.disc.fingerprint,
                "identityReliable": entry.disc.hasReliableIdentity,
                "sightings": entry.sightings.count,
                "ripAttempts": entry.rips.count,
                "availableImages": entry.existingRips.count
            ]
            if let type = entry.disc.discType { value["discType"] = type }
            if let path = entry.latestExistingRip?.backupPath { value["latestPath"] = path }
            if let artist = entry.disc.artist { value["artist"] = artist }
            if let year = entry.disc.year { value["year"] = year }
            if let genre = entry.disc.genre { value["genre"] = genre }
            if let provider = entry.disc.metadataSource { value["metadataSource"] = provider }
            if let providerID = entry.disc.metadataProviderID { value["metadataProviderId"] = providerID }
            if let overview = entry.disc.metadataOverview { value["overview"] = overview }
            if let artworkURL = entry.disc.artworkURL { value["artworkURL"] = artworkURL }
            value["metadataUserEdited"] = entry.disc.metadataUserEdited
            return value
        }
        let activity = viewModel.catalogService.getRecentRipLog(limit: 100).map { event -> [String: Any] in
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

    func startRemoteRip(
        slots: [Int],
        destination: RemoteRipDestination,
        policy: DuplicatePolicy
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
            viewModel.startBatchImaging(outputDirectory: destination.url, duplicatePolicy: policy)
            guard viewModel.currentOperation == .batchImaging else {
                return .failure(RemoteAPIError(status: 500, message: "The rip queue did not start"))
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

            let empty = viewModel.slots.filter { !$0.isFull && !$0.isInDrive }.map(\.id)
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
        var value: [String: Any] = [
            "running": state.isRunning,
            "cancelled": state.isCancelled,
            "paused": state.isPaused,
            "current": state.currentIndex,
            "total": state.totalCount,
            "slot": state.currentSlot,
            "progress": state.progress,
            "status": state.statusText,
            "completedSlots": state.completedSlots,
            "replacedSlots": state.replacedSlots,
            "failedSlots": state.failedSlots.map { ["slot": $0.slot, "error": $0.error] },
            "skippedSlots": state.skippedSlots.map { ["slot": $0.slot, "path": $0.existingPath] }
        ]
        if let id = id { value["id"] = id }
        if let name = state.currentDiscName { value["disc"] = name }
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

    init(
        control: RemoteControlProviding,
        token: @escaping () -> String,
        destinations: @escaping () -> [RemoteRipDestination],
        updateDestinations: @escaping ([RemoteRipDestination]) -> Void,
        destinationRoots: @escaping () -> [URL] = {
            [FileManager.default.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Volumes", isDirectory: true)]
        }
    ) {
        self.control = control
        self.token = token
        self.destinations = destinations
        self.updateDestinations = updateDestinations
        self.destinationRoots = destinationRoots
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
        case ("POST", "/api/v1/destinations/remove"):
            return removeDestination(request)
        case ("POST", "/api/v1/inventory/refresh"):
            return result(control.refreshRemoteInventory()) { .json(status: 202, ["accepted": true]) }
        case ("POST", "/api/v1/inventory/rescan"):
            return result(control.rescanRemoteInventory()) { .json(status: 202, ["accepted": true]) }
        case ("POST", "/api/v1/recovery/return-disc"):
            return result(control.returnLoadedDisc()) { .json(status: 202, ["accepted": true]) }
        case ("POST", "/api/v1/carousel/load"):
            return startCarouselLoad(request)
        case ("POST", "/api/v1/carousel/unload"):
            return startCarouselUnload(request)
        case ("POST", "/api/v1/carousel/action"):
            return controlCarousel(request)
        case ("POST", "/api/v1/jobs/rip"):
            return startRip(request)
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
            ["id": $0.id.uuidString, "name": $0.name, "available": $0.isAvailable]
        }
        return state
    }

    func librarySnapshot() -> [String: Any] {
        control.remoteLibrary()
    }

    private func destinationDetails() -> [[String: Any]] {
        destinations().map {
            [
                "id": $0.id.uuidString,
                "name": $0.name,
                "path": $0.path,
                "available": $0.isAvailable
            ]
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
              let destination = destinations().first(where: { $0.id == uuid }) else {
            return .json(status: 422, ["error": "slots and a configured destinationId are required"])
        }
        let slots = rawSlots.compactMap { ($0 as? NSNumber)?.intValue }
        guard slots.count == rawSlots.count else {
            return .json(status: 422, ["error": "Every slot must be an integer"])
        }
        let rawPolicy = object["duplicatePolicy"] as? String ?? DuplicatePolicy.skipExisting.rawValue
        guard let policy = DuplicatePolicy(rawValue: rawPolicy) else {
            return .json(status: 422, ["error": "Unknown duplicate policy"])
        }
        return result(control.startRemoteRip(slots: slots, destination: destination, policy: policy)) {
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
        guard trimmedPath.hasPrefix("/") else {
            return .json(status: 422, ["error": "Destination must be an absolute path"])
        }

        let url = URL(fileURLWithPath: trimmedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowed = destinationRoots().contains { root in
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            return url.path == rootPath || url.path.hasPrefix(rootPath + "/")
        }
        guard allowed else {
            return .json(status: 403, ["error": "Destinations must be inside the user's home folder or /Volumes"])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .json(status: 422, ["error": "That folder does not exist on the Discbot Mac"])
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return .json(status: 422, ["error": "That folder is not writable by Discbot"])
        }

        let requestedName = (object["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    func start(port: UInt16) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RemoteAPIError(status: 500, message: "Invalid server port")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Catalina can otherwise create an IPv6-only wildcard listener, excluding
        // older LAN clients. Explicitly constrain the IP stack to IPv4.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.service = NWListener.Service(name: ProcessInfo.processInfo.hostName, type: "_discbot._tcp")
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.publish("Listening on port \(port)")
            case .failed(let error):
                self?.publish("Server failed: \(error.localizedDescription)")
                self?.stop()
            case .cancelled:
                self?.publish("Server stopped")
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        startEventTimer()
    }

    func stop() {
        eventTimer?.cancel()
        eventTimer = nil
        eventConnections.values.forEach { $0.cancel() }
        eventConnections.removeAll()
        lastStateSnapshot = nil
        lastLibrarySnapshot = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
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
            if buffer.count > 1024 * 1024 {
                self.send(.json(status: 413, ["error": "Request too large"]), on: connection)
                return
            }
            if let expected = self.expectedRequestLength(buffer), buffer.count >= expected,
               let request = RemoteHTTPRequest.parse(buffer) {
                if request.method == "GET" && request.path == "/api/v1/events" {
                    if self.controller.isAuthorized(request) {
                        self.beginEventStream(on: connection)
                    } else {
                        self.send(.json(status: 401, ["error": "Invalid or missing bearer token"]), on: connection)
                    }
                } else {
                    self.send(self.controller.response(to: request), on: connection)
                }
            } else if complete || error != nil {
                self.send(.json(status: 400, ["error": "Malformed request"]), on: connection)
            } else {
                self.receive(connection, accumulated: buffer)
            }
        }
    }

    private func expectedRequestLength(_ data: Data) -> Int? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        var length = 0
        for line in head.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"), let value = Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) {
                length = max(0, value)
            }
        }
        return range.upperBound + length
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
        var events = Data()
        if let state = controller.stateEventData() {
            events.append(eventData(state))
            lastStateSnapshot = state
        }
        if let library = controller.libraryEventData() {
            events.append(eventData(library))
            lastLibrarySnapshot = library
            lastLibraryCheck = Date()
        }
        lastEventWrite = Date()
        var response = Data(header.utf8)
        response.append(chunk(events))
        sendRawEventData(response, id: id, connection: connection)
    }

    private func publishEventSnapshotIfNeeded() {
        guard !eventConnections.isEmpty else { return }
        var wroteEvent = false
        if let state = controller.stateEventData(), state != lastStateSnapshot {
            lastStateSnapshot = state
            lastEventWrite = Date()
            broadcast(eventData(state))
            wroteEvent = true
        }
        if Date().timeIntervalSince(lastLibraryCheck) >= 2 {
            lastLibraryCheck = Date()
            if let library = controller.libraryEventData(), library != lastLibrarySnapshot {
                lastLibrarySnapshot = library
                lastEventWrite = Date()
                broadcast(eventData(library))
                wroteEvent = true
            }
        }
        if !wroteEvent && Date().timeIntervalSince(lastEventWrite) >= 15 {
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
:root{color-scheme:dark;--bg:#080d14;--panel:#121a25;--panel2:#182230;--line:#29374a;--text:#f2f6fb;--muted:#94a2b6;--blue:#69a9ff;--blue2:#183e6d;--green:#51d393;--red:#ff7883;--amber:#f0bd62}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;line-height:1.45}header{position:sticky;top:0;z-index:5;min-height:64px;padding:10px max(18px,calc((100vw - 1180px)/2));background:#080d14ed;border-bottom:1px solid var(--line);backdrop-filter:blur(18px);display:flex;align-items:center;gap:18px}.brand{display:flex;align-items:center;gap:9px;white-space:nowrap}.brand-mark{width:18px;height:18px;border:2px solid var(--text);border-radius:50%;box-shadow:inset 0 0 0 4px var(--bg)}h1{font-size:20px;margin:0}h2{font-size:21px;margin:0}h3{font-size:15px;margin:0}.task-nav{display:flex;align-items:center;gap:4px}.task-nav button{background:transparent;border-color:transparent;color:var(--muted);font-weight:600}.task-nav button.active{background:var(--panel2);border-color:var(--line);color:var(--text)}.header-state{display:flex;align-items:center;gap:12px;margin-left:auto;min-width:0}.connection-dot{width:8px;height:8px;border-radius:50%;background:var(--green);display:inline-block;margin-right:6px}.header-message{color:var(--muted);max-width:340px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}main{max-width:1180px;margin:auto;padding:28px 20px 56px}.task-view{display:none}.task-view.active{display:block}.page-heading{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;margin-bottom:20px}.page-heading p{margin:5px 0 0}.eyebrow{color:var(--blue);font-size:12px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}.card,.panel{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px}.card b{display:block;font-size:25px;margin-top:4px}.muted{color:var(--muted)}button,select,input,textarea{border:1px solid var(--line);border-radius:9px;background:#202c3d;color:var(--text);padding:10px 13px;font:inherit}input,select{min-height:42px}textarea{width:100%;min-height:86px;resize:vertical}button{cursor:pointer}button:hover:not(:disabled){border-color:#49617e}button.primary{background:var(--blue);border-color:var(--blue);color:#07101d;font-weight:800}button.secondary{background:transparent}button.danger{color:var(--red)}button:disabled{opacity:.45;cursor:not-allowed}.toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.grow{flex:1;min-width:260px}.panel{margin-top:16px}.workflow{padding:0;overflow:hidden}.step{display:grid;grid-template-columns:38px minmax(0,1fr);gap:14px;padding:20px;border-bottom:1px solid var(--line)}.step:last-child{border-bottom:0}.step-number{width:30px;height:30px;display:grid;place-items:center;border-radius:50%;background:var(--blue2);color:#bcd8ff;font-weight:800}.step-content>p{margin:4px 0 14px}.choice-grid{display:grid;grid-template-columns:minmax(180px,1fr) minmax(180px,1fr);gap:12px}.choice label{display:block;color:var(--muted);font-size:12px;font-weight:700;margin-bottom:6px;text-transform:uppercase;letter-spacing:.05em}.choice select{width:100%}.selection-line{display:flex;align-items:center;gap:10px;margin-bottom:12px}.slots{display:grid;grid-template-columns:repeat(auto-fill,minmax(92px,1fr));gap:8px}.slot{position:relative;padding:12px 7px;text-align:center;border:1px solid var(--line);border-radius:10px;background:#0d141e}.slot.full{border-color:#425b78}.slot.ripped{border-color:#386c5a}.slot.ripped:after{content:"Ripped";display:block;color:var(--green);font-size:11px;font-weight:700;margin-top:4px}.slot input{display:block;margin:0 auto 7px}.status-strip{display:flex;align-items:center;gap:10px;margin-bottom:14px;padding:12px 15px;border:1px solid var(--line);border-radius:12px;background:#0d141e}.status-strip strong{white-space:nowrap}.status-strip .muted{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.progress{height:9px;background:#263246;border-radius:9px;overflow:hidden}.progress i{display:block;height:100%;background:var(--blue);width:0}.progress.indeterminate i{width:35%;animation:scan 1.35s ease-in-out infinite}@keyframes scan{0%{transform:translateX(-110%)}100%{transform:translateX(300%)}}.hidden{display:none!important}.right{margin-left:auto}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:11px 9px;border-bottom:1px solid var(--line);vertical-align:middle}th{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.05em}.cover{width:42px;height:58px;object-fit:cover;border-radius:6px;background:#202b3b}.metadata-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.metadata-grid .wide{grid-column:1/-1}.results{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:9px;margin-top:12px}.result{display:flex;gap:9px;text-align:left;align-items:flex-start}.result .cover{width:54px;height:74px;flex:none}.credit{font-size:12px;margin-top:12px}.activity-type{display:inline-block;padding:3px 8px;border-radius:999px;background:var(--panel2);font-size:12px}.empty-state{text-align:center;padding:28px;color:var(--muted)}details.tools{margin-top:14px;border-top:1px solid var(--line);padding-top:14px}details.tools summary{cursor:pointer;color:var(--muted);font-weight:600}.settings-group+.settings-group{margin-top:24px;padding-top:24px;border-top:1px solid var(--line)}@media(max-width:760px){header{align-items:flex-start;flex-wrap:wrap;padding:12px 14px}.task-nav{order:3;width:100%;overflow:auto}.task-nav button{flex:1}.header-message{display:none}main{padding:20px 14px}.page-heading{align-items:flex-start;flex-direction:column}.choice-grid{grid-template-columns:1fr}.step{grid-template-columns:30px minmax(0,1fr);padding:16px 14px}.right{margin-left:0}.grow{min-width:100%}.metadata-grid{grid-template-columns:1fr}.table-wrap{margin:0 -18px;padding:0 18px}}
.task-nav button{white-space:nowrap}.guide-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px}.guide-card{margin-top:0}.guide-card h2{margin-bottom:5px}.guide-card .count{font-size:34px;font-weight:800;line-height:1;margin:18px 0 4px}.guide-steps{margin:16px 0;padding-left:22px}.guide-steps li{margin:10px 0}.callout{padding:13px 15px;border:1px solid #66512b;border-radius:10px;background:#241d12;color:#f7d999}.guide-actions{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-top:16px}@media(max-width:760px){.guide-grid{grid-template-columns:1fr}}
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
<section id="jobPanel" class="panel hidden" aria-live="polite"><div class="toolbar"><strong id="jobStatus">Preparing…</strong><button id="cancelJobButton" class="danger right" onclick="cancelJob()">Cancel safely</button></div><div class="progress" style="margin-top:12px"><i id="bar"></i></div><p id="jobDetail" class="muted" style="margin-bottom:0"></p></section>
<section class="panel workflow">
<div class="step"><span class="step-number">1</span><div class="step-content"><h3>Choose discs</h3><p id="selectionSummary" class="muted">Select one or more loaded slots.</p><div class="selection-line"><button id="selectAllButton" onclick="selectAll()">Select all loaded</button><button id="clearAllButton" class="secondary" onclick="clearAll()">Clear</button></div><div id="slots" class="slots"></div><details class="tools"><summary>Changer tools</summary><div class="toolbar" style="margin-top:12px"><button id="refreshInventoryButton" onclick="refreshInventory()">Refresh inventory</button><button id="rescanInventoryButton" class="danger" onclick="rescanInventory()" title="Physically rescan all changer elements; this can take several minutes">Full hardware rescan</button></div></details></div></div>
<div class="step"><span class="step-number">2</span><div class="step-content"><h3>Choose destination and duplicate behavior</h3><p class="muted">Verified existing rips can be skipped automatically.</p><div class="choice-grid"><div class="choice"><label for="destination">Save to</label><select id="destination" onchange="updateStartState()" aria-label="Rip destination"></select></div><div class="choice"><label for="policy">If already ripped</label><select id="policy" aria-label="Duplicate policy"><option value="skipExisting">Skip verified copy</option><option value="replaceExisting">Replace existing copy</option><option value="imageAgain">Keep both copies</option></select></div></div></div></div>
<div class="step"><span class="step-number">3</span><div class="step-content"><h3>Start batch</h3><p class="muted">Discbot will load, identify, rip or skip, and safely return every selected disc.</p><button id="start" class="primary" onclick="startRip()">Start batch rip</button></div></div>
</section></section>
<section class="task-view" data-task="carousel"><div class="page-heading"><div><span class="eyebrow">Task 2</span><h2>Load or unload the carousel</h2><p class="muted">Discbot opens the Sony XL1B gate for each disc and verifies every move.</p></div><button id="carouselRefreshButton" onclick="refreshInventory()">Refresh inventory</button></div>
<div class="status-strip"><span class="connection-dot"></span><strong id="carouselDevice">—</strong><span id="carouselSummary" class="muted">Reading carousel…</span></div>
<section class="guide-grid">
<article class="panel guide-card"><span class="eyebrow">Software bulk load</span><div id="carouselEmptyCount" class="count">0</div><p class="muted">empty slots available</p><p>Choose a count. Discbot uses the next empty slots and opens the gate once per disc.</p><div class="guide-actions"><input id="carouselLoadCount" type="number" min="1" value="3" style="width:92px" aria-label="Number of discs to load"><button id="startCarouselLoadButton" class="primary" onclick="startCarouselLoad()">Start loading</button></div></article>
<article class="panel guide-card"><span class="eyebrow">Software bulk unload</span><div id="carouselFullCount" class="count">0</div><p class="muted">carousel discs loaded</p><p>Discbot presents every stored disc and waits for you to remove it before continuing.</p><button id="startCarouselUnloadButton" class="primary" onclick="startCarouselUnload()">Unload all carousel discs</button></article>
</section>
<section id="carouselDriveWarning" class="panel hidden"><div class="toolbar"><div><strong>A disc is still inside the optical drive</strong><p id="carouselDriveDetail" class="muted" style="margin-bottom:0">Sony’s bulk eject mode only unloads carousel slots.</p></div><button id="carouselReturnDriveButton" class="primary right" onclick="returnCarouselDriveDisc()">Return drive disc first</button></div></section>
<section id="carouselJobPanel" class="panel hidden" aria-live="polite"><div class="toolbar"><div><span id="carouselJobMode" class="eyebrow">Carousel operation</span><h2 id="carouselJobStatus">Preparing…</h2></div><button id="carouselCancelButton" class="danger right" onclick="carouselAction('cancel')">Cancel safely</button></div><div class="progress" style="margin-top:14px"><i id="carouselBar"></i></div><p id="carouselJobDetail" class="muted"></p><div id="carouselActions" class="guide-actions"><button id="carouselContinueButton" class="primary hidden" onclick="carouselAction('continue')">Disc removed — continue</button><button id="carouselRetryButton" class="primary hidden" onclick="carouselAction('retry')">Retry this slot</button><button id="carouselSkipButton" class="secondary hidden" onclick="carouselAction('skip')">Skip this slot</button><button id="carouselFinishButton" class="secondary hidden" onclick="carouselAction('finish')">Finish now</button></div></section>
<p class="credit muted">The gate command is verified on this changer. A missing disc is treated as an operator timeout, never as a power-cycle fault.</p></section>
<section class="task-view" data-task="library"><div class="page-heading"><div><span class="eyebrow">Task 3</span><h2>Browse library</h2><p class="muted">Find every disc Discbot has seen and manage its metadata.</p></div><input id="librarySearch" type="search" placeholder="Search discs" oninput="renderLibrary()"></div><section class="grid"><div class="card"><span class="muted">Available images</span><b id="images">0</b></div><div class="card"><span class="muted">Storage used</span><b id="stored">0 B</b></div></section>
<section id="metadataEditor" class="panel hidden"><div class="toolbar"><h2>Edit metadata</h2><button class="right" onclick="closeMetadataEditor()">Close</button></div><div class="toolbar" style="margin-top:14px"><select id="metadataSearchProvider"><option value="musicBrainz">MusicBrainz</option><option value="tmdb">TMDB</option></select><input id="metadataQuery" class="grow" placeholder="Search title or artist"><button onclick="searchMetadata()">Search</button></div><div id="metadataResults" class="results"></div><div class="metadata-grid" style="margin-top:14px"><input id="metadataTitle" placeholder="Title / album"><input id="metadataArtist" placeholder="Artist / media kind"><input id="metadataYear" placeholder="Year"><input id="metadataGenre" placeholder="Genre"><input id="metadataArtwork" class="wide" placeholder="Artwork URL"><textarea id="metadataOverview" class="wide" placeholder="Description or notes"></textarea></div><div class="toolbar" style="margin-top:10px"><button class="primary" onclick="saveMetadata()">Save metadata</button><span id="metadataSourceLabel" class="muted"></span></div></section>
<section class="panel"><div class="table-wrap"><table><thead><tr><th></th><th>Disc</th><th>Type</th><th>Metadata</th><th>Rips</th><th></th></tr></thead><tbody id="library"></tbody></table></div></section></section>
<section class="task-view" data-task="activity"><div class="page-heading"><div><span class="eyebrow">Task 4</span><h2>Review activity</h2><p class="muted">See recent ripping, skipping, and recovery events.</p></div></div><section class="panel"><div class="table-wrap"><table><thead><tr><th>When</th><th>Result</th><th>Details</th></tr></thead><tbody id="activity"></tbody></table></div></section></section>
<section class="task-view" data-task="settings"><div class="page-heading"><div><span class="eyebrow">Task 5</span><h2>Configure Discbot</h2><p class="muted">Manage storage locations and online metadata services.</p></div></div><section class="panel"><div class="settings-group"><h2>Rip destinations</h2><p class="muted">Add an existing writable folder on this Mac or an attached volume.</p><div class="toolbar"><input id="destinationName" placeholder="Name (optional)"><input id="destinationPath" class="grow" placeholder="Folder path, e.g. /Users/jackson/Discbot"><button onclick="addDestination()">Add destination</button></div><p id="destinationHint" class="muted"></p><div class="table-wrap"><table><tbody id="destinationRows"></tbody></table></div></div>
<div class="settings-group"><h2>Metadata sources</h2><p class="muted">Choose where audio CD and DVD details come from.</p><div class="choice-grid"><div class="choice"><label for="audioProvider">Audio CDs</label><select id="audioProvider"><option value="musicBrainz">MusicBrainz + Cover Art Archive</option><option value="none">Local/manual only</option></select></div><div class="choice"><label for="videoProvider">DVDs</label><select id="videoProvider"><option value="tmdb">TMDB</option><option value="none">Local/manual only</option></select></div></div><div class="toolbar" style="margin-top:12px"><input id="tmdbToken" class="grow" type="password" placeholder="TMDB API Read Access Token"><button onclick="saveMetadataConfig()">Save metadata settings</button></div><p id="metadataConfigHint" class="muted"></p><p class="credit muted">Music metadata and artwork can come from MusicBrainz and the Cover Art Archive. This product uses the <a href="https://www.themoviedb.org" target="_blank" rel="noreferrer">TMDB API</a> but is not endorsed or certified by TMDB.</p></div></section></section>
</div></main><script>
let auth='',eventAbort=null,currentJob=null,currentCarousel=null,libraryRows=[],destinationRows=[],hardwareBusy=false,editingDisc=null,editingMetadata=null,activeTask='rip',latestState=null;const $=id=>document.getElementById(id);function say(v){$('message').textContent=v||''}function bytes(v){let n=Number(v)||0,u=['B','KB','MB','GB','TB'],i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return (i?n.toFixed(n<10?1:0):n.toFixed(0))+' '+u[i]}function showTask(name){activeTask=name;document.querySelectorAll('.task-view').forEach(v=>v.classList.toggle('active',v.dataset.task===name));document.querySelectorAll('[data-task-target]').forEach(b=>b.classList.toggle('active',b.dataset.taskTarget===name));sessionStorage.setItem('discbotTask',name);window.scrollTo({top:0,behavior:'smooth'})}function setConnectionLabel(text,online){const dot=document.createElement('span');dot.className='connection-dot';if(!online)dot.style.background='var(--red)';$('connection').replaceChildren(dot,document.createTextNode(text))}function friendlyType(v){const x=(v||'').toLowerCase();if(x.includes('audio'))return'Audio CD';if(x.includes('dvd'))return'DVD';if(x.includes('data'))return'Data disc';return v||'Unknown'}function localTime(v){const d=new Date(v);return isNaN(d)?v:d.toLocaleString([], {dateStyle:'medium',timeStyle:'short'})}
async function api(path,opt={}){opt.headers={...(opt.headers||{}),Authorization:'Bearer '+auth};if(opt.body)opt.headers['Content-Type']='application/json';const r=await fetch(path,opt);const j=await r.json();if(!r.ok)throw Error(j.error||r.statusText);return j}
async function connect(){auth=$('token').value.trim();sessionStorage.setItem('discbotToken',auth);try{const [s,l,d,m]=await Promise.all([api('/api/v1/state'),api('/api/v1/library'),api('/api/v1/destinations'),api('/api/v1/metadata/config')]);applySnapshot({state:s,library:l,destinations:d.destinations,metadataConfig:m});$('login').classList.add('hidden');$('app').classList.remove('hidden');$('taskNav').classList.remove('hidden');showTask(sessionStorage.getItem('discbotTask')||'rip');startEvents()}catch(e){showConnectionError(e)}}
function applySnapshot(v){if(v.destinations){destinationRows=v.destinations;renderDestinationRows()}if(v.metadataConfig)applyMetadataConfig(v.metadataConfig);if(v.state){const s=v.state,c=s.connection||{};latestState=s;setConnectionLabel(s.connected?s.device+' · Live':(c.label||'Changer offline'),s.connected);$('device').textContent=s.connected?s.device:(c.requiresPowerCycle?'Power cycle required':'Not connected');$('full').textContent=s.fullSlots;renderDest(s.destinations||[]);renderSlots(s.slots,s.busy);renderCarousel(s);renderJob(s.job);renderOperation(s.operation);renderRecovery(s.recovery);const retry=c.retryInSeconds!=null?' Retrying in '+c.retryInSeconds+'s.':'';if(s.error||retry)say((s.error||'')+retry);else if(!s.operation&&s.notice)say(s.notice)}if(v.library){const l=v.library;$('images').textContent=l.statistics.availableImages;$('stored').textContent=bytes(l.statistics.storedBytes);libraryRows=l.entries||[];renderLibrary();renderActivity(l.activity)}}
function showConnectionError(e){say(e.message);if(e.message.toLowerCase().includes('token')){if(eventAbort)eventAbort.abort();setConnectionLabel('Disconnected',false);$('taskNav').classList.add('hidden');$('login').classList.remove('hidden');$('app').classList.add('hidden')}}
async function startEvents(){if(eventAbort)eventAbort.abort();const controller=new AbortController();eventAbort=controller;let retry=1000;while(eventAbort===controller&&!controller.signal.aborted){try{const r=await fetch('/api/v1/events',{headers:{Authorization:'Bearer '+auth,Accept:'text/event-stream'},signal:controller.signal});if(!r.ok){const j=await r.json();throw Error(j.error||r.statusText)}if(!r.body||!r.body.getReader)throw Error('This browser does not support live updates');const reader=r.body.getReader(),decoder=new TextDecoder();let buffer='';retry=1000;while(true){const part=await reader.read();if(part.done)throw Error('Live update stream ended');buffer+=decoder.decode(part.value,{stream:true});let boundary;while((boundary=buffer.indexOf('\n\n'))>=0){const block=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);const payload=block.split('\n').filter(x=>x.startsWith('data:')).map(x=>x.slice(5).trimStart()).join('\n');if(payload)applySnapshot(JSON.parse(payload))}}}catch(e){if(controller.signal.aborted)return;showConnectionError(e);if(controller.signal.aborted)return;say('Live updates interrupted; reconnecting…');await new Promise(resolve=>setTimeout(resolve,retry));retry=Math.min(retry*2,10000)}}}
function renderDest(ds){const e=$('destination'),old=e.value,options=ds.map(d=>{const o=document.createElement('option');o.value=d.id;o.textContent=d.name+(d.available?'':' (offline)');o.disabled=!d.available;return o});if(!options.length){const o=document.createElement('option');o.value='';o.textContent='No destination configured';o.disabled=true;o.selected=true;options.push(o)}e.replaceChildren(...options);if([...e.options].some(o=>o.value===old&&!o.disabled))e.value=old;destinationRows=destinationRows.map(row=>{const live=ds.find(d=>d.id===row.id);return live?{...row,available:live.available}:row});renderDestinationRows();updateStartState()}
function setHardwareBusy(busy){hardwareBusy=busy;for(const id of ['refreshInventoryButton','rescanInventoryButton','selectAllButton','clearAllButton','carouselRefreshButton','startCarouselLoadButton','startCarouselUnloadButton'])$(id).disabled=busy;document.querySelectorAll('.slot input').forEach(x=>x.disabled=busy);updateStartState()}
function renderSlots(slots,busy){const selected=new Set([...document.querySelectorAll('.slot input:checked')].map(x=>+x.value)),loaded=slots.filter(s=>s.full||s.inDrive);if(!loaded.length){const empty=document.createElement('div');empty.className='empty-state';empty.textContent='No loaded discs found. Refresh inventory after loading a magazine.';$('slots').replaceChildren(empty)}else{$('slots').replaceChildren(...loaded.map(s=>{const d=document.createElement('label');d.className='slot full '+(s.backupStatus==='ripped'?'ripped':'');const i=document.createElement('input');i.type='checkbox';i.value=s.id;i.checked=selected.has(s.id);i.disabled=busy;i.onchange=updateStartState;const t=document.createElement('strong');t.textContent='Slot '+s.id;const m=document.createElement('small');m.className='muted';m.textContent=s.label||friendlyType(s.discType);d.append(i,t,document.createElement('br'),m);return d}))}setHardwareBusy(busy)}
function updateStartState(){const count=document.querySelectorAll('.slot input:checked').length,hasDestination=!!$('destination').value;$('start').disabled=hardwareBusy||!hasDestination||count===0;$('start').textContent=count?'Start batch · '+count+' disc'+(count===1?'':'s'):'Start batch rip';$('selectionSummary').textContent=count?count+' disc'+(count===1?'':'s')+' selected.':($('full').textContent==='0'?'No loaded discs found.':'Select one or more loaded slots.')}
function renderDestinationRows(){const body=$('destinationRows');body.replaceChildren(...destinationRows.map(d=>{const tr=document.createElement('tr'),name=document.createElement('td'),path=document.createElement('td'),status=document.createElement('td'),action=document.createElement('td'),remove=document.createElement('button');name.textContent=d.name;path.textContent=d.path;status.textContent=d.available?'Available':'Offline';status.className=d.available?'':'muted';remove.textContent='Remove';remove.className='danger';remove.onclick=()=>removeDestination(d.id,d.name);action.append(remove);tr.append(name,path,status,action);return tr}));$('destinationHint').textContent=destinationRows.length?'Only existing writable folders in your home directory or /Volumes are allowed.':'No rip destinations configured. Add a folder below to enable batch ripping.'}
async function addDestination(){const path=$('destinationPath').value.trim(),name=$('destinationName').value.trim();if(!path){say('Enter a folder path on the Discbot Mac');return}try{const result=await api('/api/v1/destinations',{method:'POST',body:JSON.stringify({name,path})});destinationRows=result.destinations||[];renderDestinationRows();$('destinationName').value='';$('destinationPath').value='';const state=await api('/api/v1/state');applySnapshot({state});say('Rip destination saved')}catch(e){say(e.message)}}
async function removeDestination(id,name){if(!confirm('Remove the rip destination “'+name+'”?'))return;try{const result=await api('/api/v1/destinations/remove',{method:'POST',body:JSON.stringify({id})});destinationRows=result.destinations||[];renderDestinationRows();const state=await api('/api/v1/state');applySnapshot({state});say('Rip destination removed')}catch(e){say(e.message)}}
function renderJob(j){if(!j){$('jobPanel').classList.add('hidden');return}$('jobPanel').classList.remove('hidden');currentJob=j.id;$('jobStatus').textContent=j.status||'Preparing batch…';$('bar').style.width=Math.round(j.progress*100)+'%';$('cancelJobButton').classList.toggle('hidden',!j.running);const parts=[j.current+' of '+j.total];if(j.slot)parts.push('slot '+j.slot);parts.push(j.completedSlots.length+' completed',j.skippedSlots.length+' skipped',j.failedSlots.length+' failed');$('jobDetail').textContent=parts.join(' · ')}
function renderOperation(o){if(!o){$('operationPanel').classList.add('hidden');return}$('operationStatus').textContent=o.status||'Changer operation in progress…';$('operationPanel').classList.remove('hidden')}
function renderRecovery(r){const panel=$('recoveryPanel');if(!r||!r.needed){panel.classList.add('hidden');return}$('recoveryStatus').textContent='Disc from slot '+r.slot+' is waiting in the drive';$('recoverDiscButton').disabled=!r.canReturn;panel.classList.remove('hidden')}
function renderCarousel(s){const connected=!!s.connected,full=Number(s.fullSlots)||0,empty=Number(s.emptySlots)||0,drive=s.drive||{state:'empty'},driveOccupied=drive.state!=='empty',job=s.carouselJob||null;$('carouselDevice').textContent=connected?s.device:'Changer offline';$('carouselSummary').textContent=full+' loaded · '+empty+' empty';$('carouselFullCount').textContent=full;$('carouselEmptyCount').textContent=empty;$('carouselLoadCount').max=Math.max(1,empty);if(Number($('carouselLoadCount').value)>empty&&empty>0)$('carouselLoadCount').value=empty;$('startCarouselLoadButton').disabled=hardwareBusy||!connected||empty===0||driveOccupied;$('startCarouselUnloadButton').disabled=hardwareBusy||!connected||full===0||driveOccupied;const warning=$('carouselDriveWarning');warning.classList.toggle('hidden',!driveOccupied);if(driveOccupied){const slot=drive.slot?' from slot '+drive.slot:'';$('carouselDriveDetail').textContent=drive.state==='loaded'?'A disc'+slot+' must be returned before a carousel operation.':'Wait for the current optical-drive operation to finish.';$('carouselReturnDriveButton').classList.toggle('hidden',drive.state!=='loaded'||!drive.slot);$('carouselReturnDriveButton').disabled=hardwareBusy||drive.state!=='loaded'||!drive.slot}renderCarouselJob(job)}
function renderCarouselJob(j){const panel=$('carouselJobPanel');if(!j){panel.classList.add('hidden');currentCarousel=null;return}currentCarousel=j;$('carouselJobMode').textContent=j.mode==='load'?'Bulk load':'Bulk unload';$('carouselJobStatus').textContent=j.status||'Preparing…';$('carouselBar').style.width=Math.round((Number(j.progress)||0)*100)+'%';const parts=[(j.current||0)+' of '+j.total];if(j.slot)parts.push('slot '+j.slot);parts.push((j.completedSlots||[]).length+' completed',(j.skippedSlots||[]).length+' skipped',(j.failures||[]).length+' issues');$('carouselJobDetail').textContent=parts.join(' · ');const allowed=new Set(j.allowedActions||[]);$('carouselContinueButton').classList.toggle('hidden',!allowed.has('continue'));$('carouselRetryButton').classList.toggle('hidden',!allowed.has('retry'));$('carouselSkipButton').classList.toggle('hidden',!allowed.has('skip'));$('carouselFinishButton').classList.toggle('hidden',!allowed.has('finish'));$('carouselCancelButton').classList.toggle('hidden',!j.running);panel.classList.remove('hidden')}
async function startCarouselLoad(){if(!latestState||!latestState.connected){say('Reconnect the changer first');return}const count=Number($('carouselLoadCount').value);if(!Number.isInteger(count)||count<1){say('Enter the number of discs to load');return}try{const j=await api('/api/v1/carousel/load',{method:'POST',body:JSON.stringify({count})});say('Bulk load started. Have disc 1 ready at the changer.');currentCarousel={id:j.operationId}}catch(e){say(e.message)}}
async function startCarouselUnload(){if(!confirm('Unload every carousel disc? Stay at the changer to remove each disc as it appears.'))return;try{const j=await api('/api/v1/carousel/unload',{method:'POST',body:'{}'});say('Bulk unload started. Remove each disc when presented.');currentCarousel={id:j.operationId}}catch(e){say(e.message)}}
async function carouselAction(action){try{await api('/api/v1/carousel/action',{method:'POST',body:JSON.stringify({id:currentCarousel&&currentCarousel.id,action})});say(action==='continue'?'Continuing to the next disc…':action.charAt(0).toUpperCase()+action.slice(1)+' requested')}catch(e){say(e.message)}}
async function returnCarouselDriveDisc(){try{$('carouselReturnDriveButton').disabled=true;say('Returning the optical-drive disc to its source slot…');await api('/api/v1/recovery/return-disc',{method:'POST'});}catch(e){$('carouselReturnDriveButton').disabled=false;say(e.message)}}
function renderLibrary(){const q=$('librarySearch').value.trim().toLowerCase(),rows=libraryRows.filter(r=>!q||(r.name+' '+(r.artist||'')+' '+(r.discType||'')+' '+r.fingerprint).toLowerCase().includes(q)).slice(0,100);if(!rows.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=6;td.className='empty-state';td.textContent=q?'No discs match your search.':'No discs have been cataloged yet.';tr.append(td);$('library').replaceChildren(tr);return}$('library').replaceChildren(...rows.map(r=>{const tr=document.createElement('tr'),art=document.createElement('td'),name=document.createElement('td'),type=document.createElement('td'),meta=document.createElement('td'),rips=document.createElement('td'),action=document.createElement('td'),edit=document.createElement('button');if(r.artworkURL){const img=document.createElement('img');img.className='cover';img.src=r.artworkURL;img.alt='';img.loading='lazy';art.append(img)}const title=document.createElement('strong');title.textContent=r.name;name.append(title);if(r.artist&&r.artist!=='Unknown'){const by=document.createElement('div');by.className='muted';by.textContent=r.artist;name.append(by)}type.textContent=friendlyType(r.discType);meta.textContent=[r.metadataSource,r.year,r.genre].filter(Boolean).join(' · ')||'Local';rips.textContent=r.availableImages+' available · '+r.ripAttempts+' attempts';edit.textContent='Edit';edit.onclick=()=>openMetadataEditor(r);action.append(edit);tr.append(art,name,type,meta,rips,action);return tr}))}
function applyMetadataConfig(c){$('audioProvider').value=c.audioProvider||'musicBrainz';$('videoProvider').value=c.videoProvider||'tmdb';$('tmdbToken').value='';$('tmdbToken').placeholder=c.tmdbConfigured?'TMDB token configured — enter a new value to replace it':'TMDB API Read Access Token';$('metadataConfigHint').textContent=c.tmdbConfigured?'TMDB is configured. New DVD matches can be selected or edited.':'MusicBrainz is ready. Add a TMDB API Read Access Token to search DVD metadata.'}
async function saveMetadataConfig(){const body={audioProvider:$('audioProvider').value,videoProvider:$('videoProvider').value};if($('tmdbToken').value.trim())body.tmdbToken=$('tmdbToken').value.trim();try{applyMetadataConfig(await api('/api/v1/metadata/config',{method:'POST',body:JSON.stringify(body)}));say('Metadata sources saved')}catch(e){say(e.message)}}
function openMetadataEditor(r){showTask('library');editingDisc=r;editingMetadata={provider:r.metadataSource||'manual',providerId:r.metadataProviderId||null,tracks:null};$('metadataTitle').value=r.name||'';$('metadataArtist').value=r.artist||'';$('metadataYear').value=r.year||'';$('metadataGenre').value=r.genre||'';$('metadataArtwork').value=r.artworkURL||'';$('metadataOverview').value=r.overview||'';$('metadataQuery').value=[r.name,r.artist].filter(Boolean).join(' ');$('metadataSearchProvider').value=(r.discType||'').toLowerCase().includes('audio')?'musicBrainz':'tmdb';$('metadataSourceLabel').textContent='Current source: '+(r.metadataSource||'local');$('metadataResults').replaceChildren();$('metadataEditor').classList.remove('hidden');$('metadataEditor').scrollIntoView({behavior:'smooth',block:'start'})}
function closeMetadataEditor(){$('metadataEditor').classList.add('hidden');editingDisc=null;editingMetadata=null}
async function searchMetadata(){if(!editingDisc)return;const query=$('metadataQuery').value.trim(),provider=$('metadataSearchProvider').value;if(!query){say('Enter a title or artist');return}say('Searching '+provider+'…');try{const data=await api('/api/v1/metadata/search',{method:'POST',body:JSON.stringify({provider,query})});renderMetadataResults(data.results||[]);say((data.results||[]).length?'Choose a match or edit the fields manually':'No matches found')}catch(e){say(e.message)}}
function renderMetadataResults(rows){$('metadataResults').replaceChildren(...rows.map(r=>{const b=document.createElement('button'),img=document.createElement('img'),text=document.createElement('span'),title=document.createElement('strong'),detail=document.createElement('small');b.className='result';if(r.artworkURL){img.className='cover';img.src=r.artworkURL;img.alt=''}title.textContent=r.title;detail.className='muted';detail.textContent=[r.artist,r.year].filter(Boolean).join(' · ');text.append(title,document.createElement('br'),detail);if(r.artworkURL)b.append(img);b.append(text);b.onclick=()=>chooseMetadata(r);return b}))}
function chooseMetadata(r){editingMetadata=r;$('metadataTitle').value=r.title||'';$('metadataArtist').value=r.artist||'';$('metadataYear').value=r.year||'';$('metadataGenre').value=r.genre||'';$('metadataArtwork').value=r.artworkURL||'';$('metadataOverview').value=r.overview||'';$('metadataSourceLabel').textContent='Selected from '+r.provider+' — fields remain editable'}
async function saveMetadata(){if(!editingDisc)return;const body={discId:editingDisc.id,title:$('metadataTitle').value.trim(),artist:$('metadataArtist').value.trim()||'Unknown',year:$('metadataYear').value.trim()||null,genre:$('metadataGenre').value.trim()||null,overview:$('metadataOverview').value.trim()||null,artworkURL:$('metadataArtwork').value.trim()||null,provider:(editingMetadata&&editingMetadata.provider)||'manual',providerId:editingMetadata&&editingMetadata.providerId,tracks:editingMetadata&&editingMetadata.tracks};if(!body.title){say('Title is required');return}try{await api('/api/v1/metadata/update',{method:'POST',body:JSON.stringify(body)});applySnapshot({library:await api('/api/v1/library')});closeMetadataEditor();say('Metadata saved and rip sidecars updated')}catch(e){say(e.message)}}
function renderActivity(rows){const recent=(rows||[]).slice(0,50);if(!recent.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=3;td.className='empty-state';td.textContent='No activity recorded yet.';tr.append(td);$('activity').replaceChildren(tr);return}$('activity').replaceChildren(...recent.map(r=>{const tr=document.createElement('tr'),when=document.createElement('td'),type=document.createElement('td'),detail=document.createElement('td'),badge=document.createElement('span');when.textContent=localTime(r.at);when.className='muted';badge.className='activity-type';badge.textContent=r.type;type.append(badge);detail.textContent=(r.slot?'Slot '+r.slot+' · ':'')+r.message;tr.append(when,type,detail);return tr}))}
function selectAll(){document.querySelectorAll('.slot input:not(:disabled)').forEach(x=>x.checked=true);updateStartState()}function clearAll(){document.querySelectorAll('.slot input').forEach(x=>x.checked=false);updateStartState()}
async function startRip(){const slots=[...document.querySelectorAll('.slot input:checked')].map(x=>+x.value);if(!slots.length){say('Select at least one slot');return}if(!$('destination').value){say('Add and select a rip destination first');return}try{const j=await api('/api/v1/jobs/rip',{method:'POST',body:JSON.stringify({slots,destinationId:$('destination').value,duplicatePolicy:$('policy').value})});currentJob=j.jobId;say('Rip queue accepted')}catch(e){say(e.message)}}
async function cancelJob(){try{await api('/api/v1/jobs/cancel',{method:'POST',body:JSON.stringify({id:currentJob})});say('Cancelling after safe return…')}catch(e){say(e.message)}}async function refreshInventory(){try{setHardwareBusy(true);renderOperation({status:'Reading changer inventory…'});await api('/api/v1/inventory/refresh',{method:'POST'});say('Refresh requested')}catch(e){setHardwareBusy(false);renderOperation(null);say(e.message)}}async function rescanInventory(){if(!confirm('Physically rescan all changer elements? This can take several minutes.'))return;try{setHardwareBusy(true);renderOperation({status:'Starting full inventory rescan…'});await api('/api/v1/inventory/rescan',{method:'POST'});say('Full inventory rescan started…')}catch(e){setHardwareBusy(false);renderOperation(null);say(e.message)}}
async function returnLoadedDisc(){try{$('recoverDiscButton').disabled=true;say('Returning the disc after verified recovery…');await api('/api/v1/recovery/return-disc',{method:'POST'});}catch(e){$('recoverDiscButton').disabled=false;say(e.message)}}
const saved=sessionStorage.getItem('discbotToken');if(saved){$('token').value=saved;connect()}
</script></body></html>
"""#
}
