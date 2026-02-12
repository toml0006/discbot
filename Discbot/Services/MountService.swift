//
//  MountService.swift
//  Discbot
//
//  Service for disc detection and mounting via DiskArbitration
//

import Foundation

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
    /// Wait for a disc to appear in the drive (blocking)
    func waitForDisc(timeout: TimeInterval = 60) throws -> String {
        let result = mount_wait_for_disc(Int32(timeout))

        if result != 0 {
            throw ChangerError.timeout
        }

        guard let bsdName = findDiscBSDName() else {
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
        let result = mount_disc(bsdName, Int32(timeout))

        guard let cStr = result else {
            throw ChangerError.mountFailed("No mount point returned")
        }

        let path = String(cString: cStr)
        free(UnsafeMutableRawPointer(mutating: cStr))
        return path
    }

    /// Unmount a disc by BSD name (blocking)
    func unmountDisc(bsdName: String, force: Bool = false) throws {
        let result = mount_unmount_disc(bsdName, force)
        if result != 0 {
            throw ChangerError.unmountFailed("DADiskUnmount returned \(result)")
        }
    }

    /// Eject a disc by BSD name (blocking) - unmounts and releases from drive
    /// This prepares the disc for the changer to grab it
    func ejectDisc(bsdName: String, force: Bool = false) throws {
        let result = mount_eject_disc(bsdName, force)
        if result != 0 {
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
