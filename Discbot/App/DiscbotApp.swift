//
//  Discbot.swift
//  Discbot
//
//  Main application entry point
//

import SwiftUI
import AppKit

// App delegate - handles window creation for macOS 10.15+
class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    let viewModel = ChangerViewModel()
    var window: NSWindow?
    private var deviceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for macOS Tahoe (16.0+) which removed FireWire support
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16 {
            showTahoeWarning()
        }

        let contentView = MainView()
            .environmentObject(viewModel)

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

        // Set up menu bar
        setupMenuBar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
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
        alert.messageText = "FireWire Not Supported"
        alert.informativeText = "macOS Tahoe removed FireWire support. Discbot cannot connect to FireWire devices on this version of macOS.\n\nTo use Discbot with a FireWire changer, you'll need macOS 15 (Sequoia) or earlier."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertSecondButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Discbot", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Discbot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Refresh Inventory", action: #selector(refreshInventory), keyEquivalent: "r")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Load Selected Slot", action: #selector(loadSelectedSlot), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Eject Disc", action: #selector(ejectDisc), keyEquivalent: "e")

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func refreshInventory() {
        viewModel.refreshInventory()
    }

    @objc func loadSelectedSlot() {
        if let slot = viewModel.selectedSlotId {
            viewModel.loadSlot(slot)
        }
    }

    @objc func ejectDisc() {
        viewModel.ejectDisc()
    }
}
