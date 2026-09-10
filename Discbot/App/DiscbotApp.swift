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
        static let remoteServerEnabled = "remoteServerEnabled"
        static let remoteServerPort = "remoteServerPort"
        static let remoteAccessToken = "remoteAccessToken"
        static let remoteDestinations = "remoteDestinations"
    }

    @Published var mockChangerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(mockChangerEnabled, forKey: Keys.mockChangerEnabled)
        }
    }

    @Published var remoteServerEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remoteServerEnabled, forKey: Keys.remoteServerEnabled)
            notifyRemoteConfigurationChanged()
        }
    }

    @Published var remoteServerPort: Int {
        didSet {
            let clamped = min(max(remoteServerPort, 1024), 65535)
            if clamped != remoteServerPort {
                remoteServerPort = clamped
                return
            }
            UserDefaults.standard.set(remoteServerPort, forKey: Keys.remoteServerPort)
            notifyRemoteConfigurationChanged()
        }
    }

    @Published var remoteAccessToken: String {
        didSet {
            UserDefaults.standard.set(remoteAccessToken, forKey: Keys.remoteAccessToken)
            notifyRemoteConfigurationChanged()
        }
    }

    @Published var remoteDestinations: [RemoteRipDestination] {
        didSet {
            if let data = try? JSONEncoder().encode(remoteDestinations) {
                UserDefaults.standard.set(data, forKey: Keys.remoteDestinations)
            }
            // Controllers read destinations dynamically. Restarting the listener
            // here would disconnect the request that just added a destination.
        }
    }

    @Published var remoteServerStatus = "Server stopped"

    init() {
        self.mockChangerEnabled = UserDefaults.standard.bool(forKey: Keys.mockChangerEnabled)
        self.remoteServerEnabled = UserDefaults.standard.bool(forKey: Keys.remoteServerEnabled)
        let savedPort = UserDefaults.standard.integer(forKey: Keys.remoteServerPort)
        self.remoteServerPort = savedPort == 0 ? 8787 : min(max(savedPort, 1024), 65535)
        let savedToken = UserDefaults.standard.string(forKey: Keys.remoteAccessToken) ?? ""
        if savedToken.isEmpty {
            self.remoteAccessToken = Self.generateAccessToken()
        } else {
            self.remoteAccessToken = savedToken
        }
        if let data = UserDefaults.standard.data(forKey: Keys.remoteDestinations),
           let decoded = try? JSONDecoder().decode([RemoteRipDestination].self, from: data) {
            self.remoteDestinations = decoded
        } else {
            self.remoteDestinations = []
        }
        UserDefaults.standard.set(remoteAccessToken, forKey: Keys.remoteAccessToken)
    }

    func rotateRemoteAccessToken() {
        remoteAccessToken = Self.generateAccessToken()
    }

    private func notifyRemoteConfigurationChanged() {
        NotificationCenter.default.post(name: .remoteServerConfigurationChanged, object: nil)
    }

    private static func generateAccessToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var viewModel: ChangerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            Divider()

            Text("Remote Server")
                .font(.headline)

            Toggle(isOn: $settings.remoteServerEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow browser control on the local network")
                    Text("Uses bearer-token authentication. Put a TLS reverse proxy or VPN in front of Discbot for access outside your trusted LAN.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Text("Port")
                TextField("Port", value: $settings.remoteServerPort, formatter: NumberFormatter())
                    .frame(width: 90)
                Stepper("", value: $settings.remoteServerPort, in: 1024...65535)
                    .labelsHidden()
                Text(settings.remoteServerStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Access token").font(.subheadline).fontWeight(.medium)
                HStack {
                    Text(settings.remoteAccessToken)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(settings.remoteAccessToken, forType: .string)
                    }
                    Button("Rotate") { settings.rotateRemoteAccessToken() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Allowed rip destinations").font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Button("Add Folder…", action: addDestination)
                }
                if settings.remoteDestinations.isEmpty {
                    Text("Add a local folder or mounted SMB/NFS share before starting a remote rip.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(settings.remoteDestinations) { destination in
                        HStack {
                            SFSymbol(name: destination.isAvailable ? "externaldrive.fill" : "exclamationmark.triangle.fill", size: 13)
                                .foregroundColor(destination.isAvailable ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.name).fontWeight(.medium)
                                Text(destination.location).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Remove") {
                                settings.remoteDestinations.removeAll { $0.id == destination.id }
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 620, height: 540)
    }

    private func addDestination() {
        let panel = NSOpenPanel()
        panel.title = "Allow Remote Rip Destination"
        panel.message = "Choose a folder that remote clients may use. Mounted network shares are supported."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let standardized = url.standardizedFileURL
        guard !settings.remoteDestinations.contains(where: { $0.path == standardized.path }) else { return }
        let name = standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
        settings.remoteDestinations.append(RemoteRipDestination(name: name, path: standardized.path))
    }
}

// MARK: - Menu Notification Names

extension NSNotification.Name {
    static let menuSetViewMode = NSNotification.Name("MenuSetViewMode")
    static let menuZoomIn = NSNotification.Name("MenuZoomIn")
    static let menuZoomOut = NSNotification.Name("MenuZoomOut")
    static let menuSetSlotFilter = NSNotification.Name("MenuSetSlotFilter")
    static let menuImageSelected = NSNotification.Name("MenuImageSelected")
    static let menuShowCatalog = NSNotification.Name("MenuShowCatalog")
    static let remoteServerConfigurationChanged = NSNotification.Name("RemoteServerConfigurationChanged")
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
    private var terminationDeadline: Date?
    private var remoteServer: RemoteControlServer?
    private var remoteServerObserver: NSObjectProtocol?
    private var remoteControlAdapter: ChangerRemoteControlAdapter?
    private var isHeadlessServer: Bool { CommandLine.arguments.contains("--server") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for macOS Tahoe (macOS 26+) which removed FireWire support
        if !isHeadlessServer && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
            showTahoeWarning()
        }

        if !isHeadlessServer {
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
        }

        // Update window title when device info changes
        deviceObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("DeviceInfoChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateWindowTitle()
        }

        if !isHeadlessServer { setupMenuBar() }

        remoteServerObserver = NotificationCenter.default.addObserver(
            forName: .remoteServerConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.configureRemoteServer() }
        configureRemoteServer()

        // Crash recovery: check if previous session left a disc in the drive
        if !isHeadlessServer, let previousSlot = ChangerViewModel.checkDirtyFlag() {
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

    func applicationWillTerminate(_ notification: Notification) {
        remoteServer?.stop()
        if let observer = remoteServerObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private func configureRemoteServer() {
        let shouldRun = settings.remoteServerEnabled || isHeadlessServer
        guard shouldRun else {
            remoteServer?.stop()
            remoteServer = nil
            settings.remoteServerStatus = "Server stopped"
            return
        }

        if remoteControlAdapter == nil {
            remoteControlAdapter = ChangerRemoteControlAdapter(viewModel: viewModel)
        }
        guard let adapter = remoteControlAdapter else { return }
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
        remoteServer?.stop()
        let server = RemoteControlServer(controller: controller) { [weak self] status in
            self?.settings.remoteServerStatus = status
            if self?.isHeadlessServer == true { print("Discbot server: \(status)") }
        }
        remoteServer = server
        do {
            try server.start(port: UInt16(settings.remoteServerPort))
        } catch {
            settings.remoteServerStatus = "Server failed: \(error.localizedDescription)"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasActiveOperation = viewModel.currentOperation != nil
        let hasBatchRunning = viewModel.batchState?.isRunning == true
        let hasCarouselOperation = viewModel.carouselBatchSnapshot?.running == true
        let hasDiscLoaded = viewModel.driveStatus != .empty

        guard hasActiveOperation || hasBatchRunning || hasCarouselOperation || hasDiscLoaded else {
            return .terminateNow
        }

        if isHeadlessServer {
            gracefulShutdown()
            return .terminateLater
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
        viewModel.batchState?.cancel()
        if viewModel.carouselBatchSnapshot?.running == true {
            viewModel.cancelUnloadAll()
        }
        terminationDeadline = Date().addingTimeInterval(180)
        waitForOperationCleanup()
    }

    private func waitForOperationCleanup() {
        guard let deadline = terminationDeadline else { return }
        if viewModel.currentOperation != nil || viewModel.batchState?.isRunning == true {
            guard Date() < deadline else {
                finishTermination(success: false, reason: "The running operation did not finish its safe-return cleanup before the timeout.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.waitForOperationCleanup()
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let success = self.viewModel.emergencyEjectSync()
            DispatchQueue.main.async {
                self.finishTermination(
                    success: success,
                    reason: "Discbot could not verify that the disc was returned to its source slot. The recovery marker has been preserved."
                )
            }
        }
    }

    private func finishTermination(success: Bool, reason: String) {
        terminationDeadline = nil
        if success {
            ChangerViewModel.clearDirtyFlag()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
            return
        }

        if isHeadlessServer {
            FileHandle.standardError.write(Data("Discbot server refused to quit: \(reason)\n".utf8))
            NSApplication.shared.reply(toApplicationShouldTerminate: false)
            return
        }

        let alert = NSAlert()
        alert.icon = appIcon
        alert.messageText = "Could Not Quit Safely"
        alert.informativeText = reason
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Keep Discbot Open")
        alert.runModal()
        NSApplication.shared.reply(toApplicationShouldTerminate: false)
    }

    private func showCrashRecoveryAlert(previousSlot: Int) {
        guard viewModel.driveStatus != .empty else {
            ChangerViewModel.clearDirtyFlag()
            return
        }

        let alert = NSAlert()
        alert.icon = appIcon
        alert.messageText = "Disc Left in Drive"
        alert.informativeText = "Discbot was not shut down cleanly. A disc from slot \(previousSlot) appears to still be in the drive.\n\nYou can eject it back to its slot, or leave it loaded."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eject to Slot \(previousSlot)")
        alert.addButton(withTitle: "Leave in Drive")

        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.ejectDisc(toSlot: previousSlot)
        } else {
            // The user explicitly accepted leaving this media in the drive.
            ChangerViewModel.clearDirtyFlag()
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

        let imageItem = NSMenuItem(title: "Rip Selected…", action: #selector(imageSelected), keyEquivalent: "i")
        imageItem.keyEquivalentModifierMask = [.command, .option]
        changerMenu.addItem(imageItem)
        changerMenu.addItem(NSMenuItem.separator())
        let catalogItem = NSMenuItem(title: "Disc Library…", action: #selector(showCatalog), keyEquivalent: "y")
        catalogItem.keyEquivalentModifierMask = [.command]
        changerMenu.addItem(catalogItem)

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
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
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

    @objc func showCatalog() {
        NotificationCenter.default.post(name: .menuShowCatalog, object: nil)
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
