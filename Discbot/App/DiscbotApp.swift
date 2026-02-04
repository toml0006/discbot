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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = MainView()
            .environmentObject(viewModel)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window?.title = "VGP-XL1B Changer"
        window?.minSize = NSSize(width: 700, height: 500)
        window?.contentView = NSHostingView(rootView: contentView)
        window?.center()
        window?.makeKeyAndOrderFront(nil)

        // Set up menu bar
        setupMenuBar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About VGP-XL1B Changer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit VGP-XL1B Changer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
