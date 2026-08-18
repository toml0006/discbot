//
//  MountService.swift
//  Discbot
//
//  Service for disc detection and mounting via DiskArbitration
//

import Foundation
import Darwin
import os.log

extension Process {
    /// Wait without allowing a wedged optical-media utility to block the
    /// entire batch forever. Returns false after terminating a timed-out child.
    @discardableResult
    func discbotWaitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard isRunning else { return true }

        terminate()
        let terminationDeadline = Date().addingTimeInterval(1)
        while isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isRunning { _ = kill(processIdentifier, SIGKILL) }
        return false
    }
}

protocol MountServicing: AnyObject {
    func waitForDisc(timeout: TimeInterval) throws -> String
    func findDiscBSDName() -> String?
    func isDiscPresent() -> Bool
    func mountDisc(bsdName: String, timeout: Int) throws -> String
    func mountAudioDisc(bsdName: String, timeout: Int) throws -> String
    func unmountDisc(bsdName: String, force: Bool) throws
    func ejectDisc(bsdName: String, force: Bool) throws
    func isMounted(bsdName: String) -> Bool
    func getMountPoint(bsdName: String) -> String?
    func getVolumeName(bsdName: String) -> String?
    func waitAndMount(timeout: TimeInterval) throws -> (bsdName: String, mountPoint: String)
}

extension MountServicing {
    func mountDisc(bsdName: String) throws -> String {
        try mountDisc(bsdName: bsdName, timeout: 30)
    }

    func mountAudioDisc(bsdName: String, timeout: Int = 30) throws -> String {
        try mountDisc(bsdName: bsdName, timeout: timeout)
    }

    func unmountDisc(bsdName: String) throws {
        try unmountDisc(bsdName: bsdName, force: false)
    }

    func ejectDisc(bsdName: String) throws {
        try ejectDisc(bsdName: bsdName, force: false)
    }
}

final class MountService {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Discbot",
        category: "MountService"
    )

    private func logFailure(_ context: String, bsdName: String? = nil, details: String) {
        if let bsdName = bsdName {
            os_log(
                "%{public}@ failed for %{public}@: %{public}@",
                log: Self.log,
                type: .error,
                context,
                bsdName,
                details
            )
        } else {
            os_log(
                "%{public}@ failed: %{public}@",
                log: Self.log,
                type: .error,
                context,
                details
            )
        }
    }

    /// Wait for a disc to appear in the drive (blocking)
    func waitForDisc(timeout: TimeInterval = 60) throws -> String {
        let result = mount_wait_for_disc(Int32(timeout))

        if result != 0 {
            logFailure("waitForDisc", details: "Timed out after \(Int(timeout))s waiting for media")
            throw ChangerError.timeout
        }

        guard let bsdName = findDiscBSDName() else {
            logFailure("waitForDisc", details: "Media present signal received but BSD name lookup returned nil")
            throw ChangerError.timeout
        }

        return bsdName
    }

    /// Find the BSD name of a disc in the drive
    func findDiscBSDName() -> String? {
        let result = mount_find_dvd_bsd_name()
        guard let cStr = result else { return nil }
        let name = String(cString: cStr)
        free(UnsafeMutableRawPointer(mutating: cStr))
        return name.isEmpty ? nil : name
    }

    /// Check if disc is present
    func isDiscPresent() -> Bool {
        return mount_is_disc_present()
    }

    /// Mount a disc by BSD name (blocking)
    func mountDisc(bsdName: String, timeout: Int = 30) throws -> String {
        // Already mounted (or auto-mounted by macOS) - just return it.
        if let existingMount = getMountPoint(bsdName: bsdName) {
            return existingMount
        }

        let result = mount_disc(bsdName, Int32(timeout))

        guard let cStr = result else {
            // Some media types (notably audio CDs) have no filesystem mount point.
            // Also handle races where mount completed but callback didn't return a path.
            if let mountPoint = getMountPoint(bsdName: bsdName) {
                return mountPoint
            }

            // Catalina's Disk Arbitration daemon may decline to mount CDDA
            // for a headless LaunchDaemon. mount_cddafs is user-runnable and
            // mounts only the explicitly selected changer BSD device.
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let mountURL = applicationSupport
                .appendingPathComponent("Discbot", isDirectory: true)
                .appendingPathComponent("CDMounts", isDirectory: true)
                .appendingPathComponent(bsdName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: mountURL,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                // IOCDMedia and its TOC can appear several seconds before the
                // drive accepts the first cddafs mount. Retry only this exact
                // changer device for a bounded readiness window.
                for _ in 0..<4 {
                    if let mounted = getMountPoint(bsdName: bsdName) {
                        return mounted
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/sbin/mount_cddafs")
                    process.arguments = ["/dev/\(bsdName)", mountURL.path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let completed = process.discbotWaitUntilExit(timeout: 15)
                    if completed, process.terminationStatus == 0 {
                        return getMountPoint(bsdName: bsdName) ?? mountURL.path
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            } catch {
                logFailure(
                    "mountDisc cddafs fallback",
                    bsdName: bsdName,
                    details: error.localizedDescription
                )
            }
            logFailure("mountDisc", bsdName: bsdName, details: "No mount point returned")
            throw ChangerError.mountFailed("No mount point returned")
        }

        let path = String(cString: cStr)
        free(UnsafeMutableRawPointer(mutating: cStr))
        if path.isEmpty {
            if let mountPoint = getMountPoint(bsdName: bsdName) {
                return mountPoint
            }
            logFailure("mountDisc", bsdName: bsdName, details: "Empty mount point returned")
            throw ChangerError.mountFailed("No mount point returned")
        }
        return path
    }

    /// Mount CDDA away from /Volumes so Spotlight and Quick Look do not race
    /// the ripper for a drive that can service only one audio-track open at a
    /// time. Catalina auto-mounts audio CDs in /Volumes; release that mount and
    /// immediately replace it with a private, non-browsed cddafs mount.
    func mountAudioDisc(bsdName: String, timeout: Int = 30) throws -> String {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let mountURL = applicationSupport
            .appendingPathComponent("Discbot", isDirectory: true)
            .appendingPathComponent("CDMounts", isDirectory: true)
            .appendingPathComponent(bsdName, isDirectory: true)

        try FileManager.default.createDirectory(
            at: mountURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        if let existing = getMountPoint(bsdName: bsdName), existing == mountURL.path {
            return existing
        }
        if isMounted(bsdName: bsdName) {
            try unmountDisc(bsdName: bsdName, force: true)
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        repeat {
            if let existing = getMountPoint(bsdName: bsdName) {
                if existing == mountURL.path { return existing }
                // Disk Arbitration may race us by restoring /Volumes/Audio CD.
                // Release it again rather than handing an indexed mount to zip.
                try? unmountDisc(bsdName: bsdName, force: true)
            }

            // Ask Disk Arbitration to perform the cddafs mount at our private
            // directory. Launching the server through LaunchServices gives it
            // the Aqua-session authorization required by Catalina without
            // exposing the volume to Spotlight.
            if let mountedPointer = mount_disc_at(bsdName, mountURL.path, 15) {
                let mountedPath = String(cString: mountedPointer)
                free(UnsafeMutableRawPointer(mutating: mountedPointer))
                if mountedPath == mountURL.path { return mountedPath }
                try? unmountDisc(bsdName: bsdName, force: true)
            }

            // Retain the direct utility as a fallback when Disk Arbitration
            // declines a caller-selected path. Never fall back to /Volumes:
            // Spotlight opens every AIFF there and wedges this bridge's
            // single-stream CDDA reader before the rip can start.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/mount_cddafs")
            process.arguments = ["/dev/\(bsdName)", mountURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let completed = process.discbotWaitUntilExit(timeout: 15)
            if completed, process.terminationStatus == 0 {
                return getMountPoint(bsdName: bsdName) ?? mountURL.path
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline

        logFailure(
            "mountAudioDisc",
            bsdName: bsdName,
            details: "Could not establish a private cddafs mount"
        )
        throw ChangerError.mountFailed("Could not establish a private audio-CD mount")
    }

    /// Unmount a disc by BSD name (blocking)
    func unmountDisc(bsdName: String, force: Bool = false) throws {
        guard !bsdName.isEmpty else {
            logFailure("unmountDisc", details: "Empty BSD name")
            throw ChangerError.unmountFailed("Missing BSD device name")
        }

        // Do not short-circuit based on mount-point discovery. cddafs can own
        // an audio device while Disk Arbitration exposes no conventional
        // volume path; it still needs an explicit unmount before raw reads.
        var result = mount_unmount_disc(bsdName, force)

        // If default unmount fails (often due to another app holding the disc),
        // retry once with force.
        if result != 0 && !force {
            result = mount_unmount_disc(bsdName, true)
        }

        if !isMounted(bsdName: bsdName) { return }

        // A cddafs volume mounted directly by this user is most reliably
        // released by the matching user-runnable unmount utility.
        if let mountPoint = getMountPoint(bsdName: bsdName) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/umount")
            process.arguments = [mountPoint]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                _ = process.discbotWaitUntilExit(timeout: 15)
                if !isMounted(bsdName: bsdName) { return }
            } catch {
                logFailure(
                    "unmountDisc direct fallback",
                    bsdName: bsdName,
                    details: error.localizedDescription
                )
            }
        }

        if isMounted(bsdName: bsdName) {
            // If disk is no longer mounted, treat as success despite DA status code.
            if !isMounted(bsdName: bsdName) {
                return
            }


            // A system LaunchDaemon has no Aqua authorization session, so
            // Catalina can return kDAReturnNotPrivileged even after Full Disk
            // Access is granted. Its signed diskutil client can broker the
            // same device-specific unmount without running Discbot as root.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = force
                ? ["unmountDisk", "force", "/dev/\(bsdName)"]
                : ["unmountDisk", "/dev/\(bsdName)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let completed = process.discbotWaitUntilExit(timeout: 15)
                if (completed && process.terminationStatus == 0) || !isMounted(bsdName: bsdName) {
                    return
                }
            } catch {
                logFailure(
                    "unmountDisc diskutil fallback",
                    bsdName: bsdName,
                    details: error.localizedDescription
                )
            }

            let busyHint = (result == 49168) ? " (resource busy)" : ""
            logFailure("unmountDisc", bsdName: bsdName, details: "DADiskUnmount returned \(result)\(busyHint); diskutil also failed")
            throw ChangerError.unmountFailed("DADiskUnmount returned \(result)\(busyHint); diskutil also failed")
        }
    }

    /// Eject a disc by BSD name (blocking) - unmounts and releases from drive
    /// This prepares the disc for the changer to grab it
    func ejectDisc(bsdName: String, force: Bool = false) throws {
        // Catalina's Disk Arbitration and DiscRecording APIs can report a
        // successful optical eject while leaving the media's /dev/disk node
        // published. Moving that still-published media with the changer can
        // poison the FireWire SCSI user client, and the stale node can be
        // mistaken for the next disc. Use diskutil as the single primary
        // release operation and require the exact media node to disappear.
        // This remains device-specific; never use a bare `drutil eject` on a
        // host that may have more than one optical drive.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", "/dev/\(bsdName)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var diskutilSucceeded = false
        do {
            try process.run()
            let completed = process.discbotWaitUntilExit(timeout: 15)
            if completed, process.terminationStatus == 0 {
                diskutilSucceeded = true
            }
        } catch {
            logFailure("ejectDisc diskutil fallback", bsdName: bsdName, details: error.localizedDescription)
        }
        if diskutilSucceeded {
            guard waitForMediaNodeRemoval(bsdName: bsdName, timeout: 10) else {
                logFailure(
                    "ejectDisc diskutil verification",
                    bsdName: bsdName,
                    details: "diskutil succeeded but /dev/\(bsdName) remained attached"
                )
                throw ChangerError.unmountFailed(
                    "The optical media remained attached after eject"
                )
            }
            return
        }

        // Retain the framework path for systems where diskutil is unavailable,
        // but apply the same physical verification before permitting motion.
        let result = mount_eject_disc(bsdName, force)
        if result == 0, waitForMediaNodeRemoval(bsdName: bsdName, timeout: 10) {
            return
        }

        logFailure("ejectDisc", bsdName: bsdName, details: "DADiskEject returned \(result); diskutil also failed")
        throw ChangerError.unmountFailed("The optical drive did not release the disc")
    }

    private func waitForMediaNodeRemoval(bsdName: String, timeout: TimeInterval) -> Bool {
        let path = "/dev/\(bsdName)"
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return !FileManager.default.fileExists(atPath: path)
    }

    /// Check if BSD device is currently mounted
    func isMounted(bsdName: String) -> Bool {
        return mount_is_mounted(bsdName)
    }

    /// Get the current mount point for a BSD name
    func getMountPoint(bsdName: String) -> String? {
        let result = mount_get_mount_point(bsdName)
        guard let cStr = result else { return nil }
        let path = String(cString: cStr)
        free(UnsafeMutableRawPointer(mutating: cStr))
        return path.isEmpty ? nil : path
    }

    /// Get the volume name/label for a BSD name
    func getVolumeName(bsdName: String) -> String? {
        let result = mount_get_volume_name(bsdName)
        guard let cStr = result else { return nil }
        let name = String(cString: cStr)
        free(UnsafeMutableRawPointer(mutating: cStr))
        return name.isEmpty ? nil : name
    }

    /// Wait for disc to be ready and mount it (blocking)
    func waitAndMount(timeout: TimeInterval = 60) throws -> (bsdName: String, mountPoint: String) {
        let bsdName = try waitForDisc(timeout: timeout)
        let mountPoint = try mountDisc(bsdName: bsdName)
        return (bsdName, mountPoint)
    }
}

extension MountService: MountServicing {}

// MARK: - Mock Mount Service

/// In-memory mount service used when mocking the changer.
final class MockMountService: MountServicing {
    private let state: MockChangerState

    init(state: MockChangerState) {
        self.state = state
    }

    func waitForDisc(timeout: TimeInterval = 60) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let bsd = findDiscBSDName() {
                return bsd
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ChangerError.timeout
    }

    func findDiscBSDName() -> String? {
        state.snapshotDrive().bsdName
    }

    func isDiscPresent() -> Bool {
        state.snapshotDrive().hasDisc
    }

    func mountDisc(bsdName: String, timeout: Int = 30) throws -> String {
        guard state.snapshotDrive().bsdName == bsdName else {
            throw ChangerError.driveEmpty
        }
        // "Mount" is just state; no OS interaction.
        return state.mountCurrentDisc()
    }

    func unmountDisc(bsdName: String, force: Bool = false) throws {
        guard state.snapshotDrive().bsdName == bsdName else {
            throw ChangerError.driveEmpty
        }
        state.unmountCurrentDisc()
    }

    func ejectDisc(bsdName: String, force: Bool = false) throws {
        // This is typically used to ask macOS to release the disc. In mock mode, treat as unmount.
        try unmountDisc(bsdName: bsdName, force: force)
    }

    func isMounted(bsdName: String) -> Bool {
        let drive = state.snapshotDrive()
        return drive.bsdName == bsdName && drive.isMounted
    }

    func getMountPoint(bsdName: String) -> String? {
        let drive = state.snapshotDrive()
        guard drive.bsdName == bsdName else { return nil }
        return drive.mountPoint
    }

    func getVolumeName(bsdName: String) -> String? {
        let drive = state.snapshotDrive()
        guard drive.bsdName == bsdName else { return nil }
        return drive.volumeName
    }

    func waitAndMount(timeout: TimeInterval = 60) throws -> (bsdName: String, mountPoint: String) {
        let bsdName = try waitForDisc(timeout: timeout)
        let mountPoint = try mountDisc(bsdName: bsdName)
        return (bsdName, mountPoint)
    }
}
