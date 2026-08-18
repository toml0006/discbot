//
//  RawCDImageService.swift
//  Discbot
//
//  Lossless CDDA and single-session mixed-mode BIN/CUE imaging
//

import Foundation
import Darwin

struct CDTrackLayout: Equatable {
    enum SectorMode: String, Equatable {
        case audio = "AUDIO"
        case mode1 = "MODE1/2352"
        case mode2 = "MODE2/2352"
    }

    let number: Int
    let session: Int
    let control: UInt8
    let startLBA: UInt32
    var sectorMode: SectorMode

    var isData: Bool { (control & 0x04) != 0 }
}

struct CDDiscLayout: Equatable {
    var tracks: [CDTrackLayout]
    let leadoutLBA: UInt32

    var firstLBA: UInt32 { tracks.first?.startLBA ?? 0 }
    var sectorCount: UInt32 { leadoutLBA > firstLBA ? leadoutLBA - firstLBA : 0 }
}

protocol RawCDSectorReading: AnyObject {
    var layout: CDDiscLayout { get }
    func resolveDataTrackModes() throws
    func read(startLBA: UInt32, sectorCount: UInt32) throws -> Data
}

final class NativeRawCDReader: RawCDSectorReading {
    private let handle: OpaquePointer
    private(set) var layout: CDDiscLayout

    init(bsdName: String) throws {
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let opened = bsdName.withCString { name in
            discbot_cd_reader_open(name, &errorBuffer, errorBuffer.count)
        }
        guard let opened = opened else {
            let message = String(cString: errorBuffer)
            throw ImagingError.processFailed(-1, message.isEmpty ? "Could not open the raw CD reader" : message)
        }
        handle = opened

        let count = Int(discbot_cd_reader_track_count(opened))
        var tracks: [CDTrackLayout] = []
        tracks.reserveCapacity(count)
        for index in 0..<count {
            let rawIndex = UInt32(index)
            let control = discbot_cd_reader_track_control(opened, rawIndex)
            tracks.append(CDTrackLayout(
                number: Int(discbot_cd_reader_track_number(opened, rawIndex)),
                session: Int(discbot_cd_reader_track_session(opened, rawIndex)),
                control: control,
                startLBA: discbot_cd_reader_track_start_lba(opened, rawIndex),
                sectorMode: (control & 0x04) == 0 ? .audio : .mode1
            ))
        }
        layout = CDDiscLayout(
            tracks: tracks,
            leadoutLBA: discbot_cd_reader_leadout_lba(opened)
        )
    }

    deinit {
        discbot_cd_reader_close(handle)
    }

    func resolveDataTrackModes() throws {
        for index in layout.tracks.indices where layout.tracks[index].isData {
            let sector = try read(startLBA: layout.tracks[index].startLBA, sectorCount: 1)
            guard sector.count == Int(DISCBOT_CD_SECTOR_SIZE), sector.count > 15 else {
                throw ImagingError.processFailed(-1, "Could not inspect data track \(layout.tracks[index].number)")
            }
            switch sector[15] {
            case 1: layout.tracks[index].sectorMode = .mode1
            case 2: layout.tracks[index].sectorMode = .mode2
            default:
                throw ImagingError.unsupportedDiscType(
                    "Data track \(layout.tracks[index].number) has an unknown raw sector format"
                )
            }
        }
    }

    func read(startLBA: UInt32, sectorCount: UInt32) throws -> Data {
        let byteCount = Int(sectorCount) * Int(DISCBOT_CD_SECTOR_SIZE)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var completed: UInt32 = 0
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let result = bytes.withUnsafeMutableBytes { buffer in
            discbot_cd_reader_read(
                handle,
                startLBA,
                sectorCount,
                buffer.baseAddress,
                &completed,
                &errorBuffer,
                errorBuffer.count
            )
        }
        guard result == 0, completed > 0 else {
            let message = String(cString: errorBuffer)
            throw ImagingError.processFailed(-1, message.isEmpty ? "Raw CD read failed at sector \(startLBA)" : message)
        }
        return Data(bytes.prefix(Int(completed) * Int(DISCBOT_CD_SECTOR_SIZE)))
    }
}

enum RawCDImageService {
    static let sectorSize = Int64(DISCBOT_CD_SECTOR_SIZE)

    static func detectDiscType(bsdName: String) -> DiscType? {
        guard let reader = try? NativeRawCDReader(bsdName: bsdName) else { return nil }
        let dataTrackCount = reader.layout.tracks.filter(\.isData).count
        if dataTrackCount == 0 { return .audioCDDA }
        if dataTrackCount == reader.layout.tracks.count { return .dataCD }
        return .mixedModeCD
    }

    static func createImage(
        bsdName: String,
        outputPath: URL,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        if control?.isCancelled == true { throw ImagingError.cancelled }

        let reader = try NativeRawCDReader(bsdName: bsdName)
        return try createImage(
            reader: reader,
            outputPath: outputPath,
            control: control,
            progress: progress
        )
    }

    static func createImage(
        reader: RawCDSectorReading,
        outputPath: URL,
        control: ImagingService.ImagingControl?,
        progress: @escaping (ImagingProgressInfo) -> Void
    ) throws -> URL {
        if control?.isCancelled == true { throw ImagingError.cancelled }
        guard !reader.layout.tracks.isEmpty, reader.layout.sectorCount > 0 else {
            throw ImagingError.discNotReady
        }
        let sessions = Set(reader.layout.tracks.map(\.session))
        guard sessions.count == 1 else {
            throw ImagingError.unsupportedDiscType(
                "Multi-session mixed-mode CDs are not yet safe to store as one BIN/CUE image"
            )
        }
        try reader.resolveDataTrackModes()

        let outputBase = outputPath.deletingPathExtension()
        let binURL = outputBase.appendingPathExtension("bin")
        let cueURL = outputBase.appendingPathExtension("cue")
        let partialURL = outputBase.appendingPathExtension("partial")
        let cuePartialURL = outputBase.appendingPathExtension("cue.partial")
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: binURL.path),
              !fileManager.fileExists(atPath: cueURL.path) else {
            throw ImagingError.writeFailed(outputBase)
        }
        for url in [partialURL, cuePartialURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard fileManager.createFile(atPath: partialURL.path, contents: nil),
              let stream = OutputStream(url: partialURL, append: false) else {
            throw ImagingError.writeFailed(partialURL)
        }

        var completed = false
        var createdBin = false
        var createdCue = false
        stream.open()
        defer {
            stream.close()
            if !completed {
                try? fileManager.removeItem(at: partialURL)
                try? fileManager.removeItem(at: cuePartialURL)
                if createdBin { try? fileManager.removeItem(at: binURL) }
                if createdCue { try? fileManager.removeItem(at: cueURL) }
            }
        }

        let totalBytes = Int64(reader.layout.sectorCount) * sectorSize
        let startedAt = Date()
        var currentLBA = reader.layout.firstLBA
        var transferred: Int64 = 0

        while currentLBA < reader.layout.leadoutLBA {
            if control?.isCancelled == true { throw ImagingError.cancelled }
            let remaining = reader.layout.leadoutLBA - currentLBA
            let requested = min(remaining, 16)
            let data: Data
            do {
                data = try reader.read(startLBA: currentLBA, sectorCount: requested)
            } catch {
                // A drive may reject a multi-sector request around a marginal
                // sector even though individual retries succeed.
                if requested == 1 { throw error }
                var recovered = Data()
                recovered.reserveCapacity(Int(requested) * Int(DISCBOT_CD_SECTOR_SIZE))
                for offset in 0..<requested {
                    if control?.isCancelled == true { throw ImagingError.cancelled }
                    recovered.append(try reader.read(startLBA: currentLBA + offset, sectorCount: 1))
                }
                data = recovered
            }

            try write(data, to: stream, destination: partialURL)
            let sectorsRead = UInt32(data.count / Int(DISCBOT_CD_SECTOR_SIZE))
            guard sectorsRead > 0 else { throw ImagingError.readFailed(EIO) }
            currentLBA += sectorsRead
            transferred += Int64(data.count)

            let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
            let speed = Double(transferred) / elapsed
            progress(ImagingProgressInfo(
                fractionCompleted: min(Double(transferred) / Double(totalBytes), 1),
                bytesTransferred: transferred,
                totalBytes: totalBytes,
                speedBytesPerSecond: speed,
                etaSeconds: speed > 0 ? Double(totalBytes - transferred) / speed : nil
            ))
        }

        stream.close()
        if control?.isCancelled == true { throw ImagingError.cancelled }
        try fileManager.moveItem(at: partialURL, to: binURL)
        createdBin = true

        let cue = cueSheet(binFileName: binURL.lastPathComponent, layout: reader.layout)
        try cue.write(to: cuePartialURL, atomically: true, encoding: .utf8)
        try fileManager.moveItem(at: cuePartialURL, to: cueURL)
        createdCue = true

        completed = true
        progress(ImagingProgressInfo(
            fractionCompleted: 1,
            bytesTransferred: totalBytes,
            totalBytes: totalBytes,
            speedBytesPerSecond: Double(totalBytes) / max(Date().timeIntervalSince(startedAt), 0.001),
            etaSeconds: 0
        ))
        return binURL
    }

    static func cueSheet(binFileName: String, layout: CDDiscLayout) -> String {
        var lines = ["FILE \"\(binFileName)\" BINARY"]
        for track in layout.tracks {
            lines.append(String(format: "  TRACK %02d %@", track.number, track.sectorMode.rawValue))
            var flags: [String] = []
            if (track.control & 0x01) != 0 { flags.append("PRE") }
            if (track.control & 0x02) != 0 { flags.append("DCP") }
            if (track.control & 0x08) != 0 { flags.append("4CH") }
            if !flags.isEmpty { lines.append("    FLAGS \(flags.joined(separator: " "))") }
            let relativeLBA = track.startLBA >= layout.firstLBA ? track.startLBA - layout.firstLBA : 0
            lines.append("    INDEX 01 \(cueTime(relativeLBA))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cueTime(_ sectors: UInt32) -> String {
        let minutes = sectors / (75 * 60)
        let seconds = (sectors / 75) % 60
        let frames = sectors % 75
        return String(format: "%02u:%02u:%02u", minutes, seconds, frames)
    }

    private static func write(_ data: Data, to stream: OutputStream, destination: URL) throws {
        var offset = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            while offset < data.count {
                let written = stream.write(base.advanced(by: offset), maxLength: data.count - offset)
                guard written > 0 else { throw ImagingError.writeFailed(destination) }
                offset += written
            }
        }
    }
}
