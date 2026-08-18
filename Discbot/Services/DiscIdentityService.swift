//
//  DiscIdentityService.swift
//  Discbot
//
//  Stable identities used to recognize a disc across slots and sessions
//

import Foundation
import CommonCrypto

struct DiscIdentity: Equatable {
    let fingerprint: String
    let kind: String
    /// 2 = safe for automatic duplicate skipping, 1 = catalog correlation only.
    let confidence: Int
}

protocol DiscIdentifying: AnyObject {
    func identify(
        bsdName: String,
        discType: DiscType,
        volumeLabel: String?,
        sizeBytes: Int64?
    ) -> DiscIdentity
}

final class DiscIdentityService: DiscIdentifying {
    private let sampleSize = 64 * 1024

    func identify(
        bsdName: String,
        discType: DiscType,
        volumeLabel: String?,
        sizeBytes: Int64?
    ) -> DiscIdentity {
        // Mock media deliberately repeats every twenty slots. Treat identical mock
        // metadata as the same physical disc so duplicate handling is testable.
        if bsdName.hasPrefix("mockdisk") {
            let material = "mock-v1|\(discType.catalogString)|\(sizeBytes ?? -1)|\(volumeLabel ?? "")"
            return DiscIdentity(fingerprint: sha256(Data(material.utf8)), kind: "mock-v1", confidence: 2)
        }

        if (discType == .audioCDDA || discType == .mixedModeCD),
           let toc = cdTOCFingerprint(bsdName: bsdName) {
            return DiscIdentity(fingerprint: toc, kind: "cd-toc-v1", confidence: 2)
        }

        if let sampled = sampledFingerprint(
            bsdName: bsdName,
            discType: discType,
            sizeBytes: sizeBytes
        ) {
            return DiscIdentity(fingerprint: sampled, kind: "sampled-content-v1", confidence: 2)
        }

        if let stableIdentifier = stableMediaIdentifier(bsdName: bsdName) {
            let material = "media-id-v1|\(discType.catalogString)|\(sizeBytes ?? -1)|\(stableIdentifier)"
            return DiscIdentity(fingerprint: sha256(Data(material.utf8)), kind: "media-uuid-v1", confidence: 2)
        }

        // Labels and sizes are useful for catalog grouping but are not unique
        // enough to silently skip a rip.
        let material = "metadata-v1|\(discType.catalogString)|\(sizeBytes ?? -1)|\(volumeLabel ?? "")"
        return DiscIdentity(fingerprint: sha256(Data(material.utf8)), kind: "metadata-v1", confidence: 1)
    }

    private func sampledFingerprint(
        bsdName: String,
        discType: DiscType,
        sizeBytes: Int64?
    ) -> String? {
        guard let sizeBytes = sizeBytes, sizeBytes > Int64(sampleSize) else { return nil }

        let rawURL = URL(fileURLWithPath: "/dev/r\(bsdName)")
        let blockURL = URL(fileURLWithPath: "/dev/\(bsdName)")
        let handle: FileHandle
        if let rawHandle = try? FileHandle(forReadingFrom: rawURL) {
            handle = rawHandle
        } else if let blockHandle = try? FileHandle(forReadingFrom: blockURL) {
            handle = blockHandle
        } else {
            return nil
        }
        defer { handle.closeFile() }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        updateHash(&context, data: Data("sampled-content-v1|\(discType.catalogString)|\(sizeBytes)".utf8))

        let lastStart = max(sizeBytes - Int64(sampleSize), 0)
        let rawOffsets: [Int64] = [0, sizeBytes / 4, sizeBytes / 2, (sizeBytes * 3) / 4, lastStart]
        let offsets = Array(Set(rawOffsets.map { max(0, min($0, lastStart)) / 2048 * 2048 })).sorted()

        for offset in offsets {
            handle.seek(toFileOffset: UInt64(offset))
            let data = handle.readData(ofLength: sampleSize)
            guard !data.isEmpty else { return nil }
            updateHash(&context, data: Data("|\(offset)|\(data.count)|".utf8))
            updateHash(&context, data: data)
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func stableMediaIdentifier(bsdName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", "/dev/\(bsdName)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else { return nil }

            for key in ["VolumeUUID", "DiskUUID", "MediaUUID"] {
                if let value = plist[key] as? String, !value.isEmpty {
                    return "\(key):\(value)"
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func cdTOCFingerprint(bsdName: String) -> String? {
        guard let reader = try? NativeRawCDReader(bsdName: bsdName) else { return nil }
        let tracks = reader.layout.tracks.map {
            "\($0.number):\($0.session):\($0.control):\($0.startLBA)"
        }.joined(separator: "|")
        guard !tracks.isEmpty else { return nil }
        let material = "cd-toc-v2|\(tracks)|leadout:\(reader.layout.leadoutLBA)"
        return sha256(Data(material.utf8))
    }

    private func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func updateHash(_ context: inout CC_SHA256_CTX, data: Data) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            CC_SHA256_Update(&context, baseAddress, CC_LONG(buffer.count))
        }
    }
}
