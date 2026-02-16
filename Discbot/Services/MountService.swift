//
//  MountService.swift
//  Discbot
//
//  Service for disc detection and mounting via DiskArbitration
//

import Foundation
import os.log

protocol MountServicing: AnyObject {
    func waitForDisc(timeout: TimeInterval) throws -> String
    func findDiscBSDName() -> String?
    func isDiscPresent() -> Bool
    func mountDisc(bsdName: String, timeout: Int) throws -> String
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

    /// Unmount a disc by BSD name (blocking)
    func unmountDisc(bsdName: String, force: Bool = false) throws {
        guard !bsdName.isEmpty else {
            logFailure("unmountDisc", details: "Empty BSD name")
            throw ChangerError.unmountFailed("Missing BSD device name")
        }

        // Already unmounted; treat as success.
        if !isMounted(bsdName: bsdName) {
            return
        }

        var result = mount_unmount_disc(bsdName, force)

        // If default unmount fails (often due to another app holding the disc),
        // retry once with force.
        if result != 0 && !force {
            result = mount_unmount_disc(bsdName, true)
        }

        if result != 0 {
            // If disk is no longer mounted, treat as success despite DA status code.
            if !isMounted(bsdName: bsdName) {
                return
            }
            let busyHint = (result == 49168) ? " (resource busy)" : ""
            logFailure("unmountDisc", bsdName: bsdName, details: "DADiskUnmount returned \(result)\(busyHint)")
            throw ChangerError.unmountFailed("DADiskUnmount returned \(result)\(busyHint)")
        }
    }

    /// Eject a disc by BSD name (blocking) - unmounts and releases from drive
    /// This prepares the disc for the changer to grab it
    func ejectDisc(bsdName: String, force: Bool = false) throws {
        let result = mount_eject_disc(bsdName, force)
        if result != 0 {
            logFailure("ejectDisc", bsdName: bsdName, details: "DADiskEject returned \(result)")
            throw ChangerError.unmountFailed("DADiskEject returned \(result)")
        }
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
