//
//  Discbot.swift
//  Discbot
//
//  Main application entry point
//

import SwiftUI
import AppKit
import Combine

// MARK: - Settings

final class AppSettings: ObservableObject {
    private enum Keys {
        static let mockChangerEnabled = "mockChangerEnabled"
    }

    @Published var mockChangerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(mockChangerEnabled, forKey: Keys.mockChangerEnabled)
        }
    }

    init() {
        self.mockChangerEnabled = UserDefaults.standard.bool(forKey: Keys.mockChangerEnabled)
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewModel: ChangerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Changer")
                .font(.headline)

            Toggle(isOn: $settings.mockChangerEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mock changer")
                    Text("Simulate a 200-slot changer for UI testing. Discbot will disconnect from real hardware while this is enabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(viewModel.currentOperation != nil || viewModel.batchState?.isRunning == true)

            if viewModel.currentOperation != nil || viewModel.batchState?.isRunning == true {
                Text("Stop the current operation before changing changer settings.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 200)
    }
}

// MARK: - Menu Notification Names

extension NSNotification.Name {
    static let menuSetViewMode = NSNotification.Name("MenuSetViewMode")
    static let menuZoomIn = NSNotification.Name("MenuZoomIn")
    static let menuZoomOut = NSNotification.Name("MenuZoomOut")
    static let menuSetSlotFilter = NSNotification.Name("MenuSetSlotFilter")
    static let menuImageSelected = NSNotification.Name("MenuImageSelected")
}

// App delegate - handles window creation for macOS 10.15+
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()
    let settings = AppSettings()
    lazy var viewModel: ChangerViewModel = ChangerViewModel(settings: settings)
    var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var deviceObserver: NSObjectProtocol?
    private var crashRecoveryObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for macOS Tahoe (macOS 26+) which removed FireWire support
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            showTahoeWarning()
        }

        let contentView = MainView()
            .environmentObject(viewModel)
            .environmentObject(settings)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "Discbot"
        window?.minSize = NSSize(width: 700, height: 500)
        window?.contentView = NSHostingView(rootView: contentView)
        window?.center()
        window?.makeKeyAndOrderFront(nil)

        // Update window title when device info changes
        deviceObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DeviceInfoChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateWindowTitle()
        }

        setupMenuBar()

        // Crash recovery: check if previous session left a disc in the drive
        if let previousSlot = ChangerViewModel.checkDirtyFlag() {
            ChangerViewModel.clearDirtyFlag()

            crashRecoveryObserver = viewModel.$currentOperation
                .dropFirst()
                .filter { $0 == nil }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.showCrashRecoveryAlert(previousSlot: previousSlot)
                }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasActiveOperation = viewModel.currentOperation != nil
        let hasBatchRunning = viewModel.batchState?.isRunning == true
        let hasUnloadInProgress = viewModel.unloadAllInProgress

        guard hasActiveOperation || hasBatchRunning || hasUnloadInProgress else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.icon = appIcon
        alert.messageText = "Operation in Progress"
        alert.informativeText = "A disc operation is currently running. Quitting now will cancel the operation and attempt to eject the disc back to its slot."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Operation and Quit")
        alert.addButton(withTitle: "Don't Quit")

        if alert.runModal() == .alertSecondButtonReturn {
            return .terminateCancel
        }

        gracefulShutdown()
        return .terminateLater
    }

    private func gracefulShutdown() {
        // Cancel any running operations
        viewModel.batchState?.cancel()
        if viewModel.unloadAllInProgress {
            viewModel.cancelUnloadAll()
        }

        // Hard timeout: give up after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            ChangerViewModel.clearDirtyFlag()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        // Try to eject disc back to slot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async {
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
                return
            }

            // Give hdiutil a moment to terminate after SIGTERM
            Thread.sleep(forTimeInterval: 1.0)

            let _ = self.viewModel.emergencyEjectSync()

            ChangerViewModel.clearDirtyFlag()

            DispatchQueue.main.async {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
    }

    private func showCrashRecoveryAlert(previousSlot: Int) {
        guard viewModel.driveStatus != .empty else { return }

        let alert = NSAlert()
        alert.icon = appIcon
        alert.messageText = "Disc Left in Drive"
        alert.informativeText = "Discbot was not shut down cleanly. A disc from slot \(previousSlot) appears to still be in the drive.\n\nYou can eject it back to its slot, or leave it loaded."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eject to Slot \(previousSlot)")
        alert.addButton(withTitle: "Leave in Drive")

        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.ejectDisc(toSlot: previousSlot)
        }
    }

    private var appIcon: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon128", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    private func updateWindowTitle() {
        if viewModel.isConnected, let vendor = viewModel.deviceVendor, let product = viewModel.deviceProduct {
            window?.title = "Discbot - \(vendor) \(product)"
        } else {
            window?.title = "Discbot"
        }
    }

    private func showTahoeWarning() {
        let alert = NSAlert()
        alert.icon = appIcon
        alert.messageText = "FireWire Not Supported"
        alert.informativeText = "macOS Tahoe removed FireWire support. Discbot cannot connect to FireWire devices on this version of macOS.\n\nTo use Discbot with a FireWire changer, you'll need macOS 15 (Sequoia) or earlier."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertSecondButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Discbot", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Discbot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Refresh Inventory", action: #selector(refreshInventory), keyEquivalent: "r")

        let scanItem = NSMenuItem(title: "Catalog Unknown Discs", action: #selector(scanAllSlots), keyEquivalent: "r")
        scanItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(scanItem)

        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Load Selected Slot", action: #selector(loadSelectedSlot), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Eject to Slot", action: #selector(ejectDisc), keyEquivalent: "e")

        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Load from I/E", action: #selector(importFromIE), keyEquivalent: "i")

        let ejectDiscItem = NSMenuItem(title: "Eject Disc", action: #selector(ejectSlotToIE), keyEquivalent: "e")
        ejectDiscItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(ejectDiscItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Select All for Imaging", action: #selector(selectAllForRip), keyEquivalent: "a")

        let clearSelItem = NSMenuItem(title: "Clear Selection", action: #selector(clearRipSelection), keyEquivalent: "a")
        clearSelItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(clearSelItem)

        // Changer menu
        let changerMenuItem = NSMenuItem()
        mainMenu.addItem(changerMenuItem)
        let changerMenu = NSMenu(title: "Changer")
        changerMenuItem.submenu = changerMenu
        changerMenu.addItem(withTitle: "Load All Discs", action: #selector(loadAllDiscs), keyEquivalent: "")
        changerMenu.addItem(withTitle: "Eject All", action: #selector(ejectAllToIE), keyEquivalent: "")

        let imageItem = NSMenuItem(title: "Image Selected…", action: #selector(imageSelected), keyEquivalent: "i")
        imageItem.keyEquivalentModifierMask = [.command, .option]
        changerMenu.addItem(imageItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Grid View", action: #selector(showGridView), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "List View", action: #selector(showListView), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Carousel View", action: #selector(showCarouselView), keyEquivalent: "3")
        viewMenu.addItem(NSMenuItem.separator())

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "=")
        zoomInItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomInItem)

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(zoomOutItem)

        viewMenu.addItem(NSMenuItem.separator())

        let showAllItem = NSMenuItem(title: "Show All Slots", action: #selector(showAllSlots), keyEquivalent: "")
        showAllItem.tag = 0
        viewMenu.addItem(showAllItem)

        let showFullItem = NSMenuItem(title: "Show Full Slots Only", action: #selector(showFullSlots), keyEquivalent: "")
        showFullItem.tag = 1
        viewMenu.addItem(showFullItem)

        let showEmptyItem = NSMenuItem(title: "Show Empty Slots Only", action: #selector(showEmptySlots), keyEquivalent: "")
        showEmptyItem.tag = 2
        viewMenu.addItem(showEmptyItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let busy = viewModel.currentOperation != nil

        switch action {
        case #selector(refreshInventory), #selector(scanAllSlots):
            return !busy
        case #selector(loadSelectedSlot):
            guard !busy else { return false }
            guard let id = viewModel.selectedSlotId, id > 0, id <= viewModel.slots.count else { return false }
            let slot = viewModel.slots[id - 1]
            return slot.isFull && !slot.isInDrive
        case #selector(ejectDisc):
            guard !busy else { return false }
            if case .loaded = viewModel.driveStatus { return true }
            return false
        case #selector(importFromIE):
            guard !busy else { return false }
            guard viewModel.hasIESlot else { return false }
            if case .empty = viewModel.driveStatus { return true }
            return false
        case #selector(ejectSlotToIE):
            guard !busy else { return false }
            guard viewModel.hasIESlot else { return false }
            guard let id = viewModel.selectedSlotId, id > 0, id <= viewModel.slots.count else { return false }
            let slot = viewModel.slots[id - 1]
            return slot.isFull && !slot.isInDrive
        case #selector(selectAllForRip):
            return !viewModel.rippableSlots.isEmpty
        case #selector(clearRipSelection):
            return !viewModel.selectedSlotsForRip.isEmpty
        case #selector(loadAllDiscs):
            return !busy && viewModel.fullSlotCount > 0
        case #selector(ejectAllToIE):
            return !busy && viewModel.fullSlotCount > 0 && viewModel.hasIESlot
        case #selector(imageSelected):
            return !busy && !viewModel.selectedSlotsForRip.isEmpty
        default:
            return true
        }
    }

    // MARK: - Menu Actions

    @objc private func showPreferences() {
        if settingsWindow == nil {
            let rootView = SettingsView()
                .environmentObject(settings)
                .environmentObject(viewModel)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: rootView)
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        let alert = NSAlert()
        alert.icon = appIcon
        alert.messageText = "Discbot"
        alert.informativeText = """
            Version \(version) (\(build))

            by Jackson Tomlinson
            github.com/toml0006/discbot
            """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open GitHub")

        if alert.runModal() == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/toml0006/discbot") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func refreshInventory() {
        viewModel.refreshInventory()
    }

    @objc func scanAllSlots() {
        viewModel.scanInventory()
    }

    @objc func loadSelectedSlot() {
        if let slot = viewModel.selectedSlotId {
            viewModel.loadSlotWithEjectIfNeeded(slot)
        }
    }

    @objc func ejectDisc() {
        viewModel.ejectDisc()
    }

    @objc func importFromIE() {
        viewModel.importFromIESlot()
    }

    @objc func ejectSlotToIE() {
        if let slot = viewModel.selectedSlotId {
            viewModel.unloadSlot(slot)
        }
    }

    @objc func selectAllForRip() {
        viewModel.selectAllSlotsForRip()
    }

    @objc func clearRipSelection() {
        viewModel.clearSlotSelectionForRip()
    }

    @objc func loadAllDiscs() {
        viewModel.startBatchLoad()
    }

    @objc func ejectAllToIE() {
        viewModel.startUnloadAll()
    }

    @objc func imageSelected() {
        NotificationCenter.default.post(name: .menuImageSelected, object: nil)
    }

    @objc func showGridView() {
        NotificationCenter.default.post(name: .menuSetViewMode, object: "grid")
    }

    @objc func showListView() {
        NotificationCenter.default.post(name: .menuSetViewMode, object: "list")
    }

    @objc func showCarouselView() {
        NotificationCenter.default.post(name: .menuSetViewMode, object: "carousel")
    }

    @objc func zoomIn() {
        NotificationCenter.default.post(name: .menuZoomIn, object: nil)
    }

    @objc func zoomOut() {
        NotificationCenter.default.post(name: .menuZoomOut, object: nil)
    }

    @objc func showAllSlots() {
        viewModel.slotFilter = .all
    }

    @objc func showFullSlots() {
        viewModel.slotFilter = .full
    }

    @objc func showEmptySlots() {
        viewModel.slotFilter = .empty
    }
}
