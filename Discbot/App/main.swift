//
//  main.swift
//  Discbot
//
//  Application entry point - handles both macOS 10.15 and 11+
//

import AppKit
import SwiftUI
import Darwin

enum ProcessInstanceLockError: LocalizedError {
    case alreadyRunning(pid: Int32?)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let pid):
            return pid.map { "Discbot is already running as process \($0)" }
                ?? "Discbot is already running"
        case .unavailable(let message):
            return "Could not create Discbot's process lock: \(message)"
        }
    }
}

/// The SCSITask device grants exclusive ownership to one process. Keep that
/// invariant at the application boundary so GUI and server launches cannot
/// contend for the changer or leave one another in a false-connected state.
final class ProcessInstanceLock {
    private let descriptor: Int32

    init(url: URL? = nil) throws {
        let lockURL: URL
        if let url = url {
            lockURL = url
        } else {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Discbot", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            lockURL = support.appendingPathComponent("process.lock")
        }

        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw ProcessInstanceLockError.unavailable(String(cString: strerror(errno)))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let savedErrno = errno
            let owner = Self.readOwner(from: fd)
            Darwin.close(fd)
            if savedErrno == EWOULDBLOCK {
                throw ProcessInstanceLockError.alreadyRunning(pid: owner)
            }
            throw ProcessInstanceLockError.unavailable(String(cString: strerror(savedErrno)))
        }

        descriptor = fd
        let owner = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        owner.withCString { bytes in
            _ = Darwin.write(fd, bytes, strlen(bytes))
        }
        _ = fsync(fd)
    }

    private static func readOwner(from fd: Int32) -> Int32? {
        _ = lseek(fd, 0, SEEK_SET)
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = Darwin.read(fd, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return Int32(String(bytes: buffer.prefix(Int(count)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

if let helperIndex = CommandLine.arguments.firstIndex(of: "--changer-helper") {
    let arguments = Array(CommandLine.arguments.dropFirst(helperIndex + 1))
    exit(ChangerHelperRunner.run(arguments: arguments))
}

if CommandLine.arguments.contains("--self-test") {
    exit(SelfTestRunner.run())
}

let processInstanceLock: ProcessInstanceLock
do {
    processInstanceLock = try ProcessInstanceLock()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(75)
}

if CommandLine.arguments.contains("--server") {
    let runtime = HeadlessRemoteServerRuntime()
    do {
        try runtime.start()
    } catch {
        FileHandle.standardError.write(Data("Discbot server failed to start: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interruptSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let stopServer = {
        runtime.shutdown { success in
            if success { exit(0) }
        }
    }
    terminationSignal.setEventHandler(handler: stopServer)
    interruptSignal.setEventHandler(handler: stopServer)
    terminationSignal.resume()
    interruptSignal.resume()
    RunLoop.main.run()
    exit(0)
}

// Create and run the application
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Route service-manager and terminal shutdown through AppDelegate so an active
// batch gets the same cancel-and-return-to-slot guarantees as a GUI quit.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let interruptSignal = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
terminationSignal.setEventHandler { NSApp.terminate(nil) }
interruptSignal.setEventHandler { NSApp.terminate(nil) }
terminationSignal.resume()
interruptSignal.resume()
app.run()
